import 'dart:async';

import 'package:bluejay_design/bluejay_design.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:shared_services/app_launch_bridge.dart';
import 'package:shared_services/group_seats.dart';

import 'dev_queue_host.dart';
import 'dev_queue_logic.dart';
import 'dev_queue_models.dart';
import 'dev_queue_service.dart';
import 'dev_queue_sheets.dart';
import 'dev_queue_widgets.dart';
import 'dev_ticket_status.dart';

/// Your queue (PHASE_2_DESIGN.md 6.2): Now, Up next, Shipped (what you and
/// your group asked for) and Bonus improvements (other groups' changes to
/// your group's apps), plus a Managed workspaces tab for people who triage
/// a managed group.
class DevQueueScreen extends StatefulWidget {
  final fire_auth.User? currentUser;

  /// Opens the new-request chooser. Defaults to [DevQueueHost.newRequest].
  final DevQueueNewRequest? onNewRequest;

  /// Scrolls to this item and highlights it once (notification deep links,
  /// "Open in your queue").
  final String? focusItemKey;

  final DevQueueService? service;

  /// The group whose Shipped this shows. Defaults to
  /// [DevQueueHost.activeGroupId]; with neither, Shipped shows every
  /// finished item of the person's and no group lists.
  final String? groupId;

  /// Overrides the clock in tests.
  final DateTime? now;

  /// Reads the group's seats and developer agents. Defaults to
  /// [GroupSeatsApi.status].
  final Future<SeatStatus> Function(String groupId)? loadSeats;

  const DevQueueScreen({
    super.key,
    required this.currentUser,
    this.onNewRequest,
    this.focusItemKey,
    this.service,
    this.groupId,
    this.now,
    this.loadSeats,
  });

  @override
  State<DevQueueScreen> createState() => _DevQueueScreenState();
}

class _DevQueueScreenState extends State<DevQueueScreen> {
  List<ManagedQueueGroup>? _managed;

  DevQueueService get _service => widget.service ?? DevQueueService.instance;

  @override
  void initState() {
    super.initState();
    _loadManaged();
  }

  Future<void> _loadManaged() async {
    try {
      final groups = await _service.listManaged();
      if (mounted) setState(() => _managed = groups);
    } catch (_) {
      // No triage tab when the list can't be read.
      if (mounted) setState(() => _managed = const []);
    }
  }

  Future<void> _newRequest() async {
    final handler = widget.onNewRequest;
    if (handler != null) return handler(context);
    final hosted = DevQueueHost.newRequest;
    if (hosted != null) return hosted(context, widget.currentUser);
  }

  @override
  Widget build(BuildContext context) {
    final managed = _managed ?? const [];
    final maxWidth = devQueueContentWidth(MediaQuery.sizeOf(context).width);
    final queueTab = _YourQueueTab(
      currentUser: widget.currentUser,
      service: _service,
      focusItemKey: widget.focusItemKey,
      onNewRequest: _newRequest,
      groupId: widget.groupId ?? DevQueueHost.activeGroupId?.call(),
      now: widget.now,
      loadSeats: widget.loadSeats ?? const GroupSeatsApi().status,
    );
    final appBarActions = [
      TextButton.icon(
        onPressed: _newRequest,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Request a change'),
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
    ];
    if (managed.isEmpty) {
      return BjPage(title: 'Your queue', actions: appBarActions, maxWidth: maxWidth, body: queueTab);
    }
    return DefaultTabController(
      length: 2,
      child: BjPage(
        title: 'Your queue',
        actions: appBarActions,
        maxWidth: maxWidth,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(BjSegmentedTabs.height + BjSpace.md),
          child: Padding(
            padding: const EdgeInsets.only(bottom: BjSpace.md),
            child: BjContent(
              maxWidth: maxWidth,
              child: const BjSegmentedTabs(tabs: [
                BjTab('Your queue', icon: Icons.view_agenda_outlined),
                BjTab('Managed workspaces', icon: Icons.domain_rounded),
              ]),
            ),
          ),
        ),
        body: TabBarView(
          children: [
            queueTab,
            _ManagedTab(groups: managed, service: _service, onRefresh: _loadManaged, maxWidth: maxWidth),
          ],
        ),
      ),
    );
  }
}

/// The queue's content width: a single readable column up to
/// [BjBreakpoint.expanded], then two columns at the page width.
double devQueueContentWidth(double screenWidth) =>
    BjBreakpoint.isExpanded(screenWidth) ? BjBreakpoint.pageWidth : BjBreakpoint.formWidth;

// ─────────────────────────────────────────────────────────────────────────────
// Your queue
// ─────────────────────────────────────────────────────────────────────────────

class _YourQueueTab extends StatefulWidget {
  final fire_auth.User? currentUser;
  final DevQueueService service;
  final String? focusItemKey;
  final Future<void> Function() onNewRequest;
  final String? groupId;
  final DateTime? now;
  final Future<SeatStatus> Function(String groupId) loadSeats;

  const _YourQueueTab({
    required this.currentUser,
    required this.service,
    required this.focusItemKey,
    required this.onNewRequest,
    required this.groupId,
    required this.now,
    required this.loadSeats,
  });

  @override
  State<_YourQueueTab> createState() => _YourQueueTabState();
}

class _YourQueueTabState extends State<_YourQueueTab> {
  StreamSubscription<List<DevQueueItem>>? _activeSub;
  StreamSubscription<List<DevQueueItem>>? _finishedSub;
  List<DevQueueItem>? _active;
  List<DevQueueItem>? _finished;
  bool _failed = false;

  /// Teammates' shipped requests and other groups' changes, once read. Left
  /// empty when they can't be read: the person's own items still show.
  GroupShipped? _groupShipped;

  /// The order the person dragged to, shown until the server agrees or
  /// refuses.
  List<String>? _localOrder;
  bool _reordering = false;

  final _itemKeys = <String, GlobalKey>{};
  String? _highlightKey;

  /// The item to scroll to once it is on screen: the deep link's, or one
  /// "View" asked for.
  String? _pendingFocus;

  @override
  void initState() {
    super.initState();
    _highlightKey = widget.focusItemKey;
    _pendingFocus = widget.focusItemKey;
    _subscribe();
  }

  void _subscribe() {
    _activeSub?.cancel();
    _finishedSub?.cancel();
    final uid = widget.currentUser?.uid;
    setState(() {
      _failed = false;
      _active = null;
      _finished = null;
    });
    _loadGroupShipped();
    if (uid == null) {
      setState(() {
        _active = const [];
        _finished = const [];
      });
      return;
    }
    _activeSub = widget.service.watchActive(uid).listen(
      (items) {
        if (!mounted) return;
        setState(() {
          _active = visibleQueue(items);
          final serverKeys = upNextItems(_active!).map((i) => i.key).toList();
          if (_localOrder != null && !_reordering && _sameOrder(serverKeys, _localOrder!)) _localOrder = null;
        });
        _tryFocus();
      },
      onError: (Object _) {
        if (mounted) setState(() => _failed = true);
      },
    );
    _finishedSub = widget.service.watchFinished(uid).listen(
      (items) {
        if (!mounted) return;
        final groupId = widget.groupId;
        setState(() => _finished = shippedItems(
              items,
              now: widget.now,
              groupId: groupId,
              isInstalled: groupId == null ? null : DevQueueHost.isAppInstalled,
            ));
        _tryFocus();
      },
      onError: (Object _) {
        if (mounted) setState(() => _failed = true);
      },
    );
  }

  Future<void> _loadGroupShipped() async {
    final groupId = widget.groupId;
    if (groupId == null || groupId.isEmpty || widget.currentUser == null) {
      setState(() => _groupShipped = GroupShipped.empty);
      return;
    }
    setState(() => _groupShipped = null);
    GroupShipped result;
    try {
      result = await widget.service.groupShipped(groupId);
    } catch (_) {
      result = GroupShipped.empty;
    }
    if (mounted && widget.groupId == groupId) setState(() => _groupShipped = result);
  }

  @override
  void didUpdateWidget(covariant _YourQueueTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupId != widget.groupId) _subscribe();
  }

  static bool _sameOrder(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Scrolls to and highlights [key] (now, or once it appears).
  void _focus(String key) {
    setState(() {
      _pendingFocus = key;
      _highlightKey = key;
    });
    _tryFocus();
  }

  void _tryFocus() {
    if (_pendingFocus == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final key = _pendingFocus;
      if (key == null || !mounted) return;
      final ctx = _itemKeys[key]?.currentContext;
      if (ctx == null) return;
      _pendingFocus = null;
      Scrollable.ensureVisible(ctx, duration: BjMotion.slow, curve: BjMotion.curve, alignment: 0.1);
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted && _highlightKey == key) setState(() => _highlightKey = null);
      });
    });
  }

  Future<void> _edit(DevQueueItem item) => showDevQueueEditSheet(context, item, widget.service);

  Future<void> _withdraw(DevQueueItem item) => withdrawDevQueueItem(context, item, widget.service);

  Future<void> _reportRegression(DevQueueItem item) async {
    final outcome = await showDevQueueRegressionSheet(context, item, widget.service);
    if (outcome == null || !mounted) return;
    final key = outcome.itemKey;
    showDevQueueSnackBar(
      context,
      outcome.message,
      action: key == null ? null : SnackBarAction(label: 'View', onPressed: () => _focus(key)),
    );
  }

  @override
  void dispose() {
    _activeSub?.cancel();
    _finishedSub?.cancel();
    super.dispose();
  }

  GlobalKey _keyFor(String itemKey) => _itemKeys.putIfAbsent(itemKey, () => GlobalKey());

  Future<void> _saveOrder(List<String> keys) async {
    setState(() {
      _localOrder = keys;
      _reordering = true;
    });
    try {
      await widget.service.reorder(keys);
      if (!mounted) return;
      setState(() => _reordering = false);
      final serverKeys = upNextItems(_active ?? const []).map((i) => i.key).toList();
      if (_sameOrder(serverKeys, keys)) setState(() => _localOrder = null);
    } on DevQueueException catch (e) {
      if (!mounted) return;
      setState(() {
        _reordering = false;
        _localOrder = null;
      });
      BjSnack.error(context, e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _reordering = false;
        _localOrder = null;
      });
      BjSnack.error(context, 'Something went wrong. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return BjStateView.error(
        title: "Couldn't load your queue.",
        message: 'Check your connection and try again.',
        onRetry: _subscribe,
      );
    }

    final active = _active;
    final finished = _finished;
    final now = active == null ? const <DevQueueItem>[] : nowItems(active);
    final upNext = active == null ? const <DevQueueItem>[] : applyLocalOrder(upNextItems(active), _localOrder);
    // Positions follow the order on screen, so a drag renumbers at once.
    final positions = active == null ? const <String, int>{} : queuePositionsWithOrder(active, upNext);
    final upNextKeys = upNext.map((i) => i.key).toList();
    final activeKeys = {for (final i in active ?? const <DevQueueItem>[]) i.key};

    final width = MediaQuery.sizeOf(context).width;
    final wide = BjBreakpoint.isExpanded(width);
    final nowSection = <Widget>[
      _SectionHeader('Now', icon: Icons.bolt_rounded, count: active == null ? null : now.length, first: true),
      if (active == null)
        const SliverToBoxAdapter(child: _NowSkeleton())
      else if (now.isEmpty)
        const SliverToBoxAdapter(
          child: BjInlineNote('Nothing is being built right now.', icon: Icons.hourglass_empty_rounded),
        )
      else
        SliverList.list(
          children: [
            for (final item in now)
              _NowCard(
                key: _keyFor(item.key),
                item: item,
                service: widget.service,
                highlighted: item.key == _highlightKey,
                now: widget.now,
                onWithdraw: () => _withdraw(item),
              ),
          ],
        ),
    ];
    final upNextSection = <Widget>[
      _SectionHeader(
        'Up next',
        icon: Icons.format_list_numbered_rounded,
        count: active == null ? null : upNext.length,
        // Tops the right-hand column on wide screens.
        first: wide,
      ),
      if (active == null)
        const SliverToBoxAdapter(child: Column(children: [_RowSkeleton(), _RowSkeleton()]))
      else if (upNext.isEmpty)
        SliverToBoxAdapter(child: _UpNextEmpty(onNewRequest: widget.onNewRequest))
      else ...[
        if (anyWaitingForAgent(upNext))
          SliverToBoxAdapter(
            child: _AgentBusyNote(
              currentUser: widget.currentUser,
              groupId: widget.groupId,
              loadSeats: widget.loadSeats,
            ),
          ),
        SliverReorderableList(
          itemCount: upNext.length,
          onReorderItem: (oldIndex, newIndex) => _saveOrder(moveKeyTo(upNextKeys, oldIndex, newIndex)),
          proxyDecorator: (child, index, animation) => Material(type: MaterialType.transparency, child: child),
          itemBuilder: (context, index) {
            final item = upNext[index];
            return _UpNextRow(
              key: ValueKey('up-next-${item.key}'),
              anchorKey: _keyFor(item.key),
              index: index,
              count: upNext.length,
              item: item,
              position: positions[item.key] ?? index + 1,
              highlighted: item.key == _highlightKey,
              onMove: (target) => _saveOrder(moveKeyTo(upNextKeys, index, target)),
              onEdit: () => _edit(item),
              onWithdraw: () => _withdraw(item),
            );
          },
        ),
      ],
    ];
    final groupShipped = _groupShipped;
    // Yours and your teammates' together, newest first. Waits for both so
    // rows don't jump when the group's arrive.
    final shipped = finished == null || groupShipped == null
        ? null
        : <({DateTime? at, Widget row})>[
            for (final item in finished)
              (
                at: item.stateChangedAt,
                row: _ShippedRow(
                  key: _keyFor(item.key),
                  item: item,
                  currentUser: widget.currentUser,
                  highlighted: item.key == _highlightKey,
                  now: widget.now,
                  canReportRegression: item.canReportRegression(now: widget.now, activeKeys: activeKeys),
                  onReportRegression: () => _reportRegression(item),
                ),
              ),
            for (final item in groupShipped.team)
              (at: item.liveAt, row: _TeamShippedRow(item: item, currentUser: widget.currentUser, now: widget.now)),
          ];
    shipped?.sort((a, b) {
      final at = a.at, bt = b.at;
      if (at == null || bt == null) return at == null ? (bt == null ? 0 : 1) : -1;
      return bt.compareTo(at);
    });
    final shippedSection = <Widget>[
      _SectionHeader('Shipped', icon: Icons.rocket_launch_outlined, count: shipped?.length),
      if (shipped == null)
        const SliverToBoxAdapter(child: _RowSkeleton())
      else if (shipped.isEmpty)
        SliverToBoxAdapter(
          child: BjInlineNote(
            widget.groupId == null
                ? 'Nothing shipped yet. Your first request shows up here when it goes live.'
                : 'Nothing shipped yet. Requests from you and your group show up here when they go live.',
            icon: Icons.rocket_launch_outlined,
          ),
        )
      else
        SliverList.list(children: [for (final entry in shipped) entry.row]),
    ];
    final bonus = groupShipped?.bonus ?? const <BonusChange>[];
    final bonusSection = <Widget>[
      if (bonus.isNotEmpty) ...[
        _SectionHeader('Bonus improvements', icon: Icons.card_giftcard_rounded, count: bonus.length),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: BjSpace.sm),
            child: Text(
              'Other groups asked for these changes to apps your group uses.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        SliverList.list(
          children: [for (final change in bonus) _BonusChangeRow(change: change, now: widget.now)],
        ),
      ],
    ];

    final maxWidth = devQueueContentWidth(width);
    final side = bjPagePadding(width).left;
    final inset = width > maxWidth + side * 2 ? (width - maxWidth) / 2 : side;
    final Widget body = wide
        // Two columns: what's being built on the left, the line and what
        // shipped on the right. One scroll view, so focus and drag still work.
        ? SliverCrossAxisGroup(
            slivers: [
              SliverCrossAxisExpanded(flex: 3, sliver: SliverMainAxisGroup(slivers: nowSection)),
              const SliverConstrainedCrossAxis(maxExtent: BjSpace.xl, sliver: SliverToBoxAdapter(child: SizedBox.shrink())),
              SliverCrossAxisExpanded(
                flex: 2,
                sliver: SliverMainAxisGroup(slivers: [...upNextSection, ...shippedSection, ...bonusSection]),
              ),
            ],
          )
        : SliverMainAxisGroup(slivers: [...nowSection, ...upNextSection, ...shippedSection, ...bonusSection]);

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(inset, BjSpace.xs, inset, BjSpace.xxxl),
          sliver: body,
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final IconData icon;
  final int? count;
  final bool first;

  const _SectionHeader(this.title, {required this.icon, this.count, this.first = false});

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.only(top: first ? BjSpace.xs : BjSpace.lg, bottom: BjSpace.xs),
        child: Semantics(
          header: true,
          child: BjSectionHeader(title: title, icon: icon, count: count == 0 ? null : count),
        ),
      ),
    );
  }
}

/// A first-load placeholder shaped like a Now card.
class _NowSkeleton extends StatelessWidget {
  const _NowSkeleton();

  @override
  Widget build(BuildContext context) {
    return BjCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              BjSkeleton(width: 40, height: 40, radius: BjRadius.md),
              SizedBox(width: BjSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    BjSkeleton(width: 180, height: 16),
                    SizedBox(height: BjSpace.sm),
                    BjSkeleton(width: 90, height: 12),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: BjSpace.lg),
          for (var i = 0; i < 4; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: BjSpace.md),
              child: Row(
                children: [
                  const BjSkeleton(width: 22, height: 22, radius: BjRadius.pill),
                  const SizedBox(width: BjSpace.md),
                  BjSkeleton(width: 140.0 - i * 20, height: 12),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A first-load placeholder shaped like an Up next or Shipped row.
class _RowSkeleton extends StatelessWidget {
  const _RowSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(bottom: BjSpace.sm),
      child: BjCard(
        padding: EdgeInsets.all(BjSpace.md),
        child: Row(
          children: [
            BjSkeleton(width: 36, height: 36, radius: BjRadius.pill),
            SizedBox(width: BjSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  BjSkeleton(height: 14),
                  SizedBox(height: BjSpace.sm),
                  BjSkeleton(width: 140, height: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The well beside a row or card: the status's icon in its tone.
Widget _statusWell(DevStatusCode code, {double size = 40}) {
  final style = devStatusStyle(code);
  // The accent tone reads best as the soft accent gradient.
  return BjIconWell(icon: style.icon, size: size, tone: style.tone == BjTone.accent ? null : style.tone);
}

class _NowCard extends StatelessWidget {
  final DevQueueItem item;
  final DevQueueService service;
  final bool highlighted;
  final DateTime? now;
  final VoidCallback onWithdraw;

  const _NowCard({
    super.key,
    required this.item,
    required this.service,
    required this.highlighted,
    required this.now,
    required this.onWithdraw,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: BjSpace.md),
      child: BjCard(
        selected: highlighted,
        radius: BjRadius.xl,
        padding: const EdgeInsets.fromLTRB(BjSpace.lg, BjSpace.lg, BjSpace.sm, BjSpace.lg),
        child: Padding(
          padding: const EdgeInsets.only(right: BjSpace.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _statusWell(item.status.code),
                  const SizedBox(width: BjSpace.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.displayTitle, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                        if (item.appName.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: BjSpace.xxs),
                            child: Text(item.appName, style: text.bodySmall),
                          ),
                      ],
                    ),
                  ),
                  if (item.canWithdraw)
                    BjOverflowMenu(
                      tooltip: 'More',
                      actions: [
                        BjMenuAction(
                          label: 'Withdraw request',
                          icon: Icons.remove_circle_outline_rounded,
                          destructive: true,
                          onSelected: onWithdraw,
                        ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: BjSpace.lg),
              DevStageTracker(item: item),
              if (showsEstimateLine(item)) ...[
                const SizedBox(height: BjSpace.md),
                BjInlineNote(asSentence(item.estimate!.line), icon: Icons.schedule_rounded),
              ],
              if (item.isAwaitingAnswer) ...[
                const SizedBox(height: BjSpace.lg),
                DevQueueAnswerBox(
                  itemKey: item.key,
                  question: item.waiting?.question.isNotEmpty == true ? item.waiting!.question : item.status.detail,
                  waiting: item.waiting,
                  service: service,
                  now: now,
                ),
              ],
              if (item.isAwaitingApproval) ...[
                const SizedBox(height: BjSpace.lg),
                DevQueuePreviewActions(item: item, service: service),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _UpNextRow extends StatelessWidget {
  final GlobalKey anchorKey;
  final int index;
  final int count;
  final DevQueueItem item;
  final int position;
  final bool highlighted;
  final void Function(int target) onMove;
  final VoidCallback onEdit;
  final VoidCallback onWithdraw;

  const _UpNextRow({
    super.key,
    required this.anchorKey,
    required this.index,
    required this.count,
    required this.item,
    required this.position,
    required this.highlighted,
    required this.onMove,
    required this.onEdit,
    required this.onWithdraw,
  });

  /// The row's actions, in the order the menus list them; Withdraw last.
  List<BjMenuAction> get _actions => [
        if (index > 0)
          BjMenuAction(label: 'Move to top', icon: Icons.vertical_align_top_rounded, onSelected: () => onMove(0)),
        if (index > 0)
          BjMenuAction(label: 'Move up', icon: Icons.arrow_upward_rounded, onSelected: () => onMove(index - 1)),
        if (index < count - 1)
          BjMenuAction(label: 'Move down', icon: Icons.arrow_downward_rounded, onSelected: () => onMove(index + 1)),
        if (item.canEdit) BjMenuAction(label: 'Edit', icon: Icons.edit_outlined, onSelected: onEdit),
        if (item.canWithdraw)
          BjMenuAction(
            label: 'Withdraw',
            icon: Icons.remove_circle_outline_rounded,
            destructive: true,
            onSelected: onWithdraw,
          ),
      ];

  Future<void> _showMenu(BuildContext context, Offset at) async {
    final actions = _actions;
    if (actions.isEmpty) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<BjMenuAction>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: devQueueMenuItems(context, actions),
    );
    choice?.onSelected();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final detail = item.status.detail;
    final actions = _actions;
    return Semantics(
      key: anchorKey,
      customSemanticsActions: {
        if (index > 0) const CustomSemanticsAction(label: 'Move to top'): () => onMove(0),
        if (index > 0) const CustomSemanticsAction(label: 'Move up'): () => onMove(index - 1),
        if (index < count - 1) const CustomSemanticsAction(label: 'Move down'): () => onMove(index + 1),
        if (item.canEdit) const CustomSemanticsAction(label: 'Edit'): onEdit,
        if (item.canWithdraw) const CustomSemanticsAction(label: 'Withdraw'): onWithdraw,
      },
      child: Padding(
        padding: const EdgeInsets.only(bottom: BjSpace.sm),
        child: GestureDetector(
          onLongPressStart: (d) => _showMenu(context, d.globalPosition),
          onSecondaryTapDown: (d) => _showMenu(context, d.globalPosition),
          child: BjCard(
            selected: highlighted,
            padding: const EdgeInsets.fromLTRB(BjSpace.md, BjSpace.sm, BjSpace.xs, BjSpace.sm),
            child: Row(
              children: [
                _PositionBadge(position),
                const SizedBox(width: BjSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.displayTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall,
                      ),
                      const SizedBox(height: BjSpace.xxs),
                      Wrap(
                        spacing: BjSpace.xs + 2,
                        runSpacing: BjSpace.xs,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            detail.isEmpty ? item.status.label : '${item.status.label} · $detail',
                            style: text.bodySmall,
                          ),
                          if ((item.estimate?.short ?? '').isNotEmpty) DevQueueTextChip(item.estimate!.short),
                          if (item.expedite) const DevQueueTextChip('Fix', emphasis: true),
                        ],
                      ),
                    ],
                  ),
                ),
                if (actions.isNotEmpty) BjOverflowMenu(actions: actions),
                ReorderableDragStartListener(
                  index: index,
                  child: const SizedBox(
                    width: 44,
                    height: 48,
                    child: Tooltip(
                      message: 'Drag to reorder',
                      child: Icon(Icons.drag_indicator_rounded, color: BjNeutral.inkSubtle),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Menu entries for [actions], styled like [BjOverflowMenu]'s: an icon each,
/// destructive ones last, in the danger tone, after a divider. Used for the
/// long-press and right-click menu, which opens where the pointer is.
List<PopupMenuEntry<BjMenuAction>> devQueueMenuItems(BuildContext context, List<BjMenuAction> actions) {
  final danger = context.bj.tone(BjTone.danger).foreground;
  final safe = actions.where((a) => !a.destructive).toList();
  final destructive = actions.where((a) => a.destructive).toList();
  PopupMenuItem<BjMenuAction> item(BjMenuAction a) {
    final color = a.destructive ? danger : null;
    return PopupMenuItem(
      value: a,
      enabled: a.enabled,
      child: Row(children: [
        Icon(a.icon, size: 20, color: color ?? BjNeutral.inkMuted),
        const SizedBox(width: BjSpace.md),
        Flexible(child: Text(a.label, style: color == null ? null : TextStyle(color: color))),
      ]),
    );
  }

  return [
    ...safe.map(item),
    if (safe.isNotEmpty && destructive.isNotEmpty) const PopupMenuDivider(),
    ...destructive.map(item),
  ];
}

/// The "#2" place-in-line badge on an Up next row.
class _PositionBadge extends StatelessWidget {
  final int position;

  const _PositionBadge(this.position);

  @override
  Widget build(BuildContext context) {
    final bj = context.bj;
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(gradient: bj.softGradient, shape: BoxShape.circle),
      child: Text(
        '#$position',
        style: Theme.of(context).textTheme.labelLarge?.copyWith(color: bj.accent, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// Over Up next while a request waits for the group's developer agents.
/// Group admins get "Add a developer agent", which opens Group Admin's
/// Billing tab; other members learn their admins can add one. Shows nothing
/// when the group has no shared pool (add-on agents only grow a shared
/// pool) or its seats can't be read.
class _AgentBusyNote extends StatefulWidget {
  final fire_auth.User? currentUser;
  final String? groupId;
  final Future<SeatStatus> Function(String groupId) loadSeats;

  const _AgentBusyNote({required this.currentUser, required this.groupId, required this.loadSeats});

  @override
  State<_AgentBusyNote> createState() => _AgentBusyNoteState();
}

class _AgentBusyNoteState extends State<_AgentBusyNote> {
  SeatStatus? _seats;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_AgentBusyNote oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupId != widget.groupId) {
      _seats = null;
      _load();
    }
  }

  Future<void> _load() async {
    final groupId = widget.groupId;
    if (groupId == null || groupId.isEmpty || widget.currentUser == null) return;
    try {
      final seats = await widget.loadSeats(groupId);
      if (mounted && widget.groupId == groupId) setState(() => _seats = seats);
    } catch (_) {
      // No note without the group's seats.
    }
  }

  @override
  Widget build(BuildContext context) {
    final seats = _seats;
    if (seats == null || !seats.devQueues.isShared) return const SizedBox.shrink();
    final canBuy = seats.canManage && seats.addOns != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: BjSpace.md),
      child: BjCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const BjIconWell(icon: Icons.hourglass_empty_rounded),
                const SizedBox(width: BjSpace.md),
                Expanded(
                  child: Text(
                    canBuy
                        ? 'Your developer agents are busy, so a request is waiting its turn. '
                            'Add a developer agent to build more requests at the same time.'
                        : 'Your developer agents are busy, so a request is waiting its turn. '
                            "Your group's admins can add a developer agent in Group Admin.",
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
            if (canBuy) ...[
              const SizedBox(height: BjSpace.md),
              OutlinedButton.icon(
                onPressed: () =>
                    AppLaunchBridge.openApp(context, 'group-admin', widget.currentUser, args: const {'tab': 'billing'}),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Add a developer agent'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _UpNextEmpty extends StatelessWidget {
  final Future<void> Function() onNewRequest;

  const _UpNextEmpty({required this.onNewRequest});

  @override
  Widget build(BuildContext context) {
    return BjCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const BjIconWell(icon: Icons.lightbulb_outline_rounded),
              const SizedBox(width: BjSpace.md),
              Expanded(
                child: Text(
                  'Nothing waiting. What would save you time next?',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: BjSpace.md),
          OutlinedButton.icon(
            onPressed: onNewRequest,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Request a change'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          ),
        ],
      ),
    );
  }
}

class _ShippedRow extends StatelessWidget {
  final DevQueueItem item;
  final fire_auth.User? currentUser;
  final bool highlighted;
  final DateTime? now;
  final bool canReportRegression;
  final VoidCallback onReportRegression;

  const _ShippedRow({
    super.key,
    required this.item,
    required this.currentUser,
    required this.highlighted,
    required this.now,
    required this.canReportRegression,
    required this.onReportRegression,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final live = item.state == DevItemState.live;
    final installed = DevQueueHost.isAppInstalled;
    final canOpen = live && item.shippedAppId.isNotEmpty && (installed == null || installed(item.shippedAppId));
    final appName = item.appName.isNotEmpty ? item.appName : 'the app';
    final code = live
        ? DevStatusCode.live
        : (item.state == DevItemState.declined ? DevStatusCode.declined : DevStatusCode.closed);
    const buttonStyle = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(48, 48)),
      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: BjSpace.sm)),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: BjSpace.sm),
      child: BjCard(
        selected: highlighted,
        tone: live ? null : BjTone.neutral,
        padding: const EdgeInsets.fromLTRB(BjSpace.md, BjSpace.md, BjSpace.md, BjSpace.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _statusWell(code, size: 36),
                const SizedBox(width: BjSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.displayTitle,
                        style: text.titleSmall?.copyWith(color: live ? BjNeutral.ink : BjNeutral.inkMuted),
                      ),
                      const SizedBox(height: BjSpace.xxs),
                      Text(shippedLine(item, now: now), style: text.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
            if (live)
              Padding(
                padding: const EdgeInsets.only(left: 36 + BjSpace.md - BjSpace.sm, top: BjSpace.xs),
                child: Wrap(
                  spacing: BjSpace.xs,
                  children: [
                    if (canOpen)
                      TextButton.icon(
                        onPressed: () => AppLaunchBridge.openApp(context, item.shippedAppId, currentUser),
                        icon: const Icon(Icons.open_in_new_rounded, size: 18),
                        label: Text('Open $appName'),
                        style: buttonStyle,
                      ),
                    TextButton.icon(
                      onPressed: () => AppLaunchBridge.openApp(context, 'whats-new', currentUser),
                      icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                      label: const Text("What's New"),
                      style: buttonStyle,
                    ),
                    if (canReportRegression)
                      TextButton.icon(
                        onPressed: onReportRegression,
                        icon: const Icon(Icons.report_problem_outlined, size: 18),
                        label: const Text('This broke something'),
                        style: buttonStyle,
                      ),
                  ],
                ),
              )
            else
              const SizedBox(height: BjSpace.xs),
          ],
        ),
      ),
    );
  }
}

/// A teammate's request that went live: no actions but opening the app.
class _TeamShippedRow extends StatelessWidget {
  final TeamShippedItem item;
  final fire_auth.User? currentUser;
  final DateTime? now;

  const _TeamShippedRow({required this.item, required this.currentUser, required this.now});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final installed = DevQueueHost.isAppInstalled;
    final canOpen = item.appId.isNotEmpty && (installed == null || installed(item.appId));
    final appName = item.appName.isNotEmpty ? item.appName : 'the app';
    return Padding(
      padding: const EdgeInsets.only(bottom: BjSpace.sm),
      child: BjCard(
        padding: const EdgeInsets.fromLTRB(BjSpace.md, BjSpace.md, BjSpace.md, BjSpace.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _statusWell(DevStatusCode.live, size: 36),
                const SizedBox(width: BjSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.displayTitle, style: text.titleSmall?.copyWith(color: BjNeutral.ink)),
                      const SizedBox(height: BjSpace.xxs),
                      Text(teamShippedLine(item, now: now), style: text.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
            if (canOpen)
              Padding(
                padding: const EdgeInsets.only(left: 36 + BjSpace.md - BjSpace.sm, top: BjSpace.xs),
                child: TextButton.icon(
                  onPressed: () => AppLaunchBridge.openApp(context, item.appId, currentUser),
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: Text('Open $appName'),
                  style: const ButtonStyle(
                    minimumSize: WidgetStatePropertyAll(Size(48, 48)),
                    padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: BjSpace.sm)),
                  ),
                ),
              )
            else
              const SizedBox(height: BjSpace.xs),
          ],
        ),
      ),
    );
  }
}

/// A change another group asked for, in one of this group's apps.
class _BonusChangeRow extends StatelessWidget {
  final BonusChange change;
  final DateTime? now;

  const _BonusChangeRow({required this.change, required this.now});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final line = bonusChangeLine(change, now: now);
    return Padding(
      padding: const EdgeInsets.only(bottom: BjSpace.sm),
      child: BjCard(
        tone: BjTone.neutral,
        padding: const EdgeInsets.all(BjSpace.md),
        child: Row(
          children: [
            const BjIconWell(icon: Icons.auto_awesome_outlined, size: 36, tone: BjTone.neutral),
            const SizedBox(width: BjSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(change.title, style: text.bodyMedium?.copyWith(color: BjNeutral.ink)),
                  if (line.isNotEmpty) ...[
                    const SizedBox(height: BjSpace.xxs),
                    Text(line, style: text.bodySmall),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Managed workspaces
// ─────────────────────────────────────────────────────────────────────────────

class _ManagedTab extends StatefulWidget {
  final List<ManagedQueueGroup> groups;
  final DevQueueService service;
  final Future<void> Function() onRefresh;
  final double maxWidth;

  const _ManagedTab({required this.groups, required this.service, required this.onRefresh, required this.maxWidth});

  @override
  State<_ManagedTab> createState() => _ManagedTabState();
}

class _ManagedTabState extends State<_ManagedTab> {
  final _sending = <String>{};
  final _sent = <String>{};

  Future<void> _send(ManagedQueueItem item) async {
    setState(() => _sending.add(item.itemKey));
    try {
      await widget.service.sendToPipeline(item.itemType, item.itemId);
      if (!mounted) return;
      setState(() => _sent.add(item.itemKey));
      await widget.onRefresh();
    } on DevQueueException catch (e) {
      if (mounted) BjSnack.error(context, e.message);
    } catch (_) {
      if (mounted) BjSnack.error(context, 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _sending.remove(item.itemKey));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasItems = widget.groups.any((g) => g.items.isNotEmpty);
    if (!hasItems) {
      return const BjStateView.empty(
        icon: Icons.inbox_outlined,
        title: 'No requests from the workspaces you manage.',
        message: 'New requests from those workspaces show up here, ready to send on.',
      );
    }
    return BjScrollBody(
      onRefresh: widget.onRefresh,
      maxWidth: widget.maxWidth,
      bottomInset: BjSpace.xxl,
      spacing: BjSpace.xl,
      children: [
        for (final group in widget.groups)
          if (group.items.isNotEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  header: true,
                  child: BjSectionHeader(
                    title: group.name.isNotEmpty ? group.name : group.groupId,
                    icon: Icons.domain_rounded,
                    count: group.items.length,
                  ),
                ),
                const SizedBox(height: BjSpace.sm),
                for (final item in group.items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: BjSpace.sm),
                    child: _ManagedRow(
                      item: item,
                      sending: _sending.contains(item.itemKey),
                      sent: _sent.contains(item.itemKey) && !item.held,
                      onSend: () => _send(item),
                    ),
                  ),
              ],
            ),
      ],
    );
  }
}

class _ManagedRow extends StatelessWidget {
  final ManagedQueueItem item;
  final bool sending;
  final bool sent;
  final VoidCallback onSend;

  const _ManagedRow({required this.item, required this.sending, required this.sent, required this.onSend});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final meta = [
      if (item.submitterName.isNotEmpty) item.submitterName,
      if (item.createdAt != null) formatQueueDay(item.createdAt!),
      if (item.relatedAppName.isNotEmpty) item.relatedAppName,
    ].join(' · ');
    return BjCard(
      padding: const EdgeInsets.all(BjSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(item.title.isNotEmpty ? item.title : 'Untitled request', style: text.titleSmall),
              ),
              if (item.status != null) ...[
                const SizedBox(width: BjSpace.sm),
                DevStatusPill(item.status!, showDetail: false),
              ],
            ],
          ),
          if (meta.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: BjSpace.xxs),
              child: Text(meta, style: text.bodySmall),
            ),
          if (item.excerpt.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: BjSpace.sm),
              child: Text(item.excerpt, maxLines: 3, overflow: TextOverflow.ellipsis, style: text.bodyMedium),
            ),
          AnimatedSwitcher(
            duration: BjMotion.medium,
            switchInCurve: BjMotion.curve,
            child: sent
                ? const Padding(
                    key: ValueKey('sent'),
                    padding: EdgeInsets.only(top: BjSpace.md),
                    child: BjStatusPill(label: 'Sent', tone: BjTone.success, icon: Icons.check_rounded),
                  )
                : item.held
                    ? Padding(
                        key: const ValueKey('send'),
                        padding: const EdgeInsets.only(top: BjSpace.md),
                        child: FilledButton.tonalIcon(
                          onPressed: sending ? null : onSend,
                          icon: const Icon(Icons.send_rounded, size: 18),
                          label: const Text('Send to pipeline'),
                          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                        ),
                      )
                    : const SizedBox.shrink(key: ValueKey('none')),
          ),
        ],
      ),
    );
  }
}
