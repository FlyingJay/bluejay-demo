import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/ticket_close_reasons.dart';

void main() {
  test('bugs, ideas and app requests get their own lists', () {
    expect(closeReasonsFor('bug'), same(bugCloseReasons));
    expect(closeReasonsFor('feature'), same(ideaCloseReasons));
    expect(closeReasonsFor('app'), same(appDeclineReasons));
    expect(bugCloseReasons.first.code, 'unspecified');
    expect(ideaCloseReasons.first.code, 'unspecified');
    expect(bugCloseReasons.map((r) => r.code), contains('cannot_reproduce'));
    expect(ideaCloseReasons.map((r) => r.code), contains('out_of_scope'));
    expect(appDeclineReasons.map((r) => r.code), containsAll(['already_exists', 'withdrawn_by_requester', 'spam_or_test']));
  });

  test('codes are unique within each list', () {
    for (final list in [bugCloseReasons, ideaCloseReasons, appDeclineReasons]) {
      expect(list.map((r) => r.code).toSet().length, list.length);
    }
  });

  test('every code is one the server words a notification for', () {
    // functions/_ticket_closure.js (PHASE_2_5_DESIGN.md 7.2).
    const known = {
      'duplicate',
      'already_implemented',
      'already_exists',
      'too_broad',
      'cannot_reproduce',
      'out_of_scope',
      'not_planned',
      'not_ready',
      'needs_more_info',
      'withdrawn_by_requester',
      'spam_or_test',
      'unspecified',
    };
    for (final list in [bugCloseReasons, ideaCloseReasons, appDeclineReasons]) {
      for (final reason in list) {
        expect(known, contains(reason.code));
      }
    }
  });

  test('"Needs more information" is on every list and requires a question', () {
    for (final list in [bugCloseReasons, ideaCloseReasons, appDeclineReasons]) {
      final reason = list.singleWhere((r) => r.code == 'needs_more_info');
      expect(reason.label, 'Needs more information');
      expect(reason.requiresNote, isTrue);
      expect(reason.noteFieldLabel, 'Your question for the requester');
    }
    expect(const TicketCloseSelection(reason: needsMoreInfoCloseReason, note: '   ').isComplete, isFalse);
    const asked = TicketCloseSelection(reason: needsMoreInfoCloseReason, note: ' Which screen? ');
    expect(asked.isComplete, isTrue);
    expect(asked.message, 'Needs more information — Which screen?');
  });

  test('other reasons take an optional note', () {
    const reason = TicketCloseReason(code: 'duplicate', label: 'Duplicate ticket');
    expect(reason.noteFieldLabel, 'Details (optional)');
    expect(const TicketCloseSelection(reason: reason).isComplete, isTrue);
  });

  test('selection message is the label, plus the note when there is one', () {
    const reason = TicketCloseReason(code: 'duplicate', label: 'Duplicate ticket');
    expect(const TicketCloseSelection(reason: reason).message, 'Duplicate ticket');
    expect(const TicketCloseSelection(reason: reason, note: '  see #12 ').message, 'Duplicate ticket — see #12');
  });
}
