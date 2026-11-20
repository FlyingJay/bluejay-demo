import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'dev_queue_logic.dart';
import 'dev_queue_models.dart';
import 'dev_queue_service.dart';
import 'dev_ticket_status.dart';

/// The plain status words for a request: the label, with the detail
/// beneath it in smaller text. Shown on the bug, idea and App Maker ticket
/// screens and in Dev Pipeline. Its tone and icon come from
/// [devStatusStyles].
class DevStatusPill extends StatelessWidget {
  final DevStatus status;

  /// Hides the detail line, for dense rows.
  final bool showDetail;

  const DevStatusPill(this.status, {super.key, this.showDetail = true});

  @override
  Widget build(BuildContext context) {
    final style = devStatusStyle(status.code);
    final tone = context.bj.tone(style.tone);
    final text = Theme.of(context).textTheme;
    final detail = showDetail ? status.detail : '';
    final Widget lead = status.code.needsYou
        ? _Dot(color: tone.foreground)
        : Icon(style.icon, size: 14, color: tone.foreground);
    return Semantics(
      container: true,
      label: detail.isEmpty ? 'Status: ${status.label}' : 'Status: ${status.label}. $detail',
      excludeSemantics: true,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: BjSpace.sm + 2,
          vertical: detail.isEmpty ? BjSpace.xs : BjSpace.sm - 2,
        ),
        decoration: BoxDecoration(
          color: tone.background,
          borderRadius: BjRadius.all(detail.isEmpty ? BjRadius.pill : BjRadius.md),
          border: Border.all(color: tone.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                lead,
                const SizedBox(width: BjSpace.xs + 2),
                Flexible(
                  child: Text(
                    status.label,
                    style: text.labelMedium?.copyWith(fontWeight: FontWeight.w700, color: tone.foreground),
                  ),
                ),
              ],
            ),
            if (detail.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: BjSpace.xxs),
                child: Text(detail, style: text.bodySmall),
              ),
          ],
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  final Color color;

  const _Dot({required this.color});

  @override
  Widget build(BuildContext context) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}

/// A dot in the accent colour, shown next to labels that need the person.
class DevQueueAttentionDot extends StatelessWidget {
  const DevQueueAttentionDot({super.key});

  @override
  Widget build(BuildContext context) => _Dot(color: context.bj.accent);
}

/// A small text chip beside a status: the size ("Small") or "Fix" for a
/// regression fix. The word carries the meaning; colour only groups it.
class DevQueueTextChip extends StatelessWidget {
  final String label;

  /// The accent tone, for "Fix".
  final bool emphasis;

  const DevQueueTextChip(this.label, {super.key, this.emphasis = false});

  @override
  Widget build(BuildContext context) => BjStatusPill(
        label: label,
        tone: emphasis ? BjTone.accent : BjTone.neutral,
        icon: emphasis ? Icons.build_circle_outlined : null,
      );
}

/// A floating snack bar for the queue's results. [action] keeps its label
/// and callback.
void showDevQueueSnackBar(BuildContext context, String message, {SnackBarAction? action}) {
  BjSnack.info(context, message, actionLabel: action?.label, onAction: action?.onPressed);
}

/// Waiting on you, for a question: the question, a "Your answer" field and
/// "Send answer". Used on the queue screen and on the ticket screens, which
/// is where a managed group's submitter answers.
class DevQueueAnswerBox extends StatefulWidget {
  final String itemKey;
  final String question;
  final DevWaiting? waiting;
  final DevQueueService? service;
  final VoidCallback? onAnswered;

  /// Overrides the clock for the "holding your spot until" line in tests.
  final DateTime? now;

  const DevQueueAnswerBox({
    super.key,
    required this.itemKey,
    required this.question,
    this.waiting,
    this.service,
    this.onAnswered,
    this.now,
  });

  @override
  State<DevQueueAnswerBox> createState() => _DevQueueAnswerBoxState();
}

class _DevQueueAnswerBoxState extends State<DevQueueAnswerBox> {
  final _controller = TextEditingController();
  bool _sending = false;
  String? _idempotencyKey;

  DevQueueService get _service => widget.service ?? DevQueueService.instance;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    // One key per answer: a retry after a lost response can't apply twice.
    _idempotencyKey ??= _service.newKey();
    setState(() => _sending = true);
    try {
      await _service.answer(widget.itemKey, text, idempotencyKey: _idempotencyKey);
      if (!mounted) return;
      _controller.clear();
      _idempotencyKey = null;
      BjSnack.success(context, "Thanks. We'll pick it up from here.");
      widget.onAnswered?.call();
    } on DevQueueException catch (e) {
      if (mounted) BjSnack.error(context, e.message);
    } catch (_) {
      if (mounted) BjSnack.error(context, 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final waiting = widget.waiting;
    final slotLine = waiting == null ? '' : waitingSlotLine(waiting, now: widget.now);
    final canSend = !_sending && _controller.text.trim().isNotEmpty && _controller.text.trim().length <= 2000;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.question.isNotEmpty) ...[
          DevQueueQuestionCard(question: widget.question),
          const SizedBox(height: BjSpace.md),
        ],
        TextField(
          controller: _controller,
          enabled: !_sending,
          minLines: 2,
          maxLines: 6,
          maxLength: 2000,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Your answer', alignLabelWithHint: true),
        ),
        const SizedBox(height: BjSpace.xs),
        Align(
          alignment: Alignment.centerLeft,
          child: BjBusyButton(
            label: 'Send answer',
            icon: Icons.send_rounded,
            busy: _sending,
            onPressed: canSend ? _send : null,
          ),
        ),
        if (slotLine.isNotEmpty) ...[
          const SizedBox(height: BjSpace.md),
          BjInlineNote(slotLine, icon: Icons.event_seat_outlined),
        ],
        if (waiting?.askedByStaff == true) ...[
          const SizedBox(height: BjSpace.sm),
          Text('Answering reopens your request.', style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    );
  }
}

/// The question a request is waiting on, in a soft accent bubble.
class DevQueueQuestionCard extends StatelessWidget {
  final String question;

  const DevQueueQuestionCard({super.key, required this.question});

  @override
  Widget build(BuildContext context) {
    final bj = context.bj;
    return Container(
      padding: const EdgeInsets.all(BjSpace.md),
      decoration: BoxDecoration(
        gradient: bj.softGradient,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(BjRadius.xs),
          topRight: Radius.circular(BjRadius.lg),
          bottomLeft: Radius.circular(BjRadius.lg),
          bottomRight: Radius.circular(BjRadius.lg),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(Icons.chat_bubble_outline_rounded, size: 18, color: bj.accent),
          ),
          const SizedBox(width: BjSpace.sm),
          Expanded(child: Text(question, style: Theme.of(context).textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// Opens [url] in a new tab on the web and in the external browser elsewhere.
Future<bool> openDevQueueLink(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http')) return false;
  return launchUrl(uri, mode: LaunchMode.externalApplication, webOnlyWindowName: '_blank');
}

/// Ready to try: "Try it", the hint, and Approve / Ask for a tweak.
class DevQueuePreviewActions extends StatefulWidget {
  final DevQueueItem item;
  final DevQueueService? service;

  /// Opens the preview link; defaults to [openDevQueueLink].
  final Future<bool> Function(String url)? openLink;

  const DevQueuePreviewActions({super.key, required this.item, this.service, this.openLink});

  @override
  State<DevQueuePreviewActions> createState() => _DevQueuePreviewActionsState();
}

class _DevQueuePreviewActionsState extends State<DevQueuePreviewActions> {
  final _tweak = TextEditingController();
  bool _tweakOpen = false;
  bool _busy = false;
  String? _tweakKey;

  DevQueueService get _service => widget.service ?? DevQueueService.instance;
  String get _sha => widget.item.waiting?.sha ?? '';

  @override
  void initState() {
    super.initState();
    _tweak.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tweak.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, String success) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) BjSnack.success(context, success);
    } on DevQueueException catch (e) {
      if (mounted) BjSnack.error(context, e.message);
    } catch (_) {
      if (mounted) BjSnack.error(context, 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _approve() => _run(
        () => _service.approvePreview(widget.item.key, _sha),
        "Thanks. It's with the reviewer now.",
      );

  Future<void> _sendTweak() {
    final text = _tweak.text.trim();
    _tweakKey ??= _service.newKey();
    return _run(() async {
      await _service.requestTweak(widget.item.key, _sha, text, idempotencyKey: _tweakKey);
      _tweak.clear();
      _tweakKey = null;
      if (mounted) setState(() => _tweakOpen = false);
    }, "Got it. We're making your tweak.");
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.item.tryUrl;
    final tweakText = _tweak.text.trim();
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FilledButton.icon(
          onPressed: url.isEmpty ? null : () => (widget.openLink ?? openDevQueueLink)(url),
          icon: const Icon(Icons.open_in_new_rounded, size: 18),
          label: const Text('Try it'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
        ),
        const SizedBox(height: BjSpace.sm),
        Text(
          'Opens a test version of Bluejay with your change. Sign in with your '
          'usual email and password. It uses a test copy of your group\'s data, '
          'so nothing you do there changes your real data.',
          style: text.bodySmall,
        ),
        const SizedBox(height: BjSpace.md),
        Wrap(
          spacing: BjSpace.sm,
          runSpacing: BjSpace.sm,
          children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : _approve,
              icon: const Icon(Icons.check_rounded, size: 18),
              label: const Text('Approve'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => setState(() => _tweakOpen = !_tweakOpen),
              icon: const Icon(Icons.edit_note_rounded, size: 18),
              label: const Text('Ask for a tweak'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            ),
          ],
        ),
        // A fade, not a size animation: the field and its button take taps
        // the moment they appear.
        AnimatedSwitcher(
          duration: BjMotion.medium,
          switchInCurve: BjMotion.curve,
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.topLeft,
            children: [...previous, if (current != null) current],
          ),
          child: !_tweakOpen
              ? const SizedBox(key: ValueKey('closed'), width: double.infinity)
              : Padding(
                  key: const ValueKey('open'),
                  padding: const EdgeInsets.only(top: BjSpace.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _tweak,
                        enabled: !_busy,
                        minLines: 2,
                        maxLines: 5,
                        maxLength: 1000,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: const InputDecoration(labelText: 'What should change?', alignLabelWithHint: true),
                      ),
                      BjBusyButton(
                        label: 'Send tweak',
                        icon: Icons.send_rounded,
                        busy: _busy,
                        onPressed: _busy || tweakText.isEmpty ? null : _sendTweak,
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

/// Building → Checking → (Ready to try) → Final review → Live. Every step
/// carries its name, and done steps a check icon, so colour is never the
/// only signal. The current step shows the status label and detail.
class DevStageTracker extends StatelessWidget {
  final DevQueueItem item;

  const DevStageTracker({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final stages = stagesFor(item);
    final current = currentStage(item);
    final currentIndex = stages.indexOf(current);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < stages.length; i++)
          _StageRow(
            label: i == currentIndex ? item.status.label : stageLabels[stages[i]]!,
            detail: i == currentIndex ? item.status.detail : '',
            done: i < currentIndex,
            current: i == currentIndex,
            tone: devStatusTone(item.status.code),
            last: i == stages.length - 1,
          ),
      ],
    );
  }
}

class _StageRow extends StatelessWidget {
  final String label;
  final String detail;
  final bool done;
  final bool current;

  /// The current step's tone, from the item's status.
  final BjTone tone;
  final bool last;

  const _StageRow({
    required this.label,
    required this.detail,
    required this.done,
    required this.current,
    required this.tone,
    required this.last,
  });

  @override
  Widget build(BuildContext context) {
    final bj = context.bj;
    final text = Theme.of(context).textTheme;
    final doneColor = bj.tone(BjTone.success).foreground;
    final currentTone = bj.tone(tone);
    final state = done ? 'done' : (current ? 'current step' : 'not started');
    final Color fill = done ? doneColor : (current ? currentTone.foreground : BjNeutral.surface);
    final Color ring = done ? doneColor : (current ? currentTone.foreground : BjNeutral.borderStrong);
    return Semantics(
      label: '$label, $state${detail.isNotEmpty ? '. $detail' : ''}',
      excludeSemantics: true,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Column(
              children: [
                AnimatedContainer(
                  duration: BjMotion.medium,
                  curve: BjMotion.curve,
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: fill,
                    border: Border.all(color: ring, width: 2),
                    boxShadow: current
                        ? [BoxShadow(color: currentTone.foreground.withValues(alpha: 0.25), blurRadius: 8)]
                        : null,
                  ),
                  child: done
                      ? Icon(Icons.check_rounded, size: 14, color: bj.tone(BjTone.success).background)
                      : (current ? Icon(Icons.circle, size: 8, color: currentTone.background) : null),
                ),
                if (!last)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: BjSpace.xxs),
                      decoration: BoxDecoration(
                        color: done ? doneColor.withValues(alpha: 0.5) : BjNeutral.border,
                        borderRadius: BjRadius.all(BjRadius.pill),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: BjSpace.md),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(top: 1, bottom: last ? 0 : BjSpace.sm + 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: current
                          ? text.titleSmall?.copyWith(color: currentTone.foreground)
                          : text.bodyMedium?.copyWith(color: done ? BjNeutral.ink : BjNeutral.inkSubtle),
                    ),
                    if (detail.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: BjSpace.xxs),
                        child: Text(detail, style: text.bodySmall),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
