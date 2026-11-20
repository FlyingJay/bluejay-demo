import 'package:flutter/foundation.dart';

/// A simple singleton service that stores the currently selected group ID.
///
/// This provides a global, synchronous access point for the active group ID
/// without requiring every package to depend on a state-management library.
///
/// [GroupProvider] keeps this service in sync whenever the active group
/// changes. Packages creating Firestore documents should use [ScopedCollection]
/// rather than reading this service directly.
///
/// Every signed-in session belongs to a group: an invitation, self-serve
/// signup and a guest link all join one. The launcher opens no app until a
/// group is active, so a package's screens always run with one and don't
/// need a "pick a group" state. The group can change while an app is open,
/// so screens that hold a group-scoped query listen to this service. The
/// values are `null` only before the launcher has loaded the user's groups,
/// after sign-out, or for someone removed from every group, and no app is
/// open in any of those.
class ActiveGroupService extends ChangeNotifier {
  ActiveGroupService._();

  static final ActiveGroupService instance = ActiveGroupService._();

  String? _activeGroupId;
  String? _activeGroupDocId;
  String? _activeGroupName;
  String? _activeGroupDocumentName;

  /// The `groupId` slug of the currently selected workspace; `null` only
  /// while no app is open (see the class comment).
  String? get activeGroupId => _activeGroupId;

  /// The Firestore doc id of the currently selected workspace (`groups/{id}`;
  /// the id in membership doc ids and the access index), or `null` if no
  /// group has been selected yet. Usually equal to [activeGroupId].
  String? get activeGroupDocId => _activeGroupDocId;

  /// The display name of the currently selected workspace, or `null` if
  /// no group has been selected yet.
  String? get activeGroupName => _activeGroupName;

  /// The name the currently selected workspace goes by with clients, guests
  /// and the public: its legal name when it has one, else
  /// [activeGroupName] (`groupDocumentName` in group_docs.dart). Screens a
  /// client or guest sees use this; members' own navigation keeps
  /// [activeGroupName].
  String? get activeGroupDocumentName => _activeGroupDocumentName ?? _activeGroupName;

  /// Updates the stored group ID. Called by [GroupProvider].
  set activeGroupId(String? value) {
    if (_activeGroupId == value) return;
    _activeGroupId = value;
    notifyListeners();
  }

  /// Updates the stored group doc id. Called by [GroupProvider].
  set activeGroupDocId(String? value) {
    if (_activeGroupDocId == value) return;
    _activeGroupDocId = value;
    notifyListeners();
  }

  /// Updates the stored group display name. Called by [GroupProvider].
  set activeGroupName(String? value) {
    if (_activeGroupName == value) return;
    _activeGroupName = value;
    notifyListeners();
  }

  /// Updates the stored outward-facing group name. Called by [GroupProvider].
  set activeGroupDocumentName(String? value) {
    if (_activeGroupDocumentName == value) return;
    _activeGroupDocumentName = value;
    notifyListeners();
  }

  List<GroupSummary> _userGroups = const [];

  /// The signed-in user's groups (empty when signed out), for packages that
  /// show or switch to a group other than the active one: a To do item from
  /// another group, say. Published by [GroupProvider].
  List<GroupSummary> get userGroups => _userGroups;

  /// Replaces [userGroups]. Called by [GroupProvider].
  set userGroups(List<GroupSummary> value) {
    if (listEquals(_userGroups, value)) return;
    _userGroups = List.unmodifiable(value);
    notifyListeners();
  }

  /// The user's group whose doc id or `groupId` slug is [idOrSlug], or null
  /// when they aren't in it. Records store either, depending on their
  /// writer (server-written ones usually hold the doc id).
  GroupSummary? groupFor(String? idOrSlug) {
    if (idOrSlug == null || idOrSlug.isEmpty) return null;
    for (final group in _userGroups) {
      if (group.docId == idOrSlug || group.groupId == idOrSlug) return group;
    }
    return null;
  }

  /// Whether [idOrSlug] (doc id or slug) is the active group.
  bool isActive(String idOrSlug) =>
      idOrSlug.isNotEmpty &&
      (idOrSlug == _activeGroupId || idOrSlug == _activeGroupDocId);

  /// Makes the user's group [idOrSlug] (doc id or slug) active, through the
  /// switcher the launcher registers ([GroupProvider]). Returns whether that
  /// group is active afterwards: false when the user isn't in it or no
  /// switcher is registered (a package's own tests).
  bool switchTo(String idOrSlug) {
    if (isActive(idOrSlug)) return true;
    final group = groupFor(idOrSlug);
    final switcher = groupSwitcher;
    if (group == null || switcher == null) return false;
    return switcher(group.groupId);
  }

  /// Switches the launcher to the group with this `groupId` slug; returns
  /// false when the user isn't in it. Set by [GroupProvider].
  bool Function(String groupId)? groupSwitcher;
}

/// One of the signed-in user's groups, as [ActiveGroupService] publishes it.
class GroupSummary {
  const GroupSummary({
    required this.docId,
    required this.groupId,
    required this.name,
    this.memberCount = 0,
  });

  /// `groups/{docId}`.
  final String docId;

  /// The URL slug (the `groupId` field).
  final String groupId;

  final String name;

  /// How many members the group has; 0 when unknown.
  final int memberCount;

  @override
  bool operator ==(Object other) =>
      other is GroupSummary &&
      other.docId == docId &&
      other.groupId == groupId &&
      other.name == name &&
      other.memberCount == memberCount;

  @override
  int get hashCode => Object.hash(docId, groupId, name, memberCount);
}
