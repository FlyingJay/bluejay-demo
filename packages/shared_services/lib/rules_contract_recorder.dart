/// Records the Firestore operations the client shim issues, as rules
/// "contracts" (plans/firestore-rules/IMPLEMENTATION_PLAN.md §6.3).
///
/// Off unless a [sink] is installed. A test (or a debug build) installs one,
/// runs the package's existing tests, and writes what it collected to
/// `security/contracts/<appId>.json`; the rules suite replays each descriptor
/// against the emulator under the personas that should (and shouldn't)
/// succeed.
///
/// Each descriptor looks like:
///
/// ```json
/// {"app": "notes", "op": "list", "path": "notes",
///  "filters": [["groupId", "==", "$G"]], "writeKeys": []}
/// ```
///
/// `$G` and `$UID` stand for the active group and the signed-in user.
///
/// What ScopedCollection records today: the base filters of [query] and
/// friends (`list`), the keys of its writes (`create`/`update`/`set`), and
/// natural-key reads (`get`). TODO(T18): record the filters and orderBys a
/// caller chains onto the query (MeteredQuery), and MeteredFirestore's /
/// ScopedStorage's raw operations, for full contracts and shadow replay.
library;

/// Receives one contract descriptor.
typedef RulesContractSink = void Function(Map<String, Object?> descriptor);

class RulesContractRecorder {
  RulesContractRecorder._();

  /// Where descriptors go; null (the default) records nothing.
  static RulesContractSink? sink;

  /// The placeholder for the active group in recorded values.
  static const group = r'$G';

  /// The placeholder for the signed-in user's uid in recorded values.
  static const user = r'$UID';

  static bool get isRecording => sink != null;

  /// Sends one descriptor to [sink], if one is installed. [path] uses `{id}`
  /// for document ids, so contracts don't depend on generated ids.
  static void record({
    required String app,
    required String op,
    required String path,
    List<List<Object?>> filters = const [],
    Iterable<String> writeKeys = const [],
  }) {
    final s = sink;
    if (s == null) return;
    s({
      'app': app,
      'op': op,
      'path': path,
      'filters': filters,
      'writeKeys': (writeKeys.toList()..sort()),
    });
  }
}
