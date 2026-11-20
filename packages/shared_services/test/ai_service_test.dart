import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/ai_service.dart';

class FakeTransport implements AiTransport {
  final requests = <Map<String, Object?>>[];
  Map<String, Object?> result = {'text': 'ok', 'model': 'gemini-2.5-flash'};
  List<AiStreamEvent> events = const [];

  @override
  Future<Map<String, Object?>> generate(Map<String, Object?> request) async {
    requests.add(request);
    return result;
  }

  @override
  Stream<AiStreamEvent> stream(Map<String, Object?> request) async* {
    requests.add(request);
    for (final e in events) {
      yield e;
    }
  }
}

void main() {
  _incompleteStreamTests();

  group('AiModel.buildRequest', () {
    test('maps model, contents, system instruction and JSON mode', () {
      final model = AiModel(
        appId: 'parser',
        groupId: 'g1',
        model: 'gemini-2.5-flash',
        systemInstruction: 'be terse',
        generationConfig: const AiGenerationConfig(responseMimeType: 'application/json'),
        transport: FakeTransport(),
      );
      final bytes = Uint8List.fromList([1, 2, 3, 250]);
      final request = model.buildRequest([
        AiContent('user', [const AiTextPart('extract'), AiDataPart('application/pdf', bytes)]),
      ]);
      expect(request, {
        'appId': 'parser',
        'groupId': 'g1',
        'model': 'gemini-2.5-flash',
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': 'extract'},
              {
                'inlineData': {'mimeType': 'application/pdf', 'data': base64Encode(bytes)},
              },
            ],
          },
        ],
        'systemInstruction': 'be terse',
        'generationConfig': {'responseMimeType': 'application/json'},
      });
      // The whole payload must be plain JSON for the callable protocol.
      expect(() => jsonEncode(request), returnsNormally);
    });

    test('sends a tier only when no explicit model is set, and omits empty extras', () {
      final request = AiModel(appId: 'a', groupId: 'g', tier: AiTier.lite, systemInstruction: '', transport: FakeTransport())
          .buildRequest([AiContent.text('hi')]);
      expect(request['tier'], 'lite');
      expect(request.containsKey('model'), isFalse);
      expect(request.containsKey('systemInstruction'), isFalse);
      expect(request.containsKey('generationConfig'), isFalse);
      expect(request['contents'], [
        {
          'role': 'user',
          'parts': [
            {'text': 'hi'}
          ],
        }
      ]);
    });
  });

  test('generateContent parses the callable result', () async {
    final transport = FakeTransport()
      ..result = {
        'text': 'hello',
        'model': 'gemini-2.5-flash',
        'finishReason': 'STOP',
        'usage': {'promptTokenCount': 3, 'candidatesTokenCount': 1, 'totalTokenCount': 4},
      };
    final response = await AiModel(appId: 'a', groupId: 'g', transport: transport).generateContent([AiContent.text('x')]);
    expect(response.text, 'hello');
    expect(response.finishReason, 'STOP');
    expect(response.usage!.promptTokenCount, 3);
    expect(response.usage!.totalTokenCount, 4);
  });

  test('generateContentStream yields only the text chunks', () async {
    final transport = FakeTransport()
      ..events = const [
        AiStreamChunk('Hel'),
        AiStreamChunk('lo'),
        AiStreamResult({'text': 'Hello'}),
      ];
    final chunks = await AiModel(appId: 'a', groupId: 'g', transport: transport)
        .generateContentStream([AiContent.text('x')])
        .map((r) => r.text)
        .toList();
    expect(chunks, ['Hel', 'lo']);
  });

  group('AiChatSession', () {
    test('sends history before the new message and records each exchange', () async {
      final transport = FakeTransport()..result = {'text': 'first reply'};
      final chat = AiModel(appId: 'ai-chat', groupId: 'g', transport: transport).startChat(history: [
        AiContent('user', const [AiTextPart('earlier')]),
        AiContent('model', const [AiTextPart('earlier reply')]),
      ]);

      final reply = await chat.sendMessage(AiContent.text('now'));
      expect(reply.text, 'first reply');
      final sent = transport.requests.single['contents'] as List;
      expect(sent.map((c) => (c as Map)['role']), ['user', 'model', 'user']);
      expect(chat.history.map((c) => c.text), ['earlier', 'earlier reply', 'now', 'first reply']);
    });

    test('sendMessageStream yields chunks and appends the final text to history', () async {
      final transport = FakeTransport()
        ..events = const [
          AiStreamChunk('a'),
          AiStreamChunk('b'),
          AiStreamResult({'text': 'ab'}),
        ];
      final chat = AiModel(appId: 'ai-chat', groupId: 'g', transport: transport).startChat();
      final chunks = await chat.sendMessageStream(AiContent.text('q')).map((r) => r.text).toList();
      expect(chunks, ['a', 'b']);
      expect(chat.history.map((c) => '${c.role}:${c.text}'), ['user:q', 'model:ab']);
    });

    test('a failed stream leaves history unchanged', () async {
      final transport = _FailingTransport();
      final chat = AiModel(appId: 'ai-chat', groupId: 'g', transport: transport).startChat();
      await expectLater(chat.sendMessageStream(AiContent.text('q')).toList(), throwsA(isA<StateError>()));
      expect(chat.history, isEmpty);
    });
  });
}

void _incompleteStreamTests() {
  group('a stream that ends without the final result', () {
    // cloud_functions 6.2 on Android ends the stream silently when the server
    // sends an error frame, so "done without a result" must be a failure.
    FakeTransport silentEnd() => FakeTransport()..events = const [AiStreamChunk('par'), AiStreamChunk('tial')];

    test('errors generateContentStream after the chunks it did get', () async {
      final chunks = <String?>[];
      await expectLater(
        AiModel(appId: 'a', groupId: 'g', transport: silentEnd())
            .generateContentStream([AiContent.text('x')])
            .map((r) => chunks.add(r.text))
            .drain<void>(),
        throwsA(isA<AiException>()),
      );
      expect(chunks, ['par', 'tial']);
    });

    test('errors sendMessageStream and leaves history unchanged', () async {
      final chat = AiModel(appId: 'ai-chat', groupId: 'g', transport: silentEnd()).startChat(history: [
        AiContent('user', const [AiTextPart('earlier')]),
        AiContent('model', const [AiTextPart('earlier reply')]),
      ]);
      await expectLater(chat.sendMessageStream(AiContent.text('q')).drain<void>(), throwsA(isA<AiException>()));
      expect(chat.history.map((c) => c.text), ['earlier', 'earlier reply']);
    });
  });

  group('empty replies never become model turns', () {
    test('streaming', () async {
      final transport = FakeTransport()..events = const [AiStreamResult({'text': ''})];
      final chat = AiModel(appId: 'ai-chat', groupId: 'g', transport: transport).startChat();
      await chat.sendMessageStream(AiContent.text('q')).drain<void>();
      expect(chat.history, isEmpty);
    });

    test('one-shot', () async {
      final transport = FakeTransport()..result = {'text': '  '};
      final chat = AiModel(appId: 'ai-chat', groupId: 'g', transport: transport).startChat();
      await chat.sendMessage(AiContent.text('q'));
      expect(chat.history, isEmpty);
    });
  });

  test('with no group, requests fail fast on the client and send nothing', () async {
    final transport = FakeTransport();
    final model = AiModel(appId: 'a', groupId: '', transport: transport);
    expect(model.groupId, isNull);
    await expectLater(model.generateContent([AiContent.text('x')]), throwsA(isA<AiException>()));
    await expectLater(model.generateContentStream([AiContent.text('x')]).drain<void>(), throwsA(isA<AiException>()));
    await expectLater(model.startChat().sendMessageStream(AiContent.text('x')).drain<void>(), throwsA(isA<AiException>()));
    expect(transport.requests, isEmpty);
    expect(const AiException.noGroup().toString(), 'Select a group to use AI features.');
  });
}

class _FailingTransport extends FakeTransport {
  @override
  Stream<AiStreamEvent> stream(Map<String, Object?> request) async* {
    yield const AiStreamChunk('partial');
    throw StateError('boom');
  }
}
