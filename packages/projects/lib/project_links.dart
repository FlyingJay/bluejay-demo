import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:projects/models.dart';
import 'package:shared_services/bluejay_firestore.dart';
import 'package:shared_services/group_docs.dart';
import 'package:projects/constants.dart';

/// A bluejay app a project can be linked to.
class ProjectAppOption {
  /// The app's `appId` (falling back to its `apps` doc id) — what
  /// `relatedAppIds` and `projectsCreateChangeRequest` take.
  final String id;
  final String name;

  /// Whether the app is installed in the group the options were loaded for.
  final bool installed;

  const ProjectAppOption({
    required this.id,
    required this.name,
    required this.installed,
  });
}

/// Every app in the `apps` collection ordered by name, each flagged with
/// whether it's installed in [groupId] (groups/{groupId}.installedApps, or
/// the legacy accessibleAppIds). Same lookup as the Improve Apps form
/// (packages/bug_reports/lib/bug_reports_screen.dart `_loadApps`), except
/// uninstalled apps are kept, flagged, so ids already saved on a project
/// still resolve to a name. If the group can't be read, every app counts as
/// installed, as there.
Future<List<ProjectAppOption>> loadProjectAppOptions(String? groupId) async {
  Set<String>? installedDocIds;
  if (groupId != null && groupId.isNotEmpty) {
    final groupSnap = await GroupDocs.get(groupId, appId: APP_ID);
    final groupData = groupSnap.data();
    if (groupData != null) {
      final raw = groupData['installedApps'] ?? groupData['accessibleAppIds'];
      if (raw is List) {
        installedDocIds = raw.whereType<String>().toSet();
      }
    }
  }

  final snap = await BluejayFirestore.forApp(APP_ID).collection('apps').orderBy('name').get();
  return snap.docs
      .map((d) {
        final data = d.data();
        final id = ((data['appId'] as String?) ?? d.id).trim();
        if (id.isEmpty) return null;
        final name = ((data['name'] as String?) ?? id).trim();
        return ProjectAppOption(
          id: id,
          name: name.isEmpty ? id : name,
          installed: installedDocIds == null || installedDocIds.contains(d.id),
        );
      })
      .whereType<ProjectAppOption>()
      .toList();
}

/// Name for [appId] from [apps], falling back to the raw id.
String projectAppName(String appId, List<ProjectAppOption> apps) {
  for (final app in apps) {
    if (app.id == appId) return app.name;
  }
  return appId;
}

/// App and client-group pills for a project's card and detail header. Renders
/// nothing when the project has neither.
class ProjectLinkChips extends StatelessWidget {
  final ProjectRecord project;
  final List<ProjectAppOption> apps;

  const ProjectLinkChips({
    super.key,
    required this.project,
    required this.apps,
  });

  /// The pills on their own, for callers that lay them out in a wider row.
  static List<Widget> pills(ProjectRecord project, List<ProjectAppOption> apps) => [
        ...project.relatedAppIds.map(
          (appId) => Tooltip(
            message: 'App',
            child: BjStatusPill(
              label: projectAppName(appId, apps),
              icon: Icons.apps_rounded,
              tone: BjTone.info,
            ),
          ),
        ),
        ...project.clientGroupIds.map(
          (groupId) => Tooltip(
            message: 'Client group',
            child: BjStatusPill(
              label: project.clientGroupName(groupId),
              icon: Icons.business_outlined,
            ),
          ),
        ),
      ];

  @override
  Widget build(BuildContext context) {
    if (project.relatedAppIds.isEmpty && project.clientGroupIds.isEmpty) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: BjSpace.xs + 2,
      runSpacing: BjSpace.xs + 2,
      children: pills(project, apps),
    );
  }
}
