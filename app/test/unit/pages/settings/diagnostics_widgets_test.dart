import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/pages/settings/widgets/diagnostics_widgets.dart';
import 'package:omi/services/devices/diag_log_record.dart';

/// Regression tests for the Debug Tools diagnostics widgets.
///
/// Every case here corresponds to a defect that actually shipped into review on this
/// screen. They exist because the failures were all of one kind — the panel stating
/// something about the device that wasn't true — and that kind is invisible to
/// `flutter analyze` but trivial to pin down in a widget test.
void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  DiagLogRecord rec({int code = 1, int arg0 = 0, int arg1 = 0, int seq = 1}) =>
      DiagLogRecord(seq: seq, uptimeMs: 1000, code: code, backend: 1, arg0: arg0, arg1: arg1);

  group('DiagGroup collapsed summary', () {
    testWidgets('a clean group collapses and shows its clear summary', (tester) async {
      await tester.pumpWidget(host(const DiagGroup(
        title: 'SD write path',
        allClear: true,
        clearSummary: 'no drops',
        alertSummary: '3 blocks',
        rows: [DiagStatRow('440 B blocks dropped', '0')],
      )));

      expect(find.text('no drops'), findsOneWidget);
      // Collapsed: the rows are not built at all.
      expect(find.text('440 B blocks dropped'), findsNothing);
    });

    testWidgets('a faulting group never shows the clear summary, even hand-collapsed', (tester) async {
      // The bug: DiagGroup rendered clearSummary whenever it was collapsed, so folding
      // a group that held three block drops put "no drops" on its header.
      await tester.pumpWidget(host(const DiagGroup(
        title: 'SD write path',
        allClear: false,
        clearSummary: 'no drops',
        alertSummary: '3 blocks',
        rows: [DiagStatRow('440 B blocks dropped', '3')],
      )));

      // Starts expanded because it is not clear.
      expect(find.text('440 B blocks dropped'), findsOneWidget);

      // Collapse it by hand.
      await tester.tap(find.text('SD WRITE PATH'));
      await tester.pumpAndSettle();

      expect(find.text('440 B blocks dropped'), findsNothing);
      expect(find.text('3 blocks'), findsOneWidget);
      expect(find.text('no drops'), findsNothing, reason: 'a collapsed fault must not read as all-clear');
    });

    testWidgets('falls back to "needs attention" when no alertSummary is supplied', (tester) async {
      await tester.pumpWidget(host(const DiagGroup(
        title: 'BLE link',
        allClear: false,
        clearSummary: 'no failures',
        rows: [DiagStatRow('Connect failures', '2')],
      )));
      await tester.tap(find.text('BLE LINK'));
      await tester.pumpAndSettle();

      expect(find.text('needs attention'), findsOneWidget);
      expect(find.text('no failures'), findsNothing);
    });
  });

  group('DiagGroup expansion behaviour', () {
    testWidgets('a clean-then-faulting group opens itself', (tester) async {
      Widget build(bool clear) => host(DiagGroup(
            title: 'SD write path',
            allClear: clear,
            clearSummary: 'no drops',
            alertSummary: '1 block',
            rows: const [DiagStatRow('440 B blocks dropped', '1')],
          ));

      await tester.pumpWidget(build(true));
      expect(find.text('440 B blocks dropped'), findsNothing);

      await tester.pumpWidget(build(false));
      await tester.pumpAndSettle();
      expect(find.text('440 B blocks dropped'), findsOneWidget,
          reason: 'a counter that just moved should not stay hidden');
    });

    testWidgets('going quiet again does not yank the rows away', (tester) async {
      Widget build(bool clear) => host(DiagGroup(
            title: 'SD write path',
            allClear: clear,
            clearSummary: 'no drops',
            alertSummary: '1 block',
            rows: const [DiagStatRow('440 B blocks dropped', '1')],
          ));

      await tester.pumpWidget(build(false));
      expect(find.text('440 B blocks dropped'), findsOneWidget);

      await tester.pumpWidget(build(true));
      await tester.pumpAndSettle();
      expect(find.text('440 B blocks dropped'), findsOneWidget,
          reason: 'an expanded group must not collapse under the reader mid-read');
    });

    testWidgets('headerAction stays reachable while the group is collapsed', (tester) async {
      // The capture switch lives here precisely because the Events group collapses
      // when nothing has been captured — a control you must expand the group to reach
      // is one you cannot use to start capturing.
      var taps = 0;
      await tester.pumpWidget(host(DiagGroup(
        title: 'Events (0)',
        allClear: true,
        clearSummary: 'nothing captured',
        headerAction: DiagPill(text: 'capture off', selected: false, onTap: () => taps++),
        rows: const [DiagStatRow('held', '0')],
      )));

      expect(find.text('held'), findsNothing, reason: 'group should be collapsed');
      expect(find.text('capture off'), findsOneWidget);
      await tester.tap(find.text('capture off'));
      expect(taps, 1);
    });

    testWidgets('tapping headerAction does not toggle the group', (tester) async {
      await tester.pumpWidget(host(DiagGroup(
        title: 'Events (0)',
        allClear: true,
        clearSummary: 'nothing captured',
        headerAction: DiagPill(text: 'capture off', selected: false, onTap: () {}),
        rows: const [DiagStatRow('held', '0')],
      )));

      await tester.tap(find.text('capture off'));
      await tester.pumpAndSettle();
      expect(find.text('held'), findsNothing, reason: 'the action sits outside the expand/collapse target');
    });
  });

  group('DiagPill sizing', () {
    Size sizeOf(WidgetTester t, Finder f) => t.getSize(f);

    testWidgets('an interactive pill keeps its size when disabled mid-action', (tester) async {
      // The bug: padding was keyed on onTap, so the capture pill shrank — taking the
      // group header and the card with it — for as long as the BLE write was in flight.
      await tester.pumpWidget(host(const DiagPill(text: 'capture on', selected: true, onTap: null)));
      final disabled = sizeOf(tester, find.byType(DiagPill));

      await tester.pumpWidget(host(DiagPill(text: 'capture on', selected: true, onTap: () {})));
      final enabled = sizeOf(tester, find.byType(DiagPill));

      expect(disabled, enabled, reason: 'a pill disabled mid-action must still occupy its slot');
    });

    testWidgets('interactive pills hit 44 dp in both axes without filling the row', (tester) async {
      // Measured inside a BOUNDED parent, the way the Events group renders its filter
      // chips. The first version of this test measured a pill under loose constraints
      // and asserted only its height, which hid the real defect: the wrapper expanded
      // to whatever width the parent allowed, so every chip took the full row and the
      // five of them stacked vertically.
      const labels = ['All', 'Storage', 'Markers', 'BLE', 'Mic'];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final l in labels) DiagPill(text: l, selected: false, onTap: () {})],
            ),
          ),
        ),
      ));

      for (final l in labels) {
        final size = tester.getSize(find.ancestor(of: find.text(l), matching: find.byType(DiagPill)));
        expect(size.height, greaterThanOrEqualTo(44.0), reason: '"$l" must be tappable');
        expect(size.width, greaterThanOrEqualTo(44.0), reason: '"$l" must be tappable');
        expect(size.width, lessThan(360.0), reason: '"$l" must shrink-wrap, not claim the whole row');
      }
    });

    testWidgets('a read-only status pill stays compact', (tester) async {
      await tester.pumpWidget(host(const DiagPill(text: 'live', level: DiagLevel.ok)));
      expect(sizeOf(tester, find.byType(DiagPill)).height, lessThan(44.0));
    });
  });

  group('event severity', () {
    test('a zero mic peak is a fault, any real level is not', () {
      // vad_level: a peak of 0 is digital silence, which a real room never produces.
      expect(diagEventLevel(rec(code: 16, arg0: 0)), DiagLevel.bad);
      expect(diagEventLevel(rec(code: 16, arg0: 120)), DiagLevel.info);
    });

    test('a boot with no bond keys is a fault, a deliberate wipe is not', () {
      // bond_state: arg0 = cause (0 boot load, 1 post-DFU, 2 gesture), arg1 = keys after.
      expect(diagEventLevel(rec(code: 12, arg0: 0, arg1: 0)), DiagLevel.bad);
      expect(diagEventLevel(rec(code: 12, arg0: 0, arg1: 1)), DiagLevel.info);
      expect(diagEventLevel(rec(code: 12, arg0: 1, arg1: 0)), DiagLevel.info);
      // A wipe that left keys behind did not take.
      expect(diagEventLevel(rec(code: 12, arg0: 1, arg1: 2)), DiagLevel.bad);
    });

    test('a mic rail that was not cycled is a warning', () {
      expect(diagEventLevel(rec(code: 17, arg0: 1)), DiagLevel.info);
      expect(diagEventLevel(rec(code: 17, arg0: 0)), DiagLevel.warn);
    });

    test('unknown codes from newer firmware are surfaced, not dropped', () {
      expect(diagEventLevel(rec(code: 99)), DiagLevel.info);
      expect(diagEventCategory(rec(code: 99)), DiagEventCategory.other);
    });

    test('categories match the firmware code table', () {
      expect(diagEventCategory(rec(code: 7)), DiagEventCategory.storage);
      expect(diagEventCategory(rec(code: 4)), DiagEventCategory.markers);
      expect(diagEventCategory(rec(code: 13)), DiagEventCategory.ble);
      expect(diagEventCategory(rec(code: 16)), DiagEventCategory.mic);
    });

    test('diagWorst reports the worst member, and ok when empty', () {
      expect(diagWorst(const []), DiagLevel.ok);
      expect(diagWorst(const [DiagLevel.info, DiagLevel.warn, DiagLevel.info]), DiagLevel.warn);
      expect(diagWorst(const [DiagLevel.warn, DiagLevel.bad]), DiagLevel.bad);
    });
  });

  group('DiagEventRow', () {
    testWidgets('shows a wall clock when the uptime could be anchored', (tester) async {
      await tester.pumpWidget(host(DiagEventRow(
        record: rec(code: 7),
        uptimeLabel: '@1s',
        wallClock: DateTime(2026, 1, 1, 9, 4, 5),
      )));
      expect(find.textContaining('09:04:05'), findsOneWidget);
    });

    testWidgets('falls back to uptime alone rather than inventing a time', (tester) async {
      await tester.pumpWidget(host(DiagEventRow(record: rec(code: 7), uptimeLabel: '@1s')));
      expect(find.text('@1s'), findsOneWidget);
    });
  });

  group('DiagGaugeRow', () {
    testWidgets('renders no bar when the firmware reported nothing', (tester) async {
      await tester.pumpWidget(host(const DiagGaugeRow(
        label: 'SD worker stack',
        used: 0,
        total: 12288,
        valueLabel: '—',
      )));
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('a zero total cannot divide by zero', (tester) async {
      await tester.pumpWidget(host(const DiagGaugeRow(
        label: 'SD queue peak',
        used: 5,
        total: 0,
        valueLabel: '5 / 0',
      )));
      final bar = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
      expect(bar.value, 0.0);
    });

    testWidgets('a used value beyond total clamps instead of overflowing the bar', (tester) async {
      await tester.pumpWidget(host(const DiagGaugeRow(
        label: 'SD queue peak',
        used: 400,
        total: 120,
        valueLabel: '400 / 120',
      )));
      final bar = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
      expect(bar.value, 1.0);
    });
  });
}
