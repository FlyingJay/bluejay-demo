import 'package:cloud_functions/cloud_functions.dart';
import 'package:shared_services/cloud_functions.dart';

import 'help_desk_models.dart';

/// Everything Help Desk reads and changes. Tickets cross groups (a group's
/// desk, the desk above it, the Bluejay desk), so the app reads nothing from
/// Firestore directly: every call goes through the helpDesk* callables
/// (functions/help_desk.js), which decide what the caller may see.
/// Screens take an instance so tests can pass a fake.
class HelpDeskApi {
  const HelpDeskApi();

  Future<Object?> call(String name, Map<String, dynamic> data) async {
    final result = await BluejayFunctions.instance.httpsCallable(name).call(data);
    return result.data;
  }

  Future<HelpDeskOverview> overview(String groupId) async =>
      HelpDeskOverview.fromData(await call('helpDeskOverview', {'groupId': groupId}));

  Future<List<TicketSummary>> list(TicketView view, {String? groupId, bool active = true}) async {
    final data = await call('helpDeskList', {
      'view': view.name,
      if (groupId != null) 'groupId': groupId,
      'active': active,
    });
    final rows = data is Map ? data['tickets'] : null;
    return [for (final row in (rows is List ? rows : const [])) TicketSummary.fromData(row)];
  }

  /// Record search: the tickets in [groupId] matching [query] that the
  /// caller sees in [list] (their own; the inbox and upstream for agents).
  Future<List<TicketSummary>> search(String groupId, String query, {int limit = 8}) async {
    final data = await call('helpDeskSearch', {'groupId': groupId, 'q': query, 'limit': limit});
    final rows = data is Map ? data['tickets'] : null;
    return [for (final row in (rows is List ? rows : const [])) TicketSummary.fromData(row)];
  }

  Future<TicketDetail> ticket(String ticketId) async =>
      TicketDetail.fromData(await call('helpDeskGetTicket', {'ticketId': ticketId}));

  /// Opens a ticket; [upstream] files it from the group to the desk above.
  /// Returns the new ticket's id.
  Future<String> create({
    required String groupId,
    required String subject,
    required String body,
    String? category,
    String priority = 'normal',
    bool upstream = false,
    TicketContext context = const TicketContext(),
  }) async {
    final data = await call('helpDeskCreateTicket', {
      'groupId': groupId,
      'target': upstream ? 'upstream' : 'desk',
      'subject': subject,
      'body': body,
      if (category != null && category.isNotEmpty) 'category': category,
      'priority': priority,
      'context': context.toMap(),
    });
    return data is Map ? '${data['ticketId']}' : '';
  }

  Future<void> reply(String ticketId, String body, {String? as, bool internal = false, bool resolve = false}) =>
      call('helpDeskReply', {
        'ticketId': ticketId,
        'body': body,
        if (as != null) 'as': as,
        'internal': internal,
        'resolve': resolve,
      });

  Future<void> setStatus(String ticketId, TicketStatus status, {String? as}) =>
      call('helpDeskSetStatus', {'ticketId': ticketId, 'status': status.name, if (as != null) 'as': as});

  Future<void> assign(String ticketId, String? assigneeUid) =>
      call('helpDeskAssign', {'ticketId': ticketId, 'assigneeUid': assigneeUid});

  /// Returns the upstream ticket's id.
  Future<String> escalate(String ticketId, {required String summary, bool shareThread = false}) async {
    final data = await call('helpDeskEscalate', {'ticketId': ticketId, 'summary': summary, 'shareThread': shareThread});
    return data is Map ? '${data['upstreamTicketId']}' : '';
  }

  Future<void> linkChange(String ticketId, {required String itemType, required String itemId}) =>
      call('helpDeskLinkChange', {'ticketId': ticketId, 'itemType': itemType, 'itemId': itemId});

  /// [groupId]'s desk settings, or the Bluejay desk's with [platformDesk].
  Future<DeskSettings> settings({String? groupId, bool platformDesk = false}) async => DeskSettings.fromData(
      await call('helpDeskGetSettings', platformDesk ? {'desk': 'platform'} : {'groupId': groupId}));

  Future<DeskSettings> saveSettings(Map<String, dynamic> patch, {String? groupId, bool platformDesk = false}) async =>
      DeskSettings.fromData(await call('helpDeskSaveSettings', {
        if (platformDesk) 'desk': 'platform' else 'groupId': groupId,
        'settings': patch,
      }));

  // Signed out (bluejay.gg/help/<groupId>).

  Future<PublicDesk> publicDesk(String groupId) async =>
      PublicDesk.fromData(await call('helpDeskPublicDesk', {'groupId': groupId}));

  /// Returns the link to the new ticket's page.
  Future<String> publicSubmit({
    required String groupId,
    required String name,
    required String email,
    required String subject,
    required String body,
    String? category,
    String? orderRef,
  }) async {
    final data = await call('helpDeskPublicSubmit', {
      'groupId': groupId,
      'name': name,
      'email': email,
      'subject': subject,
      'body': body,
      if (category != null && category.isNotEmpty) 'category': category,
      if (orderRef != null && orderRef.isNotEmpty) 'orderRef': orderRef,
    });
    return data is Map ? '${data['url']}' : '';
  }

  Future<TicketDetail> publicTicket(String token) async =>
      TicketDetail.fromData(await call('helpDeskPublicTicket', {'token': token}), publicView: true);

  Future<TicketDetail> publicReply(String token, {String body = '', bool resolve = false}) async =>
      TicketDetail.fromData(
        await call('helpDeskPublicReply', {'token': token, 'body': body, 'resolve': resolve}),
        publicView: true,
      );
}

/// A callable's refusal as one readable line.
String helpDeskErrorMessage(Object error) {
  if (error is FirebaseFunctionsException) {
    final message = (error.message ?? '').trim();
    if (message.isNotEmpty) return message;
    if (error.code == 'permission-denied') return 'You do not have access to this.';
    if (error.code == 'resource-exhausted') return 'Too many requests. Please try again shortly.';
  }
  return 'Something went wrong. Please try again.';
}
