import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:shared_services/corporate_access_service.dart';
import 'package:shared_services/user_app_entitlements.dart';

/// Email check used by [GuestIdentityGate]; the server re-validates.
final RegExp kGuestEmailPattern = RegExp(r'^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$');

/// How a [GuestIdentityGate] looks. Every field defaults to the bluejay
/// design system (the group's accent, the soft canvas, rounded cards); an
/// app with its own brand can override any of them.
class GuestIdentityGateStyle {
  const GuestIdentityGateStyle({
    this.primaryColor,
    this.primaryDarkColor,
    this.backgroundColor,
    this.errorColor,
    this.radius = BjRadius.xl,
    this.cardDecoration,
    this.headingStyle,
    this.bodyStyle,
  });

  /// The hero gradient's start and the button colour; the accent when null.
  final Color? primaryColor;

  /// The hero gradient's end; the secondary accent when null.
  final Color? primaryDarkColor;
  final Color? backgroundColor;
  final Color? errorColor;
  final double radius;

  /// The form and denial cards' decoration; a [BjCard] when null.
  final BoxDecoration? cardDecoration;
  final TextStyle? headingStyle;
  final TextStyle? bodyStyle;

  Color errorOf(BuildContext context) =>
      errorColor ?? context.bj.tone(BjTone.danger).foreground;

  TextStyle? headingOf(BuildContext context) =>
      headingStyle ?? Theme.of(context).textTheme.titleLarge;

  TextStyle? bodyOf(BuildContext context) =>
      bodyStyle ??
      Theme.of(context).textTheme.bodyMedium?.copyWith(color: BjNeutral.inkMuted);
}

/// The words on a [GuestIdentityGate].
class GuestIdentityGateText {
  const GuestIdentityGateText({
    this.formHeading = 'Access request',
    this.prompt = 'Please provide your name and work email to continue.',
    this.emailLabel = 'Work email',
    this.emailHint = 'e.g. jane.smith@company.com',
    this.nameHint = 'e.g. Jane Smith',
    this.deniedTitle = 'Access not approved',
    this.deniedMessage =
        'Your organisation is not currently approved for this app. Please contact your administrator.',
    this.retryLabel = 'Use a different email',
  });

  final String formHeading;
  final String prompt;
  final String emailLabel;
  final String emailHint;
  final String nameHint;
  final String deniedTitle;
  final String deniedMessage;

  /// The denial card's button that goes back to the form.
  final String retryLabel;
}

/// Asks a corporate guest for their name and work email, then has the server
/// check the email's domain against [targetAppId]'s allowlist in [groupId]
/// (`corporateAccessSetGuestIdentity`). The server emails a one-time code to
/// the address and the gate asks for it, so a guest can only claim an address
/// they control. Shared by every embeddable app that
/// admits corporate guests; each supplies its own title, words and style.
///
/// Show it only when the server says the guest still needs to confirm an
/// email: a refusal with reason `identity-required`, or [GuestAdmissionGate]
/// for an app that opens without a server call. The server answers by the
/// app's actual access mode, so in public mode the first submit is accepted
/// without an email check, and a refused address can be swapped for another
/// from the denial card.
class GuestIdentityGate extends StatefulWidget {
  const GuestIdentityGate({
    super.key,
    required this.groupId,
    required this.targetAppId,
    required this.title,
    required this.subtitle,
    required this.onIdentityConfirmed,
    this.icon = Icons.verified_outlined,
    this.style = const GuestIdentityGateStyle(),
    this.text = const GuestIdentityGateText(),
    this.verify,
  });

  final String groupId;
  final String targetAppId;
  final String title;
  final String subtitle;
  final IconData icon;
  final GuestIdentityGateStyle style;
  final GuestIdentityGateText text;

  /// Called once the server accepts the identity. The gate is ready for
  /// another try when this returns, in case the app still can't proceed.
  final VoidCallback onIdentityConfirmed;

  /// Overrides the server check (tests). Gets the code the guest typed, or
  /// null on the first submit.
  final Future<GuestIdentityStatus> Function(String name, String email, String? code)? verify;

  @override
  State<GuestIdentityGate> createState() => _GuestIdentityGateState();
}

class _GuestIdentityGateState extends State<GuestIdentityGate> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _code = TextEditingController();
  bool _loading = false;
  // Set once a code has been emailed: the gate then asks for it.
  String? _codeSentTo;
  bool _denied = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_loading || !(_formKey.currentState?.validate() ?? false)) return;
    if (widget.groupId.isEmpty) {
      setState(() => _error = 'Unable to determine the group. Please reload the page.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _denied = false;
    });
    final name = _name.text.trim();
    final email = _email.text.trim().toLowerCase();
    // A code only counts for the address it was sent to.
    final code = _codeSentTo == email ? _code.text.trim() : null;
    GuestIdentityStatus status;
    try {
      status = widget.verify != null
          ? await widget.verify!(name, email, code)
          : await CorporateAccessService().submitGuestIdentity(
              groupId: widget.groupId,
              targetAppId: widget.targetAppId,
              guestEmail: email,
              guestName: name,
              code: code,
            );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Something went wrong. Please try again or contact support.';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      switch (status) {
        case GuestIdentityStatus.allowed:
          break;
        case GuestIdentityStatus.codeSent:
          _codeSentTo = email;
          _code.clear();
        case GuestIdentityStatus.codeInvalid:
          _error = "That code didn't work. Check the email we sent, or change the address to get a new code.";
        case GuestIdentityStatus.rateLimited:
          _error = 'Too many codes have been sent. Please wait an hour and try again.';
        case GuestIdentityStatus.sendSkipped:
          _error = "This workspace doesn't send email, so your address can't be confirmed here. "
              'Please contact your administrator.';
        case GuestIdentityStatus.denied:
          _denied = true;
      }
    });
    if (status == GuestIdentityStatus.allowed) widget.onIdentityConfirmed();
  }

  /// Back to the form from the denial card, so the guest can enter a
  /// different address (any code sent for the refused one no longer counts).
  void _tryAnotherEmail() {
    setState(() {
      _denied = false;
      _error = null;
      _codeSentTo = null;
      _code.clear();
    });
  }

  Widget _card({required Widget child}) {
    final style = widget.style;
    const padding = EdgeInsets.all(BjSpace.xl);
    if (style.cardDecoration == null) {
      return BjCard(padding: padding, radius: BjRadius.xl, child: child);
    }
    return Container(padding: padding, decoration: style.cardDecoration, child: child);
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final text = widget.text;
    final bj = context.bj;
    final textTheme = Theme.of(context).textTheme;
    final gradient = style.primaryColor == null
        ? bj.heroGradient
        : LinearGradient(
            colors: [style.primaryColor!, style.primaryDarkColor ?? style.primaryColor!],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          );
    return Scaffold(
      backgroundColor: style.backgroundColor ?? BjNeutral.canvas,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(BjSpace.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(BjSpace.xl + 4),
                  decoration: BoxDecoration(
                    gradient: gradient,
                    borderRadius: BorderRadius.circular(style.radius),
                    boxShadow: bj.shadowMd,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(BjSpace.sm + 2),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(style.radius / 2),
                        ),
                        child: Icon(widget.icon, color: Colors.white, size: 28),
                      ),
                      const SizedBox(height: BjSpace.lg),
                      Text(widget.title,
                          style: textTheme.headlineSmall?.copyWith(color: Colors.white)),
                      const SizedBox(height: BjSpace.xs),
                      Text(widget.subtitle,
                          style: textTheme.bodyMedium
                              ?.copyWith(color: Colors.white.withValues(alpha: 0.88))),
                    ],
                  ),
                ),
                const SizedBox(height: BjSpace.xl),
                if (_denied)
                  GuestAccessDeniedCard(
                    title: text.deniedTitle,
                    message: text.deniedMessage,
                    style: style,
                    retryLabel: text.retryLabel,
                    onRetry: _tryAnotherEmail,
                  )
                else
                  _card(
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(text.formHeading, style: style.headingOf(context)),
                          const SizedBox(height: BjSpace.xs),
                          Text(text.prompt, style: style.bodyOf(context)),
                          const SizedBox(height: BjSpace.xl),
                          TextFormField(
                            controller: _name,
                            enabled: !_loading,
                            textCapitalization: TextCapitalization.words,
                            decoration: InputDecoration(
                              labelText: 'Full name',
                              hintText: text.nameHint,
                              prefixIcon: const Icon(Icons.person_outline),
                            ),
                            validator: (v) => (v == null || v.trim().isEmpty) ? 'Please enter your name.' : null,
                          ),
                          const SizedBox(height: BjSpace.lg),
                          TextFormField(
                            controller: _email,
                            enabled: !_loading,
                            keyboardType: TextInputType.emailAddress,
                            autocorrect: false,
                            decoration: InputDecoration(
                              labelText: text.emailLabel,
                              hintText: text.emailHint,
                              prefixIcon: const Icon(Icons.email_outlined),
                            ),
                            validator: (v) {
                              final email = (v ?? '').trim().toLowerCase();
                              if (email.isEmpty) return 'Please enter your ${text.emailLabel.toLowerCase()}.';
                              if (!kGuestEmailPattern.hasMatch(email)) return 'Please enter a valid email address.';
                              return null;
                            },
                            onFieldSubmitted: (_) => _submit(),
                          ),
                          if (_codeSentTo != null) ...[
                            const SizedBox(height: BjSpace.lg),
                            Text('We emailed a code to $_codeSentTo. Enter it to continue.', style: style.bodyOf(context)),
                            const SizedBox(height: BjSpace.sm),
                            TextFormField(
                              controller: _code,
                              enabled: !_loading,
                              autocorrect: false,
                              textCapitalization: TextCapitalization.characters,
                              decoration: const InputDecoration(
                                labelText: 'Code',
                                hintText: 'XXXX-XXXX-XXXX-XXXX',
                                prefixIcon: Icon(Icons.pin_outlined),
                              ),
                              validator: (v) => _codeSentTo == _email.text.trim().toLowerCase() &&
                                      (v ?? '').trim().isEmpty
                                  ? 'Please enter the code from the email.'
                                  : null,
                              onFieldSubmitted: (_) => _submit(),
                            ),
                          ],
                          if (_error != null) ...[
                            const SizedBox(height: BjSpace.md),
                            BjInlineNote(_error!, icon: Icons.error_outline_rounded, tone: BjTone.danger),
                          ],
                          const SizedBox(height: BjSpace.xl),
                          FilledButton(
                            onPressed: _loading ? null : _submit,
                            style: FilledButton.styleFrom(
                              backgroundColor: style.primaryColor,
                              padding: const EdgeInsets.symmetric(vertical: BjSpace.md + 2),
                            ),
                            child: _loading
                                ? const SizedBox(
                                    height: 18,
                                    width: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  )
                                : const Text('Continue'),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown when a guest's organisation isn't on an app's allowlist.
class GuestAccessDeniedCard extends StatelessWidget {
  const GuestAccessDeniedCard({
    super.key,
    required this.title,
    required this.message,
    this.style = const GuestIdentityGateStyle(),
    this.onRetry,
    this.retryLabel = 'Use a different email',
  });

  final String title;
  final String message;
  final GuestIdentityGateStyle style;

  /// Shows a [retryLabel] button that calls this, when set.
  final VoidCallback? onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      children: [
        if (style.errorColor == null)
          const BjIconWell(icon: Icons.block_outlined, tone: BjTone.danger, size: 64)
        else
          Icon(Icons.block_outlined, color: style.errorColor, size: 48),
        const SizedBox(height: BjSpace.lg),
        Text(title, style: style.headingOf(context), textAlign: TextAlign.center),
        const SizedBox(height: BjSpace.sm),
        Text(message, textAlign: TextAlign.center, style: style.bodyOf(context)),
        if (onRetry != null) ...[
          const SizedBox(height: BjSpace.xl),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.edit_outlined),
            label: Text(retryLabel),
          ),
        ],
      ],
    );
    const padding = EdgeInsets.all(BjSpace.xl);
    if (style.cardDecoration == null) {
      return BjCard(padding: padding, radius: BjRadius.xl, child: content);
    }
    return Container(padding: padding, decoration: style.cardDecoration, child: content);
  }
}

/// Whether [entitlements] admit a guest to [appId] in the group [groupDocId]
/// (`groups/{id}`): the `{groupDocId}:{appId}:guest` entitlement the access
/// index rebuild grants only to guests the app's access mode admits
/// (computeEntitlements and functions/_guest_admission.js). Public access
/// grants it when the session starts; corporate access once the guest's work
/// email is confirmed and on the allowlist.
bool guestAdmittedTo(UserAppEntitlements entitlements, String groupDocId, String appId) {
  if (groupDocId.isEmpty || appId.isEmpty) return false;
  if (entitlements.status != 'ACTIVE' || entitlements.deniedScopes.contains(groupDocId)) return false;
  return entitlements.entitlements.contains('$groupDocId:$appId:guest');
}

/// Shows [child] once the server admits the signed-in guest to [appId], and
/// [gate] (normally a [GuestIdentityGate]) until then. For apps that open
/// without a server call, so the decision follows the group's actual access
/// mode for the app: a public guest goes straight in, a corporate guest
/// confirms their email first. Reads the guest's access index
/// ([guestAdmittedTo]).
class GuestAdmissionGate extends StatelessWidget {
  const GuestAdmissionGate({
    super.key,
    required this.uid,
    required this.groupDocId,
    required this.appId,
    required this.gate,
    required this.child,
    this.loading,
    this.entitlements,
  });

  final String uid;

  /// The group's document id (`groups/{id}`), as in the access index.
  final String groupDocId;

  /// The app's `apps/{docId}` id.
  final String appId;
  final Widget gate;
  final Widget child;

  /// Shown until the access index arrives; a spinner when null.
  final Widget? loading;

  /// Overrides the access index stream (tests).
  final Stream<UserAppEntitlements>? entitlements;

  @override
  Widget build(BuildContext context) {
    Widget decide(BuildContext context, AsyncSnapshot<UserAppEntitlements> snapshot) {
      final current = snapshot.data;
      if (current == null) {
        return loading ?? const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      return guestAdmittedTo(current, groupDocId, appId) ? child : gate;
    }

    final override = entitlements;
    if (override != null) return StreamBuilder<UserAppEntitlements>(stream: override, builder: decide);
    return UserAppEntitlementsBuilder(uid: uid, appId: appId, builder: decide);
  }
}
