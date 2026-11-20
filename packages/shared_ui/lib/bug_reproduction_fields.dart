import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:shared_services/bug_reproduction.dart';

import 'readable_selectable_text.dart';

export 'package:shared_services/bug_reproduction.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Shared "how to reproduce" form section + read-only display for bug reports.
//
// Every surface that creates or edits a `bug_reports` doc embeds
// [BugReproductionFields] and validates through [BugReproductionController],
// so the requirement, wording and worked example are identical everywhere:
// Improve Apps' submit sheet and edit dialog (which the in-app "Request a
// change" tab also opens), Improve Apps Admin's create/edit sheets, and
// Projects' "Create change request" dialog. Detail views render the stored
// fields with [BugReproductionDetails].
// ─────────────────────────────────────────────────────────────────────────────

/// Holds the three text fields' controllers plus the steps error shown after
/// a failed [validate]. Dispose it with the owning State.
class BugReproductionController extends ChangeNotifier {
  final TextEditingController steps;
  final TextEditingController expected;
  final TextEditingController actual;

  String? _stepsError;

  BugReproductionController({BugReproduction initial = const BugReproduction()})
      : steps = TextEditingController(text: initial.stepsToReproduce),
        expected = TextEditingController(text: initial.expectedBehavior),
        actual = TextEditingController(text: initial.actualBehavior) {
    steps.addListener(_clearErrorOnEdit);
  }

  /// The steps error from the last [validate], cleared as soon as the user
  /// edits the steps.
  String? get stepsError => _stepsError;

  BugReproduction get value => BugReproduction(
        stepsToReproduce: steps.text,
        expectedBehavior: expected.text,
        actualBehavior: actual.text,
      );

  /// Validates the steps (see [BugReproduction.validate]), shows the error
  /// inline under the field, and returns it (null when valid).
  String? validate({bool requireSteps = true}) {
    final error = value.validate(requireSteps: requireSteps);
    if (error != _stepsError) {
      _stepsError = error;
      notifyListeners();
    }
    return error;
  }

  void clear() {
    steps.clear();
    expected.clear();
    actual.clear();
    _stepsError = null;
    notifyListeners();
  }

  void _clearErrorOnEdit() {
    if (_stepsError == null) return;
    _stepsError = null;
    notifyListeners();
  }

  @override
  void dispose() {
    steps.removeListener(_clearErrorOnEdit);
    steps.dispose();
    expected.dispose();
    actual.dispose();
    super.dispose();
  }
}

/// Builds the decoration for one field; defaults to the theme's input style
/// with [label] and [hint].
typedef BugReproductionDecorationBuilder = InputDecoration Function({
  required String label,
  required String hint,
});

/// The "Steps to reproduce" (required), "What did you expect?" and "What
/// happened instead?" fields, with an expandable worked example.
class BugReproductionFields extends StatelessWidget {
  final BugReproductionController controller;
  final bool enabled;

  /// Whether empty steps are rejected; only changes the label ("required"
  /// vs "recommended"). Pass the same value to [BugReproductionController.validate].
  final bool requireSteps;

  final BugReproductionDecorationBuilder? decoration;

  const BugReproductionFields({
    super.key,
    required this.controller,
    this.enabled = true,
    this.requireSteps = true,
    this.decoration,
  });

  static InputDecoration _defaultDecoration({
    required String label,
    required String hint,
  }) =>
      InputDecoration(labelText: label, hintText: hint);

  @override
  Widget build(BuildContext context) {
    final decorate = decoration ?? _defaultDecoration;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const BjFieldLabel(
            'How can we reproduce it?',
            icon: Icons.replay_rounded,
            helper: 'Bugs we can reproduce get fixed fastest. List exactly '
                'what you did, step by step.',
          ),
          const BugReproductionExampleCard(),
          const SizedBox(height: BjSpace.sm),
          TextField(
            key: const ValueKey('bugReproduction.steps'),
            controller: controller.steps,
            enabled: enabled,
            minLines: 3,
            maxLines: 8,
            keyboardType: TextInputType.multiline,
            decoration: decorate(
              label: requireSteps
                  ? 'Steps to reproduce (required)'
                  : 'Steps to reproduce',
              hint: BugReproductionExample.stepsHint,
            ).copyWith(
              errorText: controller.stepsError,
              errorMaxLines: 3,
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: BjSpace.md),
          TextField(
            key: const ValueKey('bugReproduction.expected'),
            controller: controller.expected,
            enabled: enabled,
            minLines: 1,
            maxLines: 4,
            keyboardType: TextInputType.multiline,
            decoration: decorate(
              label: 'What did you expect? (optional)',
              hint: BugReproductionExample.expectedHint,
            ),
          ),
          const SizedBox(height: BjSpace.md),
          TextField(
            key: const ValueKey('bugReproduction.actual'),
            controller: controller.actual,
            enabled: enabled,
            minLines: 1,
            maxLines: 4,
            keyboardType: TextInputType.multiline,
            decoration: decorate(
              label: 'What happened instead? (optional)',
              hint: BugReproductionExample.actualHint,
            ),
          ),
        ],
      ),
    );
  }
}

/// A collapsed "See an example" link that expands to a well-written report.
class BugReproductionExampleCard extends StatefulWidget {
  final bool initiallyExpanded;

  const BugReproductionExampleCard({super.key, this.initiallyExpanded = false});

  @override
  State<BugReproductionExampleCard> createState() =>
      _BugReproductionExampleCardState();
}

class _BugReproductionExampleCardState
    extends State<BugReproductionExampleCard> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final bj = context.bj;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton.icon(
          key: const ValueKey('bugReproduction.exampleToggle'),
          onPressed: () => setState(() => _expanded = !_expanded),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: BjSpace.sm),
            visualDensity: VisualDensity.compact,
          ),
          icon: Icon(
            _expanded
                ? Icons.expand_less_rounded
                : Icons.tips_and_updates_outlined,
            size: 18,
          ),
          label: Text(_expanded ? 'Hide example' : 'See an example'),
        ),
        AnimatedSize(
          duration: BjMotion.medium,
          curve: BjMotion.curve,
          alignment: Alignment.topCenter,
          child: !_expanded
              ? const SizedBox(width: double.infinity)
              : Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: BjSpace.xs),
                  padding: const EdgeInsets.all(BjSpace.md),
                  decoration: BoxDecoration(
                    gradient: bj.softGradient,
                    borderRadius: BjRadius.all(BjRadius.md),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'A good bug report',
                        style: text.labelLarge?.copyWith(color: bj.accent),
                      ),
                      const SizedBox(height: BjSpace.sm),
                      const _ExampleSection(
                        label: 'What went wrong',
                        text: BugReproductionExample.summary,
                      ),
                      const _ExampleSection(
                        label: 'Steps to reproduce',
                        text: BugReproductionExample.steps,
                      ),
                      const _ExampleSection(
                        label: 'Expected',
                        text: BugReproductionExample.expected,
                      ),
                      const _ExampleSection(
                        label: 'What happened instead',
                        text: BugReproductionExample.actual,
                      ),
                      Text(
                        BugReproductionExample.tips,
                        style: text.bodySmall?.copyWith(
                          fontStyle: FontStyle.italic,
                          color: BjNeutral.inkMuted,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

class _ExampleSection extends StatelessWidget {
  final String label;
  final String text;

  const _ExampleSection({required this.label, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: BjSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: theme.labelSmall?.copyWith(color: BjNeutral.inkMuted)),
          const SizedBox(height: BjSpace.xxs),
          Text(text,
              style: theme.bodySmall?.copyWith(color: BjNeutral.ink, height: 1.4)),
        ],
      ),
    );
  }
}

/// Read-only display of a bug's stored reproduction details. Renders nothing
/// for tickets without any (e.g. ones filed before the fields existed).
class BugReproductionDetails extends StatelessWidget {
  final BugReproduction reproduction;

  const BugReproductionDetails({super.key, required this.reproduction});

  /// Convenience for a raw `bug_reports` doc map.
  factory BugReproductionDetails.fromData(
    Map<String, dynamic>? data, {
    Key? key,
  }) =>
      BugReproductionDetails(
        key: key,
        reproduction: BugReproduction.fromData(data),
      );

  @override
  Widget build(BuildContext context) {
    if (reproduction.isEmpty) return const SizedBox.shrink();
    final sections = <(String, String)>[
      ('Steps to reproduce', reproduction.stepsToReproduce),
      ('Expected', reproduction.expectedBehavior),
      ('What happened instead', reproduction.actualBehavior),
    ].where((s) => s.$2.trim().isNotEmpty).toList();
    final theme = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: BjSpace.sm),
      padding: const EdgeInsets.all(BjSpace.md),
      decoration: BoxDecoration(
        color: BjNeutral.surfaceMuted,
        borderRadius: BjRadius.all(BjRadius.md),
        border: Border.all(color: BjNeutral.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < sections.length; i++) ...[
            if (i > 0) const SizedBox(height: BjSpace.sm),
            Text(sections[i].$1,
                style: theme.labelSmall?.copyWith(color: BjNeutral.inkMuted)),
            const SizedBox(height: BjSpace.xxs),
            ReadableSelectableText(
              sections[i].$2,
              style: theme.bodyMedium?.copyWith(color: BjNeutral.ink, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }
}
