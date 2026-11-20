/// What someone typed in a sign-in form's "Username or email" field, as the
/// Firebase Auth emails to try, in order.
///
/// A Bluejay username signs in as `<username>@bluejay.gg`, then the legacy
/// `<username>@bluejay.ca` for older accounts. An address on either of those
/// domains counts as its username. Any other email address (a client of a
/// group's portal signs in with their real one) is used as it is.
class LoginIdentifier {
  const LoginIdentifier._({this.username, required this.emails});

  /// The login domains of username accounts, preferred first.
  static const usernameDomains = ['bluejay.gg', 'bluejay.ca'];

  /// The username, or null when the input is an outside email address.
  final String? username;

  /// The Auth emails to try, in order. Empty when the input is blank.
  final List<String> emails;

  bool get isUsername => username != null;

  /// The address a username account prefers (`@bluejay.gg`), or the email
  /// itself for an outside address.
  String? get primaryEmail => emails.isEmpty ? null : emails.first;

  /// Whether [email] is the legacy `@bluejay.ca` login of a username.
  static bool isLegacyEmail(String email) => email.endsWith('@${usernameDomains.last}');

  static LoginIdentifier parse(String input) {
    final value = input.trim().toLowerCase();
    if (value.isEmpty) return const LoginIdentifier._(emails: []);
    final at = value.lastIndexOf('@');
    if (at < 0) return _username(value);
    final local = value.substring(0, at);
    final domain = value.substring(at + 1);
    if (usernameDomains.contains(domain) && local.isNotEmpty) return _username(local);
    return LoginIdentifier._(emails: [value]);
  }

  static LoginIdentifier _username(String username) => LoginIdentifier._(
        username: username,
        emails: [for (final domain in usernameDomains) '$username@$domain'],
      );
}
