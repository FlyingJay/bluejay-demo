import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui/ticket_attachments.dart';

void main() {
  group('isTrustedAttachmentUrl', () {
    test('only https on our Storage hosts', () {
      expect(isTrustedAttachmentUrl('https://firebasestorage.googleapis.com/v0/b/x/o/a.png'), isTrue);
      expect(isTrustedAttachmentUrl('https://storage.googleapis.com/b/a.png'), isTrue);
      expect(isTrustedAttachmentUrl('http://storage.googleapis.com/b/a.png'), isFalse);
      expect(isTrustedAttachmentUrl('https://evil.example.com/a.png'), isFalse);
      expect(isTrustedAttachmentUrl('not a url'), isFalse);
    });
  });

  group('ticketAttachmentsFromData', () {
    test('reads attachments (Timestamp or ISO uploadedAt), dropping untrusted ones', () {
      final when = DateTime.utc(2026, 10, 8);
      final list = ticketAttachmentsFromData({
        'attachments': [
          {
            'url': 'https://firebasestorage.googleapis.com/o/a.png?alt=media',
            'name': 'a.png',
            'contentType': 'image/png',
            'sizeBytes': 12,
            'uploadedAt': Timestamp.fromDate(when),
          },
          {'url': 'https://storage.googleapis.com/b/report.pdf', 'name': 'report.pdf', 'uploadedAt': '2026-10-08T00:00:00Z'},
          {'url': 'https://evil.example.com/c.png', 'name': 'c.png'},
          {'url': '', 'name': 'blank'},
        ],
      });
      expect(list.map((a) => a.name), ['a.png', 'report.pdf']);
      expect(list.first.isImage, isTrue);
      expect(list.first.uploadedAt!.isAtSameMomentAs(when), isTrue);
      expect(list.last.isImage, isFalse);
      expect(list.last.uploadedAt, DateTime.utc(2026, 10, 8));
    });

    test('falls back to legacy imageUrls / imageUrl screenshots', () {
      expect(
        ticketAttachmentsFromData({'imageUrls': ['https://storage.googleapis.com/b/s.png']}).single.isImage,
        isTrue,
      );
      expect(ticketAttachmentsFromData({'imageUrl': 'https://storage.googleapis.com/b/s.png'}).length, 1);
      expect(ticketAttachmentsFromData({'attachments': [], 'imageUrls': []}), isEmpty);
    });

    test('isImage sniffs the extension when there is no content type', () {
      expect(
        const TicketAttachment(url: 'https://storage.googleapis.com/o/folder%2Fshot.JPG?alt=media').isImage,
        isTrue,
      );
      expect(const TicketAttachment(url: 'https://storage.googleapis.com/o/x', name: 'notes.txt').isImage, isFalse);
    });
  });

  testWidgets('gallery shows a chip per file and nothing for untrusted URLs', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: TicketAttachmentGallery(attachments: [
          TicketAttachment(url: 'https://storage.googleapis.com/b/report.pdf', name: 'report.pdf'),
          TicketAttachment(url: 'https://evil.example.com/x.pdf', name: 'x.pdf'),
        ]),
      ),
    ));
    expect(find.widgetWithText(ActionChip, 'report.pdf'), findsOneWidget);
    expect(find.text('x.pdf'), findsNothing);
  });
}
