class DeviceCrashLog {
  final DateTime connectedAt;
  final int resetCause;
  final int uptimeSeconds;

  DeviceCrashLog({
    required this.connectedAt,
    required this.resetCause,
    required this.uptimeSeconds,
  });

  // RESET_WATCHDOG = 0x10, RESET_CPU_LOCKUP = 0x100
  bool get isCrash => resetCause & 0x110 != 0;

  String get causeLabel {
    if (resetCause == 0) return 'unknown';
    final parts = <String>[];
    if (resetCause & 0x001 != 0) parts.add('pin reset');
    if (resetCause & 0x002 != 0) parts.add('software reset');
    if (resetCause & 0x004 != 0) parts.add('brownout');
    if (resetCause & 0x008 != 0) parts.add('power-on reset');
    if (resetCause & 0x010 != 0) parts.add('watchdog timeout');
    if (resetCause & 0x020 != 0) parts.add('debug reset');
    if (resetCause & 0x100 != 0) parts.add('CPU lockup');
    return parts.isEmpty ? '0x${resetCause.toRadixString(16).padLeft(8, '0')}' : parts.join(', ');
  }

  String get uptimeStr {
    if (uptimeSeconds == 0) return 'just started';
    if (uptimeSeconds < 60) return '${uptimeSeconds}s';
    if (uptimeSeconds < 3600) return '${uptimeSeconds ~/ 60}m ${uptimeSeconds % 60}s';
    return '${uptimeSeconds ~/ 3600}h ${(uptimeSeconds % 3600) ~/ 60}m';
  }

  Map<String, dynamic> toJson() => {
        'at': connectedAt.millisecondsSinceEpoch,
        'cause': resetCause,
        'uptime': uptimeSeconds,
      };

  factory DeviceCrashLog.fromJson(Map<String, dynamic> json) => DeviceCrashLog(
        connectedAt: DateTime.fromMillisecondsSinceEpoch(json['at'] as int),
        resetCause: json['cause'] as int,
        uptimeSeconds: json['uptime'] as int,
      );
}
