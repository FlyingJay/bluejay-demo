/// How much groups want an app: the counts in `app_demand/{appId}`
/// (functions/_app_demand.js), as `appStewardList` and `appDemandList` return
/// them. Add Apps' Stewarded apps tab and App Manager's demand badge both
/// show these, so the parsing and the wording live here once.
class AppDemandCounts {
  /// Open Add Apps install requests, one per group.
  final int openRequests;

  /// Upvotes on those requests, requesters' own included.
  final int openRequestVotes;

  /// Open tier-upgrade tickets by target tier.
  final Map<String, int> tierUpgradesByTier;

  const AppDemandCounts({
    this.openRequests = 0,
    this.openRequestVotes = 0,
    this.tierUpgradesByTier = const {},
  });

  /// Reads one demand doc. `tierUpgrades` is a map of tier to count on the
  /// server; a bare number is read as a total. Missing or malformed counts
  /// read as zero.
  factory AppDemandCounts.fromData(Object? data) {
    final m = data is Map ? data : const {};
    int count(Object? value) => value is num && value > 0 ? value.toInt() : 0;
    final upgrades = m['tierUpgrades'];
    return AppDemandCounts(
      openRequests: count(m['openRequests']),
      openRequestVotes: count(m['openRequestVotes']),
      tierUpgradesByTier: upgrades is Map
          ? {
              for (final entry in upgrades.entries)
                if (entry.key is String && count(entry.value) > 0) entry.key as String: count(entry.value),
            }
          : (count(upgrades) > 0 ? {'': count(upgrades)} : const {}),
    );
  }

  /// Open tier-upgrade tickets across every target tier.
  int get tierUpgrades => tierUpgradesByTier.values.fold(0, (sum, n) => sum + n);

  bool get isEmpty => openRequests == 0 && openRequestVotes == 0 && tierUpgrades == 0;

  /// The non-zero counts in one short line, for example
  /// "2 requests · 5 votes · 1 tier upgrade"; '' when every count is zero.
  String get summary => [
        if (openRequests > 0) _plural(openRequests, 'request'),
        if (openRequestVotes > 0) _plural(openRequestVotes, 'vote'),
        if (tierUpgrades > 0) _plural(tierUpgrades, 'tier upgrade'),
      ].join(' · ');
}

String _plural(int n, String noun) => n == 1 ? '1 $noun' : '$n ${noun}s';

/// `appDemandList`'s result as demand counts by app id. Reads
/// `{demand: [{appId, ...counts}]}`; entries without an app id are skipped.
Map<String, AppDemandCounts> appDemandByAppId(Object? data) {
  final list = data is Map ? data['demand'] : data;
  if (list is! List) return const {};
  return {
    for (final entry in list)
      if (entry is Map && entry['appId'] is String && (entry['appId'] as String).isNotEmpty)
        entry['appId'] as String: AppDemandCounts.fromData(entry),
  };
}
