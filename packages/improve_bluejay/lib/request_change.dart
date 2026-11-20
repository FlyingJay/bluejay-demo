import 'package:blue_ji/blue_ji_panel.dart';
import 'package:bluejay_design/bluejay_design.dart';
import 'package:bug_reports/bug_reports_screen.dart';
import 'package:feature_voting/feature_voting_screen.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';
import 'package:help_desk/help_desk_sheets.dart' show contactHelpDesk, mayContactHelpDesk;
import 'package:help_desk/constants.dart' as help_desk show APP_ID;
import 'package:shared_services/active_group_service.dart';
import 'package:shared_services/app_help_tab.dart';
import 'package:shared_services/guest_status.dart';
import 'package:shared_services/user_app_entitlements.dart';
import 'package:wiki/app_help.dart';

import 'improve_apps_widgets.dart';
import 'new_request_sheet.dart';
import 'request_change_availability.dart';
import 'request_queue_confirmation.dart';
import 'package:shared_services/bluejay_firestore.dart';
import 'package:improve_bluejay/constants.dart';

export 'improve_apps_widgets.dart'
    show RequestChooserOption, RequestChooserOptions;
export 'new_request_sheet.dart';
export 'request_change_availability.dart';
export 'request_queue_confirmation.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Help and "Request a change" from inside any app
//
// AppRouter.getScreen (lib/routing/app_router.dart) wraps every routed app in
// an [AppHelpShell], which shows a small edge tab. It opens a chooser
// ("Ask BlueJI about {app}" / "How {app} works" / "Report a problem" /
// "Suggest an improvement"): the first asks BlueJI about this app in a panel
// over it (blue_ji's showAskBlueJi), the second reads the app's Wiki user
// guide the same way (wiki's showAppHelp), and the person can switch between
// those two from either panel. The others open the existing Improve Apps
// submit form with the current app pre-selected and locked. With only one of the two available, the tab
// offers just that one. Where the active group takes this person's Help Desk
// requests, "Contact {group}" opens one about the current app (guests
// included: it is their way to reach a person).
// The filed bug_reports / feature_requests doc is identical to one filed
// from inside Improve Apps, so dispatch, steward routing, PR tracking and the
// "it's live" notification all apply unchanged.
// ─────────────────────────────────────────────────────────────────────────────

/// What the side tab's chooser offers.
enum AppTabAction { ask, readGuide, reportProblem, suggestImprovement, contactSupport }

/// Shows the side tab's chooser for [appName] — "Ask BlueJI about {app}"
/// when [offerAsk] and [guide] are set, "How {app} works" when [guide] is,
/// then "Report a problem" / "Suggest an improvement" — and opens what was
/// picked: BlueJI or the guide ([showGuideOrAsk]), or the matching Improve
/// Apps submit form with the app pre-selected and locked. The guide's "Still
/// stuck?" button comes back here for the other options.
///
/// The confirmation is "Added to your queue: #k." plus the estimate line
/// (request_queue_confirmation.dart), or [requestChangeSuccessMessage] for a
/// managed group or a slow intake.
///
/// [contactName] (the active group's name) adds "Contact {group}", which
/// opens a Help Desk request about this app; [offerRequests] false leaves
/// out the two change requests (guests).
Future<void> showRequestChangeSheet(
  BuildContext context, {
  required String appId,
  required String appName,
  fire_auth.User? currentUser,
  AppHelpDoc? guide,
  String? contactName,
  bool offerRequests = true,
  bool offerAsk = false,
}) async {
  final askable = offerAsk && guide != null;
  final action = await showBjSheet<AppTabAction>(
    context,
    title: guide == null && contactName == null ? 'Request a change to $appName' : 'Help with $appName',
    subtitle: !offerRequests
        ? contactName == null
            ? 'Ask BlueJI a question, or read how it works.'
            : 'Read how it works, or ask $contactName for help.'
        : guide == null && contactName == null
            ? 'Tell us what would make it better. Your request goes '
                'straight to the people who build it.'
            : 'Read how it works, ask for help, or tell the people who '
                'build it what would make it better.',
    builder: (_) => RequestChangeChooser(
      guideAppName: guide == null ? null : appName,
      askAppName: askable ? appName : null,
      contactName: contactName,
      offerRequests: offerRequests,
    ),
  );
  if (action == null || !context.mounted) return;

  if (action == AppTabAction.contactSupport) {
    await contactHelpDesk(context, appId: appId, appName: appName);
    return;
  }

  if (action == AppTabAction.readGuide || action == AppTabAction.ask) {
    final stuck = await showGuideOrAsk(
      context,
      start: action,
      appId: appId,
      appName: appName,
      guide: guide!,
      currentUser: currentUser,
      offerAsk: askable,
      offerRequestChange: offerRequests || contactName != null,
    );
    if (!stuck || !context.mounted) return;
    return showRequestChangeSheet(
      context,
      appId: appId,
      appName: appName,
      currentUser: currentUser,
      contactName: contactName,
      offerRequests: offerRequests,
    );
  }

  final successMessage = requestChangeSuccessMessage(appName);
  final String? ticketId;
  final String itemType;
  switch (action) {
    case AppTabAction.ask:
    case AppTabAction.readGuide:
    case AppTabAction.contactSupport:
      return;
    case AppTabAction.reportProblem:
      itemType = 'bug';
      ticketId = await showBugSubmitSheet(
        context,
        currentUser: currentUser,
        initialRelatedAppId: appId,
        initialRelatedAppName: appName,
        lockRelatedApp: true,
        successMessage: successMessage,
        showSuccessSnackBar: false,
      );
    case AppTabAction.suggestImprovement:
      itemType = 'feature';
      ticketId = await showFeatureSubmitDialog(
        context,
        currentUser: currentUser,
        initialRelatedAppId: appId,
        initialRelatedAppName: appName,
        lockRelatedApp: true,
        successMessage: successMessage,
        showSuccessSnackBar: false,
      );
  }
  if (ticketId == null || !context.mounted) return;
  await confirmQueuedRequest(
    context,
    itemType: itemType,
    ticketId: ticketId,
    fallbackMessage: successMessage,
    currentUser: currentUser,
    onNewRequest: (ctx) => showNewRequestSheet(ctx, currentUser: currentUser),
  );
}

/// Opens BlueJI ([start] is [AppTabAction.ask]) or the guide for [appName],
/// and lets the person switch between the two: the guide's "Ask BlueJI"
/// (with [offerAsk]) and BlueJI's "Read the guide" each close one panel and
/// open the other. Completes true when the guide's "Still stuck?" was tapped
/// (with [offerRequestChange]), so the caller can offer its requests.
Future<bool> showGuideOrAsk(
  BuildContext context, {
  required AppTabAction start,
  required String appId,
  required String appName,
  required AppHelpDoc guide,
  fire_auth.User? currentUser,
  bool offerAsk = true,
  bool offerRequestChange = false,
}) async {
  var next = start;
  while (true) {
    if (!context.mounted) return false;
    if (next == AppTabAction.ask) {
      final exit = await showAskBlueJi(
        context,
        appId: appId,
        appName: appName,
        guideSlug: guide.slug,
        currentUser: currentUser,
      );
      if (exit != BlueJiPanelExit.readGuide) return false;
      next = AppTabAction.readGuide;
    } else {
      final exit = await showAppHelp(
        context,
        appName: appName,
        doc: guide,
        offerRequestChange: offerRequestChange,
        offerAsk: offerAsk,
      );
      switch (exit) {
        case AppHelpExit.closed:
          return false;
        case AppHelpExit.requestChange:
          return true;
        case AppHelpExit.ask:
          next = AppTabAction.ask;
      }
    }
  }
}

/// The options [showRequestChangeSheet] offers, shown under its title. Pops
/// the chosen [AppTabAction]. [askAppName] adds "Ask BlueJI about {app}"
/// first, [guideAppName] "How {app} works" next, then [contactName]
/// "Contact {group}"; [offerRequests] false leaves out the change requests.
class RequestChangeChooser extends StatelessWidget {
  final String? askAppName;
  final String? guideAppName;
  final String? contactName;
  final bool offerRequests;

  const RequestChangeChooser({
    super.key,
    this.askAppName,
    this.guideAppName,
    this.contactName,
    this.offerRequests = true,
  });

  @override
  Widget build(BuildContext context) {
    void pick(AppTabAction action) => Navigator.of(context).pop(action);
    return RequestChooserOptions(options: [
      if (askAppName != null)
        RequestChooserOption(
          icon: Icons.auto_awesome_rounded,
          title: 'Ask BlueJI about $askAppName',
          subtitle: 'Get a quick answer instead of reading the whole guide',
          onTap: () => pick(AppTabAction.ask),
        ),
      if (guideAppName != null)
        RequestChooserOption(
          icon: Icons.menu_book_rounded,
          tone: BjTone.info,
          title: 'How $guideAppName works',
          subtitle: 'Read the guide without leaving the app',
          onTap: () => pick(AppTabAction.readGuide),
        ),
      if (contactName != null)
        RequestChooserOption(
          icon: Icons.support_agent_rounded,
          tone: BjTone.success,
          title: 'Contact $contactName',
          subtitle: 'Ask a person for help with this app',
          onTap: () => pick(AppTabAction.contactSupport),
        ),
      if (offerRequests) ...[
        RequestChooserOption(
          icon: Icons.bug_report_rounded,
          tone: BjTone.danger,
          title: 'Report a problem',
          subtitle: "Something isn't working the way it should",
          onTap: () => pick(AppTabAction.reportProblem),
        ),
        RequestChooserOption(
          icon: Icons.lightbulb_rounded,
          title: 'Suggest an improvement',
          subtitle: 'An idea that would make this app better',
          onTap: () => pick(AppTabAction.suggestImprovement),
        ),
      ],
    ]);
  }
}

/// Wraps a launched app's root screen with a small edge tab for help and
/// change requests. Applied generically by `AppRouter.getScreen`, so every
/// routed app gets it with no per-app code.
///
/// The tab appears when either half is available:
/// - the app's guide ([AppHelpDocs.load]): its Wiki user guide for members,
///   and its guest guide for guests (visitors and clients), so guests never
///   read about member features they don't have. An app without a guest
///   guide offers guests no guide;
/// - "Request a change", once [canOfferRequestChange] passes (the user's
///   access index, plus the app doc when the caller didn't supply it;
///   skipped entirely for guests);
/// - "Contact {group}", when the user has Help Desk in the active group
///   ([mayContactHelpDesk], from the same access index), guests included.
///
/// Signed-in members with the guide also get "Ask BlueJI about {app}", which
/// answers from that guide (blue_ji's showAskBlueJi). Guests don't: BlueJI
/// reads member guides.
///
/// With more than one, it opens [showRequestChangeSheet] with BlueJI and the
/// guide as its first options; with only the guide, it opens the guide
/// directly. It is hidden
/// while the on-screen keyboard is up so it never covers input, and while a
/// screen in the app asks for that with [HideAppHelpTab]
/// (shared_services/app_help_tab.dart), such as a game in progress.
///
/// A [chatTab], when given, sits just above the help tab (the root app's
/// ChatRibbon, which opens Chat). It hides with the help tab, for the
/// keyboard, screenshot captures, an embedded deep link and [HideAppHelpTab],
/// except where the screen passes `keepChat: true` (a head-to-head game).
/// It stays put whether or not the help tab is showing.
class AppHelpShell extends StatefulWidget {
  /// The app's `apps/{id}.appId` slug — stored as `relatedAppId`.
  final String appId;

  /// The app's display name, if the caller already has it. Otherwise it is
  /// read from the `apps` collection (falling back to [fallbackAppDisplayName]).
  final String? appName;

  /// The app's `apps/{id}.allowChangeRequests`, if the caller already has
  /// the app doc. Otherwise it is read along with the name (true when unset).
  final bool? allowChangeRequests;

  final fire_auth.User? currentUser;

  /// False suppresses the affordance outright — e.g. for an embeddable app
  /// opened via deep link, which hides Bluejay chrome.
  final bool enabled;

  /// Finds the app's guide for a member, or with `forGuest` for a guest;
  /// [AppHelpDocs.load] unless a test swaps it.
  final Future<AppHelpDoc?> Function(String appId, {bool forGuest}) loadGuide;

  /// The edge tab above the help tab, if any. See the class comment.
  final Widget? chatTab;

  final Widget child;

  const AppHelpShell({
    super.key,
    required this.appId,
    required this.child,
    this.appName,
    this.allowChangeRequests,
    this.currentUser,
    this.enabled = true,
    this.loadGuide = AppHelpDocs.load,
    this.chatTab,
  });

  @override
  State<AppHelpShell> createState() => _AppHelpShellState();
}

class _AppHelpShellState extends State<AppHelpShell> {
  bool _canRequestChange = false;
  String? _contactName;
  AppHelpDoc? _guide;
  bool _isSignedInMember = false;
  String? _appName;

  /// Counts the screens in the app hiding the tabs with [HideAppHelpTab].
  final AppHelpTabController _tabController = AppHelpTabController();

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _appName = _nonEmpty(widget.appName);
    if (!widget.enabled) return;
    _resolve();
  }

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  /// Works out whether the user is a member (no signed-in user counts as a
  /// guest), then loads the matching guide and, for members, Request a
  /// change.
  Future<void> _resolve() async {
    final user = widget.currentUser;
    final isSignedInMember = user != null &&
        await GuestStatusService.instance
            .isMemberOfActiveGroup(isAnonymous: user.isAnonymous);
    _isSignedInMember = isSignedInMember;
    if (!mounted) return;
    await Future.wait([
      _resolveGuide(forGuest: !isSignedInMember),
      if (user != null) _resolveRequestChange(user, isSignedInMember),
      if (user != null) _resolveContact(user),
    ]);
  }

  /// "Contact {group}": anyone with Help Desk in the active group, except
  /// inside Help Desk itself.
  Future<void> _resolveContact(fire_auth.User user) async {
    if (widget.appId == help_desk.APP_ID) return;
    final groupId = ActiveGroupService.instance.activeGroupId ?? '';
    final entitlements = await UserAppEntitlements.load(user.uid, appId: help_desk.APP_ID);
    if (!mayContactHelpDesk(entitlements, groupId) || !mounted) return;
    final name = _nonEmpty(ActiveGroupService.instance.activeGroupName) ?? 'support';
    setState(() => _contactName = name);
  }

  Future<void> _resolveGuide({required bool forGuest}) async {
    final guide = await widget.loadGuide(widget.appId, forGuest: forGuest);
    if (guide == null || !mounted) return;
    setState(() => _guide = guide);
  }

  Future<void> _resolveRequestChange(
    fire_auth.User user,
    bool isSignedInMember,
  ) async {
    // Guests (visitors and clients) never get Request a change.
    if (!isRequestChangeCandidate(
      appId: widget.appId,
      isSignedInMember: isSignedInMember,
    )) {
      return;
    }

    final groupId = ActiveGroupService.instance.activeGroupId;
    final results = await Future.wait<Object?>([
      UserAppEntitlements.load(user.uid, appId: improveBluejayAppId),
      widget.allowChangeRequests == null || _appName == null
          ? _loadAppDoc()
          : Future<Object?>.value(null),
    ]);
    final entitlements = results[0] as UserAppEntitlements;
    final appDoc = results[1] as Map<String, dynamic>?;
    _appName ??= _nonEmpty(appDoc?['name'] as String?);
    final available = canOfferRequestChange(
      appId: widget.appId,
      allowChangeRequests: widget.allowChangeRequests ??
          (appDoc?['allowChangeRequests'] as bool? ?? true),
      isSignedInMember: isSignedInMember,
      activeGroupId: groupId,
      entitlements: entitlements,
    );
    if (!available || !mounted) return;
    setState(() => _canRequestChange = true);
    // Resolve the name now so the tooltip can use it.
    if (_appName == null) {
      await _resolveAppName();
      if (mounted) setState(() {});
    }
  }

  /// The app's `apps` doc, looked up by its appId slug; null if unreadable.
  Future<Map<String, dynamic>?> _loadAppDoc() async {
    try {
      final snap = await BluejayFirestore.forApp(improveBluejayAppId)
          .collection('apps')
          .where('appId', isEqualTo: widget.appId)
          .limit(1)
          .get();
      return snap.docs.isEmpty ? null : snap.docs.first.data();
    } catch (_) {
      return null;
    }
  }

  Future<String> _resolveAppName() async {
    final known = _appName;
    if (known != null) return known;
    // Guests skip the `apps` read, as they do for Request a change.
    final name = _isSignedInMember
        ? _nonEmpty((await _loadAppDoc())?['name'] as String?)
        : null;
    final resolved = name ?? fallbackAppDisplayName(widget.appId);
    _appName = resolved;
    return resolved;
  }

  Future<void> _onTap() async {
    final appName = await _resolveAppName();
    if (!mounted) return;
    final guide = _guide;
    final offerAsk = _isSignedInMember && guide != null;
    if (!_canRequestChange && _contactName == null && !offerAsk) {
      if (guide != null) await showAppHelp(context, appName: appName, doc: guide);
      return;
    }
    await showRequestChangeSheet(
      context,
      appId: widget.appId,
      appName: appName,
      currentUser: widget.currentUser,
      guide: guide,
      contactName: _contactName,
      offerRequests: _canRequestChange,
      offerAsk: offerAsk,
    );
  }

  String get _tooltip {
    final name = _appName;
    if (_guide != null || _contactName != null) return name == null ? 'Help with this app' : 'Help with $name';
    return name == null ? 'Request a change to this app' : 'Request a change to $name';
  }

  @override
  Widget build(BuildContext context) {
    final available = _canRequestChange || _guide != null || _contactName != null;
    return AppEdgeTabs(
      controller: _tabController,
      help: available
          ? AppEdgeTab(
              icon: _guide != null || _contactName != null
                  ? Icons.help_outline_rounded
                  : Icons.rate_review_outlined,
              tooltip: _tooltip,
              onTap: _onTap,
            )
          : null,
      chat: widget.enabled ? widget.chatTab : null,
      child: widget.child,
    );
  }
}

/// One of the launcher's tabs on the right edge of every app: the help tab,
/// and the root app's chat tab above it. [badge] sits over its top-left
/// corner, e.g. an unread count. [gradient] replaces the theme's hero
/// gradient, so stacked tabs can be told apart; [light] instead draws a
/// quiet white tab with a hairline border and a muted icon.
class AppEdgeTab extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Widget? badge;
  final Gradient? gradient;
  final bool light;

  const AppEdgeTab({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.badge,
    this.gradient,
    this.light = false,
  });

  static final _radius =
      BorderRadius.horizontal(left: Radius.circular(BjRadius.lg));

  @override
  Widget build(BuildContext context) {
    final bj = context.bj;
    final tab = Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: DecoratedBox(
          decoration: light
              ? BoxDecoration(
                  color: bj.surface,
                  border: Border(
                    left: BorderSide(color: bj.border),
                    top: BorderSide(color: bj.border),
                    bottom: BorderSide(color: bj.border),
                  ),
                  borderRadius: _radius,
                  boxShadow: bj.shadowSm,
                )
              : BoxDecoration(
                  gradient: gradient ?? bj.heroGradient,
                  borderRadius: _radius,
                  boxShadow: bj.shadowMd,
                ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              borderRadius: _radius,
              child: SizedBox(
                width: AppEdgeTabs.tabWidth,
                height: AppEdgeTabs.tabHeight,
                child: Icon(
                  icon,
                  size: 24,
                  color: light ? bj.inkMuted : Theme.of(context).colorScheme.onPrimary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final badge = this.badge;
    if (badge == null) return tab;
    // The badge overhangs the corner; the tooltip already says the count.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        tab,
        Positioned(left: -6, top: -6, child: ExcludeSemantics(child: badge)),
      ],
    );
  }
}
