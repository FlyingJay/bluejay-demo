import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/client_view_switch.dart';
import 'package:shared_services/guest_status.dart';

void main() {
  Future<void> pump(WidgetTester t, GuestStatus? status) => t.pumpWidget(MaterialApp(
        home: ClientViewSwitch(
          status: ValueNotifier<GuestStatus?>(status),
          member: (_) => const Text('member view'),
          client: (_) => const Text('client view'),
        ),
      ));

  testWidgets('active clients get the client view; everyone else the member view', (t) async {
    await pump(t, const GuestStatus('g', GuestKind.client));
    expect(find.text('client view'), findsOneWidget);
    for (final status in [
      null,
      const GuestStatus('g', GuestKind.member),
      const GuestStatus('g', GuestKind.visitor),
      const GuestStatus('g', GuestKind.none),
    ]) {
      await pump(t, status);
      expect(find.text('member view'), findsOneWidget, reason: '$status');
    }
  });

  testWidgets('loading spins, and a pending client waits for approval', (t) async {
    await pump(t, const GuestStatus.unknown('g'));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await pump(t, const GuestStatus('g', GuestKind.pendingClient));
    expect(find.textContaining('waiting for approval'), findsOneWidget);
    expect(find.text('member view'), findsNothing);
    expect(find.text('client view'), findsNothing);
  });
}
