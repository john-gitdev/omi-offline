import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:omi/pages/recordings/recordings_page.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/heypocket_service.dart';
import 'package:omi/services/services.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/utils/notifications.dart';
import 'package:provider/provider.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterBluePlus.setLogLevel(LogLevel.none);
  initOpus(await opus_flutter.load());
  await SharedPreferencesUtil.init();
  await NotificationsService.initialize();
  await ServiceManager.init();

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
    ServiceManager.instance().start();
    _checkHeyPocketKey();
  }

  void _checkHeyPocketKey() {
    final apiKey = SharedPreferencesUtil().heypocketApiKey;
    if (apiKey.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(HeyPocketService.testConnection(apiKey).then((ok) {
        if (!ok) {
          SharedPreferencesUtil().heypocketEnabled = false;
        }
      }).catchError((e) {
        SharedPreferencesUtil().heypocketEnabled = false;
        debugPrint('HeyPocket startup check failed: $e');
      }));
    });
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => DeviceProvider()),
      ],
      child: MaterialApp(
        title: 'Offline Recorder',
        theme: ThemeData.dark(),
        home: const RecordingsPage(),
      ),
    );
  }
}
