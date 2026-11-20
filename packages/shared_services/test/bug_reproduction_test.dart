import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/bug_reproduction.dart';

void main() {
  group('BugReproduction.validateSteps', () {
    test('requires steps by default', () {
      expect(BugReproduction.validateSteps(null), isNotNull);
      expect(BugReproduction.validateSteps('   \n  '), isNotNull);
    });

    test('rejects trivially short steps', () {
      expect(BugReproduction.validateSteps('n/a'), contains('more detail'));
      expect(BugReproduction.validateSteps('see above'), contains('more detail'));
      // Whitespace padding doesn't count toward the minimum.
      expect(
        BugReproduction.validateSteps('tap      \n\n\n      upload'),
        isNotNull,
      );
    });

    test('accepts one concrete action at the minimum length', () {
      const steps = 'Open Photos, tap Upload';
      expect(steps.length, greaterThanOrEqualTo(BugReproduction.minStepsLength));
      expect(BugReproduction.validateSteps(steps), isNull);
      expect(BugReproduction.validateSteps(BugReproductionExample.steps), isNull);
    });

    test('allows empty steps when not required, but still enforces the minimum', () {
      expect(BugReproduction.validateSteps('', requireSteps: false), isNull);
      expect(BugReproduction.validateSteps('idk', requireSteps: false), isNotNull);
    });
  });

  group('BugReproduction.fromData', () {
    test('legacy tickets without the fields read as empty', () {
      final repro = BugReproduction.fromData({'description': 'Could not upload file'});
      expect(repro.isEmpty, isTrue);
      expect(BugReproduction.fromData(null).isEmpty, isTrue);
    });

    test('reads and trims the stored fields, ignoring non-strings', () {
      final repro = BugReproduction.fromData({
        'stepsToReproduce': '  1. Open it\n2. Tap it  ',
        'expectedBehavior': 42,
        'actualBehavior': ' Crash ',
      });
      expect(repro.stepsToReproduce, '1. Open it\n2. Tap it');
      expect(repro.expectedBehavior, '');
      expect(repro.actualBehavior, 'Crash');
    });
  });

  group('writes', () {
    test('toCreateFields omits empty optional fields', () {
      const repro = BugReproduction(
        stepsToReproduce: ' 1. Open Warehouse Uploader ',
        expectedBehavior: '  ',
        actualBehavior: 'Red banner',
      );
      expect(repro.toCreateFields(), {
        'stepsToReproduce': '1. Open Warehouse Uploader',
        'actualBehavior': 'Red banner',
      });
    });

    test('toUpdateFields writes every field, deleting cleared ones', () {
      const sentinel = Object();
      const repro = BugReproduction(stepsToReproduce: '1. Open the app and tap Upload');
      expect(repro.toUpdateFields(deleteValue: sentinel), {
        'stepsToReproduce': '1. Open the app and tap Upload',
        'expectedBehavior': sentinel,
        'actualBehavior': sentinel,
      });
    });
  });
}
