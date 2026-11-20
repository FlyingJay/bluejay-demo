/// Automations inside another app: [AutomationsPanel] lists one app's
/// rules and built-in automations in its settings, lets a manager switch
/// them on and off, and opens the Automations app to add or change one.
///
/// The panel talks only to the `automations*` callables through
/// [AutomationsApi] (no dependency on packages/automations, which depends
/// on this package). The models, the API client and [describeRule] are
/// exported here for the Automations app to share.
library;

import 'package:bluejay_design/bluejay_design.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';
import 'package:shared_services/active_group_service.dart';

import 'automations/automations_api.dart';
import 'automations/automations_describe.dart';
import 'automations/automations_models.dart';
import 'automations/automations_open.dart';

export 'automations/automations_api.dart';
export 'automations/automations_describe.dart';
export 'automations/automations_models.dart';
export 'automations/automations_open.dart';

/// One app's automations, for its settings screen. Shows nothing at all to
/// people who can't manage automations for [appId] (the callables refuse
/// them), so ordinary members never see it.
class AutomationsPanel extends StatefulWidget {
  /// The app whose automations to list (its `APP_ID`).
  final String appId;

  /// What the panel calls the app ("CRM"); defaults to the catalog's name.
  final String? appName;
  final fire_auth.User? currentUser;
  final AutomationsApi api;

  /// The group; defaults to the active group, and follows it as it changes.
  final String? groupId;

  /// When false, people who can't manage automations see a short
  /// explanation instead of nothing (for a screen that holds only the panel).
  final bool hideWhenUnavailable;

  /// Tests replace how the Automations app opens.
  final AutomationsAppOpener? openApp;

  const AutomationsPanel({
    super.key,
    required this.appId,
    this.appName,
    this.currentUser,
    this.api = const AutomationsApi(),
    this.groupId,
    this.hideWhenUnavailable = true,
    this.openApp,
  });

  @override
  State<AutomationsPanel> createState() => _AutomationsPanelState();
}

class _AutomationsPanelState extends State<AutomationsPanel> {
  AutomationsCatalog? _catalog;
  AutomationsListing? _listing;
  Object? _error;
  bool _denied = false;
  bool _loading = true;
  final Set<String> _busy = {};
  String _loadedGroup = '';

  String get _groupId => widget.groupId ?? ActiveGroupService.instance.activeGroupId ?? '';

  @override
  void initState() {
    super.initState();
    if (widget.groupId == null) ActiveGroupService.instance.addListener(_onGroupChanged);
    _load();
  }

  @override
  void dispose() {
    ActiveGroupService.instance.removeListener(_onGroupChanged);
    super.dispose();
  }

  void _onGroupChanged() {
    if (_groupId != _loadedGroup) _load();
  }

  Future<void> _load() async {
    final group = _groupId;
    _loadedGroup = group;
    if (group.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        widget.api.catalog(group),
        widget.api.list(group, appId: widget.appId),
      ]);
      if (!mounted || group != _loadedGroup) return;
      setState(() {
        _catalog = results[0] as AutomationsCatalog;
        _listing = results[1] as AutomationsListing;
        _denied = !_catalog!.canManageApp(widget.appId);
        _loading = false;
      });
    } catch (e) {
      if (!mounted || group != _loadedGroup) return;
      setState(() {
        _denied = isAutomationsPermissionDenied(e);
        _error = _denied ? null : e;
        _loading = false;
      });
    }
  }

  Future<void> _toggle(AutomationEntry entry, bool enabled) async {
    setState(() => _busy.add(entry.id));
    try {
      if (entry is BuiltInAutomation) {
        await widget.api.setBuiltIn(_groupId, entry.id, enabled: enabled);
      } else {
        await widget.api.setEnabled(_groupId, entry.id, enabled);
      }
      await _load();
    } catch (e) {
      if (mounted) BjSnack.error(context, automationsErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy.remove(entry.id));
    }
  }

  Future<void> _open({bool create = false}) => openAutomationsApp(
        context,
        user: widget.currentUser,
        appFilter: widget.appId,
        create: create,
        installed: _listing?.installed,
        open: widget.openApp,
      );

  String get _appName {
    final name = widget.appName;
    if (name != null && name.isNotEmpty) return name;
    return _catalog?.appName(widget.appId) ?? 'this app';
  }

  @override
  Widget build(BuildContext context) {
    if (_denied) {
      if (widget.hideWhenUnavailable) return const SizedBox.shrink();
      return const BjStateView.locked(
        title: 'Automations are set up by admins',
        message: 'Group admins and this app\'s admins can set up automations. Ask one of them if something '
            'should happen automatically.',
      );
    }
    final catalog = _catalog;
    final listing = _listing;
    if (_loading && listing == null) {
      // Nothing until we know the viewer may manage, so members never see a flash of it.
      return widget.hideWhenUnavailable ? const SizedBox.shrink() : const BjSkeletonList(count: 2, shrinkWrap: true);
    }
    if (_error != null && listing == null) {
      // Embedded in another app's settings, a failure shows nothing: the
      // viewer may not be a manager at all, and the app's own settings matter more.
      if (widget.hideWhenUnavailable) return const SizedBox.shrink();
      return BjFormSection(
        title: 'Automations',
        icon: Icons.bolt_rounded,
        children: [
          BjStateView.error(
            error: automationsErrorMessage(_error!),
            title: 'Couldn\'t load automations',
            onRetry: _load,
          ),
        ],
      );
    }
    if (catalog == null || listing == null) return const SizedBox.shrink();
    return AutomationsPanelView(
      appName: _appName,
      catalog: catalog,
      listing: listing,
      busyIds: _busy,
      onToggle: _toggle,
      onOpen: () => _open(),
      onCreate: () => _open(create: true),
    );
  }
}

/// The panel's content, from data and callbacks (tests render it directly).
class AutomationsPanelView extends StatelessWidget {
  final String appName;
  final AutomationsCatalog catalog;
  final AutomationsListing listing;
  final Set<String> busyIds;
  final void Function(AutomationEntry entry, bool enabled) onToggle;
  final VoidCallback onOpen;
  final VoidCallback onCreate;

  const AutomationsPanelView({
    super.key,
    required this.appName,
    required this.catalog,
    required this.listing,
    this.busyIds = const {},
    required this.onToggle,
    required this.onOpen,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    final entries = listing.all;
    return BjFormSection(
      title: 'Automations',
      icon: Icons.bolt_rounded,
      description: 'What happens automatically in $appName: reminders, To dos, notifications and updates.',
      children: [
        if (entries.isEmpty)
          BjInlineNote('No automations for $appName yet. Start from a template in the Automations app.')
        else
          for (final entry in entries)
            AutomationEntryRow(
              entry: entry,
              summary: entry is BuiltInAutomation && entry.description.isNotEmpty
                  ? entry.description
                  : describeRule(entry, catalog),
              busy: busyIds.contains(entry.id),
              onToggle: (on) => onToggle(entry, on),
              dense: true,
            ),
        Wrap(spacing: BjSpace.sm, runSpacing: BjSpace.sm, children: [
          FilledButton.icon(
            onPressed: onCreate,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('New automation'),
          ),
          OutlinedButton.icon(
            onPressed: onOpen,
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: const Text('Open Automations'),
          ),
        ]),
      ],
    );
  }
}

/// One rule or built-in: its name, what it does, Built in / Paused pills
/// and an on/off switch. Shared by the panel and the Automations app.
class AutomationEntryRow extends StatelessWidget {
  final AutomationEntry entry;
  final String summary;
  final bool busy;

  /// Null hides the switch (people who can't change it).
  final ValueChanged<bool>? onToggle;
  final VoidCallback? onTap;
  final List<BjMenuAction> actions;
  final List<Widget> extraMeta;
  final bool dense;

  const AutomationEntryRow({
    super.key,
    required this.entry,
    required this.summary,
    this.busy = false,
    this.onToggle,
    this.onTap,
    this.actions = const [],
    this.extraMeta = const [],
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final paused = !entry.enabled && (entry.pausedReason ?? '').isNotEmpty;
    final preview = entry is BuiltInAutomation && (entry as BuiltInAutomation).isPreviewOnly;
    final row = BjListRow(
      dense: dense,
      title: entry.name.isEmpty ? 'Untitled automation' : entry.name,
      subtitle: summary,
      leading: BjIconWell(
        icon: entry.isBuiltIn ? Icons.auto_mode_rounded : Icons.bolt_rounded,
        tone: paused ? BjTone.warning : (entry.enabled ? null : BjTone.neutral),
        size: dense ? 32 : 40,
      ),
      meta: [
        if (entry.isBuiltIn) const BjStatusPill(label: 'Built in', tone: BjTone.accent, icon: Icons.verified_outlined),
        if (preview) const BjStatusPill(label: 'Preview only', tone: BjTone.info),
        if (paused)
          const BjStatusPill(label: 'Paused', tone: BjTone.warning, icon: Icons.pause_circle_outline_rounded)
        else if (!entry.enabled)
          const BjStatusPill(label: 'Off'),
        ...extraMeta,
      ],
      trailing: onToggle == null
          ? null
          : busy
              ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
              : Switch(
                  value: entry.enabled,
                  onChanged: onToggle,
                ),
      actions: actions,
      onTap: onTap,
    );
    if (!paused) return row;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      row,
      Padding(
        padding: const EdgeInsets.only(top: BjSpace.xs),
        child: BjInlineNote(
          'Paused: ${entry.pausedReason}. Fix what it says, then switch it back on.',
          icon: Icons.warning_amber_rounded,
          tone: BjTone.warning,
        ),
      ),
    ]);
  }
}

/// A screen holding only [AutomationsPanel], for apps whose settings live
/// in a menu rather than a settings screen.
class AutomationsSettingsPage extends StatelessWidget {
  final String appId;
  final String appName;
  final fire_auth.User? currentUser;
  final AutomationsApi api;

  const AutomationsSettingsPage({
    super.key,
    required this.appId,
    required this.appName,
    this.currentUser,
    this.api = const AutomationsApi(),
  });

  @override
  Widget build(BuildContext context) => BjPage(
        title: 'Automations',
        subtitle: appName,
        maxWidth: BjBreakpoint.formWidth,
        body: BjScrollBody(maxWidth: BjBreakpoint.formWidth, children: [
          AutomationsPanel(
            appId: appId,
            appName: appName,
            currentUser: currentUser,
            api: api,
            hideWhenUnavailable: false,
          ),
        ]),
      );
}

/// A header button that opens [AutomationsSettingsPage] for [appId], for
/// apps without a settings screen. It asks `automationsList` once and
/// shows only when that works, so people who can't manage automations
/// never see it.
class AutomationsHeaderButton extends StatefulWidget {
  final String appId;
  final String appName;
  final fire_auth.User? currentUser;
  final AutomationsApi api;
  final String? groupId;

  const AutomationsHeaderButton({
    super.key,
    required this.appId,
    required this.appName,
    this.currentUser,
    this.api = const AutomationsApi(),
    this.groupId,
  });

  @override
  State<AutomationsHeaderButton> createState() => _AutomationsHeaderButtonState();
}

class _AutomationsHeaderButtonState extends State<AutomationsHeaderButton> {
  bool _show = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final group = widget.groupId ?? ActiveGroupService.instance.activeGroupId ?? '';
    if (group.isEmpty) return;
    try {
      await widget.api.list(group, appId: widget.appId);
      if (mounted) setState(() => _show = true);
    } catch (_) {
      // Not a manager, or not reachable: no button.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_show) return const SizedBox.shrink();
    return IconButton(
      icon: const Icon(Icons.bolt_rounded),
      tooltip: 'Automations',
      onPressed: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AutomationsSettingsPage(
          appId: widget.appId,
          appName: widget.appName,
          currentUser: widget.currentUser,
          api: widget.api,
        ),
      )),
    );
  }
}
