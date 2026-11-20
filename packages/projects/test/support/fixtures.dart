import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:projects/models.dart';
import 'package:projects/project_links.dart';
import 'package:projects/project_widgets.dart';

ProjectRecord project(
  String id,
  String title, {
  ProjectStatus status = ProjectStatus.active,
  String goal = '',
  String description = '',
  DateTime? due,
  List<String> tags = const [],
  List<String> apps = const [],
  List<String> clients = const [],
  Map<String, String> clientNames = const {},
}) =>
    ProjectRecord(
      id: id,
      title: title,
      description: description,
      goal: goal,
      status: status,
      dueDate: due,
      createdAt: null,
      updatedAt: null,
      ownerId: 'u1',
      memberIds: const ['u1'],
      tags: tags,
      relatedAppIds: apps,
      clientGroupIds: clients,
      clientGroupNames: clientNames,
    );

BlockerTaskRecord task(
  String id,
  String title, {
  String? parent,
  BlockerStatus status = BlockerStatus.todo,
  int priority = 3,
  String description = '',
  DateTime? due,
  List<TaskAttachment> attachments = const [],
  Map<String, dynamic>? changeRequest,
  String? changeRequestState,
  String? prUrl,
  String? prState,
}) =>
    BlockerTaskRecord.fromMap(id, {
      'projectId': 'p1',
      'title': title,
      'description': description,
      'parentTaskId': parent,
      'status': blockerStatusToString(status),
      'priority': priority,
      'changeRequest': changeRequest,
      'changeRequestState': changeRequestState,
      'prUrl': prUrl,
      'prState': prState,
    }).copyWithForTest(due: due, attachments: attachments);

extension on BlockerTaskRecord {
  BlockerTaskRecord copyWithForTest({DateTime? due, List<TaskAttachment> attachments = const []}) => BlockerTaskRecord(
        id: id,
        projectId: projectId,
        title: title,
        description: description,
        parentTaskId: parentTaskId,
        status: status,
        priority: priority,
        dueDate: due,
        createdAt: null,
        updatedAt: null,
        attachments: attachments,
        changeRequest: changeRequest,
        changeRequestState: changeRequestState,
        prUrl: prUrl,
        prState: prState,
      );
}

const sampleApps = [
  ProjectAppOption(id: 'rented-dwelling', name: 'Rented Dwelling', installed: true),
  ProjectAppOption(id: 'quotes', name: 'Quotes', installed: true),
];

final sampleTags = [
  const ProjectTagRecord(id: 't1', key: 'launch', label: 'launch'),
  const ProjectTagRecord(id: 't2', key: 'underwriting', label: 'underwriting'),
  const ProjectTagRecord(id: 't3', key: 'urgent', label: 'urgent'),
];

final sampleProjects = [
  project('p1', 'Rented dwelling launch',
      goal: 'Sell rented-dwelling policies online by December',
      description: 'Quote, bind and issue landlord policies without a broker call. Covers rating, forms and payments.',
      due: DateTime(2026, 12, 15),
      tags: ['launch', 'underwriting'],
      apps: ['rented-dwelling', 'quotes'],
      clients: ['globex'],
      clientNames: {'globex': 'Globex'}),
  project('p2', 'Broker portal SSO',
      status: ProjectStatus.onHold,
      goal: 'Brokers sign in with their agency accounts',
      description: 'Waiting on the identity provider certificate.',
      due: DateTime(2026, 11, 2),
      tags: ['urgent']),
  project('p3', 'Claims intake form', status: ProjectStatus.completed, goal: 'Digital first notice of loss', due: DateTime(2026, 9, 30)),
  project('p4', 'Renewal reminders', status: ProjectStatus.planned, goal: 'Email customers 30 days before renewal'),
];

final sampleTasks = [
  task('t1', 'Rating engine signs off on landlord rates', priority: 1, due: DateTime(2026, 11, 20),
      description: 'Underwriting needs the final rate table before forms can be filed.'),
  task('t2', 'Collect rate table from actuarial', parent: 't1', priority: 2, status: BlockerStatus.inProgress,
      changeRequest: {'itemType': 'feature', 'itemId': 'f1'}, changeRequestState: 'in_review',
      prUrl: 'https://github.com/bluejayorg/bluejay/pull/3012', prState: 'open'),
  task('t3', 'Confirm territory factors', parent: 't1', priority: 3, status: BlockerStatus.done),
  task('t4', 'Payment provider contract', priority: 2, due: DateTime(2026, 11, 1),
      attachments: const [
        TaskAttachment(url: 'https://firebasestorage.googleapis.com/v0/b/x/o/contract.pdf', name: 'contract.pdf'),
        TaskAttachment(url: 'https://example.com/notes.txt', name: 'notes.txt'),
      ]),
  task('t5', 'Policy wording reviewed by legal', priority: 4, status: BlockerStatus.done),
  task('t6', 'Fix broken address lookup on step 2', parent: 't4', priority: 3,
      changeRequest: {'itemType': 'bug', 'itemId': 'b1'}),
];

/// The dashboard body with in-memory filter state, inside a [BjPage].
class DashboardHarness extends StatefulWidget {
  final List<ProjectRecord> projects;

  const DashboardHarness({super.key, required this.projects});

  @override
  State<DashboardHarness> createState() => _DashboardHarnessState();
}

class _DashboardHarnessState extends State<DashboardHarness> {
  ProjectStatus? _status;
  final Set<String> _tags = {};

  @override
  Widget build(BuildContext context) {
    final nextById = {
      'p1': sampleTasks.first,
      'p2': task('x', 'Chase the identity provider for the signing certificate', priority: 1),
    };
    return BjPage(
      title: 'Projects',
      subtitle: 'Sunnyside Insurance',
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {},
        icon: const Icon(Icons.add_rounded),
        label: const Text('New project'),
      ),
      body: ProjectsDashboardBody(
        projects: widget.projects,
        groupTags: sampleTags,
        statusFilter: _status,
        tagFilters: _tags,
        onStatusChanged: (s) => setState(() => _status = s),
        onTagToggled: (k, sel) => setState(() => sel ? _tags.add(k) : _tags.remove(k)),
        onClearTags: () => setState(_tags.clear),
        onClearFilters: () => setState(() {
          _status = null;
          _tags.clear();
        }),
        canCreate: true,
        onCreate: () {},
        cardBuilder: (p) => ProjectCard(
          project: p,
          apps: sampleApps,
          nextAction: Future.value(nextById[p.id]),
          onTap: () {},
          actions: [
            BjMenuAction(label: 'Edit project', icon: Icons.edit_outlined, onSelected: () {}),
            BjMenuAction(label: 'Delete project', icon: Icons.delete_outline_rounded, destructive: true, onSelected: () {}),
          ],
        ),
      ),
    );
  }
}

/// The detail body with in-memory "hide completed", inside a [BjPage].
class DetailHarness extends StatefulWidget {
  final List<BlockerTaskRecord> tasks;

  const DetailHarness({super.key, required this.tasks});

  @override
  State<DetailHarness> createState() => _DetailHarnessState();
}

class _DetailHarnessState extends State<DetailHarness> {
  bool _hide = false;

  @override
  Widget build(BuildContext context) {
    return BjPage(
      title: sampleProjects.first.title,
      subtitle: 'Sunnyside Insurance',
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {},
        icon: const Icon(Icons.add_task_rounded),
        label: const Text('Add blocker'),
      ),
      body: ProjectDetailBody(
        project: sampleProjects.first,
        tasks: widget.tasks,
        apps: sampleApps,
        hideCompleted: _hide,
        onHideCompletedChanged: (v) => setState(() => _hide = v),
        onAddTask: () {},
        taskBuilder: (t, open) => BlockerTaskCard(
          task: t,
          openChildCount: open,
          onToggleDone: () {},
          requestStatus: buildTaskRequestStatus(t, filing: false, showLegacyAgentStatus: false),
          actions: [
            BjMenuAction(label: 'Edit', icon: Icons.edit_outlined, onSelected: () {}),
            BjMenuAction(label: 'Delete', icon: Icons.delete_outline_rounded, destructive: true, onSelected: () {}),
          ],
        ),
      ),
    );
  }
}

Widget themed(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: BluejayTheme.build(),
      home: child,
    );
