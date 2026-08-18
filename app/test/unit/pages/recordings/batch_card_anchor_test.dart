import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/models/integration_upload_types.dart';
import 'package:omi/models/recordings/recordings_models.dart';
import 'package:omi/pages/recordings/batch_card.dart';
import 'package:omi/pages/recordings/recordings_types.dart';

/// Coverage for the selection scroll anchor's plumbing.
///
/// Entering selection mode relays the list out from under the row the user just
/// long-pressed (the list collapses to the active day; marker sub-rows go), so
/// the page pins that row to where it already is: the row reports its on-screen
/// top edge as it starts the selection, and wears [BatchCard.anchorKey] after
/// the rebuild so the page can measure where it landed. Both halves are silent
/// when broken — the row just jumps, as it did before — so they're pinned here.
void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  final jsonl = File('/tmp/does-not-need-to-exist/discards.jsonl');

  DiscardRecord ghost(DateTime start) => DiscardRecord(
        startTime: start,
        endTime: start.add(const Duration(minutes: 1)),
        reason: 'flush_noise',
        maxVoiceProb: 0.2,
        relativeBins: const ['s/a.bin'],
        sourceJsonl: jsonl,
        audioMs: const Duration(minutes: 1).inMilliseconds,
      );

  Conversation recording(DateTime start) => Conversation(
        file: File('/tmp/recording_${start.millisecondsSinceEpoch}.wav'),
        startTime: start,
        duration: const Duration(minutes: 5),
      );

  // Newest first in the card: the recording (9:00) sits above the ghost (8:00).
  final rec = recording(DateTime(2026, 7, 9, 9));
  final gh = ghost(DateTime(2026, 7, 9, 8));
  final theBatch = Batch(
    dateString: '2026-07-09',
    date: DateTime(2026, 7, 9),
    rawSegments: const [],
    draftRecordings: const [],
    finalizedRecordings: [rec],
    discards: [gh],
  );

  Widget host({
    required void Function(RecordingRowType, String, double?) onEnterSelection,
    String? anchorId,
    GlobalKey? anchorKey,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              // A tall spacer so the rows sit well down the screen — a dy of 0
              // would pass whether or not it was really measured.
              const SizedBox(height: 200),
              BatchCard(
                batch: theBatch,
                // filterBatchRows asserts the global draft set is supplied
                // whenever the fold window is on, which it is by default.
                openDrafts: const [],
                markerMap: const {},
                anyIntegrationEnabled: false,
                filterMode: RecordingFilterMode.all,
                uploadStatus: (_) => UploadStatus.none,
                uploadCount: (_) => 0,
                isUploading: (_) => false,
                onConversationTap: (_) {},
                onMarkerTap: (_) {},
                onExportAll: (_) {},
                onUploadAll: (_) {},
                onDeleteDay: () {},
                onDeleteAllDiscards: (_) {},
                onDeleteMarkerConversation: (_) {},
                onRecoverDiscard: (_) async {},
                onDeleteDiscard: (_) async {},
                onEnterSelection: onEnterSelection,
                onToggleSelection: (_) {},
                anchorId: anchorId,
                anchorKey: anchorKey,
              ),
            ],
          ),
        ),
      );

  testWidgets('long-pressing a ghost reports its type, id and on-screen top edge', (tester) async {
    RecordingRowType? type;
    String? id;
    double? dy;
    await tester.pumpWidget(host(onEnterSelection: (t, i, d) {
      type = t;
      id = i;
      dy = d;
    }));

    final row = find.byKey(ValueKey('ghost_${gh.id}'));
    await tester.longPress(row);
    await tester.pump();

    expect(type, RecordingRowType.ghost);
    expect(id, gh.id);
    expect(dy, isNotNull);
    expect(dy, greaterThan(0));
    expect(dy, closeTo(tester.getTopLeft(row).dy, 0.5));
  });

  testWidgets('long-pressing a recording reports its path and on-screen top edge', (tester) async {
    RecordingRowType? type;
    String? id;
    double? dy;
    await tester.pumpWidget(host(onEnterSelection: (t, i, d) {
      type = t;
      id = i;
      dy = d;
    }));

    final tile = find.byType(ConversationTile);
    await tester.longPress(tile);
    await tester.pump();

    expect(type, RecordingRowType.recording);
    expect(id, rec.file.path);
    expect(dy, isNotNull);
    expect(dy, greaterThan(0));
    expect(dy, closeTo(tester.getTopLeft(tile).dy, 0.5));
  });

  testWidgets('anchorKey lands on the named row, and only on it', (tester) async {
    final key = GlobalKey();

    await tester.pumpWidget(host(onEnterSelection: (_, __, ___) {}, anchorId: gh.id, anchorKey: key));
    expect(find.byKey(key), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(key)).dy, tester.getTopLeft(find.byKey(ValueKey('ghost_${gh.id}'))).dy);

    await tester.pumpWidget(host(onEnterSelection: (_, __, ___) {}, anchorId: rec.file.path, anchorKey: key));
    expect(find.byKey(key), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(key)).dy, tester.getTopLeft(find.byType(ConversationTile)).dy);

    // No anchor asked for ⇒ no row wears the key.
    await tester.pumpWidget(host(onEnterSelection: (_, __, ___) {}));
    expect(find.byKey(key), findsNothing);
  });
}
