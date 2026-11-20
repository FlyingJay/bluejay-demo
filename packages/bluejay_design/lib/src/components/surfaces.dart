import 'package:flutter/material.dart';

import '../color.dart';
import '../theme.dart';
import '../tokens.dart';

/// A white rounded card with a hairline border and soft shadow. When
/// [onTap] is set it lifts on hover and dips slightly on press.
class BjCard extends StatefulWidget {
  const BjCard({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.padding = const EdgeInsets.all(BjSpace.lg),
    this.selected = false,
    this.tone,
    this.radius = BjRadius.lg,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final EdgeInsetsGeometry padding;
  final bool selected;

  /// Tints the card's background and border with a status tone.
  final BjTone? tone;
  final double radius;

  @override
  State<BjCard> createState() => _BjCardState();
}

class _BjCardState extends State<BjCard> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final bj = context.bj;
    final interactive = widget.onTap != null || widget.onLongPress != null;
    final tone = widget.tone == null ? null : bj.tone(widget.tone!);
    final borderColor = widget.selected
        ? bj.accent
        : tone?.border ?? (_hovered ? context.bj.borderStrong : context.bj.border);
    final radius = BjRadius.all(widget.radius);
    return AnimatedScale(
      scale: _pressed ? 0.985 : 1,
      duration: BjMotion.fast,
      curve: BjMotion.curve,
      child: AnimatedContainer(
        duration: BjMotion.medium,
        curve: BjMotion.curve,
        decoration: BoxDecoration(
          color: widget.selected
              ? bj.accentWash
              : tone?.background ?? context.bj.surface,
          borderRadius: radius,
          border: Border.all(
              color: borderColor, width: widget.selected ? 1.5 : 1),
          boxShadow: interactive && _hovered ? bj.shadowMd : bj.shadowSm,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: radius,
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            onHover: interactive ? (h) => setState(() => _hovered = h) : null,
            onHighlightChanged: interactive
                ? (p) => setState(() => _pressed = p)
                : null,
            child: Padding(padding: widget.padding, child: widget.child),
          ),
        ),
      ),
    );
  }
}

/// A gradient banner for a screen's headline summary: title, supporting
/// line, optional stats or actions underneath. White text throughout.
class BjHeroCard extends StatelessWidget {
  const BjHeroCard({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.footer,
    this.trailing,
    this.compact = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? footer;
  final Widget? trailing;

  /// A smaller title and tighter padding, for phones or long titles (a
  /// sentence-long goal wraps to three lines at the full size).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final bj = context.bj;
    final text = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(
        gradient: bj.heroGradient,
        borderRadius: BjRadius.all(BjRadius.xl),
        boxShadow: [
          BoxShadow(
            color: bj.accent.withValues(alpha: 0.25),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BjRadius.all(BjRadius.xl),
        child: Stack(children: [
          // Soft decorative bubbles for depth.
          Positioned(
            right: -40,
            top: -50,
            child: _Bubble(size: 160, alpha: 0.12),
          ),
          Positioned(
            right: 60,
            bottom: -70,
            child: _Bubble(size: 120, alpha: 0.08),
          ),
          Padding(
            padding: EdgeInsets.all(compact ? BjSpace.lg : BjSpace.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  if (icon != null) ...[
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18),
                        borderRadius: BjRadius.all(BjRadius.md),
                      ),
                      child: Icon(icon, color: Colors.white, size: 22),
                    ),
                    const SizedBox(width: BjSpace.md),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: (compact
                                    ? text.titleLarge
                                    : text.headlineSmall)
                                ?.copyWith(color: Colors.white)),
                        if (subtitle != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(subtitle!,
                                style: text.bodyMedium?.copyWith(
                                    color:
                                        Colors.white.withValues(alpha: 0.88))),
                          ),
                      ],
                    ),
                  ),
                  if (trailing != null) trailing!,
                ]),
                if (footer != null) ...[
                  const SizedBox(height: BjSpace.lg),
                  DefaultTextStyle.merge(
                    style: const TextStyle(color: Colors.white),
                    child: IconTheme.merge(
                      data: const IconThemeData(color: Colors.white),
                      child: footer!,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.size, required this.alpha});

  final double size;
  final double alpha;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: alpha),
        ),
      );
}

/// A rounded square holding an icon on a soft gradient (or tone) — the
/// leading visual for rows, stat tiles and state views.
class BjIconWell extends StatelessWidget {
  const BjIconWell({
    super.key,
    required this.icon,
    this.size = 40,
    this.tone,
    this.color,
  });

  final IconData icon;
  final double size;
  final BjTone? tone;

  /// A custom color (e.g. a user-picked tag color); overrides [tone].
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final bj = context.bj;
    final t = tone == null ? null : bj.tone(tone!);
    final fg = color ?? t?.foreground ?? bj.accent;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: color == null && t == null ? bj.softGradient : null,
        color: color != null
            ? bjTint(color!)
            : t?.background,
        borderRadius: BjRadius.all(size * 0.32),
      ),
      child: Icon(icon, size: size * 0.5, color: fg),
    );
  }
}

/// One action in a [BjListRow] overflow menu.
class BjMenuAction {
  const BjMenuAction({
    required this.label,
    required this.icon,
    required this.onSelected,
    this.destructive = false,
    this.enabled = true,
  });

  final String label;
  final IconData icon;
  final VoidCallback onSelected;

  /// Shown in the danger color, separated from the other actions.
  final bool destructive;

  /// Greyed out and not selectable when false, e.g. while the action is
  /// already running. Prefer this to dropping the item, so the menu doesn't
  /// change shape under the user.
  final bool enabled;
}

/// A list row: leading visual, title, subtitle, a line of meta pills, and
/// a single overflow menu instead of a cluster of icon buttons. Destructive
/// actions sit at the bottom of the menu in red, so the row itself stays
/// calm.
class BjListRow extends StatelessWidget {
  const BjListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.meta = const [],
    this.trailing,
    this.actions = const [],
    this.onTap,
    this.selected = false,
    this.dense = false,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> meta;
  final Widget? trailing;
  final List<BjMenuAction> actions;
  final VoidCallback? onTap;
  final bool selected;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return BjCard(
      onTap: onTap,
      selected: selected,
      padding: EdgeInsets.symmetric(
        horizontal: BjSpace.lg,
        vertical: dense ? BjSpace.sm : BjSpace.md,
      ),
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: BjSpace.md),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: text.titleSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(subtitle!,
                        style: text.bodySmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ),
                if (meta.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: BjSpace.sm),
                    child: Wrap(
                      spacing: BjSpace.xs + 2,
                      runSpacing: BjSpace.xs + 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: meta,
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: BjSpace.sm),
            trailing!,
          ],
          if (actions.isNotEmpty) BjOverflowMenu(actions: actions),
        ],
      ),
    );
  }
}

/// A "more" button listing [actions], destructive ones last and in red.
class BjOverflowMenu extends StatelessWidget {
  const BjOverflowMenu({super.key, required this.actions, this.tooltip});

  final List<BjMenuAction> actions;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final danger = context.bj.tone(BjTone.danger).foreground;
    final safe = actions.where((a) => !a.destructive).toList();
    final destructive = actions.where((a) => a.destructive).toList();
    PopupMenuItem<BjMenuAction> item(BjMenuAction a) {
      final color = !a.enabled
          ? context.bj.inkSubtle
          : a.destructive
              ? danger
              : null;
      return PopupMenuItem(
        value: a,
        enabled: a.enabled,
        child: Row(children: [
          Icon(a.icon, size: 20, color: color ?? context.bj.inkMuted),
          const SizedBox(width: BjSpace.md),
          Flexible(
            child: Text(a.label,
                style: color == null ? null : TextStyle(color: color)),
          ),
        ]),
      );
    }

    return PopupMenuButton<BjMenuAction>(
      tooltip: tooltip ?? 'More actions',
      icon: const Icon(Icons.more_horiz_rounded),
      position: PopupMenuPosition.under,
      onSelected: (a) => a.onSelected(),
      itemBuilder: (_) => [
        ...safe.map(item),
        if (safe.isNotEmpty && destructive.isNotEmpty) const PopupMenuDivider(),
        ...destructive.map(item),
      ],
    );
  }
}

/// A small rounded status label.
class BjStatusPill extends StatelessWidget {
  const BjStatusPill({
    super.key,
    required this.label,
    this.tone = BjTone.neutral,
    this.icon,
    this.color,
  });

  final String label;
  final BjTone tone;
  final IconData? icon;

  /// A custom color (e.g. a user-picked tag color); overrides [tone]. The
  /// label is darkened until readable on the pill.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = color == null ? context.bj.tone(tone) : bjToneOf(color!);
    final fg = t.foreground;
    final bg = t.background;
    final text = Theme.of(context).textTheme.labelSmall;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: BjSpace.sm + 2, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BjRadius.all(BjRadius.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: fg),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(label,
              style: text?.copyWith(color: fg, letterSpacing: 0.2),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ),
      ]),
    );
  }
}

/// A KPI tile: label, big value, optional icon and caption.
class BjStatTile extends StatelessWidget {
  const BjStatTile({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.caption,
    this.tone = BjTone.accent,
    this.onTap,
  });

  final String label;
  final String value;
  final IconData? icon;
  final String? caption;
  final BjTone tone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return BjCard(
      onTap: onTap,
      padding: const EdgeInsets.all(BjSpace.lg),
      child: Row(children: [
        if (icon != null) ...[
          BjIconWell(icon: icon!, tone: tone == BjTone.accent ? null : tone),
          const SizedBox(width: BjSpace.md),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: text.labelMedium?.copyWith(color: context.bj.inkMuted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(value, style: text.headlineSmall),
              if (caption != null)
                Text(caption!,
                    style: text.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ]),
    );
  }
}

/// A rounded progress bar with a gradient fill that animates to [value].
class BjProgressBar extends StatelessWidget {
  const BjProgressBar({
    super.key,
    required this.value,
    this.height = 8,
    this.onDark = false,
  });

  final double value;
  final double height;

  /// For use on a [BjHeroCard]: white fill on a translucent track.
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final bj = context.bj;
    final v = value.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BjRadius.all(BjRadius.pill),
      child: SizedBox(
        height: height,
        child: Stack(children: [
          Positioned.fill(
            child: ColoredBox(
              color: onDark
                  ? Colors.white.withValues(alpha: 0.25)
                  : bj.accentSoft,
            ),
          ),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: v),
            duration: BjMotion.slow * 2,
            curve: BjMotion.curve,
            builder: (_, t, __) => FractionallySizedBox(
              widthFactor: t,
              heightFactor: 1,
              alignment: Alignment.centerLeft,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: onDark ? Colors.white : null,
                  gradient: onDark ? null : bj.heroGradient,
                  borderRadius: BjRadius.all(BjRadius.pill),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// A leaderboard position: a trophy well for the top three (gold, blue,
/// red tones in that order), the rank number in a neutral well after that.
class BjRankBadge extends StatelessWidget {
  const BjRankBadge({super.key, required this.rank, this.size = 40});

  /// 1-based.
  final int rank;
  final double size;

  @override
  Widget build(BuildContext context) {
    final tone = switch (rank) {
      1 => BjTone.warning,
      2 => BjTone.info,
      3 => BjTone.danger,
      _ => null,
    };
    if (tone != null) {
      return BjIconWell(
          icon: Icons.emoji_events_rounded, tone: tone, size: size);
    }
    final bj = context.bj;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bj.surfaceMuted,
        borderRadius: BjRadius.all(size * 0.32),
      ),
      child: Text(
        '$rank',
        style: Theme.of(context)
            .textTheme
            .titleSmall
            ?.copyWith(color: bj.inkMuted),
      ),
    );
  }
}
