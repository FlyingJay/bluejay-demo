import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui/admin_block.dart';

void main() {
  test('standard wording per audience', () {
    expect(
      const AdminBlockView(appName: 'Billing').message,
      "Billing is only for this group's admins. "
      "Ask one of this group's admins if you need access.",
    );
    expect(
      const AdminBlockView(
        appName: 'Role Manager',
        audience: AdminAudience.platformAdmins,
      ).message,
      'Role Manager is only for Bluejay platform admins. '
      'Ask a platform admin if you need access.',
    );
    expect(
      const AdminBlockView(
        appName: 'Rented Dwelling',
        feature: 'Managing these settings',
      ).message,
      startsWith("Managing these settings is only for this group's admins."),
    );
    for (final audience in AdminAudience.values) {
      expect(audience.heading, startsWith('For '));
    }
  });

  testWidgets('the page titles itself with the app and adds the detail', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: BluejayTheme.build(),
        home: const AdminBlockPage(
          appName: 'Signup Setup',
          audience: AdminAudience.platformAdmins,
          detail: 'It sets up signup packages.',
        ),
      ),
    );
    expect(find.text('Signup Setup'), findsOneWidget);
    expect(find.text('For platform admins'), findsOneWidget);
    expect(find.textContaining('It sets up signup packages.'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
  });
}
