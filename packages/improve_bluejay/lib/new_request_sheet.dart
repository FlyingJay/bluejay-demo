import 'package:app_maker/app_maker_submit_screen.dart';
import 'package:bluejay_design/bluejay_design.dart';
import 'package:bug_reports/bug_reports_screen.dart';
import 'package:feature_voting/feature_voting_screen.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';

import 'request_change.dart';

/// The three kinds of request the queue screen's "Request a change" offers.
enum NewRequestKind { problem, improvement, newApp }

/// "Request a change" from the queue screen (PHASE_2_DESIGN.md 6.4): report
/// a problem, suggest an improvement or ask for a new app, with no app
/// preselected. The launcher passes this to `DevQueueScreen.onNewRequest`.
Future<void> showNewRequestSheet(BuildContext context, {fire_auth.User? currentUser}) async {
  final kind = await showBjSheet<NewRequestKind>(
    context,
    title: 'Request a change',
    subtitle: 'Ask for what would save you time. It joins your queue and '
        'you can follow it here.',
    builder: (_) => const NewRequestChooser(),
  );
  if (kind == null || !context.mounted) return;
  const fallback = "Thanks! Your request is in. We'll let you know when it's live.";

  if (kind == NewRequestKind.newApp) {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AppMakerSubmitScreen(currentUser: currentUser),
    ));
    return;
  }

  final itemType = kind == NewRequestKind.problem ? 'bug' : 'feature';
  final ticketId = kind == NewRequestKind.problem
      ? await showBugSubmitSheet(context, currentUser: currentUser, showSuccessSnackBar: false)
      : await showFeatureSubmitDialog(context, currentUser: currentUser, showSuccessSnackBar: false);
  if (ticketId == null || !context.mounted) return;
  await confirmQueuedRequest(
    context,
    itemType: itemType,
    ticketId: ticketId,
    fallbackMessage: fallback,
    currentUser: currentUser,
    onNewRequest: (ctx) => showNewRequestSheet(ctx, currentUser: currentUser),
  );
}

/// The options [showNewRequestSheet] offers, shown under the sheet's
/// "Request a change" title. Pops the chosen [NewRequestKind].
class NewRequestChooser extends StatelessWidget {
  const NewRequestChooser({super.key});

  @override
  Widget build(BuildContext context) {
    return RequestChooserOptions(options: [
      RequestChooserOption(
        icon: Icons.bug_report_rounded,
        tone: BjTone.danger,
        title: 'Report a problem',
        subtitle: "Something isn't working the way it should",
        onTap: () => Navigator.of(context).pop(NewRequestKind.problem),
      ),
      RequestChooserOption(
        icon: Icons.lightbulb_rounded,
        title: 'Suggest an improvement',
        subtitle: 'An idea that would make an app better',
        onTap: () => Navigator.of(context).pop(NewRequestKind.improvement),
      ),
      RequestChooserOption(
        icon: Icons.add_box_rounded,
        tone: BjTone.info,
        title: 'Ask for a new app',
        subtitle: "A tool that doesn't exist yet",
        onTap: () => Navigator.of(context).pop(NewRequestKind.newApp),
      ),
    ]);
  }
}
