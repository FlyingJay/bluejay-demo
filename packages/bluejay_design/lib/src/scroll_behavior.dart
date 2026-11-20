import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// How every scrollable in Bluejay responds to a mouse, set once on the
/// app's `MaterialApp(scrollBehavior: const BjScrollBehavior())`.
///
/// Flutter's defaults are written for touch: a mouse can't drag a list, and
/// a mouse wheel only moves a horizontal list while Shift is held. On the
/// web that leaves chip rows, carousels and pagers stuck for desktop users.
/// This behavior fixes that for every horizontal scrollable at once, so no
/// screen needs its own workaround:
///
/// * Dragging with the mouse scrolls it, with the same fling as a swipe.
/// * The mouse wheel scrolls it sideways, until it reaches an end; then the
///   wheel goes back to scrolling the page around it. Pagers (`PageView`)
///   are left to their own wheel handling.
///
/// Vertical scrollables keep the browser's behavior: the wheel scrolls
/// them, and a mouse drag selects text rather than moving the page.
class BjScrollBehavior extends MaterialScrollBehavior {
  const BjScrollBehavior();

  // Flutter calls both hooks for every scrollable, the overscroll one
  // first. A screen can switch either off (PageView turns off scrollbars),
  // so the wrapper goes in at the first one still on, and only once.

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) =>
      _wrap(super.buildOverscrollIndicator(context, child, details), details);

  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) {
    final bar = super.buildScrollbar(context, child, details);
    // Already wrapped by the overscroll hook, unless that was switched off.
    return child is _MouseHorizontalScroll ? bar : _wrap(bar, details);
  }

  static Widget _wrap(Widget child, ScrollableDetails details) {
    final controller = details.controller;
    if (axisDirectionToAxis(details.direction) != Axis.horizontal || controller == null) {
      return child;
    }
    return _MouseHorizontalScroll(controller: controller, child: child);
  }
}

/// Wraps a horizontal [Scrollable]'s contents (Flutter builds the scrollbar
/// around them), moving it through [controller].
class _MouseHorizontalScroll extends StatefulWidget {
  final ScrollController controller;
  final Widget child;
  const _MouseHorizontalScroll({required this.controller, required this.child});

  @override
  State<_MouseHorizontalScroll> createState() => _MouseHorizontalScrollState();
}

class _MouseHorizontalScrollState extends State<_MouseHorizontalScroll> {
  Drag? _drag;

  /// The position this list scrolls, when it has exactly one.
  ScrollPosition? get _position {
    final controller = widget.controller;
    return controller.positions.length == 1 ? controller.position : null;
  }

  static bool _isPager(ScrollPhysics? physics) {
    for (var p = physics; p != null; p = p.parent) {
      if (p is PageScrollPhysics) return true;
    }
    return false;
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || event.kind != PointerDeviceKind.mouse) return;
    // A sideways wheel or Shift is already handled by the scrollable.
    if (event.scrollDelta.dx != 0 || event.scrollDelta.dy == 0) return;
    if (HardwareKeyboard.instance.isShiftPressed) return;
    final position = _position;
    if (position == null || !position.hasContentDimensions || _isPager(position.physics)) return;
    final delta = event.scrollDelta.dy;
    final target =
        (position.pixels + delta).clamp(position.minScrollExtent, position.maxScrollExtent);
    // At an end, leave the wheel to whatever scrolls around this.
    if (target == position.pixels) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      _position?.pointerScroll(delta);
    });
  }

  void _onDragStart(DragStartDetails details) {
    final position = _position;
    if (position == null) return;
    _drag = position.drag(details, () => _drag = null);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _drag?.update(details);
  }

  void _onDragEnd(DragEndDetails details) {
    _drag?.end(details);
  }

  void _onDragCancel() {
    _drag?.cancel();
  }

  @override
  void dispose() {
    _drag?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget child = Listener(onPointerSignal: _onPointerSignal, child: widget.child);
    // Where a screen already lets the mouse drag (its own scroll
    // configuration), the scrollable handles it.
    if (!ScrollConfiguration.of(context).dragDevices.contains(PointerDeviceKind.mouse)) {
      child = RawGestureDetector(
        gestures: {
          HorizontalDragGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<HorizontalDragGestureRecognizer>(
            () => HorizontalDragGestureRecognizer(
              supportedDevices: const {PointerDeviceKind.mouse},
            ),
            (recognizer) => recognizer
              // Count the drag from where the button went down, so a quick
              // flick of a pager isn't lost to the drag threshold.
              ..dragStartBehavior = DragStartBehavior.down
              ..onStart = _onDragStart
              ..onUpdate = _onDragUpdate
              ..onEnd = _onDragEnd
              ..onCancel = _onDragCancel,
          ),
        },
        behavior: HitTestBehavior.opaque,
        child: child,
      );
    }
    return child;
  }
}
