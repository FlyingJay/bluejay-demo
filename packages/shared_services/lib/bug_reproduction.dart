// ─────────────────────────────────────────────────────────────────────────────
// Bug reproduction details
//
// Every bug report (top-level `bug_reports`, appId 'improve-apps') filed by a
// person must say how to reproduce the problem. This is the single source of
// truth for the field names, the minimum, and the worked example; the form
// section (shared_ui/bug_reproduction_fields.dart) and every create/edit path
// use it, and functions/_bug_reproduction.js mirrors the same names and
// minimum for server-side creation (projectsCreateChangeRequest) and the
// coding-agent dispatch payload. Keep the two in sync.
//
// The fields are optional on read: tickets filed before the requirement
// existed simply don't have them.
// ─────────────────────────────────────────────────────────────────────────────

/// Structured reproduction details stored on a `bug_reports` doc.
class BugReproduction {
  /// Firestore field: numbered steps that trigger the bug. Required on create.
  static const String stepsField = 'stepsToReproduce';

  /// Firestore field: what the reporter expected to happen. Optional.
  static const String expectedField = 'expectedBehavior';

  /// Firestore field: what actually happened instead. Optional.
  static const String actualField = 'actualBehavior';

  static const List<String> fields = [stepsField, expectedField, actualField];

  /// Minimum length (after trimming and collapsing whitespace) of
  /// [stepsToReproduce]. Long enough to reject "n/a", "idk" or "see above",
  /// short enough that one concrete action ("Open Photos, tap Upload") passes.
  static const int minStepsLength = 20;

  final String stepsToReproduce;
  final String expectedBehavior;
  final String actualBehavior;

  const BugReproduction({
    this.stepsToReproduce = '',
    this.expectedBehavior = '',
    this.actualBehavior = '',
  });

  /// Reads the fields from a `bug_reports` doc; absent or non-string fields
  /// read as empty, so legacy tickets work unchanged.
  factory BugReproduction.fromData(Map<String, dynamic>? data) {
    String read(String key) {
      final value = data?[key];
      return value is String ? value.trim() : '';
    }

    return BugReproduction(
      stepsToReproduce: read(stepsField),
      expectedBehavior: read(expectedField),
      actualBehavior: read(actualField),
    );
  }

  /// True when no field has any content (e.g. a legacy ticket).
  bool get isEmpty =>
      stepsToReproduce.trim().isEmpty &&
      expectedBehavior.trim().isEmpty &&
      actualBehavior.trim().isEmpty;

  bool get isNotEmpty => !isEmpty;

  /// The fields to write on create: trimmed, empty optional fields omitted.
  Map<String, String> toCreateFields() {
    final out = <String, String>{};
    final steps = stepsToReproduce.trim();
    final expected = expectedBehavior.trim();
    final actual = actualBehavior.trim();
    if (steps.isNotEmpty) out[stepsField] = steps;
    if (expected.isNotEmpty) out[expectedField] = expected;
    if (actual.isNotEmpty) out[actualField] = actual;
    return out;
  }

  /// The fields to write on update: every field is written, so clearing an
  /// optional field in the edit form clears it on the doc too. [deleteValue]
  /// is what an emptied field is set to (pass `FieldValue.delete()`).
  Map<String, Object> toUpdateFields({required Object deleteValue}) {
    final present = toCreateFields();
    return {for (final key in fields) key: present[key] ?? deleteValue};
  }

  /// Why the steps don't meet the minimum, or null when they do.
  ///
  /// With [requireSteps] false (edit paths for tickets filed before the
  /// requirement, and admin triage edits) empty steps are allowed, but
  /// anything entered must still meet the minimum.
  String? validate({bool requireSteps = true}) =>
      validateSteps(stepsToReproduce, requireSteps: requireSteps);

  /// Field-level validator for the steps text; null when valid.
  static String? validateSteps(String? value, {bool requireSteps = true}) {
    final normalized = (value ?? '').trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) {
      return requireSteps ? 'Add the steps to reproduce the problem.' : null;
    }
    if (normalized.length < minStepsLength) {
      return 'Add a bit more detail — list each step you took '
          '(at least $minStepsLength characters).';
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is BugReproduction &&
      other.stepsToReproduce == stepsToReproduce &&
      other.expectedBehavior == expectedBehavior &&
      other.actualBehavior == actualBehavior;

  @override
  int get hashCode =>
      Object.hash(stepsToReproduce, expectedBehavior, actualBehavior);
}

/// The worked example shown under "See an example" on every bug form.
class BugReproductionExample {
  BugReproductionExample._();

  static const String summary = "Can't upload a PDF to a shared folder";

  static const String steps =
      '1. Open Storage\n'
      '2. Open the "Receipts" folder\n'
      '3. Choose a 2.8 MB PDF from Files on Safari (iPad)\n'
      '4. Tap "Upload"';

  static const String expected = 'The file uploads and appears in the folder.';

  static const String actual =
      'A red banner says "Upload failed" and the file isn\'t added.';

  static const String tips =
      'Also mention your device and browser, and attach a screenshot if '
      'you can.';

  /// Placeholder text for the three fields.
  static const String stepsHint = '1. Open …\n2. Tap …\n3. …';
  static const String expectedHint = 'e.g. The file uploads and I see it';
  static const String actualHint =
      'e.g. An error banner appears and nothing uploads';
}
