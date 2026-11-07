import 'package:flutter/material.dart';

import '../data.dart';
import '../theme.dart';

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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              data.loading ? 'Loading your profile and currency…' : 'Load your profile and currency before adding a payment or plan.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (data.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Could not load your profile. Try again.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: context.mc.negative),
                ),
              ),
            const SizedBox(height: 8),
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
