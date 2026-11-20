import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/app_environment.dart';
import 'package:shared_services/federated_sign_in.dart';

void main() {
  tearDown(() => FederatedSignIn.unavailable = kFederatedSignInUnavailable);

  test('provider sign-in is available in production builds', () {
    expect(kIsPreviewBuild, isFalse);
    expect(FederatedSignIn.unavailable, isFalse);
  });

  test('in a preview build, signing in, signing up and linking explain why they are off', () async {
    FederatedSignIn.unavailable = true;
    for (final attempt in <Future<Object?> Function()>[
      () => FederatedSignIn.signIn(FederatedProvider.google),
      () => FederatedSignIn.startSignup(FederatedProvider.google),
      () => FederatedSignIn.link(FederatedProvider.google),
    ]) {
      await expectLater(
        attempt(),
        throwsA(isA<FederatedSignInException>()
            .having((e) => e.code, 'code', FederatedSignIn.previewUnavailableCode)
            .having((e) => e.message, 'message', contains('test versions'))),
      );
    }
  });
}
