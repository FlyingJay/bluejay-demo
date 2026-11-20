import 'package:bluejay_design/bluejay_design.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:storage/file_sharing_screen.dart';

const me = 'user-me';

SharedFile fakeFile({
  String id = 'f1',
  String fileName = 'Quarterly report.pdf',
  String? displayName = 'Quarterly report',
  int size = 2 * 1024 * 1024,
  bool isPublic = false,
  String userId = me,
  String userEmail = 'jay@bluejay.gg',
  List<String> sharedWithIds = const [],
  DateTime? createdAt,
  bool isFolder = false,
  String? parentId,
}) =>
    SharedFile(
      id: id,
      downloadUrl: '',
      storagePath: 'groups/g/apps/storage/files/$fileName',
      fileName: fileName,
      userId: userId,
      userEmail: userEmail,
      displayName: displayName,
      size: size,
      createdAt: Timestamp.fromDate(createdAt ?? DateTime(2026, 11, 3, 9, 41)),
      isPublic: isPublic,
      sharedWithIds: sharedWithIds,
      isFolder: isFolder,
      parentId: parentId,
    );

/// A folder named [name], in [parentId] (null for the top level).
SharedFile fakeFolder(String id, String name,
        {String? parentId, String userId = me, List<String> sharedWithIds = const []}) =>
    fakeFile(
      id: id,
      fileName: name,
      displayName: name,
      size: 0,
      isFolder: true,
      parentId: parentId,
      userId: userId,
      sharedWithIds: sharedWithIds,
    );

/// A spread of files covering every kind of row.
final sampleFiles = [
  fakeFile(id: 'a', isPublic: true, sharedWithIds: ['u2', 'u3']),
  fakeFile(
      id: 'b',
      fileName: 'Office party.jpg',
      displayName: 'Office party photos',
      size: 5400000,
      createdAt: DateTime(2026, 10, 28)),
  fakeFile(
      id: 'c',
      fileName: 'Claims 2026.xlsx',
      displayName: 'Claims tracker 2026',
      size: 184000,
      isPublic: true,
      createdAt: DateTime(2026, 10, 14)),
  fakeFile(
      id: 'd',
      fileName: 'Onboarding.mp4',
      displayName: 'New broker onboarding walkthrough recording',
      size: 312000000,
      createdAt: DateTime(2026, 9, 30),
      sharedWithIds: ['u4']),
  fakeFile(
      id: 'e',
      fileName: 'Policy wording.docx',
      displayName: 'Policy wording draft',
      size: 92000,
      createdAt: DateTime(2026, 9, 2)),
  fakeFile(
      id: 'f',
      fileName: 'Archive.zip',
      displayName: 'Old statements',
      size: 48000000,
      createdAt: DateTime(2026, 8, 19)),
];

Widget themed(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: BluejayTheme.build(),
      home: child,
    );
