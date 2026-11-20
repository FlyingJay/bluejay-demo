import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/note_autosave.dart';

void main() {
  testWidgets('saves once after edits go quiet', (t) async {
    var saves = 0;
    final autosaver = NoteAutosaver(save: () async => saves++);
    autosaver.schedule();
    await t.pump(const Duration(milliseconds: 1500));
    autosaver.schedule(); // another keystroke restarts the wait
    await t.pump(const Duration(milliseconds: 1500));
    expect(saves, 0);
    await t.pump(const Duration(milliseconds: 600));
    expect(saves, 1);
    expect(autosaver.isScheduled, isFalse);
  });

  testWidgets('cancel drops a pending save', (t) async {
    var saves = 0;
    final autosaver = NoteAutosaver(save: () async => saves++);
    autosaver.schedule();
    autosaver.cancel();
    await t.pump(const Duration(seconds: 5));
    expect(saves, 0);
  });

  testWidgets('flush saves now and skips the pending timer', (t) async {
    var saves = 0;
    final autosaver = NoteAutosaver(save: () async => saves++);
    autosaver.schedule();
    await autosaver.flush();
    expect(saves, 1);
    await t.pump(const Duration(seconds: 5));
    expect(saves, 1);
  });

  testWidgets('a flush during a save runs once more afterwards', (t) async {
    var started = 0;
    final gates = <Completer<void>>[];
    final autosaver = NoteAutosaver(save: () {
      started++;
      final gate = Completer<void>();
      gates.add(gate);
      return gate.future;
    });
    final first = autosaver.flush();
    unawaited(autosaver.flush());
    unawaited(autosaver.flush());
    expect(started, 1); // never two writes at once
    gates[0].complete();
    await t.pump();
    expect(started, 2); // the queued flushes collapse into one
    gates[1].complete();
    await first;
    expect(started, 2);
  });
}
