import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Page size for live lists of a collection that keeps growing (messages,
/// comments, notifications, history): what a screen shows before "load
/// more".
const int kLiveWindowPageSize = 50;

/// A live list that holds the first [limit] results of a growing source and
/// widens by [pageSize] on [loadMore].
///
/// The source is any `Stream<List<T>> Function(int limit)`: a Firestore query
/// through [LiveWindow.query], or a service's `watch*(limit: n)` method. The
/// window keeps one subscription to `source(limit)` and swaps it for
/// `source(limit + pageSize)` when the reader asks for more, so a screen
/// downloads and listens to one page at a time instead of the whole
/// collection.
///
/// [stream] is a single, stable stream for a `StreamBuilder`: it replays the
/// latest list to each new listener, and keeps delivering through every
/// [loadMore] and [retry], so the list on screen stays put while the wider
/// page loads. Create the window in `initState` (or a `late final` field) and
/// [dispose] it with the State; building one in `build` would resubscribe on
/// every rebuild.
///
/// For a chat, order the query newest first (`orderBy(..., descending: true)`)
/// so the window holds the newest messages and [loadMore] reaches further
/// back; show them in a `reverse: true` list.
class LiveWindow<T> extends ChangeNotifier {
  LiveWindow(Stream<List<T>> Function(int limit) source,
      {int pageSize = kLiveWindowPageSize})
      : this.pages(
          (limit) => source(limit).map(LiveWindowPage<T>.of),
          pageSize: pageSize,
        );

  /// A window over a source that drops some of what its query read (e.g.
  /// soft-deleted documents) and reports how many it read in
  /// [LiveWindowPage.fetched], so [hasMore] still sees a full page.
  LiveWindow.pages(this._source, {this.pageSize = kLiveWindowPageSize})
      : assert(pageSize > 0),
        _limit = pageSize;

  /// A window over [query]'s documents, `pageSize` at a time. [query] must
  /// carry its `orderBy`: the window adds only the `limit`.
  static LiveWindow<QueryDocumentSnapshot<M>> query<M>(
    Query<M> query, {
    int pageSize = kLiveWindowPageSize,
  }) =>
      LiveWindow<QueryDocumentSnapshot<M>>(
        (limit) => query.limit(limit).snapshots().map((s) => s.docs),
        pageSize: pageSize,
      );

  final Stream<LiveWindowPage<T>> Function(int limit) _source;

  /// How much [loadMore] widens the window.
  final int pageSize;

  int _limit;
  List<T>? _items;
  int _fetched = 0;
  Object? _error;
  StackTrace? _errorStack;
  bool _loadingMore = false;
  bool _loadingAll = false;
  bool _pinned = false;
  bool _disposed = false;
  StreamSubscription<LiveWindowPage<T>>? _upstream;
  final Set<MultiStreamController<List<T>>> _listeners = {};

  /// The window's results, for a `StreamBuilder`. Listening starts the
  /// underlying subscription; it stops when the last listener cancels.
  late final Stream<List<T>> stream = Stream<List<T>>.multi(_onListen);

  /// How many results the window currently asks for.
  int get limit => _limit;

  /// The latest results, or null before the first arrives.
  List<T>? get items => _items;

  /// Whether the source may hold more than the window shows: the last
  /// result filled the window.
  bool get hasMore => _items != null && _fetched >= _limit;

  /// Whether a [loadMore] is waiting for its first, wider result.
  bool get isLoadingMore => _loadingMore;

  /// The latest error, cleared by the next result or [retry].
  Object? get error => _error;

  /// Keeps the subscription running without a [stream] listener, for a
  /// screen that reads [items] through `addListener`/`ListenableBuilder`.
  void start() {
    _pinned = true;
    if (_upstream == null) _subscribe();
  }

  /// Widens the window by [pageSize]. Does nothing while a wider page is
  /// already loading or when the last result didn't fill the window, so a
  /// scroll listener can call it freely.
  void loadMore() {
    if (_disposed || _loadingMore || !hasMore) return;
    _limit += pageSize;
    _loadingMore = true;
    notifyListeners();
    _resubscribe();
  }

  /// Widens the window until it holds the whole source, doubling each
  /// round, e.g. while a search over the list is active: a search should
  /// find older items as well as the loaded ones.
  void loadAll() {
    if (_disposed || _loadingAll) return;
    _loadingAll = true;
    _widenForAll();
  }

  void _widenForAll() {
    if (!hasMore || _loadingMore) return;
    _limit *= 2;
    _loadingMore = true;
    notifyListeners();
    _resubscribe();
  }

  /// Subscribes again at the current size, after an error.
  void retry() {
    if (_disposed) return;
    _error = null;
    _errorStack = null;
    _resubscribe();
  }

  void _onListen(MultiStreamController<List<T>> controller) {
    if (_disposed) {
      controller.closeSync();
      return;
    }
    _listeners.add(controller);
    controller.onCancel = () {
      _listeners.remove(controller);
      if (_listeners.isEmpty && !_pinned) _unsubscribe();
    };
    final items = _items;
    if (items != null) {
      controller.add(items);
    } else if (_error != null) {
      controller.addError(_error!, _errorStack);
    }
    if (_upstream == null) _subscribe();
  }

  void _subscribe() {
    _upstream = _source(_limit).listen((page) {
      final items = page.items;
      _items = items;
      _fetched = page.fetched;
      _error = null;
      _errorStack = null;
      _loadingMore = false;
      for (final c in _listeners.toList()) {
        c.add(items);
      }
      notifyListeners();
      if (_loadingAll) _widenForAll();
    }, onError: (Object e, StackTrace s) {
      _error = e;
      _errorStack = s;
      _loadingMore = false;
      for (final c in _listeners.toList()) {
        c.addError(e, s);
      }
      notifyListeners();
    });
  }

  void _unsubscribe() {
    _upstream?.cancel();
    _upstream = null;
  }

  void _resubscribe() {
    _unsubscribe();
    if (_listeners.isNotEmpty || _pinned) _subscribe();
  }

  @override
  void dispose() {
    _disposed = true;
    _unsubscribe();
    for (final c in _listeners.toList()) {
      c.closeSync();
    }
    _listeners.clear();
    super.dispose();
  }
}

/// One result of a [LiveWindow.pages] source.
class LiveWindowPage<T> {
  const LiveWindowPage(this.items, {required this.fetched});

  /// A page that shows everything its query read.
  LiveWindowPage.of(List<T> items) : this(items, fetched: items.length);

  /// What to show.
  final List<T> items;

  /// How many documents the query read for [items], before any were
  /// dropped: a full read (`fetched >= limit`) means more may remain.
  final int fetched;
}

/// The most a badge counts before it reads "99+": count queries that only
/// feed a badge fetch at most this many documents.
const int kBadgeCountCap = 100;

/// [count] as a badge shows it: "99+" from [kBadgeCountCap] - 1 up.
String cappedCountLabel(int count) =>
    count >= kBadgeCountCap ? '${kBadgeCountCap - 1}+' : '$count';
