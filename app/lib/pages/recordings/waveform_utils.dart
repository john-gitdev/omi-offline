import 'dart:math';

// ln(10) precomputed — avoids recomputing it on every bar during waveform load.
const _ln10 = 2.302585092994046;

/// Maps a linear amplitude [0,1] to a perceptual [0,1] using a -40 dBFS log
/// scale so subtle level changes remain visible on loud/steady recordings.
/// Values at or below the -40 dB floor (< 1 % of full scale) map to 0.
double logScale(double x) {
  const floorDb = -40.0;
  if (x <= 0) return 0.0;
  final db = 20.0 * log(x) / _ln10;
  return ((db - floorDb) / (-floorDb)).clamp(0.0, 1.0);
}
