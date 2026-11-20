import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_services/active_group_service.dart';
import 'package:shared_services/bluejay_firestore.dart';
import 'package:shared_services/cloud_functions.dart';

/// Sends notifications to other members of the active group, attributed to
/// the calling app.
///
/// Notifications are created **server-side** by the `notificationsSend`
/// callable (`functions/_notification_send.js`); clients can't write the
/// `notifications` collection directly (rules plan T8). The callable checks
/// that the sender holds this app's entitlement in the group, notifies only
/// recipients who belong to that group (others are skipped; a request with
/// none is refused), validates the fields, rate-limits the sender, and
/// stamps `senderId`, `isRead: false` and `createdAt`.
/// Recipients may then only flip `isRead` on (or delete) their own
/// notifications.
///
/// **Usage**
///
/// Declare one instance per file (or per class) that creates notifications:
///
/// ```dart
/// import 'package:shared_services/notification_service.dart';
/// import 'constants.dart'; // defines APP_ID
///
/// final _notifications = NotificationService(appId: APP_ID);
/// ```
///
/// Then call [add] (one recipient) or [addForRecipients] (several, one
/// request):
///
/// ```dart
/// await _notifications.add({
///   'recipientId': recipientId,
///   'title': 'You have a new message',
///   'appName': 'Chats',        // human-readable label for the UI
///   'context': {'conversationId': id},
/// });
/// ```
///
/// Accepted fields: `recipientId` ([add] only), `title` (required), `body`,
/// `appName`, `context` (a small map of plain data), `actionUrl` (an
/// https://bluejay.gg link or a bluejay:// deep link), `informational`.
/// `isRead`, `createdAt`,
/// `groupId` and `appId` are ignored if passed — the server sets the first
/// two, and the group and app come from [ActiveGroupService.activeGroupId]
/// (or the `groupId` argument) and the constructor's `appId`.
///
/// **Sending without waiting**
///
/// A notification is a side effect of what the user just did (sent a message,
/// posted a comment), and the callable takes a server round trip. When the
/// UI shouldn't wait for it, use [addInBackground] /
/// [addForRecipientsInBackground], or [sendInBackground] when building the
/// notification takes async work of its own (a sender's display name, say).
/// These return at once and log a failure instead of throwing it:
///
/// ```dart
/// await messages.add(message);            // the only thing the UI waits on
/// _notifications.addForRecipientsInBackground(recipientIds, {...});
/// ```
///
/// **Links in SMS and email**
///
/// Without an `actionUrl`, the SMS, email and web push for a notification
/// link to the notification itself, which opens wherever a tap on it in the
/// notifications screen would (your app's NotificationRouter handler, see
/// notification_deep_link_handler.dart). Most senders need nothing more:
/// put the ids your handler reads in `context`. Set `'informational': true`
/// on a notification that needs nothing from the recipient (a game result,
/// a "for your information") to send it without a link.
///
/// **Coalescing repeated notifications**
///
/// Pass [add]'s `coalesceKey` when a notification is one event on an ongoing
/// thread — a turn in a game, a message in a conversation, a comment on a
/// document — and rapid activity on that thread would otherwise notify the
/// same person over and over:
///
/// ```dart
/// await _notifications.add({
///   'recipientId': opponentId,
///   'title': '$me tapped! Your turn.',
///   'body': "It's your turn in Tap War!",
///   …
/// }, coalesceKey: 'game:$gameId');
/// ```
///
/// The first notification of a burst is delivered immediately and in full;
/// the ones that follow within [defaultCoalesceWindow] (or an explicit
/// `coalesceWindow`) are folded into it — same single entry in the
/// recipient's list, updated to the newest title/body with a `(+N more)`
/// suffix, and no second push/SMS/email. The window is never extended by a
/// fold, so sustained activity still notifies once per window and the first
/// event after the window closes notifies immediately: nothing is ever
/// delayed, and a notification arriving after any reasonable gap is
/// unaffected. A notification the recipient has already opened never absorbs
/// a new one.
///
/// Enforcement lives in the `onNotificationCreated` Cloud Function
/// (`functions/_notification_coalescing.js`), which is also where the
/// defaults and clamps are defined — these fields only request it.
class NotificationService {
  /// The app identifier registered in `apps/{appId}`.
  ///
  /// This value is written to every notification document as the `appId`
  /// field, enabling reliable per-app badge-count lookups regardless of the
  /// human-readable `appName`. The sender must hold this app's entitlement
  /// in the notification's group.
  final String appId;

  final FirebaseFunctions? _functionsOverride;

  NotificationService({required this.appId, FirebaseFunctions? functions})
      : _functionsOverride = functions;

  /// The callable that creates notifications (functions/notifications.js).
  static const String sendCallableName = 'notificationsSend';

  /// The notification fields a caller may set; everything else in the data
  /// map is dropped (see [requestPayload]).
  static const Set<String> senderFields = {
    'title',
    'body',
    'appName',
    'context',
    'actionUrl',
    'informational',
  };

  /// Fields callers historically wrote themselves that the server now owns.
  static const Set<String> _serverOwnedFields = {
    'recipientId',
    'isRead',
    'createdAt',
    'groupId',
    'appId',
    'createdBy',
    'senderId',
  };

  FirebaseFunctions get _functions =>
      _functionsOverride ?? BluejayFunctions.instance;

  CollectionReference<Map<String, dynamic>> get _ref =>
      BluejayFirestore.forApp(appId).collection('notifications');

  String? get _activeGroupId => ActiveGroupService.instance.activeGroupId;

  /// Sends one notification to `data['recipientId']` and returns its
  /// [DocumentReference].
  ///
  /// The notification is scoped to [groupId] when given (e.g. a request
  /// that belongs to another group the sender administers), otherwise to the
  /// active group. If there is no group:
  /// - In debug mode an [AssertionError] is thrown immediately so the missing
  ///   group context is surfaced during development.
  /// - In release mode a structured warning is logged and the method returns
  ///   `null` without sending anything (fail-safe: suppress the notification
  ///   rather than leak cross-tenant data).
  ///
  /// Throws a [FirebaseFunctionsException] if the server refuses (e.g.
  /// `permission-denied` when the recipient isn't in the group,
  /// `resource-exhausted` when the sender is rate-limited).
  ///
  /// Pass [coalesceKey] (and optionally [coalesceWindow]) to have bursts on
  /// the same thread fold into one delivered notification — see the class
  /// doc above. Omitting it keeps the default "always deliver" behaviour.
  Future<DocumentReference<Map<String, dynamic>>?> add(
    Map<String, dynamic> data, {
    String? groupId,
    String? coalesceKey,
    Duration? coalesceWindow,
  }) async {
    final recipientId = data['recipientId'];
    if (recipientId is! String || recipientId.isEmpty) {
      throw ArgumentError.value(
          recipientId, 'data.recipientId', 'is required');
    }
    final refs = await addForRecipients(
      [recipientId],
      data,
      groupId: groupId,
      coalesceKey: coalesceKey,
      coalesceWindow: coalesceWindow,
    );
    return refs == null || refs.isEmpty ? null : refs.first;
  }

  /// Sends the same notification to each of [recipientIds] in one request
  /// (at most 100), and returns the [DocumentReference]s created, in order
  /// (duplicates removed; recipients outside the group are skipped). Returns
  /// `null` without sending when there is no group (see [add]) and `[]` when
  /// [recipientIds] is empty.
  Future<List<DocumentReference<Map<String, dynamic>>>?> addForRecipients(
    Iterable<String> recipientIds,
    Map<String, dynamic> data, {
    String? groupId,
    String? coalesceKey,
    Duration? coalesceWindow,
  }) async {
    final scope = (groupId ?? _activeGroupId)?.trim();
    if (scope == null || scope.isEmpty) {
      assert(
        false,
        'NotificationService called with no groupId and no active group. '
        'Ensure ActiveGroupService has resolved before sending notifications, '
        'or pass the groupId the notification belongs to.',
      );
      debugPrint(
        '[NotificationService] WARNING: notification suppressed — no '
        'groupId for appId "$appId".',
      );
      return null;
    }
    final recipients = recipientIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    if (recipients.isEmpty) return const [];

    final result = await _functions.httpsCallable(sendCallableName).call(
          requestPayload(
            data,
            groupId: scope,
            appId: appId,
            recipientIds: recipients,
            coalesceKey: coalesceKey,
            coalesceWindow: coalesceWindow,
          ),
        );
    final ids = (result.data is Map ? (result.data as Map)['ids'] : null);
    if (ids is! List) return const [];
    return ids.whereType<String>().map(_ref.doc).toList();
  }

  /// [add] without waiting: returns at once, and a failure (a refusal, a
  /// rate limit, no network) is logged rather than thrown. See
  /// [sendInBackground].
  Future<void> addInBackground(
    Map<String, dynamic> data, {
    String? groupId,
    String? coalesceKey,
    Duration? coalesceWindow,
  }) {
    return sendInBackground(
      () => add(
        data,
        groupId: groupId,
        coalesceKey: coalesceKey,
        coalesceWindow: coalesceWindow,
      ),
      label: '$appId notification',
    );
  }

  /// [addForRecipients] without waiting: returns at once, and a failure is
  /// logged rather than thrown. See [sendInBackground].
  Future<void> addForRecipientsInBackground(
    Iterable<String> recipientIds,
    Map<String, dynamic> data, {
    String? groupId,
    String? coalesceKey,
    Duration? coalesceWindow,
  }) {
    // Copied now, so a caller that reuses its list after returning can't
    // change who is notified.
    final recipients = recipientIds.toList();
    return sendInBackground(
      () => addForRecipients(
        recipients,
        data,
        groupId: groupId,
        coalesceKey: coalesceKey,
        coalesceWindow: coalesceWindow,
      ),
      label: '$appId notification to $recipients',
    );
  }

  /// Runs [send] (typically building a notification and calling [add] or
  /// [addForRecipients]) without the caller waiting for it. Any error it
  /// throws is logged with [label] and swallowed, so it never surfaces as an
  /// unhandled async error. The one pattern for "notify, but don't hold up
  /// the UI"; the returned future completes when [send] has finished
  /// (successfully or not), for tests.
  static Future<void> sendInBackground(
    Future<void> Function() send, {
    String label = 'notification',
  }) {
    final done = Future<void>.sync(send).then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        debugPrint('[NotificationService] Failed to send $label: $error');
      },
    );
    unawaited(done);
    return done;
  }

  /// The `notificationsSend` request for [data]. Pure and separated from
  /// [addForRecipients] so the field mapping is testable without Firebase.
  ///
  /// Keeps only [senderFields] (server-owned fields such as `isRead` and
  /// `createdAt` are dropped; anything else trips an assert in debug, since
  /// the server would reject it).
  @visibleForTesting
  static Map<String, dynamic> requestPayload(
    Map<String, dynamic> data, {
    required String groupId,
    required String appId,
    required List<String> recipientIds,
    String? coalesceKey,
    Duration? coalesceWindow,
  }) {
    final unknown = data.keys
        .where((k) => !senderFields.contains(k) && !_serverOwnedFields.contains(k))
        .toList();
    assert(unknown.isEmpty,
        'NotificationService: unsupported notification field(s) $unknown');
    return {
      for (final entry in data.entries)
        if (senderFields.contains(entry.key) && entry.value != null)
          entry.key: entry.value,
      ...coalescingFields(key: coalesceKey, window: coalesceWindow),
      'groupId': groupId,
      'appId': appId,
      'recipientIds': recipientIds,
    };
  }

  /// Default suppression window when [add] is given a `coalesceKey` without a
  /// `coalesceWindow`.
  ///
  /// Kept in sync with `DEFAULT_WINDOW_SECONDS` in
  /// `functions/_notification_coalescing.js`, which is what actually applies
  /// it — this value only exists so callers can reason about, and reuse, the
  /// same number.
  static const Duration defaultCoalesceWindow = Duration(minutes: 5);

  /// Hard ceiling on a requested window, mirroring the Cloud Function's own
  /// clamp so a caller can never ask to silence a thread for longer than the
  /// backend would honour anyway.
  static const Duration maxCoalesceWindow = Duration(hours: 1);

  /// The coalescing fields for a notification document, or `{}` when the
  /// notification does not opt in.
  ///
  /// Pure, and separated from [add] so the field names, the blank-key
  /// fallback, and the clamp are all testable without Firestore.
  @visibleForTesting
  static Map<String, dynamic> coalescingFields({
    String? key,
    Duration? window,
  }) {
    final trimmedKey = key?.trim() ?? '';
    // A blank key means "no coalescing": deliver every notification, which is
    // the safe behaviour to fall back to.
    if (trimmedKey.isEmpty) return const {};
    final requested = window ?? defaultCoalesceWindow;
    final seconds = requested.inSeconds.clamp(1, maxCoalesceWindow.inSeconds);
    return {
      'coalesceKey': trimmedKey,
      'coalesceWindowSeconds': seconds,
    };
  }
}
