/// Which backend this build of the app talks to.
///
/// Production builds leave `BLUEJAY_ENVIRONMENT` unset. Pull request preview
/// builds (`.github/workflows/deploy.yml`) set it to `preview`, install the
/// sandbox project's `firebase_options.dart` from `config/preview_sandbox/`,
/// and are served from the sandbox project's Hosting preview channels, so
/// the whole preview (data, sign-in, storage, functions) runs against
/// [kPreviewSandboxProjectId] and never against production.
library;

/// `production` (the default) or `preview`.
const String kBluejayEnvironment = String.fromEnvironment('BLUEJAY_ENVIRONMENT', defaultValue: 'production');

/// Whether this is a pull request preview build, backed by the sandbox.
const bool kIsPreviewBuild = kBluejayEnvironment == 'preview';

/// The production Firebase project.
const String kProductionProjectId = 'bluejay-d926f';

/// The Firebase project pull request previews run against: a copy of the
/// requesting group's data, with billing, email, SMS, push and AI turned off.
const String kPreviewSandboxProjectId = 'bluejay-preview-sandbox';

/// The Firebase project this build talks to.
const String kFirebaseProjectId = kIsPreviewBuild ? kPreviewSandboxProjectId : kProductionProjectId;

/// Whether Google (and other provider) sign-in works in preview builds. The
/// sandbox project needs the provider turned on, with the sandbox's auth
/// handler (`https://bluejay-preview-sandbox.firebaseapp.com/__/auth/handler`)
/// added to the OAuth client's redirect URIs; until then a preview explains
/// that provider sign-in isn't available (federated_sign_in.dart).
const bool kPreviewFederatedSignInEnabled = false;

/// Whether provider sign-in is unavailable in this build.
const bool kFederatedSignInUnavailable = kIsPreviewBuild && !kPreviewFederatedSignInEnabled;
