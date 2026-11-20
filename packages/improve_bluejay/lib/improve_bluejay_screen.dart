import 'package:bug_reports/bug_reports_screen.dart';
import 'package:feature_voting/feature_voting_screen.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';

import 'improve_apps_widgets.dart';
import 'improve_bluejay_notification_settings_screen.dart';

class ImproveBluejayScreen extends StatefulWidget {
  final fire_auth.User? currentUser;

  /// When set together with [initialItemType] (from a notification deep
  /// link), opens directly on the matching tab with that idea/bug
  /// scrolled to the top of its section and visually highlighted. An item
  /// in another group that the user reads as an app steward opens the tab's
  /// "Apps I manage" list instead (see BugListPage/FeatureListPage).
  final String? initialItemId;

  /// `'feature'` or `'bug'`. Selects which tab [initialItemId] applies to.
  final String? initialItemType;

  const ImproveBluejayScreen({
    super.key,
    this.currentUser,
    this.initialItemId,
    this.initialItemType,
  });

  @override
  State<ImproveBluejayScreen> createState() => _ImproveBluejayScreenState();
}

class _ImproveBluejayScreenState extends State<ImproveBluejayScreen> {
  void _showBugSubmitDialog() {
    showBugSubmitSheet(context, currentUser: widget.currentUser);
  }

  void _showFeatureSubmitDialog() {
    showFeatureSubmitDialog(context, currentUser: widget.currentUser);
  }

  void _openNotificationSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ImproveBluejayNotificationSettingsScreen(
          currentUser: widget.currentUser,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ImproveAppsShell(
      initialTab: widget.initialItemType == 'bug'
          ? ImproveAppsTab.bugs
          : ImproveAppsTab.ideas,
      onNewIdea: _showFeatureSubmitDialog,
      onReportBug: _showBugSubmitDialog,
      onOpenNotificationSettings: _openNotificationSettings,
      ideasTab: FeatureListPage(
        currentUser: widget.currentUser,
        initialItemId:
            widget.initialItemType == 'feature' ? widget.initialItemId : null,
      ),
      bugsTab: BugListPage(
        currentUser: widget.currentUser,
        initialItemId:
            widget.initialItemType == 'bug' ? widget.initialItemId : null,
      ),
    );
  }
}
