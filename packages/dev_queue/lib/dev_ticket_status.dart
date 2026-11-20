import 'package:bluejay_design/bluejay_design.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';

import 'dev_queue_models.dart';
import 'dev_queue_screen.dart';
import 'dev_queue_service.dart';
import 'dev_queue_widgets.dart';

/// How a development status looks: its icon and design-system tone. The
/// label comes from the server (`devStatus.label`).
class DevStatusStyle {
  final IconData icon;
  final BjTone tone;

  const DevStatusStyle(this.icon, this.tone);
}

/// The one place each [DevStatusCode] gets its tone and icon, so the chip,
/// the pills, the stage tracker and the ticket screens always agree. Codes
/// that need the requester take the accent; work in progress is info; Live
/// is success; finished-without-shipping is neutral.
const Map<DevStatusCode, DevStatusStyle> devStatusStyles = {
  DevStatusCode.upNext: DevStatusStyle(Icons.schedule_rounded, BjTone.info),
  DevStatusCode.waitingForSlot: DevStatusStyle(Icons.hourglass_empty_rounded, BjTone.info),
  DevStatusCode.received: DevStatusStyle(Icons.inbox_outlined, BjTone.info),
  DevStatusCode.building: DevStatusStyle(Icons.construction_rounded, BjTone.info),
  DevStatusCode.checking: DevStatusStyle(Icons.fact_check_outlined, BjTone.info),
  DevStatusCode.waitingOnYou: DevStatusStyle(Icons.help_outline_rounded, BjTone.accent),
  DevStatusCode.readyToTry: DevStatusStyle(Icons.play_circle_outline_rounded, BjTone.accent),
  DevStatusCode.finalReview: DevStatusStyle(Icons.rate_review_outlined, BjTone.info),
  DevStatusCode.live: DevStatusStyle(Icons.check_circle_rounded, BjTone.success),
  DevStatusCode.declined: DevStatusStyle(Icons.block_rounded, BjTone.neutral),
  DevStatusCode.closed: DevStatusStyle(Icons.archive_outlined, BjTone.neutral),
  DevStatusCode.unknown: DevStatusStyle(Icons.radio_button_unchecked_rounded, BjTone.neutral),
};

DevStatusStyle devStatusStyle(DevStatusCode code) => devStatusStyles[code]!;

/// The tone for [code]; see [devStatusStyles].
BjTone devStatusTone(DevStatusCode code) => devStatusStyle(code).tone;

/// The development status on a ticket screen (PHASE_2_DESIGN.md 6.5).
///
/// Everyone who can see the ticket gets the [DevStatusPill] whenever its
/// `devStatus.code` is set, managed groups included. The ticket's owner also
/// gets "Open in your queue" (non-managed items) and, while a question waits
/// on them, the [DevQueueAnswerBox]. That box is where a managed group's
/// submitter answers. Platform work has no owner to ask, so a platform admin
/// ([canAnswer]) gets the answer box on it.
class DevTicketStatus extends StatefulWidget {
  /// The ticket's `devStatus` map.
  final Object? devStatus;

  /// The ticket's `queueItemId`.
  final String? queueItemId;

  /// Whether the signed-in user filed this ticket.
  final bool isOwner;

  /// Whether the signed-in user answers this ticket's questions without
  /// owning it: a platform admin on platform work.
  final bool canAnswer;

  final fire_auth.User? currentUser;
  final DevQueueService? service;

  const DevTicketStatus({
    super.key,
    required this.devStatus,
    required this.queueItemId,
    required this.isOwner,
    this.canAnswer = false,
    this.currentUser,
    this.service,
  });

  @override
  State<DevTicketStatus> createState() => _DevTicketStatusState();
}

class _DevTicketStatusState extends State<DevTicketStatus> {
  Stream<DevQueueItem?>? _item;
  String? _itemKey;

  DevQueueService get _service => widget.service ?? DevQueueService.instance;

  String get _key => (widget.queueItemId ?? '').trim();

  bool get _ownerExtras =>
      (widget.isOwner || widget.canAnswer) && _key.isNotEmpty && widget.currentUser != null;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant DevTicketStatus oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (!_ownerExtras) {
      _item = null;
      _itemKey = null;
      return;
    }
    if (_itemKey != _key) {
      _itemKey = _key;
      // The owner and platform admins can read the item; an unreadable one
      // shows the pill alone.
      _item = _service.watchItem(_key).handleError((Object _) {});
    }
  }

  void _openQueue() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DevQueueScreen(
        currentUser: widget.currentUser,
        focusItemKey: _key,
        service: widget.service,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final status = DevStatus.fromMap(widget.devStatus);
    if (status == null) return const SizedBox.shrink();
    final pill = DevStatusPill(status);
    if (!_ownerExtras) return pill;
    return StreamBuilder<DevQueueItem?>(
      stream: _item,
      builder: (context, snap) {
        final item = snap.data;
        if (item == null) return pill;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            pill,
            if (widget.isOwner && !item.managed)
              TextButton.icon(
                onPressed: _openQueue,
                icon: const Icon(Icons.view_agenda_outlined, size: 18),
                label: const Text('Open in your queue'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              ),
            if (status.code == DevStatusCode.waitingOnYou && item.isAwaitingAnswer)
              Padding(
                padding: const EdgeInsets.only(top: BjSpace.sm),
                child: DevQueueAnswerBox(
                  itemKey: item.key,
                  question: item.waiting?.question.isNotEmpty == true ? item.waiting!.question : status.detail,
                  waiting: item.waiting,
                  service: widget.service,
                ),
              ),
          ],
        );
      },
    );
  }
}
