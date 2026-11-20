import 'dart:async';

import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:shared_services/active_group_service.dart';
import 'package:shared_services/user_app_entitlements.dart';
import 'package:wiki/app_help.dart';

import 'constants.dart';
import 'help_desk_api.dart';
import 'help_desk_models.dart';

/// Finds guides matching what someone is typing (AppHelpDocs.suggest unless
/// a test swaps it).
typedef GuideSuggester = Future<List<SuggestedGuide>> Function(String text, {bool forGuest});

/// The default [GuideSuggester]: the bundled app guides.
Future<List<SuggestedGuide>> defaultGuideSuggester(String text, {bool forGuest = false}) =>
    AppHelpDocs.suggest(text, forGuest: forGuest);

/// Whether [entitlements] give any Help Desk access in [groupId] (member,
/// admin or admitted guest): enough to offer "Contact" from another app.
/// Whether the group takes this person's tickets is decided when they open it.
bool mayContactHelpDesk(UserAppEntitlements entitlements, String groupId) {
  if (groupId.isEmpty || entitlements.status != 'ACTIVE' || entitlements.deniedScopes.contains(groupId)) {
    return false;
  }
  final scope = '$groupId:$APP_ID';
  return entitlements.entitlements.any((e) => e == scope || e.startsWith('$scope:'));
}

/// The new-ticket form. [upstream] files it from the group to the desk above
/// (the "Contact Bluejay" tab). Pops the new ticket's id.
class NewTicketForm extends StatefulWidget {
  final HelpDeskApi api;
  final HelpDeskOverview overview;
  final bool upstream;
  final TicketContext ticketContext;
  final GuideSuggester suggestGuides;

  const NewTicketForm({
    super.key,
    required this.api,
    required this.overview,
    this.upstream = false,
    this.ticketContext = const TicketContext(),
    this.suggestGuides = defaultGuideSuggester,
  });

  @override
  State<NewTicketForm> createState() => _NewTicketFormState();
}

class _NewTicketFormState extends State<NewTicketForm> {
  final _subject = TextEditingController();
  final _body = TextEditingController();
  String? _category;
  String _priority = 'normal';
  bool _busy = false;
  String? _error;
  List<SuggestedGuide> _guides = const [];
  Timer? _debounce;
  int _searchSeq = 0;

  @override
  void initState() {
    super.initState();
    _subject.addListener(_onTextChanged);
    _body.addListener(_onTextChanged);
    if (widget.ticketContext.orderRef != null && widget.overview.categories.contains('Order')) {
      _category = 'Order';
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    setState(() {});
    if (widget.upstream) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _searchGuides);
  }

  Future<void> _searchGuides() async {
    final text = '${_subject.text} ${_body.text}'.trim();
    final seq = ++_searchSeq;
    final guides = text.length < 8
        ? const <SuggestedGuide>[]
        : await widget.suggestGuides(text, forGuest: widget.overview.isGuest);
    if (!mounted || seq != _searchSeq) return;
    setState(() => _guides = guides);
  }

  bool get _valid => _subject.text.trim().isNotEmpty && _body.text.trim().isNotEmpty;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await widget.api.create(
        groupId: widget.overview.groupId,
        subject: _subject.text.trim(),
        body: _body.text.trim(),
        category: _category,
        priority: _priority,
        upstream: widget.upstream,
        context: widget.ticketContext,
      );
      if (mounted) Navigator.of(context).pop(id);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = helpDeskErrorMessage(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.overview;
    final categories = widget.upstream ? const <String>[] : o.categories;
    final priorities = widget.upstream ? ticketPriorities : const ['normal', 'high'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!widget.upstream && o.welcome.isNotEmpty) ...[
          BjInlineNote(o.welcome, icon: Icons.waving_hand_outlined),
          const SizedBox(height: BjSpace.md),
        ],
        if (widget.ticketContext.appName != null || widget.ticketContext.orderRef != null) ...[
          Wrap(spacing: BjSpace.sm, runSpacing: BjSpace.xs, children: [
            if (widget.ticketContext.appName != null)
              BjStatusPill(label: 'About ${widget.ticketContext.appName}', icon: Icons.apps_rounded),
            if (widget.ticketContext.orderRef != null)
              BjStatusPill(label: 'Order ${widget.ticketContext.orderRef}', icon: Icons.receipt_long_outlined),
          ]),
          const SizedBox(height: BjSpace.md),
        ],
        TextField(
          key: const Key('help-desk-subject'),
          controller: _subject,
          maxLength: 120,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: 'Subject', hintText: 'A short summary'),
        ),
        const SizedBox(height: BjSpace.sm),
        TextField(
          key: const Key('help-desk-body'),
          controller: _body,
          maxLength: 5000,
          minLines: 4,
          maxLines: 10,
          decoration: InputDecoration(
            labelText: widget.upstream ? 'What does your group need?' : 'How can we help?',
            hintText: 'What happened, what you expected, and anything you already tried',
            alignLabelWithHint: true,
          ),
        ),
        if (_guides.isNotEmpty) ...[
          const SizedBox(height: BjSpace.sm),
          _GuideSuggestions(guides: _guides),
        ],
        if (categories.isNotEmpty) ...[
          const SizedBox(height: BjSpace.md),
          Text('Topic', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: BjSpace.xs),
          Wrap(spacing: BjSpace.sm, runSpacing: BjSpace.xs, children: [
            for (final c in categories)
              ChoiceChip(
                label: Text(c),
                selected: _category == c,
                onSelected: (on) => setState(() => _category = on ? c : null),
              ),
          ]),
        ],
        const SizedBox(height: BjSpace.md),
        Text('Priority', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: BjSpace.xs),
        SegmentedButton<String>(
          segments: [for (final p in priorities) ButtonSegment(value: p, label: Text(priorityLabel(p)))],
          selected: {_priority},
          onSelectionChanged: (s) => setState(() => _priority = s.first),
        ),
        if (_error != null) ...[
          const SizedBox(height: BjSpace.md),
          BjInlineNote(_error!, tone: BjTone.danger, icon: Icons.error_outline_rounded),
        ],
        const SizedBox(height: BjSpace.lg),
        BjSheetActions(
          primaryLabel: 'Send',
          primaryIcon: Icons.send_rounded,
          busy: _busy,
          onPrimary: _valid && !_busy ? _submit : null,
          onCancel: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

class _GuideSuggestions extends StatelessWidget {
  final List<SuggestedGuide> guides;

  const _GuideSuggestions({required this.guides});

  @override
  Widget build(BuildContext context) {
    return BjCard(
      tone: BjTone.info,
      padding: const EdgeInsets.all(BjSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('These guides might answer it', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: BjSpace.xs),
          Wrap(spacing: BjSpace.sm, runSpacing: BjSpace.xs, children: [
            for (final g in guides)
              ActionChip(
                avatar: const Icon(Icons.menu_book_rounded, size: 18),
                label: Text('How ${g.title} works'),
                onPressed: () => showAppHelp(context, appName: g.title, doc: g.doc),
              ),
          ]),
        ],
      ),
    );
  }
}

/// Opens the new-ticket form for [overview]'s group. Pops the new ticket's
/// id, or null when cancelled.
Future<String?> showNewTicketSheet(
  BuildContext context, {
  required HelpDeskOverview overview,
  HelpDeskApi api = const HelpDeskApi(),
  bool upstream = false,
  TicketContext ticketContext = const TicketContext(),
  GuideSuggester suggestGuides = defaultGuideSuggester,
}) {
  final to = upstream ? overview.upstreamLabel : overview.deskLabel;
  return showBjSheet<String>(
    context,
    title: upstream ? 'Contact $to' : 'Ask ${to.isEmpty ? 'for help' : to}',
    subtitle: upstream
        ? 'For something your group needs help with. Only your group\'s admins see this request.'
        : 'Your request goes to the people who can help. You\'ll be notified when they reply.',
    builder: (_) => NewTicketForm(
      api: api,
      overview: overview,
      upstream: upstream,
      ticketContext: ticketContext,
      suggestGuides: suggestGuides,
    ),
  );
}

/// "Contact {group}" from inside another app (the help tab): loads the
/// active group's Help Desk, opens the form with [appId]/[appName] as the
/// ticket's context, and confirms. Explains instead when the group doesn't
/// take this person's tickets. Returns the new ticket's id.
Future<String?> contactHelpDesk(
  BuildContext context, {
  String? appId,
  String? appName,
  String? groupId,
  HelpDeskApi api = const HelpDeskApi(),
}) async {
  final group = groupId ?? ActiveGroupService.instance.activeGroupId ?? '';
  final messenger = ScaffoldMessenger.maybeOf(context);
  HelpDeskOverview overview;
  try {
    overview = await api.overview(group);
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(helpDeskErrorMessage(e))));
    return null;
  }
  if (!context.mounted) return null;
  if (!overview.canFile) {
    messenger?.showSnackBar(const SnackBar(content: Text('This group isn\'t taking requests here yet.')));
    return null;
  }
  final id = await showNewTicketSheet(
    context,
    overview: overview,
    api: api,
    ticketContext: TicketContext(appId: appId, appName: appName),
  );
  if (id != null) {
    messenger?.showSnackBar(SnackBar(
      content: Text('Sent to ${overview.deskLabel}. You\'ll be notified when they reply.'),
    ));
  }
  return id;
}

/// Escalation: what to send the desk above. Pops (summary, shareThread).
class EscalateForm extends StatefulWidget {
  final String upstreamLabel;
  final String requesterName;

  const EscalateForm({super.key, required this.upstreamLabel, required this.requesterName});

  @override
  State<EscalateForm> createState() => _EscalateFormState();
}

class _EscalateFormState extends State<EscalateForm> {
  final _summary = TextEditingController();
  bool _share = false;

  @override
  void dispose() {
    _summary.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final who = widget.requesterName.isEmpty ? 'the customer' : widget.requesterName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const Key('help-desk-escalate-summary'),
          controller: _summary,
          minLines: 3,
          maxLines: 8,
          maxLength: 5000,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'What do you need help with?',
            hintText: 'Summarize the problem and what you have tried',
            alignLabelWithHint: true,
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _share,
          onChanged: (v) => setState(() => _share = v),
          title: Text('Include the conversation with $who'),
          subtitle: const Text('Off: only your summary is shared. Internal notes are never shared.'),
        ),
        BjInlineNote(
          '$who sees that you asked ${widget.upstreamLabel} for help, and keeps talking only to you.',
          icon: Icons.privacy_tip_outlined,
        ),
        const SizedBox(height: BjSpace.lg),
        BjSheetActions(
          primaryLabel: 'Escalate',
          primaryIcon: Icons.north_east_rounded,
          onPrimary: _summary.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop((summary: _summary.text.trim(), shareThread: _share)),
          onCancel: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

Future<({String summary, bool shareThread})?> showEscalateSheet(
  BuildContext context, {
  required String upstreamLabel,
  required String requesterName,
}) =>
    showBjSheet<({String summary, bool shareThread})>(
      context,
      title: 'Escalate to $upstreamLabel',
      subtitle: 'Opens a linked request from your group. You relay the answer.',
      builder: (_) => EscalateForm(upstreamLabel: upstreamLabel, requesterName: requesterName),
    );
