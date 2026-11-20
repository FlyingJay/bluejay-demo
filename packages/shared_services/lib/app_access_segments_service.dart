import 'package:cloud_functions/cloud_functions.dart';

import 'active_group_service.dart';
import 'package:shared_services/cloud_functions.dart';

/// A named group of users within a group who share access to a set of
/// segment-gated apps. See `functions/app_access_segments.js` and
/// `computeEntitlements`'s segment governance in `functions/_shared.js` for
/// the backend enforcement — this class only mirrors the callable payloads.
class AppAccessSegment {
  final String id;
  final String groupId;
  final String name;
  final List<String> memberUserIds;
  final List<String> includedAppIds;

  const AppAccessSegment({
    required this.id,
    required this.groupId,
    required this.name,
    required this.memberUserIds,
    required this.includedAppIds,
  });

  factory AppAccessSegment.fromData(Map<String, dynamic> data) {
    return AppAccessSegment(
      id: data['id'] as String? ?? '',
      groupId: data['groupId'] as String? ?? '',
      name: data['name'] as String? ?? '',
      memberUserIds: List<String>.from(data['memberUserIds'] as List? ?? const []),
      includedAppIds: List<String>.from(data['includedAppIds'] as List? ?? const []),
    );
  }
}

/// Thin client for the `appAccess*Segment*` callables. Reads and writes
/// always go through Cloud Functions rather than direct Firestore access —
/// see the doc comment at the top of `functions/app_access_segments.js` for
/// why (group admin status can't be reliably read from entitlements alone
/// in this codebase).
class AppAccessSegmentsService {
  final FirebaseFunctions _functions;

  AppAccessSegmentsService({FirebaseFunctions? functions})
      : _functions = functions ?? BluejayFunctions.instance;

  String get _groupId => ActiveGroupService.instance.activeGroupId ?? '';

  Future<List<AppAccessSegment>> listSegments() async {
    final groupId = _groupId;
    if (groupId.isEmpty) return const [];

    final result = await _functions.httpsCallable('appAccessListSegments').call({
      'groupId': groupId,
    });
    final data = result.data;
    final rawSegments = data is Map ? data['segments'] : null;
    if (rawSegments is! List) return const [];

    return rawSegments
        .whereType<Map>()
        .map((raw) => AppAccessSegment.fromData(Map<String, dynamic>.from(raw)))
        .toList();
  }

  Future<AppAccessSegment> createSegment({
    required String name,
    required List<String> memberUserIds,
    required List<String> includedAppIds,
  }) async {
    final groupId = _groupId;
    if (groupId.isEmpty) {
      throw StateError('No active group selected.');
    }

    final result = await _functions.httpsCallable('appAccessCreateSegment').call({
      'groupId': groupId,
      'name': name,
      'memberUserIds': memberUserIds,
      'includedAppIds': includedAppIds,
    });
    final data = result.data;
    final rawSegment = data is Map ? data['segment'] : null;
    if (rawSegment is! Map) {
      throw StateError('Unexpected response creating segment.');
    }
    return AppAccessSegment.fromData(Map<String, dynamic>.from(rawSegment));
  }

  Future<AppAccessSegment> updateSegment({
    required String segmentId,
    String? name,
    List<String>? memberUserIds,
    List<String>? includedAppIds,
  }) async {
    final groupId = _groupId;
    if (groupId.isEmpty) {
      throw StateError('No active group selected.');
    }

    final payload = <String, dynamic>{
      'groupId': groupId,
      'segmentId': segmentId,
    };
    if (name != null) payload['name'] = name;
    if (memberUserIds != null) payload['memberUserIds'] = memberUserIds;
    if (includedAppIds != null) payload['includedAppIds'] = includedAppIds;

    final result = await _functions.httpsCallable('appAccessUpdateSegment').call(payload);
    final data = result.data;
    final rawSegment = data is Map ? data['segment'] : null;
    if (rawSegment is! Map) {
      throw StateError('Unexpected response updating segment.');
    }
    return AppAccessSegment.fromData(Map<String, dynamic>.from(rawSegment));
  }

  Future<void> deleteSegment(String segmentId) async {
    final groupId = _groupId;
    if (groupId.isEmpty) {
      throw StateError('No active group selected.');
    }

    await _functions.httpsCallable('appAccessDeleteSegment').call({
      'groupId': groupId,
      'segmentId': segmentId,
    });
  }
}
