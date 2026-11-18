import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:tracelet/tracelet.dart' as tl;
import 'package:wanderer/provider/foreground_position_stream_provider.dart'
    show LocationMarkerPosition;
import 'package:wanderer/services/power/mountain_power_engine.dart'
    show MountainGpsTier;

/// Seed [geo.Position] for [TraceletPositionSource.start] from an
/// already-resolved marker position. Altitude/speed aren't tracked by
/// [LocationMarkerPosition], so they're zeroed rather than left stale.
geo.Position seedPositionFrom(LocationMarkerPosition pos) => geo.Position(
  latitude: pos.latitude,
  longitude: pos.longitude,
  altitude: 0,
  altitudeAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
  heading: pos.heading ?? 0,
  headingAccuracy: pos.headingAccuracy ?? 0,
  accuracy: pos.accuracy,
  timestamp: DateTime.now(),
);

/// Whether [pos] carries a real altitude, as opposed to the "no altitude"
/// placeholder both [seedPositionFrom] and geolocator express as
/// `altitude == 0` with `altitudeAccuracy == 0`. Every consumer that anchors
/// or diffs elevation must ask this — anchoring on a fabricated 0 turns the
/// next real reading into a full-absolute-altitude climb (see the
/// `recording-elevation-gain-jump` debug session).
///
/// Not `altitudeAccuracy > 0` alone: Android reports vertical accuracy only on
/// API 26+, and this app supports API 21+, so that would disable elevation
/// tracking outright on older devices.
bool hasUsableAltitude(geo.Position pos) =>
    pos.altitude.isFinite && (pos.altitudeAccuracy > 0 || pos.altitude != 0);

/// Bridges tracelet's location engine into a [geo.Position] stream, so the
/// navigation screen's existing consumers stay type-compatible.
///
/// One stream drives both recording/stats and the live UI, via two profiles
/// swapped live with [setForeground] as the app foregrounds/backgrounds.
///
/// Lifecycle: [start] once in initState, [setForeground] from
/// `didChangeAppLifecycleState`, [dispose] in dispose().
class TraceletPositionSource {
  final _controller = StreamController<geo.Position>.broadcast();
  final _movingController = StreamController<bool>.broadcast();
  StreamSubscription<tl.Location>? _locationSub;
  StreamSubscription<tl.SpeedMotionEvent>? _motionSub;

  String? _notificationTitle;
  String? _notificationText;

  /// Active GPS tier applied via [setForeground] or [applyGpsTier].
  bool _foreground = true;
  MountainGpsTier _currentTier = MountainGpsTier.foreground3m;

  Stream<geo.Position> get stream => _controller.stream;

  /// The app's sole "is the user moving" signal, straight from tracelet's
  /// native speed-motion state machine. Nothing else recomputes motion from
  /// raw GPS.
  Stream<bool> get isMovingStream => _movingController.stream;

  /// Pedestrian-tuned rejection of bad fixes, shared by BOTH profiles.
  ///
  /// tracelet's own defaults are vehicle-scale — `maxImpliedSpeed: 80` (288
  /// km/h) and `trackingAccuracyThreshold: 100` m can never be tripped by a
  /// walker, and the default `policy: adjust` *corrects and records* a
  /// breaching fix rather than dropping it. Left at those defaults, multipath
  /// spikes in a street canyon land in the breadcrumb verbatim and the saved
  /// track becomes a starburst — see the `recording-gps-jitter-still` debug
  /// session.
  ///
  /// One constant, not two literals, because the profiles inherit *different*
  /// filters from their presets: `highAccuracy` enables the Kalman filter,
  /// `balanced` disables it, so a backgrounded (screen-off) recording used to
  /// silently lose GPS smoothing. Sharing the object is what keeps them from
  /// drifting apart again.
  ///
  /// 30 m rather than a tighter urban ceiling: most recording happens outdoors
  /// in non-urban terrain, where conifer canopy and gorges routinely report
  /// 15–25 m, and dropping those would empty the track instead of cleaning it.
  /// The accuracy ceiling is the weaker of the two gates anyway — multipath
  /// spikes frequently report optimistic accuracy — so [maxImpliedSpeed] is
  /// what actually catches them: 15 m/s (54 km/h) clears a fast bike descent
  /// while rejecting the hundreds-of-km/h teleports jitter produces.
  static const _locationFilter = tl.LocationFilter(
    trackingAccuracyThreshold: 30, // m
    maxImpliedSpeed: 15, // m/s (~54 km/h)
    policy: tl.LocationFilterPolicy.ignore, // drop, don't "adjust" and record
    rejectMockLocations: true,
    useKalmanFilter: true,
  );

  /// Unified pedestrian motion block shared across ALL tiers so screen-lock
  /// (`setForeground(false)`) never swaps `motion:` keys or drops
  /// `disableMotionActivityUpdates: true` on Android (where
  /// `ACTIVITY_RECOGNITION` is stripped from `AndroidManifest.xml`).
  static const _pedestrianMotionConfig = tl.MotionConfig(
    disableMotionActivityUpdates: true,
    motionDetectionMode: tl.MotionDetectionMode.speed,
    speedMovingThreshold: 0.4,
    speedStationaryDelay: 90,
    stationaryTrackingMode: tl.StationaryTrackingMode.periodic,
    stationaryPeriodicInterval: 300,
    stationaryPeriodicAccuracy: tl.DesiredAccuracy.low,
  );

  @visibleForTesting
  static tl.Config buildConfigForTier({
    required MountainGpsTier tier,
    required String notificationTitle,
    required String notificationText,
    TargetPlatform? platform,
  }) {
    final effPlatform = platform ?? defaultTargetPlatform;
    final base = tl.Config.highAccuracy();
    final (tl.DesiredAccuracy accuracy, double distanceFilter) = switch (tier) {
      MountainGpsTier.sosMax2m => (tl.DesiredAccuracy.high, 2.0),
      MountainGpsTier.foreground3m => (tl.DesiredAccuracy.high, 3.0),
      MountainGpsTier.background5m => (tl.DesiredAccuracy.high, 5.0),
      MountainGpsTier.expedition12m => (tl.DesiredAccuracy.high, 12.0),
      // CRITICAL OS SAFETY:
      // - iOS: `DesiredAccuracy.veryLow` (~3km cell/Wi-Fi, 500m filter) consumes
      //   0 mW GNSS satellite RF while keeping the `UIBackgroundModes: location`
      //   runtime assertion alive so CoreMotion can wake GPS in <500ms!
      // - Android: `DesiredAccuracy.low` (250m filter) parks high-power GNSS
      //   while keeping warm ephemeris until `TYPE_SIGNIFICANT_MOTION` fires.
      MountainGpsTier.stationarySleep =>
        effPlatform == TargetPlatform.iOS
            ? (tl.DesiredAccuracy.veryLow, 500.0)
            : (tl.DesiredAccuracy.low, 250.0),
    };

    return base.copyWith(
      geo: base.geo.copyWith(
        desiredAccuracy: accuracy,
        distanceFilter: distanceFilter,
        enableDeadReckoning: false,
        filter: _locationFilter,
      ),
      motion: _pedestrianMotionConfig,
      app: const tl.AppConfig(stopOnTerminate: false),
      android: base.android.copyWith(
        foregroundService: _foregroundServiceConfigFor(
          notificationTitle,
          notificationText,
        ),
      ),
    );
  }

  static tl.Config _foregroundConfigFor(
    String notificationTitle,
    String notificationText,
  ) => buildConfigForTier(
    tier: MountainGpsTier.foreground3m,
    notificationTitle: notificationTitle,
    notificationText: notificationText,
  );

  tl.Config _activeConfig() => buildConfigForTier(
    tier: _currentTier,
    notificationTitle: _notificationTitle!,
    notificationText: _notificationText!,
  );

  static tl.ForegroundServiceConfig _foregroundServiceConfigFor(
    String notificationTitle,
    String notificationText,
  ) => tl.ForegroundServiceConfig(
    channelId: 'wanderer_tracking',
    channelName: 'Wanderer Tracking',
    notificationTitle: notificationTitle,
    notificationText: notificationText,
    notificationSmallIcon: 'ic_notification_icon',
  );

  Future<void> start({
    required String notificationTitle,
    required String notificationText,
    geo.Position? seed,
  }) async {
    _notificationTitle = notificationTitle;
    _notificationText = notificationText;
    _locationSub = tl.Tracelet.onLocation(_onLocation);
    _motionSub = tl.Tracelet.onSpeedMotionChange(_onSpeedMotionChange);

    // Emit the caller's fix immediately so the live marker isn't blank through
    // tracelet's cold GPS acquisition; overwritten by the first `_onLocation`.
    if (seed != null && !_controller.isClosed) {
      _controller.add(seed);
    }

    await ensureReady(
      notificationTitle: notificationTitle,
      notificationText: notificationText,
    );
    await tl.Tracelet.start();
  }

  /// Brings tracelet's native SDK to its `ready` state with the foreground
  /// profile, without subscribing to anything or starting a session.
  ///
  /// This is a precondition for reading tracelet's store, not just for
  /// tracking: the native SDK answers `getLocations()` with an empty list until
  /// `ready()` has run in the current process, and does so as an ordinary
  /// success rather than an error. A relaunch after the process was killed is a
  /// fresh process, so `session_gap_backfill.dart` has to ready the SDK itself
  /// before it can see the fixes recorded while the app was dead.
  ///
  /// Idempotent in practice — every recording after the first in a process
  /// calls `ready()` again through [start] — but not free: with a session
  /// enabled natively, `ready()` re-enters it.
  static Future<void> ensureReady({
    required String notificationTitle,
    required String notificationText,
  }) async {
    // Must happen before the service exists: on Android 13+ the
    // foreground-service notification is suppressed without
    // POST_NOTIFICATIONS, and granting it later doesn't surface the running
    // service's notification retroactively.
    await _ensureNotificationPermission();

    await tl.Tracelet.ready(
      _foregroundConfigFor(notificationTitle, notificationText),
    );
  }

  /// Best-effort POST_NOTIFICATIONS request; a no-op below Android 13 and on
  /// iOS. Failures are swallowed: a denied permission costs visibility of the
  /// foreground-service notification, never the recording itself.
  static Future<void> _ensureNotificationPermission() async {
    if (!Platform.isAndroid) return;
    try {
      await FlutterLocalNotificationsPlugin()
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    } catch (_) {}
  }

  /// Swaps between the foreground and background profiles. The foreground
  /// service and the session survive the swap, but the native pipeline does
  /// not: tracelet's `setConfig()` restarts it in place (stop, then resume)
  /// whenever a location or motion key changes, which these two profiles do on
  /// every swap (accuracy, distance filter, update interval, and — because
  /// [_backgroundConfig] inherits the `balanced` preset's motion block —
  /// `motionDetectionMode` and `stationaryTrackingMode` too).
  Future<void> setForeground(bool foreground) async {
    _foreground = foreground;
    if (_currentTier == MountainGpsTier.foreground3m ||
        _currentTier == MountainGpsTier.background5m) {
      await applyGpsTier(
        _foreground
            ? MountainGpsTier.foreground3m
            : MountainGpsTier.background5m,
      );
    }
  }

  /// Applies [tier] idempotently — skips native `setConfig` when unchanged so
  /// brief screen peeks never restart the native location pipeline needlessly.
  Future<void> applyGpsTier(MountainGpsTier tier) async {
    if (_currentTier == tier) return;
    _currentTier = tier;
    if (_locationSub == null ||
        _notificationTitle == null ||
        _notificationText == null) {
      return;
    }
    await tl.Tracelet.setConfig(_activeConfig());
  }

  /// Rewrites the running session's notification body, leaving the tracking
  /// profile untouched. The notification names the trail, which can still be
  /// resolving when [start] fires. A no-op before [start].
  Future<void> setNotificationText(String text) async {
    if (_locationSub == null || _notificationText == text) return;
    _notificationText = text;
    await tl.Tracelet.setConfig(_activeConfig());
  }

  void _onLocation(tl.Location location) {
    if (_controller.isClosed) return;
    final c = location.coords;
    _controller.add(
      geo.Position(
        latitude: c.latitude,
        longitude: c.longitude,
        altitude: c.altitude,
        altitudeAccuracy: c.altitudeAccuracy,
        speed: c.speed,
        speedAccuracy: c.speedAccuracy,
        heading: c.heading,
        headingAccuracy: c.headingAccuracy,
        accuracy: c.accuracy,
        timestamp: DateTime.now(),
      ),
    );
  }

  /// `slowing` counts as moving — it's a grace window before the engine
  /// commits to `stationary`, and freezing during it would cut accumulation
  /// off on every brief slow-down.
  void _onSpeedMotionChange(tl.SpeedMotionEvent event) {
    if (_movingController.isClosed) return;
    _movingController.add(event.state != tl.SpeedMotionState.stationary);
  }

  /// Tear down the Dart-side listeners but leave the native session running,
  /// for when the screen goes away mid-recording (task swiped off recents,
  /// route popped). `stopOnTerminate: false` keeps tracelet recording through
  /// it; the startup reconciliation in `main.dart` then owns the session,
  /// resuming it or calling [stopOrphanedTracking].
  Future<void> detach() async {
    await _locationSub?.cancel();
    _locationSub = null;
    await _motionSub?.cancel();
    _motionSub = null;
    await _controller.close();
    await _movingController.close();
  }

  /// Tear down everything, native tracking session included. Only correct when
  /// the session is genuinely over — use [detach] otherwise.
  Future<void> dispose() async {
    await detach();
    await tl.Tracelet.stop();
  }

  /// Whether a native tracking session is currently running — true after the
  /// app process was killed while `stopOnTerminate: false` kept tracelet
  /// recording, so relaunching should drop straight back into the live session
  /// rather than offering a resume prompt. False when the state can't be read.
  static Future<bool> isTracking() async {
    try {
      return (await tl.Tracelet.getState()).enabled;
    } catch (_) {
      return false;
    }
  }

  /// Best-effort stop of a session left running by a killed app process. When
  /// the persisted session row is dropped rather than resumed, nothing else
  /// ever tells the native service to stop. Called from the startup
  /// reconciliation in `main.dart`; a no-op when nothing is running.
  static Future<void> stopOrphanedTracking() async {
    try {
      await tl.Tracelet.stop();
    } catch (_) {}
  }
}
