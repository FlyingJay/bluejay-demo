import 'dart:async';

/// Debounces autosaves for the note editor.
///
/// [schedule] restarts a quiet-period timer on every edit; when it fires,
/// [save] runs. [flush] saves straight away (used when the app is hidden).
/// Only one save runs at a time: a flush that arrives while one is in flight
/// runs once more after it finishes, so the latest text is always written.
/// [save] decides for itself whether there is anything to write.
///
/// Kept free of Firestore so it can be tested with fake time.
class NoteAutosaver {
  NoteAutosaver({
    required this.save,
    this.delay = const Duration(seconds: 2),
  });

  final Future<void> Function() save;
  final Duration delay;

  Timer? _timer;
  bool _inFlight = false;
  bool _again = false;

  /// Whether an autosave is waiting on the quiet-period timer.
  bool get isScheduled => _timer?.isActive ?? false;

  void schedule() {
    _timer?.cancel();
    _timer = Timer(delay, flush);
  }

  Future<void> flush() async {
    _timer?.cancel();
    if (_inFlight) {
      _again = true;
      return;
    }
    _inFlight = true;
    try {
      await save();
    } finally {
      _inFlight = false;
    }
    if (_again) {
      _again = false;
      await flush();
    }
  }

  /// Drops any pending autosave, e.g. when the user discards or deletes.
  void cancel() {
    _timer?.cancel();
    _again = false;
  }

  void dispose() => cancel();
}
