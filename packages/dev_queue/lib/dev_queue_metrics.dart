// The `devQueueMetrics` result (PHASE_2_5_DESIGN.md 4.5), parsed
// default-safe like the rest of the queue's callable results.

/// Shipped items in one Monday-start week, in the queue's time zone
/// (platform_config/dev_queue.timeZone, default America/Toronto).
class DevMetricsWeek {
  /// `YYYY-MM-DD` as the server sends it.
  final String weekStart;
  final int shipped;

  const DevMetricsWeek({required this.weekStart, this.shipped = 0});

  /// [weekStart] as a local calendar date, or null when malformed.
  DateTime? get start {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(weekStart);
    if (match == null) return null;
    return DateTime(int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!));
  }
}

/// Time from first start to live for one size.
class DevMetricsSize {
  /// 'S', 'M', 'L' or 'unsized'.
  final String size;

  /// The business days the size's estimate promises; null when it has none
  /// (Large is set at review).
  final num? targetDays;
  final num? medianBusinessDays;
  final int count;

  const DevMetricsSize({required this.size, this.targetDays, this.medianBusinessDays, this.count = 0});
}

/// An item over its stall threshold right now.
class DevMetricsStalledItem {
  final String itemKey;
  final String title;
  final String state;
  final DateTime? since;
  final num? thresholdDays;

  const DevMetricsStalledItem({
    required this.itemKey,
    this.title = '',
    this.state = '',
    this.since,
    this.thresholdDays,
  });

  /// `bug__abc` → (`bug`, `abc`).
  (String, String)? get ticket {
    final i = itemKey.indexOf('__');
    if (i <= 0 || i + 2 >= itemKey.length) return null;
    return (itemKey.substring(0, i), itemKey.substring(i + 2));
  }
}

/// What one platform source (advisor rounds, the spare-capacity worker,
/// Security Audit) shipped in the window.
class DevMetricsPlatformSource {
  /// The server's id for the source, e.g. `advisor-round`.
  final String source;
  final String label;
  final int shipped;

  const DevMetricsPlatformSource({required this.source, this.label = '', this.shipped = 0});
}

class DevQueueMetrics {
  /// Customers' requests shipped per week; the platform's own work is in
  /// [platformWeeks].
  final List<DevMetricsWeek> weeks;
  final List<DevMetricsSize> bySize;
  final int stalledCount;
  final List<DevMetricsStalledItem> stalled;
  final int stallRateShipped;
  final int stallRateStalled;

  /// The platform's own work shipped per week, the same weeks as [weeks].
  final List<DevMetricsWeek> platformWeeks;

  /// The platform's shipped work by what filed it, most first.
  final List<DevMetricsPlatformSource> platformBySource;

  const DevQueueMetrics({
    this.weeks = const [],
    this.bySize = const [],
    this.stalledCount = 0,
    this.stalled = const [],
    this.stallRateShipped = 0,
    this.stallRateStalled = 0,
    this.platformWeeks = const [],
    this.platformBySource = const [],
  });

  factory DevQueueMetrics.fromResult(Object? raw) {
    final data = _map(raw);
    final stalledNow = _map(data['stalledNow']);
    final stallRate = _map(data['stallRate']);
    final platform = _map(data['platform']);
    List<DevMetricsWeek> weeksOf(Object? raw) => _list(raw).map((e) {
          final m = _map(e);
          return DevMetricsWeek(weekStart: _str(m['weekStart']), shipped: _num(m['shipped'])?.toInt() ?? 0);
        }).toList();
    final stalledItems = _list(stalledNow['items']).map((e) {
      final m = _map(e);
      return DevMetricsStalledItem(
        itemKey: _str(m['itemKey']),
        title: _str(m['title']),
        state: _str(m['state']),
        since: _date(m['since']),
        thresholdDays: _num(m['thresholdDays']),
      );
    }).where((i) => i.itemKey.isNotEmpty).toList();
    return DevQueueMetrics(
      weeks: weeksOf(data['weeks']),
      bySize: _list(data['bySize']).map((e) {
        final m = _map(e);
        return DevMetricsSize(
          size: _str(m['size']),
          targetDays: _num(m['targetDays']),
          medianBusinessDays: _num(m['medianBusinessDays']),
          count: _num(m['count'])?.toInt() ?? 0,
        );
      }).where((s) => s.size.isNotEmpty).toList(),
      stalledCount: _num(stalledNow['count'])?.toInt() ?? stalledItems.length,
      stalled: stalledItems,
      stallRateShipped: _num(stallRate['shipped'])?.toInt() ?? 0,
      stallRateStalled: _num(stallRate['stalled'])?.toInt() ?? 0,
      platformWeeks: weeksOf(platform['weeks']),
      platformBySource: _list(platform['bySource']).map((e) {
        final m = _map(e);
        final source = _str(m['source']);
        return DevMetricsPlatformSource(
          source: source,
          label: _str(m['label']).isEmpty ? source : _str(m['label']),
          shipped: _num(m['shipped'])?.toInt() ?? 0,
        );
      }).where((s) => s.source.isNotEmpty).toList(),
    );
  }

  int get totalShipped => weeks.fold(0, (sum, w) => sum + w.shipped);

  int get platformShipped => platformWeeks.fold(0, (sum, w) => sum + w.shipped);

  /// Nothing shipped in the window: the metrics tab shows its empty state.
  bool get isEmpty => totalShipped == 0 && platformShipped == 0 && stallRateShipped == 0 && stalledCount == 0;

  /// Whole-number percent of shipped items that stalled, computed here from
  /// the counts so the server's `rate` (fraction or percent) can't be
  /// misread. 0 when nothing shipped.
  int get stallRatePercent =>
      stallRateShipped <= 0 ? 0 : ((stallRateStalled / stallRateShipped) * 100).round();
}

// ── Readers ─────────────────────────────────────────────────────────────────

Map<String, dynamic> _map(Object? raw) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) return raw.map((k, v) => MapEntry(k.toString(), v));
  return const {};
}

List<Object?> _list(Object? raw) => raw is List ? raw : const [];

String _str(Object? raw) => raw is String ? raw.trim() : '';

num? _num(Object? raw) {
  if (raw is num && raw.isFinite) return raw;
  if (raw is String) return num.tryParse(raw.trim());
  return null;
}

DateTime? _date(Object? raw) {
  if (raw is DateTime) return raw;
  if (raw is String && raw.trim().isNotEmpty) return DateTime.tryParse(raw.trim())?.toLocal();
  if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
  if (raw is Map) {
    final seconds = raw['_seconds'] ?? raw['seconds'];
    if (seconds is num) return DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
  }
  return null;
}
