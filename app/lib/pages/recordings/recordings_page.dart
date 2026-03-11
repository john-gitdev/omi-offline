import 'package:flutter/material.dart';

class RecordingsPage extends StatelessWidget {
  const RecordingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        title: const Text('Recordings'),
        backgroundColor: const Color(0xFF0D0D0D),
      ),
      body: const Center(
        child: Text(
          'Recordings list will go here',
          style: TextStyle(color: Colors.white),
        ),
      ),
    );
  }
}
