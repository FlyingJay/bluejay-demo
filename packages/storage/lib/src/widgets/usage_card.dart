import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';

import '../format.dart';
import '../models.dart';
import '../storage_plan.dart';

/// The storage summary at the top of the screen: what the user has stored,
/// the group's plan, and for group admins the group's total and the user's
/// share of it.
class StorageUsageCard extends StatelessWidget {
  const StorageUsageCard({
    super.key,
    required this.userSummary,
    this.groupSummary,
    this.plan,
  });

  final StorageUsageSummary userSummary;

  /// Only set for group admins.
  final StorageUsageSummary? groupSummary;

  /// The group's Storage plan, once loaded.
  final StoragePlanStatus? plan;

  /// "Free tier · 12.5 GB of 50 GB", "Pay as you go", "Unlimited storage".
  static String planLabel(StoragePlanStatus? plan) {
    if (plan == null || plan.isUnlimited) return 'Unlimited storage';
    if (plan.isPayAsYouGo) return 'Pay as you go';
    return 'Free tier · ${formatBytes(plan.usageBytes, 1)} of '
        '${formatGb(plan.freeTierGb)}';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    // White on the hero gradient, as BjHeroCard's own text is.
    final onHero = Theme.of(context).colorScheme.onPrimary;
    final group = groupSummary;
    final share = group == null || group.totalBytes <= 0
        ? null
        : userSummary.totalBytes / group.totalBytes;
    return BjHeroCard(
      icon: Icons.cloud_done_rounded,
      title: '${formatBytes(userSummary.totalBytes)} stored',
      subtitle: '${filesLabel(userSummary.totalFiles)} · ${planLabel(plan)}',
      footer: group == null
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.groups_rounded, size: 18),
                  const SizedBox(width: BjSpace.sm),
                  Expanded(
                    child: Text(
                      'Group: ${formatBytes(group.totalBytes)} · '
                      '${filesLabel(group.totalFiles)}',
                      style: text.titleSmall?.copyWith(color: onHero),
                    ),
                  ),
                ]),
                if (share != null) ...[
                  const SizedBox(height: BjSpace.sm),
                  BjProgressBar(value: share, onDark: true),
                  const SizedBox(height: BjSpace.xs),
                  Text(
                    'Your files are ${(share * 100).clamp(0, 100).round()}% '
                    "of the group's storage",
                    style: text.bodySmall?.copyWith(color: onHero),
                  ),
                ],
              ],
            ),
    );
  }
}
