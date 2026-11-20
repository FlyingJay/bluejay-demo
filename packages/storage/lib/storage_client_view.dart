import 'package:bluejay_design/bluejay_design.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_services/active_group_service.dart';
import 'package:shared_services/cloud_functions.dart';
import 'package:shared_services/mime_type_helper.dart';
import 'package:shared_services/portal_cards.dart';
import 'package:shared_services/scoped_collection.dart';
import 'package:shared_services/scoped_storage.dart';
import 'package:shared_services/service_locator.dart';

import 'constants.dart';
import 'src/file_kind.dart';
import 'src/format.dart';
import 'src/models.dart';

final _files = ScopedCollection(collection: 'files', appId: APP_ID);

/// Where a portal client's uploads go: their own files in the group's
/// `client_uploads` folder (security/storage_paths.json guestWritableFolders).
final _clientUploads = ScopedStorage(folder: 'client_uploads', appId: APP_ID);

/// The largest file a client may send (security/storage_paths.json
/// guestUploadLimits.storage).
const int kClientUploadMaxBytes = 25 * 1024 * 1024;

/// Why the Storage rules would refuse [fileName] of [size] bytes from a
/// client (guestUploadLimits: size, and images, PDFs, text and Office
/// documents), or null. Pure.
String? clientUploadProblem(String fileName, int size) {
  if (size > kClientUploadMaxBytes) return 'Files can be up to 25 MB.';
  final type = MimeTypeHelper.detect(fileName);
  final accepted = type.startsWith('image/') ||
      type == 'application/pdf' ||
      type == 'text/plain' ||
      type == 'text/csv' ||
      type == 'application/msword' ||
      type == 'application/vnd.ms-excel' ||
      type.startsWith('application/vnd.openxmlformats-officedocument.');
  return accepted ? null : 'Send a photo, PDF, text or Office document.';
}

/// How long a file shared with a client counts as new on their portal home.
const Duration kNewFileWindow = Duration(days: 14);

/// The files shared with [uid] (not their own uploads) created after
/// [now] - [window]. Pure.
int newSharedFileCount(Iterable<SharedFile> files, String uid, DateTime now,
    {Duration window = kNewFileWindow}) {
  final since = now.subtract(window);
  return files
      .where((f) => f.clientUploaderUid != uid && f.createdAt.toDate().isAfter(since))
      .length;
}

/// The client's files in the active group: shared with them, or uploaded by
/// them (the doc's clientUids names them; ScopedCollection.queryAsClient).
Future<List<SharedFile>> loadClientFiles() async {
  final snap = await _files.queryAsClient().get();
  // A shared folder's files come on their own; the folder isn't a file.
  final files = snap.docs.map(SharedFile.fromFirestore).where((f) => !f.isFolder).toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return files;
}

/// Storage for a portal client of the active group
/// (plans/business-suite/CLIENT_PORTAL_PLAN.md, Phase C): the files the
/// business shared with them, and their uploads to the business.
class StorageClientScreen extends StatefulWidget {
  const StorageClientScreen({super.key, required this.currentUser});

  final fire_auth.User? currentUser;

  @override
  State<StorageClientScreen> createState() => _StorageClientScreenState();
}

class _StorageClientScreenState extends State<StorageClientScreen> {
  late Future<List<SharedFile>> _files = loadClientFiles();
  bool _uploading = false;
  double _progress = 0;

  void _reload() => setState(() => _files = loadClientFiles());

  Future<void> _download(SharedFile file) async {
    final user = widget.currentUser;
    if (user == null) return;
    try {
      final token = await user.getIdToken();
      if (!mounted || token == null) return;
      await getPlatformService().downloadAuthenticatedFile(
        context,
        BluejayFunctions.functionUri('storageDownloadFile', query: {'fileId': file.id}),
        file.displayName ?? file.fileName,
        headers: {'Authorization': 'Bearer $token'},
      );
    } catch (e) {
      if (mounted) BjSnack.error(context, 'Couldn\'t download the file: $e');
    }
  }

  Future<void> _upload() async {
    final picked = await FilePicker.platform.pickFiles(withData: kIsWeb);
    if (picked == null || picked.files.isEmpty || !mounted) return;
    final file = picked.files.single;
    final problem = clientUploadProblem(file.name, file.size);
    if (problem != null) {
      BjSnack.error(context, problem);
      return;
    }
    setState(() {
      _uploading = true;
      _progress = 0;
    });
    try {
      final ref = _clientUploads.newRef(file.name);
      // The Storage rules accept only some types and sizes from clients
      // (security/storage_paths.json guestUploadLimits), checked on the
      // content type sent with the upload.
      final contentType = MimeTypeHelper.detect(file.name);
      if (kIsWeb) {
        final task = _clientUploads.putBytes(ref, file.bytes!, contentType: contentType);
        task.snapshotEvents.listen((TaskSnapshot s) {
          if (mounted && s.totalBytes > 0) {
            setState(() => _progress = (s.bytesTransferred / s.totalBytes).clamp(0.0, 1.0));
          }
        });
        await task;
      } else {
        await getPlatformService().uploadGenericFile(ref, file,
            metadata: _clientUploads.buildMetadata(contentType: contentType));
      }
      // The client can't write a files doc; the server registers the upload.
      await BluejayFunctions.instance.httpsCallable('storageRegisterClientUpload').call({
        'groupId': ActiveGroupService.instance.activeGroupId,
        'storagePath': ref.fullPath,
        'fileName': file.name,
      });
      if (!mounted) return;
      BjSnack.success(context, 'File sent');
      _reload();
    } on FirebaseFunctionsException catch (e) {
      if (mounted) BjSnack.error(context, e.message ?? 'Upload failed.');
    } catch (e) {
      if (mounted) BjSnack.error(context, 'Upload failed: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<SharedFile>>(
      future: _files,
      builder: (context, snap) => StorageClientView(
        uid: widget.currentUser?.uid ?? '',
        businessName: ActiveGroupService.instance.activeGroupDocumentName ?? '',
        files: snap.hasData ? snap.data : null,
        error: snap.error,
        uploading: _uploading,
        progress: _progress,
        onUpload: _upload,
        onDownload: _download,
        onRefresh: _reload,
      ),
    );
  }
}

/// The client's Files page: what the business shared with them and what
/// they sent it. [files] null while loading.
class StorageClientView extends StatelessWidget {
  const StorageClientView({
    super.key,
    required this.uid,
    required this.businessName,
    required this.files,
    required this.onUpload,
    required this.onDownload,
    required this.onRefresh,
    this.error,
    this.uploading = false,
    this.progress = 0,
  });

  final String uid;
  final String businessName;
  final List<SharedFile>? files;
  final Object? error;
  final bool uploading;
  final double progress;
  final VoidCallback onUpload;
  final ValueChanged<SharedFile> onDownload;
  final VoidCallback onRefresh;

  String get _business => businessName.isEmpty ? 'the business' : businessName;

  Widget _row(SharedFile f) => Padding(
        padding: const EdgeInsets.only(bottom: BjSpace.sm),
        child: BjListRow(
          key: ValueKey('client-file-${f.id}'),
          leading: FileKindIcon(kind: FileKind.fromName(f.fileName)),
          title: f.displayName ?? f.fileName,
          subtitle: '${formatBytes(f.size)} · ${formatDateShort(f.createdAt.toDate())}',
          trailing: IconButton(
            icon: const Icon(Icons.download_rounded),
            tooltip: 'Download',
            onPressed: () => onDownload(f),
          ),
          onTap: () => onDownload(f),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final list = files;
    final Widget body;
    if (error != null) {
      body = BjStateView.error(title: 'Couldn\'t load your files', error: error, onRetry: onRefresh);
    } else if (list == null) {
      body = const BjSkeletonList(count: 4);
    } else {
      final shared = list.where((f) => f.clientUploaderUid != uid).toList();
      final mine = list.where((f) => f.clientUploaderUid == uid).toList();
      body = ListView(padding: const EdgeInsets.all(BjSpace.md), children: [
        BjSectionHeader(title: 'Shared with you', count: shared.length),
        const SizedBox(height: BjSpace.sm),
        if (shared.isEmpty)
          BjStateView.empty(
            icon: Icons.folder_shared_outlined,
            title: 'Nothing shared yet',
            message: 'Files $_business shares with you appear here.',
            compact: true,
          )
        else
          ...shared.map(_row),
        const SizedBox(height: BjSpace.lg),
        BjSectionHeader(title: 'Sent by you', count: mine.length),
        const SizedBox(height: BjSpace.sm),
        if (mine.isEmpty)
          BjStateView.empty(
            icon: Icons.upload_file_outlined,
            title: 'Nothing sent yet',
            message: 'Upload a file to send it to $_business.',
            compact: true,
          )
        else
          ...mine.map(_row),
        const SizedBox(height: 96),
      ]);
    }
    return BjPage(
      title: 'Files',
      actions: [
        IconButton(icon: const Icon(Icons.refresh_rounded), tooltip: 'Refresh', onPressed: onRefresh),
      ],
      floatingActionButton: BjProgressFab(
        icon: Icons.upload_rounded,
        label: 'Upload',
        tooltip: 'Send a file to $_business',
        busy: uploading,
        progress: progress,
        busyLabel: (percent) => 'Uploading $percent%',
        onPressed: onUpload,
      ),
      body: BjContent(maxWidth: BjBreakpoint.formWidth, child: body),
    );
  }
}

/// The portal home card for Files: files shared in the last two weeks.
Widget? buildStoragePortalCard(BuildContext context, PortalCardContext card) =>
    StoragePortalCard(card: card);

/// Files' card on a client's portal home (lib/routing/portal_cards.dart
/// registers it).
const PortalCard storagePortalCard =
    PortalCard(appId: APP_ID, build: buildStoragePortalCard);

class StoragePortalCard extends StatefulWidget {
  const StoragePortalCard({super.key, required this.card, this.loadFiles, this.now});

  final PortalCardContext card;

  /// Overrides [loadClientFiles] (tests).
  final Future<List<SharedFile>> Function()? loadFiles;
  final DateTime? now;

  @override
  State<StoragePortalCard> createState() => _StoragePortalCardState();
}

class _StoragePortalCardState extends State<StoragePortalCard> {
  late final Future<List<SharedFile>> _files = (widget.loadFiles ?? loadClientFiles)();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<SharedFile>>(
      future: _files,
      builder: (context, snap) {
        if (!snap.hasData) return const SizedBox.shrink();
        final n = newSharedFileCount(snap.data!, widget.card.uid, widget.now ?? DateTime.now());
        return BjStatTile(
          label: 'New files',
          value: '$n',
          icon: Icons.folder_shared_outlined,
          caption: n == 0 ? 'Nothing new in the last two weeks' : 'Shared with you in the last two weeks',
          tone: n == 0 ? BjTone.neutral : BjTone.accent,
          onTap: widget.card.onOpenApp,
        );
      },
    );
  }
}
