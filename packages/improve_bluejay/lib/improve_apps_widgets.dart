import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';

import 'constants.dart';
import 'package:shared_services/active_group_pending.dart';

// Presentational widgets for Improve Apps: data in, callbacks out, no
// Firestore or FirebaseAuth. The screens in this package own the streams and
// services and wire them to these, which keeps them testable and lets
// test/screenshots_test.dart render them with fixtures.

// ─────────────────────────────────────────────────────────────────────────────
// Improve Apps shell: header, Ideas | Bugs tabs and the one primary action
// ─────────────────────────────────────────────────────────────────────────────

/// The Improve Apps screen around its two hosted lists: the page header with
/// a notification-settings action, the Ideas | Bugs tabs, and a FAB that
/// files an idea or a bug depending on the tab.
///
/// [ideasTab] and [bugsTab] are the hosted feature_voting / bug_reports
/// lists; the screen passes the real ones and tests pass stand-ins.
class ImproveAppsShell extends StatefulWidget {
  const ImproveAppsShell({
    super.key,
    required this.ideasTab,
    required this.bugsTab,
    required this.onNewIdea,
    required this.onReportBug,
    required this.onOpenNotificationSettings,
    this.initialTab = ImproveAppsTab.ideas,
  });

  final Widget ideasTab;
  final Widget bugsTab;
  final VoidCallback onNewIdea;
  final VoidCallback onReportBug;
  final VoidCallback onOpenNotificationSettings;
  final ImproveAppsTab initialTab;

  @override
  State<ImproveAppsShell> createState() => _ImproveAppsShellState();
}

/// The two tabs of [ImproveAppsShell], in order.
enum ImproveAppsTab { ideas, bugs }

class _ImproveAppsShellState extends State<ImproveAppsShell>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(
    length: ImproveAppsTab.values.length,
    vsync: this,
    initialIndex: widget.initialTab.index,
  )..addListener(_onTabChanged);

  static const _tabs = [
    BjTab('Ideas', icon: Icons.lightbulb_outline_rounded),
    BjTab('Bugs', icon: Icons.bug_report_outlined),
  ];

  void _onTabChanged() {
    if (!_tabController.indexIsChanging) setState(() {});
  }

  @override
  void dispose() {
    _tabController
      ..removeListener(_onTabChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isIdeas = _tabController.index == ImproveAppsTab.ideas.index;
    return BjPage(
      title: improveBluejayDisplayName,
      subtitle: 'Suggest ideas and report bugs for your apps',
      actions: [
        IconButton(
          onPressed: widget.onOpenNotificationSettings,
          icon: const Icon(Icons.notifications_outlined),
          tooltip: 'Notification settings',
        ),
      ],
      bottom: PreferredSize(
        preferredSize:
            const Size.fromHeight(BjSegmentedTabs.height + BjSpace.sm * 2),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: BjSpace.sm),
          child: BjContent(
            child: BjSegmentedTabs(tabs: _tabs, controller: _tabController),
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [widget.ideasTab, widget.bugsTab],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: isIdeas ? widget.onNewIdea : widget.onReportBug,
        icon: AnimatedSwitcher(
          duration: BjMotion.fast,
          child: Icon(
            isIdeas ? Icons.lightbulb_rounded : Icons.bug_report_rounded,
            key: ValueKey(isIdeas),
          ),
        ),
        label: AnimatedSize(
          duration: BjMotion.medium,
          curve: BjMotion.curve,
          child: Text(isIdeas ? 'New idea' : 'Report a bug'),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Request choosers
// ─────────────────────────────────────────────────────────────────────────────

/// One row of a request chooser: an icon, a title and a one-line subtitle.
class RequestChooserOption extends StatelessWidget {
  const RequestChooserOption({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.tone,
  });

  final IconData icon;

  /// Tints the icon well; null uses the accent gradient.
  final BjTone? tone;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return BjListRow(
      leading: BjIconWell(icon: icon, tone: tone),
      title: title,
      subtitle: subtitle,
      trailing: const Icon(Icons.chevron_right_rounded,
          color: BjNeutral.inkSubtle),
      onTap: onTap,
    );
  }
}

/// A vertical list of [RequestChooserOption]s with even spacing.
class RequestChooserOptions extends StatelessWidget {
  const RequestChooserOptions({super.key, required this.options});

  final List<RequestChooserOption> options;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < options.length; i++) ...[
          if (i > 0) const SizedBox(height: BjSpace.sm),
          options[i],
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Notification settings
// ─────────────────────────────────────────────────────────────────────────────

/// What the notification settings screen can show.
enum NotificationSettingsStatus { loading, signedOut, noGroup, error, ready }

/// The current notification preferences, as the screen holds them.
class NotificationPreferences {
  const NotificationPreferences({
    this.bugs = false,
    this.ideas = false,
    this.stewardedApps = true,
  });

  final bool bugs;
  final bool ideas;
  final bool stewardedApps;
}

/// The body of the notification settings screen for each
/// [NotificationSettingsStatus]. The toggles report changes through the
/// `onXChanged` callbacks; null callbacks disable them.
class NotificationSettingsView extends StatelessWidget {
  const NotificationSettingsView({
    super.key,
    required this.status,
    this.preferences = const NotificationPreferences(),
    this.stewardedAppNames = const [],
    this.onBugsChanged,
    this.onIdeasChanged,
    this.onStewardedAppsChanged,
    this.onRetry,
  });

  final NotificationSettingsStatus status;
  final NotificationPreferences preferences;

  /// Names of the apps the active group stewards; the stewarded-apps toggle
  /// only shows when there are any.
  final List<String> stewardedAppNames;
  final ValueChanged<bool>? onBugsChanged;
  final ValueChanged<bool>? onIdeasChanged;
  final ValueChanged<bool>? onStewardedAppsChanged;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final Widget child = switch (status) {
      NotificationSettingsStatus.loading =>
        const _NotificationSettingsSkeleton(),
      NotificationSettingsStatus.signedOut => const BjStateView.locked(
          title: 'Sign in to manage notifications',
          message: 'Notification preferences are saved to your account.',
        ),
      NotificationSettingsStatus.noGroup => const ActiveGroupPending(),
      NotificationSettingsStatus.error => BjStateView.error(
          title: "Couldn't load your notification settings",
          message: 'Check your connection and try again.',
          onRetry: onRetry,
        ),
      NotificationSettingsStatus.ready => _form(context),
    };
    return AnimatedSwitcher(
      duration: BjMotion.medium,
      switchInCurve: BjMotion.curve,
      child: KeyedSubtree(key: ValueKey(status), child: child),
    );
  }

  Widget _form(BuildContext context) {
    return BjScrollBody(
      maxWidth: BjBreakpoint.formWidth,
      children: [
        BjFormSection(
          title: 'New posts in this group',
          icon: Icons.notifications_active_outlined,
          description:
              'Get notified when someone in this group posts a new bug or idea.',
          spacing: 0,
          children: [
            _NotificationToggle(
              icon: Icons.bug_report_rounded,
              tone: BjTone.danger,
              title: 'Bug reports',
              value: preferences.bugs,
              onChanged: onBugsChanged,
            ),
            const Divider(height: BjSpace.lg),
            _NotificationToggle(
              icon: Icons.lightbulb_rounded,
              title: 'New ideas',
              value: preferences.ideas,
              onChanged: onIdeasChanged,
            ),
          ],
        ),
        if (stewardedAppNames.isNotEmpty)
          BjFormSection(
            title: 'Apps my group manages',
            icon: Icons.apps_rounded,
            description: 'Your group looks after these apps for everyone.',
            children: [
              _NotificationToggle(
                icon: Icons.apartment_rounded,
                tone: BjTone.info,
                title: 'Requests from any group',
                subtitle: 'Bugs and ideas from any group about '
                    '${stewardedAppNames.join(', ')}.',
                value: preferences.stewardedApps,
                onChanged: onStewardedAppsChanged,
              ),
            ],
          ),
      ],
    );
  }
}

class _NotificationToggle extends StatelessWidget {
  const _NotificationToggle({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.tone,
  });

  final IconData icon;
  final BjTone? tone;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      contentPadding: EdgeInsets.zero,
      secondary: BjIconWell(icon: icon, tone: tone, size: 36),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
    );
  }
}

class _NotificationSettingsSkeleton extends StatelessWidget {
  const _NotificationSettingsSkeleton();

  @override
  Widget build(BuildContext context) {
    Widget row() => const Row(children: [
          BjSkeleton(width: 36, height: 36, radius: BjRadius.md),
          SizedBox(width: BjSpace.lg),
          Expanded(child: BjSkeleton(height: 14)),
          SizedBox(width: BjSpace.xxl),
          BjSkeleton(width: 48, height: 28, radius: BjRadius.pill),
        ]);
    return BjScrollBody(
      maxWidth: BjBreakpoint.formWidth,
      children: [
        BjCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const BjSkeleton(width: 200, height: 18),
              const SizedBox(height: BjSpace.sm),
              const BjSkeleton(height: 12),
              const SizedBox(height: BjSpace.xl),
              row(),
              const SizedBox(height: BjSpace.xl),
              row(),
            ],
          ),
        ),
      ],
    );
  }
}
