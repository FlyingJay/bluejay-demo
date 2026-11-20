import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';
import 'layout.dart';
import 'surfaces.dart';

/// A centered empty / error / locked state: icon well, title, message and
/// an optional action. Use instead of a bare `Center(Text('No … yet'))` or
/// `Text('Error: $e')`.
class BjStateView extends StatelessWidget {
  const BjStateView({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.tone,
    this.compact = false,
  });

  /// Nothing here yet. Pass [action] for the obvious first step.
  const BjStateView.empty({
    Key? key,
    required IconData icon,
    required String title,
    String? message,
    Widget? action,
    bool compact = false,
  }) : this(
          key: key,
          icon: icon,
          title: title,
          message: message,
          action: action,
          compact: compact,
        );

  /// No access, or a prerequisite (like picking a group) is missing.
  const BjStateView.locked({
    Key? key,
    required String title,
    String? message,
    Widget? action,
    IconData icon = Icons.lock_outline_rounded,
  }) : this(
          key: key,
          icon: icon,
          title: title,
          message: message,
          action: action,
          tone: BjTone.neutral,
        );

  /// Something failed. Shows a friendly line plus the error text, and a
  /// retry button when [onRetry] is set.
  factory BjStateView.error({
    Key? key,
    Object? error,
    String title = 'Something went wrong',
    String? message,
    VoidCallback? onRetry,
  }) =>
      BjStateView(
        key: key,
        icon: Icons.cloud_off_rounded,
        title: title,
        message: message ?? (error == null ? null : _describe(error)),
        tone: BjTone.danger,
        action: onRetry == null
            ? null
            : OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Try again'),
              ),
      );

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  final BjTone? tone;

  /// Inline variant for inside a card or section, with less padding.
  final bool compact;

  static String _describe(Object error) {
    final s = error.toString();
    if (s.contains('permission-denied') || s.contains('PERMISSION_DENIED')) {
      return "You don't have access to this. Ask a group admin if you think you should.";
    }
    if (s.contains('unavailable') || s.contains('network')) {
      return "Couldn't reach the server. Check your connection and try again.";
    }
    return s.replaceFirst(RegExp(r'^\[[^\]]+\]\s*'), '');
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final content = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          BjIconWell(icon: icon, size: compact ? 48 : 64, tone: tone),
          SizedBox(height: compact ? BjSpace.md : BjSpace.lg),
          Text(title,
              style: compact ? text.titleMedium : text.titleLarge,
              textAlign: TextAlign.center),
          if (message != null) ...[
            const SizedBox(height: BjSpace.xs + 2),
            Text(message!,
                style: text.bodyMedium?.copyWith(color: context.bj.inkMuted),
                textAlign: TextAlign.center),
          ],
          if (action != null) ...[
            SizedBox(height: compact ? BjSpace.md : BjSpace.xl),
            action!,
          ],
        ],
      ),
    );
    final padded = Padding(
      padding: EdgeInsets.all(compact ? BjSpace.lg : BjSpace.xxl),
      child: content,
    );
    if (compact) return Center(child: padded);
    return LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(
              minHeight: c.maxHeight.isFinite ? c.maxHeight * 0.8 : 0,
              minWidth: c.maxWidth.isFinite ? c.maxWidth : 0),
          child: Center(child: padded),
        ),
      ),
    );
  }
}

/// A shimmering placeholder block.
class BjSkeleton extends StatefulWidget {
  const BjSkeleton({
    super.key,
    this.width,
    this.height = 14,
    this.radius = BjRadius.sm,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  State<BjSkeleton> createState() => _BjSkeletonState();
}

class _BjSkeletonState extends State<BjSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = context.bj.surfaceMuted;
    final shine = Color.lerp(base, context.bj.surface, 0.7)!;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        final t = _c.value * 3 - 1;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BjRadius.all(widget.radius),
            gradient: LinearGradient(
              begin: Alignment(t - 1, 0),
              end: Alignment(t + 1, 0),
              colors: [base, shine, base],
            ),
          ),
        );
      },
    );
  }
}

/// Skeleton rows shaped like [BjListRow]s, for first loads of a list.
class BjSkeletonList extends StatelessWidget {
  const BjSkeletonList({super.key, this.count = 4, this.shrinkWrap = false});

  final int count;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    final rows = List.generate(
      count,
      (i) => BjCard(
        child: Row(children: [
          const BjSkeleton(width: 40, height: 40, radius: 12),
          const SizedBox(width: BjSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FractionallySizedBox(
                    widthFactor: i.isEven ? 0.55 : 0.4,
                    child: const BjSkeleton(height: 14)),
                const SizedBox(height: BjSpace.sm),
                FractionallySizedBox(
                    widthFactor: i.isEven ? 0.8 : 0.7,
                    child: const BjSkeleton(height: 11)),
              ],
            ),
          ),
        ]),
      ),
    );
    final column = Column(
      children: [
        for (final r in rows) ...[r, const SizedBox(height: BjSpace.md)],
      ],
    );
    if (shrinkWrap) return column;
    return BjScrollPad(child: column);
  }
}

/// Lays a non-scrolling child out like [BjScrollBody] content: readable
/// width, page padding, scrollable if it overflows.
class BjScrollPad extends StatelessWidget {
  const BjScrollPad({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: BjSpace.sm),
      child: BjContent(child: child),
    );
  }
}

/// Renders an [AsyncSnapshot] with the standard loading, error and empty
/// states, so no screen spins forever on an error or shows raw exceptions.
///
/// ```dart
/// StreamBuilder<List<Item>>(
///   stream: items,
///   builder: (context, snap) => BjSnapshotView(
///     snapshot: snap,
///     isEmpty: (items) => items.isEmpty,
///     empty: const BjStateView.empty(icon: Icons.inbox, title: 'No items yet'),
///     builder: (items) => ItemList(items),
///   ),
/// )
/// ```
class BjSnapshotView<T> extends StatelessWidget {
  const BjSnapshotView({
    super.key,
    required this.snapshot,
    required this.builder,
    this.isEmpty,
    this.empty,
    this.loading,
    this.onRetry,
    this.errorTitle,
  });

  final AsyncSnapshot<T> snapshot;
  final Widget Function(T data) builder;
  final bool Function(T data)? isEmpty;
  final Widget? empty;
  final Widget? loading;
  final VoidCallback? onRetry;
  final String? errorTitle;

  @override
  Widget build(BuildContext context) {
    final Widget child;
    if (snapshot.hasError) {
      child = BjStateView.error(
        error: snapshot.error,
        onRetry: onRetry,
        title: errorTitle ?? 'Something went wrong',
      );
    } else if (!snapshot.hasData) {
      child = loading ?? const BjSkeletonList();
    } else {
      final data = snapshot.data as T;
      child = (isEmpty != null && empty != null && isEmpty!(data))
          ? empty!
          : builder(data);
    }
    return AnimatedSwitcher(
      duration: BjMotion.medium,
      switchInCurve: BjMotion.curve,
      child: KeyedSubtree(
        key: ValueKey(snapshot.hasError
            ? 'error'
            : !snapshot.hasData
                ? 'loading'
                : 'data'),
        child: child,
      ),
    );
  }
}
