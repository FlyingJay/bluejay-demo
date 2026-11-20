import 'package:bluejay_design/bluejay_design.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';
import 'package:shared_services/active_group_service.dart';
import 'package:shared_services/scoped_collection.dart';
import 'package:shared_services/bluejay_firestore.dart';
import 'package:improve_bluejay/constants.dart';

import 'improve_apps_widgets.dart';

const _improveBluejayAppId = 'improve-apps';

/// One subscription doc per user per group, keyed by uid through
/// [ScopedCollection.docForKey] (`{groupId}__{uid}`).
final _improveBluejaySubscriptions = ScopedCollection(
  collection: 'improve_bluejay_subscriptions',
  appId: _improveBluejayAppId,
);

class ImproveBluejayNotificationSettingsScreen extends StatefulWidget {
  final fire_auth.User? currentUser;

  const ImproveBluejayNotificationSettingsScreen({
    super.key,
    this.currentUser,
  });

  @override
  State<ImproveBluejayNotificationSettingsScreen> createState() =>
      _ImproveBluejayNotificationSettingsScreenState();
}

class _ImproveBluejayNotificationSettingsScreenState
    extends State<ImproveBluejayNotificationSettingsScreen> {
  bool _isLoading = true;
  bool _loadFailed = false;
  bool _subscribeToBugs = false;
  bool _subscribeToIdeas = false;
  // Requests from other groups about apps this group stewards
  // (apps/{appId}.stewardGroupIds). On unless explicitly turned off — see
  // functions/_improve_apps_new_items.js.
  bool _subscribeToStewardedApps = true;
  // Names of the apps the active group stewards; the toggle only shows when
  // there are any.
  List<String> _stewardedAppNames = const [];
  String? _groupId;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final user = widget.currentUser;
    final groupId = ActiveGroupService.instance.activeGroupId;

    if (mounted) {
      setState(() {
        _groupId = groupId;
        _isLoading = true;
        _loadFailed = false;
      });
    }

    if (user == null || groupId == null || groupId.isEmpty) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
      return;
    }

    try {
      final results = await Future.wait([
        _improveBluejaySubscriptions.getForKey(user.uid),
        BluejayFirestore.forApp(improveBluejayAppId)
            .collection('apps')
            .where('stewardGroupIds', arrayContains: groupId)
            .get(),
      ]);
      final data = (results[0] as KeyedDocSnapshot).data;
      final stewardedApps = (results[1] as QuerySnapshot<Map<String, dynamic>>)
          .docs
          .map((d) => (d.data()['name'] as String?)?.trim().isNotEmpty == true
              ? (d.data()['name'] as String).trim()
              : d.id)
          .toList()
        ..sort();

      if (!mounted) return;
      setState(() {
        _subscribeToBugs = data?['subscribeToBugs'] == true;
        _subscribeToIdeas = data?['subscribeToIdeas'] == true;
        _subscribeToStewardedApps = data?['subscribeToStewardedApps'] != false;
        _stewardedAppNames = stewardedApps;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadFailed = true;
      });
    }
  }

  Future<bool> _savePreferences() async {
    final user = widget.currentUser;
    final groupId = _groupId;
    if (user == null || groupId == null || groupId.isEmpty) {
      return false;
    }

    try {
      await _improveBluejaySubscriptions.setForKey(
        user.uid,
        {
          // set() stamps groupId/appId/creatorId/ownerIds on create.
          'userId': user.uid,
          'subscribeToBugs': _subscribeToBugs,
          'subscribeToIdeas': _subscribeToIdeas,
          'subscribeToStewardedApps': _subscribeToStewardedApps,
        },
        SetOptions(merge: true),
      );
      return true;
    } catch (_) {
      if (!mounted) return false;
      BjSnack.error(context, "Couldn't save your notification settings. Try again.");
      return false;
    }
  }

  Future<void> _toggleBugSubscription(bool value) async {
    final previous = _subscribeToBugs;
    setState(() => _subscribeToBugs = value);
    final saved = await _savePreferences();
    if (!saved && mounted) {
      setState(() => _subscribeToBugs = previous);
    }
  }

  Future<void> _toggleIdeaSubscription(bool value) async {
    final previous = _subscribeToIdeas;
    setState(() => _subscribeToIdeas = value);
    final saved = await _savePreferences();
    if (!saved && mounted) {
      setState(() => _subscribeToIdeas = previous);
    }
  }

  Future<void> _toggleStewardedAppsSubscription(bool value) async {
    final previous = _subscribeToStewardedApps;
    setState(() => _subscribeToStewardedApps = value);
    final saved = await _savePreferences();
    if (!saved && mounted) {
      setState(() => _subscribeToStewardedApps = previous);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasUser = widget.currentUser != null;
    final hasGroup = _groupId != null && _groupId!.isNotEmpty;
    final canEdit = hasUser && hasGroup && !_isLoading;

    final status = _isLoading
        ? NotificationSettingsStatus.loading
        : !hasUser
            ? NotificationSettingsStatus.signedOut
            : !hasGroup
                ? NotificationSettingsStatus.noGroup
                : _loadFailed
                    ? NotificationSettingsStatus.error
                    : NotificationSettingsStatus.ready;

    return BjPage(
      title: 'Notification settings',
      maxWidth: BjBreakpoint.formWidth,
      body: NotificationSettingsView(
        status: status,
        preferences: NotificationPreferences(
          bugs: _subscribeToBugs,
          ideas: _subscribeToIdeas,
          stewardedApps: _subscribeToStewardedApps,
        ),
        stewardedAppNames: _stewardedAppNames,
        onBugsChanged: canEdit ? _toggleBugSubscription : null,
        onIdeasChanged: canEdit ? _toggleIdeaSubscription : null,
        onStewardedAppsChanged:
            canEdit ? _toggleStewardedAppsSubscription : null,
        onRetry: _loadPreferences,
      ),
    );
  }
}
