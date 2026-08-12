import 'dart:async';

import 'package:flutter/material.dart';
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
  // Version stamp, first thing after prefs are up so it heads the launch's log
  // lines. Firmware is the last-read value (nothing is connected yet); the
  // connect that follows confirms it with a device_version line of its own.
  unawaited(DebugLogManager.logAppStart(
    lastKnownFirmware: SharedPreferencesUtil().btDevice.firmwareRevision,
  ));
  await SyncNotification.requestPermissions();
  await ServiceManager.init();
  await ServiceManager.instance().start();
  await RecordingsManager.cleanUpIncompleteExtraction();
  await RecordingsManager.cleanupOrphanedTempFiles();
  await RecordingsManager.runRecoverySweep();

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

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
      providers: [ChangeNotifierProvider(create: (_) => DeviceProvider())],
      child: MaterialApp(
        title: 'Offline Recorder',
        theme: ThemeData.dark(),
        home: const RecordingsPage(),
      ),
    );
  }
}
