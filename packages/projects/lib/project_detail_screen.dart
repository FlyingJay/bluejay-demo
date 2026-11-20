import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:projects/constants.dart';
import 'package:projects/models.dart';
import 'package:projects/project_links.dart';
import 'package:projects/project_styles.dart';
import 'package:projects/project_widgets.dart';
import 'package:projects/projects_access.dart';
import 'package:shared_services/active_group_service.dart';
import 'package:shared_services/scoped_collection.dart';
import 'package:shared_services/scoped_storage.dart';
import 'package:shared_ui/bug_reproduction_fields.dart';
import 'package:shared_services/bluejay_firestore.dart';
import 'package:shared_services/cloud_functions.dart';
import 'package:shared_services/active_group_pending.dart';
import 'package:shared_services/shared_place.dart';

final _projectTasks = ScopedCollection(
  collection: 'projects_hub_blockers',
  appId: APP_ID,
);

final _taskFileStorage = ScopedStorage(
  folder: 'projects_hub_task_files',
  appId: APP_ID,
);

final _projects = ScopedCollection(
  collection: 'projects_hub_projects',
  appId: APP_ID,
);

class ProjectDetailScreen extends StatefulWidget {
  final fire_auth.User currentUser;
  final ProjectRecord project;
  final ProjectsAccess access;

  /// A task to bring into view and highlight once the tasks load
  /// ([taskArg]); a note says so when it's no longer in the project.
  final String? initialTaskId;

  const ProjectDetailScreen({
    super.key,
    required this.currentUser,
    required this.project,
    required this.access,
    this.initialTaskId,
  });

  @override
  State<ProjectDetailScreen> createState() => _ProjectDetailScreenState();
}

class _ProjectDetailScreenState extends State<ProjectDetailScreen> {
  bool _hideCompletedTasks = false;
  final Set<String> _filingChangeRequestTaskIds = {};
  late final Future<List<ProjectAppOption>> _appsFuture;
  List<ProjectAppOption> _apps = const [];

  /// The task a shared link pointed at, highlighted while this screen shows.
  late String? _focusTaskId = widget.initialTaskId;
  BlockerTaskRecord? _focusTask;
  bool _focusResolved = false;
  final GlobalKey _focusKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _appsFuture = loadProjectAppOptions(ActiveGroupService.instance.activeGroupId)
        .catchError((_) => const <ProjectAppOption>[]);
    _appsFuture.then((apps) {
      if (mounted) setState(() => _apps = apps);
    });
  }

  /// Returns the set of all descendant task IDs reachable from [taskId] in the
  /// blocker tree. Uses BFS with a visited set to handle any pre-existing cycles
  /// defensively and avoid infinite loops.
  Set<String> _getDescendants(String taskId, List<BlockerTaskRecord> tasks) {
    final descendants = <String>{};
    final queue = <String>[taskId];
    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      for (final task in tasks) {
        if (task.parentTaskId == current && !descendants.contains(task.id)) {
          descendants.add(task.id);
          queue.add(task.id);
        }
      }
    }
    return descendants;
  }

  /// Who closed a task, written with the status change so
  /// `projectsOnTaskWritten` can leave them out of the "Task closed" alert it
  /// sends everyone else on the project.
  Map<String, dynamic> get _closedByMe => {'closedBy': widget.currentUser.uid};

  Future<void> _toggleDone(BlockerTaskRecord task) async {
    final nextStatus = task.isDone ? BlockerStatus.todo : BlockerStatus.done;
    await _projectTasks.doc(task.id).update({
      'status': blockerStatusToString(nextStatus),
      if (nextStatus == BlockerStatus.done) ..._closedByMe,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> _showTaskForm({
    BlockerTaskRecord? task,
    String? defaultParentTaskId,
    required List<BlockerTaskRecord> availableParents,
  }) async {
    final result = await showBjSheet<_TaskFormResult>(
      context,
      title: task != null ? 'Edit blocker task' : 'Add blocker task',
      subtitle: 'Capture what is blocking progress and keep momentum.',
      // Editing a task is being at it, for Chat's "Link to where I am".
      builder: (context) => ProjectPlace(
        project: widget.project,
        task: task,
        child: TaskFormSheet(
          task: task,
          defaultParentTaskId: defaultParentTaskId,
          availableParents: availableParents,
          getDescendants: _getDescendants,
        ),
      ),
    );

    if (result == null) return;

    final payload = {
      'projectId': widget.project.id,
      'title': result.title,
      'description': result.description,
      'parentTaskId': result.parentTaskId,
      'status': blockerStatusToString(result.status),
      'priority': result.priority,
      'dueDate': result.dueDate == null ? null : Timestamp.fromDate(result.dueDate!),
      'attachments': result.attachments.map((item) => item.toMap()).toList(),
      'updatedAt': FieldValue.serverTimestamp(),
    };

    if (task != null) {
      await _projectTasks.doc(task.id).update({
        ...payload,
        if (!task.isDone && result.status == BlockerStatus.done) ..._closedByMe,
      });
    } else {
      await _projectTasks.add({
        ...payload,
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
  }

  /// "Create change request": files an Improve Apps bug report or feature
  /// request from the task via `projectsCreateChangeRequest`. The server links
  /// it back onto the task (changeRequest / changeRequestState), mirrors its
  /// progress and pull request, and marks the task done once the change is
  /// live.
  Future<void> _createChangeRequest(BlockerTaskRecord task) async {
    final apps = await _appsFuture;
    if (!mounted) return;
    // The project's own apps when it names any, otherwise whatever is
    // installed in the active group.
    final relatedAppIds = widget.project.relatedAppIds;
    final appChoices = relatedAppIds.isNotEmpty
        ? relatedAppIds.map((id) => ProjectAppOption(id: id, name: projectAppName(id, apps), installed: true)).toList()
        : apps.where((app) => app.installed).toList();

    final choice = await showDialog<_ChangeRequestChoice>(
      context: context,
      builder: (context) => _ChangeRequestDialog(task: task, appChoices: appChoices),
    );
    if (choice == null || !mounted) return;

    setState(() => _filingChangeRequestTaskIds.add(task.id));
    try {
      await BluejayFunctions.instance.httpsCallable('projectsCreateChangeRequest').call({
        'taskId': task.id,
        'itemType': choice.itemType,
        'relatedAppId': choice.appId,
        if (choice.reproduction != null) ...choice.reproduction!.toCreateFields(),
      });
      if (!mounted) return;
      BjSnack.success(
        context,
        'Filed a ${choice.itemType == 'bug' ? 'bug report' : 'feature request'} in Improve Apps. '
        'This task will complete automatically when the change is live.',
      );
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      final message = e.code == 'failed-precondition'
          ? 'This task already has a change request.'
          : '[${e.code}] ${e.message ?? 'Failed to create the change request.'}';
      BjSnack.error(context, message);
    } catch (e) {
      if (!mounted) return;
      BjSnack.error(context, 'Failed to create the change request: $e');
    } finally {
      if (mounted) setState(() => _filingChangeRequestTaskIds.remove(task.id));
    }
  }

  Future<void> _deleteTask(BlockerTaskRecord task, List<BlockerTaskRecord> allTasks) async {
    final children = BlockerTree.childrenOf(task.id, allTasks);
    String? parentTitle;
    for (final candidate in allTasks) {
      if (candidate.id == task.parentTaskId) parentTitle = candidate.title;
    }
    final shouldDelete = await showBjConfirm(
      context,
      title: 'Delete blocker task?',
      message: '"${task.title}" is removed from this project.',
      destructive: true,
      confirmLabel: 'Delete task',
      consequences: [
        'The task, its details, status, priority and due date are deleted',
        if (children.isNotEmpty)
          'Its ${children.length} child ${children.length == 1 ? 'blocker moves' : 'blockers move'} up to '
              '${parentTitle == null ? 'the top level' : '"$parentTitle"'}; they are kept',
        if (task.attachments.isNotEmpty)
          'Its ${task.attachments.length} ${task.attachments.length == 1 ? 'attachment is' : 'attachments are'} unlinked from the task',
        "This can't be undone",
      ],
    );

    if (!shouldDelete) return;

    final batch = BluejayFirestore.forApp(APP_ID).batch();
    for (final child in children) {
      batch.update(_projectTasks.doc(child.id), {'parentTaskId': task.parentTaskId});
    }
    batch.delete(_projectTasks.doc(task.id));
    await batch.commit();
  }

  Widget _buildTaskCard(
    BlockerTaskRecord task,
    int openChildCount, {
    required List<BlockerTaskRecord> allTasks,
    required bool canEdit,
    required String? groupId,
  }) {
    final canCreateChangeRequest = widget.access.canCreateChangeRequest(groupId, task);
    final filing = _filingChangeRequestTaskIds.contains(task.id);
    final card = BlockerTaskCard(
      task: task,
      openChildCount: openChildCount,
      onToggleDone: canEdit ? () => _toggleDone(task) : null,
      requestStatus: buildTaskRequestStatus(
        task,
        filing: filing,
        showLegacyAgentStatus: widget.access.canViewLegacyAgentDispatch,
      ),
      actions: [
        if (canEdit) ...[
          BjMenuAction(
            label: 'Edit',
            icon: Icons.edit_outlined,
            onSelected: () => _showTaskForm(task: task, availableParents: allTasks),
          ),
          BjMenuAction(
            label: 'Add blocker beneath this task',
            icon: Icons.subdirectory_arrow_right_rounded,
            onSelected: () => _showTaskForm(defaultParentTaskId: task.id, availableParents: allTasks),
          ),
        ],
        // Disabled while a request is being filed, so it can't be sent twice.
        if (canCreateChangeRequest)
          BjMenuAction(
            label: 'Create change request',
            icon: Icons.rate_review_outlined,
            enabled: !filing,
            onSelected: () => _createChangeRequest(task),
          ),
        if (canEdit)
          BjMenuAction(
            label: 'Delete',
            icon: Icons.delete_outline_rounded,
            destructive: true,
            onSelected: () => _deleteTask(task, allTasks),
          ),
      ],
    );
    if (task.id != _focusTaskId) return card;
    return DecoratedBox(
      key: _focusKey,
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        border: Border.all(color: context.bj.accent, width: 2),
        borderRadius: BorderRadius.circular(BjRadius.lg),
      ),
      child: card,
    );
  }

  /// Finds the linked task once the tasks load: brings it into view, or says
  /// it's gone (deleted, or moved to another project).
  void _resolveFocusTask(QuerySnapshot snapshot, List<BlockerTaskRecord> tasks) {
    final focusId = _focusTaskId;
    if (focusId == null || _focusResolved) return;
    BlockerTaskRecord? found;
    for (final task in tasks) {
      if (task.id == focusId) found = task;
    }
    // A cached first snapshot may not have it yet; wait for the server's.
    if (found == null && snapshot.metadata.isFromCache) return;
    _focusResolved = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (found == null) {
        setState(() => _focusTaskId = null);
        BjSnack.info(context, "That task isn't in this project any more.");
        return;
      }
      setState(() {
        _focusTask = found;
        // Show it even when it's done and completed tasks are hidden.
        if (found!.isDone) _hideCompletedTasks = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _focusKey.currentContext;
        if (target != null && target.mounted) {
          Scrollable.ensureVisible(target, alignment: 0.3, duration: const Duration(milliseconds: 300));
        }
      });
    });
  }

  /// Each reader's alert preference for this project, keyed by their uid.
  /// `projectsOnTaskWritten` skips anyone with `muted: true`.
  late final ScopedCollection _myPrefs = _projects.sub(widget.project.id, 'notification_prefs');

  /// Bell in the header: whether this user hears about tasks added to or
  /// closed in this project. On unless they've muted it.
  Widget _buildNotificationToggle() {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _myPrefs.doc(widget.currentUser.uid).snapshots(),
      builder: (context, snapshot) {
        final muted = snapshot.data?.data()?['muted'] == true;
        return IconButton(
          tooltip: muted
              ? 'Notifications off for this project. Turn on'
              : 'Notifications on for this project. Turn off',
          icon: Icon(muted ? Icons.notifications_off_outlined : Icons.notifications_active_outlined),
          onPressed: snapshot.hasData ? () => _setMuted(!muted) : null,
        );
      },
    );
  }

  Future<void> _setMuted(bool muted) async {
    try {
      await _myPrefs.set(_myPrefs.doc(widget.currentUser.uid), {
        'userId': widget.currentUser.uid,
        'muted': muted,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(muted
            ? "You won't be notified about tasks in this project."
            : "You'll be notified when tasks are added or closed in this project."),
      ));
    } catch (error) {
      debugPrint('Failed to update project notifications: $error');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't update notifications for this project.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeGroupId = ActiveGroupService.instance.activeGroupId;
    final canView = widget.access.canViewGroup(activeGroupId);
    final canCreate = widget.access.canCreateInGroup(activeGroupId);
    final canEdit = widget.access.canEditGroup(activeGroupId);
    final groupName = (ActiveGroupService.instance.activeGroupName ?? '').trim();

    return ProjectPlace(
      project: widget.project,
      task: _focusTask,
      child: _buildPage(
        activeGroupId: activeGroupId,
        canView: canView,
        canCreate: canCreate,
        canEdit: canEdit,
        groupName: groupName,
      ),
    );
  }

  Widget _buildPage({
    required String? activeGroupId,
    required bool canView,
    required bool canCreate,
    required bool canEdit,
    required String groupName,
  }) {
    return BjPage(
      title: widget.project.title,
      subtitle: groupName.isEmpty ? null : groupName,
      actions: [if (canView) _buildNotificationToggle()],
      floatingActionButton: canCreate
          ? FloatingActionButton.extended(
              onPressed: () => _showTaskForm(availableParents: const []),
              icon: const Icon(Icons.add_task_rounded),
              label: const Text('Add blocker'),
            )
          : null,
      body: StreamBuilder<QuerySnapshot>(
        stream: _projectTasks.query.where('projectId', isEqualTo: widget.project.id).snapshots(),
        builder: (context, snapshot) {
          if (activeGroupId == null || activeGroupId.isEmpty) {
            return const ActiveGroupPending();
          }
          if (!canView) {
            return const BjStateView.locked(
              title: 'You do not have access to this group\'s projects.',
              message: 'Ask a group admin if you think you should.',
            );
          }
          return BjSnapshotView<QuerySnapshot>(
            snapshot: snapshot,
            errorTitle: "Couldn't load this project's tasks",
            onRetry: () => setState(() {}),
            loading: const ProjectDetailSkeleton(),
            builder: (data) {
              final tasks = data.docs.map(BlockerTaskRecord.fromFirestore).toList();
              _resolveFocusTask(data, tasks);
              return ProjectDetailBody(
                project: widget.project,
                tasks: tasks,
                apps: _apps,
                hideCompleted: _hideCompletedTasks,
                onHideCompletedChanged: (selected) => setState(() => _hideCompletedTasks = selected),
                onAddTask: canCreate ? () => _showTaskForm(availableParents: tasks) : null,
                taskBuilder: (task, openChildCount) => _buildTaskCard(
                  task,
                  openChildCount,
                  allTasks: tasks,
                  canEdit: canEdit,
                  groupId: activeGroupId,
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// Marks a project, or a task in it, as a shared place: `{project, task}`
/// in Projects. The detail screen and task sheet are pushed above the app's
/// own marker, so this names the app itself.
class ProjectPlace extends StatelessWidget {
  final ProjectRecord project;
  final BlockerTaskRecord? task;
  final Widget child;

  const ProjectPlace({super.key, required this.project, this.task, required this.child});

  @override
  Widget build(BuildContext context) {
    final task = this.task;
    return PlaceMarker(
      appId: APP_ID,
      appName: 'Projects',
      args: projectPlaceArgs(project.id, taskId: task?.id),
      title: task == null ? project.title : task.title,
      child: child,
    );
  }
}

class _ChangeRequestChoice {
  /// 'bug' or 'feature'.
  final String itemType;
  final String appId;

  /// Required for bugs (validated here and again by the callable).
  final BugReproduction? reproduction;

  const _ChangeRequestChoice({required this.itemType, required this.appId, this.reproduction});
}

class _ChangeRequestDialog extends StatefulWidget {
  final BlockerTaskRecord task;
  final List<ProjectAppOption> appChoices;

  const _ChangeRequestDialog({required this.task, required this.appChoices});

  @override
  State<_ChangeRequestDialog> createState() => _ChangeRequestDialogState();
}

class _ChangeRequestDialogState extends State<_ChangeRequestDialog> {
  String _itemType = 'feature';
  String? _appId;
  final _reproduction = BugReproductionController();

  bool get _isBug => _itemType == 'bug';

  @override
  void initState() {
    super.initState();
    if (widget.appChoices.length == 1) _appId = widget.appChoices.first.id;
  }

  @override
  void dispose() {
    _reproduction.dispose();
    super.dispose();
  }

  void _submit() {
    if (_isBug && _reproduction.validate() != null) return;
    Navigator.of(context).pop(
      _ChangeRequestChoice(
        itemType: _itemType,
        appId: _appId!,
        reproduction: _isBug ? _reproduction.value : null,
      ),
    );
  }

  static InputDecoration _decoration({required String label, required String hint}) =>
      InputDecoration(
        labelText: label,
        hintText: hint,
        alignLabelWithHint: true,
      );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      icon: const BjIconWell(icon: Icons.rate_review_outlined, size: 52),
      title: const Text('Create change request', textAlign: TextAlign.center),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Files "${widget.task.title}" as an Improve Apps request, with its description '
                'and project context. Claude picks it up and opens a pull request; this task '
                'tracks its progress and completes automatically when the change is live.',
                style: text.bodyMedium?.copyWith(color: BjNeutral.inkMuted),
              ),
              const SizedBox(height: BjSpace.lg),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'feature', icon: Icon(Icons.lightbulb_outline), label: Text('Feature')),
                  ButtonSegment(value: 'bug', icon: Icon(Icons.bug_report_outlined), label: Text('Bug')),
                ],
                selected: {_itemType},
                onSelectionChanged: (selection) => setState(() => _itemType = selection.first),
              ),
              const SizedBox(height: BjSpace.lg),
              if (widget.appChoices.isEmpty)
                const BjInlineNote(
                  'No apps are linked to this project or installed in this group.',
                  icon: Icons.error_outline_rounded,
                  tone: BjTone.danger,
                )
              else
                DropdownButtonFormField<String>(
                  initialValue: _appId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'App',
                    prefixIcon: Icon(Icons.apps_rounded),
                  ),
                  items: widget.appChoices
                      .map(
                        (app) => DropdownMenuItem<String>(
                          value: app.id,
                          child: Text(app.name, overflow: TextOverflow.ellipsis),
                        ),
                      )
                      .toList(),
                  onChanged: (value) => setState(() => _appId = value),
                ),
              AnimatedSize(
                duration: BjMotion.medium,
                curve: BjMotion.curve,
                alignment: Alignment.topCenter,
                child: _isBug
                    ? Padding(
                        padding: const EdgeInsets.only(top: BjSpace.lg),
                        child: BugReproductionFields(controller: _reproduction, decoration: _decoration),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.end,
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _appId == null ? null : _submit,
          child: Text(_isBug ? 'File bug report' : 'File feature request'),
        ),
      ],
    );
  }
}

class _TaskFormResult {
  final String title;
  final String description;
  final BlockerStatus status;
  final int priority;
  final DateTime? dueDate;
  final String? parentTaskId;
  final List<TaskAttachment> attachments;

  const _TaskFormResult({
    required this.title,
    required this.description,
    required this.status,
    required this.priority,
    required this.dueDate,
    required this.parentTaskId,
    required this.attachments,
  });
}

/// The add / edit blocker task form, shown in a [showBjSheet]. Pops with the
/// entered values; the screen does the write. Public so tests can pump it.
class TaskFormSheet extends StatefulWidget {
  final BlockerTaskRecord? task;
  final String? defaultParentTaskId;
  final List<BlockerTaskRecord> availableParents;
  final Set<String> Function(String, List<BlockerTaskRecord>) getDescendants;

  const TaskFormSheet({
    super.key,
    required this.task,
    required this.defaultParentTaskId,
    required this.availableParents,
    required this.getDescendants,
  });

  @override
  State<TaskFormSheet> createState() => _TaskFormSheetState();
}

class _TaskFormSheetState extends State<TaskFormSheet> {
  static const int _maxUploadBytes = 10 * 1024 * 1024;
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;

  late BlockerStatus _selectedStatus;
  late int _selectedPriority;
  DateTime? _selectedDate;
  String? _selectedParentId;
  late List<TaskAttachment> _attachments;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.task?.title ?? '');
    _descriptionController = TextEditingController(text: widget.task?.description ?? '');
    _selectedStatus = widget.task?.status ?? BlockerStatus.todo;
    _selectedPriority = widget.task?.priority ?? 3;
    _selectedDate = widget.task?.dueDate;
    _selectedParentId = widget.task?.parentTaskId ?? widget.defaultParentTaskId;
    final existingAttachments =
        widget.task?.attachments.where((item) => item.url.trim().isNotEmpty).toList() ??
        <TaskAttachment>[];
    _attachments = List<TaskAttachment>.from(existingAttachments);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _pickAndUploadFiles() async {
    final result = await FilePicker.platform.pickFiles(
      withData: true,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;

    setState(() => _uploading = true);

    final uploaded = <TaskAttachment>[];
    final skippedNames = <String>[];
    try {
      for (final file in result.files) {
        final bytes = file.bytes;
        if (bytes == null) continue;
        if (file.size > _maxUploadBytes) {
          skippedNames.add(file.name);
          continue;
        }
        final trimmedName = file.name.trim();
        final name = trimmedName.isEmpty ? 'attachment' : trimmedName;
        final contentType = file.extension == null || file.extension!.isEmpty
            ? 'application/octet-stream'
            : _contentTypeForExtension(file.extension!.toLowerCase());
        final ref = await _taskFileStorage.upload(
          name,
          bytes,
          contentType: contentType,
        );
        final url = await ref.getDownloadURL();
        uploaded.add(
          TaskAttachment(
            url: url,
            name: name,
            path: ref.fullPath,
            contentType: contentType,
            sizeBytes: file.size,
            uploadedAt: DateTime.now(),
          ),
        );
      }
      if (!mounted) return;
      setState(() {
        _attachments = [..._attachments, ...uploaded];
      });
      if (skippedNames.isNotEmpty) {
        BjSnack.info(context, 'Skipped ${skippedNames.length} file(s) over 10 MB.');
      }
    } catch (e) {
      if (mounted) {
        BjSnack.error(context, 'Upload failed: $e');
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  String _contentTypeForExtension(String extension) {
    switch (extension) {
      case 'pdf':
        return 'application/pdf';
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'txt':
        return 'text/plain';
      case 'csv':
        return 'text/csv';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xls':
        return 'application/vnd.ms-excel';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      default:
        return 'application/octet-stream';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.task != null;
    final forbiddenParentIds = widget.task != null
        ? widget.getDescendants(widget.task!.id, widget.availableParents)
        : <String>{};

    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _titleController,
            autofocus: true,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'Task title'),
            validator: (value) => value == null || value.trim().isEmpty ? 'Task title is required' : null,
          ),
          const SizedBox(height: BjSpace.md),
          TextFormField(
            controller: _descriptionController,
            minLines: 3,
            maxLines: 5,
            decoration: const InputDecoration(labelText: 'Details', alignLabelWithHint: true),
          ),
          const SizedBox(height: BjSpace.xl),
          const BjFieldLabel('Status', icon: Icons.flag_circle_outlined),
          Wrap(
            spacing: BjSpace.sm,
            runSpacing: BjSpace.sm,
            children: [
              for (final status in BlockerStatus.values)
                StatusChoiceChip(
                  style: blockerStatusStyle(status),
                  selected: _selectedStatus == status,
                  onSelected: () => setState(() => _selectedStatus = status),
                ),
            ],
          ),
          const SizedBox(height: BjSpace.lg),
          const BjFieldLabel('Priority', icon: Icons.flag_outlined, helper: 'P1 is the most urgent.'),
          Wrap(
            spacing: BjSpace.sm,
            runSpacing: BjSpace.sm,
            children: [
              for (final priority in const [1, 2, 3, 4, 5])
                ChoiceChip(
                  showCheckmark: false,
                  label: Text('P$priority'),
                  selected: _selectedPriority == priority,
                  onSelected: (_) => setState(() => _selectedPriority = priority),
                ),
            ],
          ),
          const SizedBox(height: BjSpace.xl),
          DropdownButtonFormField<String?>(
            initialValue: _selectedParentId,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Blocked by task (optional)',
              prefixIcon: Icon(Icons.account_tree_outlined),
            ),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('None')),
              ...widget.availableParents
                  .where((parent) => parent.id != widget.task?.id && !forbiddenParentIds.contains(parent.id))
                  .map(
                    (parent) => DropdownMenuItem<String?>(
                      value: parent.id,
                      child: Text(parent.title, overflow: TextOverflow.ellipsis),
                    ),
                  ),
            ],
            onChanged: (value) => setState(() => _selectedParentId = value),
          ),
          const SizedBox(height: BjSpace.lg),
          const BjFieldLabel('Due date', icon: Icons.event_outlined),
          BjDateField(value: _selectedDate, emptyLabel: 'No due date selected', onChanged: (date) => setState(() => _selectedDate = date)),
          const SizedBox(height: BjSpace.xl),
          Row(
            children: [
              const Expanded(child: BjFieldLabel('Files', icon: Icons.attach_file_rounded, helper: 'Up to 10 MB each.')),
              OutlinedButton.icon(
                onPressed: _uploading ? null : _pickAndUploadFiles,
                icon: const Icon(Icons.upload_file_rounded, size: 18),
                label: Text(_uploading ? 'Uploading…' : 'Add files'),
              ),
            ],
          ),
          if (_attachments.isEmpty)
            const BjInlineNote('No files attached yet.', icon: Icons.insert_drive_file_outlined)
          else
            for (final entry in _attachments.asMap().entries)
              Padding(
                padding: const EdgeInsets.only(bottom: BjSpace.sm),
                child: BjListRow(
                  dense: true,
                  leading: const BjIconWell(icon: Icons.insert_drive_file_outlined, size: 32),
                  title: entry.value.name.isEmpty ? 'Attachment' : entry.value.name,
                  subtitle: entry.value.sizeBytes == null ? null : _formatBytes(entry.value.sizeBytes),
                  trailing: IconButton(
                    tooltip: 'Remove file',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => setState(() => _attachments.removeAt(entry.key)),
                  ),
                ),
              ),
          if (_uploading)
            const Padding(
              padding: EdgeInsets.only(top: BjSpace.sm),
              child: BjSkeleton(height: 48, radius: BjRadius.lg, width: double.infinity),
            ),
          BjSheetActions(
            onCancel: () => Navigator.of(context).pop(),
            primaryLabel: isEditing ? 'Save task' : 'Create task',
            onPrimary: _uploading
                ? null
                : () {
                    if (!_formKey.currentState!.validate()) return;
                    Navigator.of(context).pop(
                      _TaskFormResult(
                        title: _titleController.text.trim(),
                        description: _descriptionController.text.trim(),
                        status: _selectedStatus,
                        priority: _selectedPriority,
                        dueDate: _selectedDate,
                        parentTaskId: _selectedParentId,
                        attachments: _attachments,
                      ),
                    );
                  },
          ),
        ],
      ),
    );
  }

  String _formatBytes(int? bytes) {
    if (bytes == null || bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
