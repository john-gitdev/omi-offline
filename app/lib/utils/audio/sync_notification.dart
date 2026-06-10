import 'dart:io';

import 'package:intl/intl.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:permission_handler/permission_handler.dart';

/// Single owner of the one persistent foreground-service notification (Android
/// `OmiBleForegroundService`, id 2001). Replaces the old `flutter_foreground_task`
/// service: instead of a second notification, the Dart sync pipeline pushes its
/// state here and native renders it on the single notification.
///
/// The states form the sync cycle:
///   idle → connecting → connected → preparingSync → syncing → finishingSync →
///   preparingProcessing → processing → finishingProcessing → complete →
///   disconnecting → idle
///
/// Discrete transitions are pushed immediately (live). Only the high-frequency
/// in-state progress text (segment counter, processing %) is throttled by its
/// callers. All methods no-op on iOS, which has no persistent notification
/// (background work runs via BGProcessingTask).
class SyncNotification {
  /// Last-known next-sync time, mirrored from DeviceProvider so [idle] can render
  /// the "Next sync at H:MM" title from any caller. Null = Manual Only.
  static DateTime? nextSyncTime;

  /// Keep the foreground service alive with no device connected so the idle
  /// "Next sync / Last Sync" notification persists across BLE disconnect and app
  /// background. true while auto-sync is on and a device is bound; false in
  /// Manual Only / unbound.
  static Future<void> setPersistent(bool enabled) async {
    if (!Platform.isAndroid) return;
    try {
      await BleHostApi().setPersistentNotification(enabled);
    } catch (_) {}
  }

  /// Request the permissions the single notification needs: POST_NOTIFICATIONS
  /// (Android 13+) and, on Android, ignore-battery-optimizations so the OS lets
  /// the exact alarm wake us on schedule.
  static Future<void> requestPermissions() async {
    if (!await Permission.notification.isGranted) {
      await Permission.notification.request();
    }
    if (Platform.isAndroid && !await Permission.ignoreBatteryOptimizations.isGranted) {
      await Permission.ignoreBatteryOptimizations.request();
    }
  }

  // ── State machine ──

  /// Generic push — used for the idle state, whose text the caller computes from
  /// next-sync time / last-sync / battery / connection state.
  static Future<void> push(String title, String text) => _push(title, text);

  static Future<void> connecting() => _push('Omi Offline', 'Connecting to Omi…');
  static Future<void> connected() => _push('Omi Offline', 'Connected');
  static Future<void> preparingSync() => _push('Syncing recordings', 'Preparing…');

  /// [text] is `RecordingsController.syncingNotificationText(synced, total)`.
  static Future<void> syncing(String text) => _push('Syncing recordings', text);
  static Future<void> finishingSync() => _push('Syncing recordings', 'Finishing…');
  static Future<void> preparingProcessing() => _push('Processing recordings', 'Preparing…');

  /// [text] is `RecordingsController.processingNotificationText()`.
  static Future<void> processing(String text) => _push('Processing recordings', text);
  static Future<void> finishingProcessing() => _push('Processing recordings', 'Finishing…');
  static Future<void> complete() => _push('Conversations ready', 'Sync and processing complete');
  static Future<void> disconnecting() => _push('Omi Offline', 'Disconnecting…');

  /// Settle to the idle line: title is the next-sync time (or "Omi Offline" in
  /// Manual Only), subtext is the last-sync summary. When nothing has synced yet,
  /// falls back to connection state if the caller knows it ([isConnected] /
  /// [isConnecting]), else a neutral "Ready to sync".
  static Future<void> idle({bool? isConnected, bool? isConnecting}) async {
    final prefs = SharedPreferencesUtil();
    final lastMs = prefs.lastSyncCompletedMs;
    final next = nextSyncTime;
    final title = next != null ? 'Next sync at ${DateFormat('h:mm a').format(next)}' : 'Omi Offline';
    final String text;
    if (lastMs > 0) {
      final time = DateFormat('h:mm a').format(DateTime.fromMillisecondsSinceEpoch(lastMs));
      final status = prefs.lastSyncPartial ? 'Partial' : 'Complete';
      final battery = prefs.lastBatteryLevel;
      text = battery >= 0 ? 'Last Sync: $status • $time • $battery% Battery' : 'Last Sync: $status • $time';
    } else if (isConnected == true) {
      text = 'Omi is Connected';
    } else if (isConnecting == true) {
      text = 'Connecting...';
    } else if (isConnected == false) {
      text = 'Omi is Disconnected';
    } else {
      text = 'Ready to sync';
    }
    await _push(title, text);
  }

  /// Release Dart ownership of the notification (native resumes connection-state
  /// text). Used when leaving persistent mode.
  static Future<void> clear() async {
    if (!Platform.isAndroid) return;
    try {
      await BleHostApi().clearSyncStatus();
    } catch (_) {}
  }

  static Future<void> _push(String title, String text) async {
    if (!Platform.isAndroid) return;
    try {
      await BleHostApi().setSyncStatus(title, text);
    } catch (_) {}
  }
}
