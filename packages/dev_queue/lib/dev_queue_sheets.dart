import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';

import 'dev_queue_models.dart';
import 'dev_queue_service.dart';

// The requester's edit, withdraw and "This broke something" flows
// (PHASE_2_5_DESIGN.md 8.1). Every sheet keeps its text on error, disables
// its button while sending or while a required field is empty, and labels
// every field.

const _maxDescription = 5000;
const _maxTitle = 200;

InputDecoration _field(String label) => InputDecoration(labelText: label, alignLabelWithHint: true);

Widget _errorLine(String? error) {
  return AnimatedSize(
    duration: BjMotion.medium,
    curve: BjMotion.curve,
    alignment: Alignment.topLeft,
    child: error == null
        ? const SizedBox(width: double.infinity)
        : Padding(
            padding: const EdgeInsets.only(top: BjSpace.sm),
            child: Semantics(
              liveRegion: true,
              child: BjInlineNote(error, icon: Icons.error_outline_rounded, tone: BjTone.danger),
            ),
          ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Edit
// ─────────────────────────────────────────────────────────────────────────────

/// Opens "Edit your request" for [item]. Shows "Saved. We'll build the
/// updated version." when it saves.
Future<void> showDevQueueEditSheet(BuildContext context, DevQueueItem item, DevQueueService service) async {
  final saved = await showBjSheet<bool>(
    context,
    title: 'Edit your request',
    subtitle: item.appName.isEmpty ? null : item.appName,
    builder: (_) => DevQueueEditSheet(item: item, service: service),
  );
  if (saved == true && context.mounted) {
    BjSnack.success(context, "Saved. We'll build the updated version.");
  }
}

/// The labels of the edit sheet's fields for an item type: one field for a
/// bug, a title and a description otherwise.
({String? title, String description}) editFieldLabels(String itemType) {
  switch (itemType) {
    case 'bug':
      return (title: null, description: "What's going wrong?");
    case 'app':
      return (title: 'App name', description: 'What it should do');
    default:
      return (title: 'Title', description: 'Details');
  }
}

class DevQueueEditSheet extends StatefulWidget {
  final DevQueueItem item;
  final DevQueueService service;

  const DevQueueEditSheet({super.key, required this.item, required this.service});

  @override
  State<DevQueueEditSheet> createState() => _DevQueueEditSheetState();
}

class _DevQueueEditSheetState extends State<DevQueueEditSheet> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  DevTicketText? _original;
  bool _loadFailed = false;
  bool _sending = false;
  String? _error;

  bool get _isBug => widget.item.itemType == 'bug';

  @override
  void initState() {
    super.initState();
    _title.addListener(_changed);
    _description.addListener(_changed);
    _load();
  }

  void _changed() => setState(() {});

  Future<void> _load() async {
    setState(() => _loadFailed = false);
    try {
      final text = await widget.service.readTicketText(widget.item.itemType, widget.item.itemId);
      if (!mounted) return;
      final original = DevTicketText(
        title: text.title.isNotEmpty ? text.title : (_isBug ? '' : widget.item.title),
        description: text.description,
      );
      _title.text = original.title;
      _description.text = original.description;
      setState(() => _original = original);
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  bool get _valid {
    final title = _title.text.trim();
    final description = _description.text.trim();
    if (description.length > _maxDescription) return false;
    if (_isBug) return description.isNotEmpty;
    return title.isNotEmpty && title.length <= _maxTitle;
  }

  Future<void> _save() async {
    final original = _original;
    if (original == null || !_valid || _sending) return;
    final title = _title.text.trim();
    final description = _description.text.trim();
    final titleChanged = !_isBug && title != original.title;
    final descriptionChanged = description != original.description;
    if (!titleChanged && !descriptionChanged) {
      Navigator.of(context).pop(false);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.service.editRequest(
        widget.item.key,
        title: titleChanged ? title : null,
        description: descriptionChanged ? description : null,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on DevQueueException catch (e) {
      if (!mounted) return;
      if (e.reason == 'nothing-changed') {
        Navigator.of(context).pop(false);
        return;
      }
      setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final labels = editFieldLabels(widget.item.itemType);
    if (_original == null) {
      return AnimatedSwitcher(
        duration: BjMotion.medium,
        child: _loadFailed
            ? BjStateView(
                key: const ValueKey('failed'),
                icon: Icons.cloud_off_rounded,
                tone: BjTone.danger,
                compact: true,
                title: "Couldn't load your request.",
                message: 'Check your connection and try again.',
                action: OutlinedButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Try again'),
                ),
              )
            : Column(
                key: const ValueKey('loading'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (labels.title != null) ...[
                    const BjSkeleton(height: 52, radius: BjRadius.md),
                    const SizedBox(height: BjSpace.lg),
                  ],
                  const BjSkeleton(height: 120, radius: BjRadius.md),
                ],
              ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (labels.title != null) ...[
          TextField(
            controller: _title,
            enabled: !_sending,
            maxLength: _maxTitle,
            textCapitalization: TextCapitalization.sentences,
            decoration: _field(labels.title!),
          ),
          const SizedBox(height: BjSpace.sm),
        ],
        TextField(
          controller: _description,
          enabled: !_sending,
          minLines: 3,
          maxLines: 8,
          maxLength: _maxDescription,
          textCapitalization: TextCapitalization.sentences,
          decoration: _field(labels.description),
        ),
        _errorLine(_error),
        BjSheetActions(
          primaryLabel: 'Save changes',
          primaryIcon: Icons.check_rounded,
          busy: _sending,
          onPrimary: _valid && !_sending ? _save : null,
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Withdraw
// ─────────────────────────────────────────────────────────────────────────────

/// Asks before withdrawing. [started] picks the "Stop work on this?"
/// wording, whose confirm sends `confirmStarted: true`.
Future<bool> confirmDevQueueWithdraw(BuildContext context, {required bool started}) => showBjConfirm(
      context,
      destructive: true,
      icon: started ? Icons.pan_tool_outlined : Icons.remove_circle_outline_rounded,
      title: started ? 'Stop work on this?' : 'Withdraw this request?',
      message: started
          ? "We've already started. Withdrawing stops the work, and it won't go live."
          : 'It leaves your queue and nothing gets built. You can ask again any time.',
      consequences: started
          ? const [
              'The work in progress stops and is thrown away',
              "The change won't go live",
              'Its place in your queue goes to your next request',
            ]
          : const [
              'It leaves Up next and gives up its place in line',
              'Nothing gets built from it',
            ],
      cancelLabel: 'Keep it',
      confirmLabel: started ? 'Stop and withdraw' : 'Withdraw',
    );

/// Confirms and withdraws [item]. If the server says work started since
/// the screen last updated (`already-started`), asks again with the
/// started wording before sending `confirmStarted`.
Future<bool> withdrawDevQueueItem(BuildContext context, DevQueueItem item, DevQueueService service) async {
  var started = item.isStarted;
  if (!await confirmDevQueueWithdraw(context, started: started)) return false;
  while (true) {
    try {
      await service.withdraw(item.key, confirmStarted: started);
      if (context.mounted) BjSnack.success(context, 'Request withdrawn.');
      return true;
    } on DevQueueException catch (e) {
      if (!context.mounted) return false;
      if (e.reason == 'already-started' && !started) {
        started = true;
        if (!await confirmDevQueueWithdraw(context, started: true)) return false;
        if (!context.mounted) return false;
        continue;
      }
      BjSnack.error(context, e.message);
      return false;
    } catch (_) {
      if (context.mounted) BjSnack.error(context, 'Something went wrong. Try again.');
      return false;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// This broke something
// ─────────────────────────────────────────────────────────────────────────────

/// What the regression sheet ended with. [itemKey] is the regression item
/// to show; [alreadyReported] means it was filed earlier.
class DevRegressionOutcome {
  final String? itemKey;
  final bool alreadyReported;

  const DevRegressionOutcome({this.itemKey, this.alreadyReported = false});

  String get message =>
      alreadyReported ? "You've already reported a problem with this. It's in your queue." : "Thanks. It's first in line.";
}

/// Opens "What broke?" for a live [item]. Null when dismissed.
Future<DevRegressionOutcome?> showDevQueueRegressionSheet(
  BuildContext context,
  DevQueueItem item,
  DevQueueService service,
) =>
    showBjSheet<DevRegressionOutcome>(
      context,
      title: 'What broke?',
      subtitle: item.displayTitle,
      builder: (_) => DevQueueRegressionSheet(item: item, service: service),
    );

class DevQueueRegressionSheet extends StatefulWidget {
  final DevQueueItem item;
  final DevQueueService service;

  const DevQueueRegressionSheet({super.key, required this.item, required this.service});

  @override
  State<DevQueueRegressionSheet> createState() => _DevQueueRegressionSheetState();
}

class _DevQueueRegressionSheetState extends State<DevQueueRegressionSheet> {
  final _description = TextEditingController();
  bool _sending = false;
  String? _error;

  /// One key per report, so a retry after a lost response files it once.
  String? _idempotencyKey;

  @override
  void initState() {
    super.initState();
    _description.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _description.text.trim();
    if (text.isEmpty || text.length > _maxDescription || _sending) return;
    _idempotencyKey ??= widget.service.newKey();
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final key = await widget.service.reportRegression(widget.item.key, text, idempotencyKey: _idempotencyKey);
      if (mounted) Navigator.of(context).pop(DevRegressionOutcome(itemKey: key));
    } on DevQueueException catch (e) {
      if (!mounted) return;
      if (e.reason == 'already-reported') {
        Navigator.of(context).pop(DevRegressionOutcome(itemKey: e.itemKey, alreadyReported: true));
        return;
      }
      setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = _description.text.trim();
    final canSend = !_sending && text.isNotEmpty && text.length <= _maxDescription;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _description,
          enabled: !_sending,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          maxLength: _maxDescription,
          textCapitalization: TextCapitalization.sentences,
          decoration: _field("What's going wrong since this went live?"),
        ),
        const SizedBox(height: BjSpace.xs),
        const BjInlineNote(
          "This goes to the front of your queue and doesn't use your spot.",
          icon: Icons.bolt_rounded,
        ),
        _errorLine(_error),
        BjSheetActions(
          primaryLabel: 'Report it',
          primaryIcon: Icons.report_problem_outlined,
          busy: _sending,
          onPrimary: canSend ? _send : null,
        ),
      ],
    );
  }
}
