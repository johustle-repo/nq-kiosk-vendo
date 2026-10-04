/// Coin rate arithmetic shown to customers. The ESP8266 coin controller is the
/// authority; the phone displays the controller's reported seconds-per-pulse.
class Rates {
  static const int defaultSecondsPerPulse = 240;
  static const List<int> displayPulses = [1, 5, 10, 20];

  static int secondsFor(
    int pulses, {
    int secondsPerPulse = defaultSecondsPerPulse,
  }) {
    if (pulses < 0) throw ArgumentError.value(pulses, 'pulses');
    if (secondsPerPulse <= 0) {
      throw ArgumentError.value(secondsPerPulse, 'secondsPerPulse');
    }
    return pulses * secondsPerPulse;
  }

  /// "4 min", "1 h 20 min", or "4 min 30 s" for non-minute rates.
  static String describeDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    final parts = <String>[
      if (h > 0) '$h h',
      if (m > 0 || (h == 0 && s == 0)) '$m min',
      if (s > 0) '$s s',
    ];
    return parts.join(' ');
  }
}

/// Formats a duration as HH:MM:SS. Partial seconds round up so the display
/// shows 00:00:01 until time is really gone.
String formatHms(int milliseconds) {
  final total = milliseconds <= 0 ? 0 : (milliseconds + 999) ~/ 1000;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(h)}:${two(m)}:${two(s)}';
}
