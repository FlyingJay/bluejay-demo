/// The reasons an admin can give when closing an Improve Apps ticket
/// (bug_reports / feature_requests) without fixing or completing it, or
/// when declining an App Maker request.
///
/// Bugs and ideas: the chosen [TicketCloseReason.code] and
/// [TicketCloseReason.label] are sent to the `improveBluejaySetItemStatus`
/// callable as `reasonCode`/`reasonLabel` and stored as
/// `closedReasonCode`/`closedReasonLabel`; the composed
/// [TicketCloseSelection.message] becomes `closedReason`.
///
/// App requests: the code, label and note go to
/// `appMakerAdminSetRequestStatus` as `declineReasonCode`,
/// `declineReasonLabel` and `declineNote`.
///
/// The server words the requester's notification from the code
/// (functions/_ticket_closure.js), so codes are a contract with it
/// (plans/development-queue/PHASE_2_5_DESIGN.md 7.2).
///
/// This is the one shared list: every screen that closes tickets reads it
/// from here (the dialog is `showTicketCloseReasonDialog` in
/// shared_ui/ticket_close_reason_dialog.dart).
library;

/// One close reason.
class TicketCloseReason {
  final String code;
  final String label;

  /// Whether the note must be filled in. For [needsMoreInfoCloseReason]
  /// the note is the question the requester reads and answers.
  final bool requiresNote;

  /// The note field's label when this reason is chosen; null for the
  /// default "Details (optional)".
  final String? noteLabel;

  const TicketCloseReason({
    required this.code,
    required this.label,
    this.requiresNote = false,
    this.noteLabel,
  });

  /// The label for the note field with this reason chosen.
  String get noteFieldLabel => noteLabel ?? (requiresNote ? 'Details' : 'Details (optional)');

  @override
  bool operator ==(Object other) => other is TicketCloseReason && other.code == code && other.label == label;

  @override
  int get hashCode => Object.hash(code, label);
}

/// "Needs more information": the note is a question for the requester. With
/// a queue item, it reaches them as "Waiting on you" and answering reopens
/// the request.
const needsMoreInfoCloseReason = TicketCloseReason(
  code: 'needs_more_info',
  label: 'Needs more information',
  requiresNote: true,
  noteLabel: 'Your question for the requester',
);

/// "Not ready to build yet": a real plan for later that needs more
/// definition before it's built. It takes the request out of the queue
/// without reading as won't-fix to the requester or a later agent;
/// reopening it queues it again. Review Desk's Not ready action closes
/// with it.
const notReadyCloseReason = TicketCloseReason(
  code: 'not_ready',
  label: 'Not ready to build yet',
  noteLabel: 'What it needs first (optional)',
);

/// Reasons for closing a bug report.
const List<TicketCloseReason> bugCloseReasons = [
  TicketCloseReason(code: 'unspecified', label: 'Unspecified'),
  TicketCloseReason(code: 'already_implemented', label: 'Already implemented'),
  TicketCloseReason(code: 'duplicate', label: 'Duplicate ticket'),
  TicketCloseReason(code: 'too_broad', label: 'Too broad'),
  TicketCloseReason(code: 'cannot_reproduce', label: 'Cannot reproduce'),
  needsMoreInfoCloseReason,
  notReadyCloseReason,
  TicketCloseReason(code: 'not_planned', label: 'Not planned'),
];

/// Reasons for closing an idea (feature request).
const List<TicketCloseReason> ideaCloseReasons = [
  TicketCloseReason(code: 'unspecified', label: 'Unspecified'),
  TicketCloseReason(code: 'already_implemented', label: 'Already implemented'),
  TicketCloseReason(code: 'duplicate', label: 'Duplicate ticket'),
  TicketCloseReason(code: 'too_broad', label: 'Too broad'),
  TicketCloseReason(code: 'out_of_scope', label: 'Out of scope'),
  needsMoreInfoCloseReason,
  notReadyCloseReason,
  TicketCloseReason(code: 'not_planned', label: 'Not planned'),
];

/// Reasons for declining an App Maker request.
const List<TicketCloseReason> appDeclineReasons = [
  TicketCloseReason(code: 'duplicate', label: 'Duplicate request'),
  TicketCloseReason(code: 'already_exists', label: 'An app already does this'),
  TicketCloseReason(code: 'out_of_scope', label: 'Out of scope for the platform'),
  TicketCloseReason(code: 'too_broad', label: 'Too broad — needs to be split up'),
  needsMoreInfoCloseReason,
  notReadyCloseReason,
  TicketCloseReason(code: 'not_planned', label: 'Not planned right now'),
  TicketCloseReason(code: 'withdrawn_by_requester', label: 'Requester withdrew it'),
  TicketCloseReason(code: 'spam_or_test', label: 'Spam or test submission'),
  TicketCloseReason(code: 'unspecified', label: 'Other'),
];

/// The close reasons for an `itemType`: `bug`, `feature`, or `app`.
List<TicketCloseReason> closeReasonsFor(String itemType) {
  switch (itemType) {
    case 'bug':
      return bugCloseReasons;
    case 'app':
      return appDeclineReasons;
    default:
      return ideaCloseReasons;
  }
}

/// A chosen reason plus the admin's free-text note.
class TicketCloseSelection {
  final TicketCloseReason reason;
  final String note;

  const TicketCloseSelection({required this.reason, this.note = ''});

  /// The note, trimmed.
  String get trimmedNote => note.trim();

  /// False while a reason that needs a note has none.
  bool get isComplete => !reason.requiresNote || trimmedNote.isNotEmpty;

  /// `Label — note`, or just the label when there's no note. The server
  /// strips the `Label — ` prefix to get the question for
  /// [needsMoreInfoCloseReason].
  String get message => trimmedNote.isEmpty ? reason.label : '${reason.label} — $trimmedNote';
}
