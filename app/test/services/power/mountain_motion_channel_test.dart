import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanderer/services/power/mountain_motion_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('MountainMotionChannel invokes native modes and parses wake/variance/battery events', () async {
    final calls = <String>[];
    const methodChannel = MethodChannel('com.openwanderer.wanderer/mountain_motion_test');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
      calls.add(call.method);
      if (call.method == 'getBatterySnapshot') {
        return <String, Object?>{
          'batteryPercent': 18,
          'osLowPowerMode': true,
        };
      }
      return true;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
    });

    final rawEvents = StreamController<Object?>.broadcast();
    addTearDown(rawEvents.close);

    final bridge = MountainMotionChannel(
      methodChannel: methodChannel,
      eventStreamOverride: rawEvents.stream,
      isSupportedPlatformOverride: true,
    );
    addTearDown(bridge.dispose);

    final received = <MountainMotionEvent>[];
    final sub = bridge.events.listen(received.add);
    addTearDown(sub.cancel);

    await bridge.startStepMonitoring();
    await bridge.armStationaryWakeTrigger();
    final battery = await bridge.getBatterySnapshot();

    expect(calls, ['startStepMonitoring', 'armStationaryWakeTrigger', 'getBatterySnapshot']);
    expect(battery.batteryPercent, 18);
    expect(battery.osLowPowerMode, isTrue);

    rawEvents.add(<String, Object?>{
      'kind': 'motion_sample',
      'stepBandVariance': 0.004,
      'isMovingHardware': false,
    });
    rawEvents.add(<String, Object?>{
      'kind': 'step_wake',
      'stepBandVariance': 1.45,
      'isMovingHardware': true,
    });
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(2));
    expect(received[0].kind, MountainMotionEventKind.motionSample);
    expect(received[0].isMovingHardware, isFalse);
    expect(received[1].kind, MountainMotionEventKind.stepWake);
    expect(received[1].isMovingHardware, isTrue);
  });
}
