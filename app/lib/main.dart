import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:omi/utils/debug_log_manager.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/pages/recordings/recordings_page.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/heypocket_service.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/utils/audio/sync_notification.dart';
import 'package:provider/provider.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Register the BLE Flutter API handler so native can call into Dart
  // (scan results, connection events, characteristic updates, etc.)
  BleFlutterApi.setUp(BleBridge.instance);

  initOpus(await opus_flutter.load());
  await SharedPreferencesUtil.init();
  // Bring the flat processing prefs into line with the recording mode.
  //
  // `manualMode` is only a label; the processor reads the flat vad* prefs, and
  // the two carried INDEPENDENT defaults. A fresh install is labelled Manual
  // (manualMode defaults true, matching the firmware's own DEFAULT_VAD_THRESHOLD
  // of 32769) while those flat prefs still hold auto-shaped legacy defaults:
  // Silero on, a 120 s silence split, a 3 s noise filter and a 60-minute cap. So
  // until the user first opened Recording Settings and saved, every manual
  // recording was cut by auto's rules — split at two minutes of quiet, quiet
  // stretches filed as ghost rows, and hard-capped at an hour. Nothing else
  // corrected it: the on-connect adopt only fires when the mode actually
  // CHANGES, and on a fresh install it already matches.
  //
  // Idempotent for anyone who has saved — it rewrites the flat prefs from the
  // same per-mode snapshot the settings page wrote them from — and corrective
  // for anyone who has not. Safe to run unconditionally because _saveSettings is
  // the only other writer of these keys.
  SharedPreferencesUtil().applyRecordingModeDefaults(SharedPreferencesUtil().manualMode);
  // Version stamp, first thing after prefs are up so it heads the launch's log
  // lines. Firmware is the last-read value (nothing is connected yet); the
  // connect that follows confirms it with a device_version line of its own.
  //
  // Read from the flat lastLoggedFirmwareRevision string and NOT from
  // `btDevice`, whose getter jsonDecodes a stored blob: this runs before
  // runApp(), so anything that throws here is an app that will not start at all.
  // The cost is that the very first launch on this build says "unknown" until
  // the first connect populates it.
  await SyncNotification.requestPermissions();
  await ServiceManager.init();
  await ServiceManager.instance().start();

  // Constructed HERE, not by the widget tree, and this is load-bearing.
  //
  // Its constructor is what registers BleBridge.backgroundSyncRequestedCallback — the
  // entry point for every scheduled sync. It used to be built by a lazy
  // ChangeNotifierProvider, i.e. on the first widget that read it, which was fine while
  // the engine died with the Activity: no UI meant no Dart at all. The engine now
  // outlives the Activity (see MyApp on the Android side), so a process can be started by
  // WorkManager with no Activity ever attached — and with no view there is nothing to
  // drive a frame, so the tree may never build. That would leave native reporting Dart
  // alive, delivering the request, and BleBridge calling a null callback: a sync that
  // reports success having done nothing, which is worse than the failure it replaced
  // because it is silent.
  final deviceProvider = DeviceProvider();

  // The Flutter engine now outlives MainActivity (created and cached by MyApp on the
  // Android side, so an OS memory-reclaim of the Activity no longer takes Dart with it —
  // which is what lets a scheduled background sync find something to run). Two
  // consequences are handled here.
  const systemChannel = MethodChannel('com.omi.offline/system');

  // 1. main() runs once per PROCESS now, not once per app-open, and that process can live
  //    for days. Native signals a re-attach so the launch housekeeping still happens each
  //    time the user actually opens the app.
  systemChannel.setMethodCallHandler((call) async {
    if (call.method == 'uiReattached') {
      Logger.debug('main: UI re-attached to a running engine — re-running launch housekeeping');
      await _launchHousekeeping();
    }
    return null;
  });

  // 2. Readiness is DART's to declare, not the engine's to assume. Native used to set
  //    isFlutterAlive the moment it created the engine, which is synchronously before a
  //    single line of Dart has run — fine while the engine only ever existed alongside an
  //    Activity, but a WorkManager-started process would otherwise be told Dart is ready
  //    and post a sync request at an engine with no Pigeon handler and no DeviceProvider.
  //    Everything the sync path needs is up by this point.
  try {
    await systemChannel.invokeMethod('dartReady');
  } catch (e) {
    Logger.error('main: could not signal readiness to native ($e)');
  }

  await _launchHousekeeping();

  runApp(MyApp(deviceProvider: deviceProvider));
}

/// Work that belongs to opening the app rather than to starting the process.
///
/// Every step is idempotent and safe to repeat: they sweep temp files and expired
/// discards, and stamp the log with the running versions. Failures are logged and
/// swallowed — this must never be the reason the app does not come up.
Future<void> _launchHousekeeping() async {
  unawaited(DebugLogManager.logAppStart(
    lastKnownFirmware: SharedPreferencesUtil().lastLoggedFirmwareRevision,
  ));
  try {
    await RecordingsManager.cleanUpIncompleteExtraction();
    await RecordingsManager.cleanupOrphanedTempFiles();
    await RecordingsManager.runRecoverySweep();
  } catch (e) {
    Logger.error('main: launch housekeeping failed: $e');
  }
}

class MyApp extends StatefulWidget {
  /// Built in [main] before runApp — see the note there. Passed in rather than created
  /// by the provider so that it exists whether or not a UI ever attaches.
  final DeviceProvider deviceProvider;

  const MyApp({super.key, required this.deviceProvider});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkHeyPocketKey();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _checkHeyPocketKey() {
    final apiKey = SharedPreferencesUtil().heypocketApiKey;
    if (apiKey.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        HeyPocketService.testConnection(apiKey).then((ok) {
          if (!ok) {
            SharedPreferencesUtil().heypocketEnabled = false;
          }
        }).catchError((e) {
          // Network errors (timeout, no connection) should not disable the
          // integration — we simply cannot verify the key right now.
          Logger.error('HeyPocket startup check failed: $e');
        }),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [ChangeNotifierProvider.value(value: widget.deviceProvider)],
      child: MaterialApp(
        title: 'Offline Recorder',
        theme: ThemeData.dark(),
        home: const RecordingsPage(),
      ),
    );
  }
}
