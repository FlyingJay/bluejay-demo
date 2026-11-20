import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui/additional_email_recipients_field.dart';

void main() {
  late List<String> reported;

  Future<void> pumpField(WidgetTester tester, {int max = 3}) async {
    reported = const [];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AdditionalEmailRecipientsField(
            maxRecipients: max,
            primaryEmail: 'producer@example.com',
            onChanged: (entries) => reported = entries,
          ),
        ),
      ),
    );
  }

  testWidgets('starts empty and adds boxes up to the cap', (tester) async {
    await pumpField(tester);
    expect(find.byType(TextField), findsNothing);

    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('Add recipient'));
      await tester.pump();
    }
    expect(find.byType(TextField), findsNWidgets(3));
    expect(reported, ['', '', '']);

    // The add button is now disabled and explains the cap.
    expect(find.text('Maximum of 3 additional recipients'), findsOneWidget);
    await tester.tap(find.text('Maximum of 3 additional recipients'));
    await tester.pump();
    expect(find.byType(TextField), findsNWidgets(3));
  });

  testWidgets('remove deletes the box and reports the remaining entries',
      (tester) async {
    await pumpField(tester);
    await tester.tap(find.text('Add recipient'));
    await tester.pump();
    await tester.tap(find.text('Add recipient'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(0), 'a@example.com');
    await tester.enterText(find.byType(TextField).at(1), 'b@example.com');
    await tester.pump();

    await tester.tap(find.byTooltip('Remove recipient').first);
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
    expect(reported, ['b@example.com']);
  });

  testWidgets('flags invalid and duplicate addresses inline', (tester) async {
    await pumpField(tester);
    await tester.tap(find.text('Add recipient'));
    await tester.pump();
    await tester.tap(find.text('Add recipient'));
    await tester.pump();

    await tester.enterText(find.byType(TextField).at(0), 'not-an-email');
    await tester.enterText(find.byType(TextField).at(1), 'Producer@Example.com');
    await tester.pump();

    expect(find.text('Enter a valid email address'), findsOneWidget);
    expect(find.text('Already a recipient'), findsOneWidget);
  });
}
