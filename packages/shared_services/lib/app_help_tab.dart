/// Lets a screen inside a launched app hide the launcher's in-app edge tabs
/// (improve_bluejay's `AppHelpShell`, which `AppRouter.getScreen` puts around
/// every routed app) while that screen is showing: the help tab, and the
/// chat tab just above it that opens Chat.
///
/// The tabs sit on the right edge of every app. On a screen where any tap or
/// swipe counts, such as a game in progress, they get in the way, so the app
/// wraps that screen in [HideAppHelpTab]:
///
/// ```dart
/// HideAppHelpTab(child: GameBoard(...))
/// ```
///
/// A head-to-head game, where the players want to talk while they play,
/// keeps the chat tab and hides only the help tab:
///
/// ```dart
/// HideAppHelpTab(keepChat: true, child: GameBoard(...))
/// ```
///
/// The tabs come back as soon as the last [HideAppHelpTab] under the shell
/// is removed or set to `hide: false`. Outside an `AppHelpShell` (tests, a
/// standalone app build) the widget does nothing.
///
/// A screen an app pushes as its own route sits above the shell, so it gets
/// neither tab. A head-to-head game board pushed that way wraps itself in
/// [ShowChatTab] to get the chat tab back:
///
/// ```dart
/// Navigator.of(context).push(MaterialPageRoute(
///   builder: (_) => ShowChatTab(child: GameScreen(...)),
/// ));
/// ```
///
/// [AppEdgeTabs] lays the tabs out for both the shell and [ShowChatTab].
///
/// This lives in shared_services so an app can use it without depending on
/// improve_bluejay.
library;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'capture_mode.dart';

/// Counts the [HideAppHelpTab] widgets currently asking the tabs to hide.
/// The shell owns one and listens to it.
class AppHelpTabController extends ChangeNotifier {
  int _hiders = 0;

  /// The hiders that hide the chat tab too (not `keepChat`).
  int _chatHiders = 0;
  bool _notifyScheduled = false;
  bool _disposed = false;

  /// Whether any screen under the shell is asking for the help tab to be
  /// hidden.
  bool get hidden => _hiders > 0;

  /// Whether any screen under the shell is asking for the chat tab to be
  /// hidden, i.e. hides the tabs without `keepChat`.
  bool get chatHidden => _chatHiders > 0;

  void _add({required bool keepChat}) {
    final before = (hidden, chatHidden);
    _hiders++;
    if (!keepChat) _chatHiders++;
    if (before != (hidden, chatHidden)) _notify();
  }

  void _remove({required bool keepChat}) {
    if (_hiders == 0) return;
    final before = (hidden, chatHidden);
    _hiders--;
    if (!keepChat && _chatHiders > 0) _chatHiders--;
    if (before != (hidden, chatHidden)) _notify();
  }

  /// Hiders register while the tree is building or being torn down, and the
  /// shell is an ancestor that can't be rebuilt mid-build, so a change
  /// during a frame is passed on after it.
  void _notify() {
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase != SchedulerPhase.persistentCallbacks &&
        phase != SchedulerPhase.midFrameMicrotasks) {
      notifyListeners();
      return;
    }
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      if (!_disposed) notifyListeners();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Provides an [AppHelpTabController] to the app below the help tab's shell.
class AppHelpTabScope extends InheritedWidget {
  final AppHelpTabController controller;

  const AppHelpTabScope({
    super.key,
    required this.controller,
    required super.child,
  });

  /// The nearest shell's controller, or null outside one.
  static AppHelpTabController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppHelpTabScope>()?.controller;

  @override
  bool updateShouldNotify(AppHelpTabScope oldWidget) =>
      controller != oldWidget.controller;
}

/// Hides the in-app edge tabs while this widget is in the tree and [hide] is
/// true. See the library comment.
class HideAppHelpTab extends StatefulWidget {
  /// Whether to hide the tabs. Lets a screen switch it without rebuilding its
  /// subtree in a different shape.
  final bool hide;

  /// Keeps the chat tab showing and hides only the help tab: for head-to-head
  /// games, so the players can message each other mid-game.
  final bool keepChat;

  final Widget child;

  const HideAppHelpTab({
    super.key,
    this.hide = true,
    this.keepChat = false,
    required this.child,
  });

  @override
  State<HideAppHelpTab> createState() => _HideAppHelpTabState();
}

class _HideAppHelpTabState extends State<HideAppHelpTab> {
  /// The controller this widget is currently counted in, if any, and the
  /// keepChat it was counted with.
  AppHelpTabController? _registered;
  bool _registeredKeepChat = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(HideAppHelpTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final target = widget.hide ? AppHelpTabScope.maybeOf(context) : null;
    final keepChat = widget.keepChat;
    if (identical(target, _registered) &&
        (target == null || keepChat == _registeredKeepChat)) {
      return;
    }
    _registered?._remove(keepChat: _registeredKeepChat);
    _registered = target?.._add(keepChat: keepChat);
    _registeredKeepChat = keepChat;
  }

  @override
  void dispose() {
    _registered?._remove(keepChat: _registeredKeepChat);
    _registered = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Draws the launcher's edge tabs over [child]: [help] on the right edge a
/// little below centre, clear of app bars and of the bottom-right FAB slot
/// most apps use, and [chat] just above it, each staying in its spot
/// whether or not the other shows. Both hide while the on-screen keyboard is
/// up, during a screenshot capture of a demo account, and while a
/// [HideAppHelpTab] under [controller] asks (the chat tab stays for one that
/// passes `keepChat`).
class AppEdgeTabs extends StatelessWidget {
  final AppHelpTabController controller;

  /// The help tab, or null for none.
  final Widget? help;

  /// The chat tab, or null for none.
  final Widget? chat;

  final Widget child;

  const AppEdgeTabs({
    super.key,
    required this.controller,
    this.help,
    this.chat,
    required this.child,
  });

  /// Every edge tab's size, and the gap between the chat and help tabs.
  static const double tabWidth = 42;
  static const double tabHeight = 62;
  static const double gap = 8;

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final help = this.help;
    final chat = this.chat;
    return Stack(
      fit: StackFit.expand,
      children: [
        AppHelpTabScope(controller: controller, child: child),
        if ((help != null || chat != null) && !keyboardOpen)
          ListenableBuilder(
            listenable: Listenable.merge(
                [CaptureMode.instance.hidesChrome, controller]),
            builder: (context, _) {
              if (CaptureMode.instance.hidesChrome.value) {
                return const SizedBox.shrink();
              }
              final showHelp = help != null && !controller.hidden;
              final showChat = chat != null && !controller.chatHidden;
              if (!showHelp && !showChat) return const SizedBox.shrink();
              return SafeArea(
                child: LayoutBuilder(builder: (context, box) {
                  // One column, so the tabs can never overlap. The help
                  // tab's spot stays fixed; the chat tab sits above it, or
                  // in the same place when the help tab isn't showing.
                  final helpTop = (box.maxHeight - tabHeight) * 0.65;
                  final top = (helpTop - (tabHeight + gap))
                      .clamp(0.0, double.infinity);
                  return Stack(
                    children: [
                      Positioned(
                        right: 0,
                        top: top,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            SizedBox(
                              width: tabWidth,
                              height: tabHeight,
                              child: showChat ? chat : null,
                            ),
                            const SizedBox(height: gap),
                            SizedBox(
                              width: tabWidth,
                              height: tabHeight,
                              child: showHelp ? help : null,
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                }),
              );
            },
          ),
      ],
    );
  }
}

/// Builds the chat tab for [ShowChatTab]; wired once by the root app at
/// startup (`lib/main.dart`, its ChatRibbon for the signed-in user), the
/// same way as `AppLaunchBridge`, since the tab lives in the root app.
/// Returns null when there is no one signed in.
class ChatTabBridge {
  ChatTabBridge._();

  static Widget? Function(BuildContext context)? build;
}

/// Gives a screen pushed above the app's shell the chat tab, in the spot
/// the shell puts it, for a head-to-head game where the players want to
/// talk while they play. A [HideAppHelpTab] inside it still hides the tab
/// unless it passes `keepChat`. Under a shell (the screen wasn't pushed) the
/// shell's chat tab already shows, so it does nothing; likewise before the
/// root app wires [ChatTabBridge] (tests, a standalone app build).
class ShowChatTab extends StatefulWidget {
  final Widget child;

  const ShowChatTab({super.key, required this.child});

  @override
  State<ShowChatTab> createState() => _ShowChatTabState();
}

class _ShowChatTabState extends State<ShowChatTab> {
  final AppHelpTabController _controller = AppHelpTabController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (AppHelpTabScope.maybeOf(context) != null) return widget.child;
    final chat = ChatTabBridge.build?.call(context);
    if (chat == null) return widget.child;
    return AppEdgeTabs(controller: _controller, chat: chat, child: widget.child);
  }
}
