import 'dart:async';


import 'package:omi/backend/preferences.dart';
import 'package:omi/env/env.dart';
import 'package:omi/utils/platform/platform_service.dart';

class IntercomManager {
  static final IntercomManager _instance = IntercomManager._internal();
  static IntercomManager get instance => _instance;
  static final SharedPreferencesUtil _preferences = SharedPreferencesUtil();

  IntercomManager._internal();

  bool get _isIntercomEnabled =>

  factory IntercomManager() {
    return _instance;
  }

  Future<void> initIntercom() async {
    return PlatformService.executeIfSupportedAsync(
      _isIntercomEnabled,
      ),
    )
  }

  Future displayChargingArticle(String device) async {
    return PlatformService.executeIfSupportedAsync(
      _isIntercomEnabled,
      () async {
        if (device == 'Omi DevKit 2') {
        } else if (device == 'Omi') {
        } else {
        }
      },
    );
  }

  Future loginIdentifiedUser(String uid) async {
    return PlatformService.executeIfSupportedAsync(
      _isIntercomEnabled,
    );
  }

  Future loginUnidentifiedUser() async {
    return PlatformService.executeIfSupportedAsync(
      _isIntercomEnabled,
    );
  }

  Future displayEarnMoneyArticle() async {
    return PlatformService.executeIfSupportedAsync(
      _isIntercomEnabled,
    );
  }

  Future displayFirmwareUpdateArticle() async {
    return PlatformService.executeIfSupportedAsync(
      _isIntercomEnabled,
    );
  }

  Future logEvent(String eventName, {Map<String, dynamic>? metaData}) async {
    return PlatformService.executeIfSupportedAsync(
      _isIntercomEnabled,
    );
  }

  Future updateCustomAttributes(Map<String, dynamic> attributes) async {
    return PlatformService.executeIfSupportedAsync(
      _isIntercomEnabled,
    );
  }

  Future updateUser(String? email, String? name, String? uid) async {
    return PlatformService.executeIfSupportedAsync(
      _isIntercomEnabled,
        email: email,
        name: name,
        userId: uid,
      ),
    )
  }

  Future<void> setUserAttributes() async {
    return PlatformService.executeIfSupportedAsync(
      _isIntercomEnabled,
      () => updateCustomAttributes({
        'Notifications Enabled': _preferences.notificationsEnabled,
        'Location Enabled': _preferences.locationEnabled,
        'Apps Enabled Count': _preferences.enabledAppsCount,
        'Apps Integrations Enabled Count': _preferences.enabledAppsIntegrationsCount,
        'Speaker Profile': _preferences.hasSpeakerProfile,
        'Calendar Enabled': _preferences.calendarEnabled,
        'Primary Language': _preferences.userPrimaryLanguage,
        'Authorized Storing Recordings': _preferences.permissionStoreRecordingsEnabled,
      }),
    );
  }

  Future<void> sendTokenToIntercom(String token) async {
    return PlatformService.executeIfSupportedAsync(
      _isIntercomEnabled,
      () => Intercom.instance.sendTokenToIntercom(token),
    );
  }
}
