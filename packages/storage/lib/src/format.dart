import 'dart:math';

/// A byte count as "1.50 MB".
String formatBytes(int bytes, [int decimals = 2]) {
  if (bytes <= 0) return '0 B';
  const suffixes = ['B', 'KB', 'MB', 'GB', 'TB', 'PB', 'EB', 'ZB', 'YB'];
  final i = (log(bytes) / log(1024)).floor();
  return '${(bytes / pow(1024, i)).toStringAsFixed(decimals)} ${suffixes[i]}';
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// A short date for file rows: "Nov 10", with the year ("Nov 10, 2025")
/// when it isn't [now]'s year.
String formatDateShort(DateTime date, {DateTime? now}) {
  final day = '${_months[date.month - 1]} ${date.day}';
  return date.year == (now ?? DateTime.now()).year ? day : '$day, ${date.year}';
}

/// The full upload time for the details dialog: "2026-11-10 14:05".
String formatDateTime(DateTime date) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} '
      '${two(date.hour)}:${two(date.minute)}';
}

/// "1 file", "3 files".
String filesLabel(int count) => count == 1 ? '1 file' : '$count files';
