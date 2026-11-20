/// Bluejay's security tiers, lowest to highest — see SECURITY_TIERS.md at the
/// repo root for what each one requires. Mirrors functions/_shared.js's
/// SECURITY_TIER_ORDER, the server-side source of truth this list must stay
/// in sync with; this copy is only ever used for display/comparison in the
/// client, never as an enforcement point (setGroupInstalledApps is that).
const securityTiers = ['casual', 'personal', 'shared', 'business', 'regulated'];

const securityTierLabels = {
  'casual': 'Casual',
  'personal': 'Personal',
  'shared': 'Shared',
  'business': 'Business',
  'regulated': 'Audit trail',
};

/// Unrecognized or unset tiers are treated as 'casual' (index 0) — the same
/// default apps/{appId}.securityTier and groups/{groupId}.minimumAppSecurityTier
/// both fall back to server-side when unset.
int securityTierIndex(String? tier) {
  final index = securityTiers.indexOf(tier ?? '');
  return index == -1 ? 0 : index;
}

String securityTierLabel(String? tier) =>
    securityTierLabels[tier] ?? securityTierLabels['casual']!;

/// The tier an app is held to: the lower of its declared tier
/// (`apps/{appId}.securityTier`) and the tier scripts/security_tier_audit last
/// computed (`computedSecurityTier`), or the declared tier when the app hasn't
/// been audited. Mirrors functions/_security_tiers.js's effectiveSecurityTier,
/// which the install gate enforces; this copy is for display and reports.
String effectiveSecurityTier(String? declared, String? computed) {
  final declaredTier = securityTiers.contains(declared) ? declared! : 'casual';
  if (!securityTiers.contains(computed)) return declaredTier;
  return securityTierIndex(computed) < securityTierIndex(declaredTier)
      ? computed!
      : declaredTier;
}

/// One plain-language line per tier saying what an app at that tier
/// protects, for badges and pickers (SECURITY_TIERS.md has the full
/// requirements).
const securityTierMeanings = {
  'casual': 'For low-stakes fun and quick tools, like games and polls.',
  'personal': 'Each person\'s items are theirs: only they can change or delete them.',
  'shared': 'Shared work among people who trust each other, with who-did-what kept honest.',
  'business': 'Business records: only editors and admins can change what others made.',
  'regulated': 'Audited records: every change is logged and nothing is erased.',
};

/// [tier]'s line from [securityTierMeanings]; unknown or unset tiers read as casual.
String securityTierMeaning(String? tier) =>
    securityTierMeanings[tier] ?? securityTierMeanings['casual']!;
