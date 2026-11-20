import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/corporate_access_service.dart';
import 'package:shared_services/embeddable_access_modes.dart';

void main() {
  group('CorporateAccessService app ID helpers', () {
    test('canonicalizes legacy app ID variants to a hyphenated config doc ID', () {
      expect(
        CorporateAccessService.configDocId('group-one', 'naic_sight'),
        'group-one__naic-sight',
      );
      expect(
        CorporateAccessService.configDocId('group-one', 'naic-sight'),
        'group-one__naic-sight',
      );
    });

    test('includes underscore and hyphen aliases for config lookups', () {
      expect(
        CorporateAccessService.appIdAliases('naic_sight'),
        ['naic-sight', 'naic_sight'],
      );
      expect(
        CorporateAccessService.configDocIds('group-one', 'naic_sight'),
        ['group-one__naic-sight', 'group-one__naic_sight'],
      );
    });
  });

  group('AppAccessConfig.fromData', () {
    test('keeps both modes disabled when explicitly configured off', () {
      final config = AppAccessConfig.fromData({
        'publicEnabled': false,
        'corporateEnabled': false,
        'allowedDomains': ['Example.com'],
      });

      expect(config.publicEnabled, isFalse);
      expect(config.corporateEnabled, isFalse);
      expect(config.allowedDomains, ['example.com']);
    });

    test('applies embeddable mode restrictions', () {
      final config = AppAccessConfig.fromData({
        'publicEnabled': true,
        'corporateEnabled': false,
        'allowedDomains': ['example.com'],
      }).constrainedTo(
        const EmbeddableAccessModeConfig(
          publicAllowed: false,
          corporateAllowed: true,
        ),
      );

      expect(config.publicEnabled, isFalse);
      expect(config.corporateEnabled, isFalse);
      expect(config.allowedDomains, ['example.com']);
    });

    test('reads whether the domains follow the warehouse sources', () {
      final following = AppAccessConfig.fromData({
        'corporateEnabled': true,
        'allowedDomains': ['north.example'],
        'domainsFrom': domainsFromWarehouseSources,
      });
      expect(following.followsWarehouseSources, isTrue);
      expect(
        following
            .constrainedTo(const EmbeddableAccessModeConfig(publicAllowed: false, corporateAllowed: true))
            .followsWarehouseSources,
        isTrue,
      );

      expect(AppAccessConfig.fromData({'domainsFrom': 'elsewhere'}).domainsFrom, isNull);
      expect(AppAccessConfig.fromData({}).followsWarehouseSources, isFalse);
    });
  });
}
