import 'package:bluejay_design/bluejay_design.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';

import 'claim_account_sheet.dart';

/// A floating "Create Account/Login" button shown only to anonymous (guest)
/// sessions. Claiming links a credential to an anonymous session, so this
/// reads `isAnonymous` (how the user signed in) rather than GuestStatus:
/// a client already has an account and has nothing to claim.
///
/// Listens to [FirebaseAuth.instance.userChanges] so it disappears
/// automatically the moment the user claims their account (i.e. when
/// `currentUser.isAnonymous` transitions from `true` to `false`).
///
/// Intended to be used as a [Scaffold.floatingActionButton].  Pair it with
/// [FloatingActionButtonLocation.centerFloat] for the most prominent placement.
class GuestClaimButton extends StatelessWidget {
  /// The Firebase Auth user provided by the parent widget.
  /// Used as the initial value for the auth stream so the UI renders correctly
  /// on the first frame without waiting for a stream event.
  final fire_auth.User currentUser;

  /// Optional callback invoked after the account is successfully claimed.
  final VoidCallback? onClaimed;

  const GuestClaimButton({
    super.key,
    required this.currentUser,
    this.onClaimed,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<fire_auth.User?>(
      // userChanges() fires whenever the user's profile changes, including
      // when linkWithCredential() converts the anonymous session to a
      // permanent account.
      stream: fire_auth.FirebaseAuth.instance.userChanges(),
      initialData: currentUser,
      builder: (context, snapshot) {
        final user = snapshot.data;
        if (user == null || !user.isAnonymous) {
          return const SizedBox.shrink();
        }
        return _ClaimFab(onTap: () => _showSheet(context));
      },
    );
  }

  void _showSheet(BuildContext context) {
    ClaimAccountSheet.show(context, onClaimed: onClaimed);
  }
}

// ─── Animated FAB ─────────────────────────────────────────────────────────────

class _ClaimFab extends StatefulWidget {
  final VoidCallback onTap;
  const _ClaimFab({required this.onTap});

  @override
  State<_ClaimFab> createState() => _ClaimFabState();
}

class _ClaimFabState extends State<_ClaimFab>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _scaleAnim = Tween<double>(begin: 1.0, end: 1.04).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scaleAnim,
      child: FloatingActionButton.extended(
        onPressed: widget.onTap,
        backgroundColor: context.bj.accent,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add_rounded, size: 20),
        label: Text(
          'Create Account/Login',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
        ),
        tooltip: 'Create an account or log in to continue',
      ),
    );
  }
}
