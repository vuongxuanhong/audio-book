import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide IconAlignment;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

/// Both sign-in buttons share one size and shape: App Store Review
/// Guideline 4.8 wants Sign in with Apple at least as prominent as any other
/// third-party login offered next to it.
const double _kButtonHeight = 44;
const double _kButtonWidth = 300;
const BorderRadius _kButtonRadius = BorderRadius.all(Radius.circular(22));

/// Sign in with Apple is only offered on iOS: elsewhere it needs a web
/// redirect flow the app doesn't set up, and Apple only requires it where
/// the App Store reviews the app.
bool get showAppleSignIn =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// "Sign in with Google" as Google's branding guidelines draw it: the
/// standard multicolour G, never recoloured, on a white (light) or
/// near-black (dark) button with a thin grey stroke and Roboto Medium 14.
/// https://developers.google.com/identity/branding-guidelines
class GoogleSignInButton extends StatelessWidget {
  const GoogleSignInButton({super.key, required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fill = dark ? const Color(0xFF131314) : const Color(0xFFFFFFFF);
    final stroke = dark ? const Color(0xFF8E918F) : const Color(0xFF747775);
    final text = dark ? const Color(0xFFE3E3E3) : const Color(0xFF1F1F1F);

    return SizedBox(
      width: _kButtonWidth,
      height: _kButtonHeight,
      child: Material(
        color: fill,
        shape: RoundedRectangleBorder(
          borderRadius: _kButtonRadius,
          side: BorderSide(color: stroke),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                SvgPicture.string(_googleG, width: 20, height: 20),
                Expanded(
                  child: Text(
                    'Đăng nhập bằng Google',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Roboto',
                      fontSize: 14,
                      height: 20 / 14,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.25,
                      color: text,
                    ),
                  ),
                ),
                // Balances the logo so the label sits in the true centre.
                const SizedBox(width: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Apple's own button from `sign_in_with_apple`, which follows the Human
/// Interface Guidelines: black on a light background, white on a dark one.
class AppleSignInButton extends StatelessWidget {
  const AppleSignInButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      width: _kButtonWidth,
      child: SignInWithAppleButton(
        onPressed: onPressed,
        text: 'Đăng nhập bằng Apple',
        height: _kButtonHeight,
        borderRadius: _kButtonRadius,
        iconAlignment: IconAlignment.left,
        style: dark
            ? SignInWithAppleButtonStyle.white
            : SignInWithAppleButtonStyle.black,
      ),
    );
  }
}

/// The standard Google "G" mark, from Google's sign-in branding kit.
const _googleG = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
<path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"/>
<path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"/>
<path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z"/>
<path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"/>
</svg>
''';
