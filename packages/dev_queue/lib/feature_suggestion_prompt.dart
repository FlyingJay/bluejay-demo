import 'dart:async';

import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';

import 'feature_suggestion_service.dart';

/// Copy the prompt and its snackbars use.
const featureSuggestionAddedMessage = "Added to your queue. We'll let you know when it's ready.";
const featureSuggestionStoppedMessage =
    "We won't suggest features again. You can turn this back on in Notification settings.";

/// Reads the signed-in person's feature suggestion and, when
/// [shouldShowFeatureSuggestion] allows it for [groupId], shows the prompt.
/// [canShow] is asked again once the reads finish, so the caller can drop
/// the prompt if the screen moved on meanwhile (a link opened another app,
/// another dialog came up). Read failures are silent. Resolves to true when
/// the prompt was shown.
Future<bool> maybeShowFeatureSuggestion(
  BuildContext context, {
  required String uid,
  required String groupId,
  bool isGuest = false,
  bool Function()? canShow,
  FeatureSuggestionService? service,
  DateTime Function()? now,
}) async {
  if (isGuest) return false;
  final svc = service ?? FeatureSuggestionService.instance;
  final FeatureSuggestionOffer? offer;
  final bool enabled;
  try {
    final results = await Future.wait<Object?>([svc.readOffer(uid), svc.readEnabled(uid)]);
    offer = results[0] as FeatureSuggestionOffer?;
    enabled = results[1] as bool;
  } catch (_) {
    return false;
  }
  final show = shouldShowFeatureSuggestion(
    offer: offer,
    now: (now ?? DateTime.now)(),
    activeGroupId: groupId,
    isGuest: isGuest,
    suggestionsEnabled: enabled,
  );
  if (!show || !context.mounted || (canShow != null && !canShow())) return false;
  await showFeatureSuggestionDialog(context, offer!, service: svc);
  return true;
}

/// What the dialog closed with: the action the server accepted, or the
/// message of a refused one.
class FeatureSuggestionOutcome {
  final FeatureSuggestionAction action;
  final String? error;

  const FeatureSuggestionOutcome(this.action, {this.error});
}

/// Shows "You use {app} a lot" for [offer] and sends the answer. Closing it
/// without choosing sends `later` without waiting. Resolves to the outcome,
/// or null when it was closed without choosing.
Future<FeatureSuggestionOutcome?> showFeatureSuggestionDialog(
  BuildContext context,
  FeatureSuggestionOffer offer, {
  FeatureSuggestionService? service,
}) async {
  final svc = service ?? FeatureSuggestionService.instance;
  final outcome = await showDialog<FeatureSuggestionOutcome>(
    context: context,
    builder: (_) => FeatureSuggestionDialog(offer: offer, service: svc),
  );
  if (outcome == null) {
    unawaited(svc.respond(offer.offerId, FeatureSuggestionAction.later).then((_) {}, onError: (_) {}));
    return null;
  }
  if (!context.mounted) return outcome;
  final error = outcome.error;
  if (error != null) {
    BjSnack.error(context, error);
  } else if (outcome.action == FeatureSuggestionAction.accept) {
    BjSnack.success(context, featureSuggestionAddedMessage);
  } else if (outcome.action == FeatureSuggestionAction.stop) {
    BjSnack.info(context, featureSuggestionStoppedMessage);
  }
  return outcome;
}

/// The prompt itself. Each button sends its action and closes the dialog
/// with a [FeatureSuggestionOutcome]; buttons are off while one is sending.
class FeatureSuggestionDialog extends StatefulWidget {
  final FeatureSuggestionOffer offer;
  final FeatureSuggestionService service;

  const FeatureSuggestionDialog({super.key, required this.offer, required this.service});

  @override
  State<FeatureSuggestionDialog> createState() => _FeatureSuggestionDialogState();
}

class _FeatureSuggestionDialogState extends State<FeatureSuggestionDialog> {
  FeatureSuggestionAction? _sending;

  bool get _busy => _sending != null;

  Future<void> _send(FeatureSuggestionAction action) async {
    if (_busy) return;
    setState(() => _sending = action);
    FeatureSuggestionOutcome outcome;
    try {
      await widget.service.respond(widget.offer.offerId, action);
      outcome = FeatureSuggestionOutcome(action);
    } on FeatureSuggestionException catch (e) {
      outcome = FeatureSuggestionOutcome(action, error: e.message);
    } catch (_) {
      outcome = FeatureSuggestionOutcome(action, error: 'Something went wrong. Try again.');
    }
    if (mounted) Navigator.of(context).pop(outcome);
  }

  @override
  Widget build(BuildContext context) {
    final bj = context.bj;
    final text = Theme.of(context).textTheme;
    final offer = widget.offer;
    final appName = offer.appName.isNotEmpty ? offer.appName : 'this app';
    return PopScope(
      canPop: !_busy,
      child: Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(BjSpace.xl, BjSpace.sm, BjSpace.xl, BjSpace.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    icon: const Icon(Icons.close_rounded),
                    tooltip: 'Close',
                    onPressed: _busy ? null : () => Navigator.of(context).maybePop(),
                  ),
                ),
                const Center(child: BjIconWell(icon: Icons.lightbulb_outline_rounded, size: 52)),
                const SizedBox(height: BjSpace.lg),
                Text('You use $appName a lot', textAlign: TextAlign.center, style: text.headlineSmall),
                const SizedBox(height: BjSpace.xs),
                Text('Would this help you?', textAlign: TextAlign.center, style: text.bodyLarge),
                const SizedBox(height: BjSpace.lg),
                Container(
                  padding: const EdgeInsets.all(BjSpace.lg),
                  decoration: BoxDecoration(
                    color: bj.accentWash,
                    borderRadius: BjRadius.all(BjRadius.md),
                    border: Border.all(color: bj.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(offer.title, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                      if (offer.pitch.isNotEmpty) ...[
                        const SizedBox(height: BjSpace.xs),
                        Text(offer.pitch, style: text.bodyMedium),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: BjSpace.md),
                Text(
                  "Say yes and we'll build it for you. We'll let you know when it's ready.",
                  textAlign: TextAlign.center,
                  style: text.bodySmall,
                ),
                const SizedBox(height: BjSpace.lg),
                BjBusyButton(
                  label: 'Yes, add it',
                  icon: Icons.add_rounded,
                  busy: _sending == FeatureSuggestionAction.accept,
                  onPressed: _busy ? null : () => _send(FeatureSuggestionAction.accept),
                ),
                const SizedBox(height: BjSpace.sm),
                OutlinedButton(
                  onPressed: _busy ? null : () => _send(FeatureSuggestionAction.decline),
                  child: const Text('Not this one'),
                ),
                const SizedBox(height: BjSpace.xs),
                TextButton(
                  onPressed: _busy ? null : () => _send(FeatureSuggestionAction.stop),
                  style: TextButton.styleFrom(foregroundColor: bj.inkMuted),
                  child: const Text("Don't ask me again"),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
