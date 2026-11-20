import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui/client_picker.dart';

void main() {
  Widget app(Widget child) => MaterialApp(theme: BluejayTheme.build(), home: Scaffold(body: child));

  testWidgets('lists clients by name, leaves out the excluded, and picks one', (t) async {
    final picked = <String>[];
    await t.pumpWidget(app(ClientPickerList(
      load: () async => const [
        PortalAppClient(uid: 'k1', name: 'Kim', email: 'kim@c.com'),
        PortalAppClient(uid: 'k2', email: 'lee@c.com'),
        PortalAppClient(uid: 'k3', name: 'Shared Already'),
      ],
      excludeUids: const {'k3'},
      onPick: (c) => picked.add(c.uid),
    )));
    await t.pumpAndSettle();
    expect(find.text('Kim'), findsOneWidget);
    expect(find.text('kim@c.com'), findsOneWidget);
    expect(find.text('lee@c.com'), findsOneWidget);
    expect(find.text('Shared Already'), findsNothing);
    await t.tap(find.text('Kim'));
    expect(picked, ['k1']);
  });

  testWidgets('says so when there is nobody to pick', (t) async {
    await t.pumpWidget(app(ClientPickerList(load: () async => const [], onPick: (_) {})));
    await t.pumpAndSettle();
    expect(find.text('No clients to choose'), findsOneWidget);
  });
}
