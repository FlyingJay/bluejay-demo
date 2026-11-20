import 'package:flutter/widgets.dart';

/// Makes back close an in-app sub-view that lives in widget state (a
/// selected item's detail pane, an opened folder, a wizard step) instead of
/// leaving the screen.
///
/// Back here means the browser's back button, the Android back gesture and
/// an app bar's back arrow: all of them pop the current route, and a route
/// pushed from the launcher is the whole app. While [active] is true this
/// widget holds that pop and calls [onBack], which should close the
/// sub-view (typically `setState(() => _selected = null)`). Once [active] is
/// false, back leaves the screen as usual.
///
/// Steps nest: when several are active on one screen, only the innermost
/// active one handles a back press, so each press closes one level.
///
/// Sub-views opened with `Navigator.push` already close on back and don't
/// need this.
class BjBackStep extends StatefulWidget {
  const BjBackStep({
    super.key,
    required this.active,
    required this.onBack,
    required this.child,
  });

  /// Whether the sub-view is open, so back should close it.
  final bool active;

  /// Closes the sub-view.
  final VoidCallback onBack;

  final Widget child;

  @override
  State<BjBackStep> createState() => _BjBackStepState();
}

class _BjBackStepState extends State<BjBackStep> {
  _BjBackStepState? _parent;
  final Set<_BjBackStepState> _children = {};

  bool get _activeBelow =>
      _children.any((c) => c.widget.active || c._activeBelow);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final parent =
        context.dependOnInheritedWidgetOfExactType<_BjBackStepScope>()?.state;
    if (parent != _parent) {
      _parent?._children.remove(this);
      _parent = parent?.._children.add(this);
    }
  }

  @override
  void dispose() {
    _parent?._children.remove(this);
    super.dispose();
  }

  void _handlePop(bool didPop, Object? _) {
    if (didPop || !widget.active || _activeBelow) return;
    widget.onBack();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: !widget.active,
      onPopInvokedWithResult: _handlePop,
      child: _BjBackStepScope(state: this, child: widget.child),
    );
  }
}

class _BjBackStepScope extends InheritedWidget {
  const _BjBackStepScope({required this.state, required super.child});

  final _BjBackStepState state;

  @override
  bool updateShouldNotify(_BjBackStepScope oldWidget) =>
      state != oldWidget.state;
}
