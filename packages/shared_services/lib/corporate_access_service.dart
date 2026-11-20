import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'active_group_service.dart';
import 'embeddable_access_modes.dart';
import 'scoped_collection.dart';
import 'package:shared_services/cloud_functions.dart';

const corporateAccessConfigCollection = 'corporate_access_configs';
/// App Access: the registered app corporate_access_configs belong to
/// (security/collections.json).
const corporateAccessOwnerAppId = 'app-access';

final _corporateAccessConfigs = ScopedCollection(
  collection: corporateAccessConfigCollection,
  appId: corporateAccessOwnerAppId,
);

/// `domainsFrom` value: the allowlist follows the group's warehouse sources'
/// upload domains (functions/_warehouse_access_domains.js).
const domainsFromWarehouseSources = 'warehouseSources';

class AppAccessConfig {
  final bool publicEnabled;
  final bool corporateEnabled;
  final List<String> allowedDomains;

  /// Where [allowedDomains] comes from: null for the config's own list, or
  /// [domainsFromWarehouseSources] when the server keeps it in step with the
  /// group's active warehouse sources.
  final String? domainsFrom;

  const AppAccessConfig({
    required this.publicEnabled,
    required this.corporateEnabled,
    required this.allowedDomains,
    this.domainsFrom,
  });

  bool get followsWarehouseSources => domainsFrom == domainsFromWarehouseSources;

  AppAccessConfig constrainedTo(EmbeddableAccessModeConfig allowedModes) {
    final normalizedModes = applyEmbeddableAccessModePolicy(
      publicEnabled: publicEnabled,
      corporateEnabled: corporateEnabled,
      allowedModes: allowedModes,
    );
    return AppAccessConfig(
      publicEnabled: normalizedModes.publicEnabled,
      corporateEnabled: normalizedModes.corporateEnabled,
      allowedDomains: allowedDomains,
      domainsFrom: domainsFrom,
    );
  }

  factory AppAccessConfig.fromData(Map<String, dynamic>? data) {
    final normalizedDomains =
        CorporateAccessService.normalizeDomainList(data?['allowedDomains']);

    final bool? explicitPublic = data?['publicEnabled'] as bool?;
    final bool? explicitCorporate = data?['corporateEnabled'] as bool?;

    bool publicEnabled;
    bool corporateEnabled;

    if (explicitPublic != null || explicitCorporate != null) {
      publicEnabled = explicitPublic ?? !explicitCorporate!;
      corporateEnabled = explicitCorporate ?? !explicitPublic!;
    } else {
      corporateEnabled = normalizedDomains.isNotEmpty;
      publicEnabled = !corporateEnabled;
    }

    if (publicEnabled && corporateEnabled) {
      corporateEnabled = false;
      publicEnabled = true;
    }

    final domainsFrom = data?['domainsFrom'];
    return AppAccessConfig(
      publicEnabled: publicEnabled,
      corporateEnabled: corporateEnabled,
      allowedDomains: normalizedDomains,
      domainsFrom: domainsFrom == domainsFromWarehouseSources ? domainsFrom as String : null,
    );
  }
}

class CorporateAccessService {
  CorporateAccessService({FirebaseFunctions? functions}) : _functionsOverride = functions;

  final FirebaseFunctions? _functionsOverride;

  /// Resolved on first use, so constructing the service (or a test double
  /// extending it) doesn't need an initialized Firebase app.
  FirebaseFunctions get _functions => _functionsOverride ?? BluejayFunctions.instance;

  Future<AppAccessConfig> loadConfig(String targetAppId) async {
    final groupId = ActiveGroupService.instance.activeGroupId;
    if (groupId == null || groupId.isEmpty) {
      return const AppAccessConfig(
        publicEnabled: true,
        corporateEnabled: false,
        allowedDomains: [],
      );
    }

    final docs = await Future.wait(
      configDocIds(groupId, targetAppId)
          .map((docId) => _corporateAccessConfigs.doc(docId).get()),
    );

    final data = _selectConfigData(docs, groupId: groupId, targetAppId: targetAppId);
    return AppAccessConfig.fromData(data);
  }

  Stream<AppAccessConfig> streamConfig(String targetAppId) {
    final groupId = ActiveGroupService.instance.activeGroupId;
    if (groupId == null || groupId.isEmpty) {
      return Stream.value(
        const AppAccessConfig(
          publicEnabled: true,
          corporateEnabled: false,
          allowedDomains: [],
        ),
      );
    }

    final docIds = configDocIds(groupId, targetAppId);
    return Stream.multi((controller) {
      final latestDocs = <String, DocumentSnapshot<Map<String, dynamic>>>{};
      late final List<StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>>
          subscriptions;

      void emit() {
        final data = _selectConfigData(
          latestDocs.values,
          groupId: groupId,
          targetAppId: targetAppId,
        );
        controller.add(AppAccessConfig.fromData(data));
      }

      subscriptions = docIds.map((docId) {
        return _corporateAccessConfigs.doc(docId).snapshots().listen(
          (snap) {
            latestDocs[docId] = snap;
            emit();
          },
          onError: controller.addError,
        );
      }).toList();

      controller.onCancel = () async {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
      };
    });
  }

  Future<AppAccessConfig> updateConfig({
    required String targetAppId,
    List<String>? allowedDomains,
    bool? publicEnabled,
    bool? corporateEnabled,
    bool? followWarehouseSources,
  }) async {
    final groupId = ActiveGroupService.instance.activeGroupId;
    if (groupId == null || groupId.isEmpty) {
      throw StateError('No active group selected.');
    }

    final payload = <String, dynamic>{
      'groupId': groupId,
      'targetAppId': targetAppId,
    };

    if (allowedDomains != null) {
      payload['allowedDomains'] = normalizeDomainList(allowedDomains);
    }
    if (publicEnabled != null) {
      payload['publicEnabled'] = publicEnabled;
    }
    if (corporateEnabled != null) {
      payload['corporateEnabled'] = corporateEnabled;
    }
    if (followWarehouseSources != null) {
      payload['domainsFrom'] = followWarehouseSources ? domainsFromWarehouseSources : null;
    }

    final result =
        await _functions.httpsCallable('corporateAccessUpdateConfig').call(payload);
    final data = result.data;
    if (data is Map) {
      return AppAccessConfig.fromData(Map<String, dynamic>.from(data));
    }

    return loadConfig(targetAppId);
  }

  Future<List<String>> loadAllowedDomains(String targetAppId) async {
    final config = await loadConfig(targetAppId);
    return config.allowedDomains;
  }

  Stream<List<String>> streamAllowedDomains(String targetAppId) {
    return streamConfig(targetAppId).map((config) => config.allowedDomains);
  }

  Future<List<String>> updateAllowedDomains({
    required String targetAppId,
    required List<String> allowedDomains,
  }) async {
    final config = await updateConfig(
      targetAppId: targetAppId,
      allowedDomains: allowedDomains,
    );
    return config.allowedDomains;
  }

  /// Asks the server to record a corporate guest's identity
  /// (`corporateAccessSetGuestIdentity`). The guest must prove they control
  /// [guestEmail]: the first call (no [code]) emails them a one-time code and
  /// returns [GuestIdentityStatus.codeSent]; call again with the code they
  /// type. A signed-in user whose verified account email is [guestEmail] is
  /// accepted without a code.
  Future<GuestIdentityStatus> submitGuestIdentity({
    required String groupId,
    required String targetAppId,
    required String guestEmail,
    required String guestName,
    String? code,
  }) async {
    final result = await _functions.httpsCallable('corporateAccessSetGuestIdentity').call({
      'groupId': groupId,
      'targetAppId': targetAppId,
      'guestEmail': guestEmail,
      'guestName': guestName,
      if (code != null && code.trim().isNotEmpty) 'code': code.trim(),
    });
    return GuestIdentityStatus.fromResponse(result.data);
  }

  static String normalizeAppId(String appId) => appId.trim().toLowerCase();

  static String canonicalTargetAppId(String targetAppId) =>
      normalizeAppId(targetAppId).replaceAll('_', '-');

  static List<String> appIdAliases(String targetAppId) {
    final normalized = normalizeAppId(targetAppId);
    if (normalized.isEmpty) return const [];
    final hyphenated = normalized.replaceAll('_', '-');
    final underscored = normalized.replaceAll('-', '_');
    final aliases = <String>[];
    for (final alias in [hyphenated, underscored, normalized]) {
      if (!aliases.contains(alias)) {
        aliases.add(alias);
      }
    }
    return aliases;
  }

  static String configDocId(String groupId, String targetAppId) =>
      '${groupId}__${canonicalTargetAppId(targetAppId)}';

  static List<String> configDocIds(String groupId, String targetAppId) {
    final canonicalId = configDocId(groupId, targetAppId);
    return [
      canonicalId,
      ...appIdAliases(targetAppId)
          .map((appId) => '${groupId}__${appId}')
          .where((docId) => docId != canonicalId),
    ];
  }

  static List<String> normalizeDomainList(dynamic value) {
    final source = value is List ? value : const [];
    final seen = <String>{};
    final result = <String>[];
    for (final item in source) {
      final normalized = normalizeDomain('$item');
      if (normalized.isNotEmpty && seen.add(normalized)) {
        result.add(normalized);
      }
    }
    result.sort();
    return result;
  }

  static String normalizeDomain(String domain) {
    final trimmed = domain.trim().toLowerCase().replaceAll(RegExp(r'^@'), '');
    if (trimmed.isEmpty || !trimmed.contains('.')) return '';
    return trimmed;
  }

  static bool _matchesTargetApp(
    Map<String, dynamic>? data,
    String targetAppId,
  ) {
    if (data == null) return false;
    final aliases = appIdAliases(targetAppId).toSet();
    return aliases.contains(normalizeAppId(data['targetAppId'] as String? ?? '')) ||
        aliases.contains(normalizeAppId(data['targetAppSlug'] as String? ?? ''));
  }

  static Map<String, dynamic>? _selectConfigData(
    Iterable<DocumentSnapshot<Map<String, dynamic>>> docs, {
    required String groupId,
    required String targetAppId,
  }) {
    final configIds = configDocIds(groupId, targetAppId);
    final canonicalId = configIds.first;
    final matchingDocs = docs.where((doc) {
      if (!doc.exists) return false;
      if (configIds.contains(doc.id)) return true;
      return _matchesTargetApp(doc.data(), targetAppId);
    }).toList();

    DocumentSnapshot<Map<String, dynamic>>? selectedDoc;
    for (final doc in matchingDocs) {
      if (doc.id == canonicalId) {
        selectedDoc = doc;
        break;
      }
    }
    selectedDoc ??= matchingDocs.isNotEmpty ? matchingDocs.first : null;
    return selectedDoc?.data();
  }
}

bool isEmailDomainAllowed(String email, List<String> allowedDomains) {
  if (allowedDomains.isEmpty) return false;
  final parts = email.trim().toLowerCase().split('@');
  if (parts.length != 2 || parts[1].isEmpty) return false;
  return allowedDomains.contains(parts[1]);
}

/// The outcome of [CorporateAccessService.submitGuestIdentity].
enum GuestIdentityStatus {
  /// The identity is recorded; the guest may continue.
  allowed,

  /// A code was emailed to the address; ask the guest to enter it.
  codeSent,

  /// The code was wrong, expired, or already used.
  codeInvalid,

  /// Too many codes were requested recently.
  rateLimited,

  /// No email was sent (demo groups never send), so the address can't be
  /// confirmed here.
  sendSkipped,

  /// The address's organisation isn't approved for the app.
  denied;

  static GuestIdentityStatus fromResponse(Object? data) {
    if (data is! Map) return denied;
    if (data['allowed'] == true) return allowed;
    if (data['codeSent'] == true) return codeSent;
    if (data['codeInvalid'] == true) return codeInvalid;
    if (data['rateLimited'] == true) return rateLimited;
    if (data['sendSkipped'] == true) return sendSkipped;
    return denied;
  }
}
