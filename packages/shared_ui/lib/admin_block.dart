import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';

/// Who an app (or one part of it) is for, as [AdminBlockView] words it.
enum AdminAudience {
  /// Admins of the active group: `groups/{id}.adminIds`, owners and super
  /// admins (the app's `:admin` tier). What `apps/{id}.adminOnly` means.
  groupAdmins,

  /// People with edit access to the app in the active group.
  groupEditors,

  /// Platform admins (the `admin` platform role).
  platformAdmins,

  /// Platform admins and developers.
  platformStaff,

  /// Members of the developer group.
  developerGroup,
}

extension AdminAudienceText on AdminAudience {
  /// The block's heading, e.g. "For group admins".
  String get heading => switch (this) {
    AdminAudience.groupAdmins => 'For group admins',
    AdminAudience.groupEditors => 'For group editors',
    AdminAudience.platformAdmins => 'For platform admins',
    AdminAudience.platformStaff => 'For platform admins and developers',
    AdminAudience.developerGroup => 'For the developer group',
  };

  /// The people the block names, e.g. "this group's admins".
  String get people => switch (this) {
    AdminAudience.groupAdmins => "this group's admins",
    AdminAudience.groupEditors => 'people with edit access in this group',
    AdminAudience.platformAdmins => 'Bluejay platform admins',
    AdminAudience.platformStaff => 'Bluejay platform admins and developers',
    AdminAudience.developerGroup => 'members of the developer group',
  };

  /// Who to ask for access.
  String get askWho => switch (this) {
    AdminAudience.groupAdmins ||
    AdminAudience.groupEditors => "one of this group's admins",
    _ => 'a platform admin',
  };
}

/// The one "you can't use this" state for admin apps: a lock, who the app
/// (or [feature]) is for, and who to ask. Every admin app's access block
/// renders this, and the launcher's admin-only gate shows it in place of an
/// app flagged `apps/{id}.adminOnly`, so they all read the same.
///
/// Use [AdminBlockPage] for a whole-app block; this body-only form sits
/// inside a page or tab that already has its own app bar.
class AdminBlockView extends StatelessWidget {
  const AdminBlockView({
    super.key,
    required this.appName,
    this.audience = AdminAudience.groupAdmins,
    this.feature,
    this.detail,
    this.action,
  });

  /// The app, e.g. "Billing".
  final String appName;
  final AdminAudience audience;

  /// The part of the app that's blocked, as a phrase that reads with "is",
  /// e.g. "Managing these settings", when the rest of the app is open. Null
  /// blocks the whole app.
  final String? feature;

  /// A sentence of app-specific context, after the standard message.
  final String? detail;

  /// An optional button, e.g. a settings shortcut for platform admins.
  final Widget? action;

  /// The standard message, without [detail].
  String get message =>
      '${feature ?? appName} is only for '
      '${audience.people}. Ask ${audience.askWho} if you need access.';

  @override
  Widget build(BuildContext context) => BjStateView.locked(
    title: audience.heading,
    message: detail == null ? message : '$message $detail',
    action: action,
  );
}

/// [AdminBlockView] as a whole page, titled with the app's name and with
/// the usual back button.
class AdminBlockPage extends StatelessWidget {
  const AdminBlockPage({
    super.key,
    required this.appName,
    this.audience = AdminAudience.groupAdmins,
    this.detail,
    this.action,
  });

  final String appName;
  final AdminAudience audience;
  final String? detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) => BjPage(
    title: appName,
    body: AdminBlockView(
      appName: appName,
      audience: audience,
      detail: detail,
      action: action,
    ),
  );
}
