import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

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
          id: 2002,
          channelId: 'omi_sync_channel',
          channelName: 'Omi Sync',
          channelDescription: 'Shown while syncing or processing recordings.',
          channelImportance: NotificationChannelImportance.DEFAULT,
          priority: NotificationPriority.DEFAULT,
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

  static const String defaultTitle = 'Omi Offline';

  static Future<ServiceRequestResult> startForegroundTask({
    String title = defaultTitle,
    String text = 'Connecting...',
  }) async {
    if (_isStarting) {
      return const ServiceRequestSuccess();
    }

    _isStarting = true;

    try {
      if (await FlutterForegroundTask.isRunningService) {
        // Service already running: update in place. updateService() reposts the
        // notification under the same id (bringing it back if the user swiped it
        // away on Android 14+) and — unlike stopService()+startService() — is NOT
        // subject to the Android 12+ "start FGS from background" restriction,
        // which would throw and leave us with no foreground service during a
        // background sync.
        return await FlutterForegroundTask.updateService(
          notificationTitle: title,
          notificationText: text,
        );
      }
      final result = await FlutterForegroundTask.startService(
        notificationTitle: title,
        notificationText: text,
        callback: _startForegroundCallback,
      );
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
    await FlutterForegroundTask.updateService(notificationTitle: title, notificationText: text);
  }

  static Future<void> stopForegroundTask() async {
    Logger.debug('stopForegroundTask');
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
