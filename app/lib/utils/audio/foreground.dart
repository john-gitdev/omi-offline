import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:omi/utils/logger.dart';

@pragma('vm:entry-point')
void _startForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(_ForegroundFirstTaskHandler());
}

class _ForegroundFirstTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter taskStarter) async {
    Logger.debug("Starting foreground task");
  }

  @override
  void onReceiveData(Object data) async {
    Logger.debug('onReceiveData: $data');
  }

  @override
  void onRepeatEvent(DateTime timestamp) async {
    Logger.debug("Foreground repeat event triggered");
    FlutterForegroundTask.sendDataToMain('heartbeat');
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    Logger.debug("Destroying foreground task");
    FlutterForegroundTask.stopService();
  }
}

class ForegroundUtil {
  static bool _isInitialized = false;
  static bool _isStarting = false;

  static Future<void> requestPermissions() async {
    // Android 13+, you need to allow notification permission to display foreground service notification.
    //
    // iOS: If you need notification, ask for permission.
    final NotificationPermission notificationPermissionStatus =
        await FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermissionStatus != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    if (Platform.isAndroid) {
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    }
  }

  Future<bool> get isIgnoringBatteryOptimizations async => await FlutterForegroundTask.isIgnoringBatteryOptimizations;

  static Future<bool> get isRunningService async => await FlutterForegroundTask.isRunningService;

  static Future<void> initializeForegroundService() async {
    if (_isInitialized) {
      Logger.debug('ForegroundService already initialized, skipping');
      return;
    }

    if (await FlutterForegroundTask.isRunningService) {
      _isInitialized = true;
      return;
    }

    Logger.debug('initializeForegroundService');

    try {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          id: 2001,
          channelId: 'omi_ble_channel',
          channelName: 'Omi BLE',
          channelDescription: 'Omi background services.',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(60 * 1000),
          autoRunOnBoot: true,
          allowWakeLock: true,
          allowWifiLock: false,
        ),
      );
      _isInitialized = true;
      Logger.debug('ForegroundService initialized successfully');
    } catch (e) {
      Logger.debug('ForegroundService initialization failed: $e');
      _isInitialized = false;
    }
  }

  /// Brand title shown on every Omi Offline foreground notification. The idle
  /// "sync timer" notification overrides this with its own countdown title.
  static const String defaultTitle = 'Omi Offline';

  // Mirror of the last Dart-set notification title/text, read by the native
  // OmiBleForegroundService.onCreate so its mandatory startForeground() reuses
  // the live state instead of clobbering it with a hardcoded "Connecting...".
  // Both services share notification id 2001 (last-writer-wins), so when the
  // native service spins up mid-sync it would otherwise flash stale text until
  // the next Dart progress tick. Written via the legacy SharedPreferences
  // (getInstance) API → Android "FlutterSharedPreferences" XML with a "flutter."
  // key prefix; native reads "flutter.omi_notification_text" from there.
  // Keys are kept in sync with OmiBleForegroundService (PREFS_NOTIF_*).
  static const String _notifTitlePrefKey = 'omi_notification_title';
  static const String _notifTextPrefKey = 'omi_notification_text';

  // De-dupe guard: the legacy shared_preferences plugin uses synchronous
  // commit() for setString, so persisting on every call would do disk writes at
  // the progress-listener's tick rate. Skip the write when nothing changed —
  // bounds it to actual human-readable text changes regardless of call rate.
  static String? _lastPersistedTitle;
  static String? _lastPersistedText;

  static Future<void> _persistNotification(String title, String text) async {
    if (title == _lastPersistedTitle && text == _lastPersistedText) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_notifTitlePrefKey, title);
      await prefs.setString(_notifTextPrefKey, text);
      _lastPersistedTitle = title;
      _lastPersistedText = text;
    } catch (e) {
      Logger.debug('persistNotification failed: $e');
    }
  }

  static Future<void> _clearPersistedNotification() async {
    _lastPersistedTitle = null;
    _lastPersistedText = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_notifTitlePrefKey);
      await prefs.remove(_notifTextPrefKey);
    } catch (e) {
      Logger.debug('clearPersistedNotification failed: $e');
    }
  }

  static Future<ServiceRequestResult> startForegroundTask({
    String title = defaultTitle,
    String text = 'Connecting...',
  }) async {
    if (_isStarting) {
      return const ServiceRequestSuccess();
    }

    _isStarting = true;

    try {
      // Persist before (re)starting so a near-simultaneous native onCreate reads
      // this text rather than its "Connecting..." fallback.
      await _persistNotification(title, text);
      ServiceRequestResult result;
      if (await FlutterForegroundTask.isRunningService) {
        result = await FlutterForegroundTask.updateService(
          notificationTitle: title,
          notificationText: text,
        );
      } else {
        result = await FlutterForegroundTask.startService(
          notificationTitle: title,
          notificationText: text,
          callback: _startForegroundCallback,
        );
      }
      Logger.debug('ForegroundTask started successfully');
      return result;
    } catch (e) {
      Logger.debug('ForegroundTask start failed: $e');
      return ServiceRequestFailure(error: e.toString());
    } finally {
      _isStarting = false;
    }
  }

  static Future<void> updateNotification({String title = defaultTitle, required String text}) async {
    if (!await FlutterForegroundTask.isRunningService) return;
    // Persist before the update (awaited) so a later native onCreate sees the
    // committed value — see _persistNotification.
    await _persistNotification(title, text);
    await FlutterForegroundTask.updateService(notificationTitle: title, notificationText: text);
  }

  static Future<void> stopForegroundTask() async {
    Logger.debug('stopForegroundTask');

    // Clear the mirror so a fresh native service start falls back to
    // "Connecting..." rather than reviving stale sync/processing text.
    await _clearPersistedNotification();

    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
        _isInitialized = false;
      }
    } catch (e) {
      Logger.debug('ForegroundTask stop failed: $e');
    }
  }
}
