/// Sales tax on Bluejay's own prices and invoices: the setting in
/// `platform_config/billing_tax` (functions/_billing_tax.js), as the
/// price-quoting callables return it in `tax` (signupCatalog,
/// groupPurchasesStatus, groupSeatsStatus, groupAdminGet).
///
/// Tax is off until Bluejay is registered for GST/HST. While it is off, no
/// price mentions tax. Every "plus tax" / "before tax" phrase in Bluejay's
/// pricing copy comes from this class, so the wording follows the setting
/// everywhere at once. Apps that bill a group's own customers (Invoices,
/// Budgie Ting) have their own tax rates and don't use this.
class PlatformTax {
  const PlatformTax({
    this.enabled = false,
    this.rateBps = 0,
    this.label,
    this.registrationNumber,
  });

  /// No tax: the default whenever the setting is missing or unreadable.
  static const PlatformTax off = PlatformTax();

  /// The wording for something already billed: [taxed] when that invoice
  /// was issued with tax.
  const PlatformTax.applied(bool taxed) : this(enabled: taxed);

  /// A callable's `tax` map. Anything short of `enabled: true` with a
  /// registration number reads as [off], as on the server.
  factory PlatformTax.fromData(Object? data) {
    if (data is! Map) return off;
    final number = data['registrationNumber'];
    final registration = number is String ? number.trim() : '';
    if (data['enabled'] != true || registration.isEmpty) return off;
    final rate = data['rateBps'];
    final label = data['label'];
    return PlatformTax(
      enabled: true,
      rateBps: rate is num ? rate.toInt() : 0,
      label: label is String && label.trim().isNotEmpty ? label.trim() : null,
      registrationNumber: registration,
    );
  }

  /// Whether prices are quoted plus tax and invoices charge it.
  final bool enabled;

  /// The rate in basis points (1300 is 13%), 0 while off.
  final int rateBps;

  /// The tax line's label, such as `HST (Ontario)`.
  final String? label;

  /// Bluejay's tax registration number, printed on taxed invoices.
  final String? registrationNumber;

  /// ` + tax` after a price: `CA$49.99/month + tax`.
  String get plusShort => enabled ? ' + tax' : '';

  /// ` plus tax` after a price: `I agree to pay CA$49.99 plus tax`.
  String get plus => enabled ? ' plus tax' : '';

  /// `, plus tax` after a phrase: `Up to 5 people, plus tax`.
  String get commaPlus => enabled ? ', plus tax' : '';

  /// `, plus tax,` set into a sentence: `billed on the 1st, plus tax, to
  /// your card`.
  String get plusAside => enabled ? ', plus tax,' : '';

  /// ` before tax` after a phrase: `Per group before tax`.
  String get before => enabled ? ' before tax' : '';

  /// `, before tax` after a phrase: `Paid invoices, before tax`.
  String get commaBefore => enabled ? ', before tax' : '';

  /// [rest] (a sentence starting in lower case) led by `Plus tax, ` while
  /// tax applies, else on its own with a capital: `Plus tax, billed
  /// monthly…` or `Billed monthly…`.
  String plusTaxThen(String rest) {
    if (enabled) return 'Plus tax, $rest';
    return rest.isEmpty ? rest : '${rest[0].toUpperCase()}${rest.substring(1)}';
  }

  /// The line a taxed invoice shows: `Bluejay's tax registration number: …`.
  static String registrationLine(String number) => "Bluejay's tax registration number: $number";

  @override
  bool operator ==(Object other) =>
      other is PlatformTax &&
      other.enabled == enabled &&
      other.rateBps == rateBps &&
      other.label == label &&
      other.registrationNumber == registrationNumber;

  @override
  int get hashCode => Object.hash(enabled, rateBps, label, registrationNumber);
}
