import 'package:flutter/material.dart';

import '../color.dart';
import '../theme.dart';
import '../tokens.dart';
import 'surfaces.dart' show BjStatusPill;

/// A date as `yyyy-mm-dd`: unambiguous in every locale and sorts as text.
/// The default format for [BjDuePill] and [BjDateField].
String bjFormatDate(DateTime date) {
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// A selectable label chip in a user-chosen [color]: a color dot and the
/// name when off; tinted in its own color with a check when on. Use it for
/// label filters and for picking an item's labels, where a plain
/// [FilterChip] would lose the label's color.
///
/// The selected text is darkened with [readableOn] until it reaches 4.5:1
/// on the tint, so any stored color stays readable.
class BjTagChip extends StatelessWidget {
  const BjTagChip({
    super.key,
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
    this.semanticLabel,
  });

  final String label;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;

  /// Replaces [label] for screen readers, e.g. "Urgent label filter".
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme.labelLarge;
    final tint = bjTint(color);
    final fg = selected ? readableOn(color, tint) : context.bj.ink;
    final shape = BjRadius.all(BjRadius.pill);
    return Semantics(
      label: semanticLabel,
      button: true,
      selected: selected,
      excludeSemantics: semanticLabel != null,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: shape,
          onTap: onTap,
          child: AnimatedContainer(
            duration: BjMotion.fast,
            curve: BjMotion.curve,
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: BjSpace.md),
            decoration: BoxDecoration(
              color: selected ? tint : context.bj.surface,
              borderRadius: shape,
              border: Border.all(
                color: selected ? color : context.bj.border,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              AnimatedSwitcher(
                duration: BjMotion.fast,
                transitionBuilder: (child, a) =>
                    ScaleTransition(scale: a, child: child),
                child: selected
                    ? Icon(Icons.check_rounded,
                        key: const ValueKey('on'), size: 16, color: fg)
                    : Container(
                        key: const ValueKey('off'),
                        width: 10,
                        height: 10,
                        decoration:
                            BoxDecoration(color: color, shape: BoxShape.circle),
                      ),
              ),
              const SizedBox(width: BjSpace.sm - 2),
              Text(label, style: text?.copyWith(color: fg)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A due-date pill: neutral normally, red and labelled "Overdue" once the
/// date has passed, unless [done]. Shows [emptyLabel] when there's no date.
class BjDuePill extends StatelessWidget {
  const BjDuePill({
    super.key,
    required this.due,
    this.done = false,
    this.emptyLabel = 'No due date',
    this.format = bjFormatDate,
    this.now,
  });

  final DateTime? due;

  /// Finished work is never overdue.
  final bool done;
  final String emptyLabel;
  final String Function(DateTime date) format;

  /// Today, for tests. Defaults to the clock.
  final DateTime? now;

  /// True when [due]'s date is before [now]'s date (the due day itself is
  /// not overdue).
  static bool isOverdue(DateTime? due, {DateTime? now}) {
    if (due == null) return false;
    final today = now ?? DateTime.now();
    return DateTime(due.year, due.month, due.day)
        .isBefore(DateTime(today.year, today.month, today.day));
  }

  @override
  Widget build(BuildContext context) {
    final date = due;
    if (date == null) {
      return BjStatusPill(label: emptyLabel, icon: Icons.event_busy_outlined);
    }
    final overdue = !done && isOverdue(date, now: now);
    return BjStatusPill(
      label: overdue ? 'Overdue ${format(date)}' : 'Due ${format(date)}',
      icon: overdue ? Icons.event_busy_rounded : Icons.event_rounded,
      tone: overdue ? BjTone.danger : BjTone.neutral,
    );
  }
}
