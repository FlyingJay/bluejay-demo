import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:shared_services/ticket_close_reasons.dart';

/// Asks for a close reason from [reasons] (a list in
/// shared_services/ticket_close_reasons.dart) and a note. Choosing a reason
/// that needs a note ("Needs more information") relabels the field and
/// keeps [confirmLabel] disabled until it's filled in. Null when cancelled.
Future<TicketCloseSelection?> showTicketCloseReasonDialog(
  BuildContext context, {
  required List<TicketCloseReason> reasons,
  required String title,
  String intro = 'The submitter is notified with the reason and any details.',
  String confirmLabel = 'Close',
  Widget? titleWidget,
  ButtonStyle? confirmStyle,
}) =>
    showDialog<TicketCloseSelection>(
      context: context,
      builder: (_) => TicketCloseReasonDialog(
        reasons: reasons,
        title: title,
        intro: intro,
        confirmLabel: confirmLabel,
        titleWidget: titleWidget,
        confirmStyle: confirmStyle,
      ),
    );

class TicketCloseReasonDialog extends StatefulWidget {
  final List<TicketCloseReason> reasons;
  final String title;
  final String intro;
  final String confirmLabel;

  /// Replaces the plain [title] text (a screen's own status chip).
  final Widget? titleWidget;
  final ButtonStyle? confirmStyle;

  const TicketCloseReasonDialog({
    super.key,
    required this.reasons,
    required this.title,
    this.intro = '',
    this.confirmLabel = 'Close',
    this.titleWidget,
    this.confirmStyle,
  });

  @override
  State<TicketCloseReasonDialog> createState() => _TicketCloseReasonDialogState();
}

class _TicketCloseReasonDialogState extends State<TicketCloseReasonDialog> {
  final _note = TextEditingController();
  late TicketCloseReason _selected = widget.reasons.first;

  @override
  void initState() {
    super.initState();
    _note.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selection = TicketCloseSelection(reason: _selected, note: _note.text);
    return AlertDialog(
      title: widget.titleWidget ?? Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.intro.isNotEmpty) ...[
              Text(widget.intro, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: BjSpace.md),
            ],
            DropdownButtonFormField<TicketCloseReason>(
              initialValue: _selected,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Reason'),
              items: [
                for (final reason in widget.reasons) DropdownMenuItem(value: reason, child: Text(reason.label)),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _selected = value);
              },
            ),
            const SizedBox(height: BjSpace.md),
            TextField(
              controller: _note,
              minLines: 2,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: _selected.noteFieldLabel,
                helperText: _selected.requiresNote ? 'Required. The requester reads this and can answer it.' : null,
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          style: widget.confirmStyle,
          onPressed: selection.isComplete
              ? () => Navigator.pop(context, TicketCloseSelection(reason: _selected, note: _note.text))
              : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
