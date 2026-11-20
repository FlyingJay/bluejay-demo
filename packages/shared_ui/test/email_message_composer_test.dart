import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/ai_service.dart';
import 'package:shared_ui/email_message_composer.dart';

class _FakeTransport implements AiTransport {
  _FakeTransport(this.reply);
  final String reply;
  Map<String, Object?>? lastRequest;

  @override
  Future<Map<String, Object?>> generate(Map<String, Object?> request) async {
    lastRequest = request;
    return {'text': reply, 'model': 'gemini-2.5-flash', 'finishReason': 'STOP', 'usage': <String, Object?>{}};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('Improve with AI replaces the message and Undo restores it', (tester) async {
    final subject = TextEditingController(text: 'Quote');
    final message = TextEditingController(text: 'hi bob heres the quote');
    final transport = _FakeTransport('Hi Bob,\n\nHere is the quote.');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: EmailMessageComposer(
            subjectController: subject,
            messageController: message,
            appId: 'commercial-property',
            purpose: 'a quote',
            aiModel: AiModel(appId: 'commercial-property', model: 'gemini-2.5-flash', groupId: 'g1', transport: transport),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('Improve with AI'));
    await tester.pumpAndSettle();
    expect(message.text, 'Hi Bob,\n\nHere is the quote.');
    expect(transport.lastRequest.toString(), contains('hi bob heres the quote'));

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(message.text, 'hi bob heres the quote');
    expect(find.text('Undo'), findsNothing);
  });
}
