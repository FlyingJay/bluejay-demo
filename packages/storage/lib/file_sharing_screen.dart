import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:shared_services/active_group_service.dart';
import 'package:shared_services/client_view_switch.dart';
import 'package:shared_services/member_identity.dart';
import 'package:shared_services/notification_service.dart';
import 'package:shared_services/portal_clients.dart';
import 'package:shared_services/public_collection.dart';
import 'package:shared_services/scoped_collection.dart';
import 'package:shared_services/scoped_storage.dart';
import 'package:shared_services/service_locator.dart';
import 'package:shared_services/user_facing_error.dart';
import 'package:shared_ui/client_picker.dart';
import 'package:shared_ui/user_search_screen.dart';

import 'constants.dart';
import 'src/folders.dart';
import 'src/models.dart';
import 'src/storage_plan.dart';
import 'storage_client_view.dart';
import 'src/widgets/dialogs.dart';
import 'src/widgets/file_tab_body.dart';
import 'src/widgets/file_row.dart';
import 'src/widgets/folder_row.dart';
import 'src/widgets/storage_layout.dart';
import 'src/widgets/storage_plan_screen.dart';
import 'src/widgets/upload_button.dart';
import 'src/widgets/usage_card.dart';

export 'src/models.dart' show SharedFile, StorageUsageSummary;
import 'package:shared_services/group_docs.dart';
import 'package:shared_services/cloud_functions.dart';

final _files = ScopedCollection(
  collection: 'files',
  appId: APP_ID,
);
final _storageUsage = ScopedCollection(
  collection: 'storage_usage',
  appId: APP_ID,
);

final _notifications = NotificationService(appId: APP_ID);
final _filesStorage = ScopedStorage(
  folder: 'files',
  appId: APP_ID,
);
// Public files are published (the public namespace, D2): the server copies
// the file under published/ and writes its projection to public_files. A
// tenant file is never readable outside its group, whatever it says.
final _publicFiles = PublicCollection(source: 'files', appId: APP_ID);

/// Storage: the member screen, or a portal client's files
/// ([StorageClientScreen]).
class FileSharingScreen extends StatelessWidget {
  final fire_auth.User? currentUser;

  /// Open the Storage plan on start (the App settings screen's "Open
  /// Storage plan" link, functions/app_group_settings.json).
  final bool openSettingsOnStart;
  const FileSharingScreen({
    super.key,
    this.currentUser,
    this.openSettingsOnStart = false,
  });

  @override
  Widget build(BuildContext context) => ClientViewSwitch(
        member: (_) => FileSharingMemberScreen(
          currentUser: currentUser,
          openSettingsOnStart: openSettingsOnStart,
        ),
        client: (_) => StorageClientScreen(currentUser: currentUser),
      );
}

/// The member screen: public files, your files, files shared with you, and
/// (when the group's portal gives clients Storage) the files clients sent.
class FileSharingMemberScreen extends StatefulWidget {
  final fire_auth.User? currentUser;
  final bool openSettingsOnStart;
  const FileSharingMemberScreen({
    super.key,
    this.currentUser,
    this.openSettingsOnStart = false,
  });

  @override
  State<FileSharingMemberScreen> createState() => _FileSharingScreenState();
}

class _FileSharingScreenState extends State<FileSharingMemberScreen> {
  final _platformService = getPlatformService();
  final _functions = BluejayFunctions.instance;
  bool _isUploading = false;
  double _uploadProgress = 0.0;
  int _refreshKey = 0; // Key to trigger refresh

  // Cache tab widgets to prevent unnecessary rebuilds during upload
  Widget? _cachedPublicTab;
  Widget? _cachedMyFilesTab;
  Widget? _cachedSharedTab;
  int _lastPublicTabKey = -1;
  int _lastMyFilesTabKey = -1;
  int _lastSharedTabKey = -1;

  /// The folder open in My Files, and in Shared; null at the top level.
  /// New uploads and folders go into the one open in My Files.
  String? _myFolderId;
  String? _sharedFolderId;

  /// Each folder tab's query, kept while it browses its folders so
  /// opening one doesn't load the files again.
  final Map<String, (int, Future<QuerySnapshot<Map<String, dynamic>>>)> _queries = {};

  /// Your files as last loaded, for moving items and counting what a
  /// folder holds.
  FolderTree _myTree = FolderTree(const []);

  /// Whether the group's portal gives clients Storage: then files can be
  /// shared with clients, and the files they send get a tab.
  bool _portalGivesStorage = false;

  final _planService = const StoragePlanService();

  /// The group's Storage plan; null until loaded or if it can't be read.
  StoragePlanStatus? _plan;

  String get _groupId => ActiveGroupService.instance.activeGroupId ?? '';

  @override
  void initState() {
    super.initState();
    final groupDocId = ActiveGroupService.instance.activeGroupDocId ?? '';
    if (widget.currentUser != null) {
      portalGivesApp(groupDocId, APP_ID).then((on) {
        if (mounted && on != _portalGivesStorage) setState(() => _portalGivesStorage = on);
      });
      _loadPlan();
      if (widget.openSettingsOnStart) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _openPlan();
        });
      }
    }
  }

  Future<StoragePlanStatus?> _loadPlan() async {
    if (_groupId.isEmpty) return null;
    try {
      final plan = await _planService.status(_groupId);
      if (mounted) setState(() => _plan = plan);
      return plan;
    } catch (e) {
      debugPrint('Could not load the storage plan: $e');
      return null;
    }
  }

  Future<void> _openPlan() async {
    final groupId = _groupId;
    if (groupId.isEmpty) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => StoragePlanScreen(
        load: () => _planService.status(groupId),
        setPlan: (plan, price) => _planService.setPlan(groupId, plan,
            acceptedPricePerGbMonth: price),
      ),
    ));
    if (mounted) _loadPlan();
  }

  /// Whether the group's plan has room for [bytes] more. Fresh from the
  /// server; if the plan can't be read the upload goes ahead.
  Future<bool> _checkRoomFor(int bytes) async {
    final plan = await _loadPlan();
    if (plan == null || plan.allowsUpload(bytes) || !mounted) return true;
    final free = formatGb(plan.freeTierGb);
    final message = plan.canManage
        ? 'This file would take the group past its free $free. Delete '
            'files, or turn on pay as you go to store more.'
        : 'This file would take the group past its free $free. Ask a '
            'group admin to free up space or turn on pay as you go.';
    final openPlan = await showBjConfirm(
      context,
      title: 'Not enough storage',
      icon: Icons.cloud_off_rounded,
      message: message,
      confirmLabel: 'See storage plan',
      cancelLabel: 'Close',
    );
    if (openPlan && mounted) await _openPlan();
    return false;
  }

  /// Saves the file's doc and, for a public file, publishes it. The tenant
  /// doc never stores a token URL: a public file's link is its published
  /// copy's.
  Future<void> _saveFileMetadataToFirestore({
    required String storagePath,
    required String fileName,
    required int size,
    required bool isPublic,
    String? displayName,
    String? parentId,
  }) async {
    final user = widget.currentUser;
    if (user == null) return;

    final ref = await _files.add({
      // In a folder, it is shared with whoever the folder is
      // (onStorageFolderItemWritten).
      if (parentId != null) 'parentId': parentId,
      'downloadUrl': '',
      'storagePath': storagePath,
      'fileName': fileName,
      'userId': user.uid,
      'userEmail': user.email,
      'size': size,
      'createdAt': Timestamp.now(),
      'isPublic': isPublic,
      'sharedWithIds': [],
      'sharedWithEmails': [],
      if (displayName != null) 'displayName': displayName,
    });
    if (isPublic) await _publicFiles.publish(ref.id);
  }

  /// The published copy's URL for a public file: read under the rules
  /// (published/, any signed-in user). A file from My Files looks up its
  /// projection first.
  Future<String> _publishedUrl(SharedFile file) async {
    var path = file.isPublishedCopy ? file.storagePath : '';
    if (path.isEmpty) {
      final groupId = ActiveGroupService.instance.activeGroupId ?? '';
      final snap = await _publicFiles.doc(groupId, file.id).get();
      path = (snap.data()?['storagePath'] as String?) ?? '';
    }
    if (!ScopedStorage.isPublishedPath(path)) {
      throw Exception('This file isn\'t published yet. Try again in a moment.');
    }
    return ScopedStorage.published(path).getDownloadURL();
  }

  Future<void> _downloadFile(SharedFile file) async {
    try {
      if (!mounted) return;
      final fileName = file.displayName ?? file.fileName;
      if (file.isPublishedCopy) {
        final downloadUrl = await _publishedUrl(file);
        if (!mounted) return;
        await _platformService.downloadFile(context, downloadUrl, fileName);
        return;
      }

      final user = widget.currentUser;
      if (user == null) {
        throw Exception('You must be logged in to download private files.');
      }

      final idToken = await user.getIdToken();
      if (idToken == null || idToken.isEmpty) {
        throw Exception('Could not authenticate the download request.');
      }
      if (!mounted) return;
      await _platformService.downloadAuthenticatedFile(
        context,
        _privateDownloadUri(file.id),
        fileName,
        headers: {'Authorization': 'Bearer $idToken'},
      );
    } catch (e) {
      if (!mounted) return;
      BjSnack.error(context, 'Failed to download file: $e');
    }
  }

  Future<void> _copyFileUrl(SharedFile file) async {
    try {
      if (!file.isPublic) {
        throw Exception(
          'Private files do not have a shareable URL. Download them from inside Bluejay.',
        );
      }
      final downloadUrl = await _publishedUrl(file);
      _platformService.copyToClipboard(downloadUrl);
      if (!mounted) return;
      BjSnack.success(
        context,
        file.isPublic
            ? 'Link copied to clipboard'
            : 'Temporary link copied to clipboard',
      );
    } catch (e) {
      if (!mounted) return;
      BjSnack.error(context, 'Failed to copy link: $e');
    }
  }

  // Direct to the function, not https://bluejay.gg/files/download: the
  // request carries the user's ID token, and Hosting's 60-second limit on
  // rewritten requests would cut off a large file mid-download.
  Uri _privateDownloadUri(String fileId) =>
      BluejayFunctions.functionUri('storageDownloadFile',
          query: {'fileId': fileId});

  void _showUploadSuccess() {
    if (mounted) {
      setState(() {
        _isUploading = false;
        _uploadProgress = 0.0;
        _refreshKey++; // Trigger refresh after upload
      });
      BjSnack.success(context, 'File uploaded');
      _loadPlan();
    }
  }

  void _refreshFiles() {
    setState(() {
      _refreshKey++; // Trigger refresh
    });
  }

  void _showUploadError(dynamic error) {
    if (mounted) {
      setState(() {
        _isUploading = false;
        _uploadProgress = 0.0;
      });
      BjSnack.error(context, 'Upload failed: $error');
    }
  }

  /// Who to share with: people in the group, or (when the portal gives
  /// clients Storage) one of the group's clients. Null when cancelled.
  Future<List<String>?> _pickRecipients(fire_auth.User user, SharedFile file) async {
    var withClient = false;
    if (_portalGivesStorage) {
      final choice = await showBjSheet<String>(
        context,
        title: 'Share with',
        builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
          BjListRow(
            leading: const BjIconWell(icon: Icons.people_alt_rounded),
            title: 'People in your group',
            onTap: () => Navigator.pop(ctx, 'members'),
          ),
          const SizedBox(height: BjSpace.sm),
          BjListRow(
            leading: const BjIconWell(icon: Icons.storefront_outlined),
            title: 'A client',
            subtitle: 'They see it on your client portal',
            onTap: () => Navigator.pop(ctx, 'client'),
          ),
        ]),
      );
      if (choice == null || !mounted) return null;
      withClient = choice == 'client';
    }
    if (withClient) {
      final groupId = ActiveGroupService.instance.activeGroupId ?? '';
      final client = await showClientPicker(
        context,
        title: 'Share with a client',
        excludeUids: file.sharedWithIds.toSet(),
        load: () => listPortalClientsForApp(groupId: groupId, appId: APP_ID),
      );
      return client == null ? null : [client.uid];
    }
    final selectedUsers = await Navigator.of(context).push<List<GroupMember>>(
      MaterialPageRoute(
        builder: (context) => UserSearchScreen(
          currentUser: user,
          multiSelect: true,
          excludeUserIds: [user.uid, ...file.sharedWithIds],
        ),
      ),
    );
    return selectedUsers?.map((member) => member.uid).toList();
  }

  Future<void> _shareFile(SharedFile file) async {
    final user = widget.currentUser;
    if (user == null) return;

    final picked = await _pickRecipients(user, file);

    if (picked != null && picked.isNotEmpty) {
      try {
        final newUserIds = picked;
        final updatedSharedWithIds = [...file.sharedWithIds, ...newUserIds];
        final callable = _functions.httpsCallable('storageShareFile');
        final response = await callable.call({
          'fileId': file.id,
          'userIds': updatedSharedWithIds,
        });
        final payload =
            (response.data as Map?)?.cast<String, dynamic>() ?? const {};
        final addedUserIds =
            (payload['addedUserIds'] as List<dynamic>? ?? const [])
                .cast<String>();
        if (addedUserIds.isEmpty) {
          if (mounted) {
            BjSnack.info(context, 'No new people were added');
          }
          return;
        }

        // Send notifications to new members
        final sharerName =
            await GroupMemberDirectory.instance.labelForUser(user);
        try {
          await _notifications.addForRecipients(addedUserIds, {
            'title': file.isFolder
                ? '$sharerName shared a folder with you'
                : '$sharerName shared a file with you',
            'body': file.name,
            'appName': 'File Storage',
            'context': {
              'fileId': file.id,
            },
          });
        } catch (e) {
          debugPrint('Failed to send notifications: $e');
        }

        if (mounted) {
          setState(() {
            _refreshKey++;
          });
          final who = addedUserIds.length == 1
              ? '1 person'
              : '${addedUserIds.length} people';
          BjSnack.success(
            context,
            file.isFolder
                ? 'Shared with $who, with everything in it'
                : 'Shared with $who',
          );
        }
      } on FirebaseFunctionsException catch (e) {
        if (mounted) {
          BjSnack.error(context, e.message ?? 'Failed to share file');
        }
      } catch (e) {
        if (mounted) {
          BjSnack.error(context, 'Failed to share file: $e');
        }
      }
    }
  }

  Future<void> _uploadFile() async {
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.isEmpty) return;

    final user = widget.currentUser;
    if (user == null || !mounted) return;
    // The folder open in My Files when the upload began.
    final folderId = _myFolderId;
    if (!await _checkRoomFor(result.files.single.size) || !mounted) return;

    // Ask for the file's name and who can see it.
    final details = await showUploadDetailsDialog(
      context,
      initialName: result.files.single.name.split('.').first,
      originalFileName: result.files.single.name,
    );
    if (details == null) return; // User cancelled
    final isPublic = details.isPublic;
    final fileName = details.name;

    if (fileName.trim().isEmpty) return; // Empty name

    final displayName = fileName.trim();

    final file = result.files.single;

    setState(() {
      _isUploading = true;
      _uploadProgress = 0.0;
    });

    try {
      final storageRef = _filesStorage.newRef(file.name);

      if (kIsWeb) {
        // Web platform with progress tracking
        final uploadTask = _filesStorage.putBytes(
          storageRef,
          file.bytes!,
        );

        // Listen to upload progress
        uploadTask.snapshotEvents.listen((TaskSnapshot snapshot) {
          if (mounted && snapshot.totalBytes > 0) {
            setState(() {
              _uploadProgress =
                  (snapshot.bytesTransferred / snapshot.totalBytes)
                      .clamp(0.0, 1.0);
            });
          }
        });

        await uploadTask;
      } else {
        // Mobile platform - use platform service
        await _platformService.uploadGenericFile(
          storageRef,
          file,
          metadata: _filesStorage.buildMetadata(),
        );
        // For mobile, show 100% after completion
        setState(() {
          _uploadProgress = 1.0;
        });
      }

      await _saveFileMetadataToFirestore(
        storagePath: storageRef.fullPath,
        fileName: file.name,
        size: file.size,
        isPublic: isPublic,
        displayName: displayName,
        parentId: folderId,
      );

      _showUploadSuccess();
    } catch (e) {
      _showUploadError(e);
    }
  }

  int _toNonNegativeInt(dynamic value) {
    final parsed = value is num ? value.toInt() : int.tryParse('$value') ?? 0;
    return parsed < 0 ? 0 : parsed;
  }

  StorageUsageSummary? _summaryFromUsageDoc(DocumentSnapshot doc) {
    if (!doc.exists) return null;
    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) return null;
    return StorageUsageSummary(
      totalBytes: _toNonNegativeInt(data['totalBytes']),
      totalFiles: _toNonNegativeInt(data['totalFiles']),
    );
  }

  Future<StorageUsageSummary> _loadUsageFromFiles({String? userId}) async {
    Query<Map<String, dynamic>> query = _files.query;
    if (userId != null) {
      query = query.where('userId', isEqualTo: userId);
    }
    final snapshot = await query.get();
    var totalBytes = 0;
    var totalFiles = 0;
    for (final doc in snapshot.docs) {
      if (doc.data()['isFolder'] == true) continue;
      totalBytes += _toNonNegativeInt(doc.data()['size']);
      totalFiles++;
    }
    return StorageUsageSummary(totalBytes: totalBytes, totalFiles: totalFiles);
  }

  Future<bool> _isCurrentUserGroupAdmin() async {
    final user = widget.currentUser;
    if (user == null) return false;
    final activeGroupId = ActiveGroupService.instance.activeGroupId;
    if (activeGroupId == null || activeGroupId.isEmpty) return false;

    final snapshot =
        await GroupDocs.withGroupIdField(activeGroupId, appId: APP_ID)
            .limit(1)
            .get();
    if (snapshot.docs.isEmpty) return false;
    final adminIds =
        List<String>.from(snapshot.docs.first.data()['adminIds'] ?? const []);
    return adminIds.contains(user.uid);
  }

  Widget _buildStorageUsageBanner() {
    final user = widget.currentUser;
    if (user == null) return const SizedBox.shrink();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _storageUsage.query
          .where('userId', isEqualTo: user.uid)
          .limit(1)
          .snapshots(),
      builder: (context, userUsageSnapshot) {
        final userUsageDoc = userUsageSnapshot.data?.docs.isNotEmpty == true
            ? userUsageSnapshot.data!.docs.first
            : null;
        final userSummaryFromDoc =
            userUsageDoc == null ? null : _summaryFromUsageDoc(userUsageDoc);

        return FutureBuilder<StorageUsageSummary>(
          future: userSummaryFromDoc == null
              ? _loadUsageFromFiles(userId: user.uid)
              : Future.value(userSummaryFromDoc),
          builder: (context, userSummarySnapshot) {
            final userSummary =
                userSummarySnapshot.data ?? StorageUsageSummary.zero;

            return FutureBuilder<bool>(
              future: _isCurrentUserGroupAdmin(),
              builder: (context, adminSnapshot) {
                final isGroupAdmin = adminSnapshot.data ?? false;
                if (!isGroupAdmin) {
                  return _buildUsageCard(userSummary: userSummary);
                }

                return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: _storageUsage.query
                      .where('kind', isEqualTo: 'group_total')
                      .limit(1)
                      .snapshots(),
                  builder: (context, groupUsageSnapshot) {
                    final groupUsageDoc =
                        groupUsageSnapshot.data?.docs.isNotEmpty == true
                            ? groupUsageSnapshot.data!.docs.first
                            : null;
                    final groupSummaryFromDoc = groupUsageDoc == null
                        ? null
                        : _summaryFromUsageDoc(groupUsageDoc);

                    return FutureBuilder<StorageUsageSummary>(
                      future: groupSummaryFromDoc == null
                          ? _loadUsageFromFiles()
                          : Future.value(groupSummaryFromDoc),
                      builder: (context, groupSummarySnapshot) {
                        final groupSummary = groupSummarySnapshot.data ??
                            StorageUsageSummary.zero;
                        return _buildUsageCard(
                          userSummary: userSummary,
                          groupSummary: groupSummary,
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildUsageCard({
    required StorageUsageSummary userSummary,
    StorageUsageSummary? groupSummary,
  }) =>
      StorageUsageCard(
        userSummary: userSummary,
        groupSummary: groupSummary,
        plan: _plan,
      );

  Future<void> _handlePullToRefresh() async {
    _refreshFiles();
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  Future<void> _confirmDeleteFile(SharedFile file) async {
    final confirm = await confirmDeleteFile(context, file);

    if (confirm != true) return;

    try {
      final callable = _functions.httpsCallable('storageDeleteFile');
      await callable.call({'fileId': file.id});

      if (mounted) {
        setState(() {
          _refreshKey++;
        });
        BjSnack.success(context, 'File deleted');
      }
    } catch (e) {
      if (mounted) {
        BjSnack.error(context, 'Failed to delete file: $e');
      }
    }
  }

  /// Opens [folderId] in My Files (null for the top level).
  void _openMyFolder(String? folderId) => setState(() {
        _myFolderId = folderId;
        _cachedMyFilesTab = null;
      });

  /// Opens [folderId] in Shared (null for the top level).
  void _openSharedFolder(String? folderId) => setState(() {
        _sharedFolderId = folderId;
        _cachedSharedTab = null;
      });

  /// Makes a folder in the one open in My Files.
  Future<void> _createFolder() async {
    final user = widget.currentUser;
    if (user == null) return;
    final name = await showFolderNameDialog(context);
    if (name == null || !mounted) return;
    final parentId = _myFolderId;
    try {
      await _files.add({
        'isFolder': true,
        'downloadUrl': '',
        'storagePath': '',
        'fileName': name,
        'displayName': name,
        'userId': user.uid,
        'userEmail': user.email,
        'size': 0,
        'createdAt': Timestamp.now(),
        'isPublic': false,
        'sharedWithIds': [],
        'sharedWithEmails': [],
        if (parentId != null) 'parentId': parentId,
      });
      if (!mounted) return;
      _refreshFiles();
      BjSnack.success(context, 'Folder "$name" created');
    } catch (e) {
      if (mounted) BjSnack.error(context, userFacingError(e, fallback: 'Couldn\'t create the folder.'));
    }
  }

  Future<void> _renameFolder(SharedFile folder) async {
    final name = await showFolderNameDialog(context, initialName: folder.name);
    if (name == null || name == folder.name || !mounted) return;
    try {
      await _files.update(_files.doc(folder.id), {'displayName': name, 'fileName': name});
      if (mounted) _refreshFiles();
    } catch (e) {
      if (mounted) BjSnack.error(context, userFacingError(e, fallback: 'Couldn\'t rename the folder.'));
    }
  }

  /// Moves [item] into another of your folders, or to the top level. A
  /// move into a shared folder shares it too (onStorageFolderItemWritten).
  Future<void> _moveItem(SharedFile item) async {
    final tree = _myTree;
    final target = await showMoveToFolderSheet(
      context,
      itemName: item.name,
      targets: tree.moveTargets(item),
      pathOf: (f) => tree.pathLabel(f.id),
      atTopLevel: tree.shownIn(item) == null,
    );
    if (target == null || !mounted) return;
    try {
      await _files.update(_files.doc(item.id), {
        'parentId': target.isEmpty ? FieldValue.delete() : target,
      });
      if (!mounted) return;
      _refreshFiles();
      BjSnack.success(
          context, 'Moved to ${target.isEmpty ? 'Your files' : tree.pathLabel(target)}');
    } catch (e) {
      if (mounted) BjSnack.error(context, userFacingError(e, fallback: 'Couldn\'t move it.'));
    }
  }

  Future<void> _confirmDeleteFolder(SharedFile folder) async {
    final inside = _myTree.descendantsOf(folder.id);
    if (!await confirmDeleteFolder(context, folder, inside.length)) return;
    try {
      await _functions.httpsCallable('storageDeleteFile').call({'fileId': folder.id});
      if (!mounted) return;
      setState(() {
        // Out of the folder if it, or one inside it, was open.
        if (_myFolderId == folder.id || inside.any((i) => i.id == _myFolderId)) {
          _myFolderId = _myTree.shownIn(folder);
        }
        _refreshKey++;
      });
      BjSnack.success(context, 'Folder deleted');
      _loadPlan();
    } catch (e) {
      if (mounted) BjSnack.error(context, userFacingError(e, fallback: 'Couldn\'t delete the folder.'));
    }
  }

  /// [key]'s query, made once for each refresh.
  Future<QuerySnapshot<Map<String, dynamic>>> _query(
      String key, Future<QuerySnapshot<Map<String, dynamic>>> Function() make) {
    final cached = _queries[key];
    if (cached != null && cached.$1 == _refreshKey) return cached.$2;
    final future = make();
    _queries[key] = (_refreshKey, future);
    return future;
  }

  /// A tab of files kept in folders: what the open folder holds, under a
  /// bar showing where it is.
  Widget _buildFolderTab({
    required String keyPrefix,
    required Future<QuerySnapshot<Map<String, dynamic>>> future,
    required String? folderId,
    required ValueChanged<String?> onOpen,
    required String rootLabel,
    required String title,
    required String subtitle,
    required String emptyMessage,
    required IconData emptyIcon,
    required bool showSharer,
    Widget? emptyAction,
    VoidCallback? onNewFolder,
    ValueChanged<FolderTree>? onTree,
  }) {
    return FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
      key: ValueKey('${keyPrefix}_$_refreshKey'),
      future: future,
      builder: (context, snapshot) {
        List<SharedFile>? items;
        var tree = FolderTree(const []);
        if (!snapshot.hasError &&
            snapshot.connectionState != ConnectionState.waiting &&
            snapshot.hasData) {
          tree = FolderTree(snapshot.data!.docs.map(SharedFile.fromFirestore));
          onTree?.call(tree);
        }
        // A folder that has gone shows the top level.
        final open = tree[folderId]?.isFolder == true ? folderId : null;
        if (snapshot.hasData) items = tree.childrenOf(open);
        final folder = tree[open];
        return FileTabBody(
          files: items,
          error: snapshot.error,
          onRefresh: _handlePullToRefresh,
          header: FolderBar(
            rootLabel: rootLabel,
            path: tree.pathTo(open),
            onOpen: onOpen,
            onNewFolder: onNewFolder,
          ),
          title: folder?.name ?? title,
          subtitle: folder == null ? subtitle : 'Folders first, then files newest first',
          emptyMessage: folder == null ? emptyMessage : 'This folder is empty.',
          emptyIcon: folder == null ? emptyIcon : Icons.folder_open_rounded,
          emptyAction: emptyAction,
          rowBuilder: (item) => item.isFolder
              ? _buildFolderRow(item, tree, onOpen: onOpen, showSharer: showSharer)
              : _buildFileCard(item, showSharer: showSharer, canMove: onNewFolder != null),
        );
      },
    );
  }

  Widget _buildFolderRow(SharedFile folder, FolderTree tree,
      {required ValueChanged<String?> onOpen, required bool showSharer}) {
    final isOwner = widget.currentUser?.uid == folder.userId;
    return FolderRow(
      key: ValueKey(folder.id),
      folder: folder,
      itemCount: tree.childrenOf(folder.id).length,
      isOwner: isOwner,
      showSharer: showSharer,
      actions: FolderRowActions(
        onOpen: () => onOpen(folder.id),
        onRename: () => _renameFolder(folder),
        onMove: () => _moveItem(folder),
        onShare: () => _shareFile(folder),
        onDelete: () => _confirmDeleteFolder(folder),
      ),
    );
  }

  Widget _buildFilesTab({
    required String keyPrefix,
    required Future<QuerySnapshot<Map<String, dynamic>>> future,
    SharedFile Function(DocumentSnapshot<Map<String, dynamic>> doc) toFile =
        SharedFile.fromFirestore,
    int Function(SharedFile a, SharedFile b)? sort,
    required String emptyMessage,
    required bool showSharer,
    required bool requireLogin,
    required String loginMessage,
    required String title,
    String? subtitle,
    IconData emptyIcon = Icons.folder_open_rounded,
    Widget? emptyAction,
  }) {
    if (requireLogin && widget.currentUser == null) {
      return _signInRequired(loginMessage);
    }

    return FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
      key: ValueKey('${keyPrefix}_$_refreshKey'),
      future: future,
      builder: (context, snapshot) {
        List<SharedFile>? files;
        if (!snapshot.hasError &&
            snapshot.connectionState != ConnectionState.waiting &&
            snapshot.hasData) {
          files = snapshot.data!.docs.map(toFile).toList();
          if (sort != null) files.sort(sort);
        }
        return FileTabBody(
          files: files,
          error: snapshot.error,
          onRefresh: _handlePullToRefresh,
          title: title,
          subtitle: subtitle,
          emptyMessage: emptyMessage,
          emptyIcon: emptyIcon,
          emptyAction: emptyAction,
          rowBuilder: (file) => _buildFileCard(file, showSharer: showSharer),
        );
      },
    );
  }

  Widget _signInRequired(String message) => BjStateView.locked(
        title: 'Sign in required',
        message: message,
      );

  @override
  Widget build(BuildContext context) {
    final isLoggedIn = widget.currentUser != null;

    final withClients = isLoggedIn && _portalGivesStorage;
    return DefaultTabController(
      key: ValueKey('storage-tabs-$withClients'),
      length: withClients ? 4 : 3,
      child: StorageLayout(
        onRefresh: () {
          _refreshFiles();
          _loadPlan();
        },
        onOpenPlan: isLoggedIn ? _openPlan : null,
        usage: isLoggedIn ? _buildStorageUsageBanner() : null,
        labels: withClients ? StorageLayout.tabLabelsWithClients : StorageLayout.tabLabels,
        tabs: [
          _getCachedPublicFilesTab(),
          _getCachedMyFilesTab(),
          _getCachedSharedTab(),
          if (withClients) _buildFromClientsTab(),
        ],
        uploadButton: isLoggedIn
            ? UploadButton(
                isUploading: _isUploading,
                progress: _uploadProgress,
                onPressed: _uploadFile,
              )
            : null,
      ),
    );
  }

  Widget _getCachedPublicFilesTab() {
    if (_cachedPublicTab == null || _lastPublicTabKey != _refreshKey) {
      _lastPublicTabKey = _refreshKey;
      _cachedPublicTab = _buildPublicFilesTab();
    }
    return _cachedPublicTab!;
  }

  Widget _getCachedMyFilesTab() {
    if (_cachedMyFilesTab == null || _lastMyFilesTabKey != _refreshKey) {
      _lastMyFilesTabKey = _refreshKey;
      _cachedMyFilesTab = _buildMyFilesTab();
    }
    return _cachedMyFilesTab!;
  }

  Widget _getCachedSharedTab() {
    if (_cachedSharedTab == null || _lastSharedTabKey != _refreshKey) {
      _lastSharedTabKey = _refreshKey;
      _cachedSharedTab = _buildSharedTab();
    }
    return _cachedSharedTab!;
  }

  Widget _buildPublicFilesTab() {
    return _buildFilesTab(
      keyPrefix: 'public',
      // The group's published files, newest first (sorted here: no index).
      future: _publicFiles
          .whereSourceGroup(ActiveGroupService.instance.activeGroupId ?? '')
          .get(),
      toFile: SharedFile.fromPublished,
      sort: (a, b) => b.createdAt.compareTo(a.createdAt),
      emptyMessage: 'No public files have been shared yet.',
      title: 'Public files',
      subtitle: 'Published by your group, newest first',
      emptyIcon: Icons.public_rounded,
      showSharer: false,
      requireLogin: false,
      loginMessage: '',
    );
  }

  Widget _buildMyFilesTab() {
    final user = widget.currentUser;
    if (user == null) {
      return _signInRequired('Sign in to view your files.');
    }
    return _buildFolderTab(
      keyPrefix: 'myfiles',
      future: _query(
          'myfiles',
          () => _files.query
              .where('userId', isEqualTo: user.uid)
              .orderBy('createdAt', descending: true)
              .get()),
      folderId: _myFolderId,
      onOpen: _openMyFolder,
      onNewFolder: _createFolder,
      onTree: (tree) => _myTree = tree,
      rootLabel: 'Your files',
      emptyMessage: 'You have not uploaded any files yet.',
      title: 'Your files',
      subtitle: 'Folders first, then files newest first',
      emptyIcon: Icons.cloud_upload_rounded,
      emptyAction: FilledButton.icon(
        onPressed: _isUploading ? null : _uploadFile,
        icon: const Icon(Icons.upload_rounded, size: 18),
        label: const Text('Upload a file'),
      ),
      showSharer: false,
    );
  }

  Widget _buildSharedTab() {
    final user = widget.currentUser;
    if (user == null) {
      return _signInRequired('Sign in to view files shared with you.');
    }
    // A shared folder brings everything in it (onStorageFolderItemWritten),
    // so its contents list under it here.
    return _buildFolderTab(
      keyPrefix: 'shared',
      future: _query(
          'shared',
          () => _files.query
              .where('sharedWithIds', arrayContains: user.uid)
              .orderBy('createdAt', descending: true)
              .get()),
      folderId: _sharedFolderId,
      onOpen: _openSharedFolder,
      rootLabel: 'Shared with you',
      emptyMessage: 'No one has shared a file with you yet.',
      title: 'Shared with you',
      subtitle: 'Folders first, then files newest first',
      emptyIcon: Icons.people_alt_rounded,
      showSharer: true,
    );
  }

  /// Files the group's portal clients sent (storageRegisterClientUpload),
  /// newest first (sorted here: no index).
  Widget _buildFromClientsTab() {
    return _buildFilesTab(
      keyPrefix: 'fromclients',
      future: _files.query.where('fromClient', isEqualTo: true).get(),
      sort: (a, b) => b.createdAt.compareTo(a.createdAt),
      emptyMessage: 'Files your clients send from the portal appear here.',
      title: 'From clients',
      subtitle: 'Sent from your client portal, newest first',
      emptyIcon: Icons.storefront_outlined,
      showSharer: true,
      requireLogin: true,
      loginMessage: 'Sign in to view files from clients.',
    );
  }

  Widget _buildFileCard(SharedFile file, {required bool showSharer, bool canMove = false}) {
    return FileRow(
      key: ValueKey(file.id),
      file: file,
      isOwner: widget.currentUser?.uid == file.userId,
      showSharer: showSharer,
      actions: FileRowActions(
        onOpen: () => _showFileInfoDialog(file),
        onDownload: () => _downloadFile(file),
        onCopyLink: () => _copyFileUrl(file),
        onShare: () => _shareFile(file),
        onDelete: () => _confirmDeleteFile(file),
        onMove: canMove ? () => _moveItem(file) : null,
      ),
    );
  }

  void _showFileInfoDialog(SharedFile file) {
    showFileDetailsDialog(
      context,
      file: file,
      onCopyLink: () => _copyFileUrl(file),
      onDownload: () => _downloadFile(file),
    );
  }
}
