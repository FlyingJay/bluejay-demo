import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:shared_services/change_request_grouping.dart';
import 'package:shared_services/scoped_collection.dart';

/// Shared Improve Apps UI for grouping change requests under a parent — the
/// card chips, the select-mode bar and checkbox, and the "Combine" dialog and
/// flow used by both the idea and the bug list (see shared_services'
/// change_request_grouping.dart for the data side).

// ── Card chips ─────────────────────────────────────────────────────────────

/// `Part of: <parent> · <state>` on a grouped child and "Combines N
/// requests" on a parent. Renders nothing when neither applies. Place it
/// where its width is bounded (long titles ellipsize).
class ChangeRequestGroupingChips extends StatelessWidget {
  final ParentRequestRef? parentRequest;
  final int combinedCount;

  const ChangeRequestGroupingChips({
    super.key,
    this.parentRequest,
    this.combinedCount = 0,
  });

  /// Reads `parentRequest` / `linkedRecords` straight from a ticket doc.
  factory ChangeRequestGroupingChips.fromData(
    Map<String, dynamic> data, {
    Key? key,
  }) {
    return ChangeRequestGroupingChips(
      key: key,
      parentRequest: ParentRequestRef.fromData(data['parentRequest']),
      combinedCount: linkedChangeRequestCount(data['linkedRecords']),
    );
  }

  @override
  Widget build(BuildContext context) {
    final parent = parentRequest;
    if (parent == null && combinedCount <= 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: BjSpace.sm),
      child: Wrap(
        spacing: BjSpace.xs + 2,
        runSpacing: BjSpace.xs + 2,
        children: [
          if (parent != null)
            _GroupingChip(
              icon: Icons.account_tree_outlined,
              label: parent.chipLabel,
              tone: parent.state == ChangeRequestState.resolved
                  ? BjTone.success
                  : BjTone.accent,
            ),
          if (combinedCount > 0)
            _GroupingChip(
              icon: Icons.merge_type_rounded,
              label: combinedRequestsLabel(combinedCount),
              tone: BjTone.info,
            ),
        ],
      ),
    );
  }
}

class _GroupingChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final BjTone tone;

  const _GroupingChip({
    required this.icon,
    required this.label,
    required this.tone,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.bj.tone(tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: BjSpace.sm + 2, vertical: 3),
      decoration: BoxDecoration(
        color: t.background,
        borderRadius: BjRadius.all(BjRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: t.foreground),
          const SizedBox(width: BjSpace.xs),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: t.foreground),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Select mode ────────────────────────────────────────────────────────────

/// Bar under the scope switcher in the "Apps I manage" list: a "Select"
/// action when idle; the selection count, Cancel and "Combine…" while
/// selecting.
class ChangeRequestSelectionBar extends StatelessWidget {
  final bool selecting;
  final int selectedCount;

  /// The app the selection is about, shown next to the count.
  final String appLabel;
  final VoidCallback onStart;
  final VoidCallback onCancel;
  final VoidCallback onCombine;

  const ChangeRequestSelectionBar({
    super.key,
    required this.selecting,
    required this.selectedCount,
    this.appLabel = '',
    required this.onStart,
    required this.onCancel,
    required this.onCombine,
  });

  @override
  Widget build(BuildContext context) {
    if (!selecting) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(BjSpace.md, BjSpace.xs, BjSpace.md, 0),
        child: Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: onStart,
            icon: const Icon(Icons.checklist_rounded, size: 18),
            label: const Text('Select to combine'),
          ),
        ),
      );
    }
    final countLabel = selectedCount == 0
        ? 'Select requests about one app'
        : '$selectedCount selected${appLabel.isEmpty ? '' : ' · $appLabel'}';
    final bj = context.bj;
    return Padding(
      padding: const EdgeInsets.fromLTRB(BjSpace.md, BjSpace.sm, BjSpace.md, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(BjSpace.lg, BjSpace.xs + 2, BjSpace.xs + 2, BjSpace.xs + 2),
        decoration: BoxDecoration(
          gradient: bj.softGradient,
          borderRadius: BjRadius.all(BjRadius.lg),
          border: Border.all(color: bj.tone(BjTone.accent).border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                countLabel,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(color: BjNeutral.ink),
              ),
            ),
            TextButton(
              onPressed: onCancel,
              child: const Text('Cancel'),
            ),
            const SizedBox(width: BjSpace.xs),
            FilledButton(
              onPressed: selectedCount == 0 ? null : onCombine,
              child: const Text('Combine…'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Puts a checkbox beside a card in select mode. A non-null
/// [disabledReason] disables the checkbox and explains why on tap/hover.
class ChangeRequestSelectableCard extends StatelessWidget {
  final bool selected;
  final String? disabledReason;
  final ValueChanged<bool> onChanged;
  final Widget child;

  const ChangeRequestSelectableCard({
    super.key,
    required this.selected,
    required this.disabledReason,
    required this.onChanged,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final reason = disabledReason;
    final checkbox = Checkbox(
      value: selected,
      onChanged: reason != null && !selected
          ? null
          : (value) => onChanged(value ?? false),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: BjSpace.md + 2),
          child: reason != null && !selected
              ? Tooltip(
                  message: reason,
                  triggerMode: TooltipTriggerMode.tap,
                  child: checkbox,
                )
              : checkbox,
        ),
        Expanded(child: child),
      ],
    );
  }
}

// ── Combine dialog ─────────────────────────────────────────────────────────

/// What the steward chose in the "Combine" dialog: add to [existingParent],
/// or (when it's null) create a new idea titled [title].
class CombineRequestsChoice {
  final ChangeRequestSummary? existingParent;
  final String title;
  final String description;

  const CombineRequestsChoice.newParent({
    required this.title,
    this.description = '',
  }) : existingParent = null;

  const CombineRequestsChoice.existing(ChangeRequestSummary parent)
      : existingParent = parent,
        title = '',
        description = '';
}

/// Asks how to combine [selected]: into a new idea created in the active
/// group [groupName] (unavailable when [canCreateNew] is false), or into one
/// of [parentCandidates] once they load.
Future<CombineRequestsChoice?> showCombineRequestsDialog(
  BuildContext context, {
  required List<ChangeRequestSummary> selected,
  required String groupName,
  required bool canCreateNew,
  required Future<List<ChangeRequestSummary>> parentCandidates,
}) {
  return showDialog<CombineRequestsChoice>(
    context: context,
    builder: (_) => CombineRequestsDialog(
      selected: selected,
      groupName: groupName,
      canCreateNew: canCreateNew,
      parentCandidates: parentCandidates,
    ),
  );
}

class CombineRequestsDialog extends StatefulWidget {
  final List<ChangeRequestSummary> selected;
  final String groupName;
  final bool canCreateNew;
  final Future<List<ChangeRequestSummary>> parentCandidates;

  const CombineRequestsDialog({
    super.key,
    required this.selected,
    required this.groupName,
    required this.canCreateNew,
    required this.parentCandidates,
  });

  @override
  State<CombineRequestsDialog> createState() => _CombineRequestsDialogState();
}

class _CombineRequestsDialogState extends State<CombineRequestsDialog> {
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  late bool _addToExisting = !widget.canCreateNew;
  ChangeRequestSummary? _chosenParent;
  String? _titleError;

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_addToExisting) {
      final parent = _chosenParent;
      if (parent == null) return;
      Navigator.of(context).pop(CombineRequestsChoice.existing(parent));
      return;
    }
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() => _titleError = 'Give the combined request a title');
      return;
    }
    Navigator.of(context).pop(CombineRequestsChoice.newParent(
      title: title,
      description: _descriptionController.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.selected.length;
    final includesBugs = widget.selected.any((s) => s.itemType == 'bug');
    return AlertDialog(
      icon: const Center(child: BjIconWell(icon: Icons.merge_type_rounded, size: 52)),
      title: Text('Combine $count ${count == 1 ? 'request' : 'requests'}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FutureBuilder<List<ChangeRequestSummary>>(
                future: widget.parentCandidates,
                builder: (context, snapshot) {
                  final candidates = snapshot.data ?? const [];
                  final loading =
                      snapshot.connectionState != ConnectionState.done;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<bool>(
                          showSelectedIcon: false,
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                          ),
                          segments: [
                            ButtonSegment<bool>(
                              value: false,
                              enabled: widget.canCreateNew,
                              label: const Text('New request'),
                            ),
                            ButtonSegment<bool>(
                              value: true,
                              enabled: candidates.isNotEmpty,
                              label: Text(loading
                                  ? 'Add to existing…'
                                  : 'Add to existing (${candidates.length})'),
                            ),
                          ],
                          selected: {_addToExisting},
                          onSelectionChanged: (selection) =>
                              setState(() => _addToExisting = selection.first),
                        ),
                      ),
                      const SizedBox(height: BjSpace.lg),
                      if (_addToExisting)
                        _buildExistingPicker(candidates, loading, snapshot)
                      else
                        _buildNewParentFields(includesBugs),
                    ],
                  );
                },
              ),
              const SizedBox(height: BjSpace.lg),
              BjSectionHeader(title: 'Requests', count: count),
              const SizedBox(height: BjSpace.xs),
              for (final item in widget.selected) _SummaryRow(item: item),
            ],
          ),
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _addToExisting && _chosenParent == null ? null : _submit,
          child: Text(_addToExisting ? 'Add' : 'Combine'),
        ),
      ],
    );
  }

  Widget _buildNewParentFields(bool includesBugs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _titleController,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: 'Title',
            hintText: 'What the combined request delivers',
            errorText: _titleError,
          ),
          onChanged: (_) {
            if (_titleError != null) setState(() => _titleError = null);
          },
        ),
        const SizedBox(height: BjSpace.md),
        TextField(
          controller: _descriptionController,
          maxLines: 3,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Description (optional)',
            hintText: 'Context for whoever builds it',
          ),
        ),
        const SizedBox(height: BjSpace.md),
        BjInlineNote('Create in: ${widget.groupName}', icon: Icons.group_outlined),
        const SizedBox(height: BjSpace.xs + 2),
        BjInlineNote(
          includesBugs
              ? 'The combined request is created as an idea. Each request '
                  'is resolved, and its submitter told, when it ships.'
              : 'Each request is completed, and its submitter told, when '
                  'the combined idea ships.',
          icon: Icons.info_outline_rounded,
        ),
      ],
    );
  }

  Widget _buildExistingPicker(
    List<ChangeRequestSummary> candidates,
    bool loading,
    AsyncSnapshot<List<ChangeRequestSummary>> snapshot,
  ) {
    if (loading) {
      return const Column(
        children: [
          BjSkeleton(height: 44),
          SizedBox(height: BjSpace.sm),
          BjSkeleton(height: 44),
        ],
      );
    }
    if (snapshot.hasError || candidates.isEmpty) {
      return BjInlineNote(
        snapshot.hasError
            ? 'Could not load existing requests.'
            : 'No open combined requests for this app yet.',
        icon: snapshot.hasError
            ? Icons.error_outline_rounded
            : Icons.inbox_outlined,
        tone: snapshot.hasError ? BjTone.danger : null,
      );
    }
    return RadioGroup<String>(
      groupValue: _chosenParent == null
          ? null
          : '${_chosenParent!.itemType}/${_chosenParent!.itemId}',
      onChanged: (value) => setState(() {
        _chosenParent = candidates.firstWhere(
          (c) => '${c.itemType}/${c.itemId}' == value,
        );
      }),
      child: Column(
        children: [
          for (final candidate in candidates)
            RadioListTile<String>(
              value: '${candidate.itemType}/${candidate.itemId}',
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                candidate.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  candidate.itemType == 'bug' ? 'Bug' : 'Idea',
                  combinedRequestsLabel(candidate.combinedCount),
                  if (candidate.groupLabel.isNotEmpty) candidate.groupLabel,
                ].join(' · '),
              ),
            ),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final ChangeRequestSummary item;

  const _SummaryRow({required this.item});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: BjSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            item.itemType == 'bug'
                ? Icons.bug_report_outlined
                : Icons.lightbulb_outline_rounded,
            size: 16,
            color: BjNeutral.inkMuted,
          ),
          const SizedBox(width: BjSpace.sm),
          Expanded(
            child: Text(
              item.groupLabel.isEmpty
                  ? item.title
                  : '${item.title} (${item.groupLabel})',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Flow ───────────────────────────────────────────────────────────────────

/// Thrown by a [combineChangeRequests] `invoke` callback to report a
/// user-facing failure (e.g. a callable error's message).
class ChangeRequestGroupingFailure implements Exception {
  final String message;
  const ChangeRequestGroupingFailure(this.message);

  @override
  String toString() => message;
}

/// Open parents about [relatedAppId] in either Improve Apps collection, for
/// the dialog's "Add to existing" list. Uses the same per-app equality
/// queries as the "Apps I manage" lists, which firestore.rules can prove for
/// a steward.
Future<List<ChangeRequestSummary>> loadParentRequestCandidates({
  required String improveAppsId,
  required String relatedAppId,
  Iterable<ChangeRequestSummary> selected = const [],
}) async {
  final results = await Future.wait([
    for (final entry in groupableChangeRequestCollections.entries)
      ScopedCollection(collection: entry.key, appId: improveAppsId)
          .queryForRelatedApp(relatedAppId)
          .get()
          .then((snapshot) => snapshot.docs
              .map((doc) => ChangeRequestSummary.fromData(
                    itemType: entry.value,
                    itemId: doc.id,
                    data: doc.data(),
                  ))
              .toList()),
  ]);
  return parentCandidatesFor(
    results.expand((items) => items),
    appId: relatedAppId,
    selected: selected,
  );
}

/// Runs the whole "Combine" flow for [selected] (all about one app) from the
/// [sourceItemType] ('bug' / 'feature') list: asks via
/// [showCombineRequestsDialog], calls [invoke] with the
/// `changeRequestsGroup` payload, and reports the outcome in a snackbar.
/// Returns true when the requests were grouped.
///
/// [invoke] should throw [ChangeRequestGroupingFailure] with a user-facing
/// message on failure; any other error shows a generic message.
Future<bool> combineChangeRequests(
  BuildContext context, {
  required List<ChangeRequestSummary> selected,
  required String sourceItemType,
  required String improveAppsId,
  required String? activeGroupId,
  required String? activeGroupName,
  required Future<void> Function(Map<String, dynamic> payload) invoke,
}) async {
  final appId = selectionAppId(selected);
  if (appId == null || appId.isEmpty) return false;
  final groupId = activeGroupId?.trim() ?? '';
  final groupName = (activeGroupName?.trim().isNotEmpty ?? false)
      ? activeGroupName!.trim()
      : groupId;

  final choice = await showCombineRequestsDialog(
    context,
    selected: selected,
    groupName: groupName,
    canCreateNew: groupId.isNotEmpty,
    parentCandidates: loadParentRequestCandidates(
      improveAppsId: improveAppsId,
      relatedAppId: appId,
      selected: selected,
    ),
  );
  if (choice == null || !context.mounted) return false;

  final existing = choice.existingParent;
  final payload = existing != null
      ? existingParentGroupingPayload(children: selected, parent: existing)
      : newParentGroupingPayload(
          children: selected,
          groupId: groupId,
          title: choice.title,
          description: choice.description,
        );
  try {
    await invoke(payload);
  } on ChangeRequestGroupingFailure catch (e) {
    if (context.mounted) BjSnack.error(context, e.message);
    return false;
  } catch (_) {
    if (context.mounted) {
      BjSnack.error(context, 'Could not combine these requests. Please try again.');
    }
    return false;
  }
  if (context.mounted) {
    BjSnack.success(
      context,
      groupingSuccessMessage(
        count: selected.length,
        createdNewParent: existing == null,
        sourceItemType: sourceItemType,
        parentTitle: existing?.title ?? '',
      ),
    );
  }
  return true;
}
