import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/app_stewardship.dart';

class _Ticket {
  final String id;
  final int millis;
  const _Ticket(this.id, this.millis);
}

String _idOf(_Ticket ticket) => ticket.id;
int _newestFirst(_Ticket a, _Ticket b) => b.millis.compareTo(a.millis);

void main() {
  group('stewardedAppIdsFromEntitlements', () {
    test('extracts app ids from app:<appId>:steward entries only', () {
      expect(
        stewardedAppIdsFromEntitlements([
          'app:rented-dwelling:steward',
          'app:commercial-property:steward',
          'northwind:improve-apps',
          'northwind:improve-apps:admin',
          'app:rented-dwelling',
          'xapp:notes:steward',
          'app::steward',
          42,
          null,
        ]),
        {'rented-dwelling', 'commercial-property'},
      );
    });

    test('keeps app ids that themselves contain colons', () {
      expect(
        stewardedAppIdsFromEntitlements(['app:a:b:steward']),
        {'a:b'},
      );
    });

    test('is empty for a missing or empty list', () {
      expect(stewardedAppIdsFromEntitlements(null), isEmpty);
      expect(stewardedAppIdsFromEntitlements(const []), isEmpty);
    });
  });

  group('isStewardedTicketOutsideGroup', () {
    const stewarded = {'rented-dwelling'};

    test('true for a stewarded app ticket in another group', () {
      expect(
        isStewardedTicketOutsideGroup(
          {'groupId': 'globex', 'relatedAppId': 'rented-dwelling'},
          activeGroupId: 'northwind',
          stewardedAppIds: stewarded,
        ),
        isTrue,
      );
    });

    test('false in the active group, for other apps, or with no data', () {
      expect(
        isStewardedTicketOutsideGroup(
          {'groupId': 'northwind', 'relatedAppId': 'rented-dwelling'},
          activeGroupId: 'northwind',
          stewardedAppIds: stewarded,
        ),
        isFalse,
      );
      expect(
        isStewardedTicketOutsideGroup(
          {'groupId': 'globex', 'relatedAppId': 'notes'},
          activeGroupId: 'northwind',
          stewardedAppIds: stewarded,
        ),
        isFalse,
      );
      expect(
        isStewardedTicketOutsideGroup(
          {'groupId': 'globex'},
          activeGroupId: 'northwind',
          stewardedAppIds: stewarded,
        ),
        isFalse,
      );
      expect(
        isStewardedTicketOutsideGroup(
          null,
          activeGroupId: 'northwind',
          stewardedAppIds: stewarded,
        ),
        isFalse,
      );
    });
  });

  group('ticket labels', () {
    test('prefer the denormalized names', () {
      final data = {
        'groupId': 'g1',
        'groupName': 'Globex',
        'relatedAppId': 'rented-dwelling',
        'relatedAppName': 'Rented Dwelling',
      };
      expect(stewardedTicketGroupLabel(data), 'Globex');
      expect(stewardedTicketAppLabel(data), 'Rented Dwelling');
    });

    test('fall back to the ids when names are missing or blank', () {
      final data = {
        'groupId': 'g1',
        'groupName': '  ',
        'relatedAppId': 'rented-dwelling',
      };
      expect(stewardedTicketGroupLabel(data), 'g1');
      expect(stewardedTicketAppLabel(data), 'rented-dwelling');
      expect(stewardedTicketGroupLabel(const {}), '');
    });
  });

  group('mergeUniqueById', () {
    test('de-duplicates by id, first occurrence wins', () {
      final merged = mergeUniqueById<_Ticket>(
        [
          const [_Ticket('a', 1), _Ticket('b', 2)],
          const [_Ticket('b', 99), _Ticket('c', 3)],
        ],
        idOf: _idOf,
      );
      expect(merged.map((t) => t.id), ['a', 'b', 'c']);
      expect(merged[1].millis, 2);
    });

    test('sorts with the comparator when given', () {
      final merged = mergeUniqueById<_Ticket>(
        [
          const [_Ticket('a', 1), _Ticket('b', 3)],
          const [_Ticket('c', 2)],
        ],
        idOf: _idOf,
        compare: _newestFirst,
      );
      expect(merged.map((t) => t.id), ['b', 'c', 'a']);
    });
  });

  group('combineLatestUniqueById', () {
    test('emits one empty list for no sources', () async {
      expect(
        await combineLatestUniqueById<_Ticket>(const [], idOf: _idOf).toList(),
        [isEmpty],
      );
    });

    test('waits for every source, then re-emits on each change', () async {
      final first = StreamController<List<_Ticket>>();
      final second = StreamController<List<_Ticket>>();
      final emissions = <List<String>>[];
      final subscription = combineLatestUniqueById<_Ticket>(
        [first.stream, second.stream],
        idOf: _idOf,
        compare: _newestFirst,
      ).listen((items) => emissions.add(items.map((t) => t.id).toList()));

      first.add(const [_Ticket('a', 1)]);
      await pumpEventQueue();
      expect(emissions, isEmpty);

      second.add(const [_Ticket('b', 2), _Ticket('a', 1)]);
      await pumpEventQueue();
      expect(emissions, [
        ['b', 'a'],
      ]);

      first.add(const [_Ticket('a', 1), _Ticket('c', 3)]);
      await pumpEventQueue();
      expect(emissions.last, ['c', 'b', 'a']);

      await subscription.cancel();
      expect(first.hasListener, isFalse);
      expect(second.hasListener, isFalse);
    });

    test('forwards source errors', () async {
      final source = StreamController<List<_Ticket>>();
      final errors = <Object>[];
      final subscription = combineLatestUniqueById<_Ticket>(
        [source.stream],
        idOf: _idOf,
      ).listen((_) {}, onError: errors.add);

      source.addError(StateError('permission-denied'));
      await pumpEventQueue();
      expect(errors, hasLength(1));
      await subscription.cancel();
    });
  });
}
