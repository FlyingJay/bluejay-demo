import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';

/// An app screen: transparent app bar over the soft accent canvas, with the
/// body free to scroll underneath. Pair with [BjScrollBody] or [BjContent]
/// so content keeps a readable width on desktop.
class BjPage extends StatelessWidget {
  const BjPage({
    super.key,
    required this.title,
    required this.body,
    this.subtitle,
    this.actions,
    this.leading,
    this.bottom,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    this.bottomBar,
    this.maxWidth = BjBreakpoint.pageWidth,
  });

  final String title;
  final String? subtitle;
  final Widget body;
  final List<Widget>? actions;
  final Widget? leading;
  final PreferredSizeWidget? bottom;
  final Widget? floatingActionButton;
  final FloatingActionButtonLocation? floatingActionButtonLocation;
  final Widget? bottomBar;

  /// Content width the header lines up with; match the body's.
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final width = MediaQuery.sizeOf(context).width;
    final side = bjPagePadding(width).left;
    // Line the title up with the centered content column on wide screens.
    final inset = width > maxWidth + side * 2 ? (width - maxWidth) / 2 : side;
    final canPop = ModalRoute.of(context)?.impliesAppBarDismissal ?? false;
    final lead = leading ?? (canPop ? const BackButton() : null);
    return DecoratedBox(
      decoration: BoxDecoration(gradient: context.bj.canvasGradient),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          automaticallyImplyLeading: false,
          titleSpacing: 0,
          toolbarHeight: subtitle == null ? kToolbarHeight : 64,
          title: Padding(
            padding: EdgeInsets.only(
                left: lead == null ? inset : (inset - 48).clamp(4, inset),
                right: (inset - 8).clamp(4, inset)),
            child: Row(children: [
              if (lead != null) ...[lead, const SizedBox(width: BjSpace.xs)],
              Expanded(
                child: subtitle == null
                    ? Text(title, overflow: TextOverflow.ellipsis)
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(title, overflow: TextOverflow.ellipsis),
                          Text(subtitle!,
                              style: text.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ],
                      ),
              ),
              ...?actions,
            ]),
          ),
          bottom: bottom,
        ),
        body: body,
        floatingActionButton: floatingActionButton,
        floatingActionButtonLocation: floatingActionButtonLocation,
        bottomNavigationBar: bottomBar,
      ),
    );
  }
}

/// Horizontal page padding for a given width: tighter on phones.
EdgeInsets bjPagePadding(double width) => EdgeInsets.symmetric(
      horizontal: BjBreakpoint.isCompact(width) ? BjSpace.md : BjSpace.xl,
    );

/// Centers [child] at [maxWidth] with responsive side padding. Takes its
/// child's height, so it also works in a [BjPage.bottomBar], which offers
/// the whole screen's height.
class BjContent extends StatelessWidget {
  const BjContent({
    super.key,
    required this.child,
    this.maxWidth = BjBreakpoint.pageWidth,
    this.padded = true,
  });

  final Widget child;
  final double maxWidth;
  final bool padded;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    // Padding outside the width cap, so content lines up with
    // BjScrollBody and the BjPage header at every width.
    final content = Align(
      alignment: Alignment.topCenter,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
    return padded
        ? Padding(padding: bjPagePadding(width), child: content)
        : content;
  }
}

/// A scrolling page body: children laid out at a readable width with
/// [spacing] between them, and room at the bottom for a FAB.
class BjScrollBody extends StatelessWidget {
  const BjScrollBody({
    super.key,
    required this.children,
    this.maxWidth = BjBreakpoint.pageWidth,
    this.spacing = BjSpace.lg,
    this.bottomInset = 96,
    this.onRefresh,
    this.controller,
  });

  final List<Widget> children;
  final double maxWidth;
  final double spacing;
  final double bottomInset;
  final Future<void> Function()? onRefresh;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final side = bjPagePadding(width).left;
    final extra = width > maxWidth + side * 2 ? (width - maxWidth) / 2 : side;
    final list = ListView.separated(
      controller: controller,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(extra, BjSpace.sm, extra, bottomInset),
      itemCount: children.length,
      separatorBuilder: (_, __) => SizedBox(height: spacing),
      itemBuilder: (_, i) => children[i],
    );
    return onRefresh == null
        ? list
        : RefreshIndicator(onRefresh: onRefresh!, child: list);
  }
}

/// List on the left, detail on the right once the screen is wide enough;
/// below [breakpoint] only [master] shows and callers push the detail.
class BjAdaptiveSplit extends StatelessWidget {
  const BjAdaptiveSplit({
    super.key,
    required this.master,
    required this.detail,
    this.breakpoint = BjBreakpoint.expanded,
    this.masterWidth = 380,
  });

  final Widget master;
  final Widget? detail;
  final double breakpoint;
  final double masterWidth;

  static bool isSplit(BuildContext context,
          [double breakpoint = BjBreakpoint.expanded]) =>
      MediaQuery.sizeOf(context).width >= breakpoint;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth < breakpoint) return master;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: masterWidth, child: master),
          const VerticalDivider(width: 1),
          Expanded(
            child: AnimatedSwitcher(
              duration: BjMotion.medium,
              switchInCurve: BjMotion.curve,
              child: detail ?? const SizedBox.shrink(),
            ),
          ),
        ],
      );
    });
  }
}

/// A section title with optional count, subtitle and trailing action.
class BjSectionHeader extends StatelessWidget {
  const BjSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.count,
    this.trailing,
    this.icon,
  });

  final String title;
  final String? subtitle;
  final int? count;
  final Widget? trailing;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final bj = context.bj;
    return Padding(
      padding: const EdgeInsets.only(top: BjSpace.xs, bottom: BjSpace.xs),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: bj.accent),
            const SizedBox(width: BjSpace.sm),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(title,
                        style: text.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis),
                  ),
                  if (count != null) ...[
                    const SizedBox(width: BjSpace.sm),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: BjSpace.sm, vertical: 1),
                      decoration: BoxDecoration(
                        color: bj.accentSoft,
                        borderRadius: BjRadius.all(BjRadius.pill),
                      ),
                      child: Text('$count',
                          style: text.labelSmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onPrimaryContainer)),
                    ),
                  ],
                ]),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(subtitle!, style: text.bodySmall),
                  ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// The width of the content column [BjContent] and [BjScrollBody] lay out
/// in, on a screen [screenWidth] wide.
double bjContentWidth(double screenWidth,
    {double maxWidth = BjBreakpoint.pageWidth}) {
  final inner = screenWidth - bjPagePadding(screenWidth).horizontal;
  return inner < maxWidth ? inner : maxWidth;
}

/// Cards in equal columns, as many as fit at [minTileWidth] (up to
/// [maxColumns]); one column on phones. Tiles in a row share a height, and
/// every tile gets a bounded height, so a card can push its footer down
/// with a [Spacer].
///
/// Inside a [BjScrollBody] with many tiles, spread [BjResponsiveGrid.rows]
/// into its children instead, so rows are built lazily as they scroll in.
class BjResponsiveGrid extends StatelessWidget {
  const BjResponsiveGrid({
    super.key,
    required this.children,
    this.minTileWidth = 340,
    this.maxColumns = 3,
    this.spacing = BjSpace.md,
  });

  final List<Widget> children;
  final double minTileWidth;
  final int maxColumns;
  final double spacing;

  /// How many columns of at least [minTileWidth] fit in [width].
  static int columnsFor(
    double width, {
    double minTileWidth = 340,
    int maxColumns = 3,
    double spacing = BjSpace.md,
  }) =>
      ((width + spacing) / (minTileWidth + spacing))
          .floor()
          .clamp(1, maxColumns < 1 ? 1 : maxColumns);

  /// [children] split into row widgets for a lazily built list such as
  /// [BjScrollBody], which puts its own spacing between them. Columns are
  /// worked out from the screen's content column ([bjContentWidth]).
  static List<Widget> rows(
    BuildContext context,
    List<Widget> children, {
    double minTileWidth = 340,
    int maxColumns = 3,
    double spacing = BjSpace.md,
    double maxWidth = BjBreakpoint.pageWidth,
  }) {
    final width = bjContentWidth(MediaQuery.sizeOf(context).width,
        maxWidth: maxWidth);
    return _rows(
      children,
      columnsFor(width,
          minTileWidth: minTileWidth, maxColumns: maxColumns, spacing: spacing),
      spacing,
    );
  }

  static List<Widget> _rows(
      List<Widget> children, int columns, double spacing) {
    return [
      for (var i = 0; i < children.length; i += columns)
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var j = 0; j < columns; j++) ...[
                if (j > 0) SizedBox(width: spacing),
                Expanded(
                  child: i + j < children.length
                      ? children[i + j]
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final rows = _rows(
        children,
        columnsFor(c.maxWidth,
            minTileWidth: minTileWidth,
            maxColumns: maxColumns,
            spacing: spacing),
        spacing,
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) SizedBox(height: spacing),
            rows[i],
          ],
        ],
      );
    });
  }
}

/// One tab in [BjSegmentedTabs].
class BjTab {
  const BjTab(this.label, {this.icon, this.count});

  final String label;
  final IconData? icon;

  /// A count shown in a small pill after the label (things waiting on that
  /// tab, say); hidden when null or 0, "99+" from 100.
  final int? count;
}

/// [BjTab.count]'s pill, in the tab label's colour.
class _TabCount extends StatelessWidget {
  const _TabCount(this.count);

  final int count;

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    final color = style.color ?? context.bj.inkMuted;
    return Container(
      constraints: const BoxConstraints(minWidth: 20),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BjRadius.all(BjRadius.pill),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: style.copyWith(fontSize: 12, fontWeight: FontWeight.w700, height: 1.3),
      ),
    );
  }
}

/// A rounded segmented control for switching tabs: the selected tab fills
/// with the accent gradient. Drives the nearest [DefaultTabController], or
/// [controller]. Wrap it in [BjContent] so it lines up with the page's
/// content column on wide screens. For tabs that stay pinned while the page
/// scrolls, use [BjPinnedTabs].
class BjSegmentedTabs extends StatelessWidget {
  const BjSegmentedTabs({
    super.key,
    required this.tabs,
    this.controller,
    this.maxWidth = 480,
  });

  final List<BjTab> tabs;
  final TabController? controller;
  final double maxWidth;

  /// Height of the control, including its border padding.
  static const double height = 44;

  @override
  Widget build(BuildContext context) {
    final bj = context.bj;
    final text = Theme.of(context).textTheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          padding: const EdgeInsets.all(BjSpace.xs),
          decoration: BoxDecoration(
            color: context.bj.surface,
            borderRadius: BjRadius.all(BjRadius.pill),
            border: Border.all(color: context.bj.border),
            boxShadow: bj.shadowSm,
          ),
          child: TabBar(
            controller: controller,
            dividerHeight: 0,
            indicatorSize: TabBarIndicatorSize.tab,
            splashBorderRadius: BjRadius.all(BjRadius.pill),
            indicator: BoxDecoration(
              gradient: bj.heroGradient,
              borderRadius: BjRadius.all(BjRadius.pill),
            ),
            labelColor: Theme.of(context).colorScheme.onPrimary,
            unselectedLabelColor: context.bj.inkMuted,
            labelStyle: text.labelLarge,
            unselectedLabelStyle: text.labelLarge,
            labelPadding: const EdgeInsets.symmetric(horizontal: BjSpace.xs),
            tabs: [
              for (final tab in tabs)
                Tab(
                  height: height - BjSpace.xs * 2,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (tab.icon != null) ...[
                        Icon(tab.icon, size: 18),
                        const SizedBox(width: BjSpace.xs + 2),
                      ],
                      Flexible(
                        child: Text(tab.label,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                      if ((tab.count ?? 0) > 0) ...[
                        const SizedBox(width: BjSpace.xs),
                        _TabCount(tab.count!),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// [BjSegmentedTabs] as a pinned sliver, for a `NestedScrollView` or
/// `CustomScrollView` whose header (a summary card, say) scrolls away while
/// the tabs stay. The tabs sit in the content column on an opaque band, so
/// content scrolls cleanly underneath, with a hairline once it does.
class BjPinnedTabs extends StatelessWidget {
  const BjPinnedTabs({super.key, required this.tabs, this.controller});

  final List<BjTab> tabs;
  final TabController? controller;

  @override
  Widget build(BuildContext context) {
    return SliverPersistentHeader(
      pinned: true,
      delegate: _PinnedTabsDelegate(
        tabs: tabs,
        controller: controller,
        background: Color.lerp(context.bj.accentWash, BjNeutral.canvas, 0.5)!,
      ),
    );
  }
}

class _PinnedTabsDelegate extends SliverPersistentHeaderDelegate {
  _PinnedTabsDelegate({
    required this.tabs,
    required this.controller,
    required this.background,
  });

  final List<BjTab> tabs;
  final TabController? controller;
  final Color background;

  static const double _height = BjSegmentedTabs.height + BjSpace.sm * 2;

  @override
  double get minExtent => _height;
  @override
  double get maxExtent => _height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    return AnimatedContainer(
      duration: BjMotion.medium,
      curve: BjMotion.curve,
      padding: const EdgeInsets.symmetric(vertical: BjSpace.sm),
      decoration: BoxDecoration(
        color: background,
        border: Border(
          bottom: BorderSide(color: overlaps ? context.bj.border : background),
        ),
      ),
      child: BjContent(
        child: BjSegmentedTabs(tabs: tabs, controller: controller),
      ),
    );
  }

  @override
  bool shouldRebuild(_PinnedTabsDelegate old) =>
      old.background != background ||
      old.controller != controller ||
      old.tabs != tabs;
}
