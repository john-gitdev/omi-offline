import 'package:flutter/material.dart';
import 'package:omi/pages/recordings/recordings_page.dart';
import 'package:omi/backend/preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SharedPreferencesUtil.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Offline Recorder',
      theme: ThemeData.dark(),
      home: const RecordingsPage(),
    );
  }
}
