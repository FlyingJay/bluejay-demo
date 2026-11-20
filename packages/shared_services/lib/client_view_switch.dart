import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'guest_status.dart';

/// An app's entry point that shows its client view to a portal client of
/// the active group and its member UI to everyone else
/// (plans/business-suite/CLIENT_PORTAL_PLAN.md, Phase C).
///
/// Reads [GuestStatusService.current]: an active client gets [client]; a
/// client still waiting for approval gets a waiting message (they hold no
/// app yet); while the status loads, a spinner; members, visitors and a
/// signed-out or group-less session get [member], as before.
class ClientViewSwitch extends StatelessWidget {
  const ClientViewSwitch({
    super.key,
    required this.member,
    required this.client,
    this.status,
  });

  final WidgetBuilder member;
  final WidgetBuilder client;

  /// Overrides [GuestStatusService.current] (tests).
  final ValueListenable<GuestStatus?>? status;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<GuestStatus?>(
      valueListenable: status ?? GuestStatusService.instance.current,
      builder: (context, value, _) {
        if (value == null) return member(context);
        if (!value.isLoaded) return const Center(child: CircularProgressIndicator());
        if (value.isActiveClient) return client(context);
        if (value.isPendingClient) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Your access is waiting for approval. You\'ll see this app once the business approves you.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return member(context);
      },
    );
  }
}
