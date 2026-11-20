import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/ticket_close_reasons.dart';
import 'package:shared_ui/ticket_close_reason_dialog.dart';

void main() {
  Future<void> open(WidgetTester tester, List<TicketCloseReason> reasons, void Function(TicketCloseSelection?) onResult) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => onResult(await showTicketCloseReasonDialog(context, reasons: reasons, title: 'Close ticket')),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  FilledButton confirm(WidgetTester tester) =>
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Close'));

  testWidgets('an optional note: Close is enabled and returns the selection', (tester) async {
    TicketCloseSelection? picked;
    await open(tester, bugCloseReasons, (r) => picked = r);
    expect(find.text('Details (optional)'), findsOneWidget);
    expect(confirm(tester).onPressed, isNotNull);
    await tester.enterText(find.byType(TextField), 'see #12');
    await tester.tap(find.widgetWithText(FilledButton, 'Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(picked?.message, 'Unspecified — see #12');
  });

  testWidgets('"Needs more information" relabels the note and requires it', (tester) async {
    TicketCloseSelection? picked;
    await open(tester, ideaCloseReasons, (r) => picked = r);

    await tester.tap(find.text('Unspecified'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Needs more information').last);
    await tester.pumpAndSettle();

    expect(find.text('Your question for the requester'), findsOneWidget);
    expect(confirm(tester).onPressed, isNull);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(confirm(tester).onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'Which report do you export?');
    await tester.pump();
    expect(confirm(tester).onPressed, isNotNull);
    await tester.tap(find.widgetWithText(FilledButton, 'Close'));
    await tester.pumpAndSettle();

    expect(picked?.reason.code, 'needs_more_info');
    expect(picked?.message, 'Needs more information — Which report do you export?');
  });
}
