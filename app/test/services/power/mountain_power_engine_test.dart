import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:tracelet/tracelet.dart' as tl;
import 'package:wanderer/services/power/mountain_motion_channel.dart';
import 'package:wanderer/services/power/mountain_power_engine.dart';
import 'package:wanderer/services/tracelet_position_source.dart';

void main() {
  group('MountainPowerEngine state transitions', () {
    test('stays in scrambleGrace under 90s stillness and enters stationaryCabanaSleep after 90s', () {
      var now = DateTime.utc(2026, 11, 18, 10, 0, 0);
      final states = <MountainPowerState>[];
      final tiers = <MountainGpsTier>[];

      final engine = MountainPowerEngine(
        clock: () => now,
        onStateChanged: states.add,
        onGpsTierChanged: tiers.add,
      );
      addTearDown(engine.dispose);

      // Initial walking fix at Bușteni (1.3 m/s).
      engine.ingestGpsFix(lat: 45.4100, lon: 25.5300, speedMps: 1.3, accuracyM: 6.0);
      expect(engine.state, MountainPowerState.movingActive);
      expect(engine.isStatsFrozen, isFalse);

      // Hiker stops on steep scramble / cairn: speed 0.1 m/s + hardware still.
      now = now.add(const Duration(seconds: 20));
      engine.ingestMotionEvent(
        const MountainMotionEvent(
          kind: MountainMotionEventKind.motionSample,
          stepBandVariance: 0.004,
          isMovingHardware: false,
        ),
      );
      engine.ingestGpsFix(lat: 45.41001, lon: 25.53001, speedMps: 0.05, accuracyM: 7.0);

      // At 20s (< 90s): scrambleGrace keeps GPS high-accuracy warm, freezes stopwatch after 15s!
      expect(engine.state, MountainPowerState.scrambleGrace);
      expect(engine.gpsTier, MountainGpsTier.foreground3m);
      expect(engine.isStatsFrozen, isTrue);

      // At 65s: still in scrambleGrace (not sleeping yet).
      now = now.add(const Duration(seconds: 45));
      engine.evaluateTick();
      expect(engine.state, MountainPowerState.scrambleGrace);

      // At 95s (> 90s): transitions to stationaryCabanaSleep!
      now = now.add(const Duration(seconds: 30));
      engine.evaluateTick();
      expect(engine.state, MountainPowerState.stationaryCabanaSleep);
      expect(engine.gpsTier, MountainGpsTier.stationarySleep);
      expect(engine.isStationarySleep, isTrue);

      // Instant step_wake (< 500ms) restores foreground3m immediately!
      now = now.add(const Duration(seconds: 1));
      engine.ingestMotionEvent(
        const MountainMotionEvent(
          kind: MountainMotionEventKind.stepWake,
          stepBandVariance: 1.4,
          isMovingHardware: true,
        ),
      );
      expect(engine.state, MountainPowerState.movingActive);
      expect(engine.gpsTier, MountainGpsTier.foreground3m);
      expect(engine.isStationarySleep, isFalse);
    });

    test('mandatory SOS override preempts stationaryCabanaSleep and expeditionBatteryMode immediately', () {
      var now = DateTime.utc(2026, 11, 18, 12, 0, 0);
      final engine = MountainPowerEngine(clock: () => now);
      addTearDown(engine.dispose);

      engine.setExpeditionMode(true);
      engine.ingestGpsFix(lat: 45.4100, lon: 25.5300, speedMps: 0.0, accuracyM: 8.0);
      engine.ingestMotionEvent(
        const MountainMotionEvent(
          kind: MountainMotionEventKind.motionSample,
          stepBandVariance: 0.002,
          isMovingHardware: false,
        ),
      );
      now = now.add(const Duration(seconds: 100));
      engine.evaluateTick();
      expect(engine.state, MountainPowerState.stationaryCabanaSleep);

      // Trigger SOS -> forces sosEmergencyMax + sosMax2m regardless of stillness or expedition mode!
      engine.setSosActive(true);
      expect(engine.state, MountainPowerState.sosEmergencyMax);
      expect(engine.gpsTier, MountainGpsTier.sosMax2m);
      expect(engine.isStationarySleep, isFalse);

      // Resolve SOS -> returns cleanly to expeditionMoving.
      engine.setSosActive(false);
      expect(engine.state, MountainPowerState.expeditionMoving);
      expect(engine.gpsTier, MountainGpsTier.expedition12m);
    });

    test('auto-enables expedition GPS tier when battery <= 15% or OS Low Power Mode is on', () {
      final engine = MountainPowerEngine();
      addTearDown(engine.dispose);

      engine.ingestBatterySnapshot(
        const MountainBatterySnapshot(batteryPercent: 14, osLowPowerMode: false),
      );
      expect(engine.effectiveExpeditionMode, isTrue);
      expect(engine.gpsTier, MountainGpsTier.expedition12m);
    });
  });

  group('TraceletPositionSource config builders', () {
    test('background5m preserves identical pedestrian MotionConfig and stationarySleep uses platform-safe low power', () {
      final fg = TraceletPositionSource.buildConfigForTier(
        tier: MountainGpsTier.foreground3m,
        notificationTitle: 'Wanderer',
        notificationText: 'Navigating',
        platform: TargetPlatform.android,
      );
      final bg = TraceletPositionSource.buildConfigForTier(
        tier: MountainGpsTier.background5m,
        notificationTitle: 'Wanderer',
        notificationText: 'Navigating',
        platform: TargetPlatform.android,
      );
      expect(bg.motion.disableMotionActivityUpdates, isTrue);
      expect(bg.motion.speedMovingThreshold, fg.motion.speedMovingThreshold);
      expect(bg.geo.distanceFilter, 5.0);

      // iOS stationary sleep keeps CLLocationManager alive at DesiredAccuracy.veryLow (3km, 0mW GNSS)
      final iosSleep = TraceletPositionSource.buildConfigForTier(
        tier: MountainGpsTier.stationarySleep,
        notificationTitle: 'Wanderer',
        notificationText: 'Navigating',
        platform: TargetPlatform.iOS,
      );
      expect(iosSleep.geo.desiredAccuracy, tl.DesiredAccuracy.veryLow);
      expect(iosSleep.geo.distanceFilter, 500.0);

      // Android stationary sleep uses 300s periodic low-power fallback while DSP wake trigger is armed
      final androidSleep = TraceletPositionSource.buildConfigForTier(
        tier: MountainGpsTier.stationarySleep,
        notificationTitle: 'Wanderer',
        notificationText: 'Navigating',
        platform: TargetPlatform.android,
      );
      expect(androidSleep.geo.desiredAccuracy, tl.DesiredAccuracy.low);
      expect(androidSleep.geo.distanceFilter, 250.0);
    });
  });
}
