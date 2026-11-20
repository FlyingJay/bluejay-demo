import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui/claim_account_sheet.dart';

Widget sheet({required bool visitorSession}) => MaterialApp(
      home: Scaffold(body: ClaimAccountSheet(visitorSession: visitorSession)),
    );

Future<void> switchToLogIn(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(TextButton, 'Log In'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a visitor is told before logging in that the visit\'s work stays behind', (tester) async {
    await tester.pumpWidget(sheet(visitorSession: true));
    expect(find.text('Create Your Account'), findsOneWidget);
    expect(find.text(ClaimAccountSheet.switchWarning), findsNothing,
        reason: 'creating an account keeps the work, so there is nothing to warn about');

    await switchToLogIn(tester);
    expect(find.text('Log In to Existing Account'), findsOneWidget);
    expect(find.text(ClaimAccountSheet.switchWarning), findsOneWidget);
  });

  testWidgets('a signed-in account logging in sees no visitor warning', (tester) async {
    await tester.pumpWidget(sheet(visitorSession: false));
    await switchToLogIn(tester);
    expect(find.text(ClaimAccountSheet.switchWarning), findsNothing);
  });

  test('the claim confirmation names the username to log in with', () {
    expect(ClaimAccountSheet.claimedMessage('vic'), contains('Log in as vic'));
  });
}
