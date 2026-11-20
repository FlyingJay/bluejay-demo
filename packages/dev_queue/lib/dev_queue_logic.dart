import 'dev_queue_models.dart';

// Pure decisions behind the chip, the queue screen and the "Added to your
// queue" confirmation (PHASE_2_DESIGN.md section 6), kept free of widgets so
// they are unit-tested on their own.

/// The width at which the chip switches to its long form.
const double devQueueChipWideBreakpoint = 600;

/// The items the queue screen and the chip show: active, not managed, in
/// rank order. Managed items never appear in a person's queue.
List<DevQueueItem> visibleQueue(Iterable<DevQueueItem> items) {
  final list = items.where((i) => !i.managed && !i.state.isTerminal).toList()
    ..sort(_byRank);
  return list;
}

int _byRank(DevQueueItem a, DevQueueItem b) {
  final c = a.rank.compareTo(b.rank);
  return c != 0 ? c : a.key.compareTo(b.key);
}

/// Now: building, checking, in review, merged and waiting-on-you items.
List<DevQueueItem> nowItems(List<DevQueueItem> queue) =>
    queue.where((i) => i.state.isInFlight).toList();

/// Up next: queued and failed items, in rank order.
List<DevQueueItem> upNextItems(List<DevQueueItem> queue) =>
    queue.where((i) => i.state.isWaitingForWork).toList();

/// "#k" positions: each item's place among every active, non-managed item,
/// in-flight ones included.
Map<String, int> queuePositions(List<DevQueueItem> queue) => {
      for (var i = 0; i < queue.length; i++) queue[i].key: i + 1,
    };

/// [queuePositions] with Up next shown in [upNextOrder] (a reorder in
/// flight): Up next items keep the rank slots they hold among the in-flight
/// items, filled in the new order.
Map<String, int> queuePositionsWithOrder(List<DevQueueItem> queue, List<DevQueueItem> upNextOrder) {
  final pending = List<DevQueueItem>.from(upNextOrder);
  final ordered = <DevQueueItem>[
    for (final item in queue)
      if (!item.state.isWaitingForWork)
        item
      else if (pending.isNotEmpty)
        pending.removeAt(0),
    ...pending,
  ];
  return queuePositions(ordered);
}

const _inFlightOrder = [
  DevItemState.merged,
  DevItemState.inReview,
  DevItemState.checking,
  DevItemState.building,
];

/// The chip's primary item: the first item waiting on you, else the most
/// advanced in-flight item, else the first item in Up next. Null when the
/// queue is empty.
DevQueueItem? chipPrimaryItem(List<DevQueueItem> queue) {
  for (final item in queue) {
    if (item.state == DevItemState.awaitingUser) return item;
  }
  for (final state in _inFlightOrder) {
    for (final item in queue) {
      if (item.state == state) return item;
    }
  }
  for (final item in queue) {
    if (item.state.isWaitingForWork) return item;
  }
  return null;
}

/// What the chip says. [count] is the number of other items in Up next.
class DevQueueChipCopy {
  final String text;
  final String semanticsLabel;
  final bool needsYou;
  final bool empty;

  const DevQueueChipCopy({
    required this.text,
    required this.semanticsLabel,
    this.needsYou = false,
    this.empty = false,
  });
}

String ellipsize(String value, int max) {
  final chars = value.runes.toList();
  if (chars.length <= max) return value;
  return '${String.fromCharCodes(chars.take(max - 1)).trimRight()}…';
}

DevQueueChipCopy chipCopy(List<DevQueueItem> queue, {required bool wide}) {
  final primary = chipPrimaryItem(queue);
  if (primary == null) {
    return DevQueueChipCopy(
      text: wide ? 'Your queue is empty' : 'Queue',
      semanticsLabel: 'Your queue. Your queue is empty.',
      empty: true,
    );
  }
  final others = queue.where((i) => i.state.isWaitingForWork && i.key != primary.key).length;
  final label = primary.status.label;
  final title = primary.displayTitle;
  final text = wide
      ? '$label: ${ellipsize(title, 28)}${others > 0 ? ' · +$others waiting' : ''}'
      : '$label${others > 0 ? ' · +$others' : ''}';
  final semantics = 'Your queue. $label: $title.${others > 0 ? ' $others more waiting.' : ''}';
  return DevQueueChipCopy(
    text: text,
    semanticsLabel: semantics,
    needsYou: primary.status.code.needsYou,
  );
}

/// Whether the chip shows at all: a signed-in member (not a guest) in a
/// group whose queue is not managed.
bool shouldShowDevQueueChip({
  required bool signedIn,
  required bool isGuest,
  required String? groupDevQueueMode,
}) =>
    signedIn && !isGuest && groupDevQueueMode != 'managed';

/// [keys] with the item at [index] moved to [target] (both after-move
/// indexes), for Move to top / up / down.
List<String> moveKeyTo(List<String> keys, int index, int target) {
  final next = List<String>.from(keys);
  if (index < 0 || index >= next.length) return next;
  final clamped = target.clamp(0, next.length - 1);
  final moved = next.removeAt(index);
  next.insert(clamped, moved);
  return next;
}

/// Applies a local order to the server's Up next items while a reorder is
/// in flight. Keys the server no longer lists drop out, and new keys keep
/// their server position at the end.
List<DevQueueItem> applyLocalOrder(List<DevQueueItem> serverOrder, List<String>? localKeys) {
  if (localKeys == null) return serverOrder;
  final byKey = {for (final i in serverOrder) i.key: i};
  final out = <DevQueueItem>[
    for (final k in localKeys)
      if (byKey.containsKey(k)) byKey[k]!,
  ];
  for (final item in serverOrder) {
    if (!localKeys.contains(item.key)) out.add(item);
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// Dates
// ─────────────────────────────────────────────────────────────────────────────

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// A day as the queue writes it: "today", a weekday name within 6 days
/// either side of today, otherwise "Nov 14".
String formatQueueDay(DateTime when, {DateTime? now}) {
  final local = when.toLocal();
  final today = _day(now ?? DateTime.now());
  final day = _day(local);
  final diff = day.difference(today).inDays;
  if (diff == 0) return 'today';
  if (diff.abs() <= 6) return _weekdays[local.weekday - 1];
  return '${_months[local.month - 1]} ${local.day}';
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

// ─────────────────────────────────────────────────────────────────────────────
// Copy
// ─────────────────────────────────────────────────────────────────────────────

/// [text] ending in a full stop, unless it already ends in punctuation.
String asSentence(String text) {
  final t = text.trim();
  if (t.isEmpty) return t;
  return RegExp(r'[.!?]$').hasMatch(t) ? t : '$t.';
}

/// "Added to your queue: #k.", plus the estimate's line when the request
/// is sized (PHASE_2_5_DESIGN.md 8.2).
String addedToQueueMessage(int position, DevEstimate? estimate) {
  final line = estimate?.line ?? '';
  return 'Added to your queue: #$position.${line.isEmpty ? '' : ' ${asSentence(line)}'}';
}

/// Whether a Now card shows the estimate's line under the tracker: while
/// Building or Checking.
bool showsEstimateLine(DevQueueItem item) =>
    (item.estimate?.line ?? '').isNotEmpty &&
    (item.state == DevItemState.building || item.state == DevItemState.checking);

/// Whether any of [items] waits for one of its pool's developer agents to
/// come free.
bool anyWaitingForAgent(Iterable<DevQueueItem> items) =>
    items.any((i) => i.status.code == DevStatusCode.waitingForSlot);

/// The line under the answer box about the held slot.
String waitingSlotLine(DevWaiting waiting, {DateTime? now}) {
  if (waiting.slotReleased) {
    return 'Your spot went to your next request. Answer and this goes back '
        'to the front of your queue.';
  }
  final deadline = waiting.deadline;
  if (deadline == null) return '';
  return "We're holding your spot until ${formatQueueDay(deadline, now: now)}.";
}

/// The Shipped list's line for a finished item.
String shippedLine(DevQueueItem item, {DateTime? now}) {
  switch (item.state) {
    case DevItemState.live:
      final at = item.stateChangedAt;
      return at == null ? 'Live' : 'Live since ${formatQueueDay(at, now: now)}';
    case DevItemState.declined:
      final reason = item.closureLabel ?? (item.status.detail.isNotEmpty ? item.status.detail : '');
      return reason.isEmpty ? 'Declined' : 'Declined: $reason';
    default:
      return 'Closed';
  }
}

/// Shipped shows live items, and declined or closed ones from the last 30
/// days, newest first. With [groupId], only items filed from that group
/// whose app [isInstalled] there (an item for no app, such as the launcher,
/// always counts): a request from another group means nothing to this one.
List<DevQueueItem> shippedItems(
  Iterable<DevQueueItem> items, {
  DateTime? now,
  String? groupId,
  bool Function(String appId)? isInstalled,
}) {
  final cutoff = (now ?? DateTime.now()).subtract(const Duration(days: 30));
  final list = items.where((i) {
    if (i.managed) return false;
    if (groupId != null && i.groupId != groupId) return false;
    final appId = shippedItemAppId(i);
    if (isInstalled != null && appId.isNotEmpty && !isInstalled(appId)) return false;
    if (i.state == DevItemState.live) return true;
    if (i.state == DevItemState.declined || i.state == DevItemState.closed) {
      final at = i.stateChangedAt;
      return at != null && at.isAfter(cutoff);
    }
    return false;
  }).toList()
    ..sort((a, b) {
      final at = a.stateChangedAt, bt = b.stateChangedAt;
      if (at == null || bt == null) return at == null ? 1 : -1;
      return bt.compareTo(at);
    });
  return list;
}

/// The app [item] changed: the one it shipped in, else the one it was filed
/// against. A new-app request names none until it ships. Matches
/// `itemAppId` in functions/_dev_queue_group_shipped.js.
String shippedItemAppId(DevQueueItem item) {
  if (item.shippedAppId.isNotEmpty) return item.shippedAppId;
  return item.itemType == 'app' ? '' : item.relatedAppId;
}

/// "Asked for by Sam · Live since Tue" for a teammate's shipped request.
String teamShippedLine(TeamShippedItem item, {DateTime? now}) {
  final at = item.liveAt;
  final live = at == null ? 'Live' : 'Live since ${formatQueueDay(at, now: now)}';
  return item.requesterName.isEmpty ? live : 'Asked for by ${item.requesterName} · $live';
}

/// "Notes · Tue" for a bonus change.
String bonusChangeLine(BonusChange change, {DateTime? now}) {
  final parts = [
    if (change.apps.isNotEmpty) change.apps.map((a) => a.name).join(', '),
    if (change.liveAt != null) formatQueueDay(change.liveAt!, now: now),
  ];
  return parts.join(' · ');
}

/// The stage tracker's steps for [item]. Ready to try appears only when the
/// item has a preview or is waiting for an approval.
enum DevStage { building, checking, readyToTry, finalReview, live }

const stageLabels = {
  DevStage.building: 'Building',
  DevStage.checking: 'Checking',
  DevStage.readyToTry: 'Ready to try',
  DevStage.finalReview: 'Final review',
  DevStage.live: 'Live',
};

List<DevStage> stagesFor(DevQueueItem item) => [
      DevStage.building,
      DevStage.checking,
      if (item.previewUrl.isNotEmpty || item.isAwaitingApproval) DevStage.readyToTry,
      DevStage.finalReview,
      DevStage.live,
    ];

/// The step [item] is on. A question waits at the step it was asked from:
/// Checking once there is a preview or a PR in progress, otherwise Building.
DevStage currentStage(DevQueueItem item) {
  switch (item.state) {
    case DevItemState.checking:
      return DevStage.checking;
    case DevItemState.inReview:
    case DevItemState.merged:
      return DevStage.finalReview;
    case DevItemState.live:
      return DevStage.live;
    case DevItemState.awaitingUser:
      if (item.isAwaitingApproval) return DevStage.readyToTry;
      return item.previewUrl.isNotEmpty ? DevStage.checking : DevStage.building;
    default:
      return DevStage.building;
  }
}
