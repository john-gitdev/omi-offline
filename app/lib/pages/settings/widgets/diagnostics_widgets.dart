import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/services/devices/diag_log_record.dart';

/// Severity scale for every reading on the Diagnostics card.
///
/// The card previously painted with the page's amber accent, which also fills the
/// app-bar title and the Share Logs button — so amber simultaneously meant "brand",
/// "primary action" and "something is wrong". Here each level has exactly one
/// meaning: [ok] is an explicit all-clear, [info] is a plain value carrying no
/// verdict, [warn] is worth a look, [bad] is a fault. Nothing else on the card is
/// allowed to use these colours decoratively.
enum DiagLevel { ok, info, warn, bad }

extension DiagLevelStyle on DiagLevel {
  Color get color {
    switch (this) {
      case DiagLevel.ok:
        return const Color(0xFF4ADE80);
      case DiagLevel.info:
        return Colors.white;
      case DiagLevel.warn:
        return Colors.amber;
      case DiagLevel.bad:
        return const Color(0xFFFF5C5C);
    }
  }

  IconData get icon {
    switch (this) {
      case DiagLevel.ok:
        return FontAwesomeIcons.circleCheck;
      case DiagLevel.info:
        return FontAwesomeIcons.circleInfo;
      case DiagLevel.warn:
        return FontAwesomeIcons.triangleExclamation;
      case DiagLevel.bad:
        return FontAwesomeIcons.circleExclamation;
    }
  }

  /// Ordering helper so a mixed set of readings can report its worst member.
  int get rank => index;
}

/// Worst level in [levels], or [DiagLevel.ok] when empty.
DiagLevel diagWorst(Iterable<DiagLevel> levels) {
  var worst = DiagLevel.ok;
  for (final l in levels) {
    if (l.rank > worst.rank) worst = l;
  }
  return worst;
}

/// Card shell shared by every state of the Diagnostics card (loading, waiting for
/// a device, populated) so the page doesn't reflow by hundreds of pixels the
/// moment counters arrive.
class DiagCard extends StatelessWidget {
  const DiagCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1C),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2C2C2E)),
      ),
      child: child,
    );
  }
}

/// Small status pill — used for the live/stale freshness indicator and the
/// baseline/lifetime selector.
class DiagPill extends StatelessWidget {
  const DiagPill({super.key, required this.text, this.level = DiagLevel.info, this.selected, this.onTap});

  final String text;
  final DiagLevel level;

  /// When non-null the pill renders as a selectable segment rather than a status.
  final bool? selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isSegment = selected != null;
    final on = selected ?? false;
    final fg = isSegment ? (on ? Colors.white : Colors.white38) : level.color;
    final bg = isSegment
        ? (on ? Colors.white.withValues(alpha: 0.12) : Colors.transparent)
        : level.color.withValues(alpha: 0.12);
    return GestureDetector(
      onTap: onTap,
      // Tappable pills (the baseline selector, the event filters) get a roomier box
      // than the read-only status pills — at the status size they were a ~20 px
      // target, which is a miss more often than a hit.
      child: Container(
        padding: onTap == null
            ? const EdgeInsets.symmetric(horizontal: 8, vertical: 3)
            : const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: isSegment && !on ? const Color(0xFF2C2C2E) : fg.withValues(alpha: 0.35)),
        ),
        child: Text(text, style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

/// The card's headline verdict. Replaces "scan twenty rows and decide for
/// yourself" with a single answer, and carries the two facts that are always
/// worth showing even when everything is clear: device uptime and data freshness.
class DiagStatusBanner extends StatelessWidget {
  const DiagStatusBanner({
    super.key,
    required this.level,
    required this.headline,
    this.detail,
    this.freshness,
    this.freshnessLevel = DiagLevel.info,
  });

  final DiagLevel level;
  final String headline;
  final String? detail;
  final String? freshness;
  final DiagLevel freshnessLevel;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: FaIcon(level.icon, size: 14, color: level.color),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(headline,
                  style: TextStyle(color: level.color, fontSize: 14, fontWeight: FontWeight.w700, height: 1.2)),
              if (detail != null && detail!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(detail!, style: const TextStyle(color: Colors.white54, fontSize: 11, height: 1.3)),
                ),
            ],
          ),
        ),
        if (freshness != null) ...[
          const SizedBox(width: 8),
          DiagPill(text: freshness!, level: freshnessLevel),
        ],
      ],
    );
  }
}

/// A titled group of readings that collapses to a one-line summary while
/// everything in it is clear. A healthy card is a handful of summaries instead of
/// twenty rows of zeroes.
class DiagGroup extends StatefulWidget {
  const DiagGroup({
    super.key,
    required this.title,
    required this.rows,
    this.allClear = false,
    this.clearSummary = 'all clear',
    this.alertSummary,
    this.trailing,
  });

  final String title;
  final List<Widget> rows;

  /// True when nothing in this group needs attention — drives the collapsed state.
  final bool allClear;

  /// Shown on the header while collapsed AND [allClear]. Carries the group's one
  /// useful still-healthy reading (e.g. queue headroom) so collapsing loses nothing.
  final String clearSummary;

  /// Shown on the header while collapsed and NOT [allClear]. Required for honesty:
  /// a group can be collapsed by hand while it holds a live fault, and rendering
  /// [clearSummary] there would put "no drops" above three block drops.
  final String? alertSummary;

  /// Optional controls pinned to the expanded group's header row.
  final Widget? trailing;

  @override
  State<DiagGroup> createState() => _DiagGroupState();
}

class _DiagGroupState extends State<DiagGroup> {
  late bool _expanded = !widget.allClear;

  @override
  void didUpdateWidget(DiagGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A group that starts reporting something pops open by itself — the user
    // shouldn't have to hunt for the counter that just moved. Going quiet again
    // deliberately does NOT re-collapse it: rows vanishing mid-read is worse than
    // a stale expansion, and the user can always fold it back.
    if (oldWidget.allClear && !widget.allClear && !_expanded) {
      _expanded = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                FaIcon(_expanded ? FontAwesomeIcons.chevronDown : FontAwesomeIcons.chevronRight,
                    size: 9, color: Colors.white38),
                const SizedBox(width: 8),
                Text(
                  widget.title.toUpperCase(),
                  style: const TextStyle(
                      color: Colors.white38, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.8),
                ),
                const SizedBox(width: 12),
                // Expanded rather than Spacer + Flexible: those split the free space
                // evenly, so a long summary ellipsized at half the row while the rest
                // sat empty.
                Expanded(
                  child: _expanded
                      ? const SizedBox.shrink()
                      : Text(
                          widget.allClear ? widget.clearSummary : (widget.alertSummary ?? 'needs attention'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: widget.allClear ? DiagLevel.ok.color.withValues(alpha: 0.8) : DiagLevel.warn.color,
                            fontSize: 11,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
        if (_expanded) ...[
          if (widget.trailing != null) Padding(padding: const EdgeInsets.only(bottom: 6), child: widget.trailing!),
          ...widget.rows,
          const SizedBox(height: 4),
        ],
      ],
    );
  }
}

/// One label/value reading.
class DiagStatRow extends StatelessWidget {
  const DiagStatRow(this.label, this.value, {super.key, this.level = DiagLevel.info});

  final String label;
  final String value;
  final DiagLevel level;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12))),
          const SizedBox(width: 12),
          Text(
            value,
            style: TextStyle(
              color: level.color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// A used-of-total reading drawn as a bar. Fill proportion reads instantly where
/// "10.2 / 12.0 KB" needed arithmetic.
class DiagGaugeRow extends StatelessWidget {
  const DiagGaugeRow({
    super.key,
    required this.label,
    required this.used,
    required this.total,
    required this.valueLabel,
    this.level = DiagLevel.info,
  });

  final String label;
  final int used;
  final int total;
  final String valueLabel;
  final DiagLevel level;

  @override
  Widget build(BuildContext context) {
    final fraction = total <= 0 ? 0.0 : (used / total).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12))),
              const SizedBox(width: 12),
              Text(
                valueLabel,
                style: TextStyle(
                  color: level.color,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          if (used > 0) ...[
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 3,
                backgroundColor: const Color(0xFF2C2C2E),
                valueColor: AlwaysStoppedAnimation<Color>(level == DiagLevel.info ? Colors.white24 : level.color),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Coarse grouping for the on-device event log, so a bench session can filter to
/// the subsystem under test instead of scrolling an undifferentiated list.
enum DiagEventCategory { storage, markers, ble, mic, other }

extension DiagEventCategoryLabel on DiagEventCategory {
  String get label {
    switch (this) {
      case DiagEventCategory.storage:
        return 'Storage';
      case DiagEventCategory.markers:
        return 'Markers';
      case DiagEventCategory.ble:
        return 'BLE';
      case DiagEventCategory.mic:
        return 'Mic';
      case DiagEventCategory.other:
        return 'Other';
    }
  }
}

/// Maps a firmware event code to its category. Mirrors `diag_event_code_t`;
/// unknown codes (newer firmware) fall into [DiagEventCategory.other] rather than
/// being hidden.
DiagEventCategory diagEventCategory(DiagLogRecord r) {
  switch (r.code) {
    case 1: // empty_bin_rotation
    case 7: // sd_block_drop
    case 8: // codec_drop
    case 9: // write_blocked
    case 10: // ring_io_error
    case 11: // backend_mount
      return DiagEventCategory.storage;
    case 2: // marker_write_drop
    case 3: // marker_pause_gate_save
    case 4: // priority_record_start
    case 5: // priority_record_stop
    case 6: // session_end_marker_emit
      return DiagEventCategory.markers;
    case 12: // bond_state
    case 13: // adv_start_fail
    case 14: // adv_watchdog_rescue
    case 15: // adv_stop_fail
      return DiagEventCategory.ble;
    case 16: // vad_level
    case 17: // mic_power_cycle
      return DiagEventCategory.mic;
    default:
      return DiagEventCategory.other;
  }
}

/// Severity of a single event. Several codes are only a fault in one of their arg
/// variants — a `vad_level` with a zero peak is a wedged mic while any other peak
/// is routine, and a boot `bond_state` reporting zero keys is the unpaired state
/// behind the reconnect-forever outage. Those are graded on the args, not the code.
DiagLevel diagEventLevel(DiagLogRecord r) {
  switch (r.code) {
    case 2: // marker_write_drop — a lost inline marker
    case 7: // sd_block_drop
    case 8: // codec_drop
    case 10: // ring_io_error
    case 13: // adv_start_fail
    case 15: // adv_stop_fail
      return DiagLevel.bad;
    case 1: // empty_bin_rotation
    case 9: // write_blocked
    case 14: // adv_watchdog_rescue
      return DiagLevel.warn;
    case 12: // bond_state — arg0 cause, arg1 keys held after
      if (r.arg0 == 0) return r.arg1 == 0 ? DiagLevel.bad : DiagLevel.info;
      // A wipe that left keys behind did not take.
      return r.arg1 == 0 ? DiagLevel.info : DiagLevel.bad;
    case 16: // vad_level — a zero peak is digital silence, which a real room never produces
      return r.arg0 == 0 ? DiagLevel.bad : DiagLevel.info;
    case 17: // mic_power_cycle — arg0 == 1 means the rail really was cycled
      return r.arg0 == 1 ? DiagLevel.info : DiagLevel.warn;
    default:
      return DiagLevel.info;
  }
}

/// One event-log entry: severity dot, label, wall clock (when the device uptime
/// could be anchored to phone time), device uptime, and the decoded description.
class DiagEventRow extends StatelessWidget {
  const DiagEventRow({super.key, required this.record, required this.uptimeLabel, this.wallClock});

  final DiagLogRecord record;
  final String uptimeLabel;
  final DateTime? wallClock;

  @override
  Widget build(BuildContext context) {
    final level = diagEventLevel(record);
    final clock = wallClock;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: level == DiagLevel.info ? Colors.white24 : level.color,
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        record.label,
                        style: TextStyle(
                          color: level == DiagLevel.info ? Colors.white : level.color,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      clock == null ? uptimeLabel : '${_hhmmss(clock)} · $uptimeLabel',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 10,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                Text(record.description, style: const TextStyle(color: Colors.white54, fontSize: 11, height: 1.3)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _hhmmss(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
}

/// Section heading for the plain (non-collapsing) parts of the page.
class DebugSectionHeader extends StatelessWidget {
  const DebugSectionHeader(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Text(
            title.toUpperCase(),
            style:
                const TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.8),
          ),
          const SizedBox(width: 10),
          const Expanded(child: Divider(color: Color(0xFF2C2C2E), height: 1)),
        ],
      ),
    );
  }
}
