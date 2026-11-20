import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:uuid/uuid.dart';

import 'active_group_service.dart';

/// A scoped wrapper around a Firebase Storage folder that automatically applies
/// multi-tenant access controls, mirroring [ScopedCollection] for Firestore.
///
/// Every package that reads or writes tenant-scoped files should create one
/// instance of this class (typically as a file-level or class-level constant)
/// instead of calling [FirebaseStorage.instance.ref()] directly.
///
/// Files are stored at:
/// ```
/// groups/{groupId}/apps/{appId}/{folder}/{path}
/// ```
///
/// **Uploading (bytes)**
///
/// Use [upload] to upload raw bytes with auto-injected permission metadata:
///
/// ```dart
/// final _photos = ScopedStorage(folder: 'gallery_photos', appId: APP_ID);
///
/// // Upload bytes — creatorId, groupId, appId injected automatically:
/// final ref = await _photos.upload('photo.jpg', bytes,
///     contentType: 'image/jpeg');
/// final url = await ref.getDownloadURL();
/// ```
///
/// **Uploading via PlatformService**
///
/// When using [PlatformService.uploadImageFile] (for mobile efficiency), obtain
/// a [Reference] and metadata separately:
///
/// ```dart
/// final ref = _photos.newRef('photo.jpg');
/// final meta = _photos.buildMetadata(contentType: 'image/jpeg');
/// await platformService.uploadImageFile(ref, image, metadata: meta);
/// ```
///
/// **Reading / deleting**
///
/// Use [ref] to obtain a [Reference] to an existing file by path:
///
/// ```dart
/// await _photos.ref(knownPath).delete();
/// final url = await _photos.ref(knownPath).getDownloadURL();
/// ```
///
/// **Listing**
///
/// Use [list] to enumerate all files in this app's folder for the active group
/// (analogous to [ScopedCollection.query]):
///
/// ```dart
/// final result = await _photos.list();
/// for (final item in result.items) { ... }
/// ```
///
/// **Platform-level paths**
///
/// A few platform features predate per-group folders and keep their fixed
/// paths (`profile_pictures/`, `app_icons/`, `groups/{groupId}/logo.jpg`).
/// [ScopedStorage.platform] gives those the same metadata-stamped uploads
/// without moving them:
///
/// ```dart
/// final _icons = ScopedStorage.platform(root: 'app_icons', appId: 'app-manager');
/// ```
///
/// **Published files** (the public namespace, plans/firestore-rules §2.7, D2)
///
/// No file under `groups/` is readable outside its group. A file other
/// groups must read is published: the server (the `publicPublish` callable,
/// see [PublicCollection]) copies it to `published/{groupId}/{appId}/…`,
/// which any signed-in user may read and no client may write. Read it with
/// [ScopedStorage.published]:
///
/// ```dart
/// final url = await ScopedStorage.published(doc.data['storagePath']).getDownloadURL();
/// ```
///
/// **This is the only way to reach Firebase Storage.** Every upload carries
/// `creatorId`/`groupId`/`appId` metadata, which Usage Meter uses to attribute
/// stored bytes (functions/usage_storage.js). `scripts/check_gateways.js`
/// fails CI on `FirebaseStorage.instance` or a raw `putData`/`putFile`
/// outside this file and the PlatformService implementations; use [ref],
/// [refForPath] or [refFromURL] for reads
/// and deletes, and [upload], [putBytes] or [PlatformService] for writes.
class ScopedStorage {
  /// The folder name within this app's storage namespace
  /// (e.g. `'gallery_photos'`, `'recipe_photos'`).
  final String folder;

  /// The app ID registered in `apps/{appId}` that owns this folder.
  ///
  /// Combined with [ActiveGroupService.activeGroupId] to form the permission
  /// scope string (`groupId:appId`) checked by the Storage security rules.
  final String appId;

  /// Sentinel value used when no group is active, ensuring the path is
  /// unreachable rather than leaking cross-group data.
  static const String _noActiveGroupSentinel = '__no_active_group__';

  /// For [ScopedStorage.platform]: the fixed root path, used as-is.
  final String? _platformRoot;

  /// For [ScopedStorage.platform]: the group stamped into metadata
  /// (`null` = platform-wide, no group).
  final String? _platformGroupId;

  ScopedStorage({required this.folder, required this.appId})
      : _platformRoot = null,
        _platformGroupId = null;

  /// Files under a fixed platform-level [root] path (e.g. `'profile_pictures'`
  /// or `'groups/$groupId'`) rather than the active group's app folder.
  ///
  /// Storage rules for these paths are keyed on the path itself, so this
  /// only adds metadata: `creatorId`, `appId`, and [groupId] — the group the
  /// file belongs to, or, when null, [platformNoGroupId] for platform-wide
  /// files like profile pictures.
  ScopedStorage.platform({
    required String root,
    required this.appId,
    String? groupId,
  })  : folder = root,
        _platformRoot = root,
        _platformGroupId = groupId;

  /// The `groupId` metadata value a [ScopedStorage.platform] with no group
  /// stamps: an explicit "belongs to no group", distinct from a missing
  /// group (which [requireUploadMetadata] rejects). Matches Usage Meter's
  /// no-group id (functions/_usage.js NO_GROUP_ID).
  static const String platformNoGroupId = '~none';

  String get _groupId => _platformRoot != null
      ? (_platformGroupId ?? platformNoGroupId)
      : (ActiveGroupService.instance.activeGroupId ?? '');
  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  /// Base [Reference] for this storage's folder.
  ///
  /// Path: `groups/{groupId}/apps/{appId}/{folder}` (active group), or the
  /// fixed root of a [ScopedStorage.platform].
  Reference get _base {
    final root = _platformRoot;
    if (root != null) return FirebaseStorage.instance.ref(root);
    final gid = _groupId.isEmpty ? _noActiveGroupSentinel : _groupId;
    return FirebaseStorage.instance.ref('groups/$gid/apps/$appId/$folder');
  }

  /// A [Reference] to an existing object by its full path (e.g. a
  /// `storagePath` saved on a Firestore doc), for reads and deletes.
  static Reference refForPath(String fullPath) =>
      FirebaseStorage.instance.ref(fullPath);

  /// A [Reference] to an existing object from its download URL, for reads
  /// and deletes.
  static Reference refFromURL(String url) =>
      FirebaseStorage.instance.refFromURL(url);

  /// The prefix of the public namespace in Storage (D2).
  static const String publishedRoot = 'published';

  /// A read-only [Reference] to a published file (a path under
  /// `published/`, e.g. a [PublicCollection] doc's file field). Any
  /// signed-in user may read it (storage.rules' `published` family); only
  /// the server writes or deletes it. Throws [ArgumentError] for any other
  /// path, so a tenant path can't be passed off as a published one.
  static Reference published(String path) {
    final p = path.trim();
    if (!isPublishedPath(p)) {
      throw ArgumentError.value(path, 'path', 'is not under $publishedRoot/');
    }
    return FirebaseStorage.instance.ref(p);
  }

  /// Whether [path] names an object in the public namespace. Pure.
  static bool isPublishedPath(String path) {
    final segments = path.trim().split('/');
    return segments.length >= 4 &&
        segments.first == publishedRoot &&
        segments.every((s) => s.isNotEmpty && s != '.' && s != '..');
  }

  // ---------------------------------------------------------------------------
  // Reference helpers
  // ---------------------------------------------------------------------------

  /// Returns a [Reference] for the file at [path] within this app's folder.
  ///
  /// Use for reads and deletes of a known path (analogous to
  /// [ScopedCollection.doc]).
  Reference ref(String path) => _base.child(path);

  /// Generates a new unique [Reference] for an upcoming upload.
  ///
  /// A UUID prefix is prepended to [fileName] to ensure uniqueness within the
  /// folder. Use this alongside [buildMetadata] when the upload is performed
  /// externally (e.g. via [PlatformService]).
  Reference newRef(String fileName) =>
      _base.child('${const Uuid().v4()}_$fileName');

  // ---------------------------------------------------------------------------
  // Metadata helper
  // ---------------------------------------------------------------------------

  /// Builds [SettableMetadata] with the required permission fields injected.
  ///
  /// The following custom metadata keys are always set:
  ///
  /// | Key           | Value                                            |
  /// |---------------|--------------------------------------------------|
  /// | `creatorId`   | current user UID                                 |
  /// | `groupId`     | [ActiveGroupService.activeGroupId]               |
  /// | `appId`       | [appId] (constructor parameter)                  |
  ///
  /// There is no `visibility`: no rule reads it (D2), and a file other
  /// groups must see is published instead ([ScopedStorage.published]).
  /// Pass [contentType] to set the MIME type (e.g. `'image/jpeg'`). When
  /// omitted, Firebase Storage auto-detects or inherits the caller's setting.
  ///
  /// Additional entries can be supplied via [extraMetadata]; they will not
  /// override the permission fields above.
  SettableMetadata buildMetadata({
    String? contentType,
    Map<String, String> extraMetadata = const {},
  }) {
    return permissionMetadata(
      creatorId: _uid,
      groupId: _groupId,
      appId: appId,
      contentType: contentType,
      extraMetadata: extraMetadata,
    );
  }

  /// The metadata [buildMetadata] produces, from explicit values (pure, so
  /// it can be tested without Firebase).
  static SettableMetadata permissionMetadata({
    required String creatorId,
    required String groupId,
    required String appId,
    String? contentType,
    Map<String, String> extraMetadata = const {},
  }) {
    return SettableMetadata(
      contentType: contentType,
      customMetadata: {
        // `visibility` is retired (D2): never sent, even as extra metadata.
        ...Map.of(extraMetadata)..remove('visibility'),
        // Always overwrite permission fields to prevent spoofing.
        'creatorId': creatorId,
        'groupId': groupId,
        'appId': appId,
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Write helpers
  // ---------------------------------------------------------------------------

  /// Uploads [bytes] as a new file and returns its [Reference].
  ///
  /// A UUID prefix is prepended to [fileName] to ensure uniqueness. The
  /// permission metadata fields are automatically injected (analogous to
  /// [ScopedCollection.add]).
  Future<Reference> upload(
    String fileName,
    Uint8List bytes, {
    String? contentType,
    Map<String, String> extraMetadata = const {},
  }) async {
    final storageRef = newRef(fileName);
    await putBytes(
      storageRef,
      bytes,
      contentType: contentType,
      extraMetadata: extraMetadata,
    );
    return storageRef;
  }

  /// Uploads [bytes] to [storageRef] (from [ref] or [newRef]) with the
  /// permission metadata injected, returning the [UploadTask] so callers can
  /// await it or follow its progress.
  UploadTask putBytes(
    Reference storageRef,
    Uint8List bytes, {
    String? contentType,
    Map<String, String> extraMetadata = const {},
  }) {
    return storageRef.putData(
      bytes,
      requireUploadMetadata(buildMetadata(
        contentType: contentType,
        extraMetadata: extraMetadata,
      )),
    );
  }

  // ---------------------------------------------------------------------------
  // Read helpers
  // ---------------------------------------------------------------------------

  /// Lists all files in this app's folder for the active group.
  ///
  /// This is the storage analogue of [ScopedCollection.query] — results are
  /// already scoped to the active group via the path.
  Future<ListResult> list() => _base.listAll();
}

/// The custom metadata keys every upload must carry so Usage Meter can
/// attribute the stored bytes (see [ScopedStorage.buildMetadata]).
const List<String> requiredUploadMetadataKeys = [
  'creatorId',
  'groupId',
  'appId'
];

/// Returns [metadata] if every [requiredUploadMetadataKeys] value is
/// non-empty, else throws an [ArgumentError] — an upload without them would
/// be stored with no owner (e.g. no signed-in user, or no active group).
/// A platform-wide file says "no group" explicitly with
/// [ScopedStorage.platformNoGroupId]. Build metadata with
/// [ScopedStorage.buildMetadata].
SettableMetadata requireUploadMetadata(SettableMetadata metadata) {
  final custom = metadata.customMetadata ?? const <String, String>{};
  final missing = requiredUploadMetadataKeys
      .where((k) => (custom[k] ?? '').trim().isEmpty)
      .toList();
  if (missing.isNotEmpty) {
    throw ArgumentError.value(
      metadata.customMetadata,
      'metadata',
      'Upload metadata is missing ${missing.join(', ')}; build it with '
          'ScopedStorage.buildMetadata()',
    );
  }
  return metadata;
}
