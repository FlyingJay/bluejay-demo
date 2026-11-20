/// The one format for group ids and app ids.
///
/// Access-index entitlements join these ids with `:` (`{groupId}:{appId}`)
/// and natural-key doc ids join a group id onto a key with `__`, so neither
/// id may contain `:` or `_`: 1 to 63 lowercase letters, digits and hyphens,
/// starting and ending with a letter or digit (a DNS label). The server
/// enforces the same pattern (functions/_tenant_ids.js, kept identical by
/// functions/_tenant_ids.test.js) and skips any id outside it when building
/// access indexes, so an id that fails here would get no access at all.
library;

/// Longest valid group or app id.
const int tenantIdMaxLength = 63;

/// Mirrors `TENANT_ID_PATTERN` in functions/_tenant_ids.js.
final RegExp tenantIdPattern = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');

/// Whether [value] is a well-formed group or app id.
bool isValidTenantId(String value) => tenantIdPattern.hasMatch(value);

/// The user-facing explanation for an id that fails [isValidTenantId].
const String tenantIdRequirements =
    'Use 1-63 lowercase letters, numbers and hyphens, starting and ending '
    'with a letter or number';

/// A valid tenant id derived from a display [name] ("Engineering Team" →
/// "engineering-team"), or [fallback] when the name has no usable
/// characters. A positive [suffix] is appended as `-<suffix>` (for
/// uniqueness retries), trimming the base so the result stays within
/// [tenantIdMaxLength].
String tenantIdFromName(String name, {int suffix = 0, String fallback = 'group'}) {
  var base = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (base.isEmpty) base = fallback;
  final tail = suffix > 0 ? '-$suffix' : '';
  final room = tenantIdMaxLength - tail.length;
  if (base.length > room) {
    base = base.substring(0, room).replaceAll(RegExp(r'-+$'), '');
  }
  return '$base$tail';
}
