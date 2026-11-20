import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/group_app_links.dart';

void main() {
  final origin = Uri.parse('https://preview--bluejay.web.app/some/path?x=1');

  test('groupAppUri builds /{group}/{app} on the given origin, dropping its path and query', () {
    expect(groupAppUri('kb', 'notes', origin: origin).toString(), 'https://preview--bluejay.web.app/kb/notes');
    expect(
      groupAppUri('kb', 'notes', origin: Uri.parse('http://localhost:5000/')).toString(),
      'http://localhost:5000/kb/notes',
    );
  });

  test('groupAppUri carries non-blank args as query parameters', () {
    expect(
      groupAppUri('kb', 'wiki', args: {'slug': ' notes ', 'empty': ' '}, origin: origin).toString(),
      'https://preview--bluejay.web.app/kb/wiki?slug=notes',
    );
  });

  test('groupAppUri is null without a group or app', () {
    expect(groupAppUri('', 'notes'), isNull);
    expect(groupAppUri('kb', '  '), isNull);
  });

  test('groupAppUri falls back to the production origin off the web', () {
    expect(groupAppUri('kb', 'notes').toString(), '$defaultWebOrigin/kb/notes');
  });

  test('improveAppsTicketUri opens Improve Apps on one ticket', () {
    final uri = improveAppsTicketUri('kb', itemType: 'bug', itemId: 'b1', origin: origin)!;
    expect(uri.path, '/kb/improve-apps');
    expect(uri.queryParameters, {improveAppsItemTypeArg: 'bug', improveAppsItemIdArg: 'b1'});
  });

  test('appMakerRequestUri opens App Maker on one request', () {
    final uri = appMakerRequestUri('kb', requestId: 'r1', origin: origin)!;
    expect(uri.path, '/kb/app-maker');
    expect(uri.queryParameters, {appMakerRequestIdArg: 'r1'});
    expect(appMakerRequestUri('', requestId: 'r1'), isNull);
  });

  test('NotificationLink reads the group and id from a notification link', () {
    final grouped = NotificationLink.fromUri(Uri.parse('https://bluejay.gg/kb/notifications?id=n1'))!;
    expect(grouped.groupId, 'kb');
    expect(grouped.notificationId, 'n1');

    final groupless = NotificationLink.fromUri(Uri.parse('https://bluejay.gg/notifications?id=n2'))!;
    expect(groupless.groupId, isNull);
    expect(groupless.notificationId, 'n2');

    final bare = NotificationLink.fromUri(Uri.parse('https://bluejay.gg/kb/notifications'))!;
    expect(bare.notificationId, isNull);
  });

  test('NotificationLink ignores other paths', () {
    for (final url in [
      'https://bluejay.gg/',
      'https://bluejay.gg/kb',
      'https://bluejay.gg/kb/notes?id=n1',
      'https://bluejay.gg/kb/notifications/extra',
      'https://bluejay.gg/claim?token=t',
    ]) {
      expect(NotificationLink.fromUri(Uri.parse(url)), isNull, reason: url);
    }
  });
}
