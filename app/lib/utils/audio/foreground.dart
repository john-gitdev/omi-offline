import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'package:omi/utils/logger.dart';
import 'package:omi/utils/platform/platform_service.dart';

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
    if (PlatformService.isDesktop) return;

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
          channelId: 'foreground_service',
          channelName: 'Foreground Service Notification',
          channelDescription: 'Transcription service is running in the background.',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.HIGH,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(60 * 1000 * 5),
          autoRunOnBoot: false,
          allowWakeLock: false,
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

  static Future<ServiceRequestResult> startForegroundTask() async {
    if (PlatformService.isDesktop) return const ServiceRequestSuccess();

    if (_isStarting) {
      Logger.debug('ForegroundTask already starting, skipping');
      return const ServiceRequestSuccess();
    }

    _isStarting = true;
    Logger.debug('startForegroundTask');

    try {
      ServiceRequestResult result;
      if (await FlutterForegroundTask.isRunningService) {
        result = await FlutterForegroundTask.restartService();
      } else {
        result = await FlutterForegroundTask.startService(
          notificationTitle: 'Your Omi Device is connected.',
          notificationText: 'Transcription service is running in the background.',
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

  static Future<void> stopForegroundTask() async {
    if (PlatformService.isDesktop) return;
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
