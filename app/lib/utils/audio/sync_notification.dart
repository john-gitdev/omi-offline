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

  /// Mirrored from DeviceProvider so the resting notification line can show
  /// "Muted since H:MM" while the device mic is muted. [muteSince] is null when
  /// the mute time is unknown (pre-time-sync), in which case a timeless label is
  /// used instead.
  static bool isMuted = false;
  static DateTime? muteSince;

  /// The muted title line ("Muted since 3:42 PM" / "Omi is Muted"), or null when
  /// not muted.
  static String? _mutedTitle() {
    if (!isMuted) return null;
    return muteSince != null ? 'Muted since ${DateFormat('h:mm a').format(muteSince!.toLocal())}' : 'Omi is Muted';
  }

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
  static Future<void> connected() {
    final muted = _mutedTitle();
    if (muted != null) {
      final next = nextSyncTime;
      return _push(muted, next != null ? 'Next sync at ${DateFormat('h:mm a').format(next)}' : 'Connected');
    }
    return _push('Omi Offline', 'Connected');
  }

  static Future<void> preparingSync() => _push('Syncing recordings', 'Preparing…');

  /// [text] is `RecordingsController.syncingNotificationText(synced, total)`.
  static Future<void> syncing(String text) => _push('Syncing recordings', text);
  static Future<void> finishingSync() => _push('Syncing recordings', 'Finishing…');
  static Future<void> preparingProcessing() => _push('Processing recordings', 'Preparing…');

  /// [text] is `RecordingsController.processingNotificationText()`.
  static Future<void> processing(String text) => _push('Processing recordings', text);
  static Future<void> finishingProcessing() => _push('Processing recordings', 'Finishing…');

  /// Integration upload progress, shown only while the sync/process pipeline is
  /// idle (it owns the notification when active). [text] is the controller-composed
  /// body: a one-line summary (shown collapsed) followed by per-integration lines
  /// (shown expanded via the native BigTextStyle). May contain newlines.
  static Future<void> uploading(String text) => _push('Uploading recordings', text);

  static Future<void> complete() => _push('Conversations ready', 'Sync and processing complete');
  static Future<void> disconnecting() => _push('Omi Offline', 'Disconnecting…');

  /// Settle to the idle line: title is the next-sync time (or "Omi Offline" in
  /// Manual Only), subtext is the last-sync summary. When nothing has synced yet,
  /// falls back to connection state if the caller knows it ([isConnected] /
  /// [isConnecting]), else a neutral "Ready to sync".
  static Future<void> idle({bool? isConnected, bool? isConnecting}) async {
    // Muted takes over the resting line: "Muted since 3:42 PM" / "Next sync at 4:15 PM".
    final muted = _mutedTitle();
    if (muted != null) {
      final nextMuted = nextSyncTime;
      final body = nextMuted != null ? 'Next sync at ${DateFormat('h:mm a').format(nextMuted)}' : 'Auto-sync off';
      await _push(muted, body);
      return;
    }
    final prefs = SharedPreferencesUtil();
    // Show the time of the last sync *outcome* (incl. a skip), not the last completion —
    // otherwise a "Skipped" line would borrow a stale completion timestamp.
    final lastMs = prefs.lastSyncStatusMs;
    final next = nextSyncTime;
    final title = next != null ? 'Next sync at ${DateFormat('h:mm a').format(next)}' : 'Omi Offline';
    final String text;
    if (lastMs > 0) {
      final time = DateFormat('h:mm a').format(DateTime.fromMillisecondsSinceEpoch(lastMs));
      final status = prefs.lastSyncSkipped ? 'Skipped' : (prefs.lastSyncPartial ? 'Partial' : 'Complete');
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
