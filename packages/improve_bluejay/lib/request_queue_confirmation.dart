import 'dart:async';

import 'package:bluejay_design/bluejay_design.dart';
import 'package:dev_queue/dev_queue.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';

// "Added to your queue: #k." after a request is filed (PHASE_2_DESIGN.md
// 6.3). The submit sheet hands back the new ticket's id; this waits for the
// queue item intake creates for it and confirms with its position.

/// How long to wait for intake to create the queue item.
const requestQueueConfirmationTimeout = Duration(seconds: 10);

/// What the confirmation says once the item is (or isn't) in the queue.
class RequestConfirmation {
  final String message;

  /// The queue item to open from "View", or null when the snackbar has no
  /// "View" (a managed group, or no item in time).
  final String? itemKey;

  const RequestConfirmation(this.message, {this.itemKey});
}

/// The confirmation for [itemKey] given the owner's active items, or null
/// while the item hasn't appeared yet.
RequestConfirmation? requestConfirmationFor(
  List<DevQueueItem> active,
  String itemKey, {
  required String fallbackMessage,
}) {
  final matches = active.where((i) => i.key == itemKey);
  if (matches.isEmpty) return null;
  final item = matches.first;
  if (item.managed) return RequestConfirmation(fallbackMessage);
  final position = queuePositions(visibleQueue(active))[itemKey];
  if (position == null) return RequestConfirmation(fallbackMessage);
  return RequestConfirmation(addedToQueueMessage(position, item.estimate), itemKey: itemKey);
}

/// Waits up to [timeout] for [itemKey] to appear among [uid]'s active
/// items, then returns the confirmation to show.
Future<RequestConfirmation> resolveRequestConfirmation({
  required DevQueueService service,
  required String uid,
  required String itemKey,
  required String fallbackMessage,
  Duration timeout = requestQueueConfirmationTimeout,
}) async {
  final completer = Completer<RequestConfirmation>();
  late final StreamSubscription<List<DevQueueItem>> sub;
  final timer = Timer(timeout, () {
    if (!completer.isCompleted) completer.complete(RequestConfirmation(fallbackMessage));
  });
  sub = service.watchActive(uid).listen(
    (items) {
      final found = requestConfirmationFor(items, itemKey, fallbackMessage: fallbackMessage);
      if (found != null && !completer.isCompleted) completer.complete(found);
    },
    onError: (Object _) {
      if (!completer.isCompleted) completer.complete(RequestConfirmation(fallbackMessage));
    },
  );
  final result = await completer.future;
  timer.cancel();
  await sub.cancel();
  return result;
}

/// Shows the success snackbar used across Improve Apps: the design
/// system's floating snack with a green check, plus an optional [action].
///
/// Takes the [messenger] rather than a context because it's shown after the
/// submit sheet (and sometimes the screen that opened it) has gone.
void showRequestSuccessSnackBar(
  ScaffoldMessengerState messenger,
  String message, {
  SnackBarAction? action,
}) {
  // The messenger's own context sits under MaterialApp's theme and media
  // query, so it can style the snack once the caller's context is gone.
  final context = messenger.context;
  final width = MediaQuery.sizeOf(context).width;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        width: width > 560 ? 480 : null,
        content: Row(children: [
          Icon(
            Icons.check_circle_rounded,
            size: 20,
            color: context.bj.tone(BjTone.success).border,
          ),
          const SizedBox(width: BjSpace.md),
          Expanded(child: Text(message)),
        ]),
        action: action,
      ),
    );
}

/// Confirms a filed request: "Added to your queue: #k." and the estimate
/// with "View", or [fallbackMessage] for a managed group or a slow intake.
Future<void> confirmQueuedRequest(
  BuildContext context, {
  required String itemType,
  required String ticketId,
  required String fallbackMessage,
  required fire_auth.User? currentUser,
  required DevQueueNewRequest onNewRequest,
  DevQueueService? service,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  final uid = currentUser?.uid;
  if (uid == null) {
    showRequestSuccessSnackBar(messenger, fallbackMessage);
    return;
  }
  final queue = service ?? DevQueueService.instance;
  final result = await resolveRequestConfirmation(
    service: queue,
    uid: uid,
    itemKey: devQueueItemKey(itemType, ticketId),
    fallbackMessage: fallbackMessage,
  );
  final key = result.itemKey;
  showRequestSuccessSnackBar(
    messenger,
    result.message,
    action: key == null
        ? null
        : SnackBarAction(
            label: 'View',
            onPressed: () => navigator.push(MaterialPageRoute(
              builder: (_) => DevQueueScreen(
                currentUser: currentUser,
                onNewRequest: onNewRequest,
                focusItemKey: key,
                service: service,
              ),
            )),
          ),
  );
}
