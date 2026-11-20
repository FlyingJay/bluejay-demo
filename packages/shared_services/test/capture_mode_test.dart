import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/capture_mode.dart';

class _FakeUser implements fire_auth.User {
  _FakeUser(this.uid, {this.isAnonymous = false});

  @override
  final String uid;

  @override
  final bool isAnonymous;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final captureUri = Uri.parse('https://bluejay.gg/sunnyside/notes?capture=1');

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('without ?capture=1 nothing is hidden and auth is not watched', () {
    final mode = CaptureMode.forTesting();
    final auth = StreamController<fire_auth.User?>();
    mode.init(Uri.parse('https://bluejay.gg/sunnyside/notes'),
        authChanges: auth.stream);
    expect(mode.hidesChrome.value, isFalse);
    expect(mode.confirmed.value, isFalse);
    expect(auth.hasListener, isFalse);
  });

  test('a demo account hides chrome and shows the marker', () async {
    final mode = CaptureMode.forTesting();
    final auth = StreamController<fire_auth.User?>();
    mode.init(captureUri,
        authChanges: auth.stream,
        demoAccountChanges: (uid) => Stream.value(uid == 'demo'));
    expect(mode.hidesChrome.value, isTrue,
        reason: 'hidden while the check is pending');
    auth.add(_FakeUser('demo'));
    await settle();
    expect(mode.hidesChrome.value, isTrue);
    expect(mode.confirmed.value, isTrue);
  });

  test('a real account keeps its chrome even with ?capture=1', () async {
    final mode = CaptureMode.forTesting();
    final auth = StreamController<fire_auth.User?>();
    mode.init(captureUri,
        authChanges: auth.stream,
        demoAccountChanges: (uid) => Stream.value(false));
    auth.add(_FakeUser('real'));
    await settle();
    expect(mode.hidesChrome.value, isFalse);
    expect(mode.confirmed.value, isFalse);
  });

  test('a failed lookup or a guest counts as not a demo account', () async {
    final mode = CaptureMode.forTesting();
    final auth = StreamController<fire_auth.User?>();
    mode.init(captureUri,
        authChanges: auth.stream,
        demoAccountChanges: (uid) => Stream.error('offline'));
    auth.add(_FakeUser('real'));
    await settle();
    expect(mode.hidesChrome.value, isFalse);
    auth.add(_FakeUser('guest', isAnonymous: true));
    await settle();
    expect(mode.hidesChrome.value, isFalse);
    expect(mode.confirmed.value, isFalse);
  });

  test('a stale lookup does not override a newer user', () async {
    final mode = CaptureMode.forTesting();
    final auth = StreamController<fire_auth.User?>();
    final slow = Completer<bool>();
    mode.init(captureUri,
        authChanges: auth.stream,
        demoAccountChanges: (uid) => uid == 'slow'
            ? Stream.fromFuture(slow.future)
            : Stream.value(false));
    auth.add(_FakeUser('slow'));
    await settle();
    auth.add(_FakeUser('real'));
    await settle();
    slow.complete(true);
    await settle();
    expect(mode.confirmed.value, isFalse);
    expect(mode.hidesChrome.value, isFalse);
  });

  test('follows the users doc: a later isDemo change turns it on', () async {
    final mode = CaptureMode.forTesting();
    final auth = StreamController<fire_auth.User?>();
    final doc = StreamController<bool>();
    mode.init(captureUri,
        authChanges: auth.stream, demoAccountChanges: (uid) => doc.stream);
    auth.add(_FakeUser('demo'));
    await settle();
    expect(mode.hidesChrome.value, isTrue,
        reason: 'hidden until the doc arrives');
    doc.add(false);
    await settle();
    expect(mode.hidesChrome.value, isFalse);
    doc.add(true);
    await settle();
    expect(mode.confirmed.value, isTrue);
    expect(mode.hidesChrome.value, isTrue);
  });

  test('falls back to off when no server snapshot arrives in time', () async {
    final mode = CaptureMode.forTesting();
    final auth = StreamController<fire_auth.User?>();
    final doc = StreamController<bool>();
    mode.init(captureUri,
        authChanges: auth.stream,
        demoAccountChanges: (uid) => doc.stream,
        checkTimeout: const Duration(milliseconds: 50));
    auth.add(_FakeUser('demo'));
    await settle();
    expect(mode.hidesChrome.value, isTrue, reason: 'hidden while waiting');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(mode.hidesChrome.value, isFalse);
    expect(mode.confirmed.value, isFalse);
    doc.add(true);
    await settle();
    expect(mode.confirmed.value, isTrue,
        reason: 'a late snapshot still counts');
  });

  test('a snapshot in time cancels the fallback', () async {
    final mode = CaptureMode.forTesting();
    final auth = StreamController<fire_auth.User?>();
    mode.init(captureUri,
        authChanges: auth.stream,
        demoAccountChanges: (uid) => Stream.value(true),
        checkTimeout: const Duration(milliseconds: 50));
    auth.add(_FakeUser('demo'));
    await settle();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(mode.confirmed.value, isTrue);
    expect(mode.hidesChrome.value, isTrue);
  });

  test('withoutFlag drops only the capture parameter', () {
    expect(CaptureMode.withoutFlag({'capture': '1', 'itemId': 'x'}),
        {'itemId': 'x'});
    expect(CaptureMode.withoutFlag({'capture': '1'}), isEmpty);
  });

  testWidgets('the marker toggles without remounting the app', (tester) async {
    final semantics = tester.ensureSemantics();
    final confirmed = CaptureMode.instance.confirmed;
    addTearDown(() => confirmed.value = false);
    await tester.pumpWidget(const MaterialApp(
      home: CaptureModeMarker(child: _Counter()),
    ));
    await tester.tap(find.text('0'));
    await tester.pump();
    expect(find.bySemanticsLabel(CaptureMode.markerLabel), findsNothing);

    confirmed.value = true;
    await tester.pump();
    expect(find.bySemanticsLabel(CaptureMode.markerLabel), findsOneWidget);
    expect(find.text('1'), findsOneWidget, reason: 'state kept');

    confirmed.value = false;
    await tester.pump();
    expect(find.bySemanticsLabel(CaptureMode.markerLabel), findsNothing);
    semantics.dispose();
  });
}

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int _count = 0;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () => setState(() => _count++),
        child: Text('$_count'),
      );
}
