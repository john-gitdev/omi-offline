import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/pages/settings/firmware/firmware_mixin.dart';

class ManualFirmwareFlashPage extends StatefulWidget {
  final String zipFilePath;
  final String fileName;
  final BtDevice device;

  const ManualFirmwareFlashPage({
    super.key,
    required this.zipFilePath,
    required this.fileName,
    required this.device,
  });

  @override
  State<ManualFirmwareFlashPage> createState() => _ManualFirmwareFlashPageState();
}

class _ManualFirmwareFlashPageState extends State<ManualFirmwareFlashPage> with FirmwareMixin {
  bool _confirmed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    killMcuUpdateManager();
    super.dispose();
  }

  Future<void> _startFlash() async {
    setState(() {
      _confirmed = true;
      _error = null;
    });
    try {
      await startDfu(widget.device, zipFilePath: widget.zipFilePath);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Flash Firmware', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // File info
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1E),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const FaIcon(FontAwesomeIcons.file, color: Colors.deepPurple, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.fileName,
                            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text('Target: ${widget.device.name}',
                            style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Warning
            if (!_confirmed) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.orange.shade900.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.orange.shade700.withValues(alpha: 0.5)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: Colors.orange.shade300, size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Flashing custom firmware can brick your device. Make sure this is a valid Omi firmware build. Do not disconnect during the update.',
                        style: TextStyle(color: Colors.orange.shade300, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _startFlash,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepPurple,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Flash Firmware',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
            ],

            // Progress
            if (_confirmed && !isInstalled) ...[
              const SizedBox(height: 16),
              Text(
                isInstalling ? 'Installing...' : 'Preparing...',
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: installProgress / 100,
                backgroundColor: const Color(0xFF2A2A2E),
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.deepPurple),
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 8),
              Text('${installProgress}%', style: TextStyle(color: Colors.grey.shade400, fontSize: 14)),
            ],

            // Success
            if (isInstalled) ...[
              const SizedBox(height: 32),
              const Center(
                child: Column(
                  children: [
                    Icon(Icons.check_circle, color: Colors.green, size: 64),
                    SizedBox(height: 16),
                    Text('Firmware flashed successfully!',
                        style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                    SizedBox(height: 8),
                    Text('Your device will restart.', style: TextStyle(color: Colors.grey, fontSize: 14)),
                  ],
                ),
              ),
            ],

            // Error
            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade900.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_error!, style: TextStyle(color: Colors.red.shade300, fontSize: 13)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
