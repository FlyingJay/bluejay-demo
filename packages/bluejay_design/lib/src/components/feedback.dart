import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';
import 'surfaces.dart';

/// Asks the user to confirm an action. For destructive actions, list what
/// will be lost in [consequences] so the result of tapping the red button
/// is never a surprise. Resolves to true only when confirmed.
Future<bool> showBjConfirm(
  BuildContext context, {
  required String title,
  String? message,
  List<String> consequences = const [],
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  bool destructive = false,
  IconData? icon,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) {
      final bj = context.bj;
      final text = Theme.of(context).textTheme;
      final danger = bj.tone(BjTone.danger);
      return AlertDialog(
        // Centered: the dialog's icon slot is full width and would
        // otherwise stretch the well.
        icon: Center(
          child: BjIconWell(
            icon: icon ??
                (destructive
                    ? Icons.delete_outline_rounded
                    : Icons.help_outline_rounded),
            tone: destructive ? BjTone.danger : null,
            size: 52,
          ),
        ),
        title: Text(title, textAlign: TextAlign.center),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (message != null)
                Text(message, textAlign: TextAlign.center),
              if (consequences.isNotEmpty) ...[
                const SizedBox(height: BjSpace.lg),
                Container(
                  padding: const EdgeInsets.all(BjSpace.md),
                  decoration: BoxDecoration(
                    color: destructive ? danger.background : bj.accentWash,
                    borderRadius: BjRadius.all(BjRadius.md),
                    border: Border.all(
                        color: destructive ? danger.border : context.bj.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final c in consequences)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                // A minus for what a destructive action
                                // takes away; an arrow for any other change.
                                child: Icon(
                                    destructive
                                        ? Icons.remove_circle_outline_rounded
                                        : Icons.arrow_circle_right_outlined,
                                    size: 16,
                                    color: destructive
                                        ? danger.foreground
                                        : bj.accent),
                              ),
                              const SizedBox(width: BjSpace.sm),
                              Expanded(
                                child: Text(c,
                                    style: text.bodySmall
                                        ?.copyWith(color: context.bj.ink)),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(cancelLabel),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: danger.foreground,
                    foregroundColor: Colors.white)
                : null,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return result ?? false;
}

/// Floating, toned snack bars with an icon.
abstract final class BjSnack {
  /// [duration] defaults to the snack bar's 4 seconds; games pass a short
  /// one for quick move messages.
  static void success(BuildContext context, String message,
          {Duration? duration}) =>
      _show(context, message, Icons.check_circle_rounded,
          const Color(0xFF6EE7B7),
          duration: duration);

  static void error(BuildContext context, String message,
          {Duration? duration}) =>
      _show(context, message, Icons.error_rounded, const Color(0xFFFCA5A5),
          duration: duration);

  static void info(BuildContext context, String message,
          {String? actionLabel, VoidCallback? onAction, Duration? duration}) =>
      _show(context, message, Icons.info_rounded, const Color(0xFFBFDBFE),
          actionLabel: actionLabel, onAction: onAction, duration: duration);

  static void _show(
    BuildContext context,
    String message,
    IconData icon,
    Color iconColor, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration? duration,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final width = MediaQuery.sizeOf(context).width;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        // Set here, not only in the theme: `width` requires floating.
        behavior: SnackBarBehavior.floating,
        width: width > 560 ? 480 : null,
        duration: duration ?? const Duration(milliseconds: 4000),
        content: Row(children: [
          Icon(icon, color: iconColor, size: 20),
          const SizedBox(width: BjSpace.md),
          Expanded(child: Text(message)),
        ]),
        action: actionLabel == null
            ? null
            : SnackBarAction(label: actionLabel, onPressed: onAction ?? () {}),
      ));
  }
}

/// Shows a modal bottom sheet with a title row and consistent padding. The
/// sheet scrolls, lifts above the keyboard and caps its width on desktop.
Future<T?> showBjSheet<T>(
  BuildContext context, {
  required String title,
  required WidgetBuilder builder,
  String? subtitle,
  bool isDismissible = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    isDismissible: isDismissible,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (context) {
      final text = Theme.of(context).textTheme;
      return Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
              BjSpace.xl, 0, BjSpace.xl, BjSpace.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: text.titleLarge),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(subtitle, style: text.bodySmall),
                ),
              const SizedBox(height: BjSpace.lg),
              builder(context),
            ],
          ),
        ),
      );
    },
  );
}

/// Opens a tall panel over the current screen, for help that sits beside
/// the work: a right-hand side panel from [BjBreakpoint.expanded], a tall
/// bottom sheet on phones that lifts above the keyboard. [builder] fills
/// the whole panel, header included, and pops its own result.
/// [barrierLabel] is read out for the tap-outside-to-close area on wide
/// screens.
Future<T?> showBjSidePanel<T>(
  BuildContext context, {
  required String barrierLabel,
  required WidgetBuilder builder,
}) {
  final width = MediaQuery.sizeOf(context).width;
  if (BjBreakpoint.isExpanded(width)) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: barrierLabel,
      barrierColor: BjNeutral.shadow.withValues(alpha: 0.35),
      transitionDuration: BjMotion.medium,
      pageBuilder: (context, _, __) => Align(
        alignment: Alignment.centerRight,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(BjSpace.md),
            child: SizedBox(
              width: width * 0.4 < 480 ? 480 : width * 0.4,
              child: DecoratedBox(
                decoration: BoxDecoration(
                    borderRadius: BjRadius.all(BjRadius.xl),
                    boxShadow: context.bj.shadowMd),
                child: Material(
                  color: BjNeutral.surface,
                  shape: RoundedRectangleBorder(
                      borderRadius: BjRadius.all(BjRadius.xl)),
                  clipBehavior: Clip.antiAlias,
                  child: Builder(builder: builder),
                ),
              ),
            ),
          ),
        ),
      ),
      transitionBuilder: (context, animation, _, child) => SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(
            CurvedAnimation(parent: animation, curve: BjMotion.curve)),
        child: child,
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: BjBreakpoint.formWidth),
    builder: (context) {
      final keyboard = MediaQuery.viewInsetsOf(context).bottom;
      return Padding(
        padding: EdgeInsets.only(bottom: keyboard),
        child: SizedBox(
          height: (MediaQuery.sizeOf(context).height * 0.9 - keyboard)
              .clamp(0.0, double.infinity),
          child: Builder(builder: builder),
        ),
      );
    },
  );
}
