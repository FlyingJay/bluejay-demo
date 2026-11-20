import 'dart:async';

import 'package:bluejay_design/bluejay_design.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';
import 'package:shared_services/scoped_collection.dart';

import 'constants.dart';
import 'note_detail_screen.dart';
import 'notes_widgets.dart';

/// Firestore collection scoped to the notes app.
///
/// All reads are automatically filtered to the currently active group, and
/// all writes automatically receive the required permission fields.
final _notes = ScopedCollection(
  collection: 'notes',
  appId: APP_ID,
);

class NotesListScreen extends StatefulWidget {
  final fire_auth.User currentUser;

  const NotesListScreen({super.key, required this.currentUser});

  @override
  State<NotesListScreen> createState() => _NotesListScreenState();
}

class _NotesListScreenState extends State<NotesListScreen> {
  final StreamController<List<QueryDocumentSnapshot>> _notesController =
      StreamController<List<QueryDocumentSnapshot>>.broadcast();
  StreamSubscription? _subscription;

  @override
  void initState() {
    super.initState();
    _setupStreams();
  }

  void _setupStreams() {
    // The notes the user owns in the active group: their own and those
    // shared with them (sharing adds the recipient to ownerIds). The rules
    // only let a member read notes they own, so the list must be this shape.
    _subscription = _notes.queryOwned().snapshots().listen((snapshot) {
      _publish(snapshot.docs);
    }, onError: _onStreamError);
  }

  /// Surfaces a failed listener as an error state instead of a spinner
  /// that never ends.
  void _onStreamError(Object error) {
    if (!_notesController.isClosed) _notesController.addError(error);
  }

  void _retry() {
    _subscription?.cancel();
    _setupStreams();
  }

  void _publish(List<QueryDocumentSnapshot> docs) {
    final sortedDocs = docs.toList();
    sortedDocs.sort((a, b) {
      final aData = a.data() as Map<String, dynamic>;
      final bData = b.data() as Map<String, dynamic>;
      final aTimestamp = aData['lastEdited'] as Timestamp?;
      final bTimestamp = bData['lastEdited'] as Timestamp?;
      if (aTimestamp == null || bTimestamp == null) return 0;
      return bTimestamp.compareTo(aTimestamp);
    });

    _notesController.add(sortedDocs);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _notesController.close();
    super.dispose();
  }

  NoteSummary _summaryFrom(QueryDocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final sharedWith = List<String>.from(data['sharedWithIds'] ?? []);
    return NoteSummary(
      id: doc.id,
      title: data['title'] as String? ?? '',
      content: data['content'] as String? ?? '',
      lastEdited: (data['lastEdited'] as Timestamp?)?.toDate(),
      sharedWithMe: data['creatorId'] != widget.currentUser.uid,
      sharedCount:
          sharedWith.where((id) => id != widget.currentUser.uid).length,
    );
  }

  void _openNote(String? noteId) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => NoteDetailScreen(
        currentUser: widget.currentUser,
        noteId: noteId, // null for a new note
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return BjPage(
      title: 'My Notes',
      body: StreamBuilder<List<QueryDocumentSnapshot>>(
        stream: _notesController.stream,
        builder: (context, snapshot) => BjSnapshotView<List<QueryDocumentSnapshot>>(
          snapshot: snapshot,
          loading: const NotesSkeleton(),
          errorTitle: 'Couldn\'t load your notes',
          onRetry: _retry,
          isEmpty: (docs) => docs.isEmpty,
          empty: NotesEmpty(onCreate: () => _openNote(null)),
          builder: (docs) => NotesBoard(
            notes: docs.map(_summaryFrom).toList(),
            onOpen: (n) => _openNote(n.id),
            onCreate: () => _openNote(null),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openNote(null),
        icon: const Icon(Icons.add_rounded),
        label: const Text('New note'),
        tooltip: 'New note',
      ),
    );
  }
}
