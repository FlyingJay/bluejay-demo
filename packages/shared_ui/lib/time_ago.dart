/// Short relative times ("5m ago") for lists and timelines.
library;

/// Formats [ts] as a short relative time ("5m ago", "3w ago").
String formatTimeAgo(DateTime ts, {DateTime? now}) {
  final difference = (now ?? DateTime.now()).difference(ts);
  if (difference.inSeconds < 60) return '${difference.inSeconds}s ago';
  if (difference.inMinutes < 60) return '${difference.inMinutes}m ago';
  if (difference.inHours < 24) return '${difference.inHours}h ago';
  if (difference.inDays < 7) return '${difference.inDays}d ago';
  if (difference.inDays < 30) return '${(difference.inDays / 7).floor()}w ago';
  if (difference.inDays < 365) {
    return '${(difference.inDays / 30).floor()}mo ago';
  }
  return '${(difference.inDays / 365).floor()}y ago';
}
