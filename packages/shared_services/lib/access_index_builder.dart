import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/widgets.dart';

import 'access_index.dart';
import 'bluejay_firestore.dart';
import 'user_app_entitlements.dart';

/// Builds from [uid]'s access index ([AccessIndex.snapshots]) with the shared
/// listener's latest value ([AccessIndex.current]) already in place on the
/// first frame.
///
/// A plain StreamBuilder over [AccessIndex.snapshots] shows its waiting state
/// for one frame even when the value is cached, because the stream replays
/// it a microtask after subscribing. This one starts from that same value,
/// reported as [ConnectionState.active], so only the timing changes: a
/// `connectionState == waiting` or `!hasData` check sees what it would have
/// seen a microtask later. Before the listener has a value (or with a
/// [firestore] override, which bypasses the shared listener) it waits as
/// usual.
class AccessIndexBuilder extends StatelessWidget {
  const AccessIndexBuilder({
    super.key,
    required this.uid,
    required this.appId,
    this.firestore,
    required this.builder,
  });

  final String uid;

  /// The app an uncached read is attributed to (see [AccessIndex]).
  final String appId;

  /// Tests: read this instance instead of the shared listener.
  final FirebaseFirestore? firestore;

  final AsyncWidgetBuilder<AccessIndexSnapshot> builder;

  @override
  Widget build(BuildContext context) => PrimedStreamBuilder<AccessIndexSnapshot>(
        stream: AccessIndex.snapshots(uid, appId: appId, firestore: firestore),
        initialData: AccessIndex.current(uid, firestore: firestore),
        builder: builder,
      );
}

/// [AccessIndexBuilder] for [AccessIndex.watch]: builds from the access index
/// parsed by [parse], starting from [AccessIndex.currentAs]. Pass a static
/// function or constructor tear-off as [parse] (see [AccessIndex.watch]).
class AccessIndexWatchBuilder<T> extends StatelessWidget {
  const AccessIndexWatchBuilder({
    super.key,
    required this.uid,
    required this.appId,
    required this.parse,
    this.firestore,
    required this.builder,
  });

  final String uid;
  final String appId;
  final T Function(Map<String, dynamic>? data) parse;
  final FirebaseFirestore? firestore;
  final AsyncWidgetBuilder<T> builder;

  @override
  Widget build(BuildContext context) => PrimedStreamBuilder<T>(
        stream: AccessIndex.watch(uid, appId: appId, parse: parse, firestore: firestore),
        initialData: AccessIndex.currentAs(uid, parse: parse, firestore: firestore),
        builder: builder,
      );
}

/// [AccessIndexBuilder] for [UserAppEntitlements.watch], starting from
/// [UserAppEntitlements.current].
class UserAppEntitlementsBuilder extends StatelessWidget {
  const UserAppEntitlementsBuilder({
    super.key,
    required this.uid,
    this.appId = platformAppId,
    required this.builder,
  });

  final String uid;
  final String appId;
  final AsyncWidgetBuilder<UserAppEntitlements> builder;

  @override
  Widget build(BuildContext context) => PrimedStreamBuilder<UserAppEntitlements>(
        stream: UserAppEntitlements.watch(uid, appId: appId),
        initialData: UserAppEntitlements.current(uid),
        builder: builder,
      );
}

/// A StreamBuilder whose [initialData] is the value [stream] replays to a new
/// subscriber (for the access index: [AccessIndex.current] /
/// [AccessIndex.currentAs] / [UserAppEntitlements.current], or null when
/// there is none yet). Until the stream delivers, the builder sees that value
/// as [ConnectionState.active] data, so the first frame matches the one a
/// microtask later. With a null
/// [initialData] it behaves exactly like a StreamBuilder.
///
/// The widgets above use it; call it directly where a screen keeps the
/// stream in its state (e.g. to swap it to null or re-create it on retry).
class PrimedStreamBuilder<T> extends StatelessWidget {
  const PrimedStreamBuilder({
    super.key,
    required this.stream,
    this.initialData,
    required this.builder,
  });

  final Stream<T>? stream;
  final T? initialData;
  final AsyncWidgetBuilder<T> builder;

  @override
  Widget build(BuildContext context) => StreamBuilder<T>(
        stream: stream,
        initialData: initialData,
        builder: (context, snapshot) {
          // Only the untouched initial value: after a stream swap the
          // waiting snapshot carries the previous stream's data, which
          // stays waiting.
          final primed = initialData != null &&
              snapshot.connectionState == ConnectionState.waiting &&
              identical(snapshot.data, initialData);
          return builder(
            context,
            primed ? AsyncSnapshot<T>.withData(ConnectionState.active, initialData as T) : snapshot,
          );
        },
      );
}
