import 'package:flutter/material.dart';
import 'package:omi/pages/recordings/recordings_controller.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/utils/other/time_utils.dart';

/// Inline per-integration upload detail for one recording, shown on the player
/// page. A row per configured integration with its state (Uploaded / Pending /
/// Failed / Uploading / Not available — with an integration-specific reason for
/// the unavailable case) and a per-row Upload / Retry / Re-upload action, plus
/// an "Upload all pending" button. Reactive via [ListenableBuilder] on the
/// controller so rows update live as uploads progress. Renders nothing when no
/// integration is configured.
class IntegrationStatusList extends StatelessWidget {
  final RecordingsController controller;
  final Conversation conversation;

  const IntegrationStatusList({super.key, required this.controller, required this.conversation});

  Future<void> _runAction(BuildContext context, Future<List<UploadFailure>> Function() action) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final failures = await action();
      for (final f in failures) {
        messenger.showSnackBar(
          SnackBar(content: Text('${f.integration}: ${f.error.toString().replaceFirst('Exception: ', '')}')),
        );
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final statuses = controller.integrationStatuses(conversation);
        if (statuses.isEmpty) return const SizedBox.shrink();
        final anyActionable = statuses.any((s) => s.isActionable);
        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E),
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Text(
                  'Integrations',
                  style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              ...statuses.map((s) => _IntegrationRow(
                    status: s,
                    onUpload: () => _runAction(context, () => controller.uploadOne(conversation, s.name)),
                    onReupload: () =>
                        _runAction(context, () => controller.uploadOne(conversation, s.name, force: true)),
                  )),
              if (anyActionable)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => _runAction(context, () => controller.uploadConversation(conversation)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.deepPurpleAccent,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: const Text('Upload all pending',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _IntegrationRow extends StatelessWidget {
  final IntegrationStatus status;
  final VoidCallback onUpload;
  final VoidCallback onReupload;

  const _IntegrationRow({required this.status, required this.onUpload, required this.onReupload});

  /// "Last Upload Failed at: <time>" using the recorded failure time, formatted
  /// per the user's 24-hour / AM-PM preference. Plain "Last Upload Failed" when
  /// no timestamp is available.
  String _failedLabel(DateTime? at) {
    if (at == null) return 'Last Upload Failed';
    return 'Last Upload Failed at: ${fmtHourMin(at)}';
  }

  /// Why an integration can't take this recording — integration-specific so the
  /// user understands it's expected, not an error.
  String get _unavailableReason {
    switch (status.name) {
      case 'Omi Cloud':
        return 'Recorded before Omi sync was enabled';
      case 'HeyPocket':
        return 'Audio file is no longer available';
      default:
        return 'Not available for this recording';
    }
  }

  /// " (X/Total chunks)" suffix for chunked integrations (Omi Cloud) so an
  /// in-flight or failed-midway upload shows how many segments have landed.
  /// Empty when there's no multi-chunk progress to report, or once delivered
  /// (the whole recording is up — no need to count).
  String get _chunkSuffix {
    final total = status.totalSegments;
    final delivered = status.deliveredSegments;
    if (total == null || delivered == null || total <= 1) return '';
    if (status.state == IntegrationUploadState.delivered) return '';
    return ' ($delivered/$total chunks)';
  }

  @override
  Widget build(BuildContext context) {
    final (Color color, String label, IconData icon) = switch (status.state) {
      IntegrationUploadState.delivered => (Colors.green, 'Uploaded', Icons.cloud_done),
      IntegrationUploadState.uploading => (Colors.deepPurpleAccent, 'Uploading…$_chunkSuffix', Icons.cloud_upload),
      IntegrationUploadState.failed => (
          Colors.redAccent,
          '${_failedLabel(status.failedAt)}$_chunkSuffix',
          Icons.error_outline
        ),
      IntegrationUploadState.pending => (Colors.amber, 'Ready to Upload$_chunkSuffix', Icons.cloud_upload),
      IntegrationUploadState.unavailable => (Colors.grey.shade600, 'Not available', Icons.cloud_off),
    };

    Widget trailing;
    switch (status.state) {
      case IntegrationUploadState.uploading:
        trailing = const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.deepPurpleAccent),
        );
        break;
      case IntegrationUploadState.delivered:
        trailing = TextButton(
          onPressed: onReupload,
          child: Text('Re-upload', style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
        );
        break;
      case IntegrationUploadState.failed:
        trailing = TextButton(
          onPressed: onUpload,
          child:
              const Text('Retry', style: TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.w600)),
        );
        break;
      case IntegrationUploadState.pending:
        trailing = TextButton(
          onPressed: onUpload,
          child: const Text('Upload',
              style: TextStyle(color: Colors.deepPurpleAccent, fontSize: 13, fontWeight: FontWeight.w600)),
        );
        break;
      case IntegrationUploadState.unavailable:
        trailing = const SizedBox.shrink();
        break;
    }

    final isUnavailable = status.state == IntegrationUploadState.unavailable;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(status.name, style: const TextStyle(color: Colors.white, fontSize: 15)),
                const SizedBox(height: 2),
                Text(
                  isUnavailable ? _unavailableReason : label,
                  style: TextStyle(color: color, fontSize: 12),
                ),
              ],
            ),
          ),
          trailing,
        ],
      ),
    );
  }
}
