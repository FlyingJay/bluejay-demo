import 'package:flutter/material.dart';
import 'package:shared_services/email_recipients.dart';

/// A capped list of extra email inputs: a "+ Add recipient" button appends an
/// address box (up to [maxRecipients]), each box has a remove button, and
/// entries are validated inline with the same rules the server applies
/// (`normalizeEmailRecipients` in `functions/_shared.js`).
///
/// Use it next to a send action whose primary recipient is resolved
/// server-side; pass that address as [primaryEmail] so re-entering it is
/// flagged as already included. The raw entries are reported through
/// [onChanged]; callers should run them through [normalizeEmailRecipients]
/// before sending.
class AdditionalEmailRecipientsField extends StatefulWidget {
  final int maxRecipients;
  final String? primaryEmail;
  final ValueChanged<List<String>> onChanged;
  final bool enabled;
  final String addLabel;
  final String fieldLabel;

  const AdditionalEmailRecipientsField({
    super.key,
    required this.maxRecipients,
    required this.onChanged,
    this.primaryEmail,
    this.enabled = true,
    this.addLabel = 'Add recipient',
    this.fieldLabel = 'Additional recipient email',
  });

  @override
  State<AdditionalEmailRecipientsField> createState() =>
      _AdditionalEmailRecipientsFieldState();
}

class _AdditionalEmailRecipientsFieldState
    extends State<AdditionalEmailRecipientsField> {
  final List<TextEditingController> _controllers = [];

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _notify() {
    widget.onChanged(
      _controllers.map((c) => c.text).toList(growable: false),
    );
  }

  void _add() {
    if (_controllers.length >= widget.maxRecipients) return;
    setState(() => _controllers.add(TextEditingController()));
    _notify();
  }

  void _remove(int index) {
    final removed = _controllers.removeAt(index);
    setState(() {});
    // Dispose after the frame that stops rendering its TextField.
    WidgetsBinding.instance.addPostFrameCallback((_) => removed.dispose());
    _notify();
  }

  /// Inline error for the entry at [index], or null when it's fine (or blank).
  String? _errorFor(int index) {
    final raw = _controllers[index].text.trim();
    if (raw.isEmpty) return null;
    final email = normalizeEmailAddress(raw);
    if (email.isEmpty) return 'Enter a valid email address';
    if (email == normalizeEmailAddress(widget.primaryEmail)) {
      return 'Already a recipient';
    }
    for (var i = 0; i < index; i++) {
      if (normalizeEmailAddress(_controllers[i].text) == email) {
        return 'Already a recipient';
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final canAdd = widget.enabled && _controllers.length < widget.maxRecipients;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < _controllers.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    key: ValueKey(_controllers[i]),
                    controller: _controllers[i],
                    enabled: widget.enabled,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: '${widget.fieldLabel} ${i + 1}',
                      prefixIcon: const Icon(Icons.alternate_email),
                      border: const OutlineInputBorder(),
                      isDense: true,
                      errorText: _errorFor(i),
                    ),
                    onChanged: (_) {
                      setState(() {});
                      _notify();
                    },
                  ),
                ),
                IconButton(
                  tooltip: 'Remove recipient',
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: widget.enabled ? () => _remove(i) : null,
                ),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: canAdd ? _add : null,
            icon: const Icon(Icons.add),
            label: Text(
              _controllers.length >= widget.maxRecipients
                  ? 'Maximum of ${widget.maxRecipients} additional recipients'
                  : widget.addLabel,
            ),
          ),
        ),
      ],
    );
  }
}
