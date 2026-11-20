import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help_desk/help_desk.dart';
import 'package:shared_services/user_app_entitlements.dart';
import 'package:wiki/app_help.dart';

import 'fakes.dart';

Future<void> pumpScreen(WidgetTester tester, Widget child, {Size size = const Size(1100, 900)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(theme: BluejayTheme.build(), home: child));
  await tester.pumpAndSettle();
}

void main() {
  group('models', () {
    test('an overview lists the views the person has, in tab order', () {
      expect(HelpDeskOverview.fromData(FakeApi.agentOverview).views,
          [TicketView.mine, TicketView.inbox, TicketView.upstream]);
      expect(HelpDeskOverview.fromData({'canFile': true}).views, [TicketView.mine]);
      expect(HelpDeskOverview.fromData({'isStaff': true}).views, [TicketView.platform]);
    });

    test('statuses read differently for the desk and the requester', () {
      expect(statusDisplay(TicketStatus.open, forDesk: true).label, 'Needs reply');
      expect(statusDisplay(TicketStatus.open, forDesk: false).label, 'Waiting for reply');
      expect(statusDisplay(TicketStatus.pending, forDesk: false).label, 'Replied');
      expect(ticketStatusFrom('nonsense'), TicketStatus.open);
    });

    test('a ticket parses its messages, context and desk tools', () {
      final t = TicketDetail.fromData(FakeApi().ticketData);
      expect(t.asDesk, isTrue);
      expect(t.messages.map((m) => m.internal), [false, true]);
      expect(t.context, {'appName': 'Shop', 'orderRef': 'A-7'});
      expect(t.desk!.agents.single.name, 'Olive Owner');
      expect(t.desk!.canEscalate, isTrue);
      final public = TicketDetail.fromData(FakeApi().ticketData, publicView: true);
      expect(public.asDesk, isFalse);
      expect(public.asRequester, isTrue);
    });

    test('relative times', () {
      final now = DateTime(2026, 11, 15, 12);
      expect(relativeTime(now.subtract(const Duration(minutes: 5)), now), '5m');
      expect(relativeTime(now.subtract(const Duration(hours: 3)), now), '3h');
      expect(relativeTime(now.subtract(const Duration(days: 2)), now), '2d');
      expect(relativeTime(DateTime(2026, 10, 1), now), 'Oct 1');
      expect(relativeTime(null, now), '');
    });

    test('Help Desk is offered from other apps to anyone with it in the group', () {
      const guest = UserAppEntitlements(entitlements: {'shop:help-desk:guest'});
      expect(mayContactHelpDesk(guest, 'shop'), isTrue);
      expect(mayContactHelpDesk(guest, 'other'), isFalse);
      expect(mayContactHelpDesk(const UserAppEntitlements(entitlements: {'shop:help-desk-x'}), 'shop'), isFalse);
      expect(mayContactHelpDesk(const UserAppEntitlements(entitlements: {'shop:help-desk'}, deniedScopes: {'shop'}), 'shop'), isFalse);
      expect(mayContactHelpDesk(UserAppEntitlements.none, 'shop'), isFalse);
    });
  });

  group('public links', () {
    test('parse the form, the order prefill and ticket links', () {
      final form = HelpDeskLink.fromUri(Uri.parse('https://bluejay.gg/help/corner-shop?order=AB12'))!;
      expect(form.groupId, 'corner-shop');
      expect(form.orderRef, 'AB12');
      expect(form.token, isNull);
      final token = 'a' * 43;
      expect(HelpDeskLink.fromUri(Uri.parse('/help/corner-shop/t/$token'))!.token, token);
      expect(HelpDeskLink.fromUri(Uri.parse('/help/corner-shop/t/short')), isNull);
      expect(HelpDeskLink.fromUri(Uri.parse('/help/Bad_Group')), isNull);
      expect(HelpDeskLink.fromUri(Uri.parse('/store/corner-shop')), isNull);
      expect(HelpDeskLink.formPath('shop', orderRef: 'X1'), '/help/shop?order=X1');
    });
  });

  group('screens', () {
    testWidgets('an agent sees their tabs, with what needs a reply counted', (tester) async {
      final api = FakeApi();
      await pumpScreen(tester, HelpDeskScreen(api: api, groupId: 'shop', clock: () => fakeNow, suggestGuides: noGuides));
      expect(find.text('My requests'), findsOneWidget);
      expect(find.text('Contact Bluejay support'), findsOneWidget);
      await tester.tap(find.text('Inbox'));
      await tester.pumpAndSettle();
      expect(find.text('Where is my order?'), findsOneWidget);
      expect(find.text('Needs reply'), findsOneWidget);
      expect(find.text('Overdue'), findsOneWidget);
      expect(api.callsTo('helpDeskList').map((c) => c['view']).toSet(), {'mine', 'inbox', 'upstream'});
    });

    testWidgets('someone who can only file sees no tabs and a New request button', (tester) async {
      final api = FakeApi(overview: {'groupId': 'shop', 'groupName': 'Corner Shop', 'canFile': true, 'deskLabel': 'Corner Shop', 'isGuest': true, 'categories': ['Question', 'Order']});
      await pumpScreen(tester, HelpDeskScreen(api: api, groupId: 'shop', clock: () => fakeNow, suggestGuides: noGuides));
      expect(find.byType(BjSegmentedTabs), findsNothing);
      expect(find.text('No open requests'), findsOneWidget);
      await tester.tap(find.text('New request'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('help-desk-subject')), 'Damaged box');
      await tester.enterText(find.byKey(const Key('help-desk-body')), 'The box arrived crushed.');
      await tester.pumpAndSettle();
      expect(find.text('Urgent'), findsNothing, reason: 'requesters choose normal or high');
      await tester.tap(find.text('Order'));
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      final created = api.callsTo('helpDeskCreateTicket').single;
      expect(created['target'], 'desk');
      expect(created['subject'], 'Damaged box');
      expect(created['category'], 'Order');
      expect(find.textContaining('Sent to Corner Shop'), findsOneWidget);
    });

    testWidgets('the form suggests matching guides as the person types', (tester) async {
      final api = FakeApi(overview: {'groupId': 'shop', 'canFile': true, 'deskLabel': 'Corner Shop'});
      final searched = <String>[];
      Future<List<SuggestedGuide>> suggest(String text, {bool forGuest = false}) async {
        searched.add(text);
        return const [SuggestedGuide(title: 'Shop', doc: AppHelpDoc(slug: 'shop', markdown: '# Shop'))];
      }

      await pumpScreen(tester, HelpDeskScreen(api: api, groupId: 'shop', clock: () => fakeNow, suggestGuides: suggest));
      await tester.tap(find.text('New request'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('help-desk-body')), 'How do I refund an order?');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(searched, isNotEmpty);
      expect(find.text('How Shop works'), findsOneWidget);
    });

    testWidgets('loading failure offers a retry', (tester) async {
      final api = FakeApi()..overviewError = Exception('offline');
      await pumpScreen(tester, HelpDeskScreen(api: api, groupId: 'shop', clock: () => fakeNow));
      expect(find.text('Try again'), findsOneWidget);
      api.overviewError = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Inbox'), findsOneWidget);
    });

    testWidgets('the desk sees internal notes and can reply, note, and use saved replies', (tester) async {
      final api = FakeApi();
      await pumpScreen(tester, HelpDeskTicketScreen(ticketId: 't1', api: api, clock: () => fakeNow));
      expect(find.text('It has been a week.'), findsOneWidget);
      expect(find.text('Olive · internal note'), findsOneWidget);
      expect(find.text('Order'), findsOneWidget);
      expect(find.text('A-7'), findsOneWidget);

      await tester.tap(find.text('Saved replies'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Shipping'));
      await tester.pumpAndSettle();
      expect(find.text('Orders ship in 2 days.'), findsOneWidget);
      await tester.tap(find.text('Send and resolve'));
      await tester.pumpAndSettle();
      expect(api.callsTo('helpDeskReply').single, {
        'ticketId': 't1', 'body': 'Orders ship in 2 days.', 'internal': false, 'resolve': true,
      });

      await tester.tap(find.text('Internal note'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('help-desk-reply')), 'Called the courier');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add note'));
      await tester.pumpAndSettle();
      expect(api.callsTo('helpDeskReply').last['internal'], isTrue);
    });

    testWidgets('the desk escalates with a summary, sharing the thread only when asked', (tester) async {
      final api = FakeApi();
      await pumpScreen(tester, HelpDeskTicketScreen(ticketId: 't1', api: api, clock: () => fakeNow));
      await tester.tap(find.byType(BjOverflowMenu));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Escalate to Bluejay support'));
      await tester.pumpAndSettle();
      expect(find.textContaining('keeps talking only to you'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('help-desk-escalate-summary')), 'Courier lost it');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Escalate'));
      await tester.pumpAndSettle();
      expect(api.callsTo('helpDeskEscalate').single, {'ticketId': 't1', 'summary': 'Courier lost it', 'shareThread': false});
    });

    testWidgets('the desk confirms before closing a request', (tester) async {
      final api = FakeApi();
      await pumpScreen(tester, HelpDeskTicketScreen(ticketId: 't1', api: api, clock: () => fakeNow));
      Future<void> openClose() async {
        await tester.tap(find.byType(BjOverflowMenu));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
      }

      await openClose();
      expect(find.text('Close this request?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(api.callsTo('helpDeskSetStatus'), isEmpty);

      await openClose();
      await tester.tap(find.widgetWithText(FilledButton, 'Close'));
      await tester.pumpAndSettle();
      expect(api.callsTo('helpDeskSetStatus').single, {'ticketId': 't1', 'status': 'closed'});
    });

    testWidgets('a requester never gets desk tools and can mark it solved', (tester) async {
      final api = FakeApi()
        ..ticketData = {
          'ticket': ticketRow('t1', status: 'pending'),
          'messages': [
            {'id': 'm1', 'side': 'requester', 'authorName': 'Gus', 'body': 'Hi'},
            {'id': 'm2', 'side': 'desk', 'authorName': 'Olive', 'body': 'It ships tomorrow.'},
          ],
          'sides': {'requester': true, 'desk': false},
        };
      await pumpScreen(tester, HelpDeskTicketScreen(ticketId: 't1', api: api, clock: () => fakeNow));
      expect(find.text('Replied'), findsOneWidget);
      expect(find.byType(BjOverflowMenu), findsNothing);
      expect(find.text('Internal note'), findsNothing);
      await tester.tap(find.text('Solved'));
      await tester.pumpAndSettle();
      expect(api.callsTo('helpDeskSetStatus').single, {'ticketId': 't1', 'status': 'resolved'});
    });

    testWidgets('the public form sends and confirms; the order number is filled in', (tester) async {
      final api = FakeApi();
      await pumpScreen(tester, PublicHelpFormScreen(groupId: 'shop', orderRef: 'AB12', api: api));
      expect(find.text('We reply within a day.'), findsOneWidget);
      expect(find.text('AB12'), findsOneWidget);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'Pat');
      await tester.enterText(fields.at(1), 'pat@example.com');
      await tester.enterText(fields.at(2), 'Damaged');
      await tester.enterText(fields.at(3), 'Crushed box');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      final sent = api.callsTo('helpDeskPublicSubmit').single;
      expect(sent['orderRef'], 'AB12');
      expect(sent['category'], 'Order');
      expect(find.text('We got your request'), findsOneWidget);
    });

    testWidgets('the public form says what is wrong with the email once the person leaves the field', (tester) async {
      final api = FakeApi();
      await pumpScreen(tester, PublicHelpFormScreen(groupId: 'shop', api: api));
      const message = 'Enter a valid email address.';
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'Pat');
      await tester.enterText(fields.at(1), 'pat@example');
      await tester.pumpAndSettle();
      expect(find.text(message), findsNothing, reason: 'no error while the address is still being typed');
      await tester.enterText(fields.at(2), 'Damaged');
      await tester.enterText(fields.at(3), 'Crushed box');
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget);
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(api.callsTo('helpDeskPublicSubmit'), isEmpty);

      await tester.enterText(fields.at(1), 'pat@example.com');
      await tester.pumpAndSettle();
      expect(find.text(message), findsNothing);
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(api.callsTo('helpDeskPublicSubmit').single['email'], 'pat@example.com');
    });

    test('the email check matches the one the server applies', () {
      expect(isHelpDeskEmail(' pat@example.com '), isTrue);
      expect(isHelpDeskEmail('pat@example'), isFalse);
      expect(isHelpDeskEmail('pat example@x.com'), isFalse);
      expect(isHelpDeskEmail(''), isFalse);
      expect(isHelpDeskEmail('${'a' * 250}@x.com'), isFalse);
    });

    testWidgets('a dead public link explains itself', (tester) async {
      final api = _FailingApi();
      await pumpScreen(tester, PublicHelpTicketScreen(token: 'x' * 43, api: api));
      expect(find.text('This link has expired or is not valid'), findsOneWidget);
    });
  });
}

class _FailingApi extends FakeApi {
  @override
  Future<Object?> call(String name, Map<String, dynamic> data) async => throw Exception('not-found');
}
