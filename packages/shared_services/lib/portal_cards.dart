import 'package:flutter/widgets.dart';

/// What a portal home card knows about the client and the group it is
/// shown in.
@immutable
class PortalCardContext {
  const PortalCardContext({
    required this.uid,
    required this.groupDocId,
    required this.groupSlug,
    required this.appId,
    this.onOpenApp,
  });

  /// The signed-in client.
  final String uid;

  /// The group's doc id (`groups/{id}`) and its URL slug.
  final String groupDocId;
  final String groupSlug;

  /// The app the card belongs to (its `apps/{id}` doc id).
  final String appId;

  /// Opens the card's app, for a "See all" action. Null when the launcher
  /// can't open it.
  final VoidCallback? onOpenApp;
}

/// A summary card an app contributes to a client's portal home
/// (plans/business-suite/CLIENT_PORTAL_PLAN.md, Phase C): amount due,
/// next booking, forms to fill. Return null from [build] to show nothing
/// (no data yet, or nothing to say).
@immutable
class PortalCard {
  const PortalCard({required this.appId, required this.build});

  /// The app's `apps/{id}` doc id: the card shows only when the portal gives
  /// clients this app.
  final String appId;
  final Widget? Function(BuildContext context, PortalCardContext card) build;
}

/// The portal home's cards for [appIds], in that order (the portal's app
/// order), from [registry]. The registry itself is a const list in the
/// launcher (lib/routing/portal_cards.dart), which can depend on every app
/// package; apps add their card there, like a public link resolver.
List<PortalCard> portalCardsFor(Iterable<String> appIds, List<PortalCard> registry) => [
      for (final appId in appIds) ...registry.where((card) => card.appId == appId),
    ];
