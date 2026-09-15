class DeviceCrashLog {
  final String deviceId;
  final DateTime connectedAt;
  final int resetCause;
  final int uptimeSeconds;

  DeviceCrashLog({
    required this.deviceId,
    required this.connectedAt,
    required this.resetCause,
    required this.uptimeSeconds,
  });

  bool get isCrash => isCrashCause(resetCause);

  /// RESET_WATCHDOG (0x10) or RESET_CPU_LOCKUP (0x100): the firmware died rather than
  /// being restarted. Shared with the event log's `boot` record so the crash card and the
  /// log cannot disagree about what counts as a crash.
  static bool isCrashCause(int resetCause) => (resetCause & 0x110) != 0;

  String get causeLabel => describeResetCause(resetCause);

  /// Zephyr hwinfo reset-cause bits, as text. Shared with the event log's `boot`
  /// record (diag_log_record.dart), which carries the same bitfield.
  static String describeResetCause(int resetCause) {
    if (resetCause == 0) return 'unknown';
    final parts = <String>[];
    if (resetCause & 0x001 != 0) parts.add('pin reset');
    if (resetCause & 0x002 != 0) parts.add('software reset');
    if (resetCause & 0x004 != 0) parts.add('brownout');
    if (resetCause & 0x008 != 0) parts.add('power-on reset');
    if (resetCause & 0x010 != 0) parts.add('watchdog timeout');
    if (resetCause & 0x020 != 0) parts.add('debug reset');
    if (resetCause & 0x040 != 0) parts.add('security violation');
    if (resetCause & 0x080 != 0) parts.add('low power wake');
    if (resetCause & 0x100 != 0) parts.add('CPU lockup');
    return parts.isEmpty ? '0x${resetCause.toRadixString(16).padLeft(8, '0')}' : parts.join(', ');
  }

  String get uptimeStr {
    if (uptimeSeconds == 0) return '<10m';
    if (uptimeSeconds < 60) return '${uptimeSeconds}s';
    if (uptimeSeconds < 3600) return '${uptimeSeconds ~/ 60}m ${uptimeSeconds % 60}s';
    return '${uptimeSeconds ~/ 3600}h ${(uptimeSeconds % 3600) ~/ 60}m';
  }

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'at': connectedAt.millisecondsSinceEpoch,
        'cause': resetCause,
        'uptime': uptimeSeconds,
      };

  factory DeviceCrashLog.fromJson(Map<String, dynamic> json) => DeviceCrashLog(
        deviceId: json['device_id'] as String? ?? '',
        connectedAt: DateTime.fromMillisecondsSinceEpoch(json['at'] as int),
        resetCause: json['cause'] as int,
        uptimeSeconds: json['uptime'] as int,
      );
}
