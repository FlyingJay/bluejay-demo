import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';

/// The Storage screen's frame, free of any data access: title and refresh,
/// the usage summary (which scrolls away), the Public / My Files / Shared
/// tabs (which stay pinned) and the upload button. Expects a
/// [DefaultTabController] with as many tabs as [labels] above it.
class StorageLayout extends StatelessWidget {
  const StorageLayout({
    super.key,
    required this.tabs,
    required this.onRefresh,
    this.onOpenPlan,
    this.usage,
    this.uploadButton,
    this.labels = tabLabels,
  });

  /// Public, My Files, Shared, in that order, then any [labels] add.
  final List<Widget> tabs;
  final List<BjTab> labels;
  final VoidCallback onRefresh;

  /// Opens the group's Storage plan; no button when null.
  final VoidCallback? onOpenPlan;
  final Widget? usage;
  final Widget? uploadButton;

  static const tabLabels = [
    BjTab('Public', icon: Icons.public_rounded),
    BjTab('My Files', icon: Icons.folder_rounded),
    BjTab('Shared', icon: Icons.people_alt_rounded),
  ];

  /// With the tab of files the group's portal clients sent.
  static const tabLabelsWithClients = [
    ...tabLabels,
    BjTab('From clients', icon: Icons.storefront_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    return BjPage(
      title: 'Storage',
      actions: [
        if (onOpenPlan != null)
          IconButton(
            icon: const Icon(Icons.data_usage_rounded),
            tooltip: 'Storage plan',
            onPressed: onOpenPlan,
          ),
        IconButton(
          icon: const Icon(Icons.refresh_rounded),
          tooltip: 'Refresh',
          onPressed: onRefresh,
        ),
      ],
      floatingActionButton: uploadButton,
      body: NestedScrollView(
        headerSliverBuilder: (context, _) => [
          if (usage != null)
            SliverToBoxAdapter(
              child: Padding(
                padding:
                    const EdgeInsets.only(top: BjSpace.sm, bottom: BjSpace.md),
                child: BjContent(child: usage!),
              ),
            ),
          BjPinnedTabs(tabs: labels),
        ],
        body: TabBarView(children: tabs),
      ),
    );
  }
}
