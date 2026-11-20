import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:improve_bluejay/request_change.dart';
import 'package:shared_services/app_help_tab.dart';
import 'package:wiki/app_help.dart';

const _guide = AppHelpDoc(slug: 'notes', markdown: '# Notes\n\n## Creating a note\n\nTap New note.\n');

Future<void> _pump(WidgetTester t, Widget shell) async {
  t.view.physicalSize = const Size(500, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: BluejayTheme.build(), home: shell));
  await t.pumpAndSettle();
}

void main() {
  // No signed-in user, so Request a change never resolves and only the
  // guide decides whether the tab shows.
  testWidgets('with only a guide, the tab opens it directly', (t) async {
    await _pump(
      t,
      AppHelpShell(
        appId: 'notes',
        appName: 'Notes',
        loadGuide: (_, {forGuest = false}) async => _guide,
        child: const Scaffold(body: Text('app')),
      ),
    );
    expect(find.byTooltip('Help with Notes'), findsOneWidget);
    await t.tap(find.byTooltip('Help with Notes'));
    await t.pumpAndSettle();
    expect(find.text('How Notes works'), findsOneWidget);
    expect(find.text('Report a problem'), findsNothing);
    expect(find.text('Request a change'), findsNothing);
    // BlueJI reads member guides, so a guest isn't offered it.
    expect(find.byTooltip('Ask BlueJI about Notes'), findsNothing);
  });

  testWidgets('the chooser offers Ask BlueJI first, when given an app to ask about', (t) async {
    await _pump(
      t,
      const Scaffold(
        body: RequestChangeChooser(askAppName: 'Notes', guideAppName: 'Notes', offerRequests: false),
      ),
    );
    final ask = find.text('Ask BlueJI about Notes');
    expect(ask, findsOneWidget);
    expect(t.getTopLeft(ask).dy, lessThan(t.getTopLeft(find.text('How Notes works')).dy));
  });

  testWidgets('BlueJI and the guide switch between each other', (t) async {
    bool? stuck;
    await _pump(
      t,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              stuck = await showGuideOrAsk(
                context,
                start: AppTabAction.ask,
                appId: 'notes',
                appName: 'Notes',
                guide: _guide,
                offerRequestChange: true,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.text('Ask BlueJI about Notes.'), findsOneWidget);

    await t.tap(find.text('Read the guide'));
    await t.pumpAndSettle();
    expect(find.text('How Notes works'), findsOneWidget);
    expect(find.text('Ask BlueJI about Notes.'), findsNothing);

    await t.tap(find.byTooltip('Ask BlueJI about Notes'));
    await t.pumpAndSettle();
    expect(find.text('Ask BlueJI about Notes.'), findsOneWidget);
    expect(find.text('How Notes works'), findsNothing);

    await t.tap(find.text('Read the guide'));
    await t.pumpAndSettle();
    await t.tap(find.text('Request a change'));
    await t.pumpAndSettle();
    expect(stuck, isTrue);
  });

  testWidgets('without a member account, the guest guide is asked for', (t) async {
    final asked = <bool>[];
    await _pump(
      t,
      AppHelpShell(
        appId: 'notes',
        appName: 'Notes',
        loadGuide: (_, {forGuest = false}) async {
          asked.add(forGuest);
          return null;
        },
        child: const Scaffold(body: Text('app')),
      ),
    );
    expect(asked, [true]);
    expect(find.byIcon(Icons.help_outline_rounded), findsNothing);
  });

  testWidgets('no guide and no Request a change: no tab', (t) async {
    await _pump(
      t,
      AppHelpShell(
        appId: 'notes',
        appName: 'Notes',
        loadGuide: (_, {forGuest = false}) async => null,
        child: const Scaffold(body: Text('app')),
      ),
    );
    expect(find.text('app'), findsOneWidget);
    expect(find.byIcon(Icons.help_outline_rounded), findsNothing);
    expect(find.byIcon(Icons.rate_review_outlined), findsNothing);
  });

  testWidgets('disabled (embedded deep link): no tab, no lookup', (t) async {
    var lookups = 0;
    await _pump(
      t,
      AppHelpShell(
        appId: 'notes',
        appName: 'Notes',
        enabled: false,
        loadGuide: (_, {forGuest = false}) async {
          lookups++;
          return _guide;
        },
        child: const Scaffold(body: Text('app')),
      ),
    );
    expect(lookups, 0);
    expect(find.byIcon(Icons.help_outline_rounded), findsNothing);
  });

  group('HideAppHelpTab', () {
    Widget shell(Widget child) => AppHelpShell(
          appId: 'notes',
          appName: 'Notes',
          loadGuide: (_, {forGuest = false}) async => _guide,
          child: child,
        );

    testWidgets('hides the tab while it is in the tree', (t) async {
      final playing = ValueNotifier<bool>(false);
      addTearDown(playing.dispose);
      await _pump(
        t,
        shell(ValueListenableBuilder<bool>(
          valueListenable: playing,
          builder: (_, on, __) => on
              ? const HideAppHelpTab(child: Scaffold(body: Text('game')))
              : const Scaffold(body: Text('lobby')),
        )),
      );
      expect(find.byTooltip('Help with Notes'), findsOneWidget);

      playing.value = true;
      await t.pumpAndSettle();
      expect(find.text('game'), findsOneWidget);
      expect(find.byTooltip('Help with Notes'), findsNothing);

      playing.value = false;
      await t.pumpAndSettle();
      expect(find.text('lobby'), findsOneWidget);
      expect(find.byTooltip('Help with Notes'), findsOneWidget);
    });

    testWidgets('hide: false leaves the tab showing', (t) async {
      final hide = ValueNotifier<bool>(true);
      addTearDown(hide.dispose);
      await _pump(
        t,
        shell(ValueListenableBuilder<bool>(
          valueListenable: hide,
          builder: (_, on, __) => HideAppHelpTab(
            hide: on,
            child: const Scaffold(body: Text('app')),
          ),
        )),
      );
      expect(find.byTooltip('Help with Notes'), findsNothing);

      hide.value = false;
      await t.pumpAndSettle();
      expect(find.byTooltip('Help with Notes'), findsOneWidget);
    });

    testWidgets('the tab stays hidden until the last one goes', (t) async {
      final count = ValueNotifier<int>(2);
      addTearDown(count.dispose);
      await _pump(
        t,
        shell(ValueListenableBuilder<int>(
          valueListenable: count,
          builder: (_, n, __) => Scaffold(
            body: Column(children: [
              for (var i = 0; i < n; i++)
                HideAppHelpTab(key: ValueKey(i), child: Text('hider $i')),
            ]),
          ),
        )),
      );
      expect(find.byTooltip('Help with Notes'), findsNothing);

      count.value = 1;
      await t.pumpAndSettle();
      expect(find.byTooltip('Help with Notes'), findsNothing);

      count.value = 0;
      await t.pumpAndSettle();
      expect(find.byTooltip('Help with Notes'), findsOneWidget);
    });

    testWidgets('outside a shell it does nothing', (t) async {
      await _pump(
        t,
        const HideAppHelpTab(child: Scaffold(body: Text('standalone'))),
      );
      expect(find.text('standalone'), findsOneWidget);
    });
  });

  group('chat tab', () {
    const chatTab = Tooltip(message: 'Open Chat', child: SizedBox(width: 42, height: 62));

    Widget shell(Widget child, {bool enabled = true, bool guide = true}) => AppHelpShell(
          appId: 'notes',
          appName: 'Notes',
          enabled: enabled,
          loadGuide: (_, {forGuest = false}) async => guide ? _guide : null,
          chatTab: chatTab,
          child: child,
        );

    testWidgets('sits just above the help tab', (t) async {
      await _pump(t, shell(const Scaffold(body: Text('app'))));
      final chat = t.getRect(find.byTooltip('Open Chat'));
      final help = t.getRect(find.byTooltip('Help with Notes'));
      expect(chat.right, help.right);
      expect(chat.bottom, lessThan(help.top));
      expect(help.top - chat.bottom, AppEdgeTabs.gap);
    });

    testWidgets('never overlaps the help tab, however short the screen', (t) async {
      for (final height in [120.0, 180.0, 300.0, 1000.0]) {
        t.view.physicalSize = Size(500, height);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await t.pumpWidget(MaterialApp(theme: BluejayTheme.build(), home: shell(const Scaffold(body: Text('app')))));
        await t.pumpAndSettle();
        final chat = t.getRect(find.byTooltip('Open Chat'));
        final help = t.getRect(find.byTooltip('Help with Notes'));
        expect(chat.overlaps(help), isFalse, reason: 'height $height');
      }
    });

    testWidgets('shows without a help tab, in the same spot', (t) async {
      await _pump(t, shell(const Scaffold(body: Text('app')), guide: false));
      expect(find.byTooltip('Open Chat'), findsOneWidget);
      expect(find.byIcon(Icons.help_outline_rounded), findsNothing);
    });

    testWidgets('hides with the help tab for a HideAppHelpTab', (t) async {
      await _pump(t, shell(const HideAppHelpTab(child: Scaffold(body: Text('game')))));
      expect(find.byTooltip('Open Chat'), findsNothing);
      expect(find.byTooltip('Help with Notes'), findsNothing);
    });

    testWidgets('stays for keepChat, where only the help tab hides', (t) async {
      final keep = ValueNotifier<bool>(true);
      addTearDown(keep.dispose);
      await _pump(
        t,
        shell(ValueListenableBuilder<bool>(
          valueListenable: keep,
          builder: (_, on, __) => HideAppHelpTab(
            keepChat: on,
            child: const Scaffold(body: Text('match')),
          ),
        )),
      );
      expect(find.byTooltip('Open Chat'), findsOneWidget);
      expect(find.byTooltip('Help with Notes'), findsNothing);

      keep.value = false;
      await t.pumpAndSettle();
      expect(find.byTooltip('Open Chat'), findsNothing);

      keep.value = true;
      await t.pumpAndSettle();
      expect(find.byTooltip('Open Chat'), findsOneWidget);
    });

    testWidgets('one hider without keepChat hides it despite another with', (t) async {
      await _pump(
        t,
        shell(const Scaffold(
          body: Column(children: [
            HideAppHelpTab(keepChat: true, child: Text('a')),
            HideAppHelpTab(child: Text('b')),
          ]),
        )),
      );
      expect(find.byTooltip('Open Chat'), findsNothing);
    });

    testWidgets('hides while the keyboard is up', (t) async {
      t.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(t.view.resetViewInsets);
      await _pump(t, shell(const Scaffold(body: Text('app'))));
      expect(find.byTooltip('Open Chat'), findsNothing);
    });

    testWidgets('disabled (embedded deep link): no chat tab', (t) async {
      await _pump(t, shell(const Scaffold(body: Text('app')), enabled: false));
      expect(find.byTooltip('Open Chat'), findsNothing);
    });
  });

  group('ShowChatTab', () {
    tearDown(() => ChatTabBridge.build = null);

    testWidgets('gives a screen pushed above the shell the chat tab', (t) async {
      ChatTabBridge.build = (_) => const Tooltip(message: 'Open Chat', child: SizedBox(width: 42, height: 62));
      await _pump(t, const ShowChatTab(child: Scaffold(body: Text('board'))));
      expect(find.byTooltip('Open Chat'), findsOneWidget);
    });

    testWidgets('under a shell, leaves it to the shell', (t) async {
      ChatTabBridge.build = (_) => const Tooltip(message: 'Open Chat', child: SizedBox(width: 42, height: 62));
      await _pump(
        t,
        AppHelpShell(
          appId: 'notes',
          appName: 'Notes',
          loadGuide: (_, {forGuest = false}) async => null,
          chatTab: const Tooltip(message: 'Open Chat', child: SizedBox(width: 42, height: 62)),
          child: const ShowChatTab(child: Scaffold(body: Text('board'))),
        ),
      );
      expect(find.byTooltip('Open Chat'), findsOneWidget);
    });

    testWidgets('a HideAppHelpTab inside still hides it, unless keepChat', (t) async {
      ChatTabBridge.build = (_) => const Tooltip(message: 'Open Chat', child: SizedBox(width: 42, height: 62));
      await _pump(t, const ShowChatTab(child: HideAppHelpTab(child: Scaffold(body: Text('board')))));
      expect(find.byTooltip('Open Chat'), findsNothing);
      await _pump(t, const ShowChatTab(child: HideAppHelpTab(keepChat: true, child: Scaffold(body: Text('b')))));
      expect(find.byTooltip('Open Chat'), findsOneWidget);
    });

    testWidgets('unwired or signed out: nothing', (t) async {
      await _pump(t, const ShowChatTab(child: Scaffold(body: Text('board'))));
      expect(find.text('board'), findsOneWidget);
      expect(find.byTooltip('Open Chat'), findsNothing);
    });
  });
}
