import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_services/public_collection.dart';
import 'package:shared_services/scoped_storage.dart';

// Data model for a shared file
class SharedFile {
  final String id, downloadUrl, storagePath, fileName, userId, userEmail;
  final String? displayName; // Custom name given by user
  final int size;
  final Timestamp createdAt;
  final bool isPublic;
  final List<String> sharedWithIds;
  final List<String> sharedWithEmails;

  /// Uploaded by a portal client of the group (storageRegisterClientUpload),
  /// and who: every Storage member of the group may download it.
  final bool fromClient;
  final String? clientUploaderUid;

  /// A folder: no stored file, only a name that other items are filed
  /// under (src/folders.dart).
  final bool isFolder;

  /// The folder this is in, or null at the top level.
  final String? parentId;

  SharedFile({
    required this.id,
    required this.downloadUrl,
    required this.storagePath,
    required this.fileName,
    required this.userId,
    required this.userEmail,
    this.displayName,
    required this.size,
    required this.createdAt,
    required this.isPublic,
    this.sharedWithIds = const [],
    this.sharedWithEmails = const [],
    this.fromClient = false,
    this.clientUploaderUid,
    this.isFolder = false,
    this.parentId,
  });

  /// The name to show: the one its owner gave it, else the file's own.
  String get name => displayName ?? fileName;

  factory SharedFile.fromFirestore(DocumentSnapshot doc) {
    Map data = doc.data() as Map<String, dynamic>;
    return SharedFile(
      id: doc.id,
      downloadUrl: data['downloadUrl'] ?? '',
      storagePath: data['storagePath'] ?? '',
      fileName: data['fileName'] ?? '',
      userId: data['userId'] ?? '',
      userEmail: data['userEmail'] ?? '',
      displayName: data['displayName'],
      size: data['size'] ?? 0,
      createdAt: data['createdAt'] ?? Timestamp.now(),
      isPublic: data['isPublic'] ??
          true, // Default to public for backward compatibility
      sharedWithIds: List<String>.from(data['sharedWithIds'] ?? []),
      sharedWithEmails: List<String>.from(data['sharedWithEmails'] ?? []),
      fromClient: data['fromClient'] == true,
      clientUploaderUid: data['clientUploaderUid'] as String?,
      isFolder: data['isFolder'] == true,
      parentId: _nonEmpty(data['parentId']),
    );
  }

  /// A file from the public namespace (`public_files`): its [storagePath]
  /// is the published copy (read with [ScopedStorage.published]), its [id]
  /// the source file's. Who uploaded it isn't published.
  factory SharedFile.fromPublished(DocumentSnapshot<Map<String, dynamic>> doc) {
    final published = PublishedDoc.fromSnapshot(doc);
    final data = published.data;
    return SharedFile(
      id: published.sourceId,
      downloadUrl: '',
      storagePath: data['storagePath'] as String? ?? '',
      fileName: data['fileName'] as String? ?? '',
      userId: '',
      userEmail: '',
      displayName: data['displayName'] as String?,
      size: (data['size'] as num?)?.toInt() ?? 0,
      createdAt: data['createdAt'] is Timestamp
          ? data['createdAt'] as Timestamp
          : Timestamp.now(),
      isPublic: true,
    );
  }

  /// Whether this is the published copy (from the Public tab), read under
  /// the rules rather than through the tenant file.
  bool get isPublishedCopy => ScopedStorage.isPublishedPath(storagePath);
}

/// [value] trimmed, or null when it isn't a non-empty string.
String? _nonEmpty(Object? value) {
  final s = value is String ? value.trim() : '';
  return s.isEmpty ? null : s;
}

class StorageUsageSummary {
  final int totalBytes;
  final int totalFiles;

  const StorageUsageSummary({
    required this.totalBytes,
    required this.totalFiles,
  });

  static const zero = StorageUsageSummary(totalBytes: 0, totalFiles: 0);
}
