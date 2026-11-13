// The Cloudflare challenge uses ResultReceiver Parcelables across the isolated
// :network_challenge process boundary. Android can deliver a Bundle without the
// app classloader, which causes a release-only ClassNotFoundException on lazy
// getParcelable() unless the loader is set first.
import 'dart:io';

import 'package:test/test.dart';

void main() {
  final String activity = File(
    'android/app/src/main/kotlin/app/fushi/reader/mihon/CloudflareChallengeActivity.kt',
  ).readAsStringSync();
  final String coordinator = File(
    'android/app/src/main/kotlin/app/fushi/reader/mihon/CloudflareChallengeCoordinator.kt',
  ).readAsStringSync();

  test(
    'challenge Activity sets the app loader before unpacking the callback',
    () {
      final int loader = activity.indexOf('intent.setExtrasClassLoader(');
      final int receiver = activity.indexOf(
        'intent.getParcelableExtra("receiver")',
      );
      expect(loader, isNonNegative);
      expect(receiver, greaterThan(loader));
    },
  );

  test(
    'coordinator sets the app loader before unpacking the control receiver',
    () {
      final int loader = coordinator.indexOf('controlData.classLoader =');
      final int receiver = coordinator.indexOf(
        'controlData.getParcelable("control")',
      );
      expect(loader, isNonNegative);
      expect(receiver, greaterThan(loader));
      expect(
        coordinator.substring(loader, receiver),
        contains('CloudflareChallengeCoordinator::class.java.classLoader'),
      );
    },
  );
}
