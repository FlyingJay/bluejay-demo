import 'package:bluejay_design/bluejay_design.dart';
import 'package:bug_reports/bug_reports_screen.dart';
import 'package:feature_voting/feature_voting_screen.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';
import 'package:shared_services/shared_place.dart';
import 'package:shared_ui/readable_selectable_text.dart';

import 'help_desk_api.dart';
import 'help_desk_models.dart';
import 'help_desk_record_types.dart';
import 'help_desk_sheets.dart';

/// Files the ticket as a bug report or idea through Improve Apps' own forms
/// (tests replace it). Returns the new item's id.
typedef ChangeFiler = Future<String?> Function(
    BuildContext context, String itemType, TicketDetail ticket, fire_auth.User? user);

/// The default [ChangeFiler]: Improve Apps' bug report and idea forms, with
/// the ticket's app pre-selected.
Future<String?> fileChangeInImproveApps(BuildContext context, String itemType, TicketDetail ticket, fire_auth.User? user) {
  final appId = ticket.context['appId'];
  final appName = ticket.context['appName'];
  return itemType == 'bug'
      ? showBugSubmitSheet(context, currentUser: user, initialRelatedAppId: appId, initialRelatedAppName: appName)
      : showFeatureSubmitDialog(context, currentUser: user, initialRelatedAppId: appId, initialRelatedAppName: appName);
}

/// One ticket: its conversation, and what the viewer can do with it. A
/// requester replies, marks it solved or reopens it; the desk also writes
/// internal notes, uses saved replies, assigns, changes the status,
/// escalates, and files it as a bug report or idea.
///
/// Someone on both sides (a group admin with a ticket on their own desk)
/// acts as the desk.
class HelpDeskTicketScreen extends StatefulWidget {
  final String ticketId;
  final HelpDeskApi api;
  final fire_auth.User? currentUser;
  final ChangeFiler fileChange;
  final DateTime Function() clock;

  const HelpDeskTicketScreen({
    super.key,
    required this.ticketId,
    this.api = const HelpDeskApi(),
    this.currentUser,
    this.fileChange = fileChangeInImproveApps,
    this.clock = DateTime.now,
  });

  @override
  State<HelpDeskTicketScreen> createState() => _HelpDeskTicketScreenState();
}

class _HelpDeskTicketScreenState extends State<HelpDeskTicketScreen> {
  TicketDetail? _ticket;
  Object? _error;
  bool _busy = false;
  bool _internal = false;
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
      final ticket = await widget.api.ticket(widget.ticketId);
      if (!mounted) return;
      setState(() {
        _ticket = ticket;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    setState(() => _busy = true);
    try {
      await action();
      await _load();
      if (done != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(helpDeskErrorMessage(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send({bool resolve = false}) async {
    final body = _reply.text.trim();
    if (body.isEmpty) return;
    final internal = _internal;
    await _run(() async {
      await widget.api.reply(widget.ticketId, body, internal: internal, resolve: resolve);
      _reply.clear();
    });
  }

  Future<void> _setStatus(TicketStatus status) => _run(() => widget.api.setStatus(widget.ticketId, status));

  Future<void> _close(TicketDetail t) async {
    final ok = await showBjConfirm(
      context,
      title: 'Close this request?',
      message: 'Your team can no longer reply to it. ${t.summary.requesterName.isEmpty ? 'The requester' : t.summary.requesterName} '
          'can still reply, which reopens it.',
      confirmLabel: 'Close',
      destructive: true,
      icon: Icons.lock_outline_rounded,
    );
    if (ok && mounted) await _setStatus(TicketStatus.closed);
  }

  Future<void> _escalate(TicketDetail t) async {
    final choice = await showEscalateSheet(
      context,
      upstreamLabel: t.desk!.upstreamLabel,
      requesterName: t.summary.requesterName,
    );
    if (choice == null || !mounted) return;
    await _run(
      () => widget.api.escalate(widget.ticketId, summary: choice.summary, shareThread: choice.shareThread),
      done: 'Escalated to ${t.desk!.upstreamLabel}.',
    );
  }

  Future<void> _assign(TicketDetail t) async {
    final agents = t.desk!.agents;
    final picked = await showBjSheet<String>(
      context,
      title: 'Assign',
      builder: (context) => Column(mainAxisSize: MainAxisSize.min, children: [
        for (final a in agents)
          ListTile(
            leading: Icon(a.uid == t.summary.assigneeUid ? Icons.radio_button_checked : Icons.radio_button_off),
            title: Text(a.name),
            onTap: () => Navigator.of(context).pop(a.uid),
          ),
        ListTile(
          leading: const Icon(Icons.person_off_outlined),
          title: const Text('Nobody'),
          onTap: () => Navigator.of(context).pop(''),
        ),
      ]),
    );
    if (picked == null || !mounted) return;
    await _run(() => widget.api.assign(widget.ticketId, picked.isEmpty ? null : picked));
  }

  Future<void> _file(TicketDetail t, String itemType) async {
    final id = await widget.fileChange(context, itemType, t, widget.currentUser);
    if (id == null || id.isEmpty || !mounted) return;
    await _run(
      () => widget.api.linkChange(widget.ticketId, itemType: itemType, itemId: id),
      done: itemType == 'bug' ? 'Filed as a bug report.' : 'Filed as an idea.',
    );
  }

  Future<void> _pickSavedReply(TicketDetail t) async {
    final reply = await showBjSheet<SavedReply>(
      context,
      title: 'Saved replies',
      builder: (context) => Column(mainAxisSize: MainAxisSize.min, children: [
        for (final r in t.desk!.savedReplies)
          ListTile(
            title: Text(r.title),
            subtitle: Text(r.body, maxLines: 2, overflow: TextOverflow.ellipsis),
            onTap: () => Navigator.of(context).pop(r),
          ),
      ]),
    );
    if (reply == null) return;
    final current = _reply.text.trim();
    _reply.text = current.isEmpty ? reply.body : '$current\n\n${reply.body}';
    setState(() {});
  }

  void _open(String ticketId) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => HelpDeskTicketScreen(
        ticketId: ticketId,
        api: widget.api,
        currentUser: widget.currentUser,
        fileChange: widget.fileChange,
        clock: widget.clock,
      ),
    ));
  }

  List<BjMenuAction> _deskActions(TicketDetail t) {
    final status = t.summary.status;
    return [
      if (t.desk!.agents.isNotEmpty)
        BjMenuAction(label: 'Assign', icon: Icons.person_add_alt_outlined, onSelected: () => _assign(t)),
      if (t.desk!.canEscalate)
        BjMenuAction(
          label: 'Escalate to ${t.desk!.upstreamLabel}',
          icon: Icons.north_east_rounded,
          onSelected: () => _escalate(t),
        ),
      BjMenuAction(label: 'File as a bug report', icon: Icons.bug_report_outlined, onSelected: () => _file(t, 'bug')),
      BjMenuAction(label: 'File as an idea', icon: Icons.lightbulb_outline_rounded, onSelected: () => _file(t, 'feature')),
      if (status != TicketStatus.resolved && status != TicketStatus.closed)
        BjMenuAction(label: 'Mark resolved', icon: Icons.check_circle_outline_rounded, onSelected: () => _setStatus(TicketStatus.resolved)),
      if (status == TicketStatus.resolved || status == TicketStatus.closed)
        BjMenuAction(label: 'Reopen', icon: Icons.replay_rounded, onSelected: () => _setStatus(TicketStatus.open)),
      if (status != TicketStatus.closed)
        BjMenuAction(label: 'Close', icon: Icons.lock_outline_rounded, destructive: true, onSelected: () => _close(t)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final t = _ticket;
    if (t == null) {
      return BjPage(
        title: 'Request',
        body: _error == null
            ? const BjSkeletonList(count: 3)
            : BjStateView.error(error: helpDeskErrorMessage(_error!), onRetry: _load),
      );
    }
    final s = t.summary;
    final asDesk = t.asDesk;
    final display = statusDisplay(s.status, forDesk: asDesk);
    final page = BjPage(
      title: s.subject,
      subtitle: asDesk ? 'From ${s.requesterName}${s.groupName.isEmpty ? '' : ' · ${s.groupName}'}' : s.deskLabel,
      actions: [
        if (asDesk) BjOverflowMenu(actions: _deskActions(t)),
        if (!asDesk && t.asRequester && s.isActive)
          TextButton.icon(
            onPressed: _busy ? null : () => _setStatus(TicketStatus.resolved),
            icon: const Icon(Icons.check_rounded),
            label: const Text('Solved'),
          ),
      ],
      body: Column(children: [
        Expanded(
          child: BjScrollBody(
            onRefresh: _load,
            bottomInset: BjSpace.lg,
            children: [
              Wrap(spacing: BjSpace.sm, runSpacing: BjSpace.xs, children: [
                BjStatusPill(label: display.label, tone: display.tone, icon: display.icon),
                if (s.priority != 'normal')
                  BjStatusPill(
                    label: priorityLabel(s.priority),
                    tone: s.priority == 'urgent' ? BjTone.danger : BjTone.warning,
                    icon: Icons.priority_high_rounded,
                  ),
                if (s.category.isNotEmpty) BjStatusPill(label: s.category),
                if (asDesk && s.overdue) const BjStatusPill(label: 'Overdue', tone: BjTone.danger, icon: Icons.timer_outlined),
                if (asDesk && s.assigneeName.isNotEmpty) BjStatusPill(label: s.assigneeName, icon: Icons.person_outline_rounded),
              ]),
              if (asDesk) _DeskDetails(ticket: t, onOpen: _open),
              for (final m in t.messages) _MessageBubble(message: m, viewerIsDesk: asDesk, now: widget.clock()),
            ],
          ),
        ),
        if (s.status != TicketStatus.closed || t.asRequester)
          _Composer(
            controller: _reply,
            busy: _busy,
            asDesk: asDesk,
            internal: _internal,
            closed: s.status == TicketStatus.closed,
            hasSavedReplies: asDesk && (t.desk?.savedReplies.isNotEmpty ?? false),
            onInternalChanged: (v) => setState(() => _internal = v),
            onSavedReplies: () => _pickSavedReply(t),
            onSend: () => _send(),
            onSendAndResolve: () => _send(resolve: true),
          ),
      ]),
    );
    return PlaceMarker(args: {ticketArg: widget.ticketId}, title: s.subject, child: page);
  }
}

class _DeskDetails extends StatelessWidget {
  final TicketDetail ticket;
  final void Function(String ticketId) onOpen;

  const _DeskDetails({required this.ticket, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final t = ticket;
    final rows = <Widget>[
      if (t.requesterEmail.isNotEmpty) BjKeyValue(label: 'Email', value: t.requesterEmail),
      if (t.context['appName'] != null) BjKeyValue(label: 'App', value: t.context['appName']!),
      if (t.context['orderRef'] != null) BjKeyValue(label: 'Order', value: t.context['orderRef']!),
      if (t.linkedChanges.isNotEmpty)
        BjKeyValue(label: 'Filed as', value: t.linkedChanges.map((l) => l.label).join(', ')),
      if (t.upstreamTicketId != null)
        BjKeyValue(
          label: 'Escalated',
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: () => onOpen(t.upstreamTicketId!), child: const Text('Open the escalation')),
          ),
        ),
      if (t.parentTicketId != null && t.summary.requesterKind == 'group')
        const BjKeyValue(label: 'From', value: 'An escalated customer request'),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return BjCard(child: Column(children: rows));
  }
}

class _MessageBubble extends StatelessWidget {
  final TicketMessage message;
  final bool viewerIsDesk;
  final DateTime now;

  const _MessageBubble({required this.message, required this.viewerIsDesk, required this.now});

  @override
  Widget build(BuildContext context) {
    final bj = context.bj;
    final text = Theme.of(context).textTheme;
    final m = message;
    final when = relativeTime(m.createdAt, now);
    if (m.isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: BjSpace.lg),
        child: Row(children: [
          Icon(m.internal ? Icons.lock_outline_rounded : Icons.info_outline_rounded, size: 16, color: bj.inkMuted),
          const SizedBox(width: BjSpace.sm),
          Expanded(child: Text(m.body, style: text.bodySmall?.copyWith(color: bj.inkMuted))),
          Text(when, style: text.bodySmall?.copyWith(color: bj.inkSubtle)),
        ]),
      );
    }
    final mine = viewerIsDesk ? m.side == 'desk' : m.side == 'requester';
    final tone = m.internal ? BjTone.warning : (mine ? BjTone.accent : BjTone.neutral);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: BjCard(
          tone: tone,
          padding: const EdgeInsets.all(BjSpace.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              if (m.internal) ...[
                const Icon(Icons.lock_outline_rounded, size: 14),
                const SizedBox(width: BjSpace.xs),
              ],
              Expanded(
                child: Text(
                  m.internal ? '${m.authorName} · internal note' : m.authorName,
                  style: text.labelMedium,
                ),
              ),
              Text(when, style: text.bodySmall?.copyWith(color: bj.inkSubtle)),
            ]),
            const SizedBox(height: BjSpace.xs),
            ReadableSelectableText(m.body, style: text.bodyMedium),
          ]),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final bool busy;
  final bool asDesk;
  final bool internal;
  final bool closed;
  final bool hasSavedReplies;
  final ValueChanged<bool> onInternalChanged;
  final VoidCallback onSavedReplies;
  final VoidCallback onSend;
  final VoidCallback onSendAndResolve;

  const _Composer({
    required this.controller,
    required this.busy,
    required this.asDesk,
    required this.internal,
    required this.closed,
    required this.hasSavedReplies,
    required this.onInternalChanged,
    required this.onSavedReplies,
    required this.onSend,
    required this.onSendAndResolve,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 3,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(BjSpace.lg, BjSpace.sm, BjSpace.lg, BjSpace.sm),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: BjBreakpoint.formWidth),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (asDesk)
                Row(children: [
                  FilterChip(
                    label: const Text('Internal note'),
                    avatar: const Icon(Icons.lock_outline_rounded, size: 16),
                    selected: internal,
                    onSelected: onInternalChanged,
                  ),
                  const Spacer(),
                  if (hasSavedReplies)
                    TextButton.icon(
                      onPressed: onSavedReplies,
                      icon: const Icon(Icons.bookmarks_outlined, size: 18),
                      label: const Text('Saved replies'),
                    ),
                ]),
              TextField(
                key: const Key('help-desk-reply'),
                controller: controller,
                minLines: 1,
                maxLines: 6,
                maxLength: 5000,
                buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                decoration: InputDecoration(
                  hintText: closed
                      ? 'Reply to reopen this request'
                      : asDesk
                          ? (internal ? 'Note for your team only' : 'Reply to the requester')
                          : 'Reply',
                ),
              ),
              const SizedBox(height: BjSpace.sm),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (context, value, _) {
                  final ready = value.text.trim().isNotEmpty && !busy;
                  return Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    if (asDesk && !internal)
                      TextButton(onPressed: ready ? onSendAndResolve : null, child: const Text('Send and resolve')),
                    const SizedBox(width: BjSpace.sm),
                    BjBusyButton(
                      label: internal ? 'Add note' : 'Send',
                      icon: Icons.send_rounded,
                      busy: busy,
                      onPressed: ready ? onSend : null,
                    ),
                  ]);
                },
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
