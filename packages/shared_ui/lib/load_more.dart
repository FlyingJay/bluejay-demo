import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:shared_services/live_window.dart';

/// Calls [onLoadMore] when the scrollable under [child] nears its far end:
/// the bottom of a normal list, the top of a `reverse: true` chat list.
///
/// [LiveWindow.loadMore] ignores repeat calls while a page is loading, so it
/// can be passed directly.
class LoadMoreOnScroll extends StatelessWidget {
  const LoadMoreOnScroll({
    super.key,
    required this.onLoadMore,
    required this.child,
    this.enabled = true,
    this.threshold = 400,
  });

  final VoidCallback onLoadMore;
  final Widget child;

  /// False when there is nothing more to load.
  final bool enabled;

  /// How close to the end, in pixels, the next page starts loading.
  final double threshold;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (enabled &&
            n.depth == 0 &&
            n.metrics.axis == Axis.vertical &&
            n.metrics.extentAfter < threshold) {
          onLoadMore();
        }
        return false;
      },
      child: child,
    );
  }
}

/// The row at the end of a paged list: a "Load more" button while
/// [hasMore], a spinner while [loading].
class LoadMoreButton extends StatelessWidget {
  const LoadMoreButton({
    super.key,
    required this.hasMore,
    required this.onLoadMore,
    this.loading = false,
    this.label = 'Load more',
  });

  /// The button for [window], rebuilt as it loads.
  static Widget forWindow(LiveWindow<dynamic> window,
          {String label = 'Load more'}) =>
      ListenableBuilder(
        listenable: window,
        builder: (context, _) => LoadMoreButton(
          hasMore: window.hasMore,
          loading: window.isLoadingMore,
          onLoadMore: window.loadMore,
          label: label,
        ),
      );

  final bool hasMore;
  final bool loading;
  final VoidCallback onLoadMore;
  final String label;

  @override
  Widget build(BuildContext context) {
    if (!hasMore && !loading) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: BjSpace.md),
      child: Center(
        child: loading
            ? const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : TextButton.icon(
                onPressed: onLoadMore,
                icon: const Icon(Icons.expand_more_rounded),
                label: Text(label),
              ),
      ),
    );
  }
}

/// A `ListView.builder` over a paged source: a [LoadMoreButton] after the
/// last item and [LoadMoreOnScroll] loading the next page as the reader
/// nears it.
///
/// With [reverse] (a chat, newest at the bottom), items run newest first and
/// the button sits at the top, past the oldest loaded item.
class PagedListView extends StatelessWidget {
  const PagedListView({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.hasMore,
    required this.onLoadMore,
    this.loading = false,
    this.loadMoreLabel = 'Load more',
    this.reverse = false,
    this.controller,
    this.padding,
  });

  /// A paged list over [window]'s current page.
  static Widget forWindow(
    LiveWindow<dynamic> window, {
    Key? key,
    required int itemCount,
    required IndexedWidgetBuilder itemBuilder,
    String loadMoreLabel = 'Load more',
    bool reverse = false,
    ScrollController? controller,
    EdgeInsetsGeometry? padding,
  }) =>
      PagedListView(
        key: key,
        itemCount: itemCount,
        itemBuilder: itemBuilder,
        hasMore: window.hasMore,
        loading: window.isLoadingMore,
        onLoadMore: window.loadMore,
        loadMoreLabel: loadMoreLabel,
        reverse: reverse,
        controller: controller,
        padding: padding,
      );

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final bool hasMore;
  final bool loading;
  final VoidCallback onLoadMore;
  final String loadMoreLabel;
  final bool reverse;
  final ScrollController? controller;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final showLoader = hasMore || loading;
    return LoadMoreOnScroll(
      enabled: hasMore,
      onLoadMore: onLoadMore,
      child: ListView.builder(
        controller: controller,
        reverse: reverse,
        padding: padding,
        itemCount: itemCount + (showLoader ? 1 : 0),
        itemBuilder: (context, index) => index == itemCount
            ? LoadMoreButton(
                hasMore: hasMore,
                loading: loading,
                onLoadMore: onLoadMore,
                label: loadMoreLabel,
              )
            : itemBuilder(context, index),
      ),
    );
  }
}
