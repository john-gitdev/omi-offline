import 'dart:io';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/pages/recordings/recordings_types.dart';
import 'package:omi/pages/recordings/recordings_controller.dart';
import 'package:omi/utils/other/time_utils.dart';

class UploadIconButton extends StatelessWidget {
  final Conversation? conversation;
  final bool anyIntegrationEnabled;
  final bool isUploading;
  final UploadStatus uploadStatus;

  /// Number of integrations that still need attention for this recording
  /// (pending or failed); a count badge is overlaid on the icon when >= 2 so it
  /// reflects how many remain to be addressed, not the total configured. The
  /// badge color follows [uploadStatus]. The icon is a non-interactive indicator —
  /// taps fall through to the row, which opens the player where the
  /// per-integration detail and actions live.
  final int integrationCount;

  const UploadIconButton({
    super.key,
    required this.conversation,
    required this.anyIntegrationEnabled,
    required this.isUploading,
    required this.uploadStatus,
    this.integrationCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    if (!anyIntegrationEnabled) return const SizedBox.shrink();

    if (conversation == null) {
      return _indicator(Icons.cloud_off, Colors.grey.shade600, 'Upload key unavailable');
    }
    if (isUploading) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 6),
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.deepPurpleAccent),
        ),
      );
    }

    final (IconData icon, Color color, String tooltip) = switch (uploadStatus) {
      UploadStatus.all => (Icons.cloud_done, Colors.green, 'Uploaded to all integrations'),
      UploadStatus.partial => (Icons.cloud_upload, Colors.amber, 'Some integrations pending'),
      UploadStatus.failed => (Icons.error_outline, Colors.orange, 'Upload failed'),
      UploadStatus.unavailable => (Icons.cloud_off, Colors.grey.shade600, 'No uploadable file for this recording'),
      UploadStatus.none => (Icons.cloud_upload, Colors.redAccent, 'Not uploaded'),
    };
    return _indicator(icon, color, tooltip);
  }

  Widget _indicator(IconData icon, Color color, String tooltip) {
    final showBadge = integrationCount >= 2;
    final iconWidget = showBadge
        ? Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(icon, color: color, size: 18),
              Positioned(
                right: -5,
                top: -4,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 3.5, vertical: 1),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(color: const Color(0xFF1C1C1E), width: 1),
                  ),
                  child: Text(
                    '$integrationCount',
                    style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold, height: 1.0),
                  ),
                ),
              ),
            ],
          )
        : Icon(icon, color: color, size: 18);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Tooltip(message: tooltip, child: iconWidget),
    );
  }
}

class MarkerSubEntry extends StatelessWidget {
  final MarkerConversation mc;
  final void Function()? onTap;
  final void Function()? onLongPress;

  const MarkerSubEntry({super.key, required this.mc, this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    // Priority Recording markers render red as "Priority Recording", gated on the
    // showHighPriorityMarker visibility pref (main isolate read — fine here).
    if (mc.isHighPriority && !SharedPreferencesUtil().showHighPriorityMarker) {
      return const SizedBox.shrink();
    }
    final markerColor = mc.isPending
        ? Colors.grey.shade600
        : mc.isHighPriority
            ? Colors.red
            : Colors.amber;
    final label = mc.isHighPriority ? 'Priority Recording at ${mc.markerTimeLabel}' : 'Marker at ${mc.markerTimeLabel}';
    return InkWell(
      onTap: mc.isPending ? null : onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.only(left: 16, top: 6, bottom: 6, right: 4),
        child: Row(
          children: [
            FaIcon(
              FontAwesomeIcons.solidBookmark,
              color: markerColor,
              size: 11,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                mc.isPending ? '$label (no audio)' : label,
                style: TextStyle(
                  color: mc.isPending ? Colors.grey.shade600 : Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
            if (!mc.isPending && mc.userSaved) ...[
              const FaIcon(FontAwesomeIcons.circleCheck, color: Colors.green, size: 12),
              const SizedBox(width: 6),
            ],
            if (!mc.isPending) FaIcon(FontAwesomeIcons.chevronRight, color: Colors.grey.shade700, size: 12),
          ],
        ),
      ),
    );
  }
}

/// True when [d] abuts an open draft and is still inside the window where the
/// draft-finalize/stitch pass could fold it back into that conversation. Such a
/// ghost is a not-yet-settled verdict, so surfacing it beneath the "Conversation
/// in progress" banner reads as a contradiction.
///
/// Mirrors RecordingsManager._stitchDraftRecordings' fold test exactly:
///  - it skips (`if (gap < 0) continue`) — and therefore never folds — any event
///    that starts before the draft's decoded end, so a ghost with a negative gap
///    must stay visible (it will remain a standalone row), and
///  - it folds a ghost only while the gap to reach it PLUS the ghost's own
///    wall-clock span stays under vadSplitSeconds; at/beyond that boundary the
///    pass finalizes the draft instead, leaving the ghost a real standalone row.
///
/// [drafts] should be every open draft in view (globally, across date folders),
/// because the stitch pass folds across midnight — a ghost just after midnight
/// can still belong to a draft in the previous day's batch.
///
/// [recordings] are the finalized recordings that could sit between a draft and
/// the ghost. The stitch pass stops folding at the first real recording after a
/// draft (it stitches that recording in, then re-scans), so a ghost separated
/// from the draft by a finalized recording is not the draft's trailing
/// neighbour and must stay visible — otherwise a genuine standalone row would
/// vanish. (A recording abutting the draft is absorbed into it, and the ghost
/// re-tests against the now-extended draft on the next reload.)
///
/// Bin-less ghosts (muted stretches) are never folded, so they are always shown.
bool _foldPendingTrailingGhost(
  DiscardRecord d,
  List<Conversation> drafts,
  List<Conversation> recordings,
  Duration foldWindow,
) {
  if (d.relativeBins.isEmpty) return false;
  for (final draft in drafts) {
    final gap = d.startTime.difference(draft.endTime);
    if (gap.isNegative) continue;
    if (gap + d.duration >= foldWindow) continue;
    final separatedByRecording = recordings.any(
      (r) => r.startTime.isAfter(draft.endTime) && r.startTime.isBefore(d.startTime),
    );
    if (separatedByRecording) continue;
    return true;
  }
  return false;
}

/// Applies the active filter to a batch, returning the recordings and discards
/// actually visible in the current tab. Shared by [BatchCard] (to render) and
/// the page's selection bar (so "Select All" sees exactly the rows on screen).
///
/// [foldWindow] (default off) hides a discard that trails an open draft and is
/// still a fold candidate — see [_foldPendingTrailingGhost]. Applied only in the
/// default `visible` tab; the Hidden/All tabs always surface every ghost so a
/// still-pending one is never unreachable. The hidden data is untouched: it
/// reappears on the next reload once the draft resolves (folded ⇒ the record is
/// retired; finalized ⇒ the draft is gone and the ghost stands on its own).
///
/// [openDrafts] is the set of open drafts to test against; pass every draft in
/// view (across all batches) so a cross-midnight ghost is matched against a draft
/// in the previous day's batch, mirroring the stitch pass's global lookup. When
/// null it falls back to this batch's own drafts (same-day only).
({List<Conversation> recordings, List<DiscardRecord> discards}) filterBatchRows(
  Batch batch,
  RecordingFilterMode filterMode,
  int minFilterSeconds, {
  Duration foldWindow = Duration.zero,
  List<Conversation>? openDrafts,
}) {
  // Enforce the contract: enabling suppression (foldWindow > 0) requires the
  // global open-draft set, or cross-midnight ghosts silently fall back to
  // same-day-only matching. Both production callers pass it; this traps a future
  // caller that forgets. (A caller that deliberately wants same-day may pass
  // batch.draftRecordings explicitly.)
  assert(
    foldWindow == Duration.zero || openDrafts != null,
    'filterBatchRows: pass the global openDrafts set when foldWindow > 0.',
  );
  final conversations = [...batch.finalizedRecordings]..sort((a, b) => b.startTime.compareTo(a.startTime));
  final recordings = minFilterSeconds > 0
      ? switch (filterMode) {
          RecordingFilterMode.visible => conversations.where((c) => c.duration.inSeconds >= minFilterSeconds).toList(),
          RecordingFilterMode.hidden => conversations.where((c) => c.duration.inSeconds < minFilterSeconds).toList(),
          RecordingFilterMode.all => conversations,
        }
      : conversations;
  var discards = minFilterSeconds > 0
      ? switch (filterMode) {
          RecordingFilterMode.visible =>
            batch.discards.where((d) => d.audioDuration.inSeconds >= minFilterSeconds).toList(),
          RecordingFilterMode.hidden =>
            batch.discards.where((d) => d.audioDuration.inSeconds < minFilterSeconds).toList(),
          RecordingFilterMode.all => [...batch.discards],
        }
      : [...batch.discards];
  final drafts = openDrafts ?? batch.draftRecordings;
  if (foldWindow > Duration.zero && filterMode == RecordingFilterMode.visible && drafts.isNotEmpty) {
    discards = discards
        .where((d) => !_foldPendingTrailingGhost(d, drafts, batch.finalizedRecordings, foldWindow))
        .toList();
  }
  return (recordings: recordings, discards: discards);
}

/// Leading check-circle shown on selectable rows while in selection mode.
Widget _selectionCheck(bool selected) => Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Icon(
        selected ? Icons.check_circle : Icons.circle_outlined,
        color: selected ? Colors.deepPurpleAccent : Colors.grey.shade600,
        size: 22,
      ),
    );

class ConversationTile extends StatelessWidget {
  final Conversation conversation;
  final List<MarkerConversation> markers;
  final Widget uploadIcon;
  final void Function(MarkerConversation) onMarkerTap;
  final void Function(Conversation) onConversationTap;
  final void Function(MarkerConversation) onDeleteMarkerConversation;

  /// True when this card is in selection mode (of any type). When the active
  /// type is *not* recording, recording rows render dimmed and inert.
  final bool selectionActive;

  /// True when the active selection type is recording, so this row is pickable.
  final bool selectable;
  final bool selected;

  /// Long-press in normal mode → start a recording-scoped selection here.
  final VoidCallback onEnterSelection;

  /// Tap/long-press while selecting → toggle this row in/out of the set.
  final VoidCallback onToggleSelection;

  const ConversationTile({
    super.key,
    required this.conversation,
    required this.markers,
    required this.uploadIcon,
    required this.onMarkerTap,
    required this.onConversationTap,
    required this.onDeleteMarkerConversation,
    this.selectionActive = false,
    this.selectable = false,
    this.selected = false,
    required this.onEnterSelection,
    required this.onToggleSelection,
  });

  bool _isAdjustmentMode() {
    if (conversation.relativeBins.isEmpty) return false;
    try {
      final docsPath = conversation.file.parent.parent.parent.path;
      for (final rel in conversation.relativeBins) {
        if (!File('$docsPath/adjustment_mode_segments/$rel').existsSync()) {
          return false;
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // High-priority ("Priority Recording") markers are folded into the recording row
    // itself as a leading red badge (below) rather than rendered as their own
    // sub-row, so exclude them from the marker sub-entries. The badge and the
    // exclusion both honor the showHighPriorityMarker visibility pref.
    final showHighPriority = SharedPreferencesUtil().showHighPriorityMarker;
    final isHighPriorityRec = showHighPriority && markers.any((m) => m.isHighPriority);
    final sortedMarkers = markers.where((m) => !m.isHighPriority).toList()
      ..sort((a, b) => a.markerTime.compareTo(b.markerTime));
    final isPassthrough = conversation.passthrough;
    final subtitle =
        isPassthrough ? conversation.durationLabel : '${conversation.durationLabel}  ·  ${conversation.sizeLabel}';
    final isAdj = _isAdjustmentMode();
    final dimmed = selectionActive && !selectable;
    Widget tile = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: selectionActive
              ? (selectable ? onToggleSelection : null)
              : (isPassthrough ? null : () => onConversationTap(conversation)),
          onLongPress: selectionActive ? (selectable ? onToggleSelection : null) : onEnterSelection,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            child: Row(
              children: [
                if (selectionActive && selectable) _selectionCheck(selected),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (isHighPriorityRec) ...[
                            const Tooltip(
                              message: 'Priority Recording',
                              child: FaIcon(FontAwesomeIcons.solidBookmark, color: Colors.red, size: 13),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Text(
                            isAdj ? '${conversation.timeRangeLabel} | ADJ' : conversation.timeRangeLabel,
                            style: TextStyle(
                              color: isPassthrough ? Colors.grey.shade400 : Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (conversation.forceSynced) ...[
                            const SizedBox(width: 6),
                            const Icon(Icons.bolt, color: Colors.amber, size: 16),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (!selectionActive) ...[
                  if (isPassthrough) ...[
                    Icon(Icons.send_rounded, size: 16, color: Colors.deepPurpleAccent.withValues(alpha: 0.8)),
                    const SizedBox(width: 6),
                  ] else ...[
                    uploadIcon,
                    FaIcon(FontAwesomeIcons.chevronRight, color: Colors.grey.shade600, size: 14),
                  ],
                ],
              ],
            ),
          ),
        ),
        if (!selectionActive && !isPassthrough)
          ...sortedMarkers.map((mc) =>
              MarkerSubEntry(mc: mc, onTap: () => onMarkerTap(mc), onLongPress: () => onDeleteMarkerConversation(mc))),
      ],
    );
    if (dimmed) tile = Opacity(opacity: 0.35, child: IgnorePointer(child: tile));
    return tile;
  }
}

class _Row {
  final Conversation? recording;
  final DiscardRecord? discard;
  _Row.recording(this.recording) : discard = null;
  _Row.ghost(this.discard) : recording = null;
  DateTime get startTime => recording?.startTime ?? discard!.startTime;
}

class GhostRow extends StatelessWidget {
  final DiscardRecord discard;
  final VoidCallback onTap;

  /// True when this card is in selection mode (of any type). When the active
  /// type is *not* ghost, discard rows render dimmed and inert.
  final bool selectionActive;

  /// True when the active selection type is ghost, so this row is pickable.
  final bool selectable;
  final bool selected;

  /// Long-press in normal mode → start a ghost-scoped selection here.
  final VoidCallback onEnterSelection;
  final VoidCallback onToggleSelection;

  const GhostRow({
    super.key,
    required this.discard,
    required this.onTap,
    this.selectionActive = false,
    this.selectable = false,
    this.selected = false,
    required this.onEnterSelection,
    required this.onToggleSelection,
  });

  static String _durationLabel(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h > 0) return '${h}h ${m}m';
    if (d.inMinutes > 0) return '${m}m';
    return '${d.inSeconds}s';
  }

  @override
  Widget build(BuildContext context) {
    final timeRange = '${fmtHourMin(discard.startTime)}–${fmtHourMin(discard.endTime)}';
    // Show the recorded-audio length (what Recover yields), not the wall-clock
    // span, so a ghost reads as the length of the clip it produces.
    final dur = _durationLabel(discard.audioDuration);
    final subLabel = discard.isMuted
        ? 'Muted'
        : discard.isNoise
            ? 'below minimum speech'
            : discard.reason == 'silence_only'
                ? 'no speech detected'
                : 'below minimum length';
    final dimmed = selectionActive && !selectable;
    // Ghost rows are grey by default; once they become selectable, brighten
    // them so it's clear they're now interactive picks.
    final active = selectionActive && selectable;
    Widget row = InkWell(
      onTap: selectionActive ? (selectable ? onToggleSelection : null) : onTap,
      onLongPress: selectionActive ? (selectable ? onToggleSelection : null) : onEnterSelection,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            if (selectionActive && selectable) _selectionCheck(selected),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    timeRange,
                    style: TextStyle(
                      color: active ? Colors.white : Colors.grey.shade600,
                      fontSize: 15,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '$subLabel  ·  $dur',
                    style: TextStyle(color: active ? Colors.grey.shade400 : Colors.grey.shade700, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (!selectionActive) FaIcon(FontAwesomeIcons.chevronRight, color: Colors.grey.shade800, size: 12),
          ],
        ),
      ),
    );
    if (dimmed) row = Opacity(opacity: 0.35, child: IgnorePointer(child: row));
    return row;
  }
}

Future<void> showDiscardSheet(
  BuildContext context,
  DiscardRecord d, {
  required Future<void> Function(DiscardRecord) onRecover,
  required Future<void> Function(DiscardRecord) onDeleteNow,
}) async {
  final use24 = SharedPreferencesUtil().use24HourTime;
  String two(int n) => n.toString().padLeft(2, '0');
  String fmtTime(DateTime t) {
    if (use24) return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    final h12 = t.hour == 0 ? 12 : (t.hour > 12 ? t.hour - 12 : t.hour);
    return '$h12:${two(t.minute)}:${two(t.second)} ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  String fmtAbs(DateTime t) => '${t.year}-${two(t.month)}-${two(t.day)} ${fmtHourMin(t)}';
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF1C1C1E),
    showDragHandle: true,
    builder: (sheetCtx) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${fmtTime(d.startTime)} – ${fmtTime(d.endTime)}  ·  ${GhostRow._durationLabel(d.audioDuration)}',
            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            // Muted stretches have no recorded audio to retain or recover.
            d.isMuted ? 'Muted — no audio was recorded' : 'Raw audio retained until ${fmtAbs(d.expiresAt.toLocal())}',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
          ),
          const SizedBox(height: 20),
          // Muted rows are delete-only — there's nothing to recover.
          if (!d.isMuted) ...[
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.deepPurpleAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                icon: const FaIcon(FontAwesomeIcons.rotateLeft, size: 14),
                label: const Text('Recover to Recording'),
                onPressed: () async {
                  Navigator.of(sheetCtx).pop();
                  await onRecover(d);
                },
              ),
            ),
            const SizedBox(height: 10),
          ],
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red.shade300,
                side: BorderSide(color: Colors.red.shade700.withValues(alpha: 0.5)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              icon: const FaIcon(FontAwesomeIcons.trashCan, size: 13),
              label: Text(d.isMuted ? 'Delete' : 'Delete now'),
              onPressed: () async {
                Navigator.of(sheetCtx).pop();
                await onDeleteNow(d);
              },
            ),
          ),
        ],
      ),
    ),
  );
}

/// One labelled row inside the day-actions overflow menu.
class _DayMenuRow extends StatelessWidget {
  final Widget icon;
  final String label;
  final Color color;

  const _DayMenuRow({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(width: 18, height: 18, child: Center(child: icon)),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: color, fontSize: 14)),
      ],
    );
  }
}

class BatchCard extends StatelessWidget {
  final Batch batch;
  /// Every open draft in view (across all batches), so a cross-midnight trailing
  /// ghost in this batch can be matched against a draft in an adjacent day's
  /// batch — mirroring the stitch pass's global fold. Null ⇒ same-day only.
  final List<Conversation>? openDrafts;
  final Map<String, List<MarkerConversation>> markerMap;
  final bool anyIntegrationEnabled;
  final RecordingFilterMode filterMode;
  final UploadStatus Function(Conversation) uploadStatus;
  final int Function(Conversation) uploadCount;
  final bool Function(String) isUploading;
  final void Function(Conversation) onConversationTap;
  final void Function(MarkerConversation) onMarkerTap;
  final void Function(List<Conversation>) onExportAll;
  final void Function(List<Conversation>) onUploadAll;
  final void Function(List<Conversation>, List<DiscardRecord>) onDeleteDay;
  final void Function(List<DiscardRecord>) onDeleteAllDiscards;
  final void Function(MarkerConversation) onDeleteMarkerConversation;
  final Future<void> Function(DiscardRecord) onRecoverDiscard;
  final Future<void> Function(DiscardRecord) onDeleteDiscard;

  /// Non-null only when this card is the active selection target; its value is
  /// the type being selected. Null elsewhere (normal mode / other days).
  final RecordingRowType? activeSelectionType;

  /// IDs currently selected — recording paths or discard ids depending on type.
  final Set<String> selectedIds;

  /// Long-press on a row → enter selection scoped to (this day, that type, id).
  final void Function(RecordingRowType, String) onEnterSelection;
  final void Function(String) onToggleSelection;

  const BatchCard({
    super.key,
    required this.batch,
    this.openDrafts,
    required this.markerMap,
    required this.anyIntegrationEnabled,
    required this.filterMode,
    required this.uploadStatus,
    required this.uploadCount,
    required this.isUploading,
    required this.onConversationTap,
    required this.onMarkerTap,
    required this.onExportAll,
    required this.onUploadAll,
    required this.onDeleteDay,
    required this.onDeleteAllDiscards,
    required this.onDeleteMarkerConversation,
    required this.onRecoverDiscard,
    required this.onDeleteDiscard,
    this.activeSelectionType,
    this.selectedIds = const {},
    required this.onEnterSelection,
    required this.onToggleSelection,
  });

  @override
  Widget build(BuildContext context) {
    final minFilterSeconds = SharedPreferencesUtil().filterMinDurationSeconds;
    // Shared with the page's selection bar so "Select All" sees exactly these
    // rows. Ghosts get the same filter so short discards land in the hidden tab
    // alongside short recordings; with no minimum set, all discards show.
    // foldWindow hides a trailing ghost still eligible to be folded into an open
    // draft (mirrors the finalize pass's vadSplitSeconds threshold); openDrafts
    // is the global draft set so cross-midnight ghosts are matched too.
    final rows = filterBatchRows(
      batch,
      filterMode,
      minFilterSeconds,
      foldWindow: Duration(seconds: SharedPreferencesUtil().vadSplitSeconds),
      openDrafts: openDrafts,
    );
    final filtered = rows.recordings;
    final discards = rows.discards;
    if (filtered.isEmpty && discards.isEmpty) {
      return const SizedBox.shrink();
    }

    final inSelection = activeSelectionType != null;
    final selectingRecordings = activeSelectionType == RecordingRowType.recording;
    final selectingGhosts = activeSelectionType == RecordingRowType.ghost;

    // Time-sorted (newest first) merge of recordings and ghosts.
    final items = <_Row>[
      for (final c in filtered) _Row.recording(c),
      for (final d in discards) _Row.ghost(d),
    ]..sort((a, b) => b.startTime.compareTo(a.startTime));

    return Card(
      color: const Color(0xFF1C1C1E),
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      batch.dateString,
                      style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                  // Day actions collapse into one overflow menu on the header, so
                  // the common whole-day shortcuts are reachable without scrolling
                  // and stay out of the way of the per-row multi-select path.
                  if (!inSelection)
                    PopupMenuButton<String>(
                      tooltip: 'Day actions',
                      color: const Color(0xFF2C2C2E),
                      // `child:` (not `icon:`) avoids IconButton's 48px min box,
                      // so the glyph sits near the card's right edge — matching
                      // the date's 16px inset on the left. Right padding 0 keeps
                      // it close to the edge; left/vertical padding hold the tap
                      // target.
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 0, 12),
                        child: FaIcon(FontAwesomeIcons.ellipsisVertical, size: 16, color: Colors.grey.shade400),
                      ),
                      onSelected: (value) {
                        switch (value) {
                          case 'export':
                            onExportAll(filtered);
                          case 'upload_all':
                            onUploadAll(filtered);
                          case 'discards':
                            onDeleteAllDiscards(discards);
                          case 'day':
                            onDeleteDay(filtered, discards);
                        }
                      },
                      itemBuilder: (context) => [
                        PopupMenuItem(
                          key: Key('export_all_${batch.dateString}'),
                          value: 'export',
                          child: _DayMenuRow(
                            icon: FaIcon(FontAwesomeIcons.shareFromSquare, size: 15, color: Colors.grey.shade300),
                            label: 'Export All',
                            color: Colors.grey.shade300,
                          ),
                        ),
                        if (anyIntegrationEnabled)
                          PopupMenuItem(
                            key: Key('upload_all_${batch.dateString}'),
                            value: 'upload_all',
                            child: _DayMenuRow(
                              icon: Icon(Icons.cloud_upload, size: 16, color: Colors.grey.shade300),
                              label: 'Upload All',
                              color: Colors.grey.shade300,
                            ),
                          ),
                        if (discards.isNotEmpty)
                          PopupMenuItem(
                            key: Key('delete_discards_${batch.dateString}'),
                            value: 'discards',
                            child: _DayMenuRow(
                              icon: SizedBox(
                                width: 18,
                                height: 18,
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    FaIcon(FontAwesomeIcons.ghost, size: 16, color: Colors.orange.shade300),
                                    Positioned(
                                      right: -3,
                                      top: -2,
                                      child: FaIcon(FontAwesomeIcons.xmark, size: 10, color: Colors.red.shade400),
                                    ),
                                  ],
                                ),
                              ),
                              label: 'Delete Discards',
                              color: Colors.orange.shade300,
                            ),
                          ),
                        PopupMenuItem(
                          key: Key('delete_day_${batch.dateString}'),
                          value: 'day',
                          child: _DayMenuRow(
                            icon: FaIcon(FontAwesomeIcons.trashCan, size: 15, color: Colors.red.shade400),
                            label: 'Delete Day',
                            color: Colors.red.shade400,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            ...items.map((r) {
              if (r.discard != null) {
                final d = r.discard!;
                return GhostRow(
                  key: ValueKey('ghost_${d.id}'),
                  discard: d,
                  selectionActive: inSelection,
                  selectable: selectingGhosts,
                  selected: selectedIds.contains(d.id),
                  onEnterSelection: () => onEnterSelection(RecordingRowType.ghost, d.id),
                  onToggleSelection: () => onToggleSelection(d.id),
                  onTap: () => showDiscardSheet(
                    context,
                    d,
                    onRecover: onRecoverDiscard,
                    onDeleteNow: onDeleteDiscard,
                  ),
                );
              }
              final c = r.recording!;
              final fileKey = c.file.path.split('/').last;
              final markers = markerMap[fileKey] ?? [];
              final uploadKey = c.uploadKey;
              return ConversationTile(
                conversation: c,
                markers: markers,
                selectionActive: inSelection,
                selectable: selectingRecordings,
                selected: selectedIds.contains(c.file.path),
                onEnterSelection: () => onEnterSelection(RecordingRowType.recording, c.file.path),
                onToggleSelection: () => onToggleSelection(c.file.path),
                onConversationTap: onConversationTap,
                onDeleteMarkerConversation: onDeleteMarkerConversation,
                uploadIcon: UploadIconButton(
                  conversation: c,
                  anyIntegrationEnabled: anyIntegrationEnabled,
                  isUploading: uploadKey != null && isUploading(uploadKey),
                  uploadStatus: uploadStatus(c),
                  integrationCount: uploadCount(c),
                ),
                onMarkerTap: onMarkerTap,
              );
            }),
          ],
        ),
      ),
    );
  }
}
