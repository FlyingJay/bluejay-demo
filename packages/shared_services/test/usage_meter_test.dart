import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/usage_meter.dart';

class _Harness {
  DateTime now = DateTime.utc(2026, 11, 4, 12);
  final written = <UsageDayEntry>[];
  late final UsageMeter meter = UsageMeter(clock: () => now, writer: (e) async => written.add(e));

  void advance(Duration d) => now = now.add(d);

  /// metric totals across everything written, per app.
  Map<String, Map<String, num>> get totals {
    final out = <String, Map<String, num>>{};
    for (final e in written) {
      for (final app in e.apps.entries) {
        final m = out.putIfAbsent(app.key, () => {});
        for (final kv in app.value.entries) {
          m[kv.key] = (m[kv.key] ?? 0) + kv.value;
        }
      }
    }
    return out;
  }
}

void main() {
  test('sessionOpens lists opened apps per group right away, and resets for another user', () {
    final h = _Harness()
      ..meter.setUser('u1')
      ..meter.setGroup('g');
    h.meter.beginSession('notes');
    h.meter.setGroup('h');
    h.meter.beginSession('chat');
    expect(h.meter.sessionOpens.value, {'g/notes', 'h/chat'});
    expect(h.written, isEmpty);
    h.meter.setUser('u2');
    expect(h.meter.sessionOpens.value, isEmpty);
  });

  test('records nothing without a user or an active group', () {
    final h = _Harness();
    h.meter.record('notes', 'opens');
    h.meter.setUser('u1');
    h.meter.record('notes', 'opens');
    h.meter.flush();
    expect(h.written, isEmpty);

    h.meter.setGroup('bluejay');
    h.meter.record('notes', 'opens');
    h.meter.flush();
    expect(h.written.single.docId, '2026-11-04_bluejay_u1');
    expect(h.totals, {
      'notes': {'opens': 1},
    });
  });

  test('buffers into one entry per (day, group, user) until flushed', () {
    final h = _Harness()
      ..meter.setUser('u1')
      ..meter.setGroup('g');
    h.meter.record('notes', 'fsReads', 3);
    h.meter.record('notes', 'fsReads', 2);
    h.meter.record('chat', 'opens');
    expect(h.written, isEmpty);
    expect(h.meter.pendingEntries, hasLength(1));
    h.meter.flush();
    expect(h.written, hasLength(1));
    expect(h.totals, {
      'notes': {'fsReads': 5},
      'chat': {'opens': 1},
    });
    h.meter.flush();
    expect(h.written, hasLength(1), reason: 'nothing new to write');
  });

  test('sessions count an open and accrue active time to the top app only', () {
    final h = _Harness()
      ..meter.setUser('u1')
      ..meter.setGroup('g');
    final notes = h.meter.beginSession('notes');
    h.advance(const Duration(seconds: 30));
    final chat = h.meter.beginSession('chat'); // opened on top of notes
    h.advance(const Duration(seconds: 20));
    h.meter.endSession(chat);
    h.meter.markInteraction();
    h.advance(const Duration(seconds: 10));
    h.meter.endSession(notes);
    h.meter.flush();
    expect(h.totals, {
      'notes': {'opens': 1, 'activeSec': 40},
      'chat': {'opens': 1, 'activeSec': 20},
    });
  });

  test('currentAppId is the top-most open app', () {
    final meter = _Harness().meter;
    expect(meter.currentAppId, isNull);
    final notes = meter.beginSession('notes');
    final chat = meter.beginSession('chat');
    expect(meter.currentAppId, 'chat');
    meter.endSession(chat);
    expect(meter.currentAppId, 'notes');
    meter.endSession(notes);
    expect(meter.currentAppId, isNull);
  });

  test('active time stops accruing idleGrace after the last input, across flushes', () {
    final h = _Harness()
      ..meter.setUser('u1')
      ..meter.setGroup('g');
    h.meter.beginSession('notes');
    // Idle for 20 minutes with periodic flushes every 5.
    for (var i = 0; i < 4; i++) {
      h.advance(const Duration(minutes: 5));
      h.meter.flush();
    }
    expect(h.totals['notes']!['activeSec'], UsageMeter.idleGrace.inSeconds);
    h.meter.markInteraction();
    h.advance(const Duration(seconds: 45));
    h.meter.flush();
    expect(h.totals['notes']!['activeSec'], UsageMeter.idleGrace.inSeconds + 45);
  });

  test('backgrounding stops accrual and flushes; resuming restarts it', () {
    final h = _Harness()
      ..meter.setUser('u1')
      ..meter.setGroup('g');
    h.meter.beginSession('notes');
    h.advance(const Duration(seconds: 10));
    h.meter.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(h.written, isNotEmpty, reason: 'flushed on background');
    h.advance(const Duration(hours: 1));
    h.meter.didChangeAppLifecycleState(AppLifecycleState.resumed);
    h.advance(const Duration(seconds: 5));
    h.meter.flush();
    expect(h.totals['notes']!['activeSec'], 15);
  });

  test('switching group closes out time against the previous group', () {
    final h = _Harness()
      ..meter.setUser('u1')
      ..meter.setGroup('g1');
    h.meter.beginSession('notes');
    h.advance(const Duration(seconds: 10));
    h.meter.setGroup('g2');
    h.advance(const Duration(seconds: 4));
    h.meter.flush();
    final byDoc = {for (final e in h.written) e.docId: e.apps['notes']};
    expect(byDoc['2026-11-04_g1_u1'], {'opens': 1, 'activeSec': 10});
    expect(byDoc['2026-11-04_g2_u1'], {'activeSec': 4});
  });

  test('a user switch drops the previous user\'s unflushed entries instead of writing them as the new user', () {
    final h = _Harness()
      ..meter.setUser('u1')
      ..meter.setGroup('g');
    h.meter.record('notes', 'opens');
    h.meter.setUser('u2');
    h.meter.record('notes', 'opens');
    h.meter.flush();
    expect(h.written.map((e) => e.uid), ['u2']);
  });

  test('flushAndWait waits for the writes to be acknowledged', () async {
    final acked = <String>[];
    final meter = UsageMeter(
      clock: () => DateTime.utc(2026, 11, 4),
      writer: (e) async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        acked.add(e.docId);
      },
    )
      ..setUser('u1')
      ..setGroup('g');
    meter.record('notes', 'opens');
    await meter.flushAndWait();
    expect(acked, ['2026-11-04_g_u1']);
  });

  test('resuming input after idle does not credit the idle gap a flush reopened', () {
    final h = _Harness()
      ..meter.setUser('u1')
      ..meter.setGroup('g');
    h.meter.beginSession('notes'); // input at t=0
    h.advance(const Duration(minutes: 25));
    h.meter.flush(); // credits the 2-min grace, reopens a segment at t=25
    h.advance(const Duration(minutes: 2));
    h.meter.markInteraction(); // back at t=27
    h.advance(const Duration(minutes: 3));
    h.meter.flush(); // t=30: only 27..29 (grace after the new input) counts
    expect(h.totals['notes']!['activeSec'], const Duration(minutes: 4).inSeconds);
  });

  test('days are bucketed in UTC', () {
    expect(UsageMeter.utcDateKey(DateTime.parse('2026-11-04T23:30:00-05:00')), '2026-11-05');
  });

  test('buildDocData carries the identity fields the server also writes', () {
    final entry = UsageDayEntry(date: '2026-11-04', groupId: 'g', uid: 'u')..add('notes', 'opens', 1);
    final data = UsageMeter.buildDocData(entry);
    expect(data['date'], '2026-11-04');
    expect(data['groupId'], 'g');
    expect(data['uid'], 'u');
    expect(data['appId'], 'usage-meter');
    expect(data['creatorId'], 'u');
    expect(data['ownerIds'], ['u']);
    expect((data['apps'] as Map).keys, ['notes']);
  });

  testWidgets('UsageSessionScope begins on mount and ends on dispose', (tester) async {
    final h = _Harness()
      ..meter.setUser('u1')
      ..meter.setGroup('g');
    await tester.pumpWidget(UsageSessionScope(appId: 'notes', meter: h.meter, child: const SizedBox()));
    h.advance(const Duration(seconds: 7));
    await tester.pumpWidget(const SizedBox());
    h.meter.flush();
    expect(h.totals, {
      'notes': {'opens': 1, 'activeSec': 7},
    });
  });
}
