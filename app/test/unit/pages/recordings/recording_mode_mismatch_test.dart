import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/pages/recordings/recordings_banners.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `manualMode` is only a label; the processor reads the flat vad* prefs. An auto
/// label sitting over manual's `vadSplitSeconds = 0` is the 2026-08-14
/// configuration, so the two must move together however the mode changes — by the
/// user switching, or by the app adopting one from a replacement Omi.
void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (MethodCall call) async => call.method == 'readAll' ? <String, String>{} : null,
    );
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  group('applyRecordingModeDefaults', () {
    test('manual pins VAD off and the split to 0', () {
      final p = SharedPreferencesUtil();
      p.applyRecordingModeDefaults(true);

      expect(p.vadEnabled, isFalse);
      expect(p.vadSplitSeconds, 0);
      expect(p.vadMinSpeechSeconds, 0, reason: 'manual keeps everything; no noise filter');
    });

    test('auto restores the values the user last saved for auto', () {
      final p = SharedPreferencesUtil();
      p.autoModeVadEnabled = true;
      p.autoModeVadSplitSeconds = 300;
      p.autoModeVadMinSpeechSeconds = 10;
      p.autoModeVadMaxConversationMinutes = 45;

      p.applyRecordingModeDefaults(false);

      expect(p.vadEnabled, isTrue);
      expect(p.vadSplitSeconds, 300);
      expect(p.vadMinSpeechSeconds, 10);
      expect(p.vadMaxConversationMinutes, 45);
    });

    test('a round trip through manual and back restores auto exactly', () {
      // The property that makes adopting a mode from a replacement Omi safe: it
      // must never cost the user the auto settings they had configured.
      final p = SharedPreferencesUtil();
      p.autoModeVadSplitSeconds = 600;
      p.autoModeVadMinSpeechSeconds = 3;

      p.applyRecordingModeDefaults(false);
      final before = [p.vadSplitSeconds, p.vadMinSpeechSeconds, p.vadEnabled];
      p.applyRecordingModeDefaults(true);
      p.applyRecordingModeDefaults(false);

      expect([p.vadSplitSeconds, p.vadMinSpeechSeconds, p.vadEnabled], before);
    });

    test('manualModeUserSet starts false, so a default is not a preference', () {
      // A fresh install has manualMode true because that is the default. Reporting
      // a disagreement against an auto Omi there would be noise.
      expect(SharedPreferencesUtil().manualModeUserSet, isFalse);
    });
  });

  group('RecordingModeMismatchBanner', () {
    Widget host({required bool active, bool manual = false, VoidCallback? review, VoidCallback? dismiss}) =>
        MaterialApp(
          home: Scaffold(
            body: RecordingModeMismatchBanner(
              active: active,
              manual: manual,
              onReview: review ?? () {},
              onDismiss: dismiss ?? () {},
            ),
          ),
        );

    testWidgets('renders nothing when there is no mismatch', (tester) async {
      await tester.pumpWidget(host(active: false));
      expect(find.text('Review'), findsNothing);
    });

    testWidgets('names the mode now in force', (tester) async {
      await tester.pumpWidget(host(active: true, manual: true));
      expect(find.textContaining('set to Manual recording'), findsOneWidget);

      await tester.pumpWidget(host(active: true, manual: false));
      expect(find.textContaining('set to Automatic recording'), findsOneWidget);
    });

    testWidgets('Review and Dismiss both fire', (tester) async {
      var reviewed = false;
      var dismissed = false;
      await tester.pumpWidget(host(
        active: true,
        review: () => reviewed = true,
        dismiss: () => dismissed = true,
      ));

      await tester.tap(find.text('Review'));
      await tester.tap(find.byIcon(Icons.close));
      expect(reviewed, isTrue);
      expect(dismissed, isTrue);
    });
  });
}
