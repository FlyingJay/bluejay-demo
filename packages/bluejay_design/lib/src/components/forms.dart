import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';
import 'chips.dart' show bjFormatDate;
import 'surfaces.dart' show BjCard, BjIconWell;

/// A titled group of form fields on a card, with even spacing between
/// fields.
class BjFormSection extends StatelessWidget {
  const BjFormSection({
    super.key,
    required this.children,
    this.title,
    this.description,
    this.icon,
    this.spacing = BjSpace.md,
  });

  final String? title;
  final String? description;
  final IconData? icon;
  final List<Widget> children;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return BjCard(
      padding: const EdgeInsets.all(BjSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null) ...[
            Row(children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: context.bj.accent),
                const SizedBox(width: BjSpace.sm),
              ],
              Expanded(child: Text(title!, style: text.titleMedium)),
            ]),
            if (description != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(description!, style: text.bodySmall),
              ),
            const SizedBox(height: BjSpace.lg),
          ],
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) SizedBox(height: spacing),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// One labelled set of chips in a [BjFilterBar], e.g. "Status" or "Tags".
class BjFilterGroup {
  const BjFilterGroup({
    required this.label,
    required this.filters,
    this.icon,
    this.placeholder,
  });

  final String label;
  final IconData? icon;
  final List<Widget> filters;

  /// Shown instead of the chips when [filters] is empty, e.g. a
  /// [BjInlineNote] saying there's nothing to filter by yet.
  final Widget? placeholder;
}

/// A search field with filter chips under it. Chips scroll horizontally on
/// phones and wrap on wider screens.
///
/// Pass [filters] for one unlabelled row, or [groups] for several labelled
/// rows (label beside the chips when there's room, above them otherwise).
class BjFilterBar extends StatelessWidget {
  const BjFilterBar({
    super.key,
    this.onSearchChanged,
    this.searchController,
    this.searchHint = 'Search',
    this.filters = const [],
    this.groups = const [],
    this.groupLabelWidth = 84,
    this.trailing,
  });

  final ValueChanged<String>? onSearchChanged;
  final TextEditingController? searchController;
  final String searchHint;
  final List<Widget> filters;
  final List<BjFilterGroup> groups;

  /// Width of the label column when labels sit beside their chips.
  final double groupLabelWidth;
  final Widget? trailing;

  bool get _hasSearch => onSearchChanged != null || searchController != null;

  Widget _chips(List<Widget> chips, bool compact) => compact
      ? SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final f in chips) ...[
              f,
              const SizedBox(width: BjSpace.sm),
            ],
          ]),
        )
      : Wrap(
          spacing: BjSpace.sm,
          runSpacing: BjSpace.sm,
          children: chips,
        );

  Widget _group(BuildContext context, BjFilterGroup g, bool compact) {
    final style = Theme.of(context)
        .textTheme
        .labelMedium
        ?.copyWith(color: context.bj.inkMuted);
    final heading = Row(mainAxisSize: MainAxisSize.min, children: [
      if (g.icon != null) ...[
        Icon(g.icon, size: 16, color: context.bj.inkSubtle),
        const SizedBox(width: BjSpace.xs + 2),
      ],
      Flexible(
          child: Text(g.label, style: style, overflow: TextOverflow.ellipsis)),
    ]);
    final body = g.filters.isEmpty
        ? g.placeholder ?? const SizedBox.shrink()
        : _chips(g.filters, compact);
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth < BjBreakpoint.medium) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          heading,
          const SizedBox(height: BjSpace.sm),
          body,
        ]);
      }
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: groupLabelWidth,
          // Centers the label on the first line of chips.
          child: Padding(
              padding: const EdgeInsets.only(top: BjSpace.sm + 1),
              child: heading),
        ),
        Expanded(child: body),
      ]);
    });
  }

  @override
  Widget build(BuildContext context) {
    final compact = BjBreakpoint.isCompact(MediaQuery.sizeOf(context).width);
    final rows = [
      if (filters.isNotEmpty) _chips(filters, compact),
      for (final g in groups) _group(context, g, compact),
    ];
    final chips = rows.isEmpty
        ? null
        : rows.length == 1
            ? rows.single
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    if (i > 0) const SizedBox(height: BjSpace.md),
                    rows[i],
                  ],
                ],
              );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_hasSearch || trailing != null)
          Row(children: [
            if (_hasSearch)
              Expanded(
                child: TextField(
                  controller: searchController,
                  onChanged: onSearchChanged,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: searchHint,
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    border: OutlineInputBorder(
                      borderRadius: BjRadius.all(BjRadius.pill),
                      borderSide: BorderSide(color: context.bj.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BjRadius.all(BjRadius.pill),
                      borderSide: BorderSide(color: context.bj.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BjRadius.all(BjRadius.pill),
                      borderSide:
                          BorderSide(color: context.bj.accent, width: 1.6),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: BjSpace.lg, vertical: BjSpace.sm + 2),
                  ),
                ),
              )
            else
              const Spacer(),
            if (trailing != null) ...[
              const SizedBox(width: BjSpace.sm),
              trailing!,
            ],
          ]),
        if (chips != null) ...[
          if (_hasSearch || trailing != null)
            const SizedBox(height: BjSpace.md),
          chips,
        ],
      ],
    );
  }
}

/// A small heading over a form field or group of controls (chips, a date
/// field, a picker) that has no built-in label, with an optional helper
/// line under it.
class BjFieldLabel extends StatelessWidget {
  const BjFieldLabel(this.label, {super.key, this.helper, this.icon});

  final String label;
  final String? helper;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: BjSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: context.bj.accent),
              const SizedBox(width: BjSpace.xs + 2),
            ],
            Flexible(child: Text(label, style: text.titleSmall)),
          ]),
          if (helper != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(helper!, style: text.bodySmall),
            ),
        ],
      ),
    );
  }
}

/// An optional date: the chosen date (or [emptyLabel]), a button that opens
/// the date picker, and a clear button once a date is set.
class BjDateField extends StatelessWidget {
  const BjDateField({
    super.key,
    required this.value,
    required this.onChanged,
    this.emptyLabel = 'No date selected',
    this.prefix = 'Due',
    this.format = bjFormatDate,
    this.firstDate,
    this.lastDate,
  });

  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final String emptyLabel;

  /// Shown before the date, e.g. "Due 2026-11-28". Empty for none.
  final String prefix;
  final String Function(DateTime date) format;

  /// Picker bounds; default 2000 to 2100.
  final DateTime? firstDate;
  final DateTime? lastDate;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final date = value;
    final label = date == null
        ? emptyLabel
        : prefix.isEmpty
            ? format(date)
            : '$prefix ${format(date)}';
    return Container(
      padding: const EdgeInsets.fromLTRB(
          BjSpace.md, BjSpace.xs, BjSpace.xs, BjSpace.xs),
      decoration: BoxDecoration(
        color: context.bj.surfaceMuted,
        borderRadius: BjRadius.all(BjRadius.md),
      ),
      child: Row(children: [
        Icon(date == null ? Icons.event_busy_outlined : Icons.event_rounded,
            size: 20,
            color: date == null ? context.bj.inkSubtle : context.bj.accent),
        const SizedBox(width: BjSpace.sm),
        Expanded(
          child: Text(
            label,
            style: text.bodyMedium?.copyWith(
                color: date == null ? context.bj.inkMuted : context.bj.ink),
          ),
        ),
        if (date != null)
          IconButton(
            tooltip: 'Clear date',
            onPressed: () => onChanged(null),
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        TextButton(
          onPressed: () async {
            final picked = await showDatePicker(
              context: context,
              firstDate: firstDate ?? DateTime(2000),
              lastDate: lastDate ?? DateTime(2100),
              initialDate: date ?? DateTime.now(),
            );
            if (picked != null) onChanged(picked);
          },
          child: Text(date == null ? 'Pick date' : 'Change'),
        ),
      ]),
    );
  }
}

/// One choice in a [BjOptionCards] group.
class BjOption<T> {
  const BjOption({
    required this.value,
    required this.title,
    this.description,
    this.icon,
    this.tone,
  });

  final T value;
  final String title;

  /// What picking this means, in a sentence.
  final String? description;
  final IconData? icon;

  /// Tints the icon well; null uses the accent.
  final BjTone? tone;
}

/// A selectable card for one option: icon, title and a line saying what it
/// means, with a check once selected. Group them with [BjOptionCards].
class BjOptionCard extends StatelessWidget {
  const BjOptionCard({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.description,
    this.icon,
    this.tone,
  });

  final String title;
  final String? description;
  final IconData? icon;
  final BjTone? tone;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return BjCard(
      selected: selected,
      onTap: onTap,
      padding: const EdgeInsets.all(BjSpace.md),
      child: Semantics(
        selected: selected,
        button: true,
        inMutuallyExclusiveGroup: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              if (icon != null)
                BjIconWell(
                  icon: icon!,
                  tone: tone == BjTone.accent ? null : tone,
                  size: 32,
                ),
              const Spacer(),
              AnimatedOpacity(
                opacity: selected ? 1 : 0,
                duration: BjMotion.fast,
                child: Icon(Icons.check_circle_rounded,
                    size: 20, color: context.bj.accent),
              ),
            ]),
            const SizedBox(height: BjSpace.sm),
            Text(title, style: text.titleSmall),
            if (description != null) ...[
              const SizedBox(height: BjSpace.xxs),
              Text(description!, style: text.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

/// A single choice shown as side-by-side cards of equal height, each saying
/// what it means. Use it in place of radio buttons when the options need
/// explaining. [value] can start null so nothing is chosen by default.
///
/// Works inside an `AlertDialog` (it doesn't use a `LayoutBuilder`). Pass
/// [axis] vertical for more than about three options.
class BjOptionCards<T> extends StatelessWidget {
  const BjOptionCards({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.axis = Axis.horizontal,
  });

  final List<BjOption<T>> options;
  final T? value;
  final ValueChanged<T> onChanged;
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    final cards = [
      for (final o in options)
        BjOptionCard(
          title: o.title,
          description: o.description,
          icon: o.icon,
          tone: o.tone,
          selected: value == o.value,
          onTap: () => onChanged(o.value),
        ),
    ];
    if (axis == Axis.vertical) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            if (i > 0) const SizedBox(height: BjSpace.sm),
            cards[i],
          ],
        ],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            if (i > 0) const SizedBox(width: BjSpace.sm),
            Expanded(child: cards[i]),
          ],
        ],
      ),
    );
  }
}
