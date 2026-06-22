import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/pages/recordings/recordings_banners.dart';

void main() {
  testWidgets('VadFallbackBanner is empty when inactive', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: VadFallbackBanner(active: false))));
    expect(find.textContaining('Voice detection unavailable'), findsNothing);
  });

  testWidgets('VadFallbackBanner surfaces the AAD-fallback warning when active', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: VadFallbackBanner(active: true))));
    expect(find.textContaining('Voice detection unavailable'), findsOneWidget);
  });
}
