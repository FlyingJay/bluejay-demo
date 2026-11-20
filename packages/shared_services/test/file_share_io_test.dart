import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/file_share_io.dart';

void main() {
  group('safeShareFileName', () {
    test('keeps ordinary names unchanged', () {
      expect(safeShareFileName('attendees.csv'), 'attendees.csv');
      expect(safeShareFileName('Q3 report (final).pdf'), 'Q3 report (final).pdf');
    });

    test('drops any directory part, so a name cannot escape its folder', () {
      expect(safeShareFileName('groups/acme/apps/storage/photo.jpg'), 'photo.jpg');
      expect(safeShareFileName('../../etc/passwd'), 'passwd');
      expect(safeShareFileName(r'C:\Users\pat\notes.txt'), 'notes.txt');
    });

    test('replaces characters common filesystems reject', () {
      expect(safeShareFileName('what?.csv'), 'what_.csv');
      expect(safeShareFileName('a<b>c:"d"|e*.txt'), 'a_b_c__d__e_.txt');
      expect(safeShareFileName('tab\there.txt'), 'tab_here.txt');
    });

    test('falls back when nothing usable is left', () {
      expect(safeShareFileName(''), 'download');
      expect(safeShareFileName('   '), 'download');
      expect(safeShareFileName('reports/'), 'download');
      expect(safeShareFileName('..'), 'download');
      expect(safeShareFileName('', fallback: 'export.csv'), 'export.csv');
    });

    test('long names keep their end, where the extension is', () {
      final name = '${'x' * 200}.csv';
      final safe = safeShareFileName(name);
      expect(safe.length, 120);
      expect(safe.endsWith('.csv'), isTrue);
    });
  });

  group('sharePositionOriginFor', () {
    testWidgets('returns the tapped widget\'s global rectangle', (tester) async {
      late BuildContext buttonContext;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 30, top: 40),
              child: Builder(
                builder: (context) {
                  buttonContext = context;
                  return const SizedBox(width: 100, height: 50);
                },
              ),
            ),
          ),
        ),
      );

      final rect = sharePositionOriginFor(buttonContext);
      expect(rect, const Rect.fromLTWH(30, 40, 100, 50));
    });
  });
}
