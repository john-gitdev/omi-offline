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
          priority: NotificationPriority.HIGH,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(60 * 1000 * 5),
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

  static Future<ServiceRequestResult> startForegroundTask({
    String title = 'Omi is active',
    String text = 'Running in the background',
  }) async {
    if (_isStarting) {
      return const ServiceRequestSuccess();
    }

    _isStarting = true;

    try {
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

  static Future<void> updateNotification({required String title, required String text}) async {
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
