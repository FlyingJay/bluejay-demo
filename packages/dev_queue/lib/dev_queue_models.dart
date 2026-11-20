import 'package:cloud_firestore/cloud_firestore.dart';

// The client model of `dev_queue_items` (plans/development-queue/
// PHASE_2_DESIGN.md, sections 3.1 and 5.2). Wire values are the server's
// strings (functions/_dev_queue_model.js). An unknown value parses to
// `unknown` and renders the server's own label, so a state added on the
// server later never breaks an older client.

enum DevItemState {
  queued,
  building,
  checking,
  inReview,
  merged,
  awaitingUser,
  failed,
  live,
  declined,
  closed,
  unknown;

  static DevItemState parse(Object? raw) => _itemStates[raw] ?? unknown;

  /// Items in this state appear under Now.
  bool get isInFlight => const {
        building,
        checking,
        inReview,
        merged,
        awaitingUser,
      }.contains(this);

  /// Items in this state appear under Up next.
  bool get isWaitingForWork => this == queued || this == failed;

  bool get isTerminal => this == live || this == declined || this == closed;
}

const _itemStates = <Object?, DevItemState>{
  'queued': DevItemState.queued,
  'building': DevItemState.building,
  'checking': DevItemState.checking,
  'in_review': DevItemState.inReview,
  'merged': DevItemState.merged,
  'awaiting_user': DevItemState.awaitingUser,
  'failed': DevItemState.failed,
  'live': DevItemState.live,
  'declined': DevItemState.declined,
  'closed': DevItemState.closed,
};

enum DevStatusCode {
  upNext,
  waitingForSlot,
  received,
  building,
  checking,
  waitingOnYou,
  readyToTry,
  finalReview,
  live,
  declined,
  closed,
  unknown;

  static DevStatusCode parse(Object? raw) => _statusCodes[raw] ?? unknown;

  /// The server's wire value, or '' for [unknown].
  String get wire => _statusWire[this] ?? '';

  /// The label the server writes for this code (STATUS_LABELS in
  /// functions/_dev_queue_model.js), used when a doc carries no label.
  String get defaultLabel => _statusLabels[this] ?? '';

  /// Codes that ask the requester to act. The chip and the pill give these
  /// the accent colour and a dot.
  bool get needsYou => this == waitingOnYou || this == readyToTry;
}

const _statusCodes = <Object?, DevStatusCode>{
  'up_next': DevStatusCode.upNext,
  'waiting_for_slot': DevStatusCode.waitingForSlot,
  'received': DevStatusCode.received,
  'building': DevStatusCode.building,
  'checking': DevStatusCode.checking,
  'waiting_on_you': DevStatusCode.waitingOnYou,
  'ready_to_try': DevStatusCode.readyToTry,
  'final_review': DevStatusCode.finalReview,
  'live': DevStatusCode.live,
  'declined': DevStatusCode.declined,
  'closed': DevStatusCode.closed,
};

final _statusWire = {
  for (final e in _statusCodes.entries) e.value: e.key as String,
};

const _statusLabels = <DevStatusCode, String>{
  DevStatusCode.upNext: 'Up next',
  DevStatusCode.waitingForSlot: 'Waiting for your developer agent',
  DevStatusCode.received: 'Received',
  DevStatusCode.building: 'Building',
  DevStatusCode.checking: 'Checking',
  DevStatusCode.waitingOnYou: 'Waiting on you',
  DevStatusCode.readyToTry: 'Ready to try',
  DevStatusCode.finalReview: 'Final review',
  DevStatusCode.live: 'Live',
  DevStatusCode.declined: 'Declined',
  DevStatusCode.closed: 'Closed',
};

enum DevWaitingReason {
  clarification,
  previewApproval,
  unknown;

  static DevWaitingReason parse(Object? raw) {
    switch (raw) {
      case 'clarification':
        return clarification;
      case 'preview_approval':
        return previewApproval;
      default:
        return unknown;
    }
  }
}

/// `item.status` on a queue item, or `devStatus` on a ticket.
class DevStatus {
  final DevStatusCode code;

  /// The raw wire code, kept so an [DevStatusCode.unknown] status still
  /// counts as set.
  final String rawCode;
  final String label;
  final String detail;
  final DateTime? since;
  final String previewUrl;

  const DevStatus({
    required this.code,
    this.rawCode = '',
    required this.label,
    this.detail = '',
    this.since,
    this.previewUrl = '',
  });

  /// Null when [raw] is not a map or carries no code.
  static DevStatus? fromMap(Object? raw) {
    final data = _map(raw);
    final rawCode = _str(data['code']);
    if (rawCode.isEmpty) return null;
    final code = DevStatusCode.parse(rawCode);
    final label = _str(data['label']);
    return DevStatus(
      code: code,
      rawCode: rawCode,
      label: label.isNotEmpty ? label : (code.defaultLabel.isNotEmpty ? code.defaultLabel : rawCode),
      detail: _str(data['detail']),
      since: _date(data['since']),
      previewUrl: _str(data['previewUrl']),
    );
  }
}

/// `item.waiting`: why the item is in Waiting on you or Ready to try.
class DevWaiting {
  final DevWaitingReason reason;

  /// 'agent' or 'staff'. A staff question came from a ticket closed as
  /// "needs more info", and answering it reopens the ticket.
  final String askedBy;
  final String question;
  final String sha;
  final String previewUrl;
  final DateTime? since;
  final DateTime? deadline;

  /// True once the wait passed its timeout and the slot went to the owner's
  /// next request.
  final bool slotReleased;

  const DevWaiting({
    required this.reason,
    this.askedBy = '',
    this.question = '',
    this.sha = '',
    this.previewUrl = '',
    this.since,
    this.deadline,
    this.slotReleased = false,
  });

  bool get askedByStaff => askedBy == 'staff';

  static DevWaiting? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final data = _map(raw);
    return DevWaiting(
      reason: DevWaitingReason.parse(data['reason']),
      askedBy: _str(data['askedBy']),
      question: _str(data['question']),
      sha: _str(data['sha']),
      previewUrl: _str(data['previewUrl']),
      since: _date(data['since']),
      deadline: _date(data['deadline']),
      slotReleased: data['slotReleasedAt'] != null,
    );
  }
}

/// One entry of `item.conversation`.
class DevConversationEntry {
  /// 'question', 'answer', 'tweak' or 'approval'.
  final String kind;
  final String text;

  /// 'agent', 'staff' or a uid.
  final String by;
  final DateTime? at;

  const DevConversationEntry({
    required this.kind,
    this.text = '',
    this.by = '',
    this.at,
  });

  factory DevConversationEntry.fromMap(Object? raw) {
    final data = _map(raw);
    return DevConversationEntry(
      kind: _str(data['kind']),
      text: _str(data['text']),
      by: _str(data['by']),
      at: _date(data['at']),
    );
  }
}

/// `item.estimate`: the words the server writes for a sized item
/// (`estimateFor` in functions/_dev_queue_model.js). [short] is the chip
/// ("Small"), [line] the sentence ("Takes a little longer than a small
/// change").
class DevEstimate {
  final String size;
  final String short;
  final String line;

  const DevEstimate({this.size = '', this.short = '', this.line = ''});

  /// Null when [raw] is not a map or carries no words.
  static DevEstimate? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final data = _map(raw);
    final estimate = DevEstimate(
      size: _str(data['size']).toUpperCase(),
      short: _str(data['short']),
      line: _str(data['line']),
    );
    return estimate.short.isEmpty && estimate.line.isEmpty ? null : estimate;
  }
}

/// `item.regressionOf`: the shipped item a regression fix is for. The PR
/// fields the server also keeps are left out, as on [DevQueueItem].
class DevRegressionOf {
  final String itemKey;
  final String title;

  const DevRegressionOf({required this.itemKey, this.title = ''});

  static DevRegressionOf? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final data = _map(raw);
    final key = _str(data['itemKey']);
    final title = _str(data['title']);
    if (key.isEmpty && title.isEmpty) return null;
    return DevRegressionOf(itemKey: key, title: title);
  }
}

/// How long after going live "This broke something" stays on a Shipped
/// item (`regressionWindowDays` in functions/_dev_queue_model.js).
const devQueueRegressionWindow = Duration(days: 30);

/// The owner id of platform work: requests the platform files for itself
/// (advisor rounds, the spare-capacity worker) instead of a person.
const String devPlatformOwnerId = 'platform';

/// Who to show as the requester of platform work, from the ticket's
/// `platformSource`.
String devPlatformRequesterName(Object? platformSource) {
  switch (platformSource) {
    case 'advisor-round':
      return 'Advisor rounds';
    case 'spare-capacity':
      return 'Spare-capacity worker';
    case 'security-audit':
      return 'Security Audit';
    case 'automations-sweep':
      return 'Automations contract sweep';
    default:
      return 'Bluejay platform';
  }
}

/// A `dev_queue_items` doc. PR fields are left out on purpose: end users
/// never see pull requests.
class DevQueueItem {
  final String key;
  final String itemType;
  final String itemId;
  final String title;
  final String relatedAppId;

  /// `payload.ticket.relatedAppName`, the name the ticket was filed under.
  final String relatedAppName;
  final String groupId;
  final DevItemState state;
  final DevStatus status;
  final double rank;
  final bool managed;
  final String? holdReason;
  final DevWaiting? waiting;
  final String previewUrl;
  final bool previewCurrent;
  final List<DevConversationEntry> conversation;
  final String? approvedSha;
  final String? closureLabel;
  final String shippedAppId;

  /// 'S', 'M' or 'L' once the request is sized; null until then.
  final String? size;

  /// `sizing.source`: 'ai', 'heuristic' or 'admin'; '' when unsized.
  final String sizeSource;

  /// The admin-set target for a Large item.
  final DateTime? targetDate;
  final DevEstimate? estimate;

  /// The first grant of the current cycle; null until work starts.
  final DateTime? startedAt;

  /// A regression fix: built ahead of the owner's other requests.
  final bool expedite;
  final DevRegressionOf? regressionOf;

  /// On a live item: the keys of regression items filed from it.
  final List<String> regressions;

  /// How many times the item has been granted a slot.
  final int grants;
  final DateTime? createdAt;
  final DateTime? stateChangedAt;

  const DevQueueItem({
    required this.key,
    this.itemType = '',
    this.itemId = '',
    this.title = '',
    this.relatedAppId = '',
    this.relatedAppName = '',
    this.groupId = '',
    required this.state,
    required this.status,
    this.rank = 0,
    this.managed = false,
    this.holdReason,
    this.waiting,
    this.previewUrl = '',
    this.previewCurrent = false,
    this.conversation = const [],
    this.approvedSha,
    this.closureLabel,
    this.shippedAppId = '',
    this.size,
    this.sizeSource = '',
    this.targetDate,
    this.estimate,
    this.startedAt,
    this.expedite = false,
    this.regressionOf,
    this.regressions = const [],
    this.grants = 0,
    this.createdAt,
    this.stateChangedAt,
  });

  factory DevQueueItem.fromSnapshot(DocumentSnapshot<Map<String, dynamic>> s) =>
      DevQueueItem.fromMap(s.id, s.data() ?? const {});

  factory DevQueueItem.fromMap(String key, Map<String, dynamic> data) {
    final state = DevItemState.parse(data['state']);
    final preview = _map(data['preview']);
    final payloadTicket = _map(_map(data['payload'])['ticket']);
    final hold = _map(data['hold']);
    final approval = _map(data['approval']);
    final closure = _map(data['closure']);
    final size = _str(data['size']).toUpperCase();
    final sizing = _map(data['sizing']);
    return DevQueueItem(
      key: key,
      itemType: _str(data['itemType']),
      itemId: _str(data['itemId']),
      title: _str(data['title']),
      relatedAppId: _str(data['relatedAppId']),
      relatedAppName: _str(payloadTicket['relatedAppName']),
      groupId: _str(data['groupId']),
      state: state,
      status: DevStatus.fromMap(data['status']) ??
          DevStatus(code: DevStatusCode.unknown, label: _fallbackLabel(state)),
      rank: (data['rank'] as num?)?.toDouble() ?? 0,
      managed: data['managed'] == true,
      holdReason: _nonEmpty(hold['reason']),
      waiting: DevWaiting.fromMap(data['waiting']),
      previewUrl: _str(preview['url']),
      previewCurrent: preview['current'] == true,
      conversation: (data['conversation'] is List)
          ? (data['conversation'] as List).map(DevConversationEntry.fromMap).toList()
          : const [],
      approvedSha: _nonEmpty(approval['sha']),
      closureLabel: _nonEmpty(closure['reasonLabel']),
      shippedAppId: _str(data['shippedAppId']),
      size: const {'S', 'M', 'L'}.contains(size) ? size : null,
      sizeSource: _str(sizing['source']),
      targetDate: _date(data['targetDate']),
      estimate: DevEstimate.fromMap(data['estimate']),
      startedAt: _date(data['startedAt']),
      expedite: data['expedite'] == true,
      regressionOf: DevRegressionOf.fromMap(data['regressionOf']),
      regressions: (data['regressions'] is List)
          ? (data['regressions'] as List).map(_str).where((k) => k.isNotEmpty).toList()
          : const [],
      grants: (data['grants'] as num?)?.toInt() ?? 0,
      createdAt: _date(data['createdAt']),
      stateChangedAt: _date(data['stateChangedAt']),
    );
  }

  /// The app name to show: the ticket's own, else one made from the id.
  String get appName {
    if (relatedAppName.isNotEmpty) return relatedAppName;
    if (relatedAppId.isEmpty) return '';
    return relatedAppId
        .split(RegExp(r'[-_\s]+'))
        .where((w) => w.isNotEmpty)
        .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }

  String get displayTitle => title.isNotEmpty ? title : 'Untitled request';

  /// Waiting on you with a question to answer.
  bool get isAwaitingAnswer =>
      state == DevItemState.awaitingUser && waiting?.reason == DevWaitingReason.clarification;

  /// Ready to try, waiting for an approval or a tweak.
  bool get isAwaitingApproval =>
      state == DevItemState.awaitingUser && waiting?.reason == DevWaitingReason.previewApproval;

  /// Work has started on this request: a slot was granted this cycle, or it
  /// is past Up next.
  bool get isStarted =>
      startedAt != null || state.isInFlight || state == DevItemState.failed || state == DevItemState.live;

  /// The requester can still change the text: queued, never started, and
  /// not in a managed workspace.
  bool get canEdit => state == DevItemState.queued && startedAt == null && !managed;

  /// The requester can withdraw it: active, not yet merged, not managed.
  bool get canWithdraw => !managed && !state.isTerminal && state != DevItemState.unknown && state != DevItemState.merged;

  /// "This broke something": a live bug, idea or app within
  /// [devQueueRegressionWindow] of going live, with no regression from it
  /// still open. [activeKeys] are the owner's active item keys; a key in
  /// [regressions] that isn't among them has finished.
  bool canReportRegression({DateTime? now, Set<String> activeKeys = const {}}) {
    if (state != DevItemState.live || managed || itemType == 'task') return false;
    final at = stateChangedAt;
    if (at == null) return false;
    if ((now ?? DateTime.now()).difference(at) > devQueueRegressionWindow) return false;
    return !regressions.any(activeKeys.contains);
  }

  /// The open regression item filed from this one, if any.
  String? openRegressionKey(Set<String> activeKeys) {
    for (final key in regressions) {
      if (activeKeys.contains(key)) return key;
    }
    return null;
  }

  /// The preview link for Ready to try: the waiting sha's, else the item's.
  String get tryUrl {
    final fromWaiting = waiting?.previewUrl ?? '';
    return fromWaiting.isNotEmpty ? fromWaiting : previewUrl;
  }
}

String _fallbackLabel(DevItemState state) {
  switch (state) {
    case DevItemState.queued:
    case DevItemState.failed:
      return 'Up next';
    case DevItemState.building:
      return 'Building';
    case DevItemState.checking:
      return 'Checking';
    case DevItemState.inReview:
    case DevItemState.merged:
      return 'Final review';
    case DevItemState.awaitingUser:
      return 'Waiting on you';
    case DevItemState.live:
      return 'Live';
    case DevItemState.declined:
      return 'Declined';
    case DevItemState.closed:
      return 'Closed';
    case DevItemState.unknown:
      return '';
  }
}

/// The item key for a ticket (`<itemType>__<itemId>`, as the server's
/// `itemKeyFor`).
String devQueueItemKey(String itemType, String itemId) => '${itemType}__$itemId';

// ─────────────────────────────────────────────────────────────────────────────
// Managed workspaces (devQueueListManaged)
// ─────────────────────────────────────────────────────────────────────────────

class ManagedQueueItem {
  final String itemKey;
  final String itemType;
  final String itemId;
  final String title;
  final String relatedAppName;
  final String submitterName;
  final String excerpt;
  final DateTime? createdAt;
  final bool held;
  final DevStatus? status;

  const ManagedQueueItem({
    required this.itemKey,
    this.itemType = '',
    this.itemId = '',
    this.title = '',
    this.relatedAppName = '',
    this.submitterName = '',
    this.excerpt = '',
    this.createdAt,
    this.held = false,
    this.status,
  });

  factory ManagedQueueItem.fromMap(Object? raw) {
    final data = _map(raw);
    return ManagedQueueItem(
      itemKey: _str(data['itemKey']),
      itemType: _str(data['itemType']),
      itemId: _str(data['itemId']),
      title: _str(data['title']),
      relatedAppName: _str(data['relatedAppName']),
      submitterName: _str(data['submitterName']),
      excerpt: _str(data['excerpt']),
      createdAt: _date(data['createdAt']),
      held: data['held'] == true,
      status: DevStatus.fromMap(data['status']),
    );
  }
}

class ManagedQueueGroup {
  final String groupId;
  final String name;
  final List<ManagedQueueItem> items;

  const ManagedQueueGroup({required this.groupId, this.name = '', this.items = const []});

  factory ManagedQueueGroup.fromMap(Object? raw) {
    final data = _map(raw);
    final items = data['items'];
    return ManagedQueueGroup(
      groupId: _str(data['groupId']),
      name: _str(data['name']),
      items: items is List ? items.map(ManagedQueueItem.fromMap).toList() : const [],
    );
  }

  /// Parses the callable's `{groups: [...]}` result.
  static List<ManagedQueueGroup> listFromResult(Object? raw) {
    final groups = _map(raw)['groups'];
    if (groups is! List) return const [];
    return groups.map(ManagedQueueGroup.fromMap).toList();
  }
}

/// A teammate's request that went live for the group
/// (`devQueueGroupShipped`'s `team`).
class TeamShippedItem {
  final String itemKey;
  final String title;
  final String appId;
  final String appName;

  /// Empty when the server couldn't name them.
  final String requesterName;
  final DateTime? liveAt;

  const TeamShippedItem({
    required this.itemKey,
    required this.title,
    this.appId = '',
    this.appName = '',
    this.requesterName = '',
    this.liveAt,
  });

  static TeamShippedItem fromMap(Object? raw) {
    final data = _map(raw);
    return TeamShippedItem(
      itemKey: _str(data['itemKey']),
      title: _str(data['title']),
      appId: _str(data['appId']),
      appName: _str(data['appName']),
      requesterName: _str(data['requesterName']),
      liveAt: _date(data['liveAt']),
    );
  }

  String get displayTitle => title.isNotEmpty ? title : 'Untitled request';
}

/// A change another group asked for that went live in one of this group's
/// apps (`devQueueGroupShipped`'s `bonus`).
class BonusChange {
  final String id;

  /// The friendly release note.
  final String title;

  /// The group's installed apps the change touched, as (appId, name).
  final List<({String appId, String name})> apps;
  final DateTime? liveAt;

  const BonusChange({required this.id, required this.title, this.apps = const [], this.liveAt});

  static BonusChange fromMap(Object? raw) {
    final data = _map(raw);
    final apps = data['apps'];
    return BonusChange(
      id: _str(data['id']),
      title: _str(data['title']),
      apps: apps is List
          ? [
              for (final app in apps.map(_map))
                if (_str(app['appId']).isNotEmpty)
                  (appId: _str(app['appId']), name: _str(app['name']).isNotEmpty ? _str(app['name']) : _str(app['appId'])),
            ]
          : const [],
      liveAt: _date(data['liveAt']),
    );
  }
}

/// What else shipped for a group: teammates' requests and other groups'
/// changes to its apps (`devQueueGroupShipped`).
class GroupShipped {
  final List<TeamShippedItem> team;
  final List<BonusChange> bonus;

  const GroupShipped({this.team = const [], this.bonus = const []});

  static const empty = GroupShipped();

  static GroupShipped fromResult(Object? raw) {
    final data = _map(raw);
    final team = data['team'];
    final bonus = data['bonus'];
    return GroupShipped(
      team: team is List ? team.map(TeamShippedItem.fromMap).where((i) => i.itemKey.isNotEmpty).toList() : const [],
      bonus: bonus is List ? bonus.map(BonusChange.fromMap).where((c) => c.title.isNotEmpty).toList() : const [],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Parsing helpers
// ─────────────────────────────────────────────────────────────────────────────

Map<String, dynamic> _map(Object? raw) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) return raw.map((k, v) => MapEntry(k.toString(), v));
  return const {};
}

String _str(Object? raw) => raw is String ? raw.trim() : '';

String? _nonEmpty(Object? raw) {
  final value = _str(raw);
  return value.isEmpty ? null : value;
}

DateTime? _date(Object? raw) {
  if (raw is Timestamp) return raw.toDate();
  if (raw is DateTime) return raw;
  if (raw is String) return DateTime.tryParse(raw)?.toLocal();
  if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
  if (raw is Map) {
    // A Timestamp that crossed a callable: {_seconds, _nanoseconds}.
    final seconds = raw['_seconds'] ?? raw['seconds'];
    if (seconds is num) return DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
  }
  return null;
}
