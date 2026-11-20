import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';

/// A sample screen built only from design-system parts, used by the
/// screenshot test and as a reference for app authors.
class GalleryScreen extends StatelessWidget {
  const GalleryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final stats = [
      const BjStatTile(label: 'Open tasks', value: '24', icon: Icons.checklist_rounded, caption: '6 due this week'),
      const BjStatTile(label: 'Blocked', value: '3', icon: Icons.block_rounded, tone: BjTone.danger, caption: 'Needs attention'),
      const BjStatTile(label: 'Done', value: '81%', icon: Icons.verified_rounded, tone: BjTone.success, caption: 'Up 12% this month'),
    ];
    return BjPage(
      title: 'Projects',
      subtitle: 'Sunnyside Insurance',
      actions: [IconButton(onPressed: () {}, icon: const Icon(Icons.search_rounded))],
      floatingActionButton: BjProgressFab(
        onPressed: () {},
        icon: Icons.upload_rounded,
        label: 'Import',
        busy: true,
        progress: 0.64,
        busyLabel: (p) => 'Importing $p%',
      ),
      body: BjScrollBody(children: [
        BjHeroCard(
          icon: Icons.rocket_launch_rounded,
          title: 'Q4 renewals',
          subtitle: '18 of 26 tasks done · due Dec 15',
          footer: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
            BjProgressBar(value: 0.69, onDark: true),
            SizedBox(height: BjSpace.sm),
            Text('69% complete'),
          ]),
        ),
        BjResponsiveGrid(minTileWidth: 280, children: stats),
        const DefaultTabController(
          length: 3,
          child: BjSegmentedTabs(tabs: [
            BjTab('Active', icon: Icons.bolt_rounded),
            BjTab('Planned', icon: Icons.event_note_rounded),
            BjTab('Archived', icon: Icons.inventory_2_outlined),
          ]),
        ),
        BjFilterBar(
          onSearchChanged: (_) {},
          searchHint: 'Search projects',
          filters: [
            FilterChip(label: const Text('All'), selected: true, onSelected: (_) {}),
            FilterChip(label: const Text('Active'), selected: false, onSelected: (_) {}),
            FilterChip(label: const Text('Blocked'), selected: false, onSelected: (_) {}),
            FilterChip(label: const Text('Done'), selected: false, onSelected: (_) {}),
          ],
        ),
        BjCard(
          child: BjFilterBar(groups: [
            BjFilterGroup(label: 'Labels', icon: Icons.label_outline_rounded, filters: [
              BjTagChip(label: 'underwriting', color: BjCategorical.violet, selected: true, onTap: () {}),
              BjTagChip(label: 'claims', color: BjCategorical.teal, selected: false, onTap: () {}),
              BjTagChip(label: 'brokers', color: BjCategorical.amber, selected: false, onTap: () {}),
            ]),
            const BjFilterGroup(
              label: 'Owner',
              icon: Icons.person_outline_rounded,
              filters: [],
              placeholder: BjInlineNote('No owners assigned yet.', icon: Icons.person_off_outlined),
            ),
          ]),
        ),
        const BjSectionHeader(title: 'Active projects', count: 3, subtitle: 'Sorted by due date'),
        BjListRow(
          leading: const BjIconWell(icon: Icons.house_rounded),
          title: 'Home policy migration',
          subtitle: 'Move legacy home policies onto the new rating engine',
          meta: const [
            BjStatusPill(label: 'In progress', tone: BjTone.info, icon: Icons.timelapse_rounded),
            BjStatusPill(label: 'Due Nov 28'),
            BjStatusPill(label: 'underwriting', color: Color(0xFF7C3AED)),
          ],
          onTap: () {},
          actions: [
            BjMenuAction(label: 'Edit', icon: Icons.edit_outlined, onSelected: () {}),
            BjMenuAction(label: 'Delete', icon: Icons.delete_outline, destructive: true, onSelected: () {}),
          ],
        ),
        BjListRow(
          leading: const BjIconWell(icon: Icons.warning_amber_rounded, tone: BjTone.warning),
          title: 'Broker portal SSO',
          subtitle: 'Waiting on the identity provider certificate',
          meta: const [
            BjStatusPill(label: 'Blocked', tone: BjTone.danger, icon: Icons.block_rounded),
            BjStatusPill(label: 'Due Dec 2'),
          ],
          onTap: () {},
          selected: true,
          actions: [BjMenuAction(label: 'Edit', icon: Icons.edit_outlined, onSelected: () {})],
        ),
        BjListRow(
          leading: const BjIconWell(icon: Icons.check_rounded, tone: BjTone.success),
          title: 'Claims intake form',
          subtitle: 'Shipped to all brokers',
          meta: const [BjStatusPill(label: 'Done', tone: BjTone.success, icon: Icons.check_rounded)],
          onTap: () {},
        ),
        const BjSectionHeader(title: 'Details'),
        BjFormSection(
          title: 'Project details',
          description: 'Visible to everyone in the group.',
          icon: Icons.edit_note_rounded,
          children: [
            const TextField(decoration: InputDecoration(labelText: 'Name', hintText: 'e.g. Q1 renewals')),
            const TextField(decoration: InputDecoration(labelText: 'Description'), maxLines: 2),
            Row(children: [
              OutlinedButton(onPressed: () {}, child: const Text('Cancel')),
              const SizedBox(width: BjSpace.sm),
              ElevatedButton(onPressed: () {}, child: const Text('Save project')),
            ]),
          ],
        ),
        BjFormSection(
          title: 'Share a file',
          icon: Icons.ios_share_rounded,
          children: [
            const BjFieldLabel('Who can see it?', helper: 'You can change this later.'),
            BjOptionCards<bool>(
              value: false,
              onChanged: (_) {},
              options: const [
                BjOption(value: true, title: 'Public', icon: Icons.public_rounded, tone: BjTone.info,
                    description: 'Anyone signed in to Bluejay can open its link.'),
                BjOption(value: false, title: 'Private', icon: Icons.lock_rounded, tone: BjTone.neutral,
                    description: 'Only this group and people you share it with.'),
              ],
            ),
            const BjFieldLabel('Expires', icon: Icons.event_outlined),
            BjDateField(value: DateTime(2026, 12, 15), prefix: 'Expires', onChanged: (_) {}),
            const BjInlineNote('Links to private files only work inside Bluejay.'),
            BjSheetActions(primaryLabel: 'Share', primaryIcon: Icons.check_rounded, onPrimary: () {}, onCancel: () {}),
          ],
        ),
        BjCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: BjSpace.xs + 2, runSpacing: BjSpace.xs + 2, children: [
              BjDuePill(due: DateTime(2026, 11, 2), now: DateTime(2026, 11, 10)),
              BjDuePill(due: DateTime(2026, 11, 28), now: DateTime(2026, 11, 10)),
              const BjDuePill(due: null),
              for (final (i, name) in const ['Video', 'Audio', 'Archive', 'Slides', 'Forms', 'Maps', 'Fonts', 'Data'].indexed)
                BjStatusPill(label: name, color: BjCategorical.at(i)),
            ]),
            const SizedBox(height: BjSpace.lg),
            BjDetailTable(rows: [
              const BjKeyValue(label: 'Type', value: 'Spreadsheet'),
              const BjKeyValue(label: 'Size', value: '2.4 MB'),
              const BjKeyValue(label: 'Uploaded by', value: 'jay'),
              BjKeyValue(label: 'Due', child: Align(alignment: Alignment.centerLeft,
                  child: BjDuePill(due: DateTime(2026, 11, 2), now: DateTime(2026, 11, 10)))),
            ]),
          ]),
        ),
        const BjCard(child: SizedBox(height: 220, child: BjStateView.empty(
          icon: Icons.folder_open_rounded,
          title: 'No archived projects',
          message: 'Archived projects show up here so the active list stays focused.',
          compact: true,
        ))),
        const BjSectionHeader(title: 'Group accent'),
        BjCard(child: BjAccentPicker(onChanged: (_, __) {})),
      ]),
    );
  }
}
