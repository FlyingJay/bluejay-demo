import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storage/src/folders.dart';
import 'package:storage/src/widgets/dialogs.dart';
import 'package:storage/src/widgets/file_row.dart';
import 'package:storage/src/widgets/folder_row.dart';

import 'support/fakes.dart';

/// Music / Remixes / Album, a file at each level, and a file at the top.
final _items = [
  fakeFolder('music', 'Music'),
  fakeFolder('remixes', 'Remixes', parentId: 'music'),
  fakeFolder('album', 'Album', parentId: 'remixes'),
  fakeFolder('art', 'Art'),
  fakeFile(id: 'song', fileName: 'song.mp3', displayName: 'Song', parentId: 'music',
      createdAt: DateTime(2026, 11, 2)),
  fakeFile(id: 'newer', fileName: 'newer.mp3', displayName: 'Newer', parentId: 'music',
      createdAt: DateTime(2026, 11, 9)),
  fakeFile(id: 'mix', fileName: 'mix.mp3', displayName: 'Mix', parentId: 'remixes'),
  fakeFile(id: 'track', fileName: 'track.mp3', displayName: 'Track', parentId: 'album'),
  fakeFile(id: 'loose', fileName: 'loose.pdf', displayName: 'Loose'),
];

void main() {
  group('FolderTree', () {
    final tree = FolderTree(_items);

    test('a folder lists its folders by name, then its files newest first', () {
      expect([for (final i in tree.childrenOf(null)) i.id], ['art', 'music', 'loose']);
      expect([for (final i in tree.childrenOf('music')) i.id], ['remixes', 'newer', 'song']);
    });

    test('the path runs from the top level down to the open folder', () {
      expect([for (final f in tree.pathTo('album')) f.name], ['Music', 'Remixes', 'Album']);
      expect(tree.pathTo(null), isEmpty);
      expect(tree.pathLabel('album'), 'Music / Remixes / Album');
    });

    test('everything inside a folder, all the way down', () {
      expect({for (final i in tree.descendantsOf('music')) i.id},
          {'remixes', 'album', 'song', 'newer', 'mix', 'track'});
      expect(tree.descendantsOf('art'), isEmpty);
    });

    test('an item whose folder isn\'t in the list shows at the top level', () {
      // On the Shared tab: a file shared on its own from an unshared folder.
      final shared = FolderTree([
        fakeFile(id: 'mix', fileName: 'mix.mp3', parentId: 'remixes'),
      ]);
      expect([for (final i in shared.childrenOf(null)) i.id], ['mix']);
    });

    test('an item can move anywhere but where it is, itself and what is inside it', () {
      final music = tree['music']!;
      expect({for (final f in tree.moveTargets(music)) f.id}, {'art'});
      final track = tree['track']!;
      expect({for (final f in tree.moveTargets(track)) f.id}, {'music', 'remixes', 'art'});
    });

    test('a folder filed under itself doesn\'t loop forever', () {
      final odd = FolderTree([
        fakeFolder('a', 'A', parentId: 'b'),
        fakeFolder('b', 'B', parentId: 'a'),
      ]);
      expect(odd.pathTo('a').length, lessThanOrEqualTo(2));
      expect(odd.descendantsOf('a').length, lessThanOrEqualTo(2));
    });
  });

  group('folder widgets', () {
    testWidgets('a folder row shows its name, what is in it and who it is shared with',
        (t) async {
      final log = <String>[];
      await t.pumpWidget(themed(Scaffold(
        body: FolderRow(
          folder: fakeFolder('music', 'Music', sharedWithIds: ['u2']),
          itemCount: 3,
          isOwner: true,
          showSharer: false,
          actions: FolderRowActions(
            onOpen: () => log.add('open'),
            onRename: () => log.add('rename'),
            onMove: () => log.add('move'),
            onShare: () => log.add('share'),
            onDelete: () => log.add('delete'),
          ),
        ),
      )));
      expect(find.text('Music'), findsOneWidget);
      expect(find.text('3 items'), findsOneWidget);
      expect(find.text('Shared with 1'), findsOneWidget);
      await t.tap(find.text('Music'));
      expect(log, ['open']);
      await t.tap(find.byIcon(Icons.more_horiz_rounded));
      await t.pumpAndSettle();
      for (final label in ['Open', 'Rename', 'Move to folder', 'Share', 'Delete']) {
        expect(
            find.descendant(
                of: find.byType(PopupMenuItem<BjMenuAction>), matching: find.text(label)),
            findsOneWidget,
            reason: label);
      }
    });

    test('only its owner can rename, move, share or delete a folder', () {
      final actions = folderMenuActions(
        isOwner: false,
        actions: FolderRowActions(
            onOpen: () {}, onRename: () {}, onMove: () {}, onShare: () {}, onDelete: () {}),
      );
      expect([for (final a in actions) a.label], ['Open']);
    });

    testWidgets('the folder bar steps back up to any folder on the way', (t) async {
      final opened = <String?>[];
      final tree = FolderTree(_items);
      await t.pumpWidget(themed(Scaffold(
        body: FolderBar(
          rootLabel: 'Your files',
          path: tree.pathTo('album'),
          onOpen: opened.add,
          onNewFolder: () {},
        ),
      )));
      expect(find.text('New folder'), findsOneWidget);
      await t.tap(find.text('Music'));
      await t.tap(find.text('Your files'));
      await t.tap(find.byTooltip('Back to Remixes'));
      expect(opened, ['music', null, 'remixes']);
    });

    test('the owner of a file in folders can move it; nobody else can', () {
      final actions = FileRowActions(
        onOpen: () {},
        onDownload: () {},
        onCopyLink: () {},
        onShare: () {},
        onDelete: () {},
        onMove: () {},
      );
      final owner = fileMenuActions(fakeFile(), isOwner: true, actions: actions);
      final other = fileMenuActions(fakeFile(), isOwner: false, actions: actions);
      expect(owner.map((a) => a.label), contains('Move to folder'));
      expect(other.map((a) => a.label), isNot(contains('Move to folder')));
    });

    test('deleting a folder says what goes with it', () {
      final folder = fakeFolder('music', 'Music', sharedWithIds: ['u2', 'u3']);
      expect(deleteFolderConsequences(folder, 6), [
        'The folder and the 6 items in it are deleted for good. This can\'t be undone.',
        'The 2 people you shared it with lose access right away.',
      ]);
      expect(deleteFolderConsequences(fakeFolder('e', 'Empty'), 0),
          ['The folder is deleted. It\'s empty.']);
    });
  });
}
