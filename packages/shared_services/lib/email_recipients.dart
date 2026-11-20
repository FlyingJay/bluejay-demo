/// Client-side mirror of the email helpers in `functions/_shared.js`
/// (`normalizeEmail` / `normalizeEmailRecipients`), so a form can flag the
/// same addresses the server will reject before the request is sent.
///
/// The server remains authoritative: these helpers only exist to give the
/// user immediate feedback.
library;

/// Same pattern as `EMAIL_ADDRESS_PATTERN` in `functions/_shared.js`.
final RegExp _emailAddressPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

/// RFC 5321 caps a forward-path at 256 octets including the angle brackets.
const int kMaxEmailAddressLength = 254;

/// Lowercased and trimmed, or `''` when [value] isn't a plausible address.
String normalizeEmailAddress(String? value) {
  final email = (value ?? '').trim().toLowerCase();
  if (email.length > kMaxEmailAddressLength) return '';
  return _emailAddressPattern.hasMatch(email) ? email : '';
}

/// Result of [normalizeEmailRecipients].
class EmailRecipientsResult {
  /// Valid, normalized, de-duplicated addresses (excluding any in `exclude`).
  final List<String> recipients;

  /// Trimmed entries that are not plausible email addresses.
  final List<String> invalid;

  /// True when [recipients] has more entries than the requested maximum.
  final bool tooMany;

  const EmailRecipientsResult({
    required this.recipients,
    required this.invalid,
    required this.tooMany,
  });

  bool get isValid => invalid.isEmpty && !tooMany;
}

/// Normalizes a list of user-entered extra recipients the same way the
/// server does: blanks skipped, addresses lowercased/trimmed, duplicates and
/// anything in [exclude] (e.g. the primary recipient) dropped, and [max]
/// checked after de-duplication.
EmailRecipientsResult normalizeEmailRecipients(
  Iterable<String> values, {
  int? max,
  Iterable<String?> exclude = const [],
}) {
  final excluded = exclude
      .map(normalizeEmailAddress)
      .where((e) => e.isNotEmpty)
      .toSet();
  final seen = <String>{};
  final recipients = <String>[];
  final invalid = <String>[];
  for (final raw in values) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) continue;
    final email = normalizeEmailAddress(trimmed);
    if (email.isEmpty) {
      invalid.add(trimmed);
      continue;
    }
    if (excluded.contains(email) || !seen.add(email)) continue;
    recipients.add(email);
  }
  return EmailRecipientsResult(
    recipients: recipients,
    invalid: invalid,
    tooMany: max != null && recipients.length > max,
  );
}
