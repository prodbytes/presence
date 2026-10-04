import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:presence_app/auth/google_auth_service.dart';

void main() {
  test('a sign-in error is logged with its code, description and details', () {
    expect(
      GoogleAuthService.details(
        const GoogleSignInException(
          code: GoogleSignInExceptionCode.providerConfigurationError,
          description: 'Developer console is not set up correctly.',
          details: '[28444] androidx.credentials.TYPE_UNKNOWN',
        ),
      ),
      'providerConfigurationError; Developer console is not set up '
      'correctly.; details: [28444] androidx.credentials.TYPE_UNKNOWN',
    );
    expect(
      GoogleAuthService.details(
        const GoogleSignInException(code: GoogleSignInExceptionCode.canceled),
      ),
      'canceled',
    );
    expect(GoogleAuthService.details(StateError('x')), 'Bad state: x');
  });
}
