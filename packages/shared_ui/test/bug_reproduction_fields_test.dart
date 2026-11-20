import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui/bug_reproduction_fields.dart';

void main() {
  Widget host(BugReproductionController controller, {bool requireSteps = true}) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: BugReproductionFields(
            controller: controller,
            requireSteps: requireSteps,
          ),
        ),
      ),
    );
  }

  testWidgets('shows the worked example when expanded', (tester) async {
    final controller = BugReproductionController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(host(controller));

    expect(find.text('See an example'), findsOneWidget);
    expect(find.text(BugReproductionExample.steps), findsNothing);

    await tester.tap(find.text('See an example'));
    await tester.pump();

    expect(find.text(BugReproductionExample.steps), findsOneWidget);
    expect(find.text(BugReproductionExample.expected), findsOneWidget);
    expect(find.text(BugReproductionExample.actual), findsOneWidget);
    expect(find.text('Hide example'), findsOneWidget);
  });

  testWidgets('validate shows the steps error inline and clears it on edit',
      (tester) async {
    final controller = BugReproductionController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(host(controller));

    expect(find.text('Steps to reproduce (required)'), findsOneWidget);
    expect(controller.validate(), isNotNull);
    await tester.pump();
    expect(find.text('Add the steps to reproduce the problem.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('bugReproduction.steps')),
      'short',
    );
    await tester.pump();
    expect(find.text('Add the steps to reproduce the problem.'), findsNothing);

    expect(controller.validate(), contains('more detail'));
    await tester.enterText(
      find.byKey(const ValueKey('bugReproduction.steps')),
      '1. Open Photos\n2. Tap Upload\n3. Pick a photo',
    );
    expect(controller.validate(), isNull);
    expect(controller.value.toCreateFields().keys, ['stepsToReproduce']);
  });

  testWidgets('optional label when steps are not required', (tester) async {
    final controller = BugReproductionController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(host(controller, requireSteps: false));
    expect(find.text('Steps to reproduce'), findsOneWidget);
    expect(controller.validate(requireSteps: false), isNull);
  });

  testWidgets('BugReproductionDetails renders stored fields and nothing for legacy tickets',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            BugReproductionDetails.fromData(const {'description': 'old'}),
            BugReproductionDetails.fromData(const {
              'stepsToReproduce': '1. Open it',
              'actualBehavior': 'It crashed',
            }),
          ],
        ),
      ),
    ));
    expect(find.text('Steps to reproduce'), findsOneWidget);
    expect(find.text('1. Open it'), findsOneWidget);
    expect(find.text('Expected'), findsNothing);
    expect(find.text('It crashed'), findsOneWidget);
  });
}
