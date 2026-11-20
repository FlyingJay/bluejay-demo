import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:improve_bluejay/improve_apps_widgets.dart';

/// Stand-in for a hosted idea/bug list (the real ones read Firestore).
class StubTicketList extends StatelessWidget {
  const StubTicketList({super.key, required this.tickets, required this.icon});

  final List<(String, String, String)> tickets;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return BjScrollBody(
      children: [
        BjSectionHeader(title: 'Open', count: tickets.length),
        for (final (title, body, app) in tickets)
          BjListRow(
            leading: BjIconWell(icon: icon),
            title: title,
            subtitle: body,
            meta: [BjStatusPill(label: app, icon: Icons.apps_rounded)],
          ),
      ],
    );
  }
}

const sampleIdeas = [
  ('Let me pin a list to the home screen', 'So my grocery list is one tap away.', 'Lists'),
  ('Dark mode for Notes', 'Easier on the eyes when writing at night.', 'Notes'),
  ('Weekly summary email', 'A Monday recap of what changed in my projects.', 'Projects'),
];

const sampleBugs = [
  ('Upload stalls at 99%', 'Large PDFs never finish uploading on mobile.', 'Storage'),
  ('Due dates shift by a day', 'Tasks due Friday show as Thursday after saving.', 'Lists'),
];

/// The Improve Apps shell with stub tabs; taps are recorded in [log].
Widget shellHarness({
  ImproveAppsTab initialTab = ImproveAppsTab.ideas,
  List<String>? log,
}) =>
    ImproveAppsShell(
      initialTab: initialTab,
      ideasTab: const StubTicketList(tickets: sampleIdeas, icon: Icons.lightbulb_rounded),
      bugsTab: const StubTicketList(tickets: sampleBugs, icon: Icons.bug_report_rounded),
      onNewIdea: () => log?.add('idea'),
      onReportBug: () => log?.add('bug'),
      onOpenNotificationSettings: () => log?.add('settings'),
    );

/// The notification settings page around [view].
Widget settingsPage(NotificationSettingsView view) => BjPage(
      title: 'Notification settings',
      maxWidth: BjBreakpoint.formWidth,
      body: view,
    );

const sampleStewardedApps = ['Lists', 'Notes'];
