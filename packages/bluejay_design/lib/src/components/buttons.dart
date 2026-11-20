import 'package:flutter/material.dart';

import '../tokens.dart';

/// A filled primary button that swaps its icon for a spinner and ignores
/// taps while [busy], so a slow save can't be submitted twice.
class BjBusyButton extends StatelessWidget {
  const BjBusyButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.icon,
  });

  final String label;

  /// Null disables the button.
  final VoidCallback? onPressed;
  final bool busy;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final onPrimary = Theme.of(context).colorScheme.onPrimary;
    final Widget? leading = busy
        ? SizedBox(
            key: const ValueKey('busy'),
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: onPrimary),
          )
        : icon == null
            ? null
            : Icon(icon, key: const ValueKey('icon'), size: 18);
    return FilledButton.icon(
      onPressed: busy ? null : onPressed,
      icon: leading == null
          ? null
          : AnimatedSwitcher(duration: BjMotion.fast, child: leading),
      label: Text(label),
    );
  }
}

/// The Cancel + primary row at the foot of a form sheet. On phones the two
/// buttons share the width; on wider screens they sit at the right with
/// [leading] (e.g. a secondary action) on the left. The primary is a
/// [BjBusyButton], so pass [busy] while saving.
class BjSheetActions extends StatelessWidget {
  const BjSheetActions({
    super.key,
    required this.primaryLabel,
    required this.onPrimary,
    this.primaryIcon,
    this.busy = false,
    this.onCancel,
    this.cancelLabel = 'Cancel',
    this.leading,
  });

  final String primaryLabel;

  /// Null disables the primary button (e.g. until the form is valid).
  final VoidCallback? onPrimary;
  final IconData? primaryIcon;
  final bool busy;

  /// Defaults to closing the sheet.
  final VoidCallback? onCancel;
  final String cancelLabel;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final cancel = OutlinedButton(
      onPressed: onCancel ?? () => Navigator.of(context).maybePop(),
      child: Text(cancelLabel),
    );
    final primary = BjBusyButton(
      label: primaryLabel,
      icon: primaryIcon,
      busy: busy,
      onPressed: onPrimary,
    );
    return Padding(
      padding: const EdgeInsets.only(top: BjSpace.xl),
      // Screen width rather than a LayoutBuilder, so the row also works
      // where intrinsic sizes are measured (dialogs).
      child: BjBreakpoint.isCompact(MediaQuery.sizeOf(context).width) &&
              leading == null
          ? Row(children: [
              Expanded(child: cancel),
              const SizedBox(width: BjSpace.md),
              Expanded(child: primary),
            ])
          : Row(children: [
              if (leading != null) Flexible(child: leading!),
              const Spacer(),
              cancel,
              const SizedBox(width: BjSpace.sm),
              primary,
            ]),
    );
  }
}

/// An extended floating action button for a long-running action, such as
/// an upload. While [busy] its icon becomes a progress ring (determinate
/// when [progress] is set), the label shows the percentage and it can't be
/// pressed again.
class BjProgressFab extends StatelessWidget {
  const BjProgressFab({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.progress,
    this.busyLabel,
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  /// 0 to 1, or null for an indeterminate ring.
  final double? progress;

  /// The label while busy, given the whole percent (0 when [progress] is
  /// null). Defaults to "[label] n%", or just [label] when indeterminate.
  final String Function(int percent)? busyLabel;

  /// Shown on long press while idle; defaults to [label].
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final onPrimary = Theme.of(context).colorScheme.onPrimary;
    final p = progress?.clamp(0.0, 1.0);
    final percent = ((p ?? 0) * 100).toInt();
    final busyText = busyLabel?.call(percent) ??
        (p == null ? label : '$label $percent%');
    return FloatingActionButton.extended(
      tooltip: busy ? busyText : tooltip ?? label,
      onPressed: busy ? null : onPressed,
      icon: AnimatedSwitcher(
        duration: BjMotion.medium,
        switchInCurve: BjMotion.curve,
        child: busy
            ? SizedBox(
                key: const ValueKey('ring'),
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  value: p,
                  strokeWidth: 3,
                  strokeCap: StrokeCap.round,
                  color: onPrimary,
                  backgroundColor: onPrimary.withValues(alpha: 0.25),
                ),
              )
            : Icon(icon, key: const ValueKey('icon')),
      ),
      label: Text(busy ? busyText : label),
    );
  }
}
