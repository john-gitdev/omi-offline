import 'package:flutter/material.dart';
import 'package:omi/pages/recordings/recordings_page.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/services.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:provider/provider.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  initOpus(await opus_flutter.load());
  await SharedPreferencesUtil.init();
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
