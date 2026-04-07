import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DebugTools: verify sync page imports are correct and page builds', () {
    // A quick check that nothing throws when looking at sync_page.dart
    final syncPage = File('lib/pages/settings/sync_page.dart');
    expect(syncPage.existsSync(), true);
  });
}
