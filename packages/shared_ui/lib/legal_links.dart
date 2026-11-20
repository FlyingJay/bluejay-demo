import 'package:shared_services/cloud_functions.dart' show kPublicHost;
import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// The current version of the Terms of Service and the Privacy Policy: each
/// page's `<meta name="bluejay-legal-version">`. Must match LEGAL_VERSIONS
/// in functions/_legal_terms.js (functions/_legal_terms.test.js checks all
/// three). Bumping one asks every account to accept again
/// (AccountSetupGate).
const kTermsVersion = '2';
const kPrivacyVersion = '2';

/// Whether signed-in accounts that haven't accepted the current versions
/// are stopped and asked to (AccountSetupGate).
const kPromptForLegalAcceptance = true;

/// Whether a users doc's `legalAcceptance` is for the current versions.
bool hasAcceptedCurrentLegal(Map<String, dynamic>? userData) {
  final acceptance = userData?['legalAcceptance'];
  return acceptance is Map &&
      acceptance['termsVersion'] == kTermsVersion &&
      acceptance['privacyVersion'] == kPrivacyVersion;
}

/// Bluejay's policy pages, served as static HTML by Hosting (web/privacy,
/// web/terms).
enum LegalPage {
  privacy('Privacy Policy', 'Privacy', '/privacy'),
  terms('Terms of Service', 'Terms', '/terms');

  const LegalPage(this.title, this.shortTitle, this.path);

  final String title;
  final String shortTitle;
  final String path;

  /// The page on the site the app is running from (so a preview channel
  /// opens its own copy), or on bluejay.gg outside the web.
  Uri get uri =>
      kIsWeb ? Uri.base.resolve(path) : Uri.https(kPublicHost, path);
}

/// Opens [page] in a new browser tab (web) or the system browser.
Future<void> openLegalPage(LegalPage page) => launchUrl(
  page.uri,
  mode: LaunchMode.externalApplication,
  webOnlyWindowName: '_blank',
);

/// Bluejay's landing page, `bluejay.gg/`, on the site the app is running
/// from (so a preview channel opens its own copy). A signed-out visitor
/// sees the landing page there (web/index.html).
Uri get bluejayHomeUri =>
    kIsWeb ? Uri.base.resolve('/') : Uri.https(kPublicHost, '/');

/// Opens the landing page in place of the app (web), or in the system
/// browser.
Future<void> openBluejayHome() => launchUrl(
  bluejayHomeUri,
  mode: LaunchMode.externalApplication,
  webOnlyWindowName: '_self',
);

/// Small "Privacy · Terms" text links for the foot of the sign-in and
/// signup screens. With [showAbout], an "About Bluejay" link to the landing
/// page comes first (the sign-in card).
class LegalLinks extends StatelessWidget {
  const LegalLinks({super.key, this.showAbout = false});

  /// Whether to lead with "About Bluejay", a link to the landing page.
  final bool showAbout;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: BjNeutral.inkSubtle);
    Widget button(String key, String label, VoidCallback onPressed) =>
        TextButton(
          key: ValueKey(key),
          onPressed: onPressed,
          style: TextButton.styleFrom(
            foregroundColor: BjNeutral.inkSubtle,
            textStyle: style,
            minimumSize: const Size(0, 36),
            padding: const EdgeInsets.symmetric(horizontal: BjSpace.sm),
          ),
          child: Text(label),
        );
    Widget link(LegalPage page) => button(
      'legal-link-${page.name}',
      page.shortTitle,
      () => openLegalPage(page),
    );
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (showAbout) ...[
          button('legal-link-about', 'About Bluejay', openBluejayHome),
          Text('·', style: style),
        ],
        link(LegalPage.privacy),
        Text('·', style: style),
        link(LegalPage.terms),
      ],
    );
  }
}

/// "I agree to the Terms of Service and Privacy Policy", a checkbox with
/// both titles linking to their pages. Shown wherever an account is created
/// or asked to accept again; the form sends `acceptedTerms: true` only once
/// it's ticked, and the server records the acceptance (functions/_legal_terms.js).
class LegalAgreement extends StatelessWidget {
  const LegalAgreement({
    super.key,
    required this.accepted,
    required this.onChanged,
    this.showError = false,
  });

  final bool accepted;
  final ValueChanged<bool> onChanged;

  /// Shows "Accept the terms to continue" under an unticked box (after the
  /// person tried to continue without ticking it).
  final bool showError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: BjNeutral.inkMuted,
    );
    final linkStyle = style?.copyWith(
      color: theme.colorScheme.primary,
      decoration: TextDecoration.underline,
    );
    InlineSpan link(LegalPage page) => WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: InkWell(
        key: ValueKey('legal-agreement-${page.name}'),
        onTap: () => openLegalPage(page),
        child: Text(page.title, style: linkStyle),
      ),
    );
    return Column(
      key: const ValueKey('legal-agreement'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Checkbox(
              key: const ValueKey('legal-agreement-checkbox'),
              value: accepted,
              onChanged: (value) => onChanged(value ?? false),
            ),
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(!accepted),
                child: Text.rich(
                  TextSpan(
                    style: style,
                    children: [
                      const TextSpan(text: 'I agree to the '),
                      link(LegalPage.terms),
                      const TextSpan(text: ' and '),
                      link(LegalPage.privacy),
                      const TextSpan(text: '.'),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        if (showError && !accepted)
          Padding(
            padding: const EdgeInsets.only(left: BjSpace.md),
            child: Text(
              'Accept the terms to continue.',
              key: const ValueKey('legal-agreement-error'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}
