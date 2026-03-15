import 'package:awesome_notifications/awesome_notifications.dart';

class NotificationsService {
  static const _channelKey = 'device_alerts';

  static Future<void> initialize() async {
    await AwesomeNotifications().initialize(
      null,
      [
        NotificationChannel(
          channelKey: _channelKey,
          channelName: 'Device Alerts',
          channelDescription: 'Notifications about device recording status.',
          importance: NotificationImportance.High,
          defaultPrivacy: NotificationPrivacy.Public,
        ),
      ],
      debug: false,
    );

    final allowed = await AwesomeNotifications().isNotificationAllowed();
    if (!allowed) {
      await AwesomeNotifications().requestPermissionToSendNotifications();
    }
  }

  static Future<void> showDeviceRecordingFailed() async {
    await AwesomeNotifications().createNotification(
      content: NotificationContent(
        id: 100,
        channelKey: _channelKey,
        title: 'Device stopped recording',
        body: 'Your Omi device stopped recording. Reconnect or restart the device.',
        notificationLayout: NotificationLayout.Default,
        autoDismissible: true,
      ),
    );
  }
}
