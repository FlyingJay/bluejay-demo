import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';

import '../models.dart';

/// One tab's content: skeleton rows while loading, an error with a retry,
/// an empty state, or the files under a section header with a count, in
/// two columns on wide screens.
/// Every state can be pulled to refresh.
class FileTabBody extends StatelessWidget {
  const FileTabBody({
    super.key,
    required this.files,
    required this.rowBuilder,
    required this.onRefresh,
    required this.title,
    required this.emptyMessage,
    this.error,
    this.subtitle,
    this.emptyIcon = Icons.folder_open_rounded,
    this.emptyAction,
    this.header,
  });

  /// Null while loading.
  final List<SharedFile>? files;
  final Object? error;
  final Widget Function(SharedFile file) rowBuilder;
  final Future<void> Function() onRefresh;

  /// Section header over the files, e.g. "Your files".
  final String title;
  final String? subtitle;
  final String emptyMessage;
  final IconData emptyIcon;

  /// The obvious first step when the tab is empty, e.g. an upload button.
  final Widget? emptyAction;

  /// Shown above the files, and above the empty state: where the tab is in
  /// its folders.
  final Widget? header;

  Widget _withHeader(Widget body) => header == null
      ? body
      : Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(BjSpace.md, BjSpace.sm, BjSpace.md, 0),
            child: header,
          ),
          Expanded(child: body),
        ]);

  @override
  Widget build(BuildContext context) {
    final AsyncSnapshot<List<SharedFile>> snapshot = error != null
        ? AsyncSnapshot.withError(ConnectionState.done, error!)
        : files == null
            ? const AsyncSnapshot.waiting()
            : AsyncSnapshot.withData(ConnectionState.done, files!);
    return BjSnapshotView<List<SharedFile>>(
      snapshot: snapshot,
      errorTitle: "Couldn't load files",
      onRetry: onRefresh,
      isEmpty: (files) => files.isEmpty,
      empty: _withHeader(RefreshIndicator(
        onRefresh: onRefresh,
        child: BjStateView.empty(
          icon: emptyIcon,
          title: 'Nothing here yet',
          message: emptyMessage,
          action: emptyAction,
        ),
      )),
      // One column on phones, two once the screen is wide enough.
      builder: (files) => BjScrollBody(
        onRefresh: onRefresh,
        spacing: BjSpace.md,
        children: [
          if (header != null) header!,
          BjSectionHeader(title: title, subtitle: subtitle, count: files.length),
          ...BjResponsiveGrid.rows(
            context,
            [for (final f in files) rowBuilder(f)],
            minTileWidth: 420,
            maxColumns: 2,
          ),
        ],
      ),
    );
  }
}
