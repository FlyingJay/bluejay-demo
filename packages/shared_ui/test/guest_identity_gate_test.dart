import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/corporate_access_service.dart';
import 'package:shared_services/user_app_entitlements.dart';
import 'package:shared_ui/guest_identity_gate.dart';

Future<void> fillIn(WidgetTester tester, {String email = 'pat@north.example'}) async {
  await tester.enterText(find.widgetWithText(TextFormField, 'Full name'), 'Pat');
  await tester.enterText(find.widgetWithText(TextFormField, 'Work email'), email);
}

Future<void> tapContinue(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Continue'));
  await tester.tap(find.text('Continue'));
}

Widget gate({required Future<GuestIdentityStatus> Function(String, String, String?) verify, VoidCallback? onConfirmed}) => MaterialApp(
      home: GuestIdentityGate(
        groupId: 'grp1',
        targetAppId: 'app',
        title: 'Uploader',
        subtitle: 'Send files',
        verify: verify,
        onIdentityConfirmed: onConfirmed ?? () {},
      ),
    );

void main() {
  testWidgets('an accepted identity leaves the gate ready for another try', (tester) async {
    final pending = Completer<GuestIdentityStatus>();
    final submitted = <String>[];
    var confirmed = 0;
    await tester.pumpWidget(gate(
      verify: (name, email, code) {
        submitted.add(email);
        return pending.future;
      },
      onConfirmed: () => confirmed++,
    ));
    await fillIn(tester, email: ' Pat@North.example ');
    await tester.tap(find.text('Continue'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // A second tap while checking does nothing.
    await tester.tap(find.byType(FilledButton), warnIfMissed: false);
    pending.complete(GuestIdentityStatus.allowed);
    await tester.pump();

    expect(submitted, ['pat@north.example']);
    expect(confirmed, 1);
    // If the app still can't proceed, the guest can press Continue again.
    expect(find.text('Continue'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
  });

  testWidgets('a refused organisation sees the denial', (tester) async {
    await tester.pumpWidget(gate(verify: (_, __, ___) async => GuestIdentityStatus.denied));
    await fillIn(tester);
    await tester.tap(find.text('Continue'));
    await tester.pump();
    expect(find.text('Access not approved'), findsOneWidget);
  });

  testWidgets('a refused guest can try a different email from the denial', (tester) async {
    final submitted = <(String, String?)>[];
    await tester.pumpWidget(gate(verify: (_, email, code) async {
      submitted.add((email, code));
      return email == 'pat@north.example' ? GuestIdentityStatus.denied : GuestIdentityStatus.allowed;
    }));
    await fillIn(tester);
    await tapContinue(tester);
    await tester.pump();
    expect(find.text('Access not approved'), findsOneWidget);

    await tester.tap(find.text('Use a different email'));
    await tester.pump();
    expect(find.text('Access not approved'), findsNothing);
    // Back on the form, with what they typed kept.
    expect(find.widgetWithText(TextFormField, 'pat@north.example'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Work email'), 'pat@south.example');
    await tapContinue(tester);
    await tester.pump();
    expect(submitted, [('pat@north.example', null), ('pat@south.example', null)]);
  });

  testWidgets('a public-mode answer lets the guest straight through', (tester) async {
    var confirmed = 0;
    await tester.pumpWidget(gate(
      // The server answers allowed at once in public mode (no code).
      verify: (_, __, ___) async => GuestIdentityStatus.fromResponse({'allowed': true, 'accessMode': 'public'}),
      onConfirmed: () => confirmed++,
    ));
    await fillIn(tester);
    await tapContinue(tester);
    await tester.pump();
    expect(confirmed, 1);
    expect(find.textContaining('We emailed a code'), findsNothing);
  });

  group('GuestAdmissionGate', () {
    const admitted = UserAppEntitlements(entitlements: {'g1:app:guest'});
    Widget host(Stream<UserAppEntitlements> entitlements) => MaterialApp(
          home: GuestAdmissionGate(
            uid: 'u1',
            groupDocId: 'g1',
            appId: 'app',
            entitlements: entitlements,
            loading: const Text('loading'),
            gate: const Text('gate'),
            child: const Text('app'),
          ),
        );

    testWidgets('an admitted guest (public, or a confirmed corporate email) goes straight in', (tester) async {
      await tester.pumpWidget(host(Stream.value(admitted)));
      await tester.pump();
      expect(find.text('app'), findsOneWidget);
      expect(find.text('gate'), findsNothing);
    });

    testWidgets('a guest the server has not admitted sees the gate until it does', (tester) async {
      final index = StreamController<UserAppEntitlements>();
      await tester.pumpWidget(host(index.stream));
      expect(find.text('loading'), findsOneWidget);
      index.add(const UserAppEntitlements(entitlements: {'g1:other:guest'}));
      await tester.pump();
      await tester.pump();
      expect(find.text('gate'), findsOneWidget);
      index.add(admitted);
      await tester.pump();
      await tester.pump();
      expect(find.text('app'), findsOneWidget);
      await index.close();
    });

    test('guestAdmittedTo reads the :guest entitlement and the kill switches', () {
      expect(guestAdmittedTo(admitted, 'g1', 'app'), isTrue);
      expect(guestAdmittedTo(admitted, 'g2', 'app'), isFalse);
      expect(guestAdmittedTo(const UserAppEntitlements(entitlements: {'g1:app'}), 'g1', 'app'), isFalse);
      expect(
          guestAdmittedTo(const UserAppEntitlements(entitlements: {'g1:app:guest'}, status: 'SUSPENDED'), 'g1', 'app'),
          isFalse);
      expect(
          guestAdmittedTo(const UserAppEntitlements(entitlements: {'g1:app:guest'}, deniedScopes: {'g1'}), 'g1', 'app'),
          isFalse);
      expect(guestAdmittedTo(admitted, '', 'app'), isFalse);
    });
  });

  testWidgets('a failed check can be retried', (tester) async {
    await tester.pumpWidget(gate(verify: (_, __, ___) async => throw Exception('offline')));
    await fillIn(tester);
    await tester.tap(find.text('Continue'));
    await tester.pump();
    expect(find.textContaining('Something went wrong'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
  });

  testWidgets('invalid details are not sent', (tester) async {
    var calls = 0;
    await tester.pumpWidget(gate(verify: (_, __, ___) async {
      calls++;
      return GuestIdentityStatus.allowed;
    }));
    await fillIn(tester, email: 'not-an-email');
    await tester.tap(find.text('Continue'));
    await tester.pump();
    expect(find.text('Please enter a valid email address.'), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets('a sent code is asked for and submitted with the address', (tester) async {
    final calls = <String?>[];
    var confirmed = 0;
    await tester.pumpWidget(gate(
      verify: (_, __, code) async {
        calls.add(code);
        if (code == null) return GuestIdentityStatus.codeSent;
        return code == 'GOOD-CODE' ? GuestIdentityStatus.allowed : GuestIdentityStatus.codeInvalid;
      },
      onConfirmed: () => confirmed++,
    ));
    await fillIn(tester);
    await tapContinue(tester);
    await tester.pump();
    expect(find.textContaining('We emailed a code to pat@north.example'), findsOneWidget);
    expect(confirmed, 0);

    await tester.enterText(find.widgetWithText(TextFormField, 'Code'), 'BAD-CODE');
    await tapContinue(tester);
    await tester.pump();
    expect(find.textContaining("That code didn't work"), findsOneWidget);
    expect(confirmed, 0);

    await tester.enterText(find.widgetWithText(TextFormField, 'Code'), 'GOOD-CODE');
    await tapContinue(tester);
    await tester.pump();
    expect(calls, [null, 'BAD-CODE', 'GOOD-CODE']);
    expect(confirmed, 1);
  });

  testWidgets('changing the address asks for a new code', (tester) async {
    final calls = <String?>[];
    await tester.pumpWidget(gate(verify: (_, __, code) async {
      calls.add(code);
      return GuestIdentityStatus.codeSent;
    }));
    await fillIn(tester);
    await tapContinue(tester);
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextFormField, 'Code'), 'SOME-CODE');
    await tester.enterText(find.widgetWithText(TextFormField, 'Work email'), 'sam@north.example');
    await tapContinue(tester);
    await tester.pump();
    expect(calls, [null, null]);
  });

  testWidgets('a skipped send says the address cannot be confirmed here', (tester) async {
    await tester.pumpWidget(gate(verify: (_, __, ___) async => GuestIdentityStatus.sendSkipped));
    await fillIn(tester);
    await tapContinue(tester);
    await tester.pump();
    expect(find.textContaining("doesn't send email"), findsOneWidget);
    expect(find.text('Access not approved'), findsNothing);
  });
}
