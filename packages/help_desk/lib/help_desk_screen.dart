import 'package:bluejay_design/bluejay_design.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';
import 'package:shared_services/active_group_service.dart';

import 'help_desk_api.dart';
import 'help_desk_models.dart';
import 'help_desk_settings_screen.dart';
import 'help_desk_sheets.dart';
import 'help_desk_ticket_screen.dart';

/// Help Desk: support requests. Tabs, by what the person can do in the
/// active group (helpDeskOverview):
///  - My requests: what they asked the group (or, in a staff group, Bluejay)
///  - Inbox: what was asked of the group (its admins)
///  - Contact {Bluejay}: what the group asked the desk above it (its admins)
///  - Bluejay desk: staff groups' requests and every escalation (support staff)
///
/// The launch arg `ticket` opens one ticket over the lists.
class HelpDeskScreen extends StatefulWidget {
  final fire_auth.User? currentUser;
  final HelpDeskApi api;
  final String? groupId;
  final String? initialTicketId;
  final GuideSuggester? suggestGuides;
  final ChangeFiler? fileChange;
  final DateTime Function() clock;

  const HelpDeskScreen({
    super.key,
    this.currentUser,
    this.api = const HelpDeskApi(),
    this.groupId,
    this.initialTicketId,
    this.suggestGuides,
    this.fileChange,
    this.clock = DateTime.now,
  });

  @override
  State<HelpDeskScreen> createState() => _HelpDeskScreenState();
}

class _HelpDeskScreenState extends State<HelpDeskScreen> with TickerProviderStateMixin {
  HelpDeskOverview? _overview;
  Object? _error;
  TabController? _tabs;
  final Map<TicketView, List<TicketSummary>?> _lists = {};
  final Map<TicketView, Object?> _listErrors = {};
  bool _showDone = false;
  bool _openedInitial = false;

  String get _groupId => widget.groupId ?? ActiveGroupService.instance.activeGroupId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final overview = await widget.api.overview(_groupId);
      if (!mounted) return;
      final views = overview.views;
      _tabs?.dispose();
      _tabs = views.length > 1 ? TabController(length: views.length, vsync: this) : null;
      setState(() {
        _overview = overview;
        _error = null;
      });
      await Future.wait(views.map(_loadList));
      _openInitial();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _loadList(TicketView view) async {
    try {
      final rows = await widget.api.list(view, groupId: _groupId, active: !_showDone);
      if (!mounted) return;
      setState(() {
        _lists[view] = rows;
        _listErrors[view] = null;
      });
    } catch (e) {
      if (mounted) setState(() => _listErrors[view] = e);
    }
  }

  Future<void> _refreshAll() async {
    final o = _overview;
    if (o == null) return _load();
    await Future.wait(o.views.map(_loadList));
  }

  void _openInitial() {
    final id = widget.initialTicketId;
    if (_openedInitial || id == null || id.isEmpty) return;
    _openedInitial = true;
    _openTicket(id);
  }

  Future<void> _openTicket(String id) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => HelpDeskTicketScreen(
        ticketId: id,
        api: widget.api,
        currentUser: widget.currentUser,
        clock: widget.clock,
        fileChange: widget.fileChange ?? fileChangeInImproveApps,
      ),
    ));
    if (mounted) await _refreshAll();
  }

  TicketView? get _currentView {
    final views = _overview?.views ?? const [];
    if (views.isEmpty) return null;
    return views[_tabs?.index ?? 0];
  }

  Future<void> _newTicket({bool upstream = false}) async {
    final o = _overview;
    if (o == null) return;
    final id = await showNewTicketSheet(
      context,
      overview: o,
      api: widget.api,
      upstream: upstream,
      suggestGuides: widget.suggestGuides ?? defaultGuideSuggester,
    );
    if (id == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Sent to ${upstream ? o.upstreamLabel : o.deskLabel}. You\'ll be notified when they reply.'),
    ));
    await _refreshAll();
  }


  Future<void> _openSettings({bool platformDesk = false}) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => HelpDeskSettingsScreen(
        api: widget.api,
        groupId: platformDesk ? null : _groupId,
        groupName: platformDesk ? 'Bluejay desk' : _overview?.groupName ?? '',
        platformDesk: platformDesk,
      ),
    ));
  }

  String _tabLabel(TicketView view, HelpDeskOverview o) => switch (view) {
        TicketView.mine => 'My requests',
        TicketView.inbox => 'Inbox',
        TicketView.upstream => o.upstreamLabel.isEmpty ? 'Contact support' : 'Contact ${o.upstreamLabel}',
        TicketView.platform => 'Bluejay desk',
      };

  int _waiting(TicketView view) {
    final rows = _lists[view] ?? const [];
    return switch (view) {
      TicketView.inbox || TicketView.platform => rows.where((r) => r.status == TicketStatus.open).length,
      _ => rows.where((r) => r.status == TicketStatus.pending).length,
    };
  }

  Widget? _fab(HelpDeskOverview o) {
    final view = _currentView;
    if (view == TicketView.mine) {
      return FloatingActionButton.extended(
        onPressed: () => _newTicket(),
        icon: const Icon(Icons.add_comment_outlined),
        label: const Text('New request'),
      );
    }
    if (view == TicketView.upstream) {
      return FloatingActionButton.extended(
        onPressed: () => _newTicket(upstream: true),
        icon: const Icon(Icons.support_agent_rounded),
        label: Text('Contact ${o.upstreamLabel}'),
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final o = _overview;
    if (o == null) {
      return BjPage(
        title: 'Help Desk',
        body: _error == null
            ? const BjSkeletonList()
            : BjStateView.error(error: helpDeskErrorMessage(_error!), onRetry: _load),
      );
    }
    final views = o.views;
    if (views.isEmpty) {
      return const BjPage(
        title: 'Help Desk',
        body: BjStateView.empty(
          icon: Icons.support_agent_rounded,
          title: 'Not available here',
          message: 'This group isn\'t taking requests in Help Desk yet.',
        ),
      );
    }
    final tabs = _tabs;
    return AnimatedBuilder(
      animation: tabs ?? const AlwaysStoppedAnimation(0),
      builder: (context, _) => BjPage(
        title: 'Help Desk',
        subtitle: o.groupName,
        actions: [
          BjOverflowMenu(actions: [
            BjMenuAction(
              label: _showDone ? 'Show open requests' : 'Show resolved and closed',
              icon: _showDone ? Icons.inbox_outlined : Icons.history_rounded,
              onSelected: () {
                setState(() => _showDone = !_showDone);
                _refreshAll();
              },
            ),
            if (o.isAgent || o.isPlatformAdmin)
              BjMenuAction(label: 'Desk settings', icon: Icons.tune_rounded, onSelected: () => _openSettings()),
            if (o.isStaff)
              BjMenuAction(
                label: 'Bluejay desk settings',
                icon: Icons.admin_panel_settings_outlined,
                onSelected: () => _openSettings(platformDesk: true),
              ),
          ]),
        ],
        bottom: tabs == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(BjSegmentedTabs.height + BjSpace.md),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: BjSpace.md),
                  child: BjContent(
                    child: BjSegmentedTabs(
                      controller: tabs,
                      maxWidth: 640,
                      tabs: [for (final v in views) BjTab(_tabLabel(v, o), count: _waiting(v))],
                    ),
                  ),
                ),
              ),
        floatingActionButton: _fab(o),
        body: tabs == null
            ? _TicketList(
                view: views.single,
                overview: o,
                rows: _lists[views.single],
                error: _listErrors[views.single],
                showDone: _showDone,
                now: widget.clock(),
                onOpen: _openTicket,
                onRefresh: () => _loadList(views.single),
              )
            : TabBarView(controller: tabs, children: [
                for (final v in views)
                  _TicketList(
                    view: v,
                    overview: o,
                    rows: _lists[v],
                    error: _listErrors[v],
                    showDone: _showDone,
                    now: widget.clock(),
                    onOpen: _openTicket,
                    onRefresh: () => _loadList(v),
                  ),
              ]),
      ),
    );
  }
}

class _TicketList extends StatelessWidget {
  final TicketView view;
  final HelpDeskOverview overview;
  final List<TicketSummary>? rows;
  final Object? error;
  final bool showDone;
  final DateTime now;
  final void Function(String id) onOpen;
  final Future<void> Function() onRefresh;

  const _TicketList({
    required this.view,
    required this.overview,
    required this.rows,
    required this.error,
    required this.showDone,
    required this.now,
    required this.onOpen,
    required this.onRefresh,
  });

  ({String title, String message}) get _empty => switch (view) {
        TicketView.mine => (
            title: showDone ? 'No past requests' : 'No open requests',
            message: 'Ask ${overview.deskLabel} anything: a problem, a question, something you can\'t find.',
          ),
        TicketView.inbox => (
            title: showDone ? 'Nothing resolved yet' : 'All caught up',
            message: overview.routedToPlatform
                ? 'Requests in this group go straight to Bluejay support.'
                : 'Requests from your members and customers appear here.',
          ),
        TicketView.upstream => (
            title: 'No requests to ${overview.upstreamLabel}',
            message: 'When your group needs help, or a customer\'s problem is beyond you, ask here.',
          ),
        TicketView.platform => (
            title: showDone ? 'Nothing resolved yet' : 'All caught up',
            message: 'Staff groups\' requests and every escalation to Bluejay appear here.',
          ),
      };

  @override
  Widget build(BuildContext context) {
    final list = rows;
    if (error != null && list == null) {
      return BjStateView.error(error: helpDeskErrorMessage(error!), onRetry: onRefresh);
    }
    if (list == null) return const BjSkeletonList();
    if (list.isEmpty) {
      final e = _empty;
      return BjScrollBody(onRefresh: onRefresh, children: [
        BjStateView.empty(icon: Icons.support_agent_rounded, title: e.title, message: e.message),
      ]);
    }
    final forDesk = view == TicketView.inbox || view == TicketView.platform;
    return BjScrollBody(onRefresh: onRefresh, spacing: BjSpace.sm, children: [
      for (final r in list) _TicketRow(row: r, forDesk: forDesk, view: view, now: now, onTap: () => onOpen(r.id)),
    ]);
  }
}

class _TicketRow extends StatelessWidget {
  final TicketSummary row;
  final bool forDesk;
  final TicketView view;
  final DateTime now;
  final VoidCallback onTap;

  const _TicketRow({required this.row, required this.forDesk, required this.view, required this.now, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final display = statusDisplay(row.status, forDesk: forDesk);
    final who = switch (view) {
      TicketView.platform => row.requesterKind == 'group' ? row.groupName : '${row.requesterName} · ${row.groupName}',
      TicketView.inbox => row.requesterName,
      _ => row.deskLabel,
    };
    return BjListRow(
      title: row.subject,
      subtitle: [who, if (row.assigneeName.isNotEmpty && forDesk) 'Assigned to ${row.assigneeName}']
          .where((s) => s.isNotEmpty)
          .join(' · '),
      leading: BjIconWell(icon: display.icon, tone: display.tone),
      meta: [
        BjStatusPill(label: display.label, tone: display.tone),
        if (forDesk && row.overdue) const BjStatusPill(label: 'Overdue', tone: BjTone.danger),
        if (row.priority != 'normal')
          BjStatusPill(
            label: priorityLabel(row.priority),
            tone: row.priority == 'urgent' ? BjTone.danger : BjTone.warning,
          ),
        if (forDesk && row.fromEscalation) const BjStatusPill(label: 'Escalation', tone: BjTone.accent),
      ],
      trailing: Text(relativeTime(row.lastActivityAt, now), style: Theme.of(context).textTheme.bodySmall),
      onTap: onTap,
    );
  }
}
