import 'package:flutter/material.dart';

Widget getDialog(
  BuildContext context,
  VoidCallback onCancel,
  VoidCallback onConfirm,
  String title,
  String content, {
  String? cancelText,
  String? confirmText,
  bool singleButton = false,
}) {
  return AlertDialog(
    title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 20)),
    content: Text(content, style: const TextStyle(color: Colors.white, fontSize: 16)),
    backgroundColor: Colors.grey.shade900,
    actions: [
      if (!singleButton)
        TextButton(
          onPressed: onCancel,
          child: Text(cancelText ?? 'Cancel', style: const TextStyle(color: Colors.white)),
        ),
      TextButton(
        onPressed: onConfirm,
        child: Text(confirmText ?? 'OK', style: const TextStyle(color: Colors.white)),
      ),
    ],
  );
}
