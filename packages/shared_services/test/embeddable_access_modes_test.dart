import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/embeddable_access_modes.dart';

void main() {
  group('normalizeEmbeddableAccessModes', () {
    test('defaults to both modes when config is missing', () {
      expect(
        normalizeEmbeddableAccessModes(null),
        [embeddableAccessModePublic, embeddableAccessModeCorporate],
      );
    });

    test('normalizes and filters explicit mode values', () {
      expect(
        normalizeEmbeddableAccessModes([' Corporate ', 'invalid', 'public']),
        [embeddableAccessModePublic, embeddableAccessModeCorporate],
      );
      expect(
        normalizeEmbeddableAccessModes(['corporate']),
        [embeddableAccessModeCorporate],
      );
    });

    test('keeps explicit empty mode list as empty', () {
      expect(
        normalizeEmbeddableAccessModes(const []),
        isEmpty,
      );
    });

    test('falls back to both modes for unrecognized explicit values', () {
      expect(
        normalizeEmbeddableAccessModes(['invalid']),
        [embeddableAccessModePublic, embeddableAccessModeCorporate],
      );
    });
  });

  test('applyEmbeddableAccessModePolicy disables disallowed modes', () {
    final normalized = applyEmbeddableAccessModePolicy(
      publicEnabled: true,
      corporateEnabled: false,
      allowedModes: const EmbeddableAccessModeConfig(
        publicAllowed: false,
        corporateAllowed: true,
      ),
    );

    expect(normalized.publicEnabled, isFalse);
    expect(normalized.corporateEnabled, isFalse);
  });

  test('applyEmbeddableAccessModePolicy keeps mutual exclusivity', () {
    final normalized = applyEmbeddableAccessModePolicy(
      publicEnabled: true,
      corporateEnabled: true,
      allowedModes: const EmbeddableAccessModeConfig(
        publicAllowed: true,
        corporateAllowed: true,
      ),
    );

    expect(normalized.publicEnabled, isTrue);
    expect(normalized.corporateEnabled, isFalse);
  });

  group('apps that need the guest\'s confirmed email', () {
    test('forApp withholds public access and says why', () {
      for (final appId in ['naic-sight', 'naic_sight', 'data-warehouse']) {
        final modes = EmbeddableAccessModeConfig.forApp(appId, null);
        expect(modes.publicAllowed, isFalse, reason: appId);
        expect(modes.corporateAllowed, isTrue, reason: appId);
        expect(modes.identityRequiredReason, isNotNull, reason: appId);
      }
      final uploader = EmbeddableAccessModeConfig.forApp('warehouse-uploader', null);
      expect(uploader.publicAllowed, isTrue);
      expect(uploader.identityRequiredReason, isNull);
    });

    test('a public choice becomes corporate access, as on the server', () {
      final modes = EmbeddableAccessModeConfig.forApp('naic-sight', null);
      expect(
        applyEmbeddableAccessModePolicy(publicEnabled: true, corporateEnabled: false, allowedModes: modes),
        (publicEnabled: false, corporateEnabled: true),
      );
      // App Manager allows only public: nothing, rather than public.
      expect(
        applyEmbeddableAccessModePolicy(
          publicEnabled: true,
          corporateEnabled: false,
          allowedModes: EmbeddableAccessModeConfig.forApp('naic-sight', ['public']),
        ),
        (publicEnabled: false, corporateEnabled: false),
      );
      // Other apps keep public access.
      expect(
        applyEmbeddableAccessModePolicy(
          publicEnabled: true,
          corporateEnabled: false,
          allowedModes: EmbeddableAccessModeConfig.forApp('shop', null),
        ),
        (publicEnabled: true, corporateEnabled: false),
      );
    });
  });
}
