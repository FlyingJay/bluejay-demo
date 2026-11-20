import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_ui/automations_panel.dart';

import 'constants.dart';
import 'help_desk_api.dart';
import 'help_desk_models.dart';

/// A desk's settings: who may file (guests, the signed-out form), topics,
/// saved replies, the first-response target and the welcome note. Platform
/// admins also choose where a group's requests go (its own admins, or the
/// Bluejay desk directly). With [platformDesk], the Bluejay desk's own
/// settings (topics, saved replies, target), for support staff.
class HelpDeskSettingsScreen extends StatefulWidget {
  final HelpDeskApi api;
  final String? groupId;
  final String groupName;
  final bool platformDesk;

  const HelpDeskSettingsScreen({
    super.key,
    this.api = const HelpDeskApi(),
    this.groupId,
    this.groupName = '',
    this.platformDesk = false,
  });

  @override
  State<HelpDeskSettingsScreen> createState() => _HelpDeskSettingsScreenState();
}

class _HelpDeskSettingsScreenState extends State<HelpDeskSettingsScreen> {
  DeskSettings? _settings;
  Object? _error;
  bool _saving = false;
  final _welcome = TextEditingController();
  final _newCategory = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _welcome.dispose();
    _newCategory.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await widget.api.settings(groupId: widget.groupId, platformDesk: widget.platformDesk);
      if (!mounted) return;
      _welcome.text = s.welcome;
      setState(() {
        _settings = s;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _save(Map<String, dynamic> patch, {String? done}) async {
    setState(() => _saving = true);
    try {
      final s = await widget.api.saveSettings(patch, groupId: widget.groupId, platformDesk: widget.platformDesk);
      if (!mounted) return;
      setState(() => _settings = DeskSettings(
            routing: s.routing,
            guestIntake: s.guestIntake,
            publicIntake: s.publicIntake,
            categories: s.categories,
            savedReplies: s.savedReplies,
            firstResponseHours: s.firstResponseHours,
            welcome: s.welcome,
            platformDesk: _settings!.platformDesk,
            canChangeRouting: _settings!.canChangeRouting,
            publicFormUrl: _settings!.publicFormUrl,
          ));
      if (done != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(helpDeskErrorMessage(e))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editSavedReply({SavedReply? existing, int? index}) async {
    final title = TextEditingController(text: existing?.title ?? '');
    final body = TextEditingController(text: existing?.body ?? '');
    final result = await showBjSheet<SavedReply>(
      context,
      title: existing == null ? 'New saved reply' : 'Edit saved reply',
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: title,
            maxLength: 60,
            onChanged: (_) => setSheet(() {}),
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          TextField(
            controller: body,
            maxLength: 2000,
            minLines: 3,
            maxLines: 8,
            onChanged: (_) => setSheet(() {}),
            decoration: const InputDecoration(labelText: 'Reply', alignLabelWithHint: true),
          ),
          const SizedBox(height: BjSpace.lg),
          BjSheetActions(
            primaryLabel: 'Save',
            onPrimary: title.text.trim().isEmpty || body.text.trim().isEmpty
                ? null
                : () => Navigator.of(context).pop(SavedReply(title: title.text.trim(), body: body.text.trim())),
            onCancel: () => Navigator.of(context).pop(),
          ),
        ]),
      ),
    );
    if (result == null) return;
    final replies = [..._settings!.savedReplies];
    if (index == null) {
      replies.add(result);
    } else {
      replies[index] = result;
    }
    await _save({'savedReplies': [for (final r in replies) r.toMap()]});
  }

  Future<void> _removeSavedReply(int index) async {
    final replies = [..._settings!.savedReplies]..removeAt(index);
    await _save({'savedReplies': [for (final r in replies) r.toMap()]});
  }

  Future<void> _addCategory() async {
    final value = _newCategory.text.trim();
    if (value.isEmpty) return;
    _newCategory.clear();
    await _save({'categories': [..._settings!.categories, value]});
  }

  @override
  Widget build(BuildContext context) {
    final s = _settings;
    final title = widget.platformDesk ? 'Bluejay desk settings' : 'Desk settings';
    if (s == null) {
      return BjPage(
        title: title,
        body: _error == null
            ? const BjSkeletonList(count: 3)
            : BjStateView.error(error: helpDeskErrorMessage(_error!), onRetry: _load),
      );
    }
    final group = widget.groupName.isEmpty ? 'your group' : widget.groupName;
    return BjPage(
      title: title,
      subtitle: widget.platformDesk ? null : widget.groupName,
      body: BjScrollBody(maxWidth: BjBreakpoint.formWidth, children: [
        if (s.canChangeRouting)
          BjFormSection(
            title: 'Where requests go',
            icon: Icons.alt_route_rounded,
            description: 'Platform admins only. Staff groups send their requests straight to Bluejay support.',
            children: [
              BjOptionCards<String>(
                axis: Axis.vertical,
                value: s.routing,
                onChanged: _saving ? (_) {} : (v) => _save({'routing': v}, done: 'Saved.'),
                options: [
                  BjOption(value: 'self', title: '$group\'s admins', icon: Icons.groups_rounded,
                      description: 'They answer, and escalate to Bluejay when they need to.'),
                  const BjOption(value: 'platform', title: 'Bluejay support', icon: Icons.support_agent_rounded,
                      description: 'Every request goes straight to the Bluejay desk.'),
                ],
              ),
            ],
          ),
        if (!widget.platformDesk)
          BjFormSection(
            title: 'Who can ask',
            icon: Icons.how_to_reg_outlined,
            description: 'Members with Help Desk can always ask.',
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: s.guestIntake,
                onChanged: _saving ? null : (v) => _save({'guestIntake': v}),
                title: const Text('Guests and clients'),
                subtitle: const Text('Signed-in guests and portal clients can ask from Help Desk and every app\'s help tab.'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: s.publicIntake,
                onChanged: _saving ? null : (v) => _save({'publicIntake': v}),
                title: const Text('Anyone, with the public help form'),
                subtitle: const Text('No account needed. Replies go by email. Shop orders link here.'),
              ),
              if (s.publicIntake && s.publicFormUrl != null)
                BjListRow(
                  dense: true,
                  leading: const Icon(Icons.link_rounded),
                  title: s.publicFormUrl!,
                  trailing: IconButton(
                    tooltip: 'Copy link',
                    icon: const Icon(Icons.copy_rounded),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: s.publicFormUrl!));
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied.')));
                    },
                  ),
                ),
            ],
          ),
        BjFormSection(
          title: 'Topics',
          icon: Icons.label_outline_rounded,
          description: 'What requesters choose from.',
          children: [
            Wrap(spacing: BjSpace.sm, runSpacing: BjSpace.xs, children: [
              for (final c in s.categories)
                InputChip(
                  label: Text(c),
                  onDeleted: _saving || s.categories.length <= 1
                      ? null
                      : () => _save({'categories': s.categories.where((x) => x != c).toList()}),
                ),
            ]),
            if (s.categories.length < 12)
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _newCategory,
                    maxLength: 40,
                    onSubmitted: (_) => _addCategory(),
                    decoration: const InputDecoration(labelText: 'Add a topic', counterText: ''),
                  ),
                ),
                IconButton(onPressed: _saving ? null : _addCategory, icon: const Icon(Icons.add_rounded)),
              ]),
          ],
        ),
        BjFormSection(
          title: 'Saved replies',
          icon: Icons.bookmarks_outlined,
          description: 'Answers you give often, ready to insert.',
          children: [
            for (var i = 0; i < s.savedReplies.length; i++)
              BjListRow(
                dense: true,
                title: s.savedReplies[i].title,
                subtitle: s.savedReplies[i].body,
                onTap: () => _editSavedReply(existing: s.savedReplies[i], index: i),
                actions: [
                  BjMenuAction(label: 'Edit', icon: Icons.edit_outlined, onSelected: () => _editSavedReply(existing: s.savedReplies[i], index: i)),
                  BjMenuAction(label: 'Delete', icon: Icons.delete_outline_rounded, destructive: true, onSelected: () => _removeSavedReply(i)),
                ],
              ),
            if (s.savedReplies.length < 30)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _saving ? null : () => _editSavedReply(),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add a saved reply'),
                ),
              ),
          ],
        ),
        BjFormSection(
          title: 'First reply within',
          icon: Icons.timer_outlined,
          description: 'Unanswered requests older than this are marked overdue.',
          children: [
            Wrap(spacing: BjSpace.sm, children: [
              for (final h in const [4, 8, 24, 48, 72])
                ChoiceChip(
                  label: Text(h < 24 ? '$h hours' : '${h ~/ 24} day${h == 24 ? '' : 's'}'),
                  selected: s.firstResponseHours == h,
                  onSelected: _saving ? null : (_) => _save({'firstResponseHours': h}),
                ),
            ]),
          ],
        ),
        if (!widget.platformDesk)
          BjFormSection(
            title: 'Welcome note',
            icon: Icons.waving_hand_outlined,
            description: 'Shown at the top of the request form.',
            children: [
              TextField(
                controller: _welcome,
                maxLength: 500,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(hintText: 'e.g. We reply within one business day.'),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: BjBusyButton(
                  label: 'Save note',
                  busy: _saving,
                  onPressed: () => _save({'welcome': _welcome.text.trim()}, done: 'Saved.'),
                ),
              ),
            ],
          ),
        // What happens automatically when tickets come in; shows only to people who manage automations.
        if (!widget.platformDesk && widget.groupId != null)
          AutomationsPanel(appId: APP_ID, appName: 'Help Desk', groupId: widget.groupId),
      ]),
    );
  }
}
