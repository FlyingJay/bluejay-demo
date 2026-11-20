import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:shared_services/change_request_list_scope.dart';

export 'time_ago.dart';

/// Shared pieces for change-request screens (Improve Apps' idea and bug
/// lists, the dev queue, and anything that shows a ticket card). Built on
/// bluejay_design so every ticket surface shares one look.

/// The tone a ticket card takes: green once done, muted once closed,
/// plain while open.
BjTone? changeRequestCardTone({bool isCompleted = false, bool isClosed = false}) {
  if (isCompleted) return BjTone.success;
  if (isClosed) return BjTone.neutral;
  return null;
}

/// Up/down vote control used on idea and bug cards. Null [onUpvote] and
/// [onDownvote] render the count read-only (e.g. a steward viewing another
/// group's ticket, who can't update the doc).
class ChangeRequestVoteColumn extends StatelessWidget {
  const ChangeRequestVoteColumn({
    super.key,
    required this.voteCount,
    required this.hasUpvoted,
    required this.hasDownvoted,
    required this.onUpvote,
    required this.onDownvote,
  });

  final int voteCount;
  final bool hasUpvoted;
  final bool hasDownvoted;
  final VoidCallback? onUpvote;
  final VoidCallback? onDownvote;

  @override
  Widget build(BuildContext context) {
    final bj = context.bj;
    final text = Theme.of(context).textTheme;
    final countColor = hasUpvoted
        ? bj.accent
        : hasDownvoted
            ? BjNeutral.ink
            : BjNeutral.inkMuted;
    return AnimatedContainer(
      duration: BjMotion.medium,
      curve: BjMotion.curve,
      padding: const EdgeInsets.symmetric(vertical: BjSpace.xxs),
      decoration: BoxDecoration(
        gradient: hasUpvoted ? bj.softGradient : null,
        color: hasUpvoted ? null : BjNeutral.surfaceMuted,
        borderRadius: BjRadius.all(BjRadius.pill),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _VoteButton(
            icon: Icons.keyboard_arrow_up_rounded,
            isActive: hasUpvoted,
            activeColor: bj.accent,
            onPressed: onUpvote,
            semanticLabel: 'Upvote',
          ),
          AnimatedSwitcher(
            duration: BjMotion.fast,
            child: Text(
              '$voteCount',
              key: ValueKey(voteCount),
              style: text.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: countColor,
              ),
            ),
          ),
          _VoteButton(
            icon: Icons.keyboard_arrow_down_rounded,
            isActive: hasDownvoted,
            activeColor: BjNeutral.ink,
            onPressed: onDownvote,
            semanticLabel: 'Downvote',
          ),
        ],
      ),
    );
  }
}

class _VoteButton extends StatelessWidget {
  const _VoteButton({
    required this.icon,
    required this.isActive,
    required this.activeColor,
    required this.onPressed,
    required this.semanticLabel,
  });

  final IconData icon;
  final bool isActive;
  final Color activeColor;
  final VoidCallback? onPressed;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      button: true,
      enabled: onPressed != null,
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 40,
          height: 34,
          child: Icon(
            icon,
            size: 26,
            color: isActive
                ? activeColor
                : onPressed == null
                    ? BjNeutral.borderStrong
                    : BjNeutral.inkSubtle,
          ),
        ),
      ),
    );
  }
}

/// "This group" | "Apps I manage" | "All groups" toggle at the top of the
/// idea and bug lists. Shows only the [scopes] passed in (callers build
/// them with shared_services' availableChangeRequestScopes) and renders
/// nothing when there is only one scope to choose.
class ChangeRequestScopeSwitcher extends StatelessWidget {
  const ChangeRequestScopeSwitcher({
    super.key,
    required this.scopes,
    required this.selected,
    required this.onChanged,
    this.padding = const EdgeInsets.fromLTRB(
        BjSpace.md, BjSpace.md, BjSpace.md, 0),
  });

  final List<ChangeRequestListScope> scopes;
  final ChangeRequestListScope selected;
  final ValueChanged<ChangeRequestListScope> onChanged;
  final EdgeInsetsGeometry padding;

  static (IconData, String) describe(ChangeRequestListScope scope) =>
      switch (scope) {
        ChangeRequestListScope.activeGroup => (
            Icons.group_outlined,
            'This group'
          ),
        ChangeRequestListScope.managedApps => (
            Icons.apps_rounded,
            'Apps I manage'
          ),
        ChangeRequestListScope.allGroups => (
            Icons.public_rounded,
            'All groups'
          ),
      };

  @override
  Widget build(BuildContext context) {
    if (scopes.length < 2) return const SizedBox.shrink();
    return Padding(
      padding: padding,
      child: LayoutBuilder(
        // Three segments with icons wrap on phones; drop the icons there.
        builder: (context, constraints) {
          final showIcons = constraints.maxWidth >= 140.0 * scopes.length;
          return SizedBox(
            width: double.infinity,
            child: SegmentedButton<ChangeRequestListScope>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: [
                for (final scope in scopes)
                  ButtonSegment<ChangeRequestListScope>(
                    value: scope,
                    icon: showIcons ? Icon(describe(scope).$1, size: 16) : null,
                    label: Text(describe(scope).$2,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
              ],
              selected: {selected},
              onSelectionChanged: (selection) => onChanged(selection.first),
            ),
          );
        },
      ),
    );
  }
}

/// "Client group · App" label on cards in the "Apps I manage" list, where
/// tickets from several groups appear together. Long labels ellipsize, so
/// place it where its width is bounded.
class ChangeRequestScopeChip extends StatelessWidget {
  const ChangeRequestScopeChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final tone = context.bj.tone(BjTone.info);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: BjSpace.sm + 2, vertical: 3),
      decoration: BoxDecoration(
        color: tone.background,
        borderRadius: BjRadius.all(BjRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.apartment_rounded, size: 13, color: tone.foreground),
          const SizedBox(width: BjSpace.xs),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: tone.foreground),
            ),
          ),
        ],
      ),
    );
  }
}

/// Read-only stand-in for the "Related app" dropdown on the bug/idea
/// submit forms, shown when the form was opened from inside an app and the
/// related app is already known.
class LockedRelatedAppField extends StatelessWidget {
  const LockedRelatedAppField({super.key, required this.appName});

  final String appName;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Related app',
        prefixIcon: Icon(Icons.apps_rounded, size: 20),
        suffixIcon: Icon(
          Icons.lock_outline_rounded,
          size: 18,
          color: BjNeutral.inkSubtle,
        ),
      ),
      child: Text(
        appName,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context)
            .textTheme
            .bodyLarge
            ?.copyWith(color: BjNeutral.ink, fontWeight: FontWeight.w500),
      ),
    );
  }
}

/// Small "N pts" badge for a ticket's estimate.
class ChangeRequestPointsBadge extends StatelessWidget {
  const ChangeRequestPointsBadge({super.key, required this.points});

  final int points;

  @override
  Widget build(BuildContext context) => BjStatusPill(
        label: '$points pts',
        tone: BjTone.warning,
        icon: Icons.star_rounded,
      );
}

/// A small toned, tappable chip for a card's inline actions (Mark fixed,
/// Reopen, Edit). Keep destructive actions in a `BjOverflowMenu` instead.
class ChangeRequestActionChip extends StatelessWidget {
  const ChangeRequestActionChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.tone = BjTone.accent,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final BjTone tone;

  @override
  Widget build(BuildContext context) {
    final t = context.bj.tone(tone);
    final radius = BjRadius.all(BjRadius.pill);
    return Material(
      color: t.background,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: t.border),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 36),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: BjSpace.md, vertical: BjSpace.xs + 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: t.foreground),
                const SizedBox(width: BjSpace.xs + 2),
                Text(
                  label,
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: t.foreground),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
