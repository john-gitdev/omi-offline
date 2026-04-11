import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

class StorageWarning extends StatelessWidget {
  final int percentage;

  const StorageWarning({super.key, required this.percentage});

  @override
  Widget build(BuildContext context) {
    if (percentage < 90) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: Colors.red.shade900,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      child: Row(
        children: [
          const FaIcon(
            FontAwesomeIcons.circleExclamation,
            color: Colors.white,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Omi storage is $percentage% full. Ensure your phone is nearby to sync segments.',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w500,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
