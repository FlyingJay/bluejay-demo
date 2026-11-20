import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:projects/constants.dart';
import 'package:projects/models.dart';
import 'package:projects/projects_access.dart';
import 'package:projects/project_detail_screen.dart';
import 'package:projects/project_links.dart';
import 'package:projects/project_styles.dart';
import 'package:projects/project_widgets.dart';
import 'package:shared_services/active_group_service.dart';
import 'package:shared_services/scoped_collection.dart';
import 'package:shared_services/bluejay_firestore.dart';
import 'package:shared_services/access_index.dart';
import 'package:shared_services/cloud_functions.dart';
import 'package:shared_services/active_group_pending.dart';

final _projects = ScopedCollection(
  collection: 'projects_hub_projects',
  appId: APP_ID,
);

final _projectTags = ScopedCollection(
  collection: 'projects_hub_tags',
  appId: APP_ID,
);

final _blockers = ScopedCollection(
  collection: 'projects_hub_blockers',
  appId: APP_ID,
);

class ProjectsDashboardScreen extends StatefulWidget {
  final fire_auth.User? currentUser;

  /// A project to open once the list loads ([projectArg]), and a task in it
  /// to show ([taskArg]). One the viewer can't see, or that's gone, leaves
  /// them on the list with a note.
  final String? initialProjectId;
  final String? initialTaskId;

  const ProjectsDashboardScreen({
    super.key,
    this.currentUser,
    this.initialProjectId,
    this.initialTaskId,
  });

  @override
  State<ProjectsDashboardScreen> createState() => _ProjectsDashboardScreenState();
}

Future<void> _ensureGroupTags(List<String> tags) async {
  final normalizedTags = normalizeProjectTags(tags);
  final groupId = ActiveGroupService.instance.activeGroupId;
  if (groupId == null || groupId.isEmpty) return;
  for (final tag in normalizedTags) {
    final key = projectTagNaturalKey(tag);
    if ((await _projectTags.getForKey(key)).exists) continue;
    await _projectTags.setForKey(
      key,
      {
        'key': projectTagKey(tag),
        'label': tag,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }
}

class _ProjectsDashboardScreenState extends State<ProjectsDashboardScreen> {
  ProjectStatus? _statusFilter;
  final Set<String> _tagFilters = <String>{};
  List<ProjectTagRecord> _groupTagsCache = const [];
  String? _appsGroupId;
  Future<List<ProjectAppOption>> _appsFuture = Future.value(const []);
  List<ProjectAppOption> _apps = const [];

  /// [ProjectsDashboardScreen.initialProjectId] until it has been opened or
  /// found missing.
  late String? _pendingProjectId = widget.initialProjectId;

  /// (Re)loads the app list when the active group changes. Feeds the app
  /// names on project cards and the form's app picker.
  void _ensureAppsLoaded(String? groupId) {
    if (groupId == null || groupId.isEmpty || groupId == _appsGroupId) return;
    _appsGroupId = groupId;
    final future = loadProjectAppOptions(groupId).catchError((_) => const <ProjectAppOption>[]);
    _appsFuture = future;
    future.then((apps) {
      if (!mounted || _appsGroupId != groupId) return;
      setState(() => _apps = apps);
    });
  }

  Future<BlockerTaskRecord?> _loadNextAction(String projectId) async {
    final snap = await _blockers.query.where('projectId', isEqualTo: projectId).get();
    final tasks = snap.docs.map(BlockerTaskRecord.fromFirestore).toList();
    return _findNextAction(tasks);
  }

  BlockerTaskRecord? _findNextAction(List<BlockerTaskRecord> tasks) {
    if (tasks.isEmpty) return null;
    final childrenByParent = <String, List<BlockerTaskRecord>>{};
    for (final task in tasks) {
      final parentId = task.parentTaskId;
      if (parentId == null || parentId.isEmpty) continue;
      childrenByParent.putIfAbsent(parentId, () => []).add(task);
    }

    bool isActionable(BlockerTaskRecord task) {
      if (task.isDone) return false;
      final children = childrenByParent[task.id] ?? const [];
      return children.every((child) => child.isDone);
    }

    final actionable = tasks.where(isActionable).toList()
      ..sort(compareActionableBlockerTasks);

    return actionable.isEmpty ? null : actionable.first;
  }

  Future<void> _showProjectForm({
    required ProjectsAccess access,
    ProjectRecord? project,
    ProjectRecord? duplicateFrom,
  }) async {
    assert(project == null || duplicateFrom == null, 'Cannot specify both project and duplicateFrom');
    final isEditing = project != null;
    final result = await showBjSheet<_ProjectFormResult>(
      context,
      title: duplicateFrom != null ? 'Duplicate project' : (isEditing ? 'Edit project' : 'Create project'),
      subtitle: 'Capture your plan quickly with clearer inputs.',
      builder: (context) => ProjectFormSheet(
        project: project,
        duplicateFrom: duplicateFrom,
        availableGroupTags: _groupTagsCache,
        appsFuture: _appsFuture,
        // Only a hint to skip a doomed call — the form still falls back to
        // read-only if projectsListClientGroups answers permission-denied.
        canListClientGroups: access.isPlatformAdmin,
      ),
    );

    if (result == null || widget.currentUser == null) return;

    final payload = {
      'title': result.title,
      'goal': result.goal,
      'description': result.description,
      'status': projectStatusToString(result.status),
      'tags': normalizeProjectTags(result.tags),
      'relatedAppIds': result.relatedAppIds,
      'clientGroupIds': result.clientGroupIds,
      'clientGroupNames': result.clientGroupNames,
      'dueDate': result.dueDate == null ? null : Timestamp.fromDate(result.dueDate!),
      'ownerId': project?.ownerId ?? widget.currentUser!.uid,
      'memberIds': project?.memberIds ?? [widget.currentUser!.uid],
      'updatedAt': FieldValue.serverTimestamp(),
    };

    await _ensureGroupTags(result.tags);

    if (isEditing) {
      await _projects.doc(project.id).update(payload);
    } else {
      await _projects.add({
        ...payload,
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
  }

  Future<void> _deleteProject(ProjectRecord project) async {
    // Count the tasks first so the confirmation can say what goes.
    int? taskCount;
    try {
      taskCount = (await _blockers.query.where('projectId', isEqualTo: project.id).get()).docs.length;
    } catch (_) {
      taskCount = null;
    }
    if (!mounted) return;

    final shouldDelete = await showBjConfirm(
      context,
      title: 'Delete project?',
      message: '"${project.title}" is removed for everyone in this group.',
      destructive: true,
      confirmLabel: 'Delete project',
      consequences: [
        'The project, its goal, description, tags and links are deleted',
        taskCount == null
            ? 'All of its blocker tasks are deleted'
            : taskCount == 0
                ? 'It has no blocker tasks'
                : 'Its $taskCount blocker ${taskCount == 1 ? 'task is' : 'tasks are'} deleted, including their progress and attachment links',
        "This can't be undone",
      ],
    );

    if (!shouldDelete) return;

    final taskSnap = await _blockers.query.where('projectId', isEqualTo: project.id).get();
    final batch = BluejayFirestore.forApp(APP_ID).batch();
    for (final doc in taskSnap.docs) {
      batch.delete(doc.reference);
    }
    batch.delete(_projects.doc(project.id));
    await batch.commit();
  }

  void _openProject(
    ProjectRecord project,
    fire_auth.User user,
    ProjectsAccess access, {
    String? focusTaskId,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProjectDetailScreen(
          currentUser: user,
          project: project,
          access: access,
          initialTaskId: focusTaskId,
        ),
      ),
    );
  }

  /// Opens [_pendingProjectId] once the group's projects have loaded from the
  /// server, or says it isn't there (deleted, another group's, or hidden from
  /// the viewer) and stays on the list.
  void _openPendingProject(
    QuerySnapshot snapshot,
    List<ProjectRecord> projects,
    fire_auth.User user,
    ProjectsAccess access,
  ) {
    final pendingId = _pendingProjectId;
    if (pendingId == null) return;
    ProjectRecord? project;
    for (final candidate in projects) {
      if (candidate.id == pendingId) project = candidate;
    }
    // A cached first snapshot may not have it yet; wait for the server's.
    if (project == null && snapshot.metadata.isFromCache) return;
    _pendingProjectId = null;
    final found = project;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (found == null) {
        BjSnack.info(context, "That project isn't available. It may have been deleted, or you can't see it.");
        return;
      }
      _openProject(found, user, access, focusTaskId: widget.initialTaskId);
    });
  }

  Widget _buildCard(
    ProjectRecord project, {
    required fire_auth.User user,
    required ProjectsAccess access,
    required bool canEdit,
    required bool canCreate,
  }) {
    return ProjectCard(
      project: project,
      apps: _apps,
      nextAction: _loadNextAction(project.id),
      onTap: () => _openProject(project, user, access),
      actions: [
        if (canEdit)
          BjMenuAction(
            label: 'Edit project',
            icon: Icons.edit_outlined,
            onSelected: () => _showProjectForm(access: access, project: project),
          ),
        if (canCreate)
          BjMenuAction(
            label: 'Duplicate project',
            icon: Icons.copy_all_outlined,
            onSelected: () => _showProjectForm(access: access, duplicateFrom: project),
          ),
        if (canEdit)
          BjMenuAction(
            label: 'Delete project',
            icon: Icons.delete_outline_rounded,
            destructive: true,
            onSelected: () => _deleteProject(project),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.currentUser;
    final groupName = ActiveGroupService.instance.activeGroupName;
    if (user == null) {
      return const BjPage(
        title: 'Projects',
        body: BjStateView.locked(
          icon: Icons.login_rounded,
          title: 'Please log in to manage projects.',
        ),
      );
    }

    final activeGroupId = ActiveGroupService.instance.activeGroupId;
    _ensureAppsLoaded(activeGroupId);

    return AccessIndexBuilder(
      uid: user.uid,
      appId: APP_ID,
      builder: (context, accessSnapshot) {
        final access = ProjectsAccess.fromData(accessSnapshot.data?.data());
        final canView = access.canViewGroup(activeGroupId);
        final canCreate = access.canCreateInGroup(activeGroupId);
        final canEdit = access.canEditGroup(activeGroupId);

        return BjPage(
          title: 'Projects',
          subtitle: (groupName ?? '').trim().isEmpty ? null : groupName,
          floatingActionButton: canCreate
              ? FloatingActionButton.extended(
                  onPressed: () => _showProjectForm(access: access),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('New project'),
                )
              : null,
          body: Builder(
            builder: (context) {
              // Keep showing data while a rebuilt stream resubscribes.
              if (!accessSnapshot.hasData && !accessSnapshot.hasError) {
                return const ProjectsDashboardSkeleton();
              }
              if (activeGroupId == null || activeGroupId.isEmpty) {
                return const ActiveGroupPending();
              }
              if (!canView) {
                return const BjStateView.locked(
                  title: 'You do not have access to Projects in this group.',
                  message: 'Ask a group admin if you think you should.',
                );
              }

              return StreamBuilder<QuerySnapshot>(
                stream: _projectTags.query.snapshots(),
                builder: (context, tagSnapshot) {
                  if (tagSnapshot.hasError) {
                    return BjStateView.error(
                      title: "Couldn't load this group's tags",
                      error: tagSnapshot.error,
                      onRetry: () => setState(() {}),
                    );
                  }
                  if (!tagSnapshot.hasData) {
                    return const ProjectsDashboardSkeleton();
                  }
                  // One record per tag key: until the M4 rekey deletes the
                  // legacy `{groupId}:{key}` docs, a tag can be in twice.
                  final byKey = <String, ProjectTagRecord>{};
                  for (final doc in tagSnapshot.data!.docs) {
                    final record = ProjectTagRecord.fromFirestore(doc);
                    final groupId = (doc.data() as Map<String, dynamic>?)?['groupId'];
                    final tagged = groupId is String && doc.id.startsWith('${groupId}__');
                    if (tagged || !byKey.containsKey(record.key)) byKey[record.key] = record;
                  }
                  final groupTags = byKey.values.toList()
                    ..sort((a, b) => a.key.compareTo(b.key));
                  _groupTagsCache = groupTags;
                  return StreamBuilder<QuerySnapshot>(
                    stream: _projects.query.snapshots(),
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return BjStateView.error(
                          title: "Couldn't load projects",
                          error: snapshot.error,
                          onRetry: () => setState(() {}),
                        );
                      }
                      if (!snapshot.hasData) {
                        return const ProjectsDashboardSkeleton();
                      }
                      final projects = snapshot.data!.docs.map(ProjectRecord.fromFirestore).toList();
                      _openPendingProject(snapshot.data!, projects, user, access);
                      return ProjectsDashboardBody(
                        projects: projects,
                        groupTags: groupTags,
                        statusFilter: _statusFilter,
                        tagFilters: _tagFilters,
                        onStatusChanged: (status) => setState(() => _statusFilter = status),
                        onTagToggled: (key, selected) => setState(() {
                          if (selected) {
                            _tagFilters.add(key);
                          } else {
                            _tagFilters.remove(key);
                          }
                        }),
                        onClearTags: () => setState(() => _tagFilters.clear()),
                        onClearFilters: () => setState(() {
                          _statusFilter = null;
                          _tagFilters.clear();
                        }),
                        canCreate: canCreate,
                        onCreate: () => _showProjectForm(access: access),
                        cardBuilder: (project) => _buildCard(
                          project,
                          user: user,
                          access: access,
                          canEdit: canEdit,
                          canCreate: canCreate,
                        ),
                      );
                    },
                  );
                },
              );
            },
          ),
        );
      },
    );
  }
}

class _ProjectFormResult {
  final String title;
  final String goal;
  final String description;
  final ProjectStatus status;
  final DateTime? dueDate;
  final List<String> tags;
  final List<String> relatedAppIds;
  final List<String> clientGroupIds;
  final Map<String, String> clientGroupNames;

  const _ProjectFormResult({
    required this.title,
    required this.goal,
    required this.description,
    required this.status,
    required this.dueDate,
    required this.tags,
    required this.relatedAppIds,
    required this.clientGroupIds,
    required this.clientGroupNames,
  });
}

class _ClientGroupOption {
  final String id;
  final String name;

  const _ClientGroupOption({required this.id, required this.name});
}

/// The create / edit / duplicate project form, shown in a [showBjSheet]. Pops
/// with the entered values; the screen does the write. Public so tests can
/// pump it.
class ProjectFormSheet extends StatefulWidget {
  final ProjectRecord? project;
  final ProjectRecord? duplicateFrom;
  final List<ProjectTagRecord> availableGroupTags;
  final Future<List<ProjectAppOption>> appsFuture;
  final bool canListClientGroups;

  const ProjectFormSheet({
    super.key,
    required this.project,
    this.duplicateFrom,
    this.availableGroupTags = const [],
    required this.appsFuture,
    required this.canListClientGroups,
  });

  @override
  State<ProjectFormSheet> createState() => _ProjectFormSheetState();
}

class _ProjectFormSheetState extends State<ProjectFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _goalController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _tagController;
  late ProjectStatus _status;
  DateTime? _dueDate;
  late List<String> _tags;
  late Set<String> _tagKeys;
  late Map<String, String> _availableTagLabelsByKey;

  // Linked apps and client groups. Saved ids are kept selected even when the
  // pickers can't offer them (app uninstalled, group no longer returned by
  // projectsListClientGroups) so editing never silently drops them.
  late Set<String> _relatedAppIds;
  late Set<String> _clientGroupIds;
  late Map<String, String> _clientGroupNames;
  List<ProjectAppOption> _apps = const [];
  bool _loadingApps = true;
  late bool _clientGroupsEditable;
  List<_ClientGroupOption> _clientGroupOptions = const [];
  bool _loadingClientGroups = false;
  String? _clientGroupsError;
  int _clientGroupsRequest = 0;

  @override
  void initState() {
    super.initState();
    final source = widget.project ?? widget.duplicateFrom;
    _titleController = TextEditingController(text: source?.title ?? '');
    _goalController = TextEditingController(text: source?.goal ?? '');
    _descriptionController = TextEditingController(text: source?.description ?? '');
    _tagController = TextEditingController();
    _status = source?.status ?? ProjectStatus.planned;
    _dueDate = source?.dueDate;
    _availableTagLabelsByKey = {
      for (final tag in widget.availableGroupTags) tag.key: tag.label,
    };
    _tags = normalizeProjectTags(source?.tags)
        .map((tag) => _availableTagLabelsByKey[projectTagKey(tag)] ?? tag)
        .toList();
    _tagKeys = _tags.map(projectTagKey).toSet();
    _relatedAppIds = {...?source?.relatedAppIds};
    _clientGroupIds = {...?source?.clientGroupIds};
    _clientGroupNames = {...?source?.clientGroupNames};
    _clientGroupsEditable = widget.canListClientGroups;
    widget.appsFuture.then((apps) {
      if (!mounted) return;
      setState(() {
        _apps = apps;
        _loadingApps = false;
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshClientGroups());
  }

  /// Re-queries the client groups for the selected apps. Only the latest
  /// request's answer is applied, since the selection can change mid-flight.
  Future<void> _refreshClientGroups() async {
    if (!mounted || !_clientGroupsEditable) return;
    final request = ++_clientGroupsRequest;
    if (_relatedAppIds.isEmpty) {
      setState(() {
        _clientGroupOptions = const [];
        _loadingClientGroups = false;
        _clientGroupsError = null;
      });
      return;
    }
    setState(() {
      _loadingClientGroups = true;
      _clientGroupsError = null;
    });
    try {
      final result = await BluejayFunctions.instance
          .httpsCallable('projectsListClientGroups')
          .call({'appIds': _relatedAppIds.toList()});
      if (!mounted || request != _clientGroupsRequest) return;
      final options = _parseClientGroups(result.data);
      setState(() {
        _clientGroupOptions = options;
        for (final option in options) {
          _clientGroupNames[option.id] = option.name;
        }
        _loadingClientGroups = false;
      });
    } on FirebaseFunctionsException catch (e) {
      if (!mounted || request != _clientGroupsRequest) return;
      setState(() {
        _loadingClientGroups = false;
        if (e.code == 'permission-denied') {
          _clientGroupsEditable = false;
        } else {
          _clientGroupsError = e.message ?? 'Could not load client groups (${e.code}).';
        }
      });
    } catch (e) {
      if (!mounted || request != _clientGroupsRequest) return;
      setState(() {
        _loadingClientGroups = false;
        _clientGroupsError = 'Could not load client groups: $e';
      });
    }
  }

  List<_ClientGroupOption> _parseClientGroups(Object? data) {
    final rawGroups = data is Map ? data['groups'] : null;
    if (rawGroups is! List) return const [];
    final options = <_ClientGroupOption>[];
    for (final raw in rawGroups) {
      if (raw is! Map) continue;
      final id = raw['id'];
      if (id is! String || id.trim().isEmpty) continue;
      final name = raw['name'];
      options.add(
        _ClientGroupOption(
          id: id.trim(),
          name: name is String && name.trim().isNotEmpty ? name.trim() : id.trim(),
        ),
      );
    }
    options.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return options;
  }

  String _clientGroupName(String groupId) {
    final name = (_clientGroupNames[groupId] ?? '').trim();
    return name.isEmpty ? groupId : name;
  }

  Widget _buildAppsPicker() {
    if (_loadingApps) {
      return const _ChipSkeletons();
    }
    final installed = _apps.where((app) => app.installed).toList();
    final offeredIds = installed.map((app) => app.id).toSet();
    // Saved apps the group no longer has installed: still shown (selected) so
    // they're only removed if someone deselects them.
    final savedElsewhere = _relatedAppIds.where((id) => !offeredIds.contains(id)).toList();
    if (installed.isEmpty && savedElsewhere.isEmpty) {
      return const BjInlineNote('No apps are installed in this group.', icon: Icons.apps_outlined);
    }

    void toggle(String appId, bool selected) {
      setState(() {
        if (selected) {
          _relatedAppIds.add(appId);
        } else {
          _relatedAppIds.remove(appId);
        }
      });
      _refreshClientGroups();
    }

    return Wrap(
      spacing: BjSpace.sm,
      runSpacing: BjSpace.sm,
      children: [
        ...installed.map(
          (app) => FilterChip(
            label: Text(app.name),
            selected: _relatedAppIds.contains(app.id),
            onSelected: (selected) => toggle(app.id, selected),
          ),
        ),
        ...savedElsewhere.map(
          (appId) => FilterChip(
            avatar: const Icon(Icons.warning_amber_rounded, size: 18),
            tooltip: 'Saved on this project but no longer installed in this group',
            label: Text('${projectAppName(appId, _apps)} (not installed)'),
            selected: true,
            onSelected: (selected) => toggle(appId, selected),
          ),
        ),
      ],
    );
  }

  Widget _buildClientGroupsPicker() {
    if (!_clientGroupsEditable) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_clientGroupIds.isNotEmpty) ...[
            Wrap(
              spacing: BjSpace.xs + 2,
              runSpacing: BjSpace.xs + 2,
              children: _clientGroupIds
                  .map((id) => BjStatusPill(label: _clientGroupName(id), icon: Icons.business_outlined))
                  .toList(),
            ),
            const SizedBox(height: BjSpace.sm),
          ],
          BjInlineNote(
            _clientGroupIds.isEmpty
                ? 'None. Only platform admins can change client groups.'
                : 'Only platform admins can change client groups.',
            icon: Icons.lock_outline_rounded,
          ),
        ],
      );
    }

    final offeredIds = _clientGroupOptions.map((option) => option.id).toSet();
    final savedElsewhere = _clientGroupIds.where((id) => !offeredIds.contains(id)).toList();

    void toggle(String groupId, bool selected) {
      setState(() {
        if (selected) {
          _clientGroupIds.add(groupId);
        } else {
          _clientGroupIds.remove(groupId);
        }
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_relatedAppIds.isEmpty)
          const BjInlineNote('Select an app to see the groups that have it installed.', icon: Icons.touch_app_outlined),
        if (_loadingClientGroups) ...[
          const SizedBox(height: BjSpace.sm),
          const _ChipSkeletons(),
        ],
        if (_clientGroupsError != null) ...[
          const SizedBox(height: BjSpace.sm),
          BjInlineNote(_clientGroupsError!, icon: Icons.error_outline_rounded, tone: BjTone.danger),
        ],
        if (_clientGroupOptions.isNotEmpty || savedElsewhere.isNotEmpty) ...[
          if (_relatedAppIds.isEmpty || _loadingClientGroups || _clientGroupsError != null)
            const SizedBox(height: BjSpace.sm),
          Wrap(
            spacing: BjSpace.sm,
            runSpacing: BjSpace.sm,
            children: [
              ..._clientGroupOptions.map(
                (option) => FilterChip(
                  label: Text(option.name),
                  selected: _clientGroupIds.contains(option.id),
                  onSelected: (selected) => toggle(option.id, selected),
                ),
              ),
              ...savedElsewhere.map(
                (groupId) => FilterChip(
                  label: Text(_clientGroupName(groupId)),
                  selected: true,
                  onSelected: (selected) => toggle(groupId, selected),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    _goalController.dispose();
    _descriptionController.dispose();
    _tagController.dispose();
    super.dispose();
  }

  void _addTag() {
    final candidate = normalizeProjectTag(_tagController.text);
    if (candidate == null) return;
    final candidateKey = projectTagKey(candidate);
    if (_tagKeys.contains(candidateKey)) {
      _tagController.clear();
      return;
    }
    final canonicalLabel = _availableTagLabelsByKey[candidateKey] ?? candidate;
    setState(() {
      _tags.add(canonicalLabel);
      _tagKeys.add(candidateKey);
      _tags.sort((a, b) => projectTagKey(a).compareTo(projectTagKey(b)));
      _tagController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.project != null;
    final query = _tagController.text.trim().toLowerCase();
    final suggestions = widget.availableGroupTags
        .where((tag) => !_tagKeys.contains(tag.key))
        .where((tag) => query.isEmpty || tag.label.toLowerCase().contains(query))
        .take(12)
        .toList();

    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _titleController,
            autofocus: true,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'Project name'),
            validator: (value) => value == null || value.trim().isEmpty ? 'Project name is required' : null,
          ),
          const SizedBox(height: BjSpace.md),
          TextFormField(
            controller: _goalController,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Goal',
              prefixIcon: Icon(Icons.flag_outlined),
            ),
          ),
          const SizedBox(height: BjSpace.md),
          TextFormField(
            controller: _descriptionController,
            minLines: 3,
            maxLines: 5,
            decoration: const InputDecoration(labelText: 'Description', alignLabelWithHint: true),
          ),
          const SizedBox(height: BjSpace.xl),
          const BjFieldLabel('Status', icon: Icons.flag_circle_outlined),
          Wrap(
            spacing: BjSpace.sm,
            runSpacing: BjSpace.sm,
            children: [
              for (final status in ProjectStatus.values)
                StatusChoiceChip(
                  style: projectStatusStyle(status),
                  selected: _status == status,
                  onSelected: () => setState(() => _status = status),
                ),
            ],
          ),
          const SizedBox(height: BjSpace.lg),
          const BjFieldLabel('Due date', icon: Icons.event_outlined),
          BjDateField(value: _dueDate, emptyLabel: 'No due date selected', onChanged: (date) => setState(() => _dueDate = date)),
          const SizedBox(height: BjSpace.xl),
          const BjFieldLabel('Tags', icon: Icons.sell_outlined),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _tagController,
                  textInputAction: TextInputAction.done,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Add or reuse a tag',
                    hintText: 'e.g. redesign, urgent',
                  ),
                  onSubmitted: (_) => _addTag(),
                ),
              ),
              const SizedBox(width: BjSpace.sm),
              FilledButton.tonalIcon(
                onPressed: _addTag,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add'),
              ),
            ],
          ),
          if (suggestions.isNotEmpty) ...[
            const SizedBox(height: BjSpace.sm),
            Wrap(
              spacing: BjSpace.sm,
              runSpacing: BjSpace.sm,
              children: [
                for (final tag in suggestions)
                  ActionChip(
                    avatar: const Icon(Icons.add_rounded, size: 16),
                    label: Text(tag.label),
                    onPressed: () {
                      _tagController.text = tag.label;
                      _addTag();
                    },
                  ),
              ],
            ),
          ],
          const SizedBox(height: BjSpace.sm),
          if (_tags.isEmpty)
            const BjInlineNote('No tags yet.', icon: Icons.sell_outlined)
          else
            Wrap(
              spacing: BjSpace.sm,
              runSpacing: BjSpace.sm,
              children: [
                for (final tag in _tags)
                  InputChip(
                    label: Text(tag),
                    selected: true,
                    showCheckmark: false,
                    onDeleted: () => setState(() {
                      _tags.remove(tag);
                      _tagKeys.remove(projectTagKey(tag));
                    }),
                  ),
              ],
            ),
          const SizedBox(height: BjSpace.xl),
          const BjFieldLabel('Apps', icon: Icons.apps_rounded, helper: 'Bluejay apps this project concerns.'),
          _buildAppsPicker(),
          const SizedBox(height: BjSpace.xl),
          BjFieldLabel(
            'Client groups',
            icon: Icons.business_outlined,
            helper: _clientGroupsEditable && _relatedAppIds.isNotEmpty
                ? 'Groups that have the selected apps installed.'
                : null,
          ),
          _buildClientGroupsPicker(),
          BjSheetActions(
            onCancel: () => Navigator.of(context).pop(),
            primaryLabel: isEditing ? 'Save project' : 'Create project',
            onPrimary: () {
              if (!_formKey.currentState!.validate()) return;
              Navigator.of(context).pop(
                _ProjectFormResult(
                  title: _titleController.text.trim(),
                  goal: _goalController.text.trim(),
                  description: _descriptionController.text.trim(),
                  status: _status,
                  dueDate: _dueDate,
                  tags: _tags,
                  relatedAppIds: _relatedAppIds.toList(),
                  clientGroupIds: _clientGroupIds.toList(),
                  clientGroupNames: {
                    for (final id in _clientGroupIds)
                      if ((_clientGroupNames[id] ?? '').trim().isNotEmpty) id: _clientGroupNames[id]!.trim(),
                  },
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Placeholder chips while a picker's options load.
class _ChipSkeletons extends StatelessWidget {
  const _ChipSkeletons();

  @override
  Widget build(BuildContext context) {
    return const Wrap(
      spacing: BjSpace.sm,
      runSpacing: BjSpace.sm,
      children: [
        BjSkeleton(width: 88, height: 32, radius: BjRadius.pill),
        BjSkeleton(width: 120, height: 32, radius: BjRadius.pill),
        BjSkeleton(width: 72, height: 32, radius: BjRadius.pill),
      ],
    );
  }
}
