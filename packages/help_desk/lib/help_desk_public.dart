import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:shared_ui/readable_selectable_text.dart';

import 'help_desk_api.dart';
import 'help_desk_models.dart';

/// The first path segment of Help Desk's public pages (a reserved group id,
/// RESERVED_GROUP_IDS in functions/_group_docs.js).
const helpDeskPathSegment = 'help';

/// A Help Desk public link: the form (`/help/<groupId>`, optionally
/// `?order=<ref>` from a Shop order) or one ticket (`/help/<groupId>/t/<token>`).
class HelpDeskLink {
  final String groupId;
  final String? token;
  final String? orderRef;

  const HelpDeskLink({required this.groupId, this.token, this.orderRef});

  static final _id = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
  static final _token = RegExp(r'^[A-Za-z0-9_-]{43}$');

  /// The link [uri] is, or null.
  static HelpDeskLink? fromUri(Uri uri) {
    final s = uri.pathSegments.where((p) => p.isNotEmpty).toList();
    if (s.isEmpty || s.first != helpDeskPathSegment || s.length < 2 || !_id.hasMatch(s[1])) return null;
    if (s.length == 2) {
      final order = uri.queryParameters['order']?.trim();
      return HelpDeskLink(groupId: s[1], orderRef: order == null || order.isEmpty ? null : order);
    }
    if (s.length == 4 && s[2] == 't' && _token.hasMatch(s[3])) return HelpDeskLink(groupId: s[1], token: s[3]);
    return null;
  }

  /// `/help/<groupId>?order=<ref>`, the link Shop puts on an order.
  static String formPath(String groupId, {String? orderRef}) => Uri(
        path: '/$helpDeskPathSegment/$groupId',
        queryParameters: orderRef == null || orderRef.isEmpty ? null : {'order': orderRef},
      ).toString();
}

/// The public page [uri] opens, or null when it isn't a Help Desk link.
Widget? publicHelpDeskScreenFor(Uri uri, {HelpDeskApi api = const HelpDeskApi()}) {
  final link = HelpDeskLink.fromUri(uri);
  if (link == null) return null;
  return link.token == null
      ? PublicHelpFormScreen(groupId: link.groupId, orderRef: link.orderRef, api: api)
      : PublicHelpTicketScreen(token: link.token!, api: api);
}

/// Whether [email] passes the check helpDeskPublicSubmit applies (the same
/// pattern and length limit as functions/_help_desk.js).
bool isHelpDeskEmail(String email) {
  final e = email.trim();
  return e.length <= 254 && _emailPattern.hasMatch(e);
}

final _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

/// A group's signed-out help form: name, email and the request. Replies come
/// by email, with a link back to [PublicHelpTicketScreen].
class PublicHelpFormScreen extends StatefulWidget {
  final String groupId;
  final String? orderRef;
  final HelpDeskApi api;

  const PublicHelpFormScreen({super.key, required this.groupId, this.orderRef, this.api = const HelpDeskApi()});

  @override
  State<PublicHelpFormScreen> createState() => _PublicHelpFormScreenState();
}

class _PublicHelpFormScreenState extends State<PublicHelpFormScreen> {
  PublicDesk? _desk;
  Object? _error;
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _emailFocus = FocusNode();
  // Set once the person leaves the email field, so the error doesn't show
  // while they are still typing the address for the first time.
  bool _emailLeft = false;
  final _subject = TextEditingController();
  final _body = TextEditingController();
  late final _order = TextEditingController(text: widget.orderRef ?? '');
  String? _category;
  bool _busy = false;
  String? _submitError;
  String? _sentUrl;

  @override
  void initState() {
    super.initState();
    _emailFocus.addListener(_onEmailFocus);
    _load();
  }

  @override
  void dispose() {
    for (final c in [_name, _email, _subject, _body, _order]) {
      c.dispose();
    }
    _emailFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final desk = await widget.api.publicDesk(widget.groupId);
      if (!mounted) return;
      setState(() {
        _desk = desk;
        if (widget.orderRef != null && desk.categories.contains('Order')) _category = 'Order';
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _onEmailFocus() {
    if (!_emailFocus.hasFocus && !_emailLeft) setState(() => _emailLeft = true);
  }

  /// Why the email keeps Send disabled, once the person has left the field.
  String? get _emailError =>
      _emailLeft && _email.text.trim().isNotEmpty && !isHelpDeskEmail(_email.text) ? 'Enter a valid email address.' : null;

  bool get _valid =>
      _name.text.trim().isNotEmpty &&
      isHelpDeskEmail(_email.text) &&
      _subject.text.trim().isNotEmpty &&
      _body.text.trim().isNotEmpty;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _submitError = null;
    });
    try {
      final url = await widget.api.publicSubmit(
        groupId: widget.groupId,
        name: _name.text.trim(),
        email: _email.text.trim(),
        subject: _subject.text.trim(),
        body: _body.text.trim(),
        category: _category,
        orderRef: _order.text.trim(),
      );
      if (mounted) setState(() => _sentUrl = url);
    } catch (e) {
      if (mounted) setState(() => _submitError = helpDeskErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final desk = _desk;
    if (desk == null) {
      return BjPage(
        title: 'Get help',
        body: _error == null
            ? const BjSkeletonList(count: 2)
            : const BjStateView.empty(
                icon: Icons.support_agent_rounded,
                title: 'This help page is not available',
                message: 'Check the link, or contact the business another way.',
              ),
      );
    }
    if (_sentUrl != null) {
      return BjPage(
        title: desk.groupName,
        body: BjScrollBody(maxWidth: BjBreakpoint.formWidth, children: [
          BjStateView(
            icon: Icons.mark_email_read_outlined,
            tone: BjTone.success,
            title: 'We got your request',
            message: 'We emailed you a link to it. ${desk.groupName} will reply by email.',
          ),
        ]),
      );
    }
    void changed(String _) => setState(() {});
    return BjPage(
      title: desk.groupName,
      subtitle: 'Get help',
      body: BjScrollBody(maxWidth: BjBreakpoint.formWidth, children: [
        if (desk.welcome.isNotEmpty) BjInlineNote(desk.welcome, icon: Icons.waving_hand_outlined),
        BjCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(controller: _name, maxLength: 80, onChanged: changed, decoration: const InputDecoration(labelText: 'Your name')),
            TextField(
              controller: _email,
              focusNode: _emailFocus,
              keyboardType: TextInputType.emailAddress,
              onChanged: changed,
              decoration: InputDecoration(labelText: 'Email', helperText: 'Replies come here.', errorText: _emailError),
            ),
            const SizedBox(height: BjSpace.sm),
            TextField(controller: _subject, maxLength: 120, onChanged: changed, decoration: const InputDecoration(labelText: 'Subject')),
            TextField(
              controller: _body,
              maxLength: 5000,
              minLines: 4,
              maxLines: 10,
              onChanged: changed,
              decoration: const InputDecoration(labelText: 'How can we help?', alignLabelWithHint: true),
            ),
            TextField(controller: _order, maxLength: 80, decoration: const InputDecoration(labelText: 'Order number (optional)')),
            if (desk.categories.isNotEmpty) ...[
              const SizedBox(height: BjSpace.sm),
              Wrap(spacing: BjSpace.sm, runSpacing: BjSpace.xs, children: [
                for (final c in desk.categories)
                  ChoiceChip(
                    label: Text(c),
                    selected: _category == c,
                    onSelected: (on) => setState(() => _category = on ? c : null),
                  ),
              ]),
            ],
            if (_submitError != null) ...[
              const SizedBox(height: BjSpace.md),
              BjInlineNote(_submitError!, tone: BjTone.danger, icon: Icons.error_outline_rounded),
            ],
            const SizedBox(height: BjSpace.lg),
            Align(
              alignment: Alignment.centerRight,
              child: BjBusyButton(
                label: 'Send',
                icon: Icons.send_rounded,
                busy: _busy,
                onPressed: _valid && !_busy ? _submit : null,
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// One signed-out request, opened from the link in its emails: the
/// conversation, a reply box, and "This solved it".
class PublicHelpTicketScreen extends StatefulWidget {
  final String token;
  final HelpDeskApi api;

  const PublicHelpTicketScreen({super.key, required this.token, this.api = const HelpDeskApi()});

  @override
  State<PublicHelpTicketScreen> createState() => _PublicHelpTicketScreenState();
}

class _PublicHelpTicketScreenState extends State<PublicHelpTicketScreen> {
  TicketDetail? _ticket;
  Object? _error;
  bool _busy = false;
  final _reply = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final t = await widget.api.publicTicket(widget.token);
      if (mounted) setState(() => _ticket = t);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _send({bool resolve = false}) async {
    setState(() => _busy = true);
    try {
      final t = await widget.api.publicReply(widget.token, body: _reply.text.trim(), resolve: resolve);
      _reply.clear();
      if (mounted) setState(() => _ticket = t);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(helpDeskErrorMessage(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _ticket;
    if (t == null) {
      return BjPage(
        title: 'Your request',
        body: _error == null
            ? const BjSkeletonList(count: 2)
            : const BjStateView.empty(
                icon: Icons.link_off_rounded,
                title: 'This link has expired or is not valid',
                message: 'Use the link in the most recent email about your request.',
              ),
      );
    }
    final s = t.summary;
    final display = statusDisplay(s.status, forDesk: false);
    final text = Theme.of(context).textTheme;
    return BjPage(
      title: s.subject,
      subtitle: s.groupName,
      body: BjScrollBody(maxWidth: BjBreakpoint.formWidth, children: [
        Align(
          alignment: Alignment.centerLeft,
          child: BjStatusPill(label: display.label, tone: display.tone, icon: display.icon),
        ),
        for (final m in t.messages)
          m.isSystem
              ? Text(m.body, style: text.bodySmall?.copyWith(color: context.bj.inkMuted))
              : BjCard(
                  tone: m.side == 'requester' ? BjTone.accent : BjTone.neutral,
                  padding: const EdgeInsets.all(BjSpace.md),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(m.side == 'requester' ? 'You' : (m.authorName.isEmpty ? s.groupName : m.authorName),
                        style: text.labelMedium),
                    const SizedBox(height: BjSpace.xs),
                    ReadableSelectableText(m.body),
                  ]),
                ),
        BjCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(
              controller: _reply,
              minLines: 2,
              maxLines: 8,
              maxLength: 5000,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Reply', alignLabelWithHint: true),
            ),
            const SizedBox(height: BjSpace.sm),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              if (s.isActive)
                TextButton(onPressed: _busy ? null : () => _send(resolve: true), child: const Text('This solved it')),
              const SizedBox(width: BjSpace.sm),
              BjBusyButton(
                label: 'Send',
                icon: Icons.send_rounded,
                busy: _busy,
                onPressed: _reply.text.trim().isEmpty || _busy ? null : () => _send(),
              ),
            ]),
          ]),
        ),
      ]),
    );
  }
}
