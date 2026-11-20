import 'package:bluejay_design/bluejay_design.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_services/federated_sign_in.dart';
import 'package:shared_ui/readable_selectable_text.dart';

/// Firebase's factor id for authenticator-app codes.
const _totpFactorId = 'totp';

/// The issuer authenticator apps show next to a Bluejay code.
const _totpIssuer = 'Bluejay';

/// Finishes a sign-in that needs a second step: asks for the code from the
/// person's authenticator app and resolves [error] with it. Returns null
/// when they cancel. Used by every sign-in path (password and providers).
Future<fire_auth.UserCredential?> completeTwoStepSignIn(
  BuildContext context,
  fire_auth.FirebaseAuthMultiFactorException error,
) async {
  final resolver = error.resolver;
  final hint =
      resolver.hints.where((h) => h.factorId == _totpFactorId).firstOrNull;
  if (hint == null) {
    BjSnack.error(
      context,
      'Your account uses a second step this app doesn\'t support. Contact '
      'support.',
    );
    return null;
  }
  return showDialog<fire_auth.UserCredential>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CodeDialog(
      title: 'Enter your code',
      message: 'Open your authenticator app and enter the 6-digit code for '
          'Bluejay.',
      submitLabel: 'Sign in',
      onSubmit: (code) async {
        final assertion =
            await fire_auth.TotpMultiFactorGenerator.getAssertionForSignIn(
          hint.uid,
          code,
        );
        return resolver.resolveSignIn(assertion);
      },
    ),
  );
}

/// Whether [user] has turned on two-step sign-in with an authenticator app.
Future<bool> hasTwoStepSignIn(fire_auth.User user) async {
  final factors = await user.multiFactor.getEnrolledFactors();
  return factors.any((f) => f.factorId == _totpFactorId);
}

/// The profile's "Sign-in and security" card: the identity providers linked
/// to the account (connect or disconnect each) and two-step sign-in with an
/// authenticator app (turn on or off).
class AccountSecuritySection extends StatefulWidget {
  const AccountSecuritySection({super.key, required this.user});

  final fire_auth.User user;

  @override
  State<AccountSecuritySection> createState() => _AccountSecuritySectionState();
}

class _AccountSecuritySectionState extends State<AccountSecuritySection> {
  bool? _twoStep;
  bool _busy = false;

  fire_auth.User get _user =>
      fire_auth.FirebaseAuth.instance.currentUser ?? widget.user;

  @override
  void initState() {
    super.initState();
    _loadTwoStep();
  }

  Future<void> _loadTwoStep() async {
    try {
      final on = await hasTwoStepSignIn(_user);
      if (mounted) setState(() => _twoStep = on);
    } catch (_) {
      if (mounted) setState(() => _twoStep = false);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on FederatedSignInException catch (e) {
      if (mounted) BjSnack.error(context, e.message);
    } on fire_auth.FirebaseAuthException catch (e) {
      if (mounted) BjSnack.error(context, _authMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect(FederatedProvider provider) => _run(() async {
        if (await FederatedSignIn.link(provider) && mounted) {
          BjSnack.success(
            context,
            'Connected. You can now sign in with ${provider.label}.',
          );
        }
      });

  Future<void> _disconnect(FederatedProvider provider) => _run(() async {
        final ok = await _confirm(
          title: 'Disconnect ${provider.label}?',
          message: 'You won\'t be able to sign in with ${provider.label} until '
              'you connect it again.',
          action: 'Disconnect',
        );
        if (!ok) return;
        await FederatedSignIn.unlink(provider);
        if (mounted)
          BjSnack.success(context, '${provider.label} disconnected.');
      });

  Future<void> _turnOnTwoStep() async {
    final enrolled = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TotpEnrollmentSheet(user: _user),
    );
    if (enrolled == true) {
      if (mounted) setState(() => _twoStep = true);
      if (mounted) BjSnack.success(context, 'Two-step sign-in is on.');
    }
  }

  Future<void> _turnOffTwoStep() => _run(() async {
        final ok = await _confirm(
          title: 'Turn off two-step sign-in?',
          message: 'You\'ll sign in with only your password or provider.',
          action: 'Turn off',
        );
        if (!ok) return;
        final factors = await _user.multiFactor.getEnrolledFactors();
        for (final factor
            in factors.where((f) => f.factorId == _totpFactorId)) {
          await _user.multiFactor.unenroll(multiFactorInfo: factor);
        }
        if (mounted) setState(() => _twoStep = false);
        if (mounted) BjSnack.success(context, 'Two-step sign-in is off.');
      });

  Future<bool> _confirm({
    required String title,
    required String message,
    required String action,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final linked = linkedProviders(_user);
    final text = Theme.of(context).textTheme;
    return BjCard(
      key: const ValueKey('account-security'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Sign-in and security', style: text.titleMedium),
          const SizedBox(height: BjSpace.xs),
          Text(
            'You sign in as ${_user.email ?? 'your username'}.',
            style: text.bodySmall?.copyWith(color: BjNeutral.inkMuted),
          ),
          for (final provider in FederatedProvider.available)
            ListTile(
              key: ValueKey('account-security-${provider.name}'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.login_rounded),
              title: Text(provider.label),
              subtitle: Text(
                linked.contains(provider)
                    ? 'Connected${_emailSuffix(provider)}'
                    : 'Sign in with your ${provider.label} account',
              ),
              trailing: linked.contains(provider)
                  ? TextButton(
                      onPressed: _busy ? null : () => _disconnect(provider),
                      child: const Text('Disconnect'),
                    )
                  : OutlinedButton(
                      onPressed: _busy ? null : () => _connect(provider),
                      child: const Text('Connect'),
                    ),
            ),
          ListTile(
            key: const ValueKey('account-security-two-step'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.verified_user_outlined),
            title: const Text('Two-step sign-in'),
            subtitle: Text(
              _twoStep == null
                  ? 'Checking…'
                  : _twoStep!
                      ? 'On: you enter a code from your authenticator app when '
                          'you sign in.'
                      : 'Ask for a code from an authenticator app when you sign '
                          'in.',
            ),
            trailing: _twoStep == null
                ? null
                : _twoStep!
                    ? TextButton(
                        onPressed: _busy ? null : _turnOffTwoStep,
                        child: const Text('Turn off'),
                      )
                    : OutlinedButton(
                        onPressed: _busy ? null : _turnOnTwoStep,
                        child: const Text('Turn on'),
                      ),
          ),
        ],
      ),
    );
  }

  String _emailSuffix(FederatedProvider provider) {
    final email = providerEmail(_user, provider);
    return email == null || email.isEmpty ? '' : ' as $email';
  }
}

String _authMessage(fire_auth.FirebaseAuthException e) {
  switch (e.code) {
    case 'requires-recent-login':
      return 'For your security, sign out and sign in again, then try this '
          'again.';
    case 'invalid-verification-code':
      return 'That code didn\'t work. Check your authenticator app and try '
          'again.';
    case 'operation-not-allowed':
      return 'Two-step sign-in isn\'t available yet.';
    case 'unverified-email':
      return 'Your account needs a verified email for this. Contact support.';
  }
  return e.message ?? 'Something went wrong. Try again.';
}

/// Sets up an authenticator app: shows the QR code and key, then confirms
/// with a code from the app. Pops true once enrolled.
class _TotpEnrollmentSheet extends StatefulWidget {
  const _TotpEnrollmentSheet({required this.user});

  final fire_auth.User user;

  @override
  State<_TotpEnrollmentSheet> createState() => _TotpEnrollmentSheetState();
}

class _TotpEnrollmentSheetState extends State<_TotpEnrollmentSheet> {
  fire_auth.TotpSecret? _secret;
  String? _qrUrl;
  String? _error;
  final _code = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final session = await widget.user.multiFactor.getSession();
      final secret = await fire_auth.TotpMultiFactorGenerator.generateSecret(
        session,
      );
      final url = await secret.generateQrCodeUrl(
        accountName: widget.user.email,
        issuer: _totpIssuer,
      );
      if (mounted) {
        setState(() {
          _secret = secret;
          _qrUrl = url;
        });
      }
    } on fire_auth.FirebaseAuthException catch (e) {
      if (mounted) setState(() => _error = _authMessage(e));
    }
  }

  Future<void> _confirm() async {
    final secret = _secret;
    final code = _code.text.trim();
    if (secret == null || code.length != 6 || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final assertion =
          await fire_auth.TotpMultiFactorGenerator.getAssertionForEnrollment(
        secret,
        code,
      );
      await widget.user.multiFactor.enroll(
        assertion,
        displayName: 'Authenticator app',
      );
      if (mounted) Navigator.of(context).pop(true);
    } on fire_auth.FirebaseAuthException catch (e) {
      if (mounted) setState(() => _error = _authMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final secret = _secret;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          BjSpace.xl,
          BjSpace.lg,
          BjSpace.xl,
          BjSpace.xl + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Turn on two-step sign-in', style: text.titleLarge),
              const SizedBox(height: BjSpace.sm),
              Text(
                'Scan this code with an authenticator app (Google '
                'Authenticator, 1Password, Microsoft Authenticator…), then '
                'enter the 6-digit code it shows.',
                style: text.bodyMedium?.copyWith(color: BjNeutral.inkMuted),
              ),
              const SizedBox(height: BjSpace.lg),
              if (_qrUrl == null && _error == null)
                const Center(child: CircularProgressIndicator())
              else if (_qrUrl != null) ...[
                Center(
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(BjSpace.sm),
                    child: QrImageView(data: _qrUrl!, size: 200),
                  ),
                ),
                const SizedBox(height: BjSpace.sm),
                Center(
                  child: ReadableSelectableText(
                    secret?.secretKey ?? '',
                    key: const ValueKey('totp-secret-key'),
                    style: text.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      color: BjNeutral.inkMuted,
                    ),
                  ),
                ),
                const SizedBox(height: BjSpace.lg),
                TextField(
                  key: const ValueKey('totp-enroll-code'),
                  controller: _code,
                  enabled: !_busy,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
                  decoration: const InputDecoration(
                    labelText: '6-digit code',
                    prefixIcon: Icon(Icons.pin_outlined),
                  ),
                  onSubmitted: (_) => _confirm(),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: BjSpace.md),
                BjInlineNote(
                  _error!,
                  icon: Icons.error_outline_rounded,
                  tone: BjTone.danger,
                ),
              ],
              const SizedBox(height: BjSpace.lg),
              FilledButton(
                key: const ValueKey('totp-enroll-confirm'),
                onPressed: secret == null || _busy ? null : _confirm,
                child: Text(_busy ? 'Checking…' : 'Turn on'),
              ),
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Asks for a 6-digit code and runs [onSubmit] with it; pops its result.
class _CodeDialog extends StatefulWidget {
  const _CodeDialog({
    required this.title,
    required this.message,
    required this.submitLabel,
    required this.onSubmit,
  });

  final String title;
  final String message;
  final String submitLabel;
  final Future<fire_auth.UserCredential> Function(String code) onSubmit;

  @override
  State<_CodeDialog> createState() => _CodeDialogState();
}

class _CodeDialogState extends State<_CodeDialog> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _code.text.trim();
    if (code.length != 6 || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final credential = await widget.onSubmit(code);
      if (mounted) Navigator.of(context).pop(credential);
    } on fire_auth.FirebaseAuthException catch (e) {
      if (mounted) setState(() => _error = _authMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.message),
          const SizedBox(height: BjSpace.md),
          TextField(
            key: const ValueKey('two-step-code'),
            controller: _code,
            enabled: !_busy,
            autofocus: true,
            keyboardType: TextInputType.number,
            autofillHints: const [AutofillHints.oneTimeCode],
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            decoration: InputDecoration(
              labelText: '6-digit code',
              errorText: _error,
              errorMaxLines: 3,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('two-step-submit'),
          onPressed: _busy ? null : _submit,
          child: Text(widget.submitLabel),
        ),
      ],
    );
  }
}
