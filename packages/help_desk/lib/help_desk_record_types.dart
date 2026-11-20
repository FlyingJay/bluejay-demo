import 'package:flutter/material.dart';
import 'package:shared_services/record_types.dart';

import 'constants.dart';
import 'help_desk_api.dart';

/// Launch arg that opens Help Desk on one ticket.
const String ticketArg = 'ticket';

/// Help Desk tickets are read only through its callables, so their search
/// is the helpDeskSearch callable behind the same interface: the tickets
/// the person already sees in Help Desk, in the group.
class HelpDeskRecordSearch extends RecordSearch {
  const HelpDeskRecordSearch(this.type, {this.api = const HelpDeskApi()});

  final RecordType type;
  final HelpDeskApi api;

  @override
  Future<List<RecordHit>> find(String query, {required String groupId, int limit = defaultRecordSearchLimit}) async {
    if (groupId.isEmpty) return const [];
    final rows = await api.search(groupId, query, limit: limit);
    return [for (final row in rows) type.hitOf(row.id, {'subject': row.subject, 'requesterName': row.requesterName})];
  }
}

/// Help Desk's record types (plans/record-search): tickets, found by
/// subject or requester.
final List<RecordType> helpDeskRecordTypes = [
  RecordType(
    id: 'help-desk.ticket',
    appId: APP_ID,
    collection: 'help_tickets',
    label: 'Ticket',
    pluralLabel: 'Tickets',
    icon: Icons.support_agent_outlined,
    title: (d) {
      final subject = '${d['subject'] ?? ''}'.trim();
      return subject.isEmpty ? 'Untitled ticket' : subject;
    },
    subtitle: (d) {
      final name = '${d['requesterName'] ?? ''}'.trim();
      return name.isEmpty ? null : name;
    },
    searchWith: (type) => HelpDeskRecordSearch(type),
    launchArgs: (ref) => {ticketArg: ref.id},
  ),
];
