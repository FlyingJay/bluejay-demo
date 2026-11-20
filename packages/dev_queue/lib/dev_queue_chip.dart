import 'dart:async';

import 'package:bluejay_design/bluejay_design.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';
import 'package:shared_services/guest_status.dart';

import 'dev_queue_logic.dart';
import 'dev_queue_models.dart';
import 'dev_queue_screen.dart';
import 'dev_queue_service.dart';
import 'dev_queue_widgets.dart';

/// The queue chip in the launcher app bar (PHASE_2_DESIGN.md 6.1): the
/// person's primary item and how many more are waiting. Renders nothing for
/// guests and in a managed group.
class DevQueueChip extends StatefulWidget {
  final fire_auth.User? currentUser;

  /// The active group's `devQueue.mode`.
  final String? groupDevQueueMode;

  final DevQueueService? service;

  /// Replaces opening [DevQueueScreen], for tests.
  final VoidCallback? onOpen;

  const DevQueueChip({
    super.key,
    required this.currentUser,
    required this.groupDevQueueMode,
    this.service,
    this.onOpen,
  });

  @override
  State<DevQueueChip> createState() => _DevQueueChipState();
}

class _DevQueueChipState extends State<DevQueueChip> {
  StreamSubscription<List<DevQueueItem>>? _itemsSub;
  List<DevQueueItem>? _queue;
  String? _uid;

  DevQueueService get _service => widget.service ?? DevQueueService.instance;

  bool get _eligibleUser {
    final user = widget.currentUser;
    return user != null && !_isGuest;
  }

  /// A guest (visitor or client) in the active group, or a member whose
  /// status is still loading: no queue chip.
  bool get _isGuest {
    final user = widget.currentUser;
    if (user == null) return false;
    if (user.isAnonymous) return true;
    return GuestStatusService.instance.current.value?.hidesMemberChrome ?? false;
  }

  void _onGuestStatusChanged() {
    if (!mounted) return;
    _syncItems();
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    GuestStatusService.instance.current.addListener(_onGuestStatusChanged);
    _syncItems();
  }

  @override
  void didUpdateWidget(covariant DevQueueChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncItems();
  }

  /// Listens to the person's items only while the chip can show.
  void _syncItems() {
    final uid = _eligibleUser && widget.groupDevQueueMode != 'managed' ? widget.currentUser!.uid : null;
    if (uid == _uid) return;
    _uid = uid;
    _itemsSub?.cancel();
    _itemsSub = null;
    _queue = null;
    if (uid == null) return;
    _itemsSub = _service.watchActive(uid).listen(
      (items) {
        if (mounted) setState(() => _queue = visibleQueue(items));
      },
      onError: (Object _) {
        if (mounted) setState(() => _queue = null);
      },
    );
  }

  @override
  void dispose() {
    GuestStatusService.instance.current.removeListener(_onGuestStatusChanged);
    _itemsSub?.cancel();
    super.dispose();
  }

  void _open() {
    final onOpen = widget.onOpen;
    if (onOpen != null) {
      onOpen();
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DevQueueScreen(currentUser: widget.currentUser, service: widget.service),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final show = shouldShowDevQueueChip(
      signedIn: widget.currentUser != null,
      isGuest: _isGuest,
      groupDevQueueMode: widget.groupDevQueueMode,
    );
    final queue = _queue;
    if (!show || queue == null) return const SizedBox.shrink();
    final wide = MediaQuery.sizeOf(context).width >= devQueueChipWideBreakpoint;
    final copy = chipCopy(queue, wide: wide);
    return DevQueueChipView(copy: copy, onTap: _open);
  }
}

/// The chip's look, apart from its data.
class DevQueueChipView extends StatelessWidget {
  final DevQueueChipCopy copy;
  final VoidCallback onTap;

  const DevQueueChipView({super.key, required this.copy, required this.onTap});

  /// The chip's tone: accent when something needs the person, neutral
  /// when the queue is empty, info while work is moving.
  static BjTone toneFor(DevQueueChipCopy copy) =>
      copy.needsYou ? BjTone.accent : (copy.empty ? BjTone.neutral : BjTone.info);

  @override
  Widget build(BuildContext context) {
    final tone = context.bj.tone(toneFor(copy));
    final color = tone.foreground;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: BjSpace.xs),
      child: Semantics(
        button: true,
        label: copy.semanticsLabel,
        excludeSemantics: true,
        child: Tooltip(
          message: 'Your queue',
          child: AnimatedContainer(
            duration: BjMotion.medium,
            curve: BjMotion.curve,
            decoration: ShapeDecoration(
              color: copy.empty ? BjNeutral.surface : tone.background,
              shape: StadiumBorder(side: BorderSide(color: tone.border)),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: onTap,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 40, minWidth: 48),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: BjSpace.md),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (copy.needsYou)
                          const DevQueueAttentionDot()
                        else
                          Icon(Icons.view_agenda_outlined, size: 16, color: color),
                        const SizedBox(width: BjSpace.xs + 2),
                        // App bar actions get unbounded width, so cap the label.
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 340),
                          child: Text(
                            copy.text,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: color,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
