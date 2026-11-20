import 'package:bluejay_design/bluejay_design.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';
import 'package:shared_services/member_identity.dart';
import 'package:shared_services/notification_service.dart';
import 'package:shared_services/scoped_collection.dart';
import 'package:shared_ui/user_search_screen.dart';

import 'constants.dart';
import 'note_autosave.dart';
import 'notes_widgets.dart';

/// Firestore collection scoped to the notes app.
/// all writes automatically receive the required permission fields.
final _notes = ScopedCollection(
  collection: 'notes',
  appId: APP_ID,
);

final _notifications = NotificationService(appId: APP_ID);

class NoteDetailScreen extends StatefulWidget {
  final fire_auth.User currentUser;
  final String? noteId; // Null for a new note

  const NoteDetailScreen({super.key, required this.currentUser, this.noteId});

  @override
  _NoteDetailScreenState createState() => _NoteDetailScreenState();
}

class _NoteDetailScreenState extends State<NoteDetailScreen> {
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  bool _isLoading = true;
  bool _isSaving = false;
  bool _isAutosaving = false;
  bool _isDirty = false;
  late final NoteAutosaver _autosaver = NoteAutosaver(save: _autosave);
  late final AppLifecycleListener _lifecycle;
  List<String> _sharedWithIds = [];
  List<String> _sharedWithEmails = [];
  String _initialTitle = '';
  String _initialContent = '';
  // The note's original creator — loaded from the doc itself for an
  // existing note (never assumed to be the current user, since anyone the
  // note is shared with can open and edit it; see _ownerIdsFor below).
  String? _creatorId;

  /// When the loaded note was last saved, shown above the title.
  DateTime? _lastEdited;

  /// Notes are ownerScoped: a member reads, edits and deletes only the
  /// notes they own (creatorId or ownerIds), so ownerIds is what actually
  /// enforces sharedWithIds server-side. Every write that touches
  /// sharedWithIds must also update ownerIds in the same call, or the two
  /// silently drift.
  List<String> _ownerIdsFor(List<String> sharedWithIds, {required String creatorId}) {
    return {creatorId, ...sharedWithIds}.toList();
  }

  @override
  void initState() {
    super.initState();
    _titleController.addListener(_onTextChanged);
    _contentController.addListener(_onTextChanged);
    // Write pending edits when the tab or app goes to the background, where
    // a refresh, tab close or app kill would otherwise lose them.
    _lifecycle = AppLifecycleListener(onHide: () => _autosaver.flush());
    if (widget.noteId != null) {
      _loadNoteData();
    } else {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _autosaver.dispose();
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  void _updateDirtyState() {
    final isDirty = _titleController.text != _initialTitle ||
        _contentController.text != _initialContent;
    if (_isDirty != isDirty && mounted) {
      setState(() {
        _isDirty = isDirty;
      });
    }
  }

  void _onTextChanged() {
    _updateDirtyState();
    if (widget.noteId != null && !_isLoading && _isDirty) {
      _autosaver.schedule();
    }
  }

  /// Saves the title and text of an existing note in place, without leaving
  /// the editor. New notes are left to the Save button, so a note isn't
  /// created until the user asks for it, and a note cleared to empty is left
  /// to the Save button's delete prompt. Failures stay quiet: the pill keeps
  /// showing unsaved changes and Save reports the error.
  Future<void> _autosave() async {
    if (widget.noteId == null || _isSaving || !_isDirty) return;
    final title = _titleController.text;
    final content = _contentController.text;
    if (title.isEmpty && content.isEmpty) return;

    if (mounted) setState(() => _isAutosaving = true);
    try {
      final edited = Timestamp.now();
      // Sharing fields are untouched here, so ownerIds needn't be re-sent.
      await _notes.update(_notes.doc(widget.noteId), {
        'title': title,
        'content': content,
        'lastEdited': edited,
      });
      // Baseline is what was written; anything typed since stays dirty.
      _initialTitle = title;
      _initialContent = content;
      _lastEdited = edited.toDate();
      _updateDirtyState();
    } catch (error) {
      debugPrint('Notes autosave failed: $error');
    } finally {
      if (mounted) setState(() => _isAutosaving = false);
    }
  }

  void _markSavedState() {
    _initialTitle = _titleController.text;
    _initialContent = _contentController.text;
    _updateDirtyState();
  }

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    BjSnack.error(context, message);
  }

  Future<void> _loadNoteData() async {
    try {
      final doc = await _notes.doc(widget.noteId).get();
      if (doc.exists) {
        final data = doc.data()!;
        _titleController.text = data['title'] ?? '';
        _contentController.text = data['content'] ?? '';
        _sharedWithIds = List<String>.from(data['sharedWithIds'] ?? []);
        _sharedWithEmails = List<String>.from(data['sharedWithEmails'] ?? []);
        _creatorId = data['creatorId'] as String? ?? widget.currentUser.uid;
        _lastEdited = (data['lastEdited'] as Timestamp?)?.toDate();
        _markSavedState();
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  bool get _createdByMe =>
      (_creatorId ?? widget.currentUser.uid) == widget.currentUser.uid;

  int get _sharedCount =>
      _sharedWithIds.where((id) => id != widget.currentUser.uid).length;

  Future<bool> _confirmDeleteEmptyNote() {
    return showBjConfirm(
      context,
      title: 'Delete this empty note?',
      message: 'It has no title or text now. Delete it instead of keeping a '
          'blank note?',
      consequences: noteDeleteConsequences(
          sharedCount: _sharedCount, createdByMe: _createdByMe),
      confirmLabel: 'Delete note',
      cancelLabel: 'Keep editing',
      destructive: true,
    );
  }

  Future<void> _handleExitRequest() async {
    if (_isSaving) return;
    if (!_isDirty) {
      Navigator.of(context).pop();
      return;
    }

    final action = await showNoteUnsavedDialog(context);
    if (!mounted || action == null || action == NoteExitAction.cancel) return;

    if (action == NoteExitAction.discard) {
      _autosaver.cancel();
      Navigator.of(context).pop();
      return;
    }

    await _saveNote();
  }

  Future<bool> _saveNote() async {
    if (_isSaving) return false;
    _autosaver.cancel();

    setState(() {
      _isSaving = true;
    });

    try {
      if (_titleController.text.isEmpty && _contentController.text.isEmpty) {
        // Optionally, delete the note if it's saved and now empty
        if (widget.noteId != null) {
          final shouldDelete = await _confirmDeleteEmptyNote();
          if (!shouldDelete) {
            return false;
          }
          await _deleteNote(confirm: false);
        } else if (mounted) {
          Navigator.of(context).pop();
        }
        return true;
      }

      if (widget.noteId != null) {
        // Update existing note — permission fields are already on the
        // document, but ownerIds must be re-sent on every write that could
        // change sharedWithIds, since update() doesn't merge-preserve it
        // for us and ScopedCollection's auto-injection only applies to add/set.
        await _notes.doc(widget.noteId).update({
          'title': _titleController.text,
          'content': _contentController.text,
          'lastEdited': Timestamp.now(),
          'sharedWithIds': _sharedWithIds,
          'sharedWithEmails': _sharedWithEmails,
          'ownerIds': _ownerIdsFor(_sharedWithIds,
              creatorId: _creatorId ?? widget.currentUser.uid),
        });
      } else {
        // Create new note — ScopedCollection injects groupId, appId,
        // creatorId, and a default ownerIds of [creatorId]; overridden here
        // to include sharedWithIds from the start.
        await _notes.add({
          'title': _titleController.text,
          'content': _contentController.text,
          'lastEdited': Timestamp.now(),
          'sharedWithIds': _sharedWithIds,
          'sharedWithEmails': _sharedWithEmails,
          'ownerIds': _ownerIdsFor(_sharedWithIds,
              creatorId: widget.currentUser.uid),
        });
      }
      _markSavedState();
      if (mounted) {
        Navigator.of(context).pop();
      }
      return true;
    } catch (error) {
      _showErrorSnackBar('Failed to save note. Please try again.');
      return false;
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _deleteNote({bool confirm = true}) async {
    if (widget.noteId == null) return;

    bool shouldDelete = true;
    if (confirm) {
      shouldDelete = await showBjConfirm(
        context,
        title: 'Delete this note?',
        message: _titleController.text.isEmpty
            ? null
            : '"${_titleController.text}" will be deleted.',
        consequences: noteDeleteConsequences(
            sharedCount: _sharedCount, createdByMe: _createdByMe),
        confirmLabel: 'Delete note',
        destructive: true,
      );
    }

    if (shouldDelete) {
      _autosaver.cancel();
      await _notes.doc(widget.noteId).delete();
      if (mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  Future<void> _shareNote() async {
    if (widget.noteId == null) {
      // Save the note first before sharing
      if (_titleController.text.isEmpty && _contentController.text.isEmpty) {
        BjSnack.info(context, 'Add a title or some text before sharing.');
        return;
      }

      // Create the note — ScopedCollection injects groupId, appId, creatorId.
      final docRef = await _notes.add({
        'title': _titleController.text,
        'content': _contentController.text,
        'lastEdited': Timestamp.now(),
        'sharedWithIds': [],
        'sharedWithEmails': [],
        'ownerIds': [widget.currentUser.uid],
      });

      // Now proceed with sharing using the new note ID
      if (!mounted) return;

      final selectedMembers =
          await Navigator.of(context).push<List<GroupMember>>(
        MaterialPageRoute(
          builder: (_) => UserSearchScreen(
            currentUser: widget.currentUser,
            multiSelect: true,
            excludeUserIds: [widget.currentUser.uid],
          ),
        ),
      );

      if (selectedMembers == null || selectedMembers.isEmpty) {
        // Note was created but not shared, navigate back
        if (mounted) Navigator.of(context).pop();
        return;
      }

      final newUserIds = selectedMembers.map((member) => member.uid).toList();
      final newUserEmails =
          selectedMembers.map((member) => member.email).toList();

      // Update the note with shared users
      await docRef.update({
        'sharedWithIds': newUserIds,
        'sharedWithEmails': newUserEmails,
        'ownerIds': _ownerIdsFor(newUserIds, creatorId: widget.currentUser.uid),
      });

      // Send notifications to shared users
      await _sendNotifications(
        newUserIds,
        docRef.id,
        _titleController.text,
      );

      if (mounted) {
        BjSnack.success(context,
            'Note shared with ${newUserIds.length} ${newUserIds.length > 1 ? 'people' : 'person'}');
        Navigator.of(context).pop();
      }
      return;
    }

    final selectedMembers =
        await Navigator.of(context).push<List<GroupMember>>(
      MaterialPageRoute(
        builder: (_) => UserSearchScreen(
          currentUser: widget.currentUser,
          multiSelect: true,
          excludeUserIds: [widget.currentUser.uid, ..._sharedWithIds],
        ),
      ),
    );

    if (selectedMembers == null || selectedMembers.isEmpty) return;

    final newUserIds = selectedMembers.map((member) => member.uid).toList();
    final newUserEmails =
        selectedMembers.map((member) => member.email).toList();

    setState(() {
      _sharedWithIds = [..._sharedWithIds, ...newUserIds];
      _sharedWithEmails = [..._sharedWithEmails, ...newUserEmails];
    });

    // Update the note with new shared users
    await _notes.doc(widget.noteId).update({
      'sharedWithIds': _sharedWithIds,
      'sharedWithEmails': _sharedWithEmails,
      'ownerIds': _ownerIdsFor(_sharedWithIds,
          creatorId: _creatorId ?? widget.currentUser.uid),
    });

    // Send notifications to newly shared users
    await _sendNotifications(
      newUserIds,
      widget.noteId!,
      _titleController.text,
    );

    if (mounted) {
      BjSnack.success(context,
          'Note shared with ${newUserIds.length} ${newUserIds.length > 1 ? 'people' : 'person'}');
    }
  }

  Future<void> _sendNotifications(
    List<String> recipientIds,
    String noteId,
    String noteTitle,
  ) async {
    final senderName =
        await GroupMemberDirectory.instance.labelForUser(widget.currentUser);
    final displayTitle = noteTitle.isEmpty ? 'Untitled Note' : noteTitle;

    try {
      await _notifications.addForRecipients(recipientIds, {
        'title': '$senderName shared a note with you',
        'body': displayTitle,
        'appName': 'Notes',
        'context': {
          'noteId': noteId,
        },
      });
    } catch (error) {
      // Log notification failure but don't block note sharing
      debugPrint('Failed to send notifications to $recipientIds: $error');
    }
  }

  NoteSaveState get _saveState => _isSaving || _isAutosaving
      ? NoteSaveState.saving
      : _isDirty
          ? NoteSaveState.unsaved
          : widget.noteId == null
              ? NoteSaveState.isNew
              : NoteSaveState.saved;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isDirty && !_isSaving,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) return;
        await _handleExitRequest();
      },
      child: NoteEditorPage(
        isNew: widget.noteId == null,
        saving: _isSaving,
        dirty: _isDirty,
        onSave: _saveNote,
        onDelete: widget.noteId == null ? null : _deleteNote,
        body: _isLoading
            ? const NoteEditorSkeleton()
            : NoteEditorBody(
                titleController: _titleController,
                contentController: _contentController,
                saveState: _saveState,
                sharedWithEmails: _sharedWithEmails,
                sharedWithIds: _sharedWithIds,
                lastEdited: _lastEdited,
                onShare: _isSaving ? null : _shareNote,
              ),
      ),
    );
  }
}
