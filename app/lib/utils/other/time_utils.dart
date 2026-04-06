import 'package:omi/backend/preferences.dart';

/// Formats [dt] as HH:MM (24-hour) or H:MM AM/PM depending on the user's
/// `use24HourTime` preference.
String fmtHourMin(DateTime dt) {
  final use24 = SharedPreferencesUtil().use24HourTime;
  if (use24) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
  final hour12 = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
  final period = dt.hour < 12 ? 'AM' : 'PM';
  return '$hour12:${dt.minute.toString().padLeft(2, '0')} $period';
}

/// Rounds [dt] to the nearest minute (>=30s rounds up).
DateTime roundToMinute(DateTime dt) {
  if (dt.second >= 30) {
    return DateTime(dt.year, dt.month, dt.day, dt.hour, dt.minute).add(const Duration(minutes: 1));
  }
  return DateTime(dt.year, dt.month, dt.day, dt.hour, dt.minute);
}

String secondsToHumanReadable(int seconds) {
  if (seconds < 60) {
    return '$seconds ${seconds == 1 ? 'sec' : 'secs'}';
  } else if (seconds < 3600) {
    var minutes = (seconds / 60).floor();
    var remainingSeconds = seconds % 60;
    if (remainingSeconds == 0) {
      return '$minutes ${minutes == 1 ? 'min' : 'mins'}';
    }
    return '$minutes mins $remainingSeconds secs';
  } else if (seconds < 86400) {
    var hours = (seconds / 3600).floor();
    var remainingMinutes = (seconds % 3600 / 60).floor();
    if (remainingMinutes == 0) {
      return '$hours ${hours == 1 ? 'hour' : 'hours'}';
    }
    return '$hours hours $remainingMinutes mins';
  } else {
    var days = (seconds / 86400).floor();
    var remainingHours = (seconds % 86400 / 3600).floor();
    if (remainingHours == 0) {
      return '$days ${days == 1 ? 'day' : 'days'}';
    }
    return '$days days $remainingHours hours';
  }
}

String secondsToCompactDuration(int seconds) {
  if (seconds < 60) {
    return '${seconds}s';
  } else if (seconds < 3600) {
    var minutes = (seconds / 60).floor();
    var remainingSeconds = seconds % 60;
    if (remainingSeconds == 0 || minutes >= 10) {
      return '${minutes}m';
    }
    return '${minutes}m ${remainingSeconds}s';
  } else {
    var hours = (seconds / 3600).floor();
    var remainingMinutes = (seconds % 3600 / 60).floor();
    if (remainingMinutes == 0 || hours >= 10) {
      return '${hours}h';
    }
    return '${hours}h ${remainingMinutes}m';
  }
}

String secondsToHMS(int seconds) {
  var hours = (seconds / 3600).floor();
  var minutes = (seconds % 3600 / 60).floor();
  var remainingSeconds = seconds % 60;
  return '$hours:$minutes:$remainingSeconds';
}
