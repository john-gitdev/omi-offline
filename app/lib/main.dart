import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/pages/recordings/recordings_page.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/heypocket_service.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/utils/notifications.dart';
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
  await NotificationsService.initialize();
  await ServiceManager.init();
  await ServiceManager.instance().start();
  await RecordingsManager.cleanUpIncompleteExtraction();

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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    try {
      final deviceProvider = Provider.of<DeviceProvider>(
        context,
        listen: false,
      );
      if (state == AppLifecycleState.paused) {
        deviceProvider.onAppPaused();
      } else if (state == AppLifecycleState.resumed) {
        deviceProvider.onAppResumed();
      }
    } catch (_) {
      // Provider not yet available during early lifecycle
    }
  }

  void _checkHeyPocketKey() {
    final apiKey = SharedPreferencesUtil().heypocketApiKey;
    if (apiKey.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        HeyPocketService.testConnection(apiKey)
            .then((ok) {
              if (!ok) {
                SharedPreferencesUtil().heypocketEnabled = false;
              }
            })
            .catchError((e) {
              SharedPreferencesUtil().heypocketEnabled = false;
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
