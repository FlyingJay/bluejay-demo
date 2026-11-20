import 'package:bluejay_design/bluejay_design.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';
import 'package:shared_services/group_member_directory.dart';

import 'initials_avatar.dart';

export 'package:shared_services/group_member_directory.dart'
    show GroupMember, GroupMemberDirectory;

/// Picks one or more members of a group (the active group unless [groupId]
/// is given). Pops a [GroupMember] (single select) or a `List<GroupMember>`
/// (multiSelect), read from the group member directory — never another
/// user's `users/{uid}` doc (rules plan T9).
class UserSearchScreen extends StatefulWidget {
  final fire_auth.User currentUser;
  final bool multiSelect;
  final List<String>? excludeUserIds;
  final bool includeCurrentUser;

  /// The group to pick from; defaults to the active group.
  final String? groupId;

  /// Tests inject a directory backed by a fake Firestore.
  final GroupMemberDirectory? directory;

  const UserSearchScreen({
    Key? key,
    required this.currentUser,
    this.multiSelect = false,
    this.excludeUserIds,
    this.includeCurrentUser = false,
    this.groupId,
    this.directory,
  }) : super(key: key);

  @override
  _UserSearchScreenState createState() => _UserSearchScreenState();
}

class _UserSearchScreenState extends State<UserSearchScreen> {
  final _searchController = TextEditingController();
  List<GroupMember> _allUsers = [];
  List<GroupMember> _filteredUsers = [];
  bool _isLoading = true;
  String? _loadError;
  final Set<String> _selectedUserIds = {};

  GroupMemberDirectory get _directory =>
      widget.directory ?? GroupMemberDirectory.instance;

  // ─── Lifecycle ─────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _fetchAllUsers();
    _searchController.addListener(_filterUsers);
  }

  @override
  void dispose() {
    _searchController.removeListener(_filterUsers);
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchAllUsers() async {
    setState(() => _isLoading = true);
    try {
      final members = await _directory.group(widget.groupId);
      _allUsers = members.where((m) {
        if (m.isGuest || m.status == 'DRAFT') return false;
        if (!widget.includeCurrentUser && m.uid == widget.currentUser.uid) {
          return false;
        }
        if (widget.excludeUserIds != null &&
            widget.excludeUserIds!.contains(m.uid)) {
          return false;
        }
        return true;
      }).toList();
      if (!mounted) return;
      setState(() {
        _filteredUsers = _allUsers;
        _isLoading = false;
        _loadError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _allUsers = [];
        _filteredUsers = [];
        _isLoading = false;
        _loadError = '$e';
      });
    }
  }

  void _filterUsers() {
    final searchTerm = _searchController.text.trim().toLowerCase();
    if (searchTerm.isEmpty) {
      setState(() => _filteredUsers = _allUsers);
      return;
    }

    setState(() {
      _filteredUsers =
          _allUsers.where((m) => m.matchesSearch(searchTerm)).toList();
    });
  }

  // ─── Build ─────────────────────────────────────────────────────────

  void _toggle(GroupMember member) {
    setState(() {
      if (!_selectedUserIds.remove(member.uid)) {
        _selectedUserIds.add(member.uid);
      }
    });
  }

  void _done() {
    final selected =
        _allUsers.where((m) => _selectedUserIds.contains(m.uid)).toList();
    Navigator.of(context).pop(selected);
  }

  @override
  Widget build(BuildContext context) {
    return BjPage(
      title: widget.multiSelect ? 'Select people' : 'Find someone',
      maxWidth: BjBreakpoint.formWidth,
      actions: widget.multiSelect
          ? [
              FilledButton.icon(
                onPressed: _selectedUserIds.isEmpty ? null : _done,
                icon: const Icon(Icons.check_rounded, size: 18),
                label: Text(_selectedUserIds.isEmpty
                    ? 'Done'
                    : 'Done (${_selectedUserIds.length})'),
              ),
            ]
          : null,
      body: UserSearchBody(
        searchController: _searchController,
        members: _filteredUsers,
        allMembers: _allUsers,
        isLoading: _isLoading,
        loadError: _loadError,
        multiSelect: widget.multiSelect,
        selectedUserIds: _selectedUserIds,
        onRetry: _fetchAllUsers,
        onTap: (member) => widget.multiSelect
            ? _toggle(member)
            : Navigator.of(context).pop(member),
        onDeselect: (uid) => setState(() => _selectedUserIds.remove(uid)),
      ),
    );
  }
}

/// The search field, selected-people chips and results of
/// [UserSearchScreen], without the data loading, so it can be tested and
/// rendered with sample members.
@visibleForTesting
class UserSearchBody extends StatelessWidget {
  const UserSearchBody({
    super.key,
    required this.searchController,
    required this.members,
    required this.allMembers,
    required this.isLoading,
    required this.loadError,
    required this.multiSelect,
    required this.selectedUserIds,
    required this.onTap,
    required this.onDeselect,
    this.onRetry,
  });

  final TextEditingController searchController;
  final List<GroupMember> members;
  final List<GroupMember> allMembers;
  final bool isLoading;
  final String? loadError;
  final bool multiSelect;
  final Set<String> selectedUserIds;
  final ValueChanged<GroupMember> onTap;
  final ValueChanged<String> onDeselect;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final query = searchController.text.trim();
    final Widget content;
    if (isLoading) {
      content = const BjSkeletonList(key: ValueKey('loading'), count: 6);
    } else if (loadError != null) {
      content = BjStateView.error(
        key: const ValueKey('error'),
        title: 'Couldn\'t load people',
        message: 'Check your connection and try again.',
        onRetry: onRetry,
      );
    } else if (members.isEmpty) {
      content = BjStateView.empty(
        key: ValueKey('empty-$query'),
        icon: Icons.person_search_outlined,
        title: query.isNotEmpty ? 'No one matches "$query"' : 'No one to pick yet',
        message: query.isNotEmpty
            ? 'Try part of their name or their full email address.'
            : 'People appear here once they join this group.',
      );
    } else {
      content = ListView.separated(
        key: const ValueKey('results'),
        padding: const EdgeInsets.only(top: BjSpace.xs, bottom: BjSpace.xxl),
        itemCount: members.length,
        separatorBuilder: (_, __) => const SizedBox(height: BjSpace.sm),
        itemBuilder: (context, index) {
          final member = members[index];
          final isSelected = selectedUserIds.contains(member.uid);
          return BjListRow(
            dense: true,
            title: member.label,
            selected: isSelected,
            leading: InitialsAvatar(name: member.label),
            trailing: multiSelect
                ? _SelectionCheck(selected: isSelected)
                : const Icon(Icons.chevron_right_rounded,
                    color: BjNeutral.inkSubtle),
            onTap: () => onTap(member),
          );
        },
      );
    }

    return BjContent(
      maxWidth: BjBreakpoint.formWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: BjSpace.sm),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: searchController,
            builder: (context, value, _) => TextField(
              controller: searchController,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search by name or email',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: value.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.close_rounded, size: 20),
                        onPressed: searchController.clear,
                      ),
              ),
            ),
          ),
          AnimatedSize(
            duration: BjMotion.medium,
            curve: BjMotion.curve,
            alignment: Alignment.topCenter,
            child: multiSelect && selectedUserIds.isNotEmpty
                ? Padding(
                    padding: const EdgeInsets.only(top: BjSpace.md),
                    child: Wrap(
                      spacing: BjSpace.sm,
                      runSpacing: BjSpace.sm,
                      children: [
                        for (final uid in selectedUserIds)
                          InputChip(
                            avatar: InitialsAvatar(
                                name: _labelFor(uid), size: 24),
                            label: Text(_labelFor(uid)),
                            onDeleted: () => onDeselect(uid),
                            deleteButtonTooltipMessage: 'Remove',
                          ),
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
          const SizedBox(height: BjSpace.md),
          Expanded(
            child: AnimatedSwitcher(
              duration: BjMotion.medium,
              switchInCurve: BjMotion.curve,
              child: content,
            ),
          ),
        ],
      ),
    );
  }

  String _labelFor(String uid) {
    final match = allMembers.where((m) => m.uid == uid);
    return match.isEmpty ? 'User' : match.first.label;
  }
}

class _SelectionCheck extends StatelessWidget {
  const _SelectionCheck({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final accent = context.bj.accent;
    return AnimatedContainer(
      duration: BjMotion.medium,
      curve: BjMotion.curve,
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: selected ? accent : Colors.transparent,
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? accent : BjNeutral.borderStrong,
          width: 2,
        ),
      ),
      child: selected
          ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
          : null,
    );
  }
}
