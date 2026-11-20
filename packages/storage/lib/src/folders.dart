import 'models.dart';

/// The folders among a list of Storage items, for browsing them: what a
/// folder holds, the way down to it, and where an item may be moved.
///
/// A folder is an item with [SharedFile.isFolder]; anything in one names it
/// in [SharedFile.parentId]. An item whose folder isn't in the list (on the
/// Shared tab, a file shared on its own from a folder that wasn't) is shown
/// at the top level.
class FolderTree {
  FolderTree(Iterable<SharedFile> items)
      : _byId = {for (final item in items) item.id: item};

  final Map<String, SharedFile> _byId;

  /// The item with [id], if it is in the list.
  SharedFile? operator [](String? id) => id == null ? null : _byId[id];

  /// The folder [item] shows in: its own when that is in the list, else
  /// the top level (null).
  String? shownIn(SharedFile item) {
    final parent = item.parentId;
    if (parent == null || parent == item.id) return null;
    return _byId[parent]?.isFolder == true ? parent : null;
  }

  /// What [folderId] holds (null for the top level): folders first, by
  /// name, then files, newest first.
  List<SharedFile> childrenOf(String? folderId) {
    final children = [
      for (final item in _byId.values)
        if (shownIn(item) == folderId) item
    ];
    children.sort((a, b) {
      if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
      if (a.isFolder) return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return b.createdAt.compareTo(a.createdAt);
    });
    return children;
  }

  /// The folders from the top level down to [folderId], it included; empty
  /// at the top level or for a folder that isn't in the list.
  List<SharedFile> pathTo(String? folderId) {
    final path = <SharedFile>[];
    final seen = <String>{};
    var at = this[folderId];
    while (at != null && at.isFolder && seen.add(at.id)) {
      path.insert(0, at);
      at = this[shownIn(at)];
    }
    return path;
  }

  /// Everything inside [folderId], all the way down, not the folder itself.
  List<SharedFile> descendantsOf(String folderId) {
    final out = <SharedFile>[];
    final queue = [folderId];
    final seen = <String>{folderId};
    while (queue.isNotEmpty) {
      final id = queue.removeLast();
      for (final child in childrenOf(id)) {
        if (!seen.add(child.id)) continue;
        out.add(child);
        if (child.isFolder) queue.add(child.id);
      }
    }
    return out;
  }

  /// The folders [item] may be moved into, by their path: every folder but
  /// the one it is in, itself and those inside it.
  List<SharedFile> moveTargets(SharedFile item) {
    final inside = item.isFolder
        ? {item.id, for (final d in descendantsOf(item.id)) d.id}
        : const <String>{};
    final targets = [
      for (final f in _byId.values)
        if (f.isFolder && !inside.contains(f.id) && f.id != shownIn(item)) f
    ];
    targets.sort((a, b) => pathLabel(a.id).toLowerCase().compareTo(pathLabel(b.id).toLowerCase()));
    return targets;
  }

  /// [folderId]'s path for showing, like "Music / Remixes".
  String pathLabel(String? folderId) => pathTo(folderId).map((f) => f.name).join(' / ');
}
