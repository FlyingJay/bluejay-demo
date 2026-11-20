import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:projects/models.dart';

/// How each project, task and change-request state looks: label, icon and
/// design-system tone. The one place these are decided, so the dashboard,
/// detail screen and forms always agree.
class StatusStyle {
  final String label;
  final IconData icon;
  final BjTone tone;

  const StatusStyle(this.label, this.icon, this.tone);
}

const Map<ProjectStatus, StatusStyle> projectStatusStyles = {
  ProjectStatus.planned: StatusStyle('Planned', Icons.event_note_rounded, BjTone.info),
  ProjectStatus.active: StatusStyle('Active', Icons.bolt_rounded, BjTone.success),
  ProjectStatus.onHold: StatusStyle('On hold', Icons.pause_circle_outline_rounded, BjTone.warning),
  ProjectStatus.completed: StatusStyle('Completed', Icons.check_circle_outline_rounded, BjTone.neutral),
};

const Map<BlockerStatus, StatusStyle> blockerStatusStyles = {
  BlockerStatus.todo: StatusStyle('To do', Icons.radio_button_unchecked_rounded, BjTone.warning),
  BlockerStatus.inProgress: StatusStyle('In progress', Icons.timelapse_rounded, BjTone.info),
  BlockerStatus.done: StatusStyle('Done', Icons.check_circle_rounded, BjTone.success),
};

/// Labels come from the shared lifecycle so they match Improve Apps.
final Map<ChangeRequestState, StatusStyle> changeRequestStateStyles = {
  for (final entry in const {
    ChangeRequestState.open: (Icons.inbox_outlined, BjTone.neutral),
    ChangeRequestState.queued: (Icons.schedule_rounded, BjTone.accent),
    ChangeRequestState.inReview: (Icons.rate_review_outlined, BjTone.info),
    ChangeRequestState.merged: (Icons.merge_type_rounded, BjTone.success),
    ChangeRequestState.resolved: (Icons.task_alt_rounded, BjTone.success),
    ChangeRequestState.closed: (Icons.block_rounded, BjTone.neutral),
  }.entries)
    entry.key: StatusStyle(changeRequestStateLabel(entry.key), entry.value.$1, entry.value.$2),
};

StatusStyle projectStatusStyle(ProjectStatus status) => projectStatusStyles[status]!;
StatusStyle blockerStatusStyle(BlockerStatus status) => blockerStatusStyles[status]!;
StatusStyle changeRequestStateStyle(ChangeRequestState state) => changeRequestStateStyles[state]!;

/// Tone for a task priority: P1 stands out, P2 is flagged, the rest are calm.
BjTone priorityTone(int priority) {
  if (priority <= 1) return BjTone.danger;
  if (priority == 2) return BjTone.warning;
  return BjTone.neutral;
}

/// A [BjStatusPill] for a [StatusStyle].
class StylePill extends StatelessWidget {
  final StatusStyle style;
  final String? label;

  const StylePill(this.style, {super.key, this.label});

  @override
  Widget build(BuildContext context) =>
      BjStatusPill(label: label ?? style.label, icon: style.icon, tone: style.tone);
}
