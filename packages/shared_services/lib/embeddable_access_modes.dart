const embeddableAccessModePublic = 'public';
const embeddableAccessModeCorporate = 'corporate';

const embeddableAccessModes = [
  embeddableAccessModePublic,
  embeddableAccessModeCorporate,
];

class EmbeddableAccessModeOption {
  final String id;
  final String title;
  final String description;

  const EmbeddableAccessModeOption({
    required this.id,
    required this.title,
    required this.description,
  });
}

const embeddableAccessModeOptions = [
  EmbeddableAccessModeOption(
    id: embeddableAccessModePublic,
    title: 'Public access',
    description:
        'Group admins can allow anonymous internet users with the direct link.',
  ),
  EmbeddableAccessModeOption(
    id: embeddableAccessModeCorporate,
    title: 'Corporate access',
    description:
        'Group admins can allow guest access limited to approved email domains.',
  ),
];

/// Returns normalized embeddable access mode IDs in canonical order.
///
/// Non-list values are treated as "unset" and fall back to allowing all modes.
/// An explicit empty list remains empty. Lists with only unrecognized values
/// fall back to all modes for safety/backward compatibility. Mixed lists keep
/// recognized values and ignore unrecognized values.
List<String> normalizeEmbeddableAccessModes(dynamic value) {
  if (value is! List) {
    return List<String>.from(embeddableAccessModes);
  }

  final source = value;
  final normalized = source
      .map((item) => '$item'.trim().toLowerCase())
      .where(embeddableAccessModes.contains)
      .toSet();

  if (normalized.isEmpty && source.isNotEmpty) {
    return List<String>.from(embeddableAccessModes);
  }

  return embeddableAccessModes
      .where((modeId) => normalized.contains(modeId))
      .toList(growable: false);
}

/// Embeddable apps that can serve a guest only once the guest has confirmed
/// a work email, with why (keyed by the canonical `apps/{docId}` id). Public
/// access is unavailable for them: a public choice becomes corporate access.
///
/// The server's copy is `GUEST_IDENTITY_REQUIRED_APPS` in
/// functions/_corporate_access.js, which enforces it;
/// functions/guest_identity_required_apps.test.js keeps the two equal.
const guestIdentityRequiredApps = <String, String>{
  'naic-sight':
      "NAIC Sight emails results to each guest's confirmed work email and bills their organisation, so it is available to corporate guests only.",
  'data-warehouse':
      "Data Warehouse shows each guest only their own organisation's data, found from their confirmed work email, so it is available to corporate guests only.",
};

/// Why [appId] needs every guest's confirmed work email, or null when it can
/// serve public guests.
String? guestIdentityRequiredReason(String appId) =>
    guestIdentityRequiredApps[appId.trim().toLowerCase().replaceAll('_', '-')];

class EmbeddableAccessModeConfig {
  final bool publicAllowed;
  final bool corporateAllowed;

  /// Set when the app needs each guest's confirmed work email
  /// ([guestIdentityRequiredApps]): public access is unavailable, and this
  /// says why.
  final String? identityRequiredReason;

  const EmbeddableAccessModeConfig({
    required this.publicAllowed,
    required this.corporateAllowed,
    this.identityRequiredReason,
  });

  /// The App Manager modes in [value], before any app's own needs. Use
  /// [EmbeddableAccessModeConfig.forApp] to decide what a group can choose.
  factory EmbeddableAccessModeConfig.fromData(dynamic value) {
    final modes = normalizeEmbeddableAccessModes(value);
    return EmbeddableAccessModeConfig(
      publicAllowed: modes.contains(embeddableAccessModePublic),
      corporateAllowed: modes.contains(embeddableAccessModeCorporate),
    );
  }

  /// The modes a group can choose for [appId]: the App Manager modes in
  /// [value], without public access for an app in
  /// [guestIdentityRequiredApps]. The same ceiling the server applies
  /// (normalizeAccessModeConfig in functions/_corporate_access.js).
  factory EmbeddableAccessModeConfig.forApp(String appId, dynamic value) {
    final base = EmbeddableAccessModeConfig.fromData(value);
    final reason = guestIdentityRequiredReason(appId);
    if (reason == null) return base;
    return EmbeddableAccessModeConfig(
      publicAllowed: false,
      corporateAllowed: base.corporateAllowed,
      identityRequiredReason: reason,
    );
  }

  List<String> toModes() {
    final modes = <String>[];
    if (publicAllowed) modes.add(embeddableAccessModePublic);
    if (corporateAllowed) modes.add(embeddableAccessModeCorporate);
    return modes;
  }
}

/// Applies the app-manager mode allowlist to a group-level access config.
///
/// This also preserves the existing single-mode invariant by forcing
/// `corporateEnabled` off when both mode flags are true, and turns a public
/// choice into corporate access for an app that needs the guest's work email
/// ([EmbeddableAccessModeConfig.identityRequiredReason]).
({bool publicEnabled, bool corporateEnabled}) applyEmbeddableAccessModePolicy({
  required bool publicEnabled,
  required bool corporateEnabled,
  required EmbeddableAccessModeConfig allowedModes,
}) {
  var nextPublicEnabled = publicEnabled;
  var nextCorporateEnabled = corporateEnabled;

  // An app that needs the guest's work email can't be public: a public
  // choice becomes corporate access, as on the server.
  if (allowedModes.identityRequiredReason != null &&
      nextPublicEnabled &&
      !nextCorporateEnabled &&
      allowedModes.corporateAllowed) {
    nextCorporateEnabled = true;
  }
  if (!allowedModes.publicAllowed) {
    nextPublicEnabled = false;
  }
  if (!allowedModes.corporateAllowed) {
    nextCorporateEnabled = false;
  }
  if (nextPublicEnabled && nextCorporateEnabled) {
    nextCorporateEnabled = false;
  }

  return (
    publicEnabled: nextPublicEnabled,
    corporateEnabled: nextCorporateEnabled,
  );
}
