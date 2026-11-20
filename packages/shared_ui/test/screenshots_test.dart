// Renders the key shared_ui widgets as PNGs with the real bundled fonts,
// for design review. Off by default (pixels depend on the host's font
// rendering). Run with:
//
//   BJ_DESIGN_SCREENSHOTS=1 flutter test test/screenshots_test.dart --update-goldens
//
// Output: test/screenshots/out/*.png (git-ignored).

import 'dart:io';

import 'package:bluejay_design/bluejay_design.dart';
import 'package:bluejay_design/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/change_request_grouping.dart';
import 'package:shared_services/change_request_list_scope.dart';
import 'package:shared_ui/bug_reproduction_fields.dart';
import 'package:shared_ui/change_request_grouping_ui.dart';
import 'package:shared_ui/change_request_ui.dart';
import 'package:shared_ui/claim_account_sheet.dart';
import 'package:shared_ui/comment_thread_widget.dart';
import 'package:shared_ui/shared_message_composer.dart';
import 'package:shared_ui/user_search_screen.dart';

import 'support/fixtures.dart';

final _enabled = Platform.environment['BJ_DESIGN_SCREENSHOTS'] == '1';

Future<void> _loadFonts() async {
  Future<ByteData> file(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  const fonts = '../../assets/fonts';
  await loadBjFonts(fonts);
  final root = Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable)
          .parent
          .parent
          .parent
          .parent
          .parent
          .parent
          .path;
  await (FontLoader('MaterialIcons')
        ..addFont(file(
            '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')))
      .load();
}

/// A user search page with sample members and no data loading.
Widget _search({
  bool multi = false,
  Set<String> selected = const {},
  List<GroupMember>? members,
  bool loading = false,
  String query = '',
}) =>
    BjPage(
      title: multi ? 'Select people' : 'Find someone',
      maxWidth: BjBreakpoint.formWidth,
      actions: multi
          ? [
              FilledButton.icon(
                onPressed: selected.isEmpty ? null : () {},
                icon: const Icon(Icons.check_rounded, size: 18),
                label: Text(selected.isEmpty ? 'Done' : 'Done (${selected.length})'),
              ),
            ]
          : null,
      body: UserSearchBody(
        searchController: TextEditingController(text: query),
        members: members ?? sampleMembers,
        allMembers: sampleMembers,
        isLoading: loading,
        loadError: null,
        multiSelect: multi,
        selectedUserIds: selected,
        onTap: (_) {},
        onDeselect: (_) {},
      ),
    );

/// The comment thread as its sheet shows it, over a dimmed page.
Widget _thread({List<CommentEntry>? comments, String? replyTo}) => Builder(
      builder: (context) {
        final height = MediaQuery.sizeOf(context).height;
        return Stack(children: [
          const BjPage(title: 'Improve Apps', body: SizedBox.shrink()),
          const ModalBarrier(color: Colors.black54),
          Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 640, maxHeight: height * 0.75),
              child: Material(
                color: BjNeutral.surface,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(BjRadius.xl)),
                clipBehavior: Clip.antiAlias,
                child: CommentThreadFrame(
                  onClose: () {},
                  body: CommentThreadList(
                    comments: comments ?? sampleComments,
                    canModerate: true,
                    onLike: (_) {},
                    onReply: (_) {},
                    onDelete: (_) {},
                    onModerate: (_) {},
                  ),
                  composer: CommentComposer(
                    controller: TextEditingController(),
                    enabled: true,
                    isSubmitting: false,
                    replyToAuthor: replyTo,
                    onCancelReply: () {},
                    onSubmit: () {},
                  ),
                ),
              ),
            ),
          ),
        ]);
      },
    );

/// A chat-style page ending in the shared message composer.
Widget _composer() => BjPage(
      title: 'Town Square',
      body: Column(children: [
        Expanded(
          child: BjScrollBody(children: [
            for (final c in sampleComments.where((c) => !c.isDeleted).take(3))
              BjCard(
                child: Text(c.text),
              ),
          ]),
        ),
        SharedMessageComposer(
          controller: TextEditingController(text: 'Looks great, shipping it today'),
          onSend: () {},
          onPickImage: () {},
        ),
      ]),
    );

/// The ticket building blocks Improve Apps' cards are made of.
Widget _ticketParts() => BjPage(
      title: 'Ticket parts',
      body: BjScrollBody(maxWidth: BjBreakpoint.formWidth, children: [
        ChangeRequestScopeSwitcher(
          scopes: ChangeRequestListScope.values,
          selected: ChangeRequestListScope.managedApps,
          onChanged: (_) {},
          padding: EdgeInsets.zero,
        ),
        ChangeRequestSelectionBar(
          selecting: true,
          selectedCount: 2,
          appLabel: 'Rented Dwelling',
          onStart: () {},
          onCancel: () {},
          onCombine: () {},
        ),
        BjCard(
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ChangeRequestVoteColumn(
              voteCount: 12,
              hasUpvoted: true,
              hasDownvoted: false,
              onUpvote: () {},
              onDownvote: () {},
            ),
            const SizedBox(width: BjSpace.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const ChangeRequestScopeChip(label: 'Acme Insurance · Rented Dwelling'),
                const SizedBox(height: BjSpace.sm),
                const ChangeRequestGroupingChips(
                  parentRequest: ParentRequestRef(
                    itemType: 'feature',
                    itemId: 'p1',
                    title: 'Faster exports',
                    state: ChangeRequestState.inReview,
                  ),
                  combinedCount: 3,
                ),
                const Text('Export to CSV drops rows past 50'),
                const SizedBox(height: BjSpace.sm),
                Wrap(spacing: BjSpace.sm, runSpacing: BjSpace.sm, children: [
                  ChangeRequestActionChip(
                    icon: Icons.check_circle_outline_rounded,
                    label: 'Mark fixed',
                    tone: BjTone.success,
                    onTap: () {},
                  ),
                  const CommentCountButton(count: 4, onTap: null),
                  const ChangeRequestPointsBadge(points: 5),
                ]),
              ]),
            ),
          ]),
        ),
        BjCard(
          child: BugReproductionFields(controller: BugReproductionController()),
        ),
        const BjCard(child: BugReproductionExampleCard(initiallyExpanded: true)),
        const LockedRelatedAppField(appName: 'Habit Tracker'),
      ]),
    );

class _SheetHost extends StatefulWidget {
  const _SheetHost();

  @override
  State<_SheetHost> createState() => _SheetHostState();
}

class _SheetHostState extends State<_SheetHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => ClaimAccountSheet.show(context));
  }

  @override
  Widget build(BuildContext context) =>
      const BjPage(title: 'Projects', body: SizedBox.shrink());
}

void main() {
  setUpAll(() async {
    if (_enabled) await _loadFonts();
  });

  final sizes = {'phone': const Size(390, 1100), 'desktop': const Size(1280, 900)};
  final screens = <String, Widget Function()>{
    'user_search': () => _search(),
    'user_search_multi': () => _search(multi: true, selected: {'u1', 'u4'}),
    'user_search_empty': () => _search(members: const [], query: 'zed'),
    'user_search_loading': () => _search(loading: true),
    'comment_thread': () => _thread(replyTo: 'bianca'),
    'comment_thread_empty': () => _thread(comments: const []),
    'message_composer': _composer,
    'ticket_parts': _ticketParts,
    'claim_account': () => const _SheetHost(),
  };

  for (final size in sizes.entries) {
    for (final screen in screens.entries) {
      testWidgets('${screen.key} ${size.key}', (t) async {
        t.view.physicalSize = size.value * 2;
        t.view.devicePixelRatio = 2;
        FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTouch;
        await t.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BluejayTheme.build(),
          home: screen.value(),
        ));
        for (var i = 0; i < 20; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('screenshots/out/${screen.key}_${size.key}.png'),
        );
        t.view.reset();
      }, skip: !_enabled);
    }
  }
}
