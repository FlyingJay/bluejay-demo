import 'package:shared_services/cloud_functions.dart';

/// Bytes in a GB as the server counts them (GiB, like [formatBytes]).
const int bytesPerGb = 1024 * 1024 * 1024;

/// The group's Storage plan, as `storageBillingStatus` returns it
/// (functions/_storage_billing.js).
class StoragePlanStatus {
  const StoragePlanStatus({
    required this.plan,
    required this.usageBytes,
    required this.freeTierGb,
    required this.uploadsAllowed,
    required this.pricePerGbMonth,
    required this.currentPricePerGbMonth,
    required this.currency,
    required this.estimatedMonthlyCost,
    required this.canManage,
    this.payerIsYou = false,
    this.payerEmail,
    this.hasPaymentMethod,
  });

  static const free = 'free';
  static const payAsYouGo = 'pay_as_you_go';
  static const unlimited = 'unlimited';

  /// [free], [payAsYouGo] or [unlimited] (granted by Bluejay, never billed).
  final String plan;
  final int usageBytes;
  final double freeTierGb;
  final bool uploadsAllowed;

  /// The price this group pays per GB-month above the free tier: the one its
  /// payer accepted on pay as you go, else today's.
  final double pricePerGbMonth;

  /// Today's price, which turning on pay as you go accepts.
  final double currentPricePerGbMonth;
  final String currency;

  /// What a month at today's usage would cost on pay as you go.
  final double estimatedMonthlyCost;
  final bool canManage;
  final bool payerIsYou;

  /// Only shown to the group's admins.
  final String? payerEmail;

  /// Whether the caller has a default card (admins only; null otherwise).
  final bool? hasPaymentMethod;

  int get freeTierBytes => (freeTierGb * bytesPerGb).round();
  bool get isFree => plan == free;
  bool get isPayAsYouGo => plan == payAsYouGo;
  bool get isUnlimited => plan == unlimited;

  /// Whether the group can take [bytes] more: always, unless it's on the
  /// free tier and they'd take it past the tier.
  bool allowsUpload(int bytes) =>
      !isFree || usageBytes + bytes <= freeTierBytes;

  /// The share of the free tier in use, 0–1 (can pass 1 on pay as you go).
  double get freeTierShare =>
      freeTierBytes <= 0 ? 0 : usageBytes / freeTierBytes;

  factory StoragePlanStatus.fromMap(Map<String, dynamic> data) {
    double number(Object? value) => (value as num?)?.toDouble() ?? 0;
    final price = (data['price'] as Map?)?.cast<String, dynamic>() ?? const {};
    return StoragePlanStatus(
      plan: data['plan'] as String? ?? free,
      usageBytes: (data['usageBytes'] as num?)?.toInt() ?? 0,
      freeTierGb: number(data['freeTierGiB']),
      uploadsAllowed: data['uploadsAllowed'] != false,
      pricePerGbMonth: number(price['pricePerGiBMonth']),
      currentPricePerGbMonth: number(
          price['currentPricePerGiBMonth'] ?? price['pricePerGiBMonth']),
      currency: price['currency'] as String? ?? 'CAD',
      estimatedMonthlyCost: number(data['estimatedMonthlyCost']),
      canManage: data['canManage'] == true,
      payerIsYou: data['payerIsYou'] == true,
      payerEmail: data['payerEmail'] as String?,
      hasPaymentMethod: data['hasPaymentMethod'] as bool?,
    );
  }
}

/// Reads and changes the active group's Storage plan.
class StoragePlanService {
  const StoragePlanService();

  Future<StoragePlanStatus> status(String groupId) async {
    final result = await BluejayFunctions.instance
        .httpsCallable('storageBillingStatus')
        .call({'groupId': groupId});
    return StoragePlanStatus.fromMap(
        (result.data as Map).cast<String, dynamic>());
  }

  /// Switches to [plan]; pay as you go passes the price the admin accepted.
  Future<StoragePlanStatus> setPlan(
    String groupId,
    String plan, {
    double? acceptedPricePerGbMonth,
  }) async {
    final result = await BluejayFunctions.instance
        .httpsCallable('storageBillingSetPlan')
        .call({
      'groupId': groupId,
      'plan': plan,
      if (acceptedPricePerGbMonth != null)
        'acceptedPricePerGiBMonth': acceptedPricePerGbMonth,
    });
    return StoragePlanStatus.fromMap(
        (result.data as Map).cast<String, dynamic>());
  }
}

/// A price as "CA$0.0644" (up to 4 decimals below a dollar) or "CA$6.44".
String formatPrice(double amount, String currency) {
  final symbol = switch (currency) {
    'CAD' => r'CA$',
    'USD' => r'US$',
    _ => '$currency ',
  };
  if (amount > 0 && amount < 1) {
    var digits = amount.toStringAsFixed(4);
    while (digits.endsWith('0') && !digits.endsWith('.00')) {
      digits = digits.substring(0, digits.length - 1);
    }
    return '$symbol$digits';
  }
  return '$symbol${amount.toStringAsFixed(2)}';
}

/// A GB count as "50 GB" or "12.5 GB".
String formatGb(double gb) {
  final rounded = (gb * 10).round() / 10;
  return rounded == rounded.roundToDouble()
      ? '${rounded.toInt()} GB'
      : '${rounded.toStringAsFixed(1)} GB';
}
