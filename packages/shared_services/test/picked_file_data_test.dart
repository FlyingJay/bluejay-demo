import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/file_pick.dart';

void main() {
  group('PickedFileData', () {
    test('is readable only when its bytes were read', () {
      final read = PickedFileData(name: 'a.csv', size: 3, bytes: Uint8List.fromList([1, 2, 3]));
      const unread = PickedFileData(name: 'a.csv', size: 3, readProblem: 'nope');
      expect(read.isReadable, isTrue);
      expect(unread.isReadable, isFalse);
    });
  });

  group('fileReadProblemMessage', () {
    test('points at synced folders when the browser says the file is unreadable', () {
      expect(fileReadProblemMessage('NotReadableError'), contains('iCloud Drive'));
      expect(fileReadProblemMessage('NotFoundError'), contains('iCloud Drive'));
    });

    test('explains a browser refusal', () {
      expect(fileReadProblemMessage('SecurityError'), contains('didn\'t allow'));
    });

    test('falls back to a general message', () {
      expect(fileReadProblemMessage(null), contains('couldn\'t be read'));
      expect(fileReadProblemMessage('AbortError'), contains('couldn\'t be read'));
    });
  });
}
