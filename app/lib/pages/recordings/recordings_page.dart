import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
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
import 'package:omi/pages/recordings/integration_status_sheet.dart';
import 'package:omi/pages/recordings/recordings_types.dart';
import 'package:omi/pages/recordings/recordings_banners.dart';
import 'package:omi/pages/recordings/sync_process_card.dart';
import 'package:omi/pages/recordings/batch_card.dart';
import 'package:omi/pages/recordings/recording_player_page.dart';
import 'package:omi/pages/recordings/marker_day_card.dart';
import 'package:omi/pages/recordings/recordings_controller.dart';
import 'package:omi/pages/settings/offline_audio_settings_page.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/widgets/dialog.dart';
import 'package:omi/widgets/battery_status_indicator.dart';

// ─── Page ───────────────────────────────────────────────────────────────────
class RecordingsPage extends StatefulWidget {
  const RecordingsPage({super.key});

  @override
  State<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends State<RecordingsPage> {
  // Back press on the root page minimizes the app (moves the task to back)
  // rather than finishing MainActivity — finishing would tear down the BLE
  // foreground service and drop its persistent notification.
  static const _systemChannel = MethodChannel('com.omi.offline/system');

  final _prefs = SharedPreferencesUtil();
  late final RecordingsController _controller;

  bool _showMarkersOnly = false;
  RecordingFilterMode _filterMode = RecordingFilterMode.visible;

  @override
  void initState() {
    super.initState();
    _controller = RecordingsController()..init();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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

  Widget _buildFilterBubble(String label, RecordingFilterMode mode) {
    final selected = _filterMode == mode;
    return Expanded(
      child: Semantics(
        button: true,
        label: 'Filter by $label',
        selected: selected,
        child: Tooltip(
          message: 'Filter by $label',
          child: Material(
            color: selected ? Colors.deepPurpleAccent : Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(17),
              side: selected ? BorderSide.none : BorderSide(color: Colors.grey.shade700),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => setState(() => _filterMode = mode),
              child: Container(
                height: 34,
                alignment: Alignment.center,
                child: Text(
                  label,
                  style: TextStyle(
                    color: selected ? Colors.white : Colors.grey.shade500,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ),
          ),
        ),
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
      if (mounted)
        messenger.showSnackBar(
          SnackBar(content: Text('Error deleting conversation: $e')),
        );
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
        'This will permanently delete this marker conversation.',
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
      if (mounted)
        messenger.showSnackBar(
          SnackBar(content: Text('Error deleting marker: $e')),
        );
    }
  }

  Future<void> _exportAll(Batch batch, List<Conversation> conversations) async {
    if (conversations.isEmpty) return;
    final files = conversations.map((r) => XFile(r.file.path)).toList();
    await SharePlus.instance.share(
      ShareParams(files: files, subject: 'Conversations – ${batch.dateString}'),
    );
  }

  Future<void> _handleUploadTap(Conversation conversation) async {
    final uploadKey = conversation.uploadKey;
    if (uploadKey == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Upload key unavailable — please reconnect your device and try again.',
          ),
        ),
      );
      return;
    }
    if (_controller.uploadingFiles.contains(uploadKey)) return;

    // With 2+ applicable integrations the single aggregate icon can't represent
    // every per-integration state, so a tap opens the detail sheet (per-row
    // upload/retry) instead of firing a blind upload-to-all.
    if (_controller.applicableIntegrationCount(conversation) >= 2) {
      await showIntegrationStatusSheet(context, _controller, conversation);
      return;
    }

    final alreadyUploaded = _controller.isUploaded(conversation);
    if (alreadyUploaded) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (c) => getDialog(
          c,
          () => Navigator.of(c).pop(false),
          () => Navigator.of(c).pop(true),
          'Re-upload Conversation',
          'This conversation was already uploaded to your enabled integrations. Upload again? (It may create duplicates.)',
          confirmText: 'Upload',
        ),
      );
      if (confirm != true) return;
    }

    try {
      final failures = await _controller.uploadConversation(conversation, force: alreadyUploaded);
      if (!mounted) return;
      for (final failure in failures) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${failure.integration} upload failed: ${failure.error}')));
      }
    } catch (e) {
      Logger.error('Manual upload failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
      }
    }
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
              if (mounted)
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(snack)));
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
                  padding: const EdgeInsets.fromLTRB(24, 8, 16, 16),
                  child: Row(
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
                      GestureDetector(
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const OfflineAudioSettingsPage(
                              flashManualMode: true,
                            ),
                          ),
                        ),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color:
                                _prefs.manualMode ? const Color(0xFF2A2A2E) : Colors.deepPurpleAccent.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color:
                                  _prefs.manualMode ? Colors.grey.shade700 : Colors.deepPurpleAccent.withOpacity(0.6),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              FaIcon(
                                _prefs.manualMode ? FontAwesomeIcons.hand : FontAwesomeIcons.wandMagicSparkles,
                                size: 11,
                                color: _prefs.manualMode ? Colors.grey.shade400 : Colors.deepPurpleAccent,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                _prefs.manualMode ? 'Manual' : 'Automatic',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: _prefs.manualMode ? Colors.grey.shade400 : Colors.deepPurpleAccent,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (!_showMarkersOnly && _prefs.filterMinDurationSeconds > 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Row(
                      children: [
                        _buildFilterBubble('Main', RecordingFilterMode.visible),
                        const SizedBox(width: 8),
                        _buildFilterBubble('Hidden', RecordingFilterMode.hidden),
                        const SizedBox(width: 8),
                        _buildFilterBubble('All', RecordingFilterMode.all),
                      ],
                    ),
                  ),
                StorageWarningBanner(
                  percentage: deviceProvider.storageFullPercentage,
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
                    if (controller.spState == SyncProcessState.idle)
                      controller.startPipeline();
                    else if (controller.spState == SyncProcessState.resume)
                      controller.resumePipeline();
                    else if (controller.spState == SyncProcessState.error) controller.retryFromError();
                  },
                ),
                AccumulatingBanner(
                  spState: controller.spState,
                  toProcessMinutes: controller.toProcessMinutes,
                  draftMinutes: controller.draftMinutes,
                  unprocessedBinCount: controller.unprocessedBinCount,
                  onTap: () {
                    if (controller.spState == SyncProcessState.syncing ||
                        controller.spState == SyncProcessState.processing ||
                        controller.spState == SyncProcessState.stopping) return;
                    showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        backgroundColor: const Color(0xFF1C1C1E),
                        title: const Text(
                          'Process Audio',
                          style: TextStyle(color: Colors.white),
                        ),
                        content: const Text(
                          'You can process the accumulated audio now. Processing normally will respect the conversation pause limits, while Force Processing will finalize everything immediately.',
                          style: TextStyle(color: Colors.white70, fontSize: 14),
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
                              controller.startProcessingWithoutSync();
                            },
                            child: const Text(
                              'Process Normally',
                              style: TextStyle(color: Colors.deepPurpleAccent),
                            ),
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.of(ctx).pop();
                              controller.startForceProcessingWithoutSync();
                            },
                            child: const Text(
                              'Force Process',
                              style: TextStyle(color: Colors.deepPurpleAccent),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                Expanded(
                  child: controller.isLoading
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
                                        children: [
                                          const SizedBox(height: 100),
                                          Center(
                                            child: const Text(
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
                                        padding: const EdgeInsets.all(16),
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
                            final unknownRecordings =
                                visibleBatches.expand((b) => b.finalizedRecordings).where((c) => c.isUnknown).toList();
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
                                      physics: const AlwaysScrollableScrollPhysics(),
                                      padding: const EdgeInsets.all(16),
                                      itemCount: visibleBatches.length + 1,
                                      itemBuilder: (context, index) {
                                        if (index == 0) {
                                          return _buildUnorganizedSection(
                                            unknownRecordings,
                                          );
                                        }
                                        final batchIndex = index - 1;
                                        final anyIntegrationEnabled = PassthroughIntegration.hasAnyConfigured(_prefs);
                                        return BatchCard(
                                          batch: visibleBatches[batchIndex],
                                          markerMap: markerMap,
                                          anyIntegrationEnabled: anyIntegrationEnabled,
                                          filterMode: _filterMode,
                                          uploadStatus: controller.uploadStatus,
                                          uploadCount: controller.applicableIntegrationCount,
                                          isUploading: controller.uploadingFiles.contains,
                                          onUploadTap: _handleUploadTap,
                                          onConversationTap: _openConversation,
                                          onMarkerTap: _openMarkerConversation,
                                          onExportAll: (conversations) => _exportAll(
                                            visibleBatches[batchIndex],
                                            conversations,
                                          ),
                                          onDeleteDay: (toDelete, toDeleteDiscards) => _deleteDayConversations(
                                            visibleBatches[batchIndex],
                                            toDelete,
                                            toDeleteDiscards,
                                          ),
                                          onDeleteConversation: _deleteConversation,
                                          onDeleteMarkerConversation: _deleteMarkerConversation,
                                          onRecoverDiscard: controller.recoverDiscard,
                                          onDeleteDiscard: controller.deleteDiscard,
                                        );
                                      },
                                    ),
                            );
                          },
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
        // Root page: minimize instead of closing so the BLE foreground service
        // (and its notification) survives. iOS forbids self-backgrounding.
        if (Platform.isAndroid) _systemChannel.invokeMethod('moveTaskToBack');
      },
      child: body,
    );
  }
}
