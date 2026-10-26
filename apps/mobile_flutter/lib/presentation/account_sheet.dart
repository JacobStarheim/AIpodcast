import 'package:flutter/material.dart';

import '../session_controller.dart';
import 'app_theme.dart';
import 'common.dart';

void showAccountSheet(BuildContext context, SessionController session) {
  showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (_) => AccountSheet(session: session),
  );
}

/// Who is signed in, and signing out.
class AccountSheet extends StatelessWidget {
  const AccountSheet({super.key, required this.session});
  final SessionController session;

  @override
  Widget build(BuildContext context) {
    final user = session.user;
    final name = user?.name.trim() ?? '';
    final email = user?.email.trim() ?? '';
    return ConstrainedBox(
      constraints:
          BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .8),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            24, 0, 24, 24 + MediaQuery.paddingOf(context).bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Eyebrow('SIGNED IN AS'),
            const SizedBox(height: 10),
            if (user == null)
              Text('This app’s API key',
                  style: Theme.of(context).textTheme.titleLarge)
            else ...[
              Text(name.isEmpty ? email : name,
                  key: const ValueKey('account-name'),
                  style: Theme.of(context).textTheme.titleLarge),
              if (name.isNotEmpty && email.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(email,
                    key: const ValueKey('account-email'),
                    style: const TextStyle(color: AppColors.muted)),
              ],
            ],
            const SizedBox(height: 24),
            FilledButton.tonalIcon(
              key: const ValueKey('sign-out'),
              onPressed: () {
                Navigator.pop(context);
                session.signOut();
              },
              icon: const Icon(Icons.logout_rounded),
              label: const Text('Sign out'),
            ),
            const SizedBox(height: 8),
            Text(
                user == null
                    ? 'You’ll be asked to sign in with an account.'
                    : 'Playback stops. Your conversations stay on this device for the next time you sign in.',
                style: const TextStyle(color: AppColors.muted, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
