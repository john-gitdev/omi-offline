List<double> normalizeAmplitudes(List<double> amps) {
  if (amps.length < 4) return amps;
  final sorted = [...amps]..sort();
  final p5 = sorted[(sorted.length * 0.05).floor()];
  final p95 = sorted[(sorted.length * 0.95).floor()];
  final range = p95 - p5;
  if (range < 0.02) return amps;
  return amps.map((a) => ((a - p5) / range).clamp(0.0, 1.0)).toList();
}
