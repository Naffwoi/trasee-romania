import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanderer/provider/compass_heading_stream_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'acquires source only while watched and pauses on AppLifecycleState.paused',
    () async {
      var startCount = 0;
      var stopCount = 0;
      final rawController = StreamController<double>.broadcast(
        onListen: () => startCount++,
        onCancel: () => stopCount++,
      );

      final container = ProviderContainer(
        overrides: [
          rawAzimuthDegreesStreamFactoryProvider.overrideWithValue(
            () => rawController.stream,
          ),
        ],
      );

      final received = <CompassHeadingReading?>[];
      StreamSubscription<CompassHeadingReading?>? streamSub;
      addTearDown(() async {
        await streamSub?.cancel();
        container.dispose();
        await rawController.close();
      });

      final sub = container.listen(liveCompassProvider, (_, stream) {
        streamSub?.cancel();
        streamSub = stream.listen(received.add);
      }, fireImmediately: true);

      expect(startCount, 1);
      rawController.add(90.0);
      await Future<void>.delayed(Duration.zero);
      expect(received.last?.heading, closeTo(90.0, 0.1));

      // Simulate app backgrounding -> sensor subscription cancelled
      container
          .read(compassHeadingStreamProvider.notifier)
          .didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      expect(stopCount, 1);

      // Simulate app foregrounding -> sensor subscription resumed
      container
          .read(compassHeadingStreamProvider.notifier)
          .didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(startCount, 2);

      sub.close();
      await Future<void>.delayed(Duration.zero);
      expect(stopCount, 2);
    },
  );
}
