# Development — Feature Improvements

## 1. Deploy a PR's server changes to its preview

**Problem:** Previews run the PR's client code against `main`'s Cloud Functions and rules, so a feature that needs new server behaviour looks incomplete when the requester tries it.

**Proposal:** A small pool of sandbox projects leased to PRs that change server code, each getting the PR's affected functions and rules. The full plan, constraints and the setup steps to repeat are in `plans/preview-sandbox/PR_BACKEND_PREVIEWS.md`.

## 2. Google sign-in in the sandbox

**Problem:** Members who only sign in with Google can't sign in to a preview. Preview builds show a notice instead (`FederatedSignIn.previewUnavailable`).

**Proposal:** Add `https://bluejay-preview-sandbox.firebaseapp.com/__/auth/handler` to the production web OAuth client's redirect URIs, enable the Google provider on `bluejay-preview-sandbox` with that client, then set `kPreviewFederatedSignInEnabled` to true in `packages/shared_services/lib/app_environment.dart`.
