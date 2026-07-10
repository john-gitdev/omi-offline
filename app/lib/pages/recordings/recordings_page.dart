import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart' show SharePlus, ShareParams, XFile;
import 'package:omi/providers/device_provider.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/pages/settings/settings_drawer.dart';
import 'package:omi/pages/settings/find_devices_page.dart';
import 'package:omi/pages/settings/device_settings.dart';
import 'package:omi/pages/recordings/marker_conversation_player_page.dart';
import 'package:omi/pages/recordings/passthrough_integration.dart';
import 'package:omi/pages/recordings/recordings_types.dart';
import 'package:omi/pages/recordings/recordings_banners.dart';
import 'package:omi/pages/recordings/sync_process_card.dart';
import 'package:omi/pages/recordings/batch_card.dart';
import 'package:omi/pages/recordings/recording_player_page.dart';
import 'package:omi/pages/recordings/marker_day_card.dart';
import 'package:omi/pages/recordings/recordings_controller.dart';
import 'package:omi/pages/settings/offline_audio_settings_page.dart';
import 'package:omi/widgets/dialog.dart';
import 'package:omi/widgets/battery_status_indicator.dart';

// ─── Page ───────────────────────────────────────────────────────────────────
class RecordingsPage extends StatefulWidget {
  const RecordingsPage({super.key});

  @override
  State<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends State<RecordingsPage> with SingleTickerProviderStateMixin {
  // Back press on the root page minimizes the app (moves the task to back)
  // rather than finishing MainActivity — finishing would tear down the BLE
  // foreground service and drop its persistent notification.
  static const _systemChannel = MethodChannel('com.omi.offline/system');

  final _prefs = SharedPreferencesUtil();
  late final RecordingsController _controller;

  bool _showMarkersOnly = false;
  RecordingFilterMode _filterMode = RecordingFilterMode.visible;

  // ─── Multi-select state ─────────────────────────────────────────────────
  // Selection is scoped to one day (_selDate) and one type (_selType) so a
  // selection never mixes recordings and discards. Null _selDate == off.
  String? _selDate;
  RecordingRowType? _selType;
  final Set<String> _selIds = {};
  bool get _inSelectionMode => _selDate != null;

  // Drives the action bar sliding up from / down to the bottom edge.
  late final AnimationController _selBarAnim;
  late final Animation<double> _selBarCurve;

  // Back-to-top FAB: appears once scrolled ~1.5 viewports down the day list.
  final ScrollController _scrollController = ScrollController();
  bool _showBackToTop = false;

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final show = pos.pixels > pos.viewportDimension * 1.5;
    if (show != _showBackToTop) setState(() => _showBackToTop = show);
  }

  void _enterSelection(String date, RecordingRowType type, String id) {
    setState(() {
      _selDate = date;
      _selType = type;
      _selIds
        ..clear()
        ..add(id);
    });
    _selBarAnim.forward(from: 0);
  }

  void _toggleSelection(String id) {
    setState(() {
      if (!_selIds.remove(id)) _selIds.add(id);
    });
  }

  void _selectAll(Iterable<String> ids) => setState(() => _selIds
    ..clear()
    ..addAll(ids));

  void _selectNone() => setState(_selIds.clear);

  void _exitSelection() {
    if (_selDate == null) return;
    // Slide the bar back down first, then clear state (which re-expands the
    // list) once it's fully off-screen.
    _selBarAnim.reverse().whenComplete(() {
      if (mounted && _selBarAnim.status == AnimationStatus.dismissed) {
        setState(() {
          _selDate = null;
          _selType = null;
          _selIds.clear();
        });
      }
    });
  }

  Batch? _activeBatch(RecordingsController controller) {
    for (final b in controller.batches) {
      if (b.dateString == _selDate) return b;
    }
    return null;
  }

  /// The on-screen recordings/discards for the active selection day, filtered
  /// identically to [BatchCard] so "Select All" matches what's visible.
  ({List<Conversation> recordings, List<DiscardRecord> discards})? _activeRows(RecordingsController controller) {
    final b = _activeBatch(controller);
    if (b == null) return null;
    return filterBatchRows(
      b,
      _filterMode,
      _prefs.filterMinDurationSeconds,
      foldWindow: Duration(seconds: _prefs.vadSplitSeconds),
      openDrafts: controller.batches.expand((batch) => batch.draftRecordings).toList(),
    );
  }

  Future<void> _deleteSelectedRecordings(RecordingsController controller) async {
    final rows = _activeRows(controller);
    if (rows == null) return;
    final sel = rows.recordings.where((r) => _selIds.contains(r.file.path)).toList();
    if (sel.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final n = sel.length;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => getDialog(
        c,
        () => Navigator.of(c).pop(false),
        () => Navigator.of(c).pop(true),
        'Delete ${n == 1 ? 'Recording' : 'Recordings'}',
        'This will permanently delete $n recording${n == 1 ? '' : 's'}. This cannot be undone.',
        confirmText: 'Delete',
      ),
    );
    if (confirm != true) return;
    try {
      await controller.deleteConversations(sel);
      _exitSelection();
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('Deleted $n recording${n == 1 ? '' : 's'}')));
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('Error deleting: $e')));
    }
  }

  Future<void> _deleteSelectedDiscards(RecordingsController controller) async {
    final rows = _activeRows(controller);
    if (rows == null) return;
    final sel = rows.discards.where((d) => _selIds.contains(d.id)).toList();
    if (sel.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final n = sel.length;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => getDialog(
        c,
        () => Navigator.of(c).pop(false),
        () => Navigator.of(c).pop(true),
        'Delete ${n == 1 ? 'Discard' : 'Discards'}',
        'This will permanently delete $n discarded ${n == 1 ? 'segment' : 'segments'}, including their audio. '
            'They can no longer be recovered. This cannot be undone.',
        confirmText: 'Delete',
      ),
    );
    if (confirm != true) return;
    try {
      await controller.deleteDiscards(sel);
      _exitSelection();
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('Deleted $n discard${n == 1 ? '' : 's'}')));
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('Error deleting: $e')));
    }
  }

  Future<void> _recoverSelectedDiscards(RecordingsController controller) async {
    final rows = _activeRows(controller);
    if (rows == null) return;
    final sel = rows.discards.where((d) => _selIds.contains(d.id)).toList();
    if (sel.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    if (controller.isPipelineBusy) {
      messenger.showSnackBar(const SnackBar(content: Text('Finishing sync — try recovering again in a moment.')));
      return;
    }
    final n = sel.length;
    _exitSelection();
    if (mounted) messenger.showSnackBar(SnackBar(content: Text('Recovering $n discard${n == 1 ? '' : 's'}…')));
    // One pass over all selected discards → each recovered standalone, then a
    // single "Completed" banner (instead of one ~10s banner per item).
    await controller.recoverDiscards(sel);
  }

  /// Per-row Recover. The controller clears a lingering "Completed" banner and
  /// proceeds, so the only no-op case left is a genuinely busy pipeline — show a
  /// hint there instead of silently dropping the tap.
  Future<void> _recoverDiscard(RecordingsController controller, DiscardRecord d) async {
    if (controller.isPipelineBusy) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Finishing sync — try recovering again in a moment.')));
      return;
    }
    await controller.recoverDiscard(d);
  }

  Future<void> _exportSelectedRecordings(RecordingsController controller) async {
    final rows = _activeRows(controller);
    if (rows == null) return;
    final sel = rows.recordings.where((r) => _selIds.contains(r.file.path)).toList();
    if (sel.isEmpty) return;
    final date = _selDate;
    _exitSelection();
    final files = sel.map((r) => XFile(r.file.path)).toList();
    await SharePlus.instance.share(
      ShareParams(files: files, subject: 'Conversations – $date'),
    );
  }

  Widget _buildSelectionBar(RecordingsController controller) {
    final rows = _activeRows(controller);
    final type = _selType;
    if (rows == null || type == null) return const SizedBox.shrink();
    final isRec = type == RecordingRowType.recording;
    final allIds = isRec ? rows.recordings.map((r) => r.file.path).toList() : rows.discards.map((d) => d.id).toList();
    final count = _selIds.length;
    final hasSel = count > 0;
    Color actionColor(Color enabled) => hasSel ? enabled : Colors.grey.shade700;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 12),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2E),
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 12, offset: Offset(0, 4))],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 22),
                tooltip: 'Cancel',
                onPressed: _exitSelection,
              ),
              Text('$count', style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.checklist, color: Colors.white, size: 20),
                tooltip: 'Select all',
                onPressed: () => _selectAll(allIds),
              ),
              IconButton(
                icon: Icon(Icons.remove_done, color: hasSel ? Colors.white : Colors.grey.shade700, size: 20),
                tooltip: 'Select none',
                onPressed: hasSel ? _selectNone : null,
              ),
              if (isRec)
                IconButton(
                  icon: FaIcon(FontAwesomeIcons.shareFromSquare, color: actionColor(Colors.grey.shade300), size: 18),
                  tooltip: 'Export selected',
                  onPressed: hasSel ? () => _exportSelectedRecordings(controller) : null,
                )
              else
                IconButton(
                  icon: FaIcon(FontAwesomeIcons.rotateLeft, color: actionColor(Colors.deepPurpleAccent), size: 18),
                  tooltip: 'Recover selected',
                  onPressed: hasSel ? () => _recoverSelectedDiscards(controller) : null,
                ),
              IconButton(
                icon: FaIcon(FontAwesomeIcons.trashCan, color: actionColor(Colors.red.shade400), size: 18),
                tooltip: 'Delete selected',
                onPressed: hasSel
                    ? (isRec ? () => _deleteSelectedRecordings(controller) : () => _deleteSelectedDiscards(controller))
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _controller = RecordingsController()..init();
    _selBarAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
    _selBarCurve = CurvedAnimation(parent: _selBarAnim, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _selBarAnim.dispose();
    _controller.dispose();
    super.dispose();
  }

  Widget _buildBackToTop() {
    final visible = _showBackToTop;
    return AnimatedSlide(
      offset: visible ? Offset.zero : const Offset(0, 1.5),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: IgnorePointer(
          ignoring: !visible,
          child: FloatingActionButton.small(
            heroTag: null,
            backgroundColor: const Color(0xFF2C2C2E),
            foregroundColor: Colors.white,
            elevation: 4,
            onPressed: () => _scrollController.animateTo(
              0,
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeOutCubic,
            ),
            child: const Icon(Icons.keyboard_arrow_up),
          ),
        ),
      ),
    );
  }

  Future<void> _forceSyncButtonPressed() async {
    if (_controller.spState != SyncProcessState.idle) return;
    if (_controller.forceSyncOnCooldown) return;

    final skipConfirm = _prefs.forceSyncSkipConfirm;
    if (!skipConfirm) {
      bool doNotShowAgain = false;
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            backgroundColor: const Color(0xFF1C1C1E),
            title: const Text(
              'Force Sync',
              style: TextStyle(color: Colors.white),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'This will close the current recording segment and immediately sync all available data, including recordings shorter than the usual minimum.',
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 16),
                GestureDetector(
                  onTap: () => setDialogState(() => doNotShowAgain = !doNotShowAgain),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: Checkbox(
                          value: doNotShowAgain,
                          onChanged: (v) => setDialogState(() => doNotShowAgain = v ?? false),
                          activeColor: Colors.deepPurpleAccent,
                          side: const BorderSide(color: Colors.grey),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Don\'t show again',
                        style: TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text(
                  'Cancel',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text(
                  'Yes',
                  style: TextStyle(color: Colors.deepPurpleAccent),
                ),
              ),
            ],
          ),
        ),
      );
      if (confirm != true) return;
      if (doNotShowAgain) _prefs.forceSyncSkipConfirm = true;
    }

    unawaited(_controller.startForcePipeline());
  }

  Future<void> _showCancelModal() async {
    final state = _controller.spState;
    if (state == SyncProcessState.syncing) {
      // Mid-download: let the user keep the segments already pulled to the phone
      // (continue into processing) or stop everything. Dismissing keeps syncing.
      final choice = await showDialog<String>(
        context: context,
        builder: (c) => getDialog(
          c,
          () => Navigator.of(c).pop('stop'),
          () => Navigator.of(c).pop('process'),
          'Stop syncing?',
          'Process the segments already downloaded to this phone, or stop and leave them for the next sync?',
          cancelText: 'Stop everything',
          confirmText: 'Process downloaded',
        ),
      );
      if (choice == 'process') {
        _controller.cancelPipeline(processDownloaded: true);
      } else if (choice == 'stop') {
        _controller.cancelPipeline(processDownloaded: false);
      }
    } else if (state == SyncProcessState.processing) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (c) => getDialog(
          c,
          () => Navigator.of(c).pop(false),
          () => Navigator.of(c).pop(true),
          'Stop processing?',
          'Processing will stop. Downloaded segments are kept and finish on the next sync.',
          confirmText: 'Stop',
        ),
      );
      if (confirm == true) _controller.cancelPipeline(processDownloaded: false);
    }
  }

  void _uploadAllDay(List<Conversation> filtered) {
    if (filtered.isEmpty) return;

    // Sort oldest-to-newest so they queue and upload in chronological order
    final sorted = List<Conversation>.from(filtered)..sort((a, b) => a.startTime.compareTo(b.startTime));

    int queued = 0;
    for (final c in sorted) {
      if (_controller.uploadStatus(c) != UploadStatus.all && _controller.uploadStatus(c) != UploadStatus.unavailable) {
        _controller.uploadConversation(c).ignore();
        queued++;
      }
    }
    if (queued > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Queued $queued recording${queued == 1 ? '' : 's'} for upload')),
      );
    }
  }

  Future<void> _deleteDayConversations(
      Batch batch, List<Conversation> toDelete, List<DiscardRecord> toDeleteDiscards) async {
    if (toDelete.isEmpty && toDeleteDiscards.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);

    // If tabs are disabled OR we are in "All" mode, we are effectively
    // deleting everything the user can see for the whole day.
    final isFullDay = _prefs.filterMinDurationSeconds == 0 || _filterMode == RecordingFilterMode.all;

    final totalCount = toDelete.length + toDeleteDiscards.length;
    final description = isFullDay
        ? 'everything for ${batch.dateString}'
        : '$totalCount ${_filterMode == RecordingFilterMode.hidden ? 'hidden' : 'main'} item${totalCount == 1 ? '' : 's'} for ${batch.dateString}';

    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (c) => getDialog(
        c,
        () => Navigator.of(c).pop(false),
        () => Navigator.of(c).pop(true),
        'Delete Day',
        'This will permanently delete $description. This cannot be undone.',
        confirmText: 'Delete',
      ),
    );
    if (confirm != true) return;
    try {
      if (isFullDay) {
        await _controller.deleteDay(batch);
      } else {
        await _controller.deleteConversations(toDelete);
        await _controller.deleteDiscards(toDeleteDiscards);
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Error deleting day: $e')),
        );
      }
    }
  }

  Future<void> _deleteAllDiscards(Batch batch, List<DiscardRecord> discards) async {
    if (discards.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final count = discards.length;

    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (c) => getDialog(
        c,
        () => Navigator.of(c).pop(false),
        () => Navigator.of(c).pop(true),
        'Delete Discards',
        'This will permanently delete $count discarded ${count == 1 ? 'segment' : 'segments'} for ${batch.dateString}, '
            'including their audio. They can no longer be recovered. This cannot be undone.',
        confirmText: 'Delete',
      ),
    );
    if (confirm != true) return;
    try {
      await _controller.deleteDiscards(discards);
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Error deleting discards: $e')),
        );
      }
    }
  }

  String _filterLabel(RecordingFilterMode mode) => switch (mode) {
        RecordingFilterMode.visible => 'Main',
        RecordingFilterMode.hidden => 'Hidden',
        RecordingFilterMode.all => 'All',
      };

  PopupMenuItem<RecordingFilterMode> _buildFilterMenuItem(String label, RecordingFilterMode mode) {
    final selected = _filterMode == mode;
    return PopupMenuItem<RecordingFilterMode>(
      value: mode,
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: selected ? const Icon(Icons.check, size: 16, color: Colors.deepPurpleAccent) : null,
          ),
          Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : Colors.grey.shade300,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteConversation(Conversation conversation) async {
    final messenger = ScaffoldMessenger.of(context);
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (c) => getDialog(
        c,
        () => Navigator.of(c).pop(false),
        () => Navigator.of(c).pop(true),
        'Delete Conversation',
        'This will permanently delete this conversation. This cannot be undone.',
        confirmText: 'Delete',
      ),
    );
    if (confirm != true) return;
    try {
      await _controller.deleteConversation(conversation);
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Deleted conversation from ${conversation.timeRangeLabel}')),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Error deleting conversation: $e')),
        );
      }
    }
  }

  Future<void> _deleteMarkerConversation(MarkerConversation mc) async {
    final messenger = ScaffoldMessenger.of(context);
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (c) => getDialog(
        c,
        () => Navigator.of(c).pop(false),
        () => Navigator.of(c).pop(true),
        'Delete Marker',
        'This will permanently delete this marker.',
        confirmText: 'Delete',
      ),
    );
    if (confirm != true) return;
    try {
      await _controller.deleteMarkerConversation(mc);
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Deleted Marker at ${mc.markerTimeLabel}')),
        );
        if (_controller.markerConversations.isEmpty) {
          setState(() => _showMarkersOnly = false);
        }
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Error deleting marker: $e')),
        );
      }
    }
  }

  Future<void> _exportAll(Batch batch, List<Conversation> conversations) async {
    if (conversations.isEmpty) return;
    final files = conversations.map((r) => XFile(r.file.path)).toList();
    await SharePlus.instance.share(
      ShareParams(files: files, subject: 'Conversations – ${batch.dateString}'),
    );
  }

  Map<String, List<MarkerConversation>> _buildMarkerMap() {
    final map = <String, List<MarkerConversation>>{};
    for (final mc in _controller.markerConversations) {
      if (mc.segment == null) continue;
      final key = mc.segment!.path.split('/').last;
      map.putIfAbsent(key, () => []).add(mc);
    }
    return map;
  }

  Map<String, List<MarkerConversation>> _groupMarkersByDate() {
    final map = <String, List<MarkerConversation>>{};
    for (final mc in _controller.markerConversations) {
      final dt = mc.markerTime;
      final dateStr = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
      map.putIfAbsent(dateStr, () => []).add(mc);
    }
    return map;
  }

  Future<void> _openMarkerConversation(MarkerConversation mc) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MarkerConversationPlayerPage(markerConversation: mc),
      ),
    );
    await _controller.reloadBatchesSilently();
  }

  Future<void> _openConversation(Conversation conv) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ConversationPlayerPage(conversation: conv, controller: _controller),
      ),
    );
    await _controller.reloadBatchesSilently();
  }

  Widget _buildUnorganizedSection(List<Conversation> unknown) {
    if (unknown.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Row(
            children: [
              const FaIcon(
                FontAwesomeIcons.circleQuestion,
                color: Colors.amber,
                size: 13,
              ),
              const SizedBox(width: 8),
              const Text(
                'Unorganized',
                style: TextStyle(
                  color: Colors.amber,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '· ${unknown.length} recording${unknown.length == 1 ? '' : 's'} with unknown timestamps',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
              ),
            ],
          ),
        ),
        ...unknown.map(
          (conv) => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Material(
              color: Colors.grey.shade900,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _openConversation(conv),
                onLongPress: () => _deleteConversation(conv),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 10,
                    horizontal: 12,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Unknown date  ·  ${conv.durationLabel}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              'Estimated: ${conv.startTime.year}-${conv.startTime.month.toString().padLeft(2, '0')}-${conv.startTime.day.toString().padLeft(2, '0')}  ·  ${conv.sizeLabel}',
                              style: TextStyle(
                                color: Colors.grey.shade500,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      FaIcon(
                        FontAwesomeIcons.chevronRight,
                        color: Colors.grey.shade600,
                        size: 14,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = ChangeNotifierProvider.value(
      value: _controller,
      child: Consumer2<DeviceProvider, RecordingsController>(
        builder: (context, deviceProvider, controller, child) {
          final snack = controller.consumePendingSnack();
          if (snack != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(snack)));
              }
            });
          }
          return Scaffold(
            backgroundColor: const Color(0xFF0D0D0D),
            appBar: AppBar(
              backgroundColor: const Color(0xFF0D0D0D),
              elevation: 0,
              centerTitle: false,
              leadingWidth: 72,
              leading: !deviceProvider.isConnected
                  ? Container(
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.only(left: 8.0),
                      child: deviceProvider.isConnecting
                          ? const Padding(
                              padding: EdgeInsets.only(left: 8.0),
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              ),
                            )
                          : Padding(
                              padding: const EdgeInsets.only(left: 8.0),
                              child: IconButton(
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                icon: FaIcon(
                                  FontAwesomeIcons.bluetooth,
                                  color: deviceProvider.isBluetoothEnabled ? Colors.grey : Colors.red,
                                  size: 20,
                                ),
                                tooltip: 'Find devices',
                                onPressed: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (c) => const FindDevicesPage(),
                                  ),
                                ),
                              ),
                            ),
                    )
                  : BatteryStatusIndicator(
                      batteryLevel: deviceProvider.batteryLevel,
                      isCharging: deviceProvider.isCharging,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (c) => const DeviceSettings(),
                        ),
                      ),
                    ),
              actions: [
                // Manual/Automatic mode indicator — icon only. Taps open the
                // audio settings page where the mode (and its per-mode fields)
                // are edited; the icon refreshes on return.
                IconButton(
                  icon: FaIcon(
                    _prefs.manualMode ? FontAwesomeIcons.hand : FontAwesomeIcons.wandMagicSparkles,
                    color: _prefs.manualMode ? Colors.grey.shade300 : Colors.deepPurpleAccent,
                    size: 20,
                  ),
                  tooltip: _prefs.manualMode ? 'Manual mode' : 'Automatic mode',
                  onPressed: () => Navigator.of(context)
                      .push(
                    MaterialPageRoute(
                      builder: (_) => const OfflineAudioSettingsPage(flashManualMode: true),
                    ),
                  )
                      .then((_) {
                    if (mounted) setState(() {});
                  }),
                ),
                if (controller.markerConversations.isNotEmpty)
                  IconButton(
                    icon: FaIcon(
                      _showMarkersOnly ? FontAwesomeIcons.solidBookmark : FontAwesomeIcons.bookmark,
                      color: _showMarkersOnly ? Colors.amber : Colors.white,
                      size: 20,
                    ),
                    onPressed: () => setState(() => _showMarkersOnly = !_showMarkersOnly),
                    tooltip: 'Toggle markers only',
                  ),
                // Mute toggle — auto mode only (mute is unavailable in manual mode).
                // Red mic-off when muted; disabled until connected.
                if (!_prefs.manualMode)
                  IconButton(
                    icon: FaIcon(
                      deviceProvider.isMuted ? FontAwesomeIcons.microphoneSlash : FontAwesomeIcons.microphone,
                      color: deviceProvider.isMuted
                          ? Colors.red
                          : (deviceProvider.isConnected ? Colors.white : Colors.grey.shade700),
                      size: 20,
                    ),
                    onPressed: deviceProvider.isConnected
                        ? () => unawaited(deviceProvider.setMuted(!deviceProvider.isMuted))
                        : null,
                    tooltip: deviceProvider.isMuted ? 'Unmute Omi' : 'Mute Omi',
                  ),
                IconButton(
                  icon: FaIcon(
                    FontAwesomeIcons.boltLightning,
                    color: (deviceProvider.isConnected &&
                            controller.spState == SyncProcessState.idle &&
                            !controller.forceSyncOnCooldown)
                        ? Colors.white
                        : Colors.grey.shade700,
                    size: 20,
                  ),
                  onPressed: (deviceProvider.isConnected &&
                          controller.spState == SyncProcessState.idle &&
                          !controller.forceSyncOnCooldown)
                      ? _forceSyncButtonPressed
                      : null,
                  tooltip: 'Force sync',
                ),
                IconButton(
                  icon: const FaIcon(
                    FontAwesomeIcons.gear,
                    color: Colors.white,
                    size: 20,
                  ),
                  onPressed: () => SettingsDrawer.show(context, controller),
                  tooltip: 'Settings',
                ),
              ],
            ),
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  // 16 all around: a full day-gap above the title and below the
                  // "Last synced" line, matching the day-gap down to whatever
                  // sits below (the first day card, or a status card).
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const Text(
                            'Conversations',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          // Filter menu — only meaningful when short conversations
                          // are hidden. Off (filterMinDurationSeconds == 0) → no
                          // overflow menu at all. Using `child:` (not `icon:`)
                          // avoids IconButton's 48px min box so the glyph sits
                          // flush on the section's right edge. The tap ink flash
                          // is suppressed via the wrapping Theme (transparent
                          // splash/highlight/hover) — against a flush-right glyph
                          // the rectangular highlight looked lopsided.
                          if (!_showMarkersOnly && _prefs.filterMinDurationSeconds > 0)
                            Theme(
                                data: Theme.of(context).copyWith(
                                  splashColor: Colors.transparent,
                                  highlightColor: Colors.transparent,
                                  hoverColor: Colors.transparent,
                                ),
                                child: PopupMenuButton<RecordingFilterMode>(
                                  tooltip: 'Filter recordings',
                                  color: const Color(0xFF2C2C2E),
                                  position: PopupMenuPosition.under,
                                  initialValue: _filterMode,
                                  onSelected: (mode) => setState(() => _filterMode = mode),
                                  itemBuilder: (context) => [
                                    _buildFilterMenuItem('Main', RecordingFilterMode.visible),
                                    _buildFilterMenuItem('Hidden', RecordingFilterMode.hidden),
                                    _buildFilterMenuItem('All', RecordingFilterMode.all),
                                  ],
                                  // Show the active filter as a label on the control
                                  // (like a select). Tinted purple on a non-default
                                  // filter so a stray "Hidden"/"All" — where some
                                  // recordings are held back — stands out.
                                  child: Builder(builder: (context) {
                                    final filtering = _filterMode != RecordingFilterMode.visible;
                                    final tint = filtering ? Colors.deepPurpleAccent : Colors.grey.shade400;
                                    return Padding(
                                      padding: const EdgeInsets.fromLTRB(12, 8, 0, 8),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          // Default filter (Main) shows the funnel
                                          // alone; only a non-default selection labels
                                          // itself, tinted purple so it stands out.
                                          if (filtering) ...[
                                            Text(
                                              _filterLabel(_filterMode),
                                              style: TextStyle(
                                                color: tint,
                                                fontSize: 13,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                          ],
                                          FaIcon(
                                            FontAwesomeIcons.filter,
                                            size: 16,
                                            color: tint,
                                          ),
                                        ],
                                      ),
                                    );
                                  }),
                                )),
                        ],
                      ),
                      // "Last synced …" sits directly under the header; renders
                      // nothing before the first-ever sync. Uses the completion
                      // timestamp (success/partial), not the status timestamp, so a
                      // skipped cycle (device out of range / BT off) never resets
                      // the clock — only a sync that actually moved data does.
                      LastSyncedLabel(lastSyncCompletedMs: _prefs.lastSyncCompletedMs),
                    ],
                  ),
                ),
                StorageWarningBanner(
                  percentage: deviceProvider.storageFullPercentage,
                ),
                VadFallbackBanner(active: _prefs.lastVadFallbackActive),
                MutedBanner(
                  isMuted: deviceProvider.isMuted,
                  since: deviceProvider.muteSince,
                ),
                SyncProcessCard(
                  data: SyncCardData(
                    state: controller.spState,
                    isForcePipeline: controller.isForcePipeline,
                    syncedCount: controller.syncedCount,
                    totalCount: controller.totalCount,
                    syncSpeed: controller.syncSpeed,
                    minutesRemaining: controller.minutesRemaining,
                    totalMinutes: controller.totalMinutes,
                    processingProgress: controller.processingProgress,
                    isTranscoding: controller.isTranscoding,
                    audioSaveFormat: _prefs.audioSaveFormat,
                    lastActiveStage: controller.lastActiveStage,
                  ),
                  onCancelTap: () => unawaited(_showCancelModal()),
                  onDismissTap: () => controller.dismissSuccess(),
                  onActionTap: () {
                    if (controller.spState == SyncProcessState.idle) {
                      controller.startPipeline();
                    } else if (controller.spState == SyncProcessState.resume) {
                      controller.resumePipeline();
                    } else if (controller.spState == SyncProcessState.error) {
                      controller.retryFromError();
                    }
                  },
                ),
                AccumulatingBanner(
                  spState: controller.spState,
                  toProcessMinutes: controller.toProcessMinutes,
                  draftMinutes: controller.draftMinutes,
                  unprocessedBinCount: controller.unprocessedBinCount,
                  draftEndTime: controller.draftEndTime,
                  onTap: () {
                    if (controller.spState == SyncProcessState.syncing ||
                        controller.spState == SyncProcessState.processing ||
                        controller.spState == SyncProcessState.stopping) {
                      return;
                    }

                    // Raw bins waiting to be decoded → just process them; the
                    // normal pass respects pause limits and folds them into the
                    // draft. No need to confirm — nothing gets cut.
                    const double minShown = 1.0 / 60.0;
                    if (controller.toProcessMinutes >= minShown) {
                      controller.startProcessingWithoutSync();
                      return;
                    }

                    // No bins left, only an open draft: force-finalizing cuts the
                    // conversation at its current end. Show the estimated end time
                    // when we have one; otherwise just confirm finalizing early.
                    final end = controller.draftEndTime;
                    final endLabel = end != null
                        ? DateFormat(SharedPreferencesUtil().use24HourTime ? 'HH:mm' : 'h:mm a').format(end)
                        : null;
                    showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        backgroundColor: const Color(0xFF1C1C1E),
                        title: const Text(
                          'Finalize Recording',
                          style: TextStyle(color: Colors.white),
                        ),
                        content: Text(
                          endLabel != null
                              ? 'This recording will be finalized with an end time of ~$endLabel.'
                              : 'This finalizes the in-progress recording early.',
                          style: const TextStyle(color: Colors.white70, fontSize: 14),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            child: const Text(
                              'Cancel',
                              style: TextStyle(color: Colors.grey),
                            ),
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.of(ctx).pop();
                              controller.startForceProcessingWithoutSync();
                            },
                            child: const Text(
                              'Confirm',
                              style: TextStyle(color: Colors.deepPurpleAccent),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      controller.isLoading
                          ? const Center(
                              child: CircularProgressIndicator(
                                color: Colors.deepPurpleAccent,
                              ),
                            )
                          : Builder(
                              builder: (context) {
                                if (_showMarkersOnly) {
                                  final byDate = _groupMarkersByDate();
                                  final dates = byDate.keys.toList()..sort((a, b) => b.compareTo(a));
                                  return RefreshIndicator(
                                    color: Colors.deepPurpleAccent,
                                    onRefresh: () async {},
                                    child: dates.isEmpty
                                        ? ListView(
                                            physics: const AlwaysScrollableScrollPhysics(),
                                            children: const [
                                              SizedBox(height: 100),
                                              Center(
                                                child: Text(
                                                  'No marked recordings yet.\nPress the button on your Omi to tag a moment.',
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(
                                                    color: Colors.grey,
                                                    fontSize: 16,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          )
                                        : ListView.builder(
                                            physics: const AlwaysScrollableScrollPhysics(),
                                            // Top 0: the gap above lives outside
                                            // the scroll view (header padding, or
                                            // the status card's margin), so it
                                            // persists while scrolling.
                                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                                            itemCount: dates.length,
                                            itemBuilder: (context, index) => MarkerDayCard(
                                              dateStr: dates[index],
                                              markers: byDate[dates[index]]!,
                                              onMarkerTap: _openMarkerConversation,
                                              onDeleteMarkerConversation: _deleteMarkerConversation,
                                            ),
                                          ),
                                  );
                                }

                                final markerMap = _buildMarkerMap();
                                final minSeconds = _prefs.filterMinDurationSeconds;
                                final visibleBatches = minSeconds > 0
                                    ? switch (_filterMode) {
                                        RecordingFilterMode.visible => controller.batches
                                            .where((b) =>
                                                b.rawSegments.isNotEmpty ||
                                                b.finalizedRecordings.any((c) => c.duration.inSeconds >= minSeconds) ||
                                                b.discards.any((d) => d.duration.inSeconds >= minSeconds))
                                            .toList(),
                                        RecordingFilterMode.hidden => controller.batches
                                            .where((b) =>
                                                b.rawSegments.isNotEmpty ||
                                                b.finalizedRecordings.any((c) => c.duration.inSeconds < minSeconds) ||
                                                b.discards.any((d) => d.duration.inSeconds < minSeconds))
                                            .toList(),
                                        RecordingFilterMode.all => controller.batches
                                            .where((b) =>
                                                b.rawSegments.isNotEmpty ||
                                                b.finalizedRecordings.isNotEmpty ||
                                                b.discards.isNotEmpty)
                                            .toList(),
                                      }
                                    : controller.batches
                                        .where((b) =>
                                            b.rawSegments.isNotEmpty ||
                                            b.finalizedRecordings.isNotEmpty ||
                                            b.discards.isNotEmpty)
                                        .toList();
                                final unknownRecordings = visibleBatches
                                    .expand((b) => b.finalizedRecordings)
                                    .where((c) => c.isUnknown)
                                    .toList();
                                // In selection mode, collapse the list to just the
                                // active day so you can't scroll to another card and
                                // keep selecting. If the active day vanished (e.g. a
                                // background reload), drop out of selection.
                                if (_inSelectionMode && !visibleBatches.any((b) => b.dateString == _selDate)) {
                                  WidgetsBinding.instance.addPostFrameCallback((_) {
                                    if (mounted && _inSelectionMode) _exitSelection();
                                  });
                                }
                                final renderBatches = _inSelectionMode
                                    ? visibleBatches.where((b) => b.dateString == _selDate).toList()
                                    : visibleBatches;
                                // Global open-draft set (across every batch), computed once so each
                                // BatchCard can match a cross-midnight trailing ghost against a draft
                                // in an adjacent day's batch — mirroring the stitch pass's global fold.
                                final allOpenDrafts =
                                    controller.batches.expand((b) => b.draftRecordings).toList();
                                return RefreshIndicator(
                                  color: Colors.deepPurpleAccent,
                                  onRefresh: () {
                                    if (controller.spState != SyncProcessState.idle &&
                                        controller.spState != SyncProcessState.error) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text('Sync already in progress'),
                                        ),
                                      );
                                      return Future.value();
                                    }
                                    return controller.startPipeline();
                                  },
                                  child: visibleBatches.isEmpty
                                      ? ListView(
                                          physics: const AlwaysScrollableScrollPhysics(),
                                          children: [
                                            const SizedBox(height: 100),
                                            Center(
                                              child: Column(
                                                children: [
                                                  const Text(
                                                    'No conversations found.\nSwipe down to sync device.',
                                                    textAlign: TextAlign.center,
                                                    style: TextStyle(
                                                      color: Colors.grey,
                                                      fontSize: 16,
                                                    ),
                                                  ),
                                                  if (deviceProvider.isConnected) ...[
                                                    const SizedBox(height: 32),
                                                    ElevatedButton.icon(
                                                      onPressed: controller.spState == SyncProcessState.idle
                                                          ? controller.startPipeline
                                                          : null,
                                                      icon: const FaIcon(
                                                        FontAwesomeIcons.rotate,
                                                        size: 16,
                                                      ),
                                                      label: const Text(
                                                        'Sync and Process',
                                                      ),
                                                      style: ElevatedButton.styleFrom(
                                                        backgroundColor: Colors.deepPurpleAccent,
                                                        foregroundColor: Colors.white,
                                                      ),
                                                    ),
                                                  ] else ...[
                                                    const SizedBox(height: 32),
                                                    ElevatedButton(
                                                      onPressed: () => Navigator.of(
                                                        context,
                                                      ).push(
                                                        MaterialPageRoute(
                                                          builder: (c) => const FindDevicesPage(),
                                                        ),
                                                      ),
                                                      style: ElevatedButton.styleFrom(
                                                        backgroundColor: Colors.deepPurpleAccent,
                                                        foregroundColor: Colors.white,
                                                      ),
                                                      child: const Text(
                                                        'Connect Omi',
                                                      ),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                            ),
                                          ],
                                        )
                                      : ListView.builder(
                                          controller: _scrollController,
                                          physics: const AlwaysScrollableScrollPhysics(),
                                          // Top 0: the gap above the list lives
                                          // outside the scroll view — the header's
                                          // bottom padding when no status card is
                                          // shown, else the bottom-most status
                                          // card's margin — so it persists while
                                          // scrolling instead of scrolling away.
                                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                                          // Unorganized section hides in selection mode.
                                          itemCount: renderBatches.length + (_inSelectionMode ? 0 : 1),
                                          itemBuilder: (context, index) {
                                            if (!_inSelectionMode && index == 0) {
                                              return _buildUnorganizedSection(
                                                unknownRecordings,
                                              );
                                            }
                                            final batch = renderBatches[_inSelectionMode ? index : index - 1];
                                            final anyIntegrationEnabled =
                                                PassthroughIntegration.hasAnyConfigured(_prefs);
                                            return BatchCard(
                                              batch: batch,
                                              openDrafts: allOpenDrafts,
                                              markerMap: markerMap,
                                              anyIntegrationEnabled: anyIntegrationEnabled,
                                              filterMode: _filterMode,
                                              uploadStatus: controller.uploadStatus,
                                              uploadCount: controller.actionableIntegrationCount,
                                              isUploading: controller.uploadingFiles.contains,
                                              onConversationTap: _openConversation,
                                              onMarkerTap: _openMarkerConversation,
                                              onExportAll: (conversations) => _exportAll(batch, conversations),
                                              onUploadAll: _uploadAllDay,
                                              onDeleteDay: (toDelete, toDeleteDiscards) => _deleteDayConversations(
                                                batch,
                                                toDelete,
                                                toDeleteDiscards,
                                              ),
                                              onDeleteAllDiscards: (toDeleteDiscards) => _deleteAllDiscards(
                                                batch,
                                                toDeleteDiscards,
                                              ),
                                              onDeleteMarkerConversation: _deleteMarkerConversation,
                                              onRecoverDiscard: (d) => _recoverDiscard(controller, d),
                                              onDeleteDiscard: controller.deleteDiscard,
                                              activeSelectionType:
                                                  (_inSelectionMode && batch.dateString == _selDate) ? _selType : null,
                                              selectedIds: _selIds,
                                              onEnterSelection: (type, id) =>
                                                  _enterSelection(batch.dateString, type, id),
                                              onToggleSelection: _toggleSelection,
                                            );
                                          },
                                        ),
                                );
                              },
                            ),
                      // Back-to-top FAB overlays the list (normal browse only).
                      if (!_showMarkersOnly && !_inSelectionMode)
                        Positioned(
                          right: 16,
                          bottom: 16,
                          child: _buildBackToTop(),
                        ),
                    ],
                  ),
                ),
                // Floating action pill — in-flow below the list so it shrinks
                // the viewport (last row stays tappable) instead of overlaying.
                SafeArea(
                  top: false,
                  // axisAlignment 1.0 anchors the reveal to the bottom edge, so
                  // the bar slides up from the bottom on enter and back down on
                  // exit, while still shrinking the list as it grows.
                  child: SizeTransition(
                    sizeFactor: _selBarCurve,
                    axisAlignment: 1.0,
                    child: _buildSelectionBar(controller),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // Back exits selection mode first, before falling through to minimize.
        if (_inSelectionMode) {
          _exitSelection();
          return;
        }
        // Root page: minimize instead of closing so the BLE foreground service
        // (and its notification) survives. iOS forbids self-backgrounding.
        if (Platform.isAndroid) _systemChannel.invokeMethod('moveTaskToBack');
      },
      child: body,
    );
  }
}
