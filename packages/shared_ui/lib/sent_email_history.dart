import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:shared_services/scoped_collection.dart';

import 'stored_file_actions.dart';

/// The emails sent about one record (e.g. an insurance application), newest
/// first, each with a download of the exact message sent (.eml).
///
/// Reads `sent_emails`, which Cloud Functions write when a send opts into the
/// archive (functions/_sent_email_archive.js); clients can't create or alter
/// a record. [appId] is the reading app: a product app sees its own sends, a
/// staff app (Policy Editor) every product's, as the rules allow. Pass
/// [groupId] when the screen is bound to a record's group rather than the
/// active one.
class SentEmailHistory extends StatelessWidget {
  const SentEmailHistory({
    super.key,
    required this.appId,
    required this.recordId,
    this.groupId,
    this.emptyText = 'No emails have been sent for this record yet.',
    this.accentColor,
  });

  final String appId;
  final String recordId;
  final String? groupId;
  final String emptyText;
  final Color? accentColor;

  Query<Map<String, dynamic>> _query() {
    final collection = ScopedCollection(collection: 'sent_emails', appId: appId);
    final scoped = groupId == null || groupId!.isEmpty
        ? collection.query
        : collection.queryInGroup(groupId!);
    return scoped.where('recordId', isEqualTo: recordId);
  }

  @override
  Widget build(BuildContext context) {
    if (recordId.isEmpty) return const SizedBox.shrink();
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _query().snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const BjInlineNote(
            'Email history is unavailable right now.',
            icon: Icons.error_outline_rounded,
            tone: BjTone.danger,
          );
        }
        if (!snapshot.hasData) {
          return const BjSkeleton(height: 72, radius: BjRadius.lg);
        }
        final emails = snapshot.data!.docs.map((d) => d.data()).toList()
          ..sort((a, b) => _sentAt(b).compareTo(_sentAt(a)));
        if (emails.isEmpty) {
          return BjInlineNote(emptyText, icon: Icons.mail_outline_rounded);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final email in emails)
              _SentEmailTile(email: email, accentColor: accentColor),
          ],
        );
      },
    );
  }

  static DateTime _sentAt(Map<String, dynamic> email) {
    final raw = email['sentAt'];
    // A just-written record's server timestamp is null until it resolves.
    return raw is Timestamp ? raw.toDate() : DateTime.now();
  }
}

class _SentEmailTile extends StatelessWidget {
  const _SentEmailTile({required this.email, this.accentColor});

  final Map<String, dynamic> email;
  final Color? accentColor;

  static List<String> _list(Object? raw) =>
      raw is List ? raw.map((e) => '$e').where((e) => e.isNotEmpty).toList() : const [];

  static String _formatSentAt(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final hour = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final minute = d.minute.toString().padLeft(2, '0');
    return '${months[d.month - 1]} ${d.day}, ${d.year} · $hour:$minute ${d.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: BjNeutral.inkSubtle);
    final subject = (email['subject'] as String?)?.trim();
    final to = _list(email['to']);
    final cc = _list(email['cc']);
    final attachments = (email['attachments'] as List? ?? const [])
        .whereType<Map>()
        .map((a) => '${a['filename'] ?? 'attachment'}')
        .toList();
    final preview = (email['bodyPreview'] as String?)?.trim() ?? '';
    final sentAt = SentEmailHistory._sentAt(email);
    final id = (email['emlPath'] as String? ?? '').split('/').last;

    return Container(
      margin: const EdgeInsets.only(bottom: BjSpace.sm + 2),
      padding: const EdgeInsets.fromLTRB(BjSpace.md + 2, BjSpace.md, BjSpace.xs + 2, BjSpace.sm + 2),
      decoration: BoxDecoration(
        color: BjNeutral.surface,
        borderRadius: BjRadius.all(BjRadius.lg),
        border: Border.all(color: BjNeutral.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.mark_email_read_outlined, size: 20, color: accentColor ?? context.bj.accent),
              const SizedBox(width: BjSpace.sm + 2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      subject == null || subject.isEmpty ? '(no subject)' : subject,
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(_formatSentAt(sentAt), style: muted),
                  ],
                ),
              ),
              StoredFileActions(
                fileName: id.isEmpty ? 'email.eml' : id,
                downloadUrl: email['emlUrl'] as String?,
                showPreview: false,
                color: accentColor,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 30, right: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('To: ${to.join(', ')}', style: theme.textTheme.bodySmall),
                if (cc.isNotEmpty) Text('Cc: ${cc.join(', ')}', style: theme.textTheme.bodySmall),
                if (attachments.isNotEmpty)
                  Text('Attachments: ${attachments.join(', ')}', style: theme.textTheme.bodySmall),
                if (preview.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(preview, maxLines: 2, overflow: TextOverflow.ellipsis, style: muted),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
