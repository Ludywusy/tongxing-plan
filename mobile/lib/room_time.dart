/// Converts instants to and from the room's fixed Asia/Shanghai wall clock.
///
/// Room timestamps are stored as UTC instants internally. Keeping the room
/// offset explicit makes display and picker behavior independent of the
/// Android device's configured time zone.
class RoomTime {
  RoomTime._();

  static const Duration _roomOffset = Duration(hours: 8);

  static DateTime parse(String value) {
    if (!RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(value)) {
      throw const FormatException('时间必须包含时区偏移。');
    }
    return DateTime.parse(value).toUtc();
  }

  static DateTime toWallTime(DateTime instant) {
    final shifted = instant.toUtc().add(_roomOffset);
    return DateTime.utc(
      shifted.year,
      shifted.month,
      shifted.day,
      shifted.hour,
      shifted.minute,
      shifted.second,
      shifted.millisecond,
      shifted.microsecond,
    );
  }

  static DateTime fromWallTime(DateTime wallTime) => DateTime.utc(
    wallTime.year,
    wallTime.month,
    wallTime.day,
    wallTime.hour,
    wallTime.minute,
    wallTime.second,
    wallTime.millisecond,
    wallTime.microsecond,
  ).subtract(_roomOffset);

  static String toIso8601(DateTime instant) {
    final wall = toWallTime(instant);
    final year = wall.year.toString().padLeft(4, '0');
    final month = wall.month.toString().padLeft(2, '0');
    final day = wall.day.toString().padLeft(2, '0');
    final hour = wall.hour.toString().padLeft(2, '0');
    final minute = wall.minute.toString().padLeft(2, '0');
    final second = wall.second.toString().padLeft(2, '0');
    return '$year-$month-$day'
        'T$hour:$minute:$second+08:00';
  }

  static String format(DateTime instant) {
    final wall = toWallTime(instant);
    return '${wall.month}月${wall.day}日 '
        '${wall.hour.toString().padLeft(2, '0')}:'
        '${wall.minute.toString().padLeft(2, '0')}';
  }
}
