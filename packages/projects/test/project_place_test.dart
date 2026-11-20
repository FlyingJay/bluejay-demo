import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:projects/constants.dart';
import 'package:projects/project_detail_screen.dart';
import 'package:shared_services/active_group_service.dart';
import 'package:shared_services/shared_place.dart';

import 'support/fixtures.dart';

void main() {
  setUp(() => ActiveGroupService.instance.activeGroupId = 'acme');

  tearDown(() {
    CurrentPlace.reset();
    ActiveGroupService.instance.activeGroupId = null;
  });

  test('projectPlaceArgs names the project, and the task when given', () {
    expect(projectPlaceArgs('p1'), {projectArg: 'p1'});
    expect(projectPlaceArgs('p1', taskId: 't1'), {'project': 'p1', 'task': 't1'});
    expect(projectPlaceArgs('p1', taskId: ''), {'project': 'p1'});
  });

  testWidgets('a project screen is a place in Projects', (t) async {
    await t.pumpWidget(ProjectPlace(project: project('p1', 'Launch'), child: const SizedBox()));
    final here = CurrentPlace.here()!;
    expect(here.appId, APP_ID);
    expect(here.appName, 'Projects');
    expect(here.args, {projectArg: 'p1'});
    expect(here.title, 'Launch');
  });

  testWidgets('a task in it is a place titled by the task', (t) async {
    await t.pumpWidget(ProjectPlace(
      project: project('p1', 'Launch'),
      task: task('t1', 'Sign off rates'),
      child: const SizedBox(),
    ));
    final here = CurrentPlace.here()!;
    expect(here.args, {projectArg: 'p1', taskArg: 't1'});
    expect(here.title, 'Sign off rates');
  });
}
