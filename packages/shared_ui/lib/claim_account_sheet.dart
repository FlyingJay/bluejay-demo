import 'dart:async';

import 'package:bluejay_design/bluejay_design.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';
import 'package:shared_services/guest_user_service.dart';

/// A bottom sheet that lets an anonymous visitor "claim" their session by
/// choosing a username and password, or log in to an existing account.
///
/// Creating an account links the credential to the visitor's anonymous
/// session, so the uid and everything they created stay theirs, and the
/// server keeps their visitor membership in each group they visited
/// (`portalClaimVisitor`, documentation/guest_users/developer.md
/// "Claim-account flow"). Logging in switches to another account, which
/// leaves this visit's work behind, so the sheet says so before the switch
/// ([switchWarning]).
///
/// Shows availability feedback in real-time and handles all error cases
/// gracefully.  After a successful claim or login the sheet dismisses itself
/// and the [onClaimed] callback is invoked.
class ClaimAccountSheet extends StatefulWidget {
  /// Called after the account has been successfully claimed (or the person
  /// logged in to an existing account).
  final VoidCallback? onClaimed;

  /// Whether the signed-in user is an anonymous visitor, whose work a login
  /// would leave behind. Null reads it from Firebase Auth.
  final bool? visitorSession;

  const ClaimAccountSheet({super.key, this.onClaimed, this.visitorSession});

  /// Shown in Log In mode to a visitor: logging in switches accounts and
  /// does not move what they did in this visit.
  static const switchWarning =
      'Logging in switches to that account. What you did in this visit stays '
      'with the visit and is not moved to it. To keep your work, create an '
      'account instead.';

  /// The confirmation shown once [username]'s account is created.
  static String claimedMessage(String username) =>
      'Your account is saved. Log in as $username to get back to your work anytime.';

  /// Shows the sheet as a modal bottom sheet.
  static Future<void> show(BuildContext context, {VoidCallback? onClaimed}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) => ClaimAccountSheet(onClaimed: onClaimed),
    );
  }

  @override
  State<ClaimAccountSheet> createState() => _ClaimAccountSheetState();
}

class _ClaimAccountSheetState extends State<ClaimAccountSheet> {
  final _formKey = GlobalKey<FormState>();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  _AccountMode _mode = _AccountMode.create;

  // Availability state
  _AvailabilityStatus _availability = _AvailabilityStatus.idle;
  String? _availabilityReason;
  Timer? _debounce;

  // UI state
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  bool _isSubmitting = false;
  String? _submitError;
  bool get _isLoginMode => _mode == _AccountMode.login;
  late final bool _visitorSession = widget.visitorSession ?? _currentUserIsAnonymous();

  static bool _currentUserIsAnonymous() {
    try {
      return fire_auth.FirebaseAuth.instance.currentUser?.isAnonymous ?? false;
    } catch (_) {
      // Firebase isn't initialized (a test or a screenshot).
      return false;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Username availability
  // ---------------------------------------------------------------------------

  void _onUsernameChanged(String value) {
    _debounce?.cancel();
    final trimmed = value.trim().toLowerCase();
    if (trimmed.isEmpty) {
      setState(() {
        _availability = _AvailabilityStatus.idle;
        _availabilityReason = null;
      });
      return;
    }

    // Client-side format check before hitting the server.
    if (trimmed.length < 3) {
      setState(() {
        _availability = _AvailabilityStatus.unavailable;
        _availabilityReason = 'At least 3 characters required.';
      });
      return;
    }
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]*[a-z0-9]$').hasMatch(trimmed) &&
        trimmed.length > 1) {
      setState(() {
        _availability = _AvailabilityStatus.unavailable;
        _availabilityReason =
            'Letters, numbers, dots, hyphens, underscores only.';
      });
      return;
    }

    setState(() => _availability = _AvailabilityStatus.checking);

    _debounce = Timer(const Duration(milliseconds: 500), () async {
      final result = await GuestUserService.checkUsernameAvailable(trimmed);
      if (!mounted) return;
      final available = result['available'] as bool? ?? false;
      setState(() {
        _availability = available
            ? _AvailabilityStatus.available
            : _AvailabilityStatus.unavailable;
        _availabilityReason = available ? null : result['reason'] as String?;
      });
    });
  }

  // ---------------------------------------------------------------------------
  // Form submission
  // ---------------------------------------------------------------------------

  Future<void> _submit() async {
    setState(() => _submitError = null);
    if (!_formKey.currentState!.validate()) return;
    if (!_isLoginMode && _availability != _AvailabilityStatus.available) return;

    setState(() => _isSubmitting = true);
    try {
      if (_isLoginMode) {
        await GuestUserService.signInWithExistingAccount(
          _usernameCtrl.text,
          _passwordCtrl.text,
        );
      } else {
        final username = _usernameCtrl.text.trim().toLowerCase();
        await GuestUserService.claimAccount(username, _passwordCtrl.text);
        if (mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              SnackBar(content: Text(ClaimAccountSheet.claimedMessage(username))));
        }
      }
      if (mounted) {
        Navigator.of(context).pop();
        widget.onClaimed?.call();
      }
    } on fire_auth.FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitError = _isLoginMode
            ? _loginAuthErrorMessage(e.code)
            : _createAuthErrorMessage(e.code);
        _isSubmitting = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitError = 'Something went wrong. Please try again.';
        _isSubmitting = false;
      });
    }
  }

  String _createAuthErrorMessage(String code) {
    switch (code) {
      case 'credential-already-in-use':
        return 'That username is already in use.';
      case 'email-already-in-use':
        return 'That username is already in use.';
      case 'weak-password':
        return 'Password must be at least 6 characters.';
      case 'requires-recent-login':
        return 'Please sign in again before claiming your account.';
      default:
        return 'An error occurred. Please try again.';
    }
  }

  String _loginAuthErrorMessage(String code) {
    switch (code) {
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Invalid username, email or password.';
      default:
        return 'Unable to log in right now. Please try again.';
    }
  }

  void _toggleMode() {
    if (_isSubmitting) return;
    setState(() {
      _mode = _isLoginMode ? _AccountMode.create : _AccountMode.login;
      _submitError = null;
      _availability = _AvailabilityStatus.idle;
      _availabilityReason = null;
    });

    if (!_isLoginMode) {
      _onUsernameChanged(_usernameCtrl.text);
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(
          BjSpace.xl, 0, BjSpace.xl, BjSpace.xl + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(),
            const SizedBox(height: BjSpace.xl),
            Form(
              key: _formKey,
              child: AnimatedSize(
                duration: BjMotion.medium,
                curve: BjMotion.curve,
                alignment: Alignment.topCenter,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildUsernameField(),
                    const SizedBox(height: BjSpace.lg),
                    _buildPasswordField(),
                    if (!_isLoginMode) ...[
                      const SizedBox(height: BjSpace.lg),
                      _buildConfirmPasswordField(),
                    ],
                    const SizedBox(height: BjSpace.xl),
                    if (_isLoginMode && _visitorSession) ...[
                      const BjInlineNote(ClaimAccountSheet.switchWarning,
                          icon: Icons.warning_amber_rounded,
                          tone: BjTone.warning),
                      const SizedBox(height: BjSpace.lg),
                    ],
                    if (_submitError != null) ...[
                      BjInlineNote(_submitError!,
                          icon: Icons.error_outline_rounded,
                          tone: BjTone.danger),
                      const SizedBox(height: BjSpace.lg),
                    ],
                    _buildSubmitButton(),
                  ],
                ),
              ),
            ),
            const SizedBox(height: BjSpace.md),
            _buildPrivacyNote(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const BjIconWell(icon: Icons.person_add_rounded, size: 52),
            const Spacer(),
            TextButton(
              onPressed: _toggleMode,
              child: Text(_isLoginMode ? 'Create Account' : 'Log In'),
            ),
          ],
        ),
        const SizedBox(height: BjSpace.lg),
        AnimatedSwitcher(
          duration: BjMotion.medium,
          child: Column(
            key: ValueKey(_isLoginMode),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _isLoginMode
                    ? 'Log In to Existing Account'
                    : 'Create Your Account',
                style: text.headlineSmall,
              ),
              const SizedBox(height: BjSpace.xs + 2),
              Text(
                _isLoginMode
                    ? 'Use your existing username or email and password to continue.'
                    : 'Choose a username and password to save your work and access it anytime.',
                style: text.bodyMedium?.copyWith(
                    color: BjNeutral.inkMuted, height: 1.4),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildUsernameField() {
    final success = context.bj.tone(BjTone.success).foreground;
    final danger = context.bj.tone(BjTone.danger).foreground;
    final small = Theme.of(context).textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        BjFieldLabel(_isLoginMode ? 'Username or email' : 'Username'),
        TextFormField(
          controller: _usernameCtrl,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.next,
          keyboardType: TextInputType.emailAddress,
          onChanged: _isLoginMode ? null : _onUsernameChanged,
          decoration: InputDecoration(
            hintText: _isLoginMode ? 'your-username or you@example.com' : 'your-username',
            prefixIcon: const Icon(Icons.alternate_email_rounded, size: 18),
            suffixIcon: _isLoginMode
                ? null
                : _AvailabilitySuffix(status: _availability),
          ),
          validator: (v) {
            if (v == null || v.trim().isEmpty) {
              return _isLoginMode ? 'Enter your username or email.' : 'Username is required.';
            }
            if (v.trim().length < 3) {
              return 'At least 3 characters required.';
            }
            if (_isLoginMode) return null;
            if (_availability == _AvailabilityStatus.unavailable) {
              return _availabilityReason ?? 'Username not available.';
            }
            if (_availability != _AvailabilityStatus.available) {
              return 'Please wait while we check availability.';
            }
            return null;
          },
        ),
        if (!_isLoginMode &&
            _availabilityReason != null &&
            _availability == _AvailabilityStatus.unavailable) ...[
          const SizedBox(height: BjSpace.xs),
          Text(_availabilityReason!, style: small?.copyWith(color: danger)),
        ],
        if (!_isLoginMode && _availability == _AvailabilityStatus.available) ...[
          const SizedBox(height: BjSpace.xs),
          Row(
            children: [
              Icon(Icons.check_circle_outline, size: 14, color: success),
              const SizedBox(width: BjSpace.xs),
              Text('Username is available!',
                  style: small?.copyWith(color: success)),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildPasswordField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const BjFieldLabel('Password'),
        TextFormField(
          controller: _passwordCtrl,
          obscureText: _obscurePassword,
          textInputAction:
              _isLoginMode ? TextInputAction.done : TextInputAction.next,
          onFieldSubmitted: _isLoginMode ? (_) => _submit() : null,
          decoration: InputDecoration(
            hintText: 'At least 6 characters',
            prefixIcon: const Icon(Icons.lock_outline, size: 18),
            suffixIcon: _ToggleVisibilityButton(
              obscure: _obscurePassword,
              onToggle: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
          validator: (v) {
            if (v == null || v.isEmpty) return 'Password is required.';
            if (v.length < 6) return 'Password must be at least 6 characters.';
            return null;
          },
        ),
      ],
    );
  }

  Widget _buildConfirmPasswordField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const BjFieldLabel('Confirm Password'),
        TextFormField(
          controller: _confirmCtrl,
          obscureText: _obscureConfirm,
          textInputAction: TextInputAction.done,
          onFieldSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            hintText: 'Re-enter your password',
            prefixIcon: const Icon(Icons.lock_outline, size: 18),
            suffixIcon: _ToggleVisibilityButton(
              obscure: _obscureConfirm,
              onToggle: () =>
                  setState(() => _obscureConfirm = !_obscureConfirm),
            ),
          ),
          validator: (v) {
            if (v == null || v.isEmpty) return 'Please confirm your password.';
            if (v != _passwordCtrl.text) return 'Passwords do not match.';
            return null;
          },
        ),
      ],
    );
  }

  Widget _buildSubmitButton() {
    final isEnabled = _isLoginMode
        ? !_isSubmitting
        : _availability == _AvailabilityStatus.available && !_isSubmitting;
    return SizedBox(
      height: 52,
      child: BjBusyButton(
        label: _isLoginMode ? 'Log In' : 'Create Account',
        icon: _isLoginMode ? Icons.login_rounded : Icons.person_add_rounded,
        busy: _isSubmitting,
        onPressed: isEnabled ? _submit : null,
      ),
    );
  }

  Widget _buildPrivacyNote() {
    return Text(
      _isLoginMode
          ? 'Use the same username/password you use on Bluejay.'
          : 'Your data and submissions are saved to your account. No email confirmation required.',
      textAlign: TextAlign.center,
      style: Theme.of(context)
          .textTheme
          .bodySmall
          ?.copyWith(color: BjNeutral.inkSubtle, height: 1.4),
    );
  }
}

enum _AccountMode { create, login }

// ─── Availability status enum ─────────────────────────────────────────────────

enum _AvailabilityStatus { idle, checking, available, unavailable }

// ─── Sub-widgets ──────────────────────────────────────────────────────────────

class _AvailabilitySuffix extends StatelessWidget {
  final _AvailabilityStatus status;
  const _AvailabilitySuffix({required this.status});

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case _AvailabilityStatus.checking:
        return const Padding(
          padding: EdgeInsets.all(BjSpace.md),
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: BjNeutral.inkSubtle,
            ),
          ),
        );
      case _AvailabilityStatus.available:
        return Icon(Icons.check_circle_rounded,
            color: context.bj.tone(BjTone.success).foreground, size: 20);
      case _AvailabilityStatus.unavailable:
        return Icon(Icons.cancel_rounded,
            color: context.bj.tone(BjTone.danger).foreground, size: 20);
      case _AvailabilityStatus.idle:
        return const SizedBox.shrink();
    }
  }
}

class _ToggleVisibilityButton extends StatelessWidget {
  final bool obscure;
  final VoidCallback onToggle;
  const _ToggleVisibilityButton(
      {required this.obscure, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(
        obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
        size: 20,
      ),
      tooltip: obscure ? 'Show password' : 'Hide password',
      onPressed: onToggle,
    );
  }
}
