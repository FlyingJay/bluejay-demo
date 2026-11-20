import 'package:flutter/foundation.dart';

import 'cloud_functions.dart';
import 'scoped_collection.dart';

/// An active client of a group's portal, as a member of one of the portal's
/// apps may pick them (to share a file with, or start a conversation with).
@immutable
class PortalAppClient {
  const PortalAppClient({required this.uid, this.name = '', this.email = ''});

  final String uid;
  final String name;
  final String email;

  /// The name, else the email, else the uid.
  String get label => name.isNotEmpty ? name : (email.isNotEmpty ? email : uid);

  factory PortalAppClient.fromMap(Map<String, dynamic> data) => PortalAppClient(
        uid: data['uid'] as String? ?? '',
        name: data['name'] as String? ?? '',
        email: data['email'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      other is PortalAppClient && other.uid == uid && other.name == name && other.email == email;

  @override
  int get hashCode => Object.hash(uid, name, email);
}

/// The active clients of [groupId] whose portal gives them [appId]
/// (`portalListAppClients`, functions/client_portal.js): empty when the
/// portal is off or doesn't give clients that app. Only members who use
/// [appId] may ask.
Future<List<PortalAppClient>> listPortalClientsForApp({
  required String groupId,
  required String appId,
}) async {
  final result = await BluejayFunctions.instance
      .httpsCallable('portalListAppClients')
      .call({'groupId': groupId, 'appId': appId});
  final data = Map<String, dynamic>.from(result.data as Map);
  return [
    for (final raw in (data['clients'] as List? ?? const []))
      PortalAppClient.fromMap(Map<String, dynamic>.from(raw as Map)),
  ].where((c) => c.uid.isNotEmpty).toList();
}

final _portalConfigs = ScopedCollection(collection: 'portal_configs', appId: 'app-access');

/// Whether the portal of group [groupDocId] is on and gives its clients
/// [appId] (`portal_configs/{groupDocId}`, which members read). False when
/// it can't be read.
Future<bool> portalGivesApp(String groupDocId, String appId) async {
  if (groupDocId.isEmpty) return false;
  try {
    final data = (await _portalConfigs.doc(groupDocId).get()).data();
    final apps = data?['apps'];
    return data?['enabled'] == true && apps is List && apps.contains(appId);
  } catch (_) {
    return false;
  }
}
