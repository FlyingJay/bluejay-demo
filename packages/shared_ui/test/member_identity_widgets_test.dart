import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/group_member_directory.dart';
import 'package:shared_ui/member_identity_widgets.dart';

void main() {
  late GroupMemberDirectory dir;

  setUp(() {
    dir = GroupMemberDirectory();
    dir.primeCache('g1', [
      GroupMember.fromMap({
        'groupId': 'g1',
        'uid': 'priya',
        'email': 'demo-priya@bluejay.gg',
        'displayName': 'Priya Nair',
      }),
    ]);
  });

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('MemberName shows the directory display name', (tester) async {
    await tester.pumpWidget(wrap(MemberName(uid: 'priya', groupId: 'g1', directory: dir)));
    expect(find.text('Priya Nair'), findsOneWidget);
  });

  testWidgets('MemberName resolves an email-only reference', (tester) async {
    await tester.pumpWidget(wrap(MemberName(
      email: 'demo-priya@bluejay.gg',
      groupId: 'g1',
      directory: dir,
      format: (n) => 'by $n',
    )));
    expect(find.text('by Priya Nair'), findsOneWidget);
  });

  testWidgets('MemberName falls back to the stored name', (tester) async {
    await tester.pumpWidget(wrap(MemberName(
      uid: 'gone',
      name: 'Sam Okafor',
      groupId: 'g1',
      directory: dir,
    )));
    await tester.pump();
    expect(find.text('Sam Okafor'), findsOneWidget);
  });

  testWidgets('MemberAvatar shows initials when there is no picture', (tester) async {
    await tester.pumpWidget(wrap(MemberAvatar(uid: 'priya', groupId: 'g1', directory: dir)));
    expect(find.text('PN'), findsOneWidget);
  });
}
