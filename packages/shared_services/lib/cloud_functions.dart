/// The one place client code reaches Bluejay's Cloud Functions.
///
/// Every callable goes through [BluejayFunctions.instance], and every URL of
/// an `onRequest` function is built with [BluejayFunctions.functionUri], so
/// the region the app talks to is stated once, here ([kFunctionsRegion]).
/// `scripts/check_gateways.js` (rule `cloud-functions-client`) fails CI on
/// `FirebaseFunctions.instance`, `FirebaseFunctions.instanceFor` or a
/// `cloudfunctions.net` URL anywhere else in client code.
///
/// The server side of the same policy is `functions/_function_regions.js`
/// (`CLIENT_REGION`, `PUBLIC_HOST`, `PUBLIC_FUNCTION_PATHS`);
/// `functions/_function_regions.test.js` keeps the two equal.
library;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

import 'app_environment.dart';

/// The region every Bluejay Cloud Function is called in.
const String kFunctionsRegion = 'northamerica-northeast2';

/// The Firebase project the functions belong to: production, or the preview
/// sandbox in a pull request preview build (app_environment.dart).
const String kFunctionsProjectId = kFirebaseProjectId;

/// `https://<region>-<project>.cloudfunctions.net`: the base of every
/// `onRequest` function URL, for `const` contexts (`'$kFunctionsBaseUrl/fn'`).
/// Prefer [BluejayFunctions.functionUri] elsewhere.
const String kFunctionsBaseUrl = 'https://$kFunctionsRegion-$kFunctionsProjectId.cloudfunctions.net';

/// The host serving the app and its region-free public links.
const String kPublicHost = 'bluejay.gg';

/// The host to build links people keep or share on (sales pages, portal and
/// form invitations, calendar feeds): [kPublicHost], except in a pull
/// request preview build on the web, where it is the preview's own host
/// (`bluejay-preview-sandbox--pr-12-abc.web.app`). Every preview channel
/// serves the same paths and firebase.json rewrites, so a link copied in a
/// preview opens the preview and its sandbox data rather than production.
/// `scripts/check_gateways.js` (rule `public-link-host`) fails CI on a
/// `bluejay.gg` link written anywhere else in client code.
String get publicLinkHost => publicLinkHostFor(previewBuild: kIsPreviewBuild, page: kIsWeb ? Uri.base : null);

/// [publicLinkHost] for a build that is or isn't a preview, on [page] (the
/// browser's URL on web, null elsewhere).
@visibleForTesting
String publicLinkHostFor({required bool previewBuild, Uri? page}) {
  if (!previewBuild || page == null || page.scheme != 'https' || page.host.isEmpty) return kPublicHost;
  return page.host;
}

/// The typed entry point for calling a callable by name: [call] with the
/// name written literally at the call site (`BluejayCallable.call('x', data)`).
/// The security tier audit's `writesThroughCallables` check reads callable
/// names only from this form and `httpsCallable('x')`, so an app that opts
/// in calls every callable this way and never holds a callable client.
class BluejayCallable {
  BluejayCallable._();

  /// Calls callable [name] with [data] and returns its result's data.
  /// Throws [FirebaseFunctionsException] as the callable SDK does.
  static Future<Object?> call(String name, [Object? data, HttpsCallableOptions? options]) async {
    final callable = options == null
        ? BluejayFunctions.instance.httpsCallable(name)
        : BluejayFunctions.instance.httpsCallable(name, options: options);
    final result = await callable.call<Object?>(data);
    return result.data;
  }
}

class BluejayFunctions {
  BluejayFunctions._();

  /// The callable client. Use this instead of `FirebaseFunctions.instance`.
  static FirebaseFunctions get instance => FirebaseFunctions.instanceFor(region: kFunctionsRegion);

  /// The callable client for functions deployed in a group's data region
  /// rather than [kFunctionsRegion] (the warehouse's row-data callables,
  /// pinned to where the group's rows live). Null [region] is [instance].
  static FirebaseFunctions inRegion(String? region) =>
      region == null ? instance : FirebaseFunctions.instanceFor(region: region);

  /// A callable by [name], with [options] (e.g. a longer timeout).
  static HttpsCallable callable(String name, {HttpsCallableOptions? options}) =>
      instance.httpsCallable(name, options: options);

  /// HTTPS URL of `onRequest` function [name], for code that calls it with
  /// `http` (or hands the URL to a browser). [path] is appended after the
  /// function name, for functions that route on it.
  static Uri functionUri(String name, {String path = '', Map<String, String>? query}) {
    final suffix = path.isEmpty ? '' : (path.startsWith('/') ? path : '/$path');
    return Uri.https('$kFunctionsRegion-$kFunctionsProjectId.cloudfunctions.net', '/$name$suffix', query);
  }

  /// [functionUri] as a string.
  static String functionUrl(String name, {String path = '', Map<String, String>? query}) =>
      functionUri(name, path: path, query: query).toString();

  /// A region-free link on [publicLinkHost] for things people keep (feeds,
  /// invitations): firebase.json rewrites the path to its function. The
  /// paths are `PUBLIC_FUNCTION_PATHS` in `functions/_function_regions.js`
  /// (`/rsvp`, `/broker-answers`, `/calendar/ics`, `/files/download`).
  static Uri publicUri(String path, [Map<String, String>? query]) =>
      Uri.https(publicLinkHost, path.startsWith('/') ? path : '/$path', query);
}
