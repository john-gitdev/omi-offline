/// Thrown when the framed BLE protocol detects a gap in the offset sequence.
class ProtocolGapException implements Exception {
  final int incoming;
  final int expected;
  const ProtocolGapException(this.incoming, this.expected);
  @override
  String toString() => 'Protocol gap: incoming=$incoming expected=$expected';
}

/// Thrown when the firmware returns a non-zero ACK (error) for a command.
class AckException implements Exception {
  final int code;
  const AckException(this.code);
  @override
  String toString() => 'Error ACK: $code';
}
