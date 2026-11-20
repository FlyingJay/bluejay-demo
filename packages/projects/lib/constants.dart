/// App-level constants for the projects package.
// ignore: constant_identifier_names
const APP_ID = 'projects';

/// Launch arg that opens Projects on one project (its doc id).
const String projectArg = 'project';

/// Launch arg that, with [projectArg], opens one task in that project.
const String taskArg = 'task';

/// The launch args that open project [projectId], and task [taskId] in it.
Map<String, String> projectPlaceArgs(String projectId, {String? taskId}) => {
      projectArg: projectId,
      if (taskId != null && taskId.isNotEmpty) taskArg: taskId,
    };
