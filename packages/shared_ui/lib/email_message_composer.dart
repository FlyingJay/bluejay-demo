import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:shared_services/ai_service.dart';

/// Subject and message fields for an email the app sends on the user's
/// behalf (e.g. a quote to a broker), with "Improve with AI" to polish the
/// message and Undo to put the previous text back.
///
/// The caller owns the controllers and sends their text; an empty field means
/// "use the default" to the server. [appId] is the app the AI tokens are spent
/// in; [purpose] tells the model what the email is ("a commercial property
/// insurance quote sent to a broker's producer"). [onReset] restores the
/// caller's default text.
class EmailMessageComposer extends StatefulWidget {
  const EmailMessageComposer({
    super.key,
    required this.subjectController,
    required this.messageController,
    required this.appId,
    required this.purpose,
    this.onReset,
    this.enabled = true,
    this.accentColor,
    this.aiModel,
  });

  final TextEditingController subjectController;
  final TextEditingController messageController;
  final String appId;
  final String purpose;
  final VoidCallback? onReset;
  final bool enabled;
  final Color? accentColor;

  /// Overrides the model used by "Improve with AI" (tests).
  final AiModel? aiModel;

  static const int maxSubjectChars = 200;
  static const int maxMessageChars = 5000;

  @override
  State<EmailMessageComposer> createState() => _EmailMessageComposerState();
}

class _EmailMessageComposerState extends State<EmailMessageComposer> {
  bool _improving = false;
  String? _beforeImprove;

  String _prompt(String message) => '''
You are editing an email for ${widget.purpose}.
Improve the message below: clear, warm and professional, well organized, correct grammar and spelling.
Keep every fact, name, number, date and request exactly as given. Do not invent details, prices, promises or placeholders, and keep any sign-off and name.
Keep it about the same length or shorter. Reply with the improved message only: no subject line, no preamble, no quotes, no markdown.

Message:
$message''';

  Future<void> _improve() async {
    final original = widget.messageController.text.trim();
    if (original.isEmpty) return;
    setState(() => _improving = true);
    try {
      final model = widget.aiModel ??
          AiModel(appId: widget.appId, model: 'gemini-2.5-flash');
      final response = await model.generateContent([AiContent.text(_prompt(original))]);
      final improved = (response.text ?? '').trim();
      if (!mounted) return;
      if (improved.isEmpty) throw const AiException('The AI returned an empty message.');
      setState(() {
        _beforeImprove = widget.messageController.text;
        widget.messageController.text = improved.length > EmailMessageComposer.maxMessageChars
            ? improved.substring(0, EmailMessageComposer.maxMessageChars)
            : improved;
      });
    } catch (e) {
      if (mounted) {
        BjSnack.error(context,
            'Couldn\'t improve the message: ${e is AiException ? e.message : 'please try again.'}');
      }
    } finally {
      if (mounted) setState(() => _improving = false);
    }
  }

  void _undo() {
    final previous = _beforeImprove;
    if (previous == null) return;
    setState(() {
      widget.messageController.text = previous;
      _beforeImprove = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && !_improving;
    final accent = widget.accentColor ?? context.bj.accent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: widget.subjectController,
          enabled: enabled,
          maxLength: EmailMessageComposer.maxSubjectChars,
          decoration: const InputDecoration(
            labelText: 'Subject',
            counterText: '',
          ),
        ),
        const SizedBox(height: BjSpace.md),
        TextField(
          controller: widget.messageController,
          enabled: enabled,
          minLines: 5,
          maxLines: 14,
          maxLength: EmailMessageComposer.maxMessageChars,
          keyboardType: TextInputType.multiline,
          onChanged: (_) {
            if (_beforeImprove != null) setState(() => _beforeImprove = null);
          },
          decoration: const InputDecoration(
            labelText: 'Message',
            alignLabelWithHint: true,
          ),
        ),
        Wrap(
          spacing: BjSpace.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton.icon(
              onPressed: enabled ? _improve : null,
              style: TextButton.styleFrom(foregroundColor: accent),
              icon: _improving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_awesome_outlined, size: 18),
              label: Text(_improving ? 'Improving…' : 'Improve with AI'),
            ),
            if (_beforeImprove != null)
              TextButton.icon(
                onPressed: enabled ? _undo : null,
                style: TextButton.styleFrom(foregroundColor: accent),
                icon: const Icon(Icons.undo, size: 18),
                label: const Text('Undo'),
              ),
            if (widget.onReset != null)
              TextButton.icon(
                onPressed: enabled
                    ? () {
                        widget.onReset!();
                        setState(() => _beforeImprove = null);
                      }
                    : null,
                style: TextButton.styleFrom(foregroundColor: accent),
                icon: const Icon(Icons.restart_alt, size: 18),
                label: const Text('Reset to default'),
              ),
          ],
        ),
      ],
    );
  }
}
