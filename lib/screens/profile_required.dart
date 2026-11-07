import 'package:flutter/material.dart';

import '../data.dart';

/// Amount entry needs the owner's currency, including after a failed first load.
class ProfileRequired extends StatelessWidget {
  const ProfileRequired({super.key, required this.data, required this.builder});

  final AppData data;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: data,
    builder: (context, _) {
      if (data.profile != null) return builder(context);
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              data.loading ? 'Loading your profile and currency…' : 'Load your profile and currency before adding a payment or plan.',
            ),
            if (data.error != null)
              const Text('Could not load your profile. Try again.'),
            TextButton(
              onPressed: data.loading ? null : data.refresh,
              child: const Text('Reload profile'),
            ),
          ],
        ),
      );
    },
  );
}
