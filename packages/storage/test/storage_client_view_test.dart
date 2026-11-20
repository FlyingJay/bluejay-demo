import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/portal_cards.dart';
import 'package:storage/src/models.dart';
import 'package:storage/storage_client_view.dart';

import 'support/fakes.dart';

const client = 'client-kim';

SharedFile _file(String id, {String? uploader, DateTime? at, String name = 'Report.pdf'}) => SharedFile(
      id: id,
      downloadUrl: '',
      storagePath: 'groups/g/apps/storage/files/$id',
      fileName: name,
      userId: uploader ?? 'staff',
      userEmail: '',
      size: 2048,
      createdAt: Timestamp.fromDate(at ?? DateTime(2026, 11, 10)),
      isPublic: false,
      sharedWithIds: uploader == null ? const [client] : const [],
      fromClient: uploader != null,
      clientUploaderUid: uploader,
    );

void main() {
  test('SharedFile reads a client upload\'s fields', () {
    final f = _file('u', uploader: client);
    expect(f.fromClient, isTrue);
    expect(f.clientUploaderUid, client);
  });

  test('newSharedFileCount counts recent files shared with the client, not their uploads', () {
    final now = DateTime(2026, 11, 13);
    final files = [
      _file('a', at: DateTime(2026, 11, 12)),
      _file('b', at: DateTime(2026, 10, 1)),
      _file('c', at: DateTime(2026, 11, 12), uploader: client),
    ];
    expect(newSharedFileCount(files, client, now), 1);
  });

  testWidgets('shows shared files and the client\'s uploads apart, downloads and uploads', (t) async {
    final log = <String>[];
    await t.pumpWidget(themed(StorageClientView(
      uid: client,
      businessName: 'Acme Dental',
      files: [_file('a', name: 'Treatment plan.pdf'), _file('b', uploader: client, name: 'X-ray.png')],
      onUpload: () => log.add('upload'),
      onDownload: (f) => log.add('download:${f.id}'),
      onRefresh: () => log.add('refresh'),
    )));
    expect(find.text('Shared with you'), findsOneWidget);
    expect(find.text('Sent by you'), findsOneWidget);
    expect(find.text('Treatment plan.pdf'), findsOneWidget);
    expect(find.text('X-ray.png'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('client-file-a')));
    await t.tap(find.text('Upload'));
    expect(log, ['download:a', 'upload']);
  });

  testWidgets('empty sections explain what goes there', (t) async {
    await t.pumpWidget(themed(StorageClientView(
      uid: client,
      businessName: 'Acme Dental',
      files: const [],
      onUpload: () {},
      onDownload: (_) {},
      onRefresh: () {},
    )));
    expect(find.text('Nothing shared yet'), findsOneWidget);
    expect(find.textContaining('Upload a file to send it to Acme Dental'), findsOneWidget);
  });

  testWidgets('the portal card shows new files and opens Files', (t) async {
    var opened = 0;
    final card = PortalCardContext(
      uid: client, groupDocId: 'g', groupSlug: 'g', appId: 'storage', onOpenApp: () => opened++,
    );
    await t.pumpWidget(themed(Scaffold(
      body: StoragePortalCard(
        card: card,
        now: DateTime(2026, 11, 13),
        loadFiles: () async => [_file('a'), _file('b'), _file('c', uploader: client)],
      ),
    )));
    await t.pumpAndSettle();
    expect(find.text('New files'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    await t.tap(find.text('New files'));
    expect(opened, 1);
    expect(storagePortalCard.appId, 'storage');
  });

  test('clientUploadProblem matches the Storage rules\' limits for clients', () {
    expect(clientUploadProblem('scan.pdf', 1024), isNull);
    expect(clientUploadProblem('photo.JPG', 1024), isNull);
    expect(clientUploadProblem('sheet.xlsx', 1024), isNull);
    expect(clientUploadProblem('notes.txt', 1024), isNull);
    expect(clientUploadProblem('setup.exe', 1024), isNotNull);
    expect(clientUploadProblem('big.pdf', kClientUploadMaxBytes + 1), isNotNull);
  });
}
