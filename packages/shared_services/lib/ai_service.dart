/// The one way apps call generative AI.
///
/// Requests go to the `aiGenerate` / `aiGenerateStream` Cloud Functions
/// (functions/ai_gateway.js), never straight to Gemini: the server holds the
/// API key, checks the caller can use [AiModel.appId] in their active group,
/// rate-limits, and records token usage for Usage Meter. CI
/// (scripts/check_gateways.js) rejects `GenerativeModel(` and
/// `package:google_generative_ai` anywhere else.
///
/// The API deliberately mirrors `google_generative_ai`'s `GenerativeModel`
/// (generateContent, generateContentStream, startChat / sendMessage /
/// sendMessageStream), so call sites read the same:
///
/// ```dart
/// final model = AiModel(appId: APP_ID, model: 'gemini-2.5-flash');
/// final response = await model.generateContent([AiContent.text(prompt)]);
/// print(response.text);
/// ```
///
/// Models: apps may name one of the server's allowlisted models (see
/// `CLIENT_MODELS` in functions/ai_gateway.js) or an [AiTier]; anything else
/// is rejected server-side.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';

import 'active_group_service.dart';
import 'package:shared_services/cloud_functions.dart';
import 'user_facing_error.dart';

/// A Remote-Config-resolved model tier. `pro` is server-only.
enum AiTier { lite, standard }

/// One piece of a message.
sealed class AiPart {
  const AiPart();
  Map<String, Object?> toJson();
}

class AiTextPart extends AiPart {
  final String text;
  const AiTextPart(this.text);

  @override
  Map<String, Object?> toJson() => {'text': text};
}

/// Inline binary data (an image, a PDF, ...), sent base64-encoded. The server
/// caps the total per request (about 14 MB).
///
/// Office files the model can't read directly (.xlsx/.xls/.xlsm/.xlsb/.ods
/// spreadsheets and .docx documents) are accepted too: the gateway converts
/// them to text before calling the model (functions/_ai_document_text.js), so
/// callers pass them through unchanged.
class AiDataPart extends AiPart {
  final String mimeType;
  final Uint8List bytes;
  const AiDataPart(this.mimeType, this.bytes);

  @override
  Map<String, Object?> toJson() => {
        'inlineData': {'mimeType': mimeType, 'data': base64Encode(bytes)},
      };
}

/// One message: a [role] (`user` or `model`) and its [parts].
class AiContent {
  final String role;
  final List<AiPart> parts;

  const AiContent(this.role, this.parts);

  /// A user message of plain text (`Content.text` in google_generative_ai).
  AiContent.text(String text) : this('user', [AiTextPart(text)]);

  AiContent.user(this.parts) : role = 'user';
  AiContent.model(this.parts) : role = 'model';

  /// The concatenated text parts.
  String get text => parts.whereType<AiTextPart>().map((p) => p.text).join();

  Map<String, Object?> toJson() => {
        'role': role,
        'parts': [for (final p in parts) p.toJson()],
      };
}

/// Generation options. `responseMimeType: 'application/json'` is JSON mode.
class AiGenerationConfig {
  final String? responseMimeType;
  final Map<String, Object?>? responseSchema;
  final double? temperature;
  final double? topP;
  final int? topK;
  final int? maxOutputTokens;
  final List<String>? stopSequences;

  const AiGenerationConfig({
    this.responseMimeType,
    this.responseSchema,
    this.temperature,
    this.topP,
    this.topK,
    this.maxOutputTokens,
    this.stopSequences,
  });

  Map<String, Object?> toJson() => {
        if (responseMimeType != null) 'responseMimeType': responseMimeType,
        if (responseSchema != null) 'responseSchema': responseSchema,
        if (temperature != null) 'temperature': temperature,
        if (topP != null) 'topP': topP,
        if (topK != null) 'topK': topK,
        if (maxOutputTokens != null) 'maxOutputTokens': maxOutputTokens,
        if (stopSequences != null) 'stopSequences': stopSequences,
      };
}

/// A safety threshold for one harm category, using Gemini's enum names
/// (e.g. `HARM_CATEGORY_HARASSMENT` / `BLOCK_ONLY_HIGH`).
class AiSafetySetting {
  final String category;
  final String threshold;
  const AiSafetySetting(this.category, this.threshold);

  Map<String, Object?> toJson() => {'category': category, 'threshold': threshold};
}

class AiUsage {
  final int promptTokenCount;
  final int candidatesTokenCount;
  final int thoughtsTokenCount;
  final int totalTokenCount;

  const AiUsage({
    this.promptTokenCount = 0,
    this.candidatesTokenCount = 0,
    this.thoughtsTokenCount = 0,
    this.totalTokenCount = 0,
  });

  factory AiUsage.fromJson(Map<String, Object?> json) => AiUsage(
        promptTokenCount: _int(json['promptTokenCount']),
        candidatesTokenCount: _int(json['candidatesTokenCount']),
        thoughtsTokenCount: _int(json['thoughtsTokenCount']),
        totalTokenCount: _int(json['totalTokenCount']),
      );

  static int _int(Object? v) => v is num ? v.toInt() : 0;
}

/// A generation result, or (from a stream) one chunk of it. Chunks carry
/// only [text].
class AiResponse {
  final String? text;
  final String? model;
  final String? finishReason;
  final AiUsage? usage;

  const AiResponse({this.text, this.model, this.finishReason, this.usage});

  factory AiResponse.fromJson(Map<String, Object?> json) {
    final usage = json['usage'];
    return AiResponse(
      text: json['text'] as String?,
      model: json['model'] as String?,
      finishReason: json['finishReason'] as String?,
      usage: usage is Map ? AiUsage.fromJson(_stringKeyed(usage)) : null,
    );
  }
}

/// What a transport stream emits: text chunks, then the final result.
sealed class AiStreamEvent {
  const AiStreamEvent();
}

class AiStreamChunk extends AiStreamEvent {
  final String text;
  const AiStreamChunk(this.text);
}

class AiStreamResult extends AiStreamEvent {
  final Map<String, Object?> result;
  const AiStreamResult(this.result);
}

/// How requests reach the server. [FirebaseAiTransport] in the app; a fake
/// in tests.
abstract class AiTransport {
  Future<Map<String, Object?>> generate(Map<String, Object?> request);
  Stream<AiStreamEvent> stream(Map<String, Object?> request);
}

class FirebaseAiTransport implements AiTransport {
  /// Long enough for a multi-page document; matches the functions' timeout.
  static const timeout = Duration(minutes: 5);

  final FirebaseFunctions? _functionsOverride;
  const FirebaseAiTransport({FirebaseFunctions? functions}) : _functionsOverride = functions;

  FirebaseFunctions get _functions => _functionsOverride ?? BluejayFunctions.instance;

  @override
  Future<Map<String, Object?>> generate(Map<String, Object?> request) async {
    final result = await _functions
        .httpsCallable('aiGenerate', options: HttpsCallableOptions(timeout: timeout))
        .call<Object?>(request);
    return _stringKeyed(result.data);
  }

  @override
  Stream<AiStreamEvent> stream(Map<String, Object?> request) async* {
    final callable =
        _functions.httpsCallable('aiGenerateStream', options: HttpsCallableOptions(timeout: timeout));
    await for (final event in callable.stream<Object?, Object?>(request)) {
      switch (event) {
        case Chunk(:final partialData):
          final text = _stringKeyed(partialData)['text'];
          if (text is String && text.isNotEmpty) yield AiStreamChunk(text);
        case Result(:final result):
          yield AiStreamResult(_stringKeyed(result.data));
      }
    }
  }
}

/// A configured model — the replacement for google_generative_ai's
/// `GenerativeModel`.
class AiModel {
  /// The app spending the tokens. The caller must be entitled to it in
  /// [groupId] (default: the active group).
  final String appId;

  /// An allowlisted model id (e.g. `gemini-2.5-flash`). Overrides [tier].
  final String? model;
  final AiTier? tier;
  final String? systemInstruction;
  final AiGenerationConfig? generationConfig;
  final List<AiSafetySetting>? safetySettings;
  final String? _groupId;
  final AiTransport _transport;

  AiModel({
    required this.appId,
    this.model,
    this.tier,
    this.systemInstruction,
    this.generationConfig,
    this.safetySettings,
    String? groupId,
    AiTransport? transport,
  })  : _groupId = groupId,
        _transport = transport ?? const FirebaseAiTransport();

  /// The group the tokens are spent in: the one passed in, else the active
  /// group. Null when neither is set; requests then fail fast with
  /// [AiException.noGroup] rather than reaching the server.
  String? get groupId {
    final id = _groupId ?? ActiveGroupService.instance.activeGroupId;
    return (id == null || id.isEmpty) ? null : id;
  }

  /// The request payload sent to the gateway for [contents].
  ///
  /// Throws [AiException] when there's no group to spend tokens in.
  Map<String, Object?> buildRequest(Iterable<AiContent> contents) {
    final group = groupId;
    if (group == null) throw const AiException.noGroup();
    return {
      'appId': appId,
      'groupId': group,
      if (model != null) 'model': model,
      if (model == null && tier != null) 'tier': tier!.name,
      'contents': [for (final c in contents) c.toJson()],
      if (systemInstruction != null && systemInstruction!.isNotEmpty) 'systemInstruction': systemInstruction,
      if (generationConfig != null) 'generationConfig': generationConfig!.toJson(),
      if (safetySettings != null) 'safetySettings': [for (final s in safetySettings!) s.toJson()],
    };
  }

  Future<AiResponse> generateContent(Iterable<AiContent> contents) async {
    final request = buildRequest(contents);
    return AiResponse.fromJson(await _transport.generate(request));
  }

  /// Streams the reply as text chunks (each an [AiResponse] with only
  /// `text`). Chunk sizes are whatever Gemini emits. Errors with
  /// [AiException] if the stream ends without the server's final result.
  Stream<AiResponse> generateContentStream(Iterable<AiContent> contents) async* {
    final request = buildRequest(contents);
    await for (final event in _stream(request)) {
      if (event.isChunk) yield event.response;
    }
  }

  /// Transport events as chunks then exactly one final result. A stream
  /// that finishes without the result is a failure: some platforms (Android
  /// in cloud_functions 6.2) end the stream silently when the server sends
  /// an error, and treating that as success would lose the error and leave
  /// a truncated or empty reply.
  Stream<_Event> _stream(Map<String, Object?> request) async* {
    var gotResult = false;
    await for (final event in _transport.stream(request)) {
      switch (event) {
        case AiStreamChunk(:final text):
          yield _Event(AiResponse(text: text), isChunk: true);
        case AiStreamResult(:final result):
          gotResult = true;
          yield _Event(AiResponse.fromJson(result), isChunk: false);
      }
    }
    if (!gotResult) throw const AiException.incomplete();
  }

  /// A multi-turn chat seeded with [history].
  AiChatSession startChat({List<AiContent>? history}) => AiChatSession._(this, history ?? const []);
}

/// A failure detected on the client: no group to spend tokens in, or a reply
/// that never completed. Server-side failures arrive as
/// `FirebaseFunctionsException`s. [message] is written for the user, so
/// `userFacingError` shows it as is.
class AiException implements UserFacingException {
  final String message;
  const AiException(this.message);

  const AiException.noGroup() : message = 'Select a group to use AI features.';
  const AiException.incomplete() : message = "The AI reply didn't finish. Please try again.";

  @override
  String get userMessage => message;

  @override
  String toString() => message;
}

class _Event {
  final AiResponse response;
  final bool isChunk;
  const _Event(this.response, {required this.isChunk});
}

/// Multi-turn chat, mirroring google_generative_ai's `ChatSession`: each
/// completed exchange is appended to [history]. A failed or empty reply
/// leaves history unchanged, so no empty model turn is ever sent back.
class AiChatSession {
  final AiModel _model;
  final List<AiContent> _history;

  AiChatSession._(this._model, List<AiContent> history) : _history = List.of(history);

  List<AiContent> get history => List.unmodifiable(_history);

  void _record(AiContent message, String? reply) {
    if (reply == null || reply.trim().isEmpty) return;
    _history
      ..add(message)
      ..add(AiContent.model([AiTextPart(reply)]));
  }

  Future<AiResponse> sendMessage(AiContent message) async {
    final response = await _model.generateContent([..._history, message]);
    _record(message, response.text);
    return response;
  }

  /// Streams the reply; the exchange joins [history] once the stream
  /// completes with the server's final result.
  Stream<AiResponse> sendMessageStream(AiContent message) async* {
    final request = _model.buildRequest([..._history, message]);
    String? finalText;
    await for (final event in _model._stream(request)) {
      if (event.isChunk) {
        yield event.response;
      } else {
        finalText = event.response.text;
      }
    }
    _record(message, finalText);
  }
}

Map<String, Object?> _stringKeyed(Object? value) {
  if (value is Map) {
    return value.map((k, v) => MapEntry(k.toString(), v is Map ? _stringKeyed(v) : v));
  }
  return const {};
}
