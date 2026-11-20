import 'package:help_desk/help_desk_api.dart';
import 'package:help_desk/help_desk_models.dart';
import 'package:wiki/app_help.dart' show SuggestedGuide;

final fakeNow = DateTime(2026, 11, 15, 12);
int _ms(Duration ago) => fakeNow.subtract(ago).millisecondsSinceEpoch;

Map<String, dynamic> ticketRow(String id, {String status = 'open', String subject = 'Where is my order?', bool overdue = false}) => {
      'id': id,
      'subject': subject,
      'status': status,
      'priority': 'normal',
      'requesterKind': 'person',
      'requesterName': 'Gus Guest',
      'groupId': 'shop',
      'groupName': 'Corner Shop',
      'deskKey': 'group:shop',
      'deskLabel': 'Corner Shop',
      'messageCount': 1,
      'createdAtMs': _ms(const Duration(hours: 3)),
      'lastActivityAtMs': _ms(const Duration(hours: 2)),
      'overdue': overdue,
    };

/// An in-memory [HelpDeskApi]: canned answers, and every call recorded.
class FakeApi extends HelpDeskApi {
  FakeApi({Map<String, dynamic>? overview}) : overviewData = overview ?? agentOverview;

  static const agentOverview = {
    'groupId': 'shop',
    'groupName': 'Corner Shop',
    'canFile': true,
    'deskLabel': 'Corner Shop',
    'isAgent': true,
    'canContactUpstream': true,
    'upstreamLabel': 'Bluejay support',
    'categories': ['Question', 'Order'],
  };

  Map<String, dynamic> overviewData;
  final calls = <String, List<Map<String, dynamic>>>{};
  final lists = <String, List<Map<String, dynamic>>>{
    'mine': [],
    'inbox': [ticketRow('t1', overdue: true)],
    'upstream': [],
    'platform': [],
  };
  Map<String, dynamic> ticketData = {
    'ticket': {...ticketRow('t1'), 'context': {'appName': 'Shop', 'orderRef': 'A-7'}},
    'messages': [
      {'id': 'm1', 'side': 'requester', 'authorName': 'Gus Guest', 'body': 'It has been a week.', 'createdAtMs': _ms(const Duration(hours: 3))},
      {'id': 'm2', 'side': 'desk', 'internal': true, 'authorName': 'Olive', 'body': 'Courier is late', 'createdAtMs': _ms(const Duration(hours: 2))},
    ],
    'sides': {'requester': false, 'desk': true},
    'desk': {
      'agents': [{'uid': 'owner', 'name': 'Olive Owner'}],
      'savedReplies': [{'title': 'Shipping', 'body': 'Orders ship in 2 days.'}],
      'canEscalate': true,
      'upstreamLabel': 'Bluejay support',
    },
  };
  Object? overviewError;

  @override
  Future<Object?> call(String name, Map<String, dynamic> data) async {
    (calls[name] ??= []).add(data);
    switch (name) {
      case 'helpDeskOverview':
        if (overviewError != null) throw overviewError!;
        return overviewData;
      case 'helpDeskList':
        return {'tickets': lists[data['view']] ?? []};
      case 'helpDeskGetTicket':
      case 'helpDeskPublicTicket':
      case 'helpDeskPublicReply':
        return ticketData;
      case 'helpDeskCreateTicket':
        return {'ticketId': 'new1', 'deskLabel': 'Corner Shop'};
      case 'helpDeskEscalate':
        return {'upstreamTicketId': 'up1', 'upstreamLabel': 'Bluejay support'};
      case 'helpDeskPublicDesk':
        return {'groupId': 'shop', 'groupName': 'Corner Shop', 'categories': ['Order'], 'welcome': 'We reply within a day.'};
      case 'helpDeskPublicSubmit':
        return {'ticketId': 'p1', 'url': 'https://bluejay.gg/help/shop/t/x'};
      case 'helpDeskGetSettings':
      case 'helpDeskSaveSettings':
        return {'routing': 'self', 'categories': ['Question'], 'firstResponseHours': 24, 'canChangeRouting': false};
      default:
        return {};
    }
  }

  List<Map<String, dynamic>> callsTo(String name) => calls[name] ?? const [];
}

Future<List<SuggestedGuide>> noGuides(String text, {bool forGuest = false}) async => const [];

TicketSummary summaryOf(Map<String, dynamic> row) => TicketSummary.fromData(row);
