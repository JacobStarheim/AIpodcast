import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../session_controller.dart';
import 'app_theme.dart';
import 'common.dart';

/// Email and password sign-in. Accounts are created by an administrator.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.session});
  final SessionController session;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final email = TextEditingController();
  final password = TextEditingController();
  final passwordFocus = FocusNode();
  bool showPassword = false;

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final session = widget.session;
    if (session.isSigningIn) return;
    final signedIn =
        await session.signIn(email: email.text, password: password.text);
    if (signedIn) {
      TextInput.finishAutofillContext();
    } else if (mounted && session.signInError != null) {
      password.clear();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.session,
        builder: (context, _) {
          final session = widget.session;
          final busy = session.isSigningIn;
          final notice = session.notice;
          final error = session.signInError;
          return Scaffold(
            body: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: AutofillGroup(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: BrandMark(size: 40)),
                          const SizedBox(height: 22),
                          Semantics(
                            header: true,
                            child: Text('Sign in',
                                style:
                                    Theme.of(context).textTheme.headlineLarge),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                              'Use the account your administrator created for you.',
                              style: TextStyle(color: AppColors.muted)),
                          if (notice != null) ...[
                            const SizedBox(height: 18),
                            Semantics(
                              liveRegion: true,
                              child: Container(
                                key: const ValueKey('login-notice'),
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                    color: AppColors.sage,
                                    borderRadius: BorderRadius.circular(16)),
                                child: Text(notice,
                                    style: const TextStyle(
                                        fontSize: 13, height: 1.5)),
                              ),
                            ),
                          ],
                          const SizedBox(height: 24),
                          TextField(
                            key: const ValueKey('login-email'),
                            controller: email,
                            enabled: !busy,
                            keyboardType: TextInputType.emailAddress,
                            autocorrect: false,
                            enableSuggestions: false,
                            textInputAction: TextInputAction.next,
                            autofillHints: const [
                              AutofillHints.username,
                              AutofillHints.email,
                            ],
                            onSubmitted: (_) => passwordFocus.requestFocus(),
                            decoration: const InputDecoration(
                              labelText: 'Email',
                              prefixIcon: Icon(Icons.mail_outline_rounded),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            key: const ValueKey('login-password'),
                            controller: password,
                            focusNode: passwordFocus,
                            enabled: !busy,
                            obscureText: !showPassword,
                            autocorrect: false,
                            enableSuggestions: false,
                            textInputAction: TextInputAction.done,
                            autofillHints: const [AutofillHints.password],
                            onSubmitted: (_) => _submit(),
                            decoration: InputDecoration(
                              labelText: 'Password',
                              prefixIcon:
                                  const Icon(Icons.lock_outline_rounded),
                              suffixIcon: IconButton(
                                tooltip: showPassword
                                    ? 'Hide password'
                                    : 'Show password',
                                onPressed: () => setState(
                                    () => showPassword = !showPassword),
                                icon: Icon(showPassword
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined),
                              ),
                            ),
                          ),
                          if (error != null) ...[
                            const SizedBox(height: 12),
                            Semantics(
                              liveRegion: true,
                              child: Text(error,
                                  key: const ValueKey('login-error'),
                                  style: const TextStyle(
                                      color: AppColors.orange, fontSize: 13)),
                            ),
                          ],
                          const SizedBox(height: 20),
                          FilledButton(
                            key: const ValueKey('login-submit'),
                            onPressed: busy ? null : _submit,
                            child: busy
                                ? const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox.square(
                                          dimension: 16,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2)),
                                      SizedBox(width: 10),
                                      Flexible(child: Text('Signing in…')),
                                    ],
                                  )
                                : const Text('Sign in'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
}
