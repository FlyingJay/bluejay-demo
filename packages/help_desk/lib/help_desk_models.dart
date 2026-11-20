import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';

/// The ticket lists a person can see (helpDeskList's `view`).
enum TicketView {
  /// Tickets the caller filed in the group.
  mine,

  /// Tickets filed to the group's desk (its admins).
  inbox,

  /// Tickets the group filed with the desk above it (Bluejay, or the managing group).
  upstream,

  /// The Bluejay desk (support staff).
  platform,
}

DateTime? _date(Object? ms) => ms is num ? DateTime.fromMillisecondsSinceEpoch(ms.toInt()) : null;

String _str(Object? value) => value is String ? value : '';

List<String> _strings(Object? value) =>
    value is List ? [for (final v in value) if (v is String && v.isNotEmpty) v] : const [];

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const {};

/// What the caller can do in a group's Help Desk (helpDeskOverview).
class HelpDeskOverview {
  final String groupId;
  final String groupName;
  final bool canFile;
  final String deskLabel;
  final bool routedToPlatform;
  final bool isAgent;
  final bool canContactUpstream;
  final String upstreamLabel;
  final bool isStaff;
  final bool isPlatformAdmin;
  final bool isGuest;
  final List<String> categories;
  final String welcome;
  final String? publicFormUrl;

  const HelpDeskOverview({
    required this.groupId,
    required this.groupName,
    this.canFile = false,
    this.deskLabel = '',
    this.routedToPlatform = false,
    this.isAgent = false,
    this.canContactUpstream = false,
    this.upstreamLabel = '',
    this.isStaff = false,
    this.isPlatformAdmin = false,
    this.isGuest = false,
    this.categories = const [],
    this.welcome = '',
    this.publicFormUrl,
  });

  factory HelpDeskOverview.fromData(Object? raw) {
    final d = _map(raw);
    return HelpDeskOverview(
      groupId: _str(d['groupId']),
      groupName: _str(d['groupName']),
      canFile: d['canFile'] == true,
      deskLabel: _str(d['deskLabel']),
      routedToPlatform: d['routedToPlatform'] == true,
      isAgent: d['isAgent'] == true,
      canContactUpstream: d['canContactUpstream'] == true,
      upstreamLabel: _str(d['upstreamLabel']),
      isStaff: d['isStaff'] == true,
      isPlatformAdmin: d['isPlatformAdmin'] == true,
      isGuest: d['isGuest'] == true,
      categories: _strings(d['categories']),
      welcome: _str(d['welcome']),
      publicFormUrl: d['publicFormUrl'] is String ? d['publicFormUrl'] as String : null,
    );
  }

  /// The views this person has, in tab order.
  List<TicketView> get views => [
        if (canFile) TicketView.mine,
        if (isAgent) TicketView.inbox,
        if (canContactUpstream) TicketView.upstream,
        if (isStaff) TicketView.platform,
      ];
}

/// A ticket's status, as stored (`help_tickets.status`).
enum TicketStatus { open, pending, escalated, resolved, closed }

TicketStatus ticketStatusFrom(String value) =>
    TicketStatus.values.firstWhere((s) => s.name == value, orElse: () => TicketStatus.open);

/// A status as the person looking at it reads it: the desk sees whose move
/// it is; the requester sees what is happening with their request.
({String label, BjTone tone, IconData icon}) statusDisplay(TicketStatus status, {required bool forDesk}) =>
    switch (status) {
      TicketStatus.open => forDesk
          ? (label: 'Needs reply', tone: BjTone.warning, icon: Icons.mark_chat_unread_outlined)
          : (label: 'Waiting for reply', tone: BjTone.info, icon: Icons.schedule_rounded),
      TicketStatus.pending => forDesk
          ? (label: 'Waiting on requester', tone: BjTone.info, icon: Icons.hourglass_empty_rounded)
          : (label: 'Replied', tone: BjTone.warning, icon: Icons.mark_chat_unread_outlined),
      TicketStatus.escalated => (label: 'Escalated', tone: BjTone.accent, icon: Icons.north_east_rounded),
      TicketStatus.resolved => (label: 'Resolved', tone: BjTone.success, icon: Icons.check_circle_outline_rounded),
      TicketStatus.closed => (label: 'Closed', tone: BjTone.neutral, icon: Icons.lock_outline_rounded),
    };

const ticketPriorities = ['normal', 'high', 'urgent'];

String priorityLabel(String priority) => switch (priority) {
      'high' => 'High',
      'urgent' => 'Urgent',
      _ => 'Normal',
    };

/// A row of a ticket list.
class TicketSummary {
  final String id;
  final String subject;
  final TicketStatus status;
  final String priority;
  final String category;
  final String requesterKind;
  final String requesterName;
  final String groupId;
  final String groupName;
  final String deskKey;
  final String deskLabel;
  final String? assigneeUid;
  final String assigneeName;
  final int messageCount;
  final DateTime? createdAt;
  final DateTime? lastActivityAt;
  final bool overdue;
  final bool escalated;
  final bool fromEscalation;

  const TicketSummary({
    required this.id,
    required this.subject,
    this.status = TicketStatus.open,
    this.priority = 'normal',
    this.category = '',
    this.requesterKind = 'person',
    this.requesterName = '',
    this.groupId = '',
    this.groupName = '',
    this.deskKey = '',
    this.deskLabel = '',
    this.assigneeUid,
    this.assigneeName = '',
    this.messageCount = 0,
    this.createdAt,
    this.lastActivityAt,
    this.overdue = false,
    this.escalated = false,
    this.fromEscalation = false,
  });

  factory TicketSummary.fromData(Object? raw) {
    final d = _map(raw);
    return TicketSummary(
      id: _str(d['id']),
      subject: _str(d['subject']),
      status: ticketStatusFrom(_str(d['status'])),
      priority: _str(d['priority']).isEmpty ? 'normal' : _str(d['priority']),
      category: _str(d['category']),
      requesterKind: _str(d['requesterKind']).isEmpty ? 'person' : _str(d['requesterKind']),
      requesterName: _str(d['requesterName']),
      groupId: _str(d['groupId']),
      groupName: _str(d['groupName']),
      deskKey: _str(d['deskKey']),
      deskLabel: _str(d['deskLabel']),
      assigneeUid: d['assigneeUid'] is String ? d['assigneeUid'] as String : null,
      assigneeName: _str(d['assigneeName']),
      messageCount: (d['messageCount'] as num?)?.toInt() ?? 0,
      createdAt: _date(d['createdAtMs']),
      lastActivityAt: _date(d['lastActivityAtMs']),
      overdue: d['overdue'] == true,
      escalated: d['escalated'] == true,
      fromEscalation: d['fromEscalation'] == true,
    );
  }

  bool get isActive =>
      status == TicketStatus.open || status == TicketStatus.pending || status == TicketStatus.escalated;

  bool get isPlatformDesk => deskKey == 'platform';
}

/// One message of a ticket's conversation.
class TicketMessage {
  final String id;

  /// 'requester', 'desk' or 'system'.
  final String side;
  final bool internal;
  final String authorName;
  final String? authorUid;
  final String body;
  final DateTime? createdAt;

  const TicketMessage({
    required this.id,
    required this.side,
    required this.body,
    this.internal = false,
    this.authorName = '',
    this.authorUid,
    this.createdAt,
  });

  factory TicketMessage.fromData(Object? raw) {
    final d = _map(raw);
    return TicketMessage(
      id: _str(d['id']),
      side: _str(d['side']).isEmpty ? 'system' : _str(d['side']),
      internal: d['internal'] == true,
      authorName: _str(d['authorName']),
      authorUid: d['authorUid'] is String ? d['authorUid'] as String : null,
      body: _str(d['body']),
      createdAt: _date(d['createdAtMs']),
    );
  }

  bool get isSystem => side == 'system';
}

/// A bug report or idea the desk filed from a ticket.
class LinkedChange {
  final String itemType;
  final String itemId;

  const LinkedChange(this.itemType, this.itemId);

  String get label => itemType == 'bug' ? 'Bug report' : 'Idea';
}

class SavedReply {
  final String title;
  final String body;

  const SavedReply({required this.title, required this.body});

  Map<String, dynamic> toMap() => {'title': title, 'body': body};
}

class DeskAgent {
  final String uid;
  final String name;

  const DeskAgent(this.uid, this.name);
}

/// What the desk side gets with a ticket.
class DeskTools {
  final List<DeskAgent> agents;
  final List<SavedReply> savedReplies;
  final bool canEscalate;
  final String upstreamLabel;

  const DeskTools({
    this.agents = const [],
    this.savedReplies = const [],
    this.canEscalate = false,
    this.upstreamLabel = '',
  });

  factory DeskTools.fromData(Object? raw) {
    final d = _map(raw);
    return DeskTools(
      agents: [
        for (final a in (d['agents'] is List ? d['agents'] as List : const []))
          DeskAgent(_str(_map(a)['uid']), _str(_map(a)['name'])),
      ],
      savedReplies: _savedReplies(d['savedReplies']),
      canEscalate: d['canEscalate'] == true,
      upstreamLabel: _str(d['upstreamLabel']),
    );
  }
}

List<SavedReply> _savedReplies(Object? raw) => [
      for (final r in (raw is List ? raw : const []))
        SavedReply(title: _str(_map(r)['title']), body: _str(_map(r)['body'])),
    ];

/// A ticket opened in full (helpDeskGetTicket or, signed out, helpDeskPublicTicket).
class TicketDetail {
  final TicketSummary summary;
  final Map<String, String> context;
  final String requesterEmail;
  final String? parentTicketId;
  final String? upstreamTicketId;
  final List<LinkedChange> linkedChanges;
  final List<TicketMessage> messages;
  final bool asRequester;
  final bool asDesk;
  final DeskTools? desk;

  const TicketDetail({
    required this.summary,
    this.context = const {},
    this.requesterEmail = '',
    this.parentTicketId,
    this.upstreamTicketId,
    this.linkedChanges = const [],
    this.messages = const [],
    this.asRequester = false,
    this.asDesk = false,
    this.desk,
  });

  factory TicketDetail.fromData(Object? raw, {bool publicView = false}) {
    final d = _map(raw);
    final t = _map(d['ticket']);
    final sides = _map(d['sides']);
    return TicketDetail(
      summary: TicketSummary.fromData(t),
      context: {
        for (final e in _map(t['context']).entries)
          if (e.value is String && (e.value as String).isNotEmpty) e.key: e.value as String,
      },
      requesterEmail: _str(t['requesterEmail']),
      parentTicketId: t['parentTicketId'] is String ? t['parentTicketId'] as String : null,
      upstreamTicketId: t['upstreamTicketId'] is String ? t['upstreamTicketId'] as String : null,
      linkedChanges: [
        for (final l in (t['linkedChanges'] is List ? t['linkedChanges'] as List : const []))
          LinkedChange(_str(_map(l)['itemType']), _str(_map(l)['itemId'])),
      ],
      messages: [
        for (final m in (d['messages'] is List ? d['messages'] as List : const [])) TicketMessage.fromData(m),
      ],
      asRequester: publicView || sides['requester'] == true,
      asDesk: !publicView && sides['desk'] == true,
      desk: d['desk'] == null ? null : DeskTools.fromData(d['desk']),
    );
  }
}

/// A desk's settings (helpDeskGetSettings).
class DeskSettings {
  final String routing;
  final bool guestIntake;
  final bool publicIntake;
  final List<String> categories;
  final List<SavedReply> savedReplies;
  final int firstResponseHours;
  final String welcome;
  final bool platformDesk;
  final bool canChangeRouting;
  final String? publicFormUrl;

  const DeskSettings({
    this.routing = 'self',
    this.guestIntake = false,
    this.publicIntake = false,
    this.categories = const [],
    this.savedReplies = const [],
    this.firstResponseHours = 24,
    this.welcome = '',
    this.platformDesk = false,
    this.canChangeRouting = false,
    this.publicFormUrl,
  });

  factory DeskSettings.fromData(Object? raw) {
    final d = _map(raw);
    return DeskSettings(
      routing: _str(d['routing']).isEmpty ? 'self' : _str(d['routing']),
      guestIntake: d['guestIntake'] == true,
      publicIntake: d['publicIntake'] == true,
      categories: _strings(d['categories']),
      savedReplies: _savedReplies(d['savedReplies']),
      firstResponseHours: (d['firstResponseHours'] as num?)?.toInt() ?? 24,
      welcome: _str(d['welcome']),
      platformDesk: d['platformDesk'] == true,
      canChangeRouting: d['canChangeRouting'] == true,
      publicFormUrl: d['publicFormUrl'] is String ? d['publicFormUrl'] as String : null,
    );
  }
}

/// The signed-out form's header (helpDeskPublicDesk).
class PublicDesk {
  final String groupId;
  final String groupName;
  final List<String> categories;
  final String welcome;

  const PublicDesk({required this.groupId, required this.groupName, this.categories = const [], this.welcome = ''});

  factory PublicDesk.fromData(Object? raw) {
    final d = _map(raw);
    return PublicDesk(
      groupId: _str(d['groupId']),
      groupName: _str(d['groupName']),
      categories: _strings(d['categories']),
      welcome: _str(d['welcome']),
    );
  }
}

/// Where a ticket came from, filled in by whatever opened the form.
class TicketContext {
  final String? appId;
  final String? appName;
  final String? orderRef;

  const TicketContext({this.appId, this.appName, this.orderRef});

  Map<String, String> toMap() => {
        if (appId != null && appId!.isNotEmpty) 'appId': appId!,
        if (appName != null && appName!.isNotEmpty) 'appName': appName!,
        if (orderRef != null && orderRef!.isNotEmpty) 'orderRef': orderRef!,
      };
}

/// "5m", "3h", "2d", or a date, for list rows.
String relativeTime(DateTime? at, DateTime now) {
  if (at == null) return '';
  final diff = now.difference(at);
  if (diff.inMinutes < 1) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  if (diff.inDays < 7) return '${diff.inDays}d';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${months[at.month - 1]} ${at.day}';
}
