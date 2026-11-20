/// Presentational pieces of the Projects screens. They take plain records
/// and callbacks and never touch Firestore, so they can be pumped in tests
/// with fake data. The screens own the streams, reads and writes.
library;

import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:projects/models.dart';
import 'package:projects/project_links.dart';
import 'package:projects/project_styles.dart';
import 'package:shared_ui/clickable_url.dart';
import 'package:shared_ui/fullscreen_image_viewer.dart';
import 'package:url_launcher/url_launcher.dart';

// ---------------------------------------------------------------------------
// Form pieces
// ---------------------------------------------------------------------------

/// A [ChoiceChip] for a [StatusStyle], with its icon in the status tone.
class StatusChoiceChip extends StatelessWidget {
  final StatusStyle style;
  final bool selected;
  final VoidCallback onSelected;
  final String? label;

  const StatusChoiceChip({super.key, required this.style, required this.selected, required this.onSelected, this.label});

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      avatar: Icon(style.icon, size: 18, color: context.bj.tone(style.tone).foreground),
      showCheckmark: false,
      label: Text(label ?? style.label),
      selected: selected,
      onSelected: (_) => onSelected(),
    );
  }
}

// ---------------------------------------------------------------------------
// Dashboard
// ---------------------------------------------------------------------------

/// First-load placeholder for the dashboard: filter card plus project rows.
class ProjectsDashboardSkeleton extends StatelessWidget {
  const ProjectsDashboardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return BjScrollPad(
      child: Column(
        children: [
          BjCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: BjSpace.sm, runSpacing: BjSpace.sm, children: [
                for (final w in const [56.0, 72.0, 64.0, 80.0, 72.0])
                  BjSkeleton(width: w, height: 28, radius: BjRadius.pill),
              ]),
              const SizedBox(height: BjSpace.md),
              Wrap(spacing: BjSpace.sm, runSpacing: BjSpace.sm, children: [
                for (final w in const [72.0, 64.0, 56.0])
                  BjSkeleton(width: w, height: 28, radius: BjRadius.pill),
              ]),
            ]),
          ),
          const SizedBox(height: BjSpace.lg),
          const BjSkeletonList(count: 4, shrinkWrap: true),
        ],
      ),
    );
  }
}

/// Status and tag filters, with a count on each status.
class ProjectFilterPanel extends StatelessWidget {
  final ProjectStatus? statusFilter;
  final Map<ProjectStatus, int> statusCounts;
  final int totalCount;
  final List<String> availableTags;
  final Set<String> tagFilters;
  final ValueChanged<ProjectStatus?> onStatusChanged;
  final void Function(String tagKey, bool selected) onTagToggled;
  final VoidCallback onClearTags;

  const ProjectFilterPanel({
    super.key,
    required this.statusFilter,
    required this.statusCounts,
    required this.totalCount,
    required this.availableTags,
    required this.tagFilters,
    required this.onStatusChanged,
    required this.onTagToggled,
    required this.onClearTags,
  });

  @override
  Widget build(BuildContext context) {
    return BjCard(
      padding: const EdgeInsets.fromLTRB(BjSpace.lg, BjSpace.md, BjSpace.lg, BjSpace.md),
      child: BjFilterBar(groups: [
        BjFilterGroup(
          label: 'Status',
          icon: Icons.flag_outlined,
          filters: [
            ChoiceChip(
              showCheckmark: false,
              label: Text('All · $totalCount'),
              selected: statusFilter == null,
              onSelected: (_) => onStatusChanged(null),
            ),
            for (final status in ProjectStatus.values)
              StatusChoiceChip(
                style: projectStatusStyle(status),
                label: '${projectStatusStyle(status).label} · ${statusCounts[status] ?? 0}',
                selected: statusFilter == status,
                onSelected: () => onStatusChanged(status),
              ),
          ],
        ),
        BjFilterGroup(
          label: 'Tags',
          icon: Icons.sell_outlined,
          placeholder: const BjInlineNote('No tags yet. Add tags to projects to filter them here.', icon: Icons.sell_outlined),
          filters: [
            if (availableTags.isNotEmpty)
              FilterChip(
                label: const Text('Any tag'),
                selected: tagFilters.isEmpty,
                onSelected: (_) => onClearTags(),
              ),
            for (final tag in availableTags)
              FilterChip(
                label: Text(tag),
                selected: tagFilters.contains(projectTagKey(tag)),
                onSelected: (selected) => onTagToggled(projectTagKey(tag), selected),
              ),
          ],
        ),
      ]),
    );
  }
}

/// One project on the dashboard: status, goal, description, tags, linked
/// apps and client groups, due date, and its next actionable blocker.
class ProjectCard extends StatelessWidget {
  final ProjectRecord project;
  final List<ProjectAppOption> apps;
  final Future<BlockerTaskRecord?> nextAction;
  final VoidCallback onTap;
  final List<BjMenuAction> actions;

  const ProjectCard({
    super.key,
    required this.project,
    required this.apps,
    required this.nextAction,
    required this.onTap,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final style = projectStatusStyle(project.status);
    final done = project.status == ProjectStatus.completed;
    return BjCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(BjSpace.lg, BjSpace.lg, BjSpace.sm, BjSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            BjIconWell(icon: style.icon, tone: style.tone, size: 40),
            const SizedBox(width: BjSpace.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(project.title, style: text.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                if (project.goal.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(project.goal,
                        style: text.bodyMedium?.copyWith(color: BjNeutral.ink, fontWeight: FontWeight.w500)),
                  ),
              ]),
            ),
            if (actions.isNotEmpty) BjOverflowMenu(actions: actions, tooltip: 'Project actions') else const SizedBox(width: BjSpace.sm),
          ]),
          Padding(
            padding: const EdgeInsets.only(right: BjSpace.sm),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (project.description.isNotEmpty) ...[
                const SizedBox(height: BjSpace.sm),
                Text(project.description, style: text.bodySmall, maxLines: 4, overflow: TextOverflow.ellipsis),
              ],
              const SizedBox(height: BjSpace.md),
              Wrap(
                spacing: BjSpace.xs + 2,
                runSpacing: BjSpace.xs + 2,
                children: [
                  StylePill(style),
                  BjDuePill(due: project.dueDate, done: done),
                  for (final tag in project.tags) BjStatusPill(label: tag, icon: Icons.sell_outlined, tone: BjTone.accent),
                  ...ProjectLinkChips.pills(project, apps),
                ],
              ),
            ]),
          ),
          const Spacer(),
          const SizedBox(height: BjSpace.md),
          Padding(
            padding: const EdgeInsets.only(right: BjSpace.sm),
            child: NextActionStrip(nextAction: nextAction),
          ),
        ],
      ),
    );
  }
}

/// "Next action: …" under a project card. Shows a placeholder line while the
/// project's tasks load.
class NextActionStrip extends StatelessWidget {
  final Future<BlockerTaskRecord?> nextAction;

  const NextActionStrip({super.key, required this.nextAction});

  @override
  Widget build(BuildContext context) {
    final bj = context.bj;
    final text = Theme.of(context).textTheme;
    return FutureBuilder<BlockerTaskRecord?>(
      future: nextAction,
      builder: (context, snap) {
        final loading = snap.connectionState == ConnectionState.waiting && !snap.hasData;
        final task = snap.data;
        final has = task != null;
        return AnimatedContainer(
          duration: BjMotion.medium,
          curve: BjMotion.curve,
          padding: const EdgeInsets.symmetric(horizontal: BjSpace.md, vertical: BjSpace.sm + 2),
          decoration: BoxDecoration(
            color: has ? bj.accentWash : BjNeutral.surfaceMuted,
            borderRadius: BjRadius.all(BjRadius.md),
            border: Border.all(color: has ? bj.accentSoft : BjNeutral.surfaceMuted),
          ),
          child: Row(children: [
            Icon(has ? Icons.play_circle_fill_rounded : Icons.play_circle_outline_rounded,
                size: 20, color: has ? bj.accent : BjNeutral.inkSubtle),
            const SizedBox(width: BjSpace.sm),
            Expanded(
              child: loading
                  ? const Align(alignment: Alignment.centerLeft, child: BjSkeleton(width: 180, height: 12))
                  : has
                      ? Text.rich(
                          TextSpan(children: [
                            TextSpan(text: 'Next action  ', style: text.labelSmall?.copyWith(color: bj.accent)),
                            TextSpan(text: task.title, style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: BjNeutral.ink)),
                          ]),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        )
                      : Text('No actionable blocker right now.', style: text.bodySmall),
            ),
            if (has) BjStatusPill(label: 'P${task.priority}', tone: priorityTone(task.priority)),
          ]),
        );
      },
    );
  }
}

/// Filters and sorts projects the way the dashboard always has: every
/// selected tag must match, open projects first, then by due date, then by
/// title.
List<ProjectRecord> filterAndSortProjects(
  List<ProjectRecord> projects, {
  ProjectStatus? status,
  Set<String> tagKeys = const {},
}) {
  var result = projects.toList();
  if (status != null) {
    result = result.where((p) => p.status == status).toList();
  }
  if (tagKeys.isNotEmpty) {
    result = result.where((project) {
      final projectTagKeys = project.tags.map(projectTagKey).toSet();
      return tagKeys.every(projectTagKeys.contains);
    }).toList();
  }
  result.sort((a, b) {
    final aCompleted = a.status == ProjectStatus.completed ? 1 : 0;
    final bCompleted = b.status == ProjectStatus.completed ? 1 : 0;
    final statusCompare = aCompleted.compareTo(bCompleted);
    if (statusCompare != 0) return statusCompare;
    final aDate = a.dueDate;
    final bDate = b.dueDate;
    if (aDate == null && bDate == null) return a.title.compareTo(b.title);
    if (aDate == null) return 1;
    if (bDate == null) return -1;
    return aDate.compareTo(bDate);
  });
  return result;
}

/// The group's tags plus any tag used on a project, one label per key,
/// sorted by key.
List<String> availableProjectTags(List<ProjectTagRecord> groupTags, List<ProjectRecord> projects) {
  final byKey = <String, String>{for (final tag in groupTags) tag.key: tag.label};
  for (final project in projects) {
    for (final tag in project.tags) {
      byKey.putIfAbsent(projectTagKey(tag), () => tag);
    }
  }
  return byKey.values.toList()..sort((a, b) => projectTagKey(a).compareTo(projectTagKey(b)));
}

/// The loaded dashboard: filters, a count header and the project cards (two
/// columns on wide screens), or an empty state.
class ProjectsDashboardBody extends StatelessWidget {
  final List<ProjectRecord> projects;
  final List<ProjectTagRecord> groupTags;
  final ProjectStatus? statusFilter;
  final Set<String> tagFilters;
  final ValueChanged<ProjectStatus?> onStatusChanged;
  final void Function(String tagKey, bool selected) onTagToggled;
  final VoidCallback onClearTags;
  final VoidCallback onClearFilters;
  final bool canCreate;
  final VoidCallback onCreate;
  final Widget Function(ProjectRecord project) cardBuilder;

  const ProjectsDashboardBody({
    super.key,
    required this.projects,
    required this.groupTags,
    required this.statusFilter,
    required this.tagFilters,
    required this.onStatusChanged,
    required this.onTagToggled,
    required this.onClearTags,
    required this.onClearFilters,
    required this.canCreate,
    required this.onCreate,
    required this.cardBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final tags = availableProjectTags(groupTags, projects);
    final visible = filterAndSortProjects(projects, status: statusFilter, tagKeys: tagFilters);
    final counts = <ProjectStatus, int>{};
    for (final p in projects) {
      counts[p.status] = (counts[p.status] ?? 0) + 1;
    }
    final filtered = statusFilter != null || tagFilters.isNotEmpty;

    final Widget? empty = visible.isNotEmpty
        ? null
        : BjCard(
            child: projects.isEmpty
                ? BjStateView.empty(
                    compact: true,
                    icon: Icons.hub_outlined,
                    title: 'No projects yet',
                    message: 'Create your first project and define blockers to reveal your next best action.',
                    action: FilledButton.icon(
                      onPressed: canCreate ? onCreate : null,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Create project'),
                    ),
                  )
                : BjStateView.empty(
                    compact: true,
                    icon: Icons.filter_alt_off_outlined,
                    title: 'No projects match these filters',
                    message: '${projects.length} ${projects.length == 1 ? 'project is' : 'projects are'} hidden by the status or tag filters.',
                    action: OutlinedButton.icon(
                      onPressed: onClearFilters,
                      icon: const Icon(Icons.filter_alt_off_rounded, size: 18),
                      label: const Text('Clear filters'),
                    ),
                  ),
          );

    return BjScrollBody(
      spacing: BjSpace.md,
      children: [
        ProjectFilterPanel(
          statusFilter: statusFilter,
          statusCounts: counts,
          totalCount: projects.length,
          availableTags: tags,
          tagFilters: tagFilters,
          onStatusChanged: onStatusChanged,
          onTagToggled: onTagToggled,
          onClearTags: onClearTags,
        ),
        Padding(
          padding: const EdgeInsets.only(top: BjSpace.xs),
          child: BjSectionHeader(
            title: statusFilter == null ? 'All projects' : '${projectStatusStyle(statusFilter!).label} projects',
            count: visible.length,
            subtitle: 'Open projects first, then by due date',
            trailing: filtered
                ? TextButton.icon(
                    onPressed: onClearFilters,
                    icon: const Icon(Icons.filter_alt_off_rounded, size: 18),
                    label: const Text('Clear filters'),
                  )
                : null,
          ),
        ),
        if (empty != null)
          empty
        else
          // Two columns from the expanded breakpoint up.
          ...BjResponsiveGrid.rows(
            context,
            [for (final p in visible) cardBuilder(p)],
            minTileWidth: 420,
            maxColumns: 2,
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Project detail
// ---------------------------------------------------------------------------

/// First-load placeholder for the detail screen.
class ProjectDetailSkeleton extends StatelessWidget {
  const ProjectDetailSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return const BjScrollPad(
      child: Column(children: [
        BjSkeleton(height: 168, radius: BjRadius.xl, width: double.infinity),
        SizedBox(height: BjSpace.lg),
        BjSkeletonList(count: 3, shrinkWrap: true),
      ]),
    );
  }
}

/// The project's headline: goal, description, progress, status, due date,
/// tags and links, on the accent gradient.
class ProjectSummaryHero extends StatelessWidget {
  final ProjectRecord project;
  final List<ProjectAppOption> apps;
  final int doneCount;
  final int totalCount;

  const ProjectSummaryHero({
    super.key,
    required this.project,
    required this.apps,
    required this.doneCount,
    required this.totalCount,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final progress = totalCount == 0 ? 0.0 : doneCount / totalCount;
    final onHero = text.bodySmall?.copyWith(color: Colors.white.withValues(alpha: 0.92));
    return BjHeroCard(
      // Goals are often a full sentence; keep them to two lines on phones.
      compact: BjBreakpoint.isCompact(MediaQuery.sizeOf(context).width),
      icon: Icons.flag_rounded,
      title: project.goal.isEmpty ? 'No goal defined yet.' : project.goal,
      subtitle: project.description.isEmpty ? null : project.description,
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(child: BjProgressBar(value: progress, onDark: true, height: 10)),
            const SizedBox(width: BjSpace.md),
            Text('${(progress * 100).round()}%', style: text.titleSmall?.copyWith(color: Colors.white)),
          ]),
          const SizedBox(height: BjSpace.sm),
          Text('$doneCount of $totalCount blocker tasks completed', style: onHero),
          const SizedBox(height: BjSpace.md),
          Wrap(
            spacing: BjSpace.xs + 2,
            runSpacing: BjSpace.xs + 2,
            children: [
              StylePill(projectStatusStyle(project.status)),
              BjDuePill(due: project.dueDate, done: project.status == ProjectStatus.completed),
              for (final tag in project.tags) BjStatusPill(label: tag, icon: Icons.sell_outlined, tone: BjTone.accent),
              ...ProjectLinkChips.pills(project, apps),
            ],
          ),
        ],
      ),
    );
  }
}

/// Up to five tasks that can be worked on now (not done, nothing open
/// beneath them), most urgent first.
class NextTasksCard extends StatelessWidget {
  final List<BlockerTaskRecord> actionable;

  const NextTasksCard({super.key, required this.actionable});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final bj = context.bj;
    return BjCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BjSectionHeader(
            title: 'Actionable next tasks',
            icon: Icons.play_circle_outline_rounded,
            count: actionable.length,
          ),
          const SizedBox(height: BjSpace.sm),
          if (actionable.isEmpty)
            const BjInlineNote('No actionable tasks yet. Add blockers to start planning flow.', icon: Icons.lightbulb_outline_rounded)
          else ...[
            for (final (i, task) in actionable.take(5).indexed)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: BjSpace.sm, vertical: BjSpace.sm),
                decoration: BoxDecoration(
                  color: i == 0 ? bj.accentWash : null,
                  borderRadius: BjRadius.all(BjRadius.md),
                ),
                child: Row(children: [
                  Icon(i == 0 ? Icons.play_circle_fill_rounded : Icons.play_circle_outline_rounded,
                      size: 18, color: bj.accent),
                  const SizedBox(width: BjSpace.sm),
                  Expanded(
                    child: Text(task.title,
                        style: i == 0 ? text.bodyMedium?.copyWith(fontWeight: FontWeight.w600) : text.bodyMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: BjSpace.sm),
                  BjStatusPill(label: 'P${task.priority}', tone: priorityTone(task.priority)),
                ]),
              ),
            if (actionable.length > 5)
              Padding(
                padding: const EdgeInsets.only(top: BjSpace.xs, left: BjSpace.sm),
                child: Text('+${actionable.length - 5} more in the flow map', style: text.bodySmall),
              ),
          ],
        ],
      ),
    );
  }
}

/// Change-request state and pull-request link for a task; or, for tasks
/// sent straight to Claude before change requests existed, the legacy
/// dispatch status (only when [showLegacyAgentStatus]). Null when there's
/// nothing to show.
Widget? buildTaskRequestStatus(
  BlockerTaskRecord task, {
  required bool filing,
  required bool showLegacyAgentStatus,
}) {
  final state = task.displayChangeRequestState;
  if (state != null) {
    final style = changeRequestStateStyle(state);
    final pr = _pullRequestChip(task);
    return Wrap(
      spacing: BjSpace.sm,
      runSpacing: BjSpace.xs + 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Tooltip(
          message: task.changeRequest!.isBug ? 'Improve Apps bug report' : 'Improve Apps feature request',
          child: BjStatusPill(
            label: style.label,
            tone: style.tone,
            icon: task.changeRequest!.isBug ? Icons.bug_report_outlined : Icons.lightbulb_outline,
          ),
        ),
        if (pr != null) pr,
      ],
    );
  }
  if (filing) {
    return const _StatusNote('Filing change request…', icon: Icons.hourglass_top_rounded);
  }
  if (!showLegacyAgentStatus) return null;
  final pr = _pullRequestChip(task);
  if (pr != null) return pr;
  if (task.hasDispatchError) {
    return _StatusNote('Claude dispatch failed: ${task.agentDispatchError}',
        icon: Icons.error_outline_rounded, tone: BjTone.danger);
  }
  if (task.agentDispatchedAt != null) {
    return _StatusNote('Claude opened a pull request on ${bjFormatDate(task.agentDispatchedAt!)}',
        icon: Icons.smart_toy_outlined);
  }
  if (task.agentQueuedAt != null) {
    return _StatusNote('Queued for Claude ${bjFormatDate(task.agentQueuedAt!)}, waiting for a pull request',
        icon: Icons.smart_toy_outlined);
  }
  return null;
}

Widget? _pullRequestChip(BlockerTaskRecord task) {
  final uri = task.pullRequestUri;
  if (uri == null) return null;
  return ActionChip(
    avatar: const Icon(Icons.merge_type_rounded, size: 16),
    label: Text(
      task.prState == 'merged' ? 'View merged PR' : (task.prState == 'closed' ? 'View closed PR' : 'View pull request'),
    ),
    tooltip: uri.toString(),
    visualDensity: VisualDensity.compact,
    onPressed: () => launchUrl(uri, mode: LaunchMode.externalApplication),
  );
}

class _StatusNote extends StatelessWidget {
  final String text;
  final IconData icon;
  final BjTone? tone;

  const _StatusNote(this.text, {required this.icon, this.tone});

  @override
  Widget build(BuildContext context) {
    final color = tone == null ? BjNeutral.inkMuted : context.bj.tone(tone!).foreground;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 15, color: color)),
      const SizedBox(width: BjSpace.xs + 2),
      Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color))),
    ]);
  }
}

/// One blocker task: done checkbox, title, details, status/priority/due
/// pills, request status, attachments and an overflow menu.
class BlockerTaskCard extends StatelessWidget {
  final BlockerTaskRecord task;

  /// Null disables the checkbox.
  final VoidCallback? onToggleDone;
  final List<BjMenuAction> actions;
  final Widget? requestStatus;

  /// Open blockers nested beneath this task.
  final int openChildCount;

  const BlockerTaskCard({
    super.key,
    required this.task,
    required this.onToggleDone,
    this.actions = const [],
    this.requestStatus,
    this.openChildCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final done = task.isDone;
    return BjCard(
      padding: const EdgeInsets.fromLTRB(BjSpace.xs, BjSpace.xs, BjSpace.xs, BjSpace.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            value: done,
            onChanged: onToggleDone == null ? null : (_) => onToggleDone!(),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: BjSpace.sm + 3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.title,
                    style: text.titleSmall?.copyWith(
                      decoration: done ? TextDecoration.lineThrough : null,
                      color: done ? BjNeutral.inkSubtle : null,
                    ),
                  ),
                  if (task.description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(task.description, style: text.bodySmall),
                    ),
                  const SizedBox(height: BjSpace.sm),
                  Wrap(
                    spacing: BjSpace.xs + 2,
                    runSpacing: BjSpace.xs + 2,
                    children: [
                      StylePill(blockerStatusStyle(task.status)),
                      Tooltip(
                        message: 'Priority ${task.priority}',
                        child: BjStatusPill(
                            label: 'P${task.priority}', icon: Icons.flag_outlined, tone: priorityTone(task.priority)),
                      ),
                      BjDuePill(due: task.dueDate, done: done, emptyLabel: 'No date'),
                      if (openChildCount > 0)
                        BjStatusPill(
                          label: '$openChildCount open ${openChildCount == 1 ? 'blocker' : 'blockers'}',
                          icon: Icons.account_tree_outlined,
                          tone: BjTone.warning,
                        ),
                    ],
                  ),
                  if (requestStatus != null) ...[
                    const SizedBox(height: BjSpace.sm),
                    requestStatus!,
                  ],
                  if (task.attachments.isNotEmpty) ...[
                    const SizedBox(height: BjSpace.md),
                    TaskAttachmentsView(attachments: task.attachments),
                  ],
                ],
              ),
            ),
          ),
          if (actions.isNotEmpty) BjOverflowMenu(actions: actions, tooltip: 'Task actions') else const SizedBox(width: BjSpace.md),
        ],
      ),
    );
  }
}

const Set<String> _imageExtensions = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.heic', '.heif'};
const Set<String> _trustedAttachmentHosts = {'firebasestorage.googleapis.com', 'storage.googleapis.com'};

bool _looksLikeImagePath(String value) {
  final withoutQuery = value.split('?').first.toLowerCase();
  return _imageExtensions.any(withoutQuery.endsWith);
}

/// Whether an attachment renders as an image (by content type, name or URL).
bool isImageAttachment(TaskAttachment attachment) {
  final contentType = (attachment.contentType ?? '').toLowerCase();
  if (contentType.startsWith('image/')) return true;
  if (_looksLikeImagePath(attachment.name.toLowerCase())) return true;
  return _looksLikeImagePath(attachment.url.toLowerCase());
}

/// Only https links on Firebase/Cloud Storage are shown; task docs are
/// group-writable, so anything else is hidden.
bool isDisplayableAttachmentUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || uri.host.isEmpty) return false;
  if (uri.scheme != 'https') return false;
  return _trustedAttachmentHosts.contains(uri.host.toLowerCase());
}

/// A task's attachments: images in a swipeable strip (tap for full screen),
/// other files as chips that show their link.
class TaskAttachmentsView extends StatelessWidget {
  final List<TaskAttachment> attachments;

  const TaskAttachmentsView({super.key, required this.attachments});

  Future<void> _showLink(BuildContext context, TaskAttachment attachment) {
    return showBjSheet<void>(
      context,
      title: attachment.name.isEmpty ? 'Attachment' : attachment.name,
      subtitle: 'Tip: tap the link to open.',
      builder: (context) => buildClickableText(
        context,
        attachment.url,
        defaultStyle: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final safe = attachments.where((a) => isDisplayableAttachmentUrl(a.url)).toList();
    final images = safe.where(isImageAttachment).toList();
    final files = safe.where((a) => !isImageAttachment(a)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (safe.length != attachments.length)
          const Padding(
            padding: EdgeInsets.only(bottom: BjSpace.sm),
            child: _StatusNote('Some attachments are hidden because they are not from trusted https sources.',
                icon: Icons.shield_outlined),
          ),
        if (images.isNotEmpty) ...[
          TaskImageCarousel(attachments: images),
          if (files.isNotEmpty) const SizedBox(height: BjSpace.sm),
        ],
        if (files.isNotEmpty)
          Wrap(
            spacing: BjSpace.sm,
            runSpacing: BjSpace.xs + 2,
            children: [
              for (final attachment in files)
                ActionChip(
                  avatar: const Icon(Icons.attach_file_rounded, size: 16),
                  label: Text(attachment.name.isEmpty ? 'Attachment' : attachment.name, overflow: TextOverflow.ellipsis),
                  tooltip: attachment.url,
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _showLink(context, attachment),
                ),
            ],
          ),
      ],
    );
  }
}

/// Image attachments in a 160-high swipeable strip with page dots. Tapping
/// opens the shared full-screen viewer.
class TaskImageCarousel extends StatefulWidget {
  final List<TaskAttachment> attachments;

  const TaskImageCarousel({super.key, required this.attachments});

  @override
  State<TaskImageCarousel> createState() => _TaskImageCarouselState();
}

class _TaskImageCarouselState extends State<TaskImageCarousel> {
  int _currentPage = 0;
  final PageController _pageController = PageController();

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _open(int index) {
    showFullscreenImages(
      context,
      images: [
        for (final a in widget.attachments) FullscreenImage(url: a.url, label: a.name),
      ],
      initialIndex: index,
    );
  }

  Widget _image(TaskAttachment attachment, int index) {
    return ClipRRect(
      borderRadius: BjRadius.all(BjRadius.md),
      child: Material(
        color: BjNeutral.surfaceMuted,
        child: InkWell(
          onTap: () => _open(index),
          child: Image.network(
            attachment.url,
            fit: BoxFit.cover,
            width: double.infinity,
            semanticLabel: attachment.name.isEmpty ? 'Task attachment image' : attachment.name,
            loadingBuilder: (context, child, progress) =>
                progress == null ? child : const BjSkeleton(height: 160, radius: BjRadius.md),
            errorBuilder: (_, __, ___) => const Center(
              child: Icon(Icons.broken_image_rounded, color: BjNeutral.inkSubtle),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.attachments.length == 1) {
      return SizedBox(height: 160, child: _image(widget.attachments.first, 0));
    }
    return Column(children: [
      SizedBox(
        height: 160,
        child: PageView.builder(
          controller: _pageController,
          itemCount: widget.attachments.length,
          onPageChanged: (index) => setState(() => _currentPage = index),
          itemBuilder: (_, index) => _image(widget.attachments[index], index),
        ),
      ),
      ImagePageDots(
        count: widget.attachments.length,
        current: _currentPage,
        activeColor: context.bj.accent,
        inactiveColor: BjNeutral.borderStrong,
        onTap: (index) => _pageController.animateToPage(index, duration: BjMotion.slow, curve: BjMotion.curve),
      ),
    ]);
  }
}

/// The blocker tree, derived from a project's tasks. Same rules the screen
/// has always used: with "hide completed" on, tasks whose parent is hidden
/// are promoted to the top level.
class BlockerTree {
  final List<BlockerTaskRecord> all;
  final List<BlockerTaskRecord> visible;
  final List<BlockerTaskRecord> topLevel;
  final List<BlockerTaskRecord> actionable;
  final int doneCount;

  BlockerTree._(this.all, this.visible, this.topLevel, this.actionable, this.doneCount);

  factory BlockerTree(List<BlockerTaskRecord> tasks, {required bool hideCompleted}) {
    final visible = hideCompleted ? tasks.where((task) => !task.isDone).toList() : tasks;
    final topLevel = <BlockerTaskRecord>[];
    if (hideCompleted) {
      final visibleIds = visible.map((task) => task.id).toSet();
      final byId = <String, BlockerTaskRecord>{};
      for (final task in visible) {
        final parentId = task.parentTaskId;
        final isRoot = parentId == null || parentId.isEmpty;
        if (isRoot || !visibleIds.contains(parentId)) byId[task.id] = task;
      }
      topLevel.addAll(byId.values);
    } else {
      topLevel.addAll(tasks.where((task) => task.parentTaskId == null || task.parentTaskId!.isEmpty));
    }
    topLevel.sort(compareBlockerTaskPriority);
    bool isActionable(BlockerTaskRecord task) =>
        !task.isDone && childrenOf(task.id, tasks).every((child) => child.isDone);
    final actionable = tasks.where(isActionable).toList()..sort(compareActionableBlockerTasks);
    return BlockerTree._(tasks, visible, topLevel, actionable, tasks.where((t) => t.isDone).length);
  }

  static List<BlockerTaskRecord> childrenOf(String taskId, List<BlockerTaskRecord> tasks) =>
      tasks.where((task) => task.parentTaskId == taskId).toList();
}

/// The loaded detail screen: summary hero, next tasks and the blocker flow
/// map. On wide screens the next tasks sit in a sidebar beside the map.
class ProjectDetailBody extends StatelessWidget {
  final ProjectRecord project;
  final List<BlockerTaskRecord> tasks;
  final List<ProjectAppOption> apps;
  final bool hideCompleted;
  final ValueChanged<bool> onHideCompletedChanged;

  /// Null hides the add buttons.
  final VoidCallback? onAddTask;
  final Widget Function(BlockerTaskRecord task, int openChildCount) taskBuilder;

  const ProjectDetailBody({
    super.key,
    required this.project,
    required this.tasks,
    required this.apps,
    required this.hideCompleted,
    required this.onHideCompletedChanged,
    required this.onAddTask,
    required this.taskBuilder,
  });

  Widget _node(BlockerTaskRecord task, BlockerTree tree, Set<String> visited) {
    // Guard against cycles in existing data.
    if (!visited.add(task.id)) return const SizedBox.shrink();
    final children = BlockerTree.childrenOf(task.id, tree.visible)..sort(compareBlockerTaskPriority);
    final openChildren = BlockerTree.childrenOf(task.id, tree.all).where((c) => !c.isDone).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        taskBuilder(task, openChildren),
        if (children.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: BjSpace.lg, top: BjSpace.sm),
            child: _TreeRail(
              children: [for (final child in children) _node(child, tree, visited)],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tree = BlockerTree(tasks, hideCompleted: hideCompleted);
    final wide = MediaQuery.sizeOf(context).width >= BjBreakpoint.expanded;
    final visited = <String>{};

    final hero = ProjectSummaryHero(
      project: project,
      apps: apps,
      doneCount: tree.doneCount,
      totalCount: tasks.length,
    );
    final next = NextTasksCard(actionable: tree.actionable);
    final mapHeader = BjSectionHeader(
      title: 'Blocker flow map',
      count: tasks.length,
      subtitle: 'Nested tasks block the one above',
      trailing: onAddTask == null
          ? null
          : FilledButton.tonalIcon(
              onPressed: onAddTask,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add'),
            ),
    );
    final hideChip = Align(
      alignment: Alignment.centerLeft,
      child: FilterChip(
        avatar: const Icon(Icons.visibility_off_outlined, size: 18),
        label: Text(tree.doneCount > 0 ? 'Hide completed · ${tree.doneCount}' : 'Hide completed'),
        selected: hideCompleted,
        onSelected: onHideCompletedChanged,
      ),
    );
    final List<Widget> mapItems;
    if (tasks.isEmpty) {
      mapItems = [
        BjCard(
          child: BjStateView.empty(
            compact: true,
            icon: Icons.account_tree_outlined,
            title: 'No blockers yet',
            message: 'Add a blocker task to define what is stopping this project from moving forward.',
            action: onAddTask == null
                ? null
                : FilledButton.icon(
                    onPressed: onAddTask,
                    icon: const Icon(Icons.add_task_rounded),
                    label: const Text('Add blocker'),
                  ),
          ),
        ),
      ];
    } else if (tree.visible.isEmpty) {
      mapItems = [
        BjCard(
          child: BjStateView.empty(
            compact: true,
            icon: Icons.celebration_outlined,
            title: 'All tasks are completed',
            message: 'Turn off "Hide completed" to view completed blocker tasks.',
            action: OutlinedButton(
              onPressed: () => onHideCompletedChanged(false),
              child: const Text('Show completed'),
            ),
          ),
        ),
      ];
    } else {
      mapItems = [for (final task in tree.topLevel) _node(task, tree, visited)];
    }

    if (!wide) {
      return BjScrollBody(
        spacing: BjSpace.md,
        children: [
          hero,
          next,
          Padding(padding: const EdgeInsets.only(top: BjSpace.sm), child: mapHeader),
          hideChip,
          ...mapItems,
        ],
      );
    }
    return BjScrollBody(
      children: [
        hero,
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  mapHeader,
                  const SizedBox(height: BjSpace.sm),
                  hideChip,
                  for (final item in mapItems) ...[const SizedBox(height: BjSpace.md), item],
                ],
              ),
            ),
            const SizedBox(width: BjSpace.xl),
            SizedBox(width: 340, child: next),
          ],
        ),
      ],
    );
  }
}

/// Indents nested tasks behind a soft accent rail.
class _TreeRail extends StatelessWidget {
  final List<Widget> children;

  const _TreeRail({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: BjSpace.md),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: context.bj.accentSoft, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: BjSpace.sm),
            children[i],
          ],
        ],
      ),
    );
  }
}
