import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/scoped_storage.dart';

SettableMetadata _meta(Map<String, String> custom) =>
    SettableMetadata(customMetadata: custom);

void main() {
  group('requireUploadMetadata', () {
    test('accepts metadata carrying creatorId, groupId and appId', () {
      final meta = _meta({'creatorId': 'u', 'groupId': 'g', 'appId': 'chat'});
      expect(requireUploadMetadata(meta), same(meta));
    });

    test('accepts the explicit platform no-group marker', () {
      final meta = _meta({
        'creatorId': 'u',
        'groupId': ScopedStorage.platformNoGroupId,
        'appId': 'me',
      });
      expect(requireUploadMetadata(meta), same(meta));
      expect(ScopedStorage.platformNoGroupId, '~none');
    });

    test('rejects missing attribution keys', () {
      expect(
        () =>
            requireUploadMetadata(SettableMetadata(contentType: 'image/jpeg')),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('creatorId, groupId, appId'),
        )),
      );
      expect(() => requireUploadMetadata(_meta({'creatorId': 'u'})),
          throwsArgumentError);
    });

    test('rejects empty or blank values (signed out, no active group)', () {
      expect(
        () => requireUploadMetadata(
            _meta({'creatorId': '', 'groupId': 'g', 'appId': 'chat'})),
        throwsA(isA<ArgumentError>()
            .having((e) => e.message, 'message', contains('creatorId'))),
      );
      expect(
        () => requireUploadMetadata(
            _meta({'creatorId': 'u', 'groupId': '', 'appId': 'chat'})),
        throwsA(isA<ArgumentError>()
            .having((e) => e.message, 'message', contains('groupId'))),
      );
      expect(
        () => requireUploadMetadata(
            _meta({'creatorId': 'u', 'groupId': 'g', 'appId': '  '})),
        throwsArgumentError,
      );
    });
  });

  group('ScopedStorage.permissionMetadata', () {
    test('stamps the permission fields over any extra metadata', () {
      final meta = ScopedStorage.permissionMetadata(
        creatorId: 'u',
        groupId: 'g',
        appId: 'chat',
        contentType: 'image/png',
        extraMetadata: {'appId': 'spoofed', 'note': 'kept'},
      );
      expect(meta.contentType, 'image/png');
      expect(meta.customMetadata, {
        'note': 'kept',
        'creatorId': 'u',
        'groupId': 'g',
        'appId': 'chat',
      });
      expect(requireUploadMetadata(meta), same(meta));
    });
  });
}
