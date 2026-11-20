import 'package:dev_queue/dev_queue.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';

/// One recorded callable call.
class RecordedCall {
  final String name;
  final Map<String, Object?> data;

  RecordedCall(this.name, this.data);

  @override
  String toString() => '$name $data';
}

/// A [DevQueueService] over [FakeFirebaseFirestore] whose callables are
/// recorded and answered by [respond].
class FakeQueue {
  final firestore = FakeFirebaseFirestore();
  final calls = <RecordedCall>[];

  /// Returns the callable's result, or throws to refuse it.
  Object? Function(RecordedCall call) respond = (call) {
    if (call.name == 'devQueueListManaged') return {'groups': <Object?>[]};
    return {'success': true};
  };

  late final DevQueueService service = DevQueueService(
    firestore: firestore,
    newKey: () => 'key-${calls.length}',
    call: (name, data) async {
      final call = RecordedCall(name, data);
      calls.add(call);
      return respond(call);
    },
  );

  Future<void> addItem(String key, Map<String, Object?> data) =>
      firestore.collection('dev_queue_items').doc(key).set({
        'ownerId': 'u1',
        'active': true,
        'managed': false,
        ...data,
      });
}

/// Item fields for a state, with the status the server would write.
Map<String, Object?> itemFields({
  required String state,
  required String code,
  required String label,
  String title = 'Export to CSV',
  double rank = 1,
  String detail = '',
  Map<String, Object?>? waiting,
  Map<String, Object?>? preview,
  bool active = true,
  bool managed = false,
  DateTime? stateChangedAt,
  String? shippedAppId,
  Map<String, Object?>? closure,
}) =>
    {
      'state': state,
      'title': title,
      'rank': rank,
      'relatedAppId': 'notes',
      'payload': {
        'ticket': {'relatedAppName': 'Notes'},
      },
      'active': active,
      'managed': managed,
      'status': {'code': code, 'label': label, 'detail': detail},
      'waiting': waiting,
      'preview': preview,
      'stateChangedAt': stateChangedAt,
      'shippedAppId': shippedAppId,
      'closure': closure,
    };
