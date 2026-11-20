import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';

/// One label and value, side by side: a muted fixed-width label and the
/// value beside it. Pass [value] for text or [child] for anything else (a
/// pill, a link). Stack them in a [BjDetailTable].
class BjKeyValue extends StatelessWidget {
  const BjKeyValue({
    super.key,
    required this.label,
    this.value,
    this.child,
    this.labelWidth = 112,
  }) : assert(value != null || child != null,
            'BjKeyValue needs a value or a child');

  final String label;
  final String? value;
  final Widget? child;

  /// Width of the label column; keep it the same within one table.
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: labelWidth,
          child: Text(label,
              style: text.labelMedium?.copyWith(color: context.bj.inkMuted)),
        ),
        Expanded(child: child ?? Text(value!, style: text.bodyMedium)),
      ],
    );
  }
}

/// A label/value table for a record's details (type, size, owner, dates),
/// in place of a column of hand-aligned `Row`s.
///
/// ```dart
/// BjDetailTable(rows: [
///   BjKeyValue(label: 'Type', value: 'PDF'),
///   BjKeyValue(label: 'Size', value: '2.0 MB'),
/// ])
/// ```
class BjDetailTable extends StatelessWidget {
  const BjDetailTable({super.key, required this.rows});

  final List<BjKeyValue> rows;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: BjSpace.xs),
            child: row,
          ),
      ],
    );
  }
}

/// A muted one-line note on a soft background, for "nothing here yet" and
/// short hints inside forms and cards, where a full [BjStateView] would be
/// too much. Pass [tone] for an inline error or warning.
class BjInlineNote extends StatelessWidget {
  const BjInlineNote(this.text, {super.key, this.icon, this.tone});

  final String text;

  /// Defaults to an info icon.
  final IconData? icon;
  final BjTone? tone;

  @override
  Widget build(BuildContext context) {
    final t = tone == null ? null : context.bj.tone(tone!);
    final style = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: t?.foreground ?? context.bj.inkMuted);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
          horizontal: BjSpace.md, vertical: BjSpace.sm + 2),
      decoration: BoxDecoration(
        color: t?.background ?? context.bj.surfaceMuted,
        borderRadius: BjRadius.all(BjRadius.md),
      ),
      child: Row(children: [
        Icon(icon ?? Icons.info_outline_rounded, size: 16, color: style?.color),
        const SizedBox(width: BjSpace.sm),
        Expanded(child: Text(text, style: style)),
      ]),
    );
  }
}
