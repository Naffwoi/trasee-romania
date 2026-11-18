import 'package:wanderer/components/map/map_ui_controls.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' show exp, max, min, pi;
import 'dart:ui' show lerpDouble;

import 'package:collection/collection.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:fl_chart/fl_chart.dart' show FlSpot;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rotation_sensor/flutter_rotation_sensor.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:go_router/go_router.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:gpx/gpx.dart';
import 'package:maplibre/maplibre.dart' as ml;
import 'package:objectbox/objectbox.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wanderer/components/base/wanderer_attribution.dart';
import 'package:wanderer/components/map/location_marker_layer.dart';
import 'package:wanderer/components/map/map_layers_sheet.dart';
import 'package:wanderer/components/map/salvamont_map_layer.dart';
import 'package:wanderer/components/map/screen_marker_layer.dart';
import 'package:wanderer/components/map/terrain_overlay_controls.dart';
import 'package:wanderer/components/map/trail_layer.dart';
import 'package:wanderer/components/navigation/group_sheet.dart';
import 'package:wanderer/components/navigation/peak_finder_sheet.dart';
import 'package:wanderer/components/navigation/sos_banner_and_dialog.dart';
import 'package:wanderer/components/navigation/waze_nearby_prompt.dart';
import 'package:wanderer/components/navigation/waze_report_sheet.dart';
import 'package:wanderer/components/trail/active_hikers_badge.dart';
import 'package:wanderer/components/trail/elevation_profile.dart';
import 'package:wanderer/components/trail/waypoint_sheet.dart';
import 'package:wanderer/entities/active_navigation_entity.dart';
import 'package:wanderer/entities/region_entity.dart';
import 'package:wanderer/i18n/app_localizations.dart';
import 'package:wanderer/models/emergency/salvamont_models.dart';
import 'package:wanderer/models/live/trail_live_models.dart';
import 'package:wanderer/models/navigate_response.dart';
import 'package:wanderer/models/trail.dart';
import 'package:wanderer/models/trail_sync_state.dart';
import 'package:wanderer/models/waypoint.dart';
import 'package:wanderer/provider/api_provider.dart';
import 'package:wanderer/provider/auth_provider.dart';
import 'package:wanderer/provider/foreground_position_stream_provider.dart';
import 'package:wanderer/provider/group_session_provider.dart';
import 'package:wanderer/provider/local_settings_provider.dart';
import 'package:wanderer/provider/map_style_json_provider.dart';
import 'package:wanderer/provider/nav_session_hibernation_provider.dart';
import 'package:wanderer/provider/navigation_provider.dart';
import 'package:wanderer/provider/navigation_stats_provider.dart';
import 'package:wanderer/provider/objectbox_store_provider.dart';
import 'package:wanderer/provider/online_status_provider.dart';
import 'package:wanderer/provider/profile/profile_trails_provider.dart';
import 'package:wanderer/provider/region/tile_proxy_provider.dart';
import 'package:wanderer/provider/salvamont_provider.dart';
import 'package:wanderer/provider/subcategory_preference_provider.dart';
import 'package:wanderer/provider/toast_provider.dart';
import 'package:wanderer/provider/trail/category_provider.dart';
import 'package:wanderer/provider/trail/subcategory_provider.dart';
import 'package:wanderer/provider/trail/trail_library_provider.dart';
import 'package:wanderer/provider/trail/trail_provider.dart';
import 'package:wanderer/services/navigation/nav_terrain_worker_isolate.dart';
import 'package:wanderer/services/power/mountain_motion_channel.dart';
import 'package:wanderer/services/power/mountain_power_engine.dart';
import 'package:wanderer/services/power/radio_sync_scheduler.dart';
import 'package:wanderer/store/active_navigation_store.dart' as active_nav;
import 'package:wanderer/store/breadcrumb_slab_store.dart';
import 'package:wanderer/store/current_account.dart';
import 'package:wanderer/store/local_trail_store.dart';
import 'package:wanderer/util/local/id.dart';
import 'package:wanderer/util/format.dart';
import 'package:wanderer/util/gpx/gpx.dart';
import 'package:wanderer/util/region/proxy_style_rewriter.dart';
import 'package:wanderer/util/geo/polyline.dart';
import 'package:wanderer/util/map/compass_rate_policy.dart';
import 'package:wanderer/util/map/heading_math.dart'
    show normalizeHeading, shortestAngleDelta;
import 'package:wanderer/theme/colors.dart';
import 'package:wanderer/util/emergency/salvamont_resolver.dart';
import 'package:wanderer/util/navigation/cooperative_gps_fusion.dart';
import 'package:wanderer/util/navigation/dem_tile_grid.dart';
import 'package:wanderer/util/navigation/eta_calculator.dart';
import 'package:wanderer/util/navigation/gps_pace_coaster.dart';
import 'package:wanderer/util/navigation/off_trail_router.dart';
import 'package:wanderer/util/navigation/peak_finder_engine.dart';
import 'package:wanderer/util/navigation/ridge_sunset_calculator.dart';
import 'package:wanderer/util/navigation/sun_calc.dart';
import 'package:wanderer/util/route/planner_handoff.dart';
import 'package:wanderer/util/route/track_position_matcher.dart';
import 'package:wanderer/models/route_travel_bucket.dart';
import 'package:wanderer/services/ble/ble_mesh_engine.dart';
import 'package:wanderer/services/ble/ble_mesh_protocol.dart';
import 'package:wanderer/services/ble/sos_crypto_and_outbox.dart';
import 'package:wanderer/services/tracelet_position_source.dart';
import 'package:wanderer/services/trail_live_service.dart';
import 'package:wanderer/actions/import_trail_file.dart';
import 'package:wanderer/util/route/valhalla.dart';

/// The three actions offered by [_NavigationScreenState._confirmExit]'s
/// premature-exit dialog.
enum _NavExitChoice { cancel, exit, saveTrack }

/// Breadcrumb length below which the live elevation chart still refreshes on
/// every single GPS fix. Redrawing is cheap while the track is short, and a
/// just-started recording is exactly when the user is most likely watching the
/// profile appear.
const _kLiveChartFullFidelityPoints = 300;

/// One chart refresh per this many fixes once past
/// [_kLiveChartFullFidelityPoints]. At 1 Hz that is a redraw roughly every
/// 10 s — invisible on an elevation profile spanning hours, and it cuts the
/// per-fix cost by 10x exactly when the track is long enough for that cost to
/// matter.
const _kLiveChartStride = 10;

/// Change signal for the live (recording) elevation chart, derived from
/// `NavigationState.breadcrumbLength`.
///
/// Monotonically non-decreasing, so it can never make the chart go backwards,
/// but it deliberately holds steady across consecutive fixes once the track is
/// long — see the two constants above and the cost note in
/// `_buildElevationPage`. Full fidelity below the threshold, then one step per
/// [_kLiveChartStride] fixes.
@visibleForTesting
int liveElevationChartRevision(int breadcrumbLength) =>
    breadcrumbLength <= _kLiveChartFullFidelityPoints
    ? breadcrumbLength
    : _kLiveChartFullFidelityPoints + breadcrumbLength ~/ _kLiveChartStride;

class NavigationScreen extends ConsumerStatefulWidget {
  final String id;
  final NavigateResponse response;
  final ActiveNavigationEntity? resumeSession;

  /// True for a trail-less GPS-recording session (pushed via the top-level
  /// `/record` route) — false (default) preserves every existing
  /// turn-by-turn navigation call site unchanged. See the recording-mode
  /// branches in `_buildButtonRow`, `_confirmExit`, `_persistNow`, and
  /// `_buildElevationPage`.
  final bool isRecording;

  /// Initial map camera center for a fresh recording session (recording mode
  /// has no `response.shape` to derive one from). Resolved by the caller
  /// (`trail_source_select_screen.dart`'s `_openRecorder`) from a real GPS
  /// fix before pushing `/record`, so the map never opens at the
  /// `Geographic(0, 0)` fallback. Ignored outside recording mode.
  final ml.Geographic? initialCenter;

  /// Already-resolved GPS fix — from `_openRecorder` (recording) or
  /// `launchNavigation` (turn-by-turn) — seeded into [TraceletPositionSource]
  /// so the live marker renders instantly instead of waiting for tracelet's
  /// own cold GPS acquisition. Null for a resumed session (no fresh fix to
  /// hand off) — the marker waits for tracelet's fix same as before.
  final geo.Position? initialPosition;

  /// Valhalla costing (`'pedestrian'`/`'bicycle'`) chosen via
  /// `showTravelProfileSheet` at record start (`_openRecorder`) — gives
  /// "Follow roads" the same profile picker the route planner already has,
  /// instead of always costing as pedestrian for a trail-less recording
  /// (which has no trail category for [costingForCategory] to read). Ignored
  /// outside recording mode; a resumed session reads its own persisted
  /// [ActiveNavigationEntity.recordingCosting] instead (see `initState`).
  final String? recordingCosting;

  const NavigationScreen({
    super.key,
    required this.id,
    required this.response,
    this.resumeSession,
    this.isRecording = false,
    this.initialCenter,
    this.initialPosition,
    this.recordingCosting,
  });

  @override
  ConsumerState<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends ConsumerState<NavigationScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static const _trailLayer = TrailLayer();

  late final TraceletPositionSource _positionSource;
  late final Stream<geo.Position> _positionStream;
  StreamSubscription<geo.Position>? _sub;

  /// ObjectBox store, read once in [initState] — used to persist/clear the
  /// single active-session row via `active_navigation_store`.
  late final Store _store;

  /// Resume seeds computed once from [NavigationScreen.resumeSession]. Every
  /// `navigationProvider`/`navigationStatsProvider` call site below must pass
  /// the identical seed fields or the family resolves to a different
  /// (split-brain) provider instance.
  /// The session's route as JSON, encoded once and written on every persist.
  ///
  /// Re-encoding the full route on each persist tick would be pure waste, and
  /// a resumed session already has the string — reuse it rather than rebuild
  /// an identical one. Null while recording (no route).
  late final String? _sessionNavJson;

  late final int? _resumeManeuverIndex;
  late final List<Wpt>? _resumeBreadcrumb;
  late final NavigationStatsSeed? _resumeStats;

  /// Resolved once in [initState]: a resumed recording's own persisted
  /// costing wins over [NavigationScreen.recordingCosting] (a fresh push
  /// only ever supplies one of the two — resume seeds have no fresh sheet
  /// selection to carry). Null outside recording mode.
  late final String? _recordingCosting;

  /// Family provider instances constructed ONCE (in [initState], after the
  /// resume seeds resolve) and reused for every watch/read/listen in this
  /// file. Constructing them inline per call site both risks split-brain
  /// seeds and re-creates the argument record each time. Note the container
  /// still hashes the argument per lookup (and that hash deep-walks the full
  /// route shape — freezed's DeepCollectionEquality), which is why the
  /// per-GPS-fix path below goes through the cached NOTIFIER references
  /// instead of any provider read.
  late final NavigationProvider _navProviderInstance;
  late final NavigationStatsNotifierProvider _statsProviderInstance;

  /// Notifier references cached once in [initState] — the per-fix hot path
  /// calls these directly, doing ZERO provider lookups per GPS fix. Safe for
  /// the session: both families are kept alive by this screen's own
  /// watch/listen subscriptions and nothing invalidates them mid-session.
  late final Navigation _navNotifier;
  late final NavigationStatsNotifier _statsNotifier;

  /// Mirror of `stats.isPaused || stats.isStationary`, maintained by a
  /// [ref.listenManual] subscription — so the per-fix handler never has to
  /// `ref.read` the stats provider (see [_statsProviderInstance] docs).
  bool _frozen = false;

  /// False while the app is backgrounded (paused/hidden/detached). Gates the
  /// per-fix breadcrumb GeoJSON serialization + platform-channel push — the
  /// native map is paused and invisible, so feeding it geometry is pure
  /// battery waste. Recording itself (breadcrumb, stats, persistence) is
  /// UNAFFECTED: background recording is first-class, only map-feeding
  /// stops. On resume, [_pushBreadcrumbSources] catches the map up in one
  /// update.
  bool _uiVisible = true;

  /// Number of leading breadcrumb points currently baked into the native
  /// `breadcrumb` (frozen) GeoJSON source. Points past this index live in the
  /// small `breadcrumb-tail` source, re-serialized per fix — bounding the
  /// per-fix cost to O(tail) instead of O(whole track), which over a
  /// multi-hour hike made the old single-source push quadratic. The tail is
  /// rolled into the frozen source every [_kBreadcrumbTailMax] points.
  int _frozenCount = 0;
  static const _kBreadcrumbTailMax = 250;

  /// obxId of the single active-session row this screen owns. 0 means "not
  /// yet inserted" — the first [_persistNow] call inserts and this is updated
  /// with the id `active_nav.save` returns so every later save updates the
  /// same row instead of inserting a duplicate.
  int _activeRowObxId = 0;

  /// Periodic best-effort persistence tick (in addition to maneuver-advance
  /// and pause-toggle saves).
  Timer? _persistTimer;

  /// Guards [_saveRecordedTrack] against a double-tap firing two concurrent
  /// conversions/navigations, and drives the completion banner's loading
  /// state.
  bool _savingTrack = false;

  /// Latest *animated* GPS fix, driving both the custom [_LocationMarkerLayer]
  /// marker and camera-follow. A [ValueNotifier] so the marker rebuilds in a
  /// scoped `ValueListenableBuilder` without a full-screen `setState`. Sourced
  /// from [_positionSource] (tracelet), which runs a continuous, unfiltered
  /// foreground config while the screen is active (see
  /// [TraceletPositionSource.setForeground]) — no separate GPS stream needed.
  /// Values are interpolated between raw fixes by [_positionAnimController]
  /// — see [_onFix].
  final ValueNotifier<LocationMarkerPosition?> _currentPosition = ValueNotifier(
    null,
  );

  /// Resolves each raw fix to a distance along the navigated trail's GPX in
  /// the elevation chart's x units. Built once the trail model resolves
  /// (see the post-frame callback in [initState]). Stays null in recording
  /// mode (the chart is the breadcrumb, the user is always at its end),
  /// while the trail is loading, or when the trail has no plottable track.
  TrackPositionMatcher? _trackMatcher;
  EtaCalculator? _etaCalculator;
  List<NavTrackPoint> _navTrackPoints = const [];
  late final DemTileGrid _demGrid = () {
    try {
      final base = ref.read(tileProxyBaseUrlProvider);
      if (base.isNotEmpty) {
        return DemTileGrid(tileUrlTemplate: '$base/dem/{z}/{x}/{y}.png');
      }
    } catch (_) {}
    return DemTileGrid();
  }();
  final OfflinePeakFinder _peakFinder = OfflinePeakFinder();
  final ValueNotifier<TrailSolarForecast?> _solarForecastNotifier =
      ValueNotifier(null);
  DateTime? _simulatedSolarTime;
  DateTime? _lastSolarCalcAt;

  /// Latest on-track along-track metres for the elevation chart's live
  /// marker, null = off-track/unknown. A [ValueNotifier], like
  /// [_currentPosition], so per-fix updates rebuild only the chart, never
  /// the whole screen — [ValueNotifier] skips notification when the value
  /// is unchanged, so a run of nulls is free.
  final ValueNotifier<double?> _liveTrackMeters = ValueNotifier(null);
  final ValueNotifier<EtaSnapshot?> _etaNotifier = ValueNotifier(null);
  final ValueNotifier<OffTrailRerouteResult?> _offTrailNotifier = ValueNotifier(
    null,
  );
  final ValueNotifier<List<FlSpot>?> _offTrailChartSpots = ValueNotifier(null);
  OffTrailMode _offTrailMode = OffTrailMode.minClimb;
  ml.Geographic? _lastRerouteCalcPos;
  OffTrailMode? _lastRerouteCalcMode;
  DateTime? _lastRerouteCalcAt;
  double? _lastMatchedAlongTrackM;
  double? _lastKnownAltitudeM;
  bool _didAutoExpandSheet = false;
  bool _demFallbackPrefetchStarted = false;
  String _localeCode = 'ro';

  // Cooperative GPS fusion, 1 Hz Tobler pace coasting, hybrid Valhalla & preview state.
  GpsPaceCoaster? _paceCoaster;
  Timer? _coasterTimer;
  final ValueNotifier<GpsSignalState> _gpsSignalState =
      ValueNotifier<GpsSignalState>(GpsSignalState.good);
  final ValueNotifier<double> _effectiveGpsAccuracy = ValueNotifier<double>(
    15.0,
  );
  final ValueNotifier<double?> _farPreviewDistanceM = ValueNotifier<double?>(
    null,
  );
  final ValueNotifier<bool> _accessRouteLoading = ValueNotifier<bool>(false);
  bool _showingAccessRoute = false;
  int _rerouteGeneration = 0;
  CancelToken? _valhallaRerouteCancelToken;
  Set<String> _lastCoLocatedPeerIds = <String>{};
  SelfGpsObservation? _lastRawSelfFix;
  double? _lastRawSpeed;
  double? _lastRawHeading;

  // Live Waze reports, permanent landmarks, 30-min presence, 5 km SOS & Live Groups.
  TrailLiveService? _liveService;
  final ValueNotifier<GroupSessionModel?> _groupSession =
      ValueNotifier<GroupSessionModel?>(null);
  VoidCallback? _groupSessionSyncListener;
  final ValueNotifier<GroupMemberModel?> _selectedGroupMember =
      ValueNotifier<GroupMemberModel?>(null);
  final ValueNotifier<int?> _activeHikers30m = ValueNotifier<int?>(null);
  final ValueNotifier<List<TrailReportModel>> _liveReports =
      ValueNotifier<List<TrailReportModel>>(const []);
  final ValueNotifier<({TrailReportModel report, double? distanceM})?>
  _nearbyPromptReport = ValueNotifier(null);
  final ValueNotifier<SosAlertModel?> _myActiveSos = ValueNotifier(null);
  final ValueNotifier<List<SosAlertModel>> _nearbySosAlerts =
      ValueNotifier<List<SosAlertModel>>(const []);
  final ValueNotifier<OffTrailRerouteResult?> _rescueRouteNotifier =
      ValueNotifier(null);
  final ValueNotifier<bool> _liveActionBusy = ValueNotifier<bool>(false);
  final Set<String> _snoozedOrVotedReportIds = <String>{};
  String? _pinnedPromptReportId;
  StreamSubscription<TrailLiveSseEvent>? _liveSseSub;
  CancelToken? _liveSseCancelToken;
  Timer? _liveSseReconnectTimer;
  bool _firstHeartbeatSent = false;
  ml.Geographic? _lastSosBroadcastPos;
  DateTime? _lastSosBroadcastAt;
  ml.Geographic? _lastRescueCalcPos;
  DateTime? _lastRescueCalcAt;
  DateTime? _lastResponderSyncAt;
  bool _rescueDemPrefetchStarted = false;

  // Offline BLE Multi-Hop Mesh & Store-and-Forward SOS Relay state.
  late final SosOutboxAndRelayStore _sosOutboxStore;
  late final BleMeshEngine _bleMeshEngine;
  final List<StreamSubscription<Object?>> _bleSubscriptions =
      <StreamSubscription<Object?>>[];
  final Map<String, GroupMemberModel> _bleGroupPeers =
      <String, GroupMemberModel>{};
  final Set<String> _bleAckResponderIds = <String>{};
  final SosLocalNotificationHelper _fallbackSosNotifier =
      SosLocalNotificationHelper();
  final Set<String> _fallbackNotifiedSosKeys = <String>{};
  bool _sosOutboxFlushInFlight = false;
  bool _blePermissionsRequestedOnce = false;
  ml.Geographic? _lastBleGroupBroadcastPos;
  DateTime? _lastBleGroupBroadcastAt;
  DateTime? _lastBleResponderAckAt;
  String _selfGroupDisplayName = 'Drumeț';

  // Battery & 60/120 FPS isolate/power/radio/slab state.
  final ValueNotifier<double?> _headingNotifier = ValueNotifier<double?>(null);
  final ValueNotifier<MountainPowerState> _powerStateNotifier =
      ValueNotifier<MountainPowerState>(MountainPowerState.movingActive);
  final CameraPushThrottle _cameraPushThrottle = CameraPushThrottle();
  CompassRateConfig _compassRateCfg = CompassRateConfig.disabled;

  late final MountainMotionChannel _motionChannel;
  late final MountainPowerEngine _powerEngine;
  StreamSubscription<MountainMotionEvent>? _motionSub;
  Timer? _powerWatchdogTimer;

  late final RadioSyncScheduler _radioScheduler;
  String? _lastHeartbeatStateHash;
  String? _lastLiveSseEventId;
  int _sseFailureCount = 0;

  BreadcrumbSlabStore? _breadcrumbSlab;
  int _lastPersistedPointCount = -1;
  int _lastPersistedElapsedSec = -1;
  bool _lastPersistedPaused = false;

  NavTerrainWorkerIsolate? _terrainWorker;
  int _matchFixSeq = 0;
  int _latestAppliedMatchSeq = 0;
  ProviderContainer? _hibernationContainer;
  Duration? _appliedCompassPeriod;

  bool get _isRo => _localeCode.toLowerCase().startsWith('ro');

  /// Short per-fix position tween smoothing the marker/camera between raw GPS
  /// fixes — mirrors the 200ms `fastOutSlowIn` `flutter_map_location_marker`'s
  /// `CurrentLocationLayer` used pre-MapLibre-migration, which this screen lost
  /// when native `trackLocation` was replaced by one-shot `animateCamera` calls
  /// per fix (that native animation cancels/restarts on every call, causing
  /// stutter once fixes arrive faster than its duration).
  late final AnimationController _positionAnimController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  )..addListener(_applyAnimatedFrame);
  late final CurvedAnimation _positionCurve = CurvedAnimation(
    parent: _positionAnimController,
    curve: Curves.fastOutSlowIn,
  );

  double? _animStartLat;
  double? _animStartLon;
  double? _animTargetLat;
  double? _animTargetLon;
  double _animAccuracy = 0;

  /// Latest interpolated position, updated every position-tween frame and
  /// reused when a heading-sensor event needs to re-publish the marker/camera.
  double? _lastLat;
  double? _lastLon;

  /// Camera bearing we last told MapLibre to use — the single source of
  /// truth for every `moveCamera` bearing argument. This MapLibre version's
  /// camera-update builder does not reliably treat an omitted (`null`) field
  /// as "leave unchanged", so passing `bearing: null` while a heading-up/
  /// north-return transition is mid-flight can reset or fight the in-flight
  /// rotation, occasionally leaving it stuck partway. Every camera push below
  /// writes this explicit value instead of `null`. Written by either
  /// [_bearingTransitionController] (the two discrete transitions) or
  /// [_bearingFollowTicker] (continuous heading-up follow) — never both at
  /// once, see the latter's `isAnimating` guard in [_onBearingFollowTick].
  double _mapBearing = 0;

  /// One-shot tween for the two discrete, user-triggered bearing transitions
  /// (compass tap to enter/exit heading-up). Continuous heading-up follow is
  /// driven separately by [_bearingFollowTicker], which defers to this
  /// controller while it's animating — so this is the only writer of
  /// [_mapBearing] during those 400ms transitions.
  late final AnimationController _bearingTransitionController =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 400),
      )..addListener(_applyBearingTransition);
  late final CurvedAnimation _bearingTransitionCurve = CurvedAnimation(
    parent: _bearingTransitionController,
    curve: Curves.easeInOut,
  );
  double _bearingTransitionStart = 0;
  double _bearingTransitionTarget = 0;

  /// Per-frame ticker that continuously eases [_mapBearing] toward
  /// [_smoothedHeading] while following in heading-up mode — decouples the
  /// camera's update rate from the heading sensor's throttled ~15Hz cadence
  /// so rotation reads as smooth as a native gesture instead of stepping.
  /// Started/stopped by [_syncBearingFollowTicker].
  late final Ticker _bearingFollowTicker = createTicker(_onBearingFollowTick);

  /// Elapsed timestamp of the previous [_bearingFollowTicker] tick that
  /// actually advanced [_mapBearing] — used to compute a frame-rate
  /// independent smoothing factor. Reset to `null` whenever the ticker
  /// (re)starts or is gated off, so resuming never applies one giant
  /// catch-up jump from a stale baseline.
  Duration? _lastBearingFollowElapsed;

  /// Time constant (seconds) for [_bearingFollowTicker]'s exponential
  /// smoothing — smaller converges faster but jitters more.
  static const double _kBearingFollowTauSeconds = 0.15;

  /// Device heading in degrees (0 = north, clockwise), sourced from the
  /// orientation sensor ([_headingSub]) independently of GPS — GPS `heading`
  /// is only produced while moving and is useless when turning in place.
  /// Null until the first sensor event. Low-pass smoothed via [_lerpBearing]
  /// since the raw magnetometer signal is jittery. Also the convergence
  /// target [_bearingFollowTicker] eases [_mapBearing] toward in heading-up
  /// follow, rather than something snapped straight to the camera.
  double? _smoothedHeading;
  StreamSubscription<OrientationEvent>? _headingSub;
  static const _kHeadingSmoothingAlpha = 0.35;

  final DraggableScrollableController _sheetController =
      DraggableScrollableController();
  final DraggableScrollableController _waypointSheetController =
      DraggableScrollableController();

  Waypoint? _selectedWaypoint;

  static const _kSheetMinSize = 0.2;
  static const _kSheetStatsSize = 0.3;
  static const _kSheetElevationSize = 0.45;
  static const _kNavSheetElevationSize = 0.52;

  double get _elevationSheetSize =>
      widget.isRecording ? _kSheetElevationSize : _kNavSheetElevationSize;

  ml.MapController? _controller;

  /// Buffers a style-loaded event that arrives before [_controller] is set —
  /// the native platform channel does not reliably fire `onMapCreated` before
  /// `onStyleLoaded` (the same race `TrailCollectionMap` guards against).
  ml.StyleController? _pendingStyle;

  /// The style currently bound, held so a trail that resolves *after*
  /// `onStyleLoaded` can still have its outline added.
  ml.StyleController? _loadedStyle;

  /// Whether the trail outline is on [_loadedStyle]. Reset on every style
  /// load — a swap drops added sources and layers, and re-adding onto a style
  /// that still has them would throw on the duplicate source id.
  bool _trailLayerAdded = false;

  /// The last successfully-resolved (and possibly offline-rewritten) style
  /// JSON. Cached so a provider refresh (e.g. a theme toggle) never drops us
  /// back to the loading state and remounts the map — the live swap goes
  /// through [ml.MapController.setStyle] instead.
  String? _lastStyleJson;

  /// Identity-keyed memo of [_composeStyle]'s last input/output — see the
  /// build() comment at the compose call site.
  String? _composeBaseInput;
  String? _composeOutput;

  /// [ml.MapOptions] built exactly once (first build with a resolved style):
  /// `MapOptions` has no value equality, so a fresh instance per build
  /// defeats the plugin's `didUpdateWidget` early-out and re-issues its
  /// min/max zoom + pitch JNI setters on every rebuild. Every field in it is
  /// init-only anyway (style/theme changes post-creation go through
  /// [_swapStyle], never through options).
  ml.MapOptions? _mapOptions;

  /// Active pointer count on the map surface. `CameraChangeReason.apiGesture`
  /// fires identically for pan/pinch/rotate (no native sub-classification
  /// exists), so this heuristic narrows follow-break to a single-finger
  /// drag. Read synchronously inside `onEvent` only — never mutated via
  /// `setState`.
  int _activePointers = 0;

  bool _followEnabled = true;
  bool _headingUp = false;
  bool _showingElevation = false;
  // Ceiling for maxChildSize — raised before animating to elevation and lowered
  // only after the shrink animation finishes, so the sheet never gets clamped
  // mid-animation.
  bool _sheetAtElevationSize = false;

  @override
  void initState() {
    super.initState();

    _showingElevation = !widget.isRecording;
    _sheetAtElevationSize = !widget.isRecording;
    WidgetsBinding.instance.addObserver(this);

    _hibernationContainer = ProviderScope.containerOf(context, listen: false);
    Future.microtask(() {
      if (mounted) {
        ref
            .read(navSessionHibernationProvider.notifier)
            .enterNavigationSession();
      }
    });

    _store = ref.read(objectBoxProvider);
    ref.read(tileProxyServerProvider)?.terrainDemGrid = _demGrid;
    unawaited(_peakFinder.ensureLoaded());
    final resumeSession = widget.resumeSession;
    _sessionNavJson = widget.isRecording
        ? null
        : (resumeSession?.navResponseJson ??
              jsonEncode(widget.response.toJson()));
    _resumeManeuverIndex = resumeSession?.currentManeuverIndex;
    _activeRowObxId = resumeSession?.obxId ?? 0;
    _recordingCosting =
        resumeSession?.recordingCosting ?? widget.recordingCosting;

    _breadcrumbSlab = ref.read(breadcrumbSlabStoreProvider);
    final slabPts = resumeSession != null
        ? (_breadcrumbSlab?.readAllWaypoints() ?? const <Wpt>[])
        : const <Wpt>[];
    if (resumeSession == null) {
      _breadcrumbSlab?.clear();
    }

    if (slabPts.isNotEmpty) {
      _resumeBreadcrumb = slabPts;
    } else {
      final resumePos = (resumeSession?.breadcrumbPolyline != null &&
              resumeSession!.breadcrumbPolyline!.isNotEmpty)
          ? PolylineUtil.decode(resumeSession.breadcrumbPolyline!)
          : null;
      // elevations/timestampsUtc may be null or shorter than the decoded
      // polyline (e.g. a row persisted before these fields existed) — index
      // defensively rather than assuming they're always the same length.
      final resumeElevations = resumeSession?.elevations;
      final resumeTimestamps = resumeSession?.timestampsUtc;
      _resumeBreadcrumb = resumePos
          ?.mapIndexed(
            (i, pos) => Wpt(
              lat: pos.lat,
              lon: pos.lon,
              ele: (resumeElevations != null && i < resumeElevations.length)
                  ? resumeElevations[i]
                  : null,
              time: (resumeTimestamps != null && i < resumeTimestamps.length)
                  ? DateTime.fromMillisecondsSinceEpoch(resumeTimestamps[i])
                  : null,
            ),
          )
          .toList();
    }
    _resumeStats = resumeSession != null
        ? NavigationStatsSeed(
            distanceMeters: resumeSession.distanceMeters,
            elevationGainMeters: resumeSession.elevationGainMeters,
            elevationLossMeters: resumeSession.elevationLossMeters,
            elapsed: Duration(seconds: resumeSession.currentElapsedSeconds),
            pausedAccum: Duration(seconds: resumeSession.pausedAccumSeconds),
            isPaused: resumeSession.isPaused,
          )
        : null;

    // Family instances + notifiers cached once — see the field docs. Every
    // later read/watch/listen in this file MUST go through these so the
    // family seeds can never split-brain.
    _navProviderInstance = navigationProvider(
      widget.response,
      resumeManeuverIndex: _resumeManeuverIndex,
      resumeBreadcrumb: _resumeBreadcrumb,
    );
    _statsProviderInstance = navigationStatsProvider(
      widget.response,
      resume: _resumeStats,
    );
    _navNotifier = ref.read(_navProviderInstance.notifier);
    _statsNotifier = ref.read(_statsProviderInstance.notifier);

    _positionSource = TraceletPositionSource();
    _positionStream = _positionSource.stream;

    _motionChannel = MountainMotionChannel();
    _powerEngine = MountainPowerEngine(
      onStateChanged: (nextState) {
        _powerStateNotifier.value = nextState;
        _statsNotifier.setStationary(_powerEngine.isStatsFrozen);
        _syncCompassSamplingRate();
        _syncCoasterTimer();
        _radioScheduler.updateState(
          isStationary: _powerEngine.isStationarySleep,
          expeditionMode: _powerEngine.effectiveExpeditionMode,
          sosActive: nextState == MountainPowerState.sosEmergencyMax,
        );
        if (nextState == MountainPowerState.stationaryCabanaSleep) {
          unawaited(_motionChannel.armStationaryWakeTrigger());
        } else {
          unawaited(_motionChannel.startStepMonitoring());
        }
      },
      onGpsTierChanged: (tier) {
        unawaited(_positionSource.applyGpsTier(tier));
      },
    );
    _powerEngine.setExpeditionMode(ref.read(expeditionBatteryModeProvider));

    // Keeps the per-fix handler free of provider reads: mirror the frozen
    // flag on every stats emission instead of re-deriving it per fix.
    ref.listenManual(_statsProviderInstance, fireImmediately: true, (_, next) {
      _frozen = next.isPaused || next.isStationary;
      _syncCoasterTimer();
    });
    ref.listenManual(trailLiveServiceProvider, fireImmediately: true, (_, next) {
      _liveService = next;
    });

    _sosOutboxStore = SosOutboxAndRelayStore();
    _bleMeshEngine = BleMeshEngine(
      knownClaimHashLookup: _sosOutboxStore.lookupClaimHash,
    );
    _bleSubscriptions.addAll(<StreamSubscription<Object?>>[
      _bleMeshEngine.onGroupPosReceived.listen(_onBleGroupPosReceived),
      _bleMeshEngine.onSosAlertReceived.listen(_onBleSosAlertReceived),
      _bleMeshEngine.onSosAckReceived.listen(_onBleSosAckReceived),
      _bleMeshEngine.onSosResolvedReceived.listen(_onBleSosResolvedReceived),
    ]);

    _radioScheduler = RadioSyncScheduler(
      onCoalescedBurst: _executeCoalescedRadioBurst,
    );
    _radioScheduler.updateState(
      isOnline: ref.read(onlineStatusProvider),
      uiForeground: _uiVisible,
      hasActiveGroup: _groupSession.value != null,
      isStationary: false,
      expeditionMode: _powerEngine.effectiveExpeditionMode,
      sosActive: false,
    );
    _radioScheduler.start();

    ref.listenManual(expeditionBatteryModeProvider, (_, enabled) {
      _powerEngine.setExpeditionMode(enabled);
      _syncCompassSamplingRate();
      _radioScheduler.updateState(
        expeditionMode: _powerEngine.effectiveExpeditionMode,
      );
    });
    _myActiveSos.addListener(_syncSosPowerOverride);
    _nearbySosAlerts.addListener(_syncSosPowerOverride);

    final seededGroup = ref.read(globalGroupSessionProvider);
    if (seededGroup != null && _groupSession.value == null) {
      _groupSession.value = seededGroup;
      _configureBleForActiveGroup(seededGroup);
      _radioScheduler.updateState(hasActiveGroup: true);
    }
    _groupSessionSyncListener = () {
      if (!mounted) return;
      ref
          .read(globalGroupSessionProvider.notifier)
          .syncExternalSession(_groupSession.value);
    };
    _groupSession.addListener(_groupSessionSyncListener!);

    _motionSub = _motionChannel.events.listen(_powerEngine.ingestMotionEvent);
    unawaited(_motionChannel.startStepMonitoring());
    _powerWatchdogTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _powerEngine.evaluateTick();
      unawaited(
        _motionChannel.getBatterySnapshot().then(
          _powerEngine.ingestBatterySnapshot,
        ),
      );
    });

    ref.listenManual(onlineStatusProvider, (prev, next) {
      _radioScheduler.updateState(isOnline: next);
      if (next && prev == false) {
        unawaited(_flushSosOutboxAndRelayQueue());
        if (_uiVisible) {
          final curFix = _currentGeoFix();
          if (curFix != null && _firstHeartbeatSent) {
            _connectLiveSse(curFix);
          }
        }
      }
    });

    if (resumeSession == null) {
      // Fresh session: clear any stale prior-trail row, then write an
      // initial zeroed row for this trail.
      active_nav.clear(_store);
      _breadcrumbSlab?.clear();
      _persistNow(force: true);
    }
    _persistTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _persistNow(),
    );
    _syncCoasterTimer();
    // AppLocalizations.of(context) isn't safe to call synchronously here —
    // inherited-widget dependencies aren't established until after the first
    // frame — so the notification-text lookup (and thus `start()`) is
    // deferred by one frame.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final localizations = AppLocalizations.of(context)!;
      _localeCode = localizations.localeName;
      if (!widget.isRecording &&
          _showingElevation &&
          !_didAutoExpandSheet &&
          _sheetController.isAttached) {
        _didAutoExpandSheet = true;
        _sheetController.animateTo(
          _elevationSheetSize,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
      // Awaited (not fire-and-forget) purely so the rewrite below can never
      // reconfigure the service before it has been configured.
      await _positionSource.start(
        notificationTitle: localizations.location_tracking_notification_title,
        notificationText: _notificationText(localizations),
        seed: widget.initialPosition,
      );
      unawaited(_initBleAndRestoreSosOutbox());
      // The navigating notification names the trail, and the elevation
      // chart's live-position matcher needs the trail's GPX — the trail
      // model can still be loading right here, since a session resumed at
      // launch pushes straight to this route with nothing warm to read, so
      // `start()` above had to fall back to the generic wording. Resolve it
      // ONCE and use it for both; the trail is fixed for the session
      // (switching trails means leaving this screen), so there is nothing
      // further to watch. A no-op notification rewrite in the common case
      // where the name was already known at `start()`.
      if (widget.isRecording) return;
      _fetchInitialTrailLiveSummary();
      // Failure (offline with nothing cached) leaves the generic wording
      // rather than naming a trail we don't have, and the chart marker off.
      final trail = await ref
          .read(trailProvider(widget.id).future)
          .then<Trail?>((trail) => trail, onError: (_) => null);
      if (!mounted || trail == null) return;
      _initTrailNavigation(trail);
      final name = trail.name;
      if (name.isEmpty) return;
      await _positionSource.setNotificationText(
        localizations.location_tracking_notification_text_navigating(name),
      );
    });
    // Single stream drives both recording/stats and the live marker/camera —
    // TraceletPositionSource swaps between a continuous foreground config and
    // a battery-conscious background config (see [_positionSource.setForeground],
    // called from [didChangeAppLifecycleState]) rather than running a second,
    // separate GPS session just for the UI.
    _sub = _positionStream.listen(
      (pos) {
        // HOT PATH — one call per GPS fix for the whole session. Zero
        // provider lookups here by design: every ref.read hashes the family
        // argument, which deep-walks the full route shape (see the
        // _navProviderInstance field docs).
        //
        // Frozen (manually paused and/or tracelet-detected stationary) must
        // not append to the breadcrumb — that's the data persisted to disk
        // and exported as the saved trail's GPX. Maneuver-advance detection
        // is unrelated bookkeeping and must keep running even while frozen,
        // so it's not gated here — only the breadcrumb append is.
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        _powerEngine.ingestGpsFix(
          lat: pos.latitude,
          lon: pos.longitude,
          speedMps: pos.speed,
          accuracyM: pos.accuracy,
        );
        final rawFix = ml.Geographic(lat: pos.latitude, lon: pos.longitude);
        final usableAlt = hasUsableAltitude(pos) ? pos.altitude : null;
        if (usableAlt != null) _lastKnownAltitudeM = usableAlt;

        _lastRawSelfFix = SelfGpsObservation(
          lat: pos.latitude,
          lon: pos.longitude,
          accuracy: pos.accuracy,
          ele: usableAlt,
          timestampMs: nowMs,
        );
        _lastRawSpeed = pos.speed;
        _lastRawHeading = pos.heading;

        final fused = widget.isRecording
            ? null
            : CooperativeGpsFusion.fuse(
                selfFix: _lastRawSelfFix,
                peers: _peerObservations(nowMs),
                lastCoLocatedPeerIds: _lastCoLocatedPeerIds,
                nowMs: nowMs,
              );
        if (fused != null) {
          _lastCoLocatedPeerIds = fused.coLocatedPeerIds;
          _effectiveGpsAccuracy.value = fused.accuracy;
        } else {
          _effectiveGpsAccuracy.value = pos.accuracy;
        }

        final effectiveLat = fused?.lat ?? pos.latitude;
        final effectiveLon = fused?.lon ?? pos.longitude;
        final effectiveAcc = fused?.accuracy ?? pos.accuracy;
        final fix = ml.Geographic(lat: effectiveLat, lon: effectiveLon);

        final advanced = _navNotifier.onPosition(
          fix,
          // `null`, never a fabricated 0, when the fix carries no real
          // altitude (see [hasUsableAltitude]). The breadcrumb IS the saved
          // trail's GPX, and computeTrailMetrics deliberately skips waypoints
          // with no usable `ele` so the first point that does carry elevation
          // becomes the anchor. Passing 0 here instead would bake a
          // ~absolute-altitude phantom climb into every saved recording that
          // started from an already-resolved map-marker position.
          altitude: usableAlt,
          heading: pos.heading,
          headingAccuracy: pos.headingAccuracy,
          speed: pos.speed,
          accuracy: effectiveAcc,
          recordBreadcrumb: !_frozen,
        );
        _statsNotifier.onPosition(pos);
        _onFix(
          pos,
          latOverride: effectiveLat,
          lonOverride: effectiveLon,
          accuracyOverride: effectiveAcc,
        );
        // Same fix that just drove _onFix (the map marker), so the map
        // marker and the elevation chart's marker never disagree. Not
        // gated on _frozen — a paused user's position is still valid.
        final matcher = _trackMatcher;
        if (!widget.isRecording && matcher != null) {
          _handleNavMatchFix(
            pos,
            fix,
            matcher,
            effectiveAccuracy: effectiveAcc,
            fusedSource: fused?.source ?? FusedGpsSource.self,
            nowMs: nowMs,
          );
        }
        _onLiveCommunityFix(rawFix, usableAlt);
        if (advanced) {
          _persistNow();
        }
      },
      onError: (Object error) {
        debugPrint('NavigationScreen: GPS stream error — $error');
      },
    );

    _syncCompassSamplingRate();
  }

  /// Builds [_trackMatcher] from the navigated trail's [gpx], once, from the
  /// post-frame callback in [initState] — never from the per-fix hot path.
  /// Uses [buildRawTrackPoints] (not the chart's 250-point thinning) so
  /// switchbacks are not chord-cut, and the same raw `distanceM` axis the
  /// chart plots on. Leaves [_trackMatcher] null (no live marker) when
  /// [gpx] is absent or has fewer than 2 plottable points.
  void _initTrackMatcher(Gpx? gpx) {
    if (gpx == null || _trackMatcher != null) return;
    final raw = buildRawTrackPoints(gpx);
    if (raw.length < 2) return;
    _trackMatcher = TrackPositionMatcher(
      shape: raw.map((p) => p.lonlat).toList(growable: false),
      cumulativeMeters: raw.map((p) => p.distanceM).toList(growable: false),
    );
  }

  void _initTrailNavigation(Trail trail) {
    final gpx = trail.expand?.gpx;
    if (gpx == null) return;
    _initTrackMatcher(gpx);
    if (_etaCalculator != null) return;

    final navPoints = extractNavTrackPoints(gpx);
    if (navPoints.length < 2) return;
    _navTrackPoints = navPoints;

    _trackMatcher ??= TrackPositionMatcher(
      shape: navPoints.map((p) => p.geographic).toList(growable: false),
      cumulativeMeters: navPoints
          .map((p) => p.distanceM)
          .toList(growable: false),
    );

    final isCycling =
        costingForTrail(trail, subcategories: ref.read(subcategoryProvider)) ==
        'bicycle';
    final calc = EtaCalculator.fromPoints(navPoints, isCycling: isCycling);
    _etaCalculator = calc;
    _paceCoaster = GpsPaceCoaster(navPoints, isCycling: isCycling);
    _etaNotifier.value = calc.compute(0.0);

    final localDemArchives = <String>[
      for (final r in _store.box<RegionEntity>().getAll())
        if (r.demPackage.target?.localFilePath != null)
          r.demPackage.target!.localFilePath!,
    ];
    _demGrid.setDemArchivePaths(localDemArchives);

    final corridorGeos = navPoints
        .map((p) => p.geographic)
        .toList(growable: false);

    unawaited(() async {
      final supportDir = await getApplicationSupportDirectory();
      final token = await _resolveDeviceToken();
      if (!mounted) return;
      final apiUrl = ref.read(apiProvider).options.baseUrl;
      final worker = await NavTerrainWorkerIsolate.spawn(
        trailPoints: navPoints,
        isCycling: isCycling,
        localeCode: _localeCode,
        demTileUrlTemplate: _demGrid.tileUrlTemplate,
        cacheRootPath: supportDir.path,
        demArchivePaths: localDemArchives,
        apiBaseUrl: apiUrl.contains('unconfigured') ? null : apiUrl,
        deviceToken: token,
        onHybridRerouteReady: (hybrid) {
          if (!mounted ||
              hybrid.generation != _rerouteGeneration ||
              _farPreviewDistanceM.value != null) {
            return;
          }
          _applyWorkerRerouteResponse(hybrid);
        },
      );
      if (!mounted) {
        await worker.dispose();
        return;
      }
      _terrainWorker = worker;
      await worker.prefetchCorridor(corridorGeos);
      if (mounted) {
        _maybeUpdateSolarForecast(force: true);
      }
    }());
  }

  List<PeerGpsObservation> _peerObservations(int nowMs) {
    final session = _groupSession.value;
    if (session == null) return const <PeerGpsObservation>[];
    final peers = session.peers;
    if (peers.isEmpty) return const <PeerGpsObservation>[];
    return <PeerGpsObservation>[
      for (final p in peers)
        if (!p.viaBluetooth || p.bleHopCount == 0)
          PeerGpsObservation(
            memberId: p.memberId,
            lat: p.lat,
            lon: p.lon,
            accuracy: p.accuracy,
            ele: p.ele,
            updatedAtMs: p.updatedAt?.millisecondsSinceEpoch ?? nowMs,
          ),
    ];
  }

  void _onCoasterTick() {
    if (!mounted || widget.isRecording || _paceCoaster == null) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final rawSelf = _lastRawSelfFix;

    // Only activate groupTether / autonomous coasting when own GPS fix is >6s old.
    if (rawSelf != null &&
        (nowMs - rawSelf.timestampMs) <= CooperativeGpsFusion.maxOwnFixAgeMs) {
      return;
    }

    final tethered = CooperativeGpsFusion.fuse(
      selfFix: rawSelf,
      peers: _peerObservations(nowMs),
      lastCoLocatedPeerIds: _lastCoLocatedPeerIds,
      nowMs: nowMs,
    );

    if (tethered != null && tethered.source == FusedGpsSource.groupTether) {
      _lastCoLocatedPeerIds = tethered.coLocatedPeerIds;
      _effectiveGpsAccuracy.value = tethered.accuracy;
      _gpsSignalState.value = GpsSignalState.cooperative;
      _animateMarkerTo(tethered.lat, tethered.lon, tethered.accuracy);
      final matcher = _trackMatcher;
      if (matcher != null) {
        final detail = matcher.matchDetailed(
          tethered.geographic,
          accuracy: tethered.accuracy,
        );
        if (detail != null) {
          _lastMatchedAlongTrackM = detail.alongTrackMeters;
          _liveTrackMeters.value = detail.alongTrackMeters;
          _etaNotifier.value = _etaCalculator?.compute(detail.alongTrackMeters);
        }
      }
      return;
    }

    final coast = _paceCoaster!.tickCoasting(
      nowMs,
      _etaCalculator?.paceFactor ?? 1.0,
      _frozen,
    );
    if (coast == null) return;

    _gpsSignalState.value = GpsSignalState.coasting;
    _effectiveGpsAccuracy.value = coast.effectiveAccuracyM;
    _lastMatchedAlongTrackM = coast.effectiveAlongM;
    _liveTrackMeters.value = coast.effectiveAlongM;
    _etaNotifier.value = _etaCalculator?.compute(coast.effectiveAlongM);
    _animateMarkerTo(coast.lat, coast.lon, coast.effectiveAccuracyM);
  }

  void _handleNavMatchFix(
    geo.Position pos,
    ml.Geographic fix,
    TrackPositionMatcher matcher, {
    required double effectiveAccuracy,
    required FusedGpsSource fusedSource,
    required int nowMs,
  }) {
    final seq = ++_matchFixSeq;
    final worker = _terrainWorker;
    if (worker != null && !worker.isDisposed) {
      unawaited(
        worker
            .matchFix(
              lat: fix.lat,
              lon: fix.lon,
              heading: pos.heading,
              headingAccuracy: pos.headingAccuracy,
              speed: pos.speed,
              accuracy: effectiveAccuracy,
              recordProgress: !_frozen,
              nowMs: nowMs,
              activeOffTrail: _offTrailNotifier.value,
            )
            .then((resp) {
              if (!mounted || resp == null || seq < _latestAppliedMatchSeq) {
                return;
              }
              _latestAppliedMatchSeq = seq;
              _applyNavMatchDetail(
                resp.detail,
                fix: fix,
                effectiveAccuracy: effectiveAccuracy,
                fusedSource: fusedSource,
                nowMs: nowMs,
                workerEta: resp.eta,
              );
            }),
      );
      return;
    }

    final detail = matcher.matchDetailed(
      fix,
      heading: pos.heading,
      headingAccuracy: pos.headingAccuracy,
      speed: pos.speed,
      accuracy: effectiveAccuracy,
    );
    if (detail == null) return;
    _latestAppliedMatchSeq = seq;
    _applyNavMatchDetail(
      detail,
      fix: fix,
      effectiveAccuracy: effectiveAccuracy,
      fusedSource: fusedSource,
      nowMs: nowMs,
    );
  }

  void _applyNavMatchDetail(
    TrackMatchDetail detail, {
    required ml.Geographic fix,
    required double effectiveAccuracy,
    required FusedGpsSource fusedSource,
    required int nowMs,
    EtaSnapshot? workerEta,
  }) {
    final coastSnap = _paceCoaster?.ingestFix(
      lat: fix.lat,
      lon: fix.lon,
      accuracy: effectiveAccuracy,
      matchedAlongM: detail.alongTrackMeters,
      crossTrackM: detail.crossTrackMeters,
      isPaused: _frozen,
      paceFactor: workerEta?.paceFactor ?? _etaCalculator?.paceFactor ?? 1.0,
      nowMs: nowMs,
      fusedSource: fusedSource,
    );

    if (coastSnap != null) {
      _gpsSignalState.value = coastSnap.signalState;
    }

    final effectiveAlongM =
        coastSnap?.effectiveAlongM ?? detail.alongTrackMeters;
    final suppressOffTrail = coastSnap?.suppressOffTrail ?? false;
    final effectiveOffTrail = detail.isOffTrail && !suppressOffTrail;

    _lastMatchedAlongTrackM = effectiveAlongM;
    _liveTrackMeters.value = effectiveAlongM;

    // > 3000 m Calm Preview Mode: never draw automatic cross-country line.
    if (detail.crossTrackMeters > OffTrailRouter.farPreviewThresholdMeters) {
      _farPreviewDistanceM.value = detail.crossTrackMeters;
      if (!_showingAccessRoute && _offTrailNotifier.value != null) {
        _clearOffTrailState();
      }
      _etaNotifier.value =
          workerEta ?? _etaCalculator?.compute(effectiveAlongM);
      return;
    }

    if (_farPreviewDistanceM.value != null) {
      _farPreviewDistanceM.value = null;
      if (_showingAccessRoute) {
        _showingAccessRoute = false;
        _clearOffTrailState();
      }
    }

    if (!effectiveOffTrail) {
      if (_offTrailNotifier.value != null) {
        _clearOffTrailState();
      }
      if (workerEta == null) {
        _etaCalculator?.recordProgress(effectiveAlongM, DateTime.now());
      }
      _etaNotifier.value =
          workerEta ?? _etaCalculator?.compute(effectiveAlongM);
      return;
    }

    if (_terrainWorker == null &&
        !_demFallbackPrefetchStarted &&
        ref.read(onlineStatusProvider) &&
        _demGrid.sampleElevation(fix.lat, fix.lon) == null) {
      _demFallbackPrefetchStarted = true;
      unawaited(
        _demGrid.prefetchCorridor([fix, detail.matchedPoint]).then((_) {
          if (!mounted || _offTrailNotifier.value == null) return;
          final curPos = _lastRerouteCalcPos;
          final curAlong = _lastMatchedAlongTrackM;
          if (curPos != null && curAlong != null) {
            _recomputeOffTrailReroute(curPos, curAlong);
          }
        }),
      );
    }

    final now = DateTime.now();
    final movedM = _lastRerouteCalcPos == null
        ? double.infinity
        : ml.SphericalGreatCircle(_lastRerouteCalcPos!).distanceTo(fix);
    final elapsedSec = _lastRerouteCalcAt == null
        ? 999
        : now.difference(_lastRerouteCalcAt!).inSeconds;
    final shouldRecompute =
        _offTrailNotifier.value == null ||
        _lastRerouteCalcMode != _offTrailMode ||
        movedM >= 20.0 ||
        elapsedSec >= 10;

    if (shouldRecompute) {
      _recomputeOffTrailReroute(fix, effectiveAlongM);
    } else {
      final active = _offTrailNotifier.value;
      _etaNotifier.value =
          workerEta ??
          _etaCalculator?.compute(
            effectiveAlongM,
            now: now,
            offTrailDistanceM: active?.distanceM,
            offTrailDurationSec: active?.estimatedSeconds,
            offTrailAscentM: active?.ascentM,
            rejoinAlongTrackM: active?.rejoinAlongTrackM,
          );
    }
  }

  void _clearOffTrailState() {
    _valhallaRerouteCancelToken?.cancel('cleared');
    _valhallaRerouteCancelToken = null;
    final nextGen = ++_rerouteGeneration;
    _terrainWorker?.cancelActiveReroutes(nextGen);
    _offTrailNotifier.value = null;
    _offTrailChartSpots.value = null;
    _lastRerouteCalcPos = null;
    _lastRerouteCalcMode = null;
    _lastRerouteCalcAt = null;
    _demFallbackPrefetchStarted = false;
    _pushOffTrailSource(null);
  }

  void _applyWorkerRerouteResponse(WorkerRerouteResponse resp) {
    final alongM = _lastMatchedAlongTrackM ?? 0.0;
    _lastRerouteCalcMode = resp.result.mode;
    _lastRerouteCalcAt = DateTime.now();
    _offTrailNotifier.value = resp.result;
    _offTrailChartSpots.value = _buildOffTrailChartSpots(alongM, resp.result);
    if (resp.eta != null) {
      _etaNotifier.value = resp.eta;
    }
    if (_uiVisible) {
      final style = _controller?.style ?? _loadedStyle;
      style
          ?.updateGeoJsonSource(
            id: 'off-trail-reroute',
            data: resp.geoJsonString,
          )
          .catchError((Object _) {});
    }
  }

  void _applyRerouteResult(
    OffTrailRerouteResult? reroute,
    ml.Geographic userPos,
    double alongTrackM,
  ) {
    final now = DateTime.now();
    _lastRerouteCalcPos = userPos;
    _lastRerouteCalcMode = _offTrailMode;
    _lastRerouteCalcAt = now;
    _offTrailNotifier.value = reroute;
    _offTrailChartSpots.value = reroute == null
        ? null
        : _buildOffTrailChartSpots(alongTrackM, reroute);
    _pushOffTrailSource(reroute);
    _etaNotifier.value = _etaCalculator?.compute(
      alongTrackM,
      now: now,
      offTrailDistanceM: reroute?.distanceM,
      offTrailDurationSec: reroute?.estimatedSeconds,
      offTrailAscentM: reroute?.ascentM,
      rejoinAlongTrackM: reroute?.rejoinAlongTrackM,
    );
  }

  void _recomputeOffTrailReroute(ml.Geographic userPos, double alongTrackM) {
    if (_navTrackPoints.length < 2) return;
    _valhallaRerouteCancelToken?.cancel('superseded');
    _valhallaRerouteCancelToken = null;
    final myGen = ++_rerouteGeneration;
    _lastRerouteCalcPos = userPos;
    _lastRerouteCalcMode = _offTrailMode;
    _lastRerouteCalcAt = DateTime.now();

    final worker = _terrainWorker;
    final tryValhalla =
        ref.read(onlineStatusProvider) && (_liveService?.isConfigured ?? false);
    if (worker != null && !worker.isDisposed) {
      unawaited(
        worker
            .computeReroute(
              generation: myGen,
              userPos: userPos,
              userEleM: _lastKnownAltitudeM,
              alongTrackM: alongTrackM,
              mode: _offTrailMode,
              localeCode: _localeCode,
              tryValhalla: tryValhalla,
            )
            .then((resp) {
              if (!mounted ||
                  resp == null ||
                  myGen != _rerouteGeneration ||
                  _farPreviewDistanceM.value != null) {
                return;
              }
              _applyWorkerRerouteResponse(resp);
            }),
      );
      return;
    }

    // Synchronous fallback only during the first ~40ms before worker spawn resolves.
    final localReroute = OffTrailRouter.compute(
      userPos: userPos,
      userEleM: _lastKnownAltitudeM,
      trailPoints: _navTrackPoints,
      lastAlongTrackM: alongTrackM,
      sampler: _demGrid.sampleElevation,
      mode: _offTrailMode,
      localeCode: _localeCode,
      isCycling: _etaCalculator?.isCycling ?? false,
      precomputedEta: _etaCalculator,
    );
    _applyRerouteResult(localReroute, userPos, alongTrackM);
  }

  Future<void> _toggleFarPreviewAccessRoute() async {
    if (_showingAccessRoute) {
      setState(() => _showingAccessRoute = false);
      _offTrailNotifier.value = null;
      _pushOffTrailSource(null);
      return;
    }

    final pos = _currentGeoFix();
    if (pos == null ||
        _navTrackPoints.isEmpty ||
        !(_liveService?.isConfigured ?? false)) {
      return;
    }

    _accessRouteLoading.value = true;
    try {
      final route = await OffTrailRouter.computeValhallaAccessRoute(
        dio: ref.read(apiProvider),
        userPos: pos,
        userEleM: _lastKnownAltitudeM,
        trailPoints: _navTrackPoints,
        sampler: _demGrid.sampleElevation,
        localeCode: _localeCode,
        isCycling: _etaCalculator?.isCycling ?? false,
      );
      if (!mounted || route == null) return;
      setState(() => _showingAccessRoute = true);
      _offTrailNotifier.value = route;
      _pushOffTrailSource(route);
    } finally {
      if (mounted) _accessRouteLoading.value = false;
    }
  }

  List<FlSpot>? _buildOffTrailChartSpots(
    double alongTrackM,
    OffTrailRerouteResult reroute,
  ) {
    if (_navTrackPoints.length < 2 || reroute.points.length < 2) return null;
    final maxDist = _navTrackPoints.last.distanceM;
    if (maxDist <= 0) return null;

    final rejoinX = reroute.rejoinAlongTrackM.clamp(0.0, maxDist);
    var startX = alongTrackM.clamp(0.0, maxDist);
    var endX = rejoinX;
    if ((endX - startX).abs() < 8.0) {
      final span = min(maxDist * 0.15, max(20.0, reroute.distanceM));
      if (rejoinX >= span) {
        startX = rejoinX - span;
      } else {
        startX = 0.0;
        endX = min(maxDist, span);
      }
    }

    final totalOffDist = reroute.distanceM > 0 ? reroute.distanceM : 1.0;
    final spots = <FlSpot>[
      for (final pt in reroute.points)
        FlSpot(
          startX + (endX - startX) * (pt.distanceM / totalOffDist).clamp(0.0, 1.0),
          pt.ele,
        ),
    ];
    if (spots.length >= 2 && spots.first.x > spots.last.x) {
      return spots.reversed.toList(growable: false);
    }
    return spots;
  }

  void _selectOffTrailMode(OffTrailMode mode) {
    if (_offTrailMode == mode) return;
    _offTrailMode = mode;
    final pos =
        _lastRerouteCalcPos ??
        (_lastLat != null && _lastLon != null
            ? ml.Geographic(lat: _lastLat!, lon: _lastLon!)
            : null);
    final along = _lastMatchedAlongTrackM;
    if (pos != null && along != null) {
      _recomputeOffTrailReroute(pos, along);
    }
  }

  // ---------------------------------------------------------------------------
  // Live Community: Waze Reports, Permanent Landmarks, 30m Presence & 5km SOS
  // ---------------------------------------------------------------------------

  ml.Geographic? _currentGeoFix() {
    final lat = _animTargetLat ?? _lastLat;
    final lon = _animTargetLon ?? _lastLon;
    if (lat != null && lon != null) {
      return ml.Geographic(lat: lat, lon: lon);
    }
    final seed = widget.initialPosition;
    if (seed != null) {
      return ml.Geographic(lat: seed.latitude, lon: seed.longitude);
    }
    return null;
  }

  void _fetchInitialTrailLiveSummary() {
    final service = _liveService;
    if (service == null || !service.isConfigured || widget.id.isEmpty) return;
    unawaited(
      service.fetchTrailSummary(widget.id).then((summary) {
        if (!mounted || summary == null) return;
        _applyLiveSummary(summary);
      }).catchError((Object _) {}),
    );
  }

  Future<String> _resolveDeviceToken() {
    final service = _liveService;
    if (service != null) {
      return service.getDeviceToken();
    }
    return LiveDeviceTokenStore.getOrCreateToken();
  }

  Future<bool> _ensureBlePermissions() async {
    if (!_bleMeshEngine.isSupportedPlatform) return false;
    final alreadyGranted = await _bleMeshEngine.checkPermissions();
    if (alreadyGranted) {
      unawaited(_bleMeshEngine.getState());
      return true;
    }
    if (_blePermissionsRequestedOnce) {
      return false;
    }
    _blePermissionsRequestedOnce = true;
    final granted = await _bleMeshEngine.requestPermissions();
    unawaited(_bleMeshEngine.getState());
    return granted;
  }

  void _syncBleRadioMode() {
    if (!_bleMeshEngine.isSupportedPlatform) return;
    final targetMode = _myActiveSos.value != null
        ? BleRadioMode.sosEmergencyActive
        : (_groupSession.value != null
              ? BleRadioMode.groupMeshNormal
              : BleRadioMode.passiveTrailGuard);
    if (_bleMeshEngine.radioMode != targetMode) {
      unawaited(_bleMeshEngine.setRadioMode(targetMode));
    }
  }

  Future<void> _initBleAndRestoreSosOutbox() async {
    await _sosOutboxStore.ensureLoaded();
    if (!mounted) return;

    final pendingMine = _sosOutboxStore.myPendingSos;
    if (pendingMine != null && pendingMine.isActive) {
      final serverId = pendingMine.serverSosId;
      final restored = SosAlertModel(
        id: (serverId != null && serverId.isNotEmpty)
            ? serverId
            : 'local-${pendingMine.clientSosId}',
        clientSosId: pendingMine.clientSosId,
        trailId: pendingMine.trailId,
        status: 'active',
        reason: pendingMine.reason,
        message: pendingMine.message,
        requesterName: pendingMine.requesterName,
        lat: pendingMine.lat,
        lon: pendingMine.lon,
        ele: pendingMine.ele,
        isMine: true,
        viaBluetooth: true,
        bleServerConfirmed: serverId != null && serverId.isNotEmpty,
        localClaimSecret: pendingMine.sosClaimSecret,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          pendingMine.createdEpochSec * 1000,
          isUtc: true,
        ),
      );
      _myActiveSos.value = restored;
      await _ensureBlePermissions();
      if (!mounted) return;
      final bleAlert = BleSosAlertPacket(
        clientSosId: pendingMine.clientSosId,
        sosClaimHash: pendingMine.sosClaimHash,
        reason: pendingMine.reason,
        isStationary: _frozen,
        lat: pendingMine.lat,
        lon: pendingMine.lon,
        eleM: pendingMine.ele.round(),
        createdEpochSec: pendingMine.createdEpochSec,
        shortMsg: BleSosAlertPacket.composeShortMsg(
          requesterName: pendingMine.requesterName,
          message: pendingMine.message,
        ),
      );
      await _bleMeshEngine.publishLocalSosAlert(
        bleAlert,
        activateEmergencyMode: true,
      );
    } else {
      final permitted = await _ensureBlePermissions();
      if (!mounted) return;
      if (permitted) {
        _syncBleRadioMode();
      }
    }

    unawaited(_flushSosOutboxAndRelayQueue());
  }

  void _onLiveCommunityFix(ml.Geographic fix, double? usableAlt) {
    if (!_firstHeartbeatSent) {
      _firstHeartbeatSent = true;
      unawaited(
        _radioScheduler.triggerImmediateBurst(
          reason: 'first_fix',
          forceHeartbeat: true,
        ),
      );
      if (_uiVisible) {
        _connectLiveSse(fix);
      }
    }

    _refreshNearbyWazePrompt(fix);

    final now = DateTime.now();
    final activeGroup = _groupSession.value;
    if (activeGroup != null && _bleMeshEngine.isSupportedPlatform) {
      final lastBlePos = _lastBleGroupBroadcastPos;
      final lastBleAt = _lastBleGroupBroadcastAt;
      final movedBleM = lastBlePos == null
          ? double.infinity
          : ml.SphericalGreatCircle(lastBlePos).distanceTo(fix);
      final elapsedBleMs = lastBleAt == null
          ? 999999
          : now.difference(lastBleAt).inMilliseconds;
      final stationaryBleMs = _powerEngine.isStationarySleep ? 120000 : 15000;
      if ((movedBleM >= 5.0 && elapsedBleMs >= 3000) ||
          elapsedBleMs >= stationaryBleMs) {
        _lastBleGroupBroadcastPos = fix;
        _lastBleGroupBroadcastAt = now;
        final rawSelf = _lastRawSelfFix;
        final accM = (rawSelf?.accuracy ?? 15.0).round().clamp(1, 255);
        final eleM = (usableAlt ?? _lastKnownAltitudeM ?? 0.0).round();
        final pkt = BleGroupPosPacket(
          memberIdHex: activeGroup.selfMemberId,
          lat: fix.lat,
          lon: fix.lon,
          eleM: eleM,
          accuracyM: accM,
          inNavigation: true,
          headingDeg: _lastRawHeading ?? _smoothedHeading,
          speedMps: _lastRawSpeed,
          displayName: _selfGroupDisplayName,
          timestampSec: now.toUtc().millisecondsSinceEpoch ~/ 1000,
        );
        unawaited(_bleMeshEngine.publishLocalGroupPosition(pkt));
      }
    }

    final mySos = _myActiveSos.value;
    if (mySos != null) {
      final lastSosPos = _lastSosBroadcastPos;
      final lastSosAt = _lastSosBroadcastAt;
      final movedM = lastSosPos == null
          ? double.infinity
          : ml.SphericalGreatCircle(lastSosPos).distanceTo(fix);
      final elapsedSec = lastSosAt == null
          ? 999
          : now.difference(lastSosAt).inSeconds;
      if (movedM >= 15.0 && elapsedSec >= 60) {
        _lastSosBroadcastPos = fix;
        _lastSosBroadcastAt = now;
        final curEle = usableAlt ?? _lastKnownAltitudeM ?? mySos.ele;
        final nowEpochSec = now.toUtc().millisecondsSinceEpoch ~/ 1000;

        final cid = mySos.clientSosId;
        final claimHash = cid != null
            ? _sosOutboxStore.lookupClaimHash(cid)
            : null;
        if (cid != null && claimHash != null) {
          final updatedBleAlert = BleSosAlertPacket(
            clientSosId: cid,
            sosClaimHash: claimHash,
            reason: mySos.reason,
            isStationary: _frozen,
            lat: fix.lat,
            lon: fix.lon,
            eleM: curEle.round(),
            createdEpochSec: nowEpochSec,
            shortMsg: BleSosAlertPacket.composeShortMsg(
              requesterName: mySos.requesterName,
              message: mySos.message,
            ),
          );
          unawaited(
            _bleMeshEngine.publishLocalSosAlert(
              updatedBleAlert,
              activateEmergencyMode: true,
            ),
          );
        }

        final service = _liveService;
        if (service != null &&
            service.isConfigured &&
            !mySos.id.startsWith('local-')) {
          unawaited(
            service
                .updateSos(
                  sosId: mySos.id,
                  lat: fix.lat,
                  lon: fix.lon,
                  ele: curEle,
                  sosClaimSecret: mySos.localClaimSecret,
                )
                .then((updated) {
                  if (!mounted) return;
                  final cur = _myActiveSos.value;
                  if (cur != null && updated.isActiveAt(DateTime.now())) {
                    _myActiveSos.value = _mergeIntoMyActiveSos(cur, updated);
                  }
                })
                .catchError((Object _) {}),
          );
        }
      }
    }

    final respondingSos = _activeRespondingSos();
    if (respondingSos != null) {
      final lastCalcPos = _lastRescueCalcPos;
      final lastCalcAt = _lastRescueCalcAt;
      final movedM = lastCalcPos == null
          ? double.infinity
          : ml.SphericalGreatCircle(lastCalcPos).distanceTo(fix);
      final elapsedSec = lastCalcAt == null
          ? 999
          : now.difference(lastCalcAt).inSeconds;
      if (_rescueRouteNotifier.value == null ||
          movedM >= 20.0 ||
          elapsedSec >= 12) {
        _recomputeRescueRoute(fix, respondingSos, syncWithServer: true);
      }
    } else if (_rescueRouteNotifier.value != null) {
      _rescueRouteNotifier.value = null;
      _pushRescueSource(null);
    }
  }

  SosAlertModel _mergeIntoMyActiveSos(
    SosAlertModel local,
    SosAlertModel server,
  ) {
    return server.copyWith(
      isMine: true,
      clientSosId: server.clientSosId ?? local.clientSosId,
      viaBluetooth: local.viaBluetooth || server.viaBluetooth,
      bleAckCount: local.bleAckCount,
      bleServerConfirmed: true,
      bleNearestEtaMin: local.bleNearestEtaMin,
      bleNearestDistanceM: local.bleNearestDistanceM,
      localClaimSecret: local.localClaimSecret,
    );
  }

  SosAlertModel _mergeNearbySos(SosAlertModel existing, SosAlertModel incoming) {
    final preferIncomingId =
        !incoming.id.startsWith('ble-') || existing.id.startsWith('ble-');
    return incoming.copyWith(
      id: preferIncomingId ? incoming.id : existing.id,
      clientSosId: incoming.clientSosId ?? existing.clientSosId,
      amResponding: existing.amResponding || incoming.amResponding,
      responderCount: max(existing.responderCount, incoming.responderCount),
      viaBluetooth: existing.viaBluetooth || incoming.viaBluetooth,
      bleHopCount: incoming.viaBluetooth
          ? incoming.bleHopCount
          : existing.bleHopCount,
    );
  }

  SosAlertModel? _activeRespondingSos() {
    for (final s in _nearbySosAlerts.value) {
      if (s.amResponding && s.status == 'active') return s;
    }
    return null;
  }

  void _syncSosPowerOverride() {
    final sosEmergency =
        _myActiveSos.value != null || _activeRespondingSos() != null;
    _powerEngine.setSosActive(sosEmergency);
  }

  Future<bool> _executeCoalescedRadioBurst(RadioBurstContext ctx) async {
    final service = _liveService;
    if (service == null || !service.isConfigured) return false;
    if (!ref.read(onlineStatusProvider) && !ctx.sosActive) return false;

    var anySucceeded = false;
    final tasks = <Future<void>>[];

    tasks.add(
      _flushSosOutboxAndRelayQueue().then((_) {
        anySucceeded = true;
      }).catchError((Object _) {}),
    );

    final session = _groupSession.value;
    final pos = _currentGeoFix();
    if (session != null && !session.isOfflineBleGroup && pos != null) {
      final rawSelf = _lastRawSelfFix;
      final acc =
          rawSelf?.accuracy ?? (_animAccuracy > 0 ? _animAccuracy : 15.0);
      final sseLive = _liveSseSub != null && _uiVisible;
      tasks.add(
        service
            .pingGroup(
              code: session.code,
              lat: rawSelf?.lat ?? pos.lat,
              lon: rawSelf?.lon ?? pos.lon,
              ele: _lastKnownAltitudeM,
              accuracy: acc,
              heading: _lastRawHeading ?? _smoothedHeading,
              speed: _lastRawSpeed,
              alongTrackM: _lastMatchedAlongTrackM,
              inNavigation: true,
              stationary: ctx.isStationary,
              ackOnly: sseLive,
            )
            .then((updated) {
              anySucceeded = true;
              if (!mounted) return;
              final cur = _groupSession.value;
              if (cur == null || cur.code != updated.code) return;
              if (!updated.hasMembersSnapshot) return; // ?ack=1 fast 200 OK
              final nextSelfId = updated.selfMemberId.isNotEmpty
                  ? updated.selfMemberId
                  : cur.selfMemberId;
              _groupSession.value = cur.copyWith(
                selfMemberId: nextSelfId,
                expiresAt: updated.expiresAt ?? cur.expiresAt,
                members: _mergeGroupMembersWithBle(
                  serverMembers: updated.members,
                  selfMemberId: nextSelfId,
                ),
              );
            })
            .catchError((Object _) {}),
      );
    }

    if (ctx.includeHeartbeat && pos != null) {
      tasks.add(
        service
            .sendHeartbeat(
              trailId: widget.isRecording || widget.id.isEmpty
                  ? null
                  : widget.id,
              lat: pos.lat,
              lon: pos.lon,
              ele: _lastKnownAltitudeM,
              inNavigation: true,
              stationary: ctx.isStationary,
              stateHash: _lastHeartbeatStateHash,
              isRo: _isRo,
            )
            .then((summary) {
              anySucceeded = true;
              if (!mounted || summary == null) return;
              if (summary.stateHash != null && summary.stateHash!.isNotEmpty) {
                _lastHeartbeatStateHash = summary.stateHash;
              }
              if (summary.unchanged) {
                _activeHikers30m.value = summary.activeHikers30m;
              } else {
                _applyLiveSummary(summary);
              }
            })
            .catchError((Object _) {}),
      );
    }

    await Future.wait(tasks);
    return anySucceeded;
  }

  void _connectLiveSse(ml.Geographic pos) {
    final service = _liveService;
    if (service == null || !service.isConfigured || !_uiVisible) return;
    if (!ref.read(onlineStatusProvider)) return;
    _disconnectLiveSse();
    unawaited(_flushSosOutboxAndRelayQueue());
    final cancelToken = CancelToken();
    _liveSseCancelToken = cancelToken;
    _liveSseSub = service
        .connectStream(
          lat: pos.lat,
          lon: pos.lon,
          trailId: widget.isRecording || widget.id.isEmpty ? null : widget.id,
          groupCode: _groupSession.value?.code,
          lastEventId: _lastLiveSseEventId,
          cancelToken: cancelToken,
          isRo: _isRo,
        )
        .listen(
          _handleLiveSseEvent,
          onError: (Object _) => _scheduleLiveSseReconnect(),
          onDone: _scheduleLiveSseReconnect,
        );
  }

  void _disconnectLiveSse() {
    _liveSseReconnectTimer?.cancel();
    _liveSseReconnectTimer = null;
    final token = _liveSseCancelToken;
    _liveSseCancelToken = null;
    if (token != null && !token.isCancelled) {
      token.cancel('disconnect');
    }
    _liveSseSub?.cancel();
    _liveSseSub = null;
  }

  void _scheduleLiveSseReconnect() {
    if (!mounted || !_uiVisible) return;
    if (!ref.read(onlineStatusProvider)) return;
    if (_liveSseReconnectTimer?.isActive ?? false) return;
    final delay = _radioScheduler.nextSseReconnectDelay(++_sseFailureCount);
    _liveSseReconnectTimer = Timer(delay, () {
      if (!mounted || !_uiVisible) return;
      final pos = _currentGeoFix();
      if (pos != null) {
        _connectLiveSse(pos);
      }
    });
  }

  void _applyLiveSummary(TrailLiveSummary summary) {
    final now = DateTime.now();
    _activeHikers30m.value = summary.activeHikers30m;
    _liveReports.value = summary.visibleReports(now: now);

    final currentMine = _myActiveSos.value;
    final serverMine = summary.myActiveSos(now: now);
    if (serverMine != null) {
      _myActiveSos.value = currentMine != null
          ? _mergeIntoMyActiveSos(currentMine, serverMine)
          : serverMine;
      _syncBleRadioMode();
    } else if (currentMine != null) {
      // Check if a nearby hiker relayed our offline SOS (`device_hash == ""` -> `!isMine` until claimed).
      final myCid = currentMine.clientSosId;
      final relayedMatch = (myCid != null && myCid.isNotEmpty)
          ? summary.sosAlerts.firstWhereOrNull((s) => s.clientSosId == myCid)
          : null;
      if (relayedMatch != null) {
        if (relayedMatch.isActiveAt(now)) {
          _myActiveSos.value = _mergeIntoMyActiveSos(currentMine, relayedMatch);
          unawaited(_flushSosOutboxAndRelayQueue());
        } else {
          _myActiveSos.value = null;
          _syncBleRadioMode();
        }
      } else if (!currentMine.id.startsWith('local-') &&
          !currentMine.isActiveAt(now)) {
        _myActiveSos.value = null;
        _syncBleRadioMode();
      }
    }

    final myCid = _myActiveSos.value?.clientSosId;
    final existingByKey = <String, SosAlertModel>{
      for (final s in _nearbySosAlerts.value) s.dedupeKey: s,
    };
    final mergedNearby = <SosAlertModel>[];
    final seenKeys = <String>{};

    for (final s in summary.nearbyActiveSos(now: now)) {
      if (myCid != null && myCid.isNotEmpty && s.clientSosId == myCid) {
        continue;
      }
      final prev = existingByKey[s.dedupeKey];
      final combined = prev != null ? _mergeNearbySos(prev, s) : s;
      if (seenKeys.add(combined.dedupeKey)) {
        mergedNearby.add(combined);
      }
    }

    // Retain BLE-discovered alerts that have not yet reached the server.
    for (final prev in _nearbySosAlerts.value) {
      if (prev.viaBluetooth &&
          prev.isActiveAt(now) &&
          seenKeys.add(prev.dedupeKey)) {
        mergedNearby.add(prev);
      }
    }
    _nearbySosAlerts.value = mergedNearby;

    final fix = _currentGeoFix();
    if (fix != null) {
      _refreshNearbyWazePrompt(fix);
      final responding = _activeRespondingSos();
      if (responding != null) {
        _recomputeRescueRoute(fix, responding, syncWithServer: false);
      } else if (_rescueRouteNotifier.value != null) {
        _rescueRouteNotifier.value = null;
        _pushRescueSource(null);
      }
    }
  }

  void _handleLiveSseEvent(TrailLiveSseEvent event) {
    if (!mounted) return;
    if (event.eventId != null && event.eventId!.isNotEmpty) {
      _lastLiveSseEventId = event.eventId;
      _sseFailureCount = 0;
    }
    if (event.type == TrailLiveSseEvent.resyncRequired) {
      _lastHeartbeatStateHash = null;
      unawaited(
        _radioScheduler.triggerImmediateBurst(
          reason: 'sse_resync',
          forceHeartbeat: true,
        ),
      );
      final session = _groupSession.value;
      final service = _liveService;
      if (session != null &&
          !session.isOfflineBleGroup &&
          service != null &&
          service.isConfigured) {
        unawaited(
          service.getGroup(session.code).then((fresh) {
            if (!mounted) return;
            final cur = _groupSession.value;
            if (cur == null || cur.code != fresh.code) return;
            _groupSession.value = cur.copyWith(
              members: _mergeGroupMembersWithBle(
                serverMembers: fresh.members,
                selfMemberId: cur.selfMemberId,
              ),
            );
          }).catchError((Object _) {}),
        );
      }
      return;
    }
    final now = DateTime.now();
    final incomingReport = event.report;
    if (incomingReport != null) {
      final next = List<TrailReportModel>.of(_liveReports.value);
      final idx = next.indexWhere((r) => r.id == incomingReport.id);
      if (!incomingReport.isVisibleAt(now)) {
        if (idx >= 0) next.removeAt(idx);
      } else if (idx >= 0) {
        next[idx] = incomingReport;
      } else {
        next.insert(0, incomingReport);
      }
      _liveReports.value = next;
      final fix = _currentGeoFix();
      if (fix != null) _refreshNearbyWazePrompt(fix);
    }

    final incomingSos = event.sos;
    if (incomingSos != null) {
      final currentMine = _myActiveSos.value;
      final isSameAsMine =
          currentMine != null &&
          (currentMine.id == incomingSos.id ||
              (currentMine.clientSosId != null &&
                  currentMine.clientSosId == incomingSos.clientSosId));
      if (incomingSos.isMine || isSameAsMine) {
        if (incomingSos.isActiveAt(now)) {
          _myActiveSos.value = currentMine != null
              ? _mergeIntoMyActiveSos(currentMine, incomingSos)
              : incomingSos.copyWith(isMine: true);
        } else {
          _myActiveSos.value = null;
        }
        _syncBleRadioMode();
        return;
      }

      final next = List<SosAlertModel>.of(_nearbySosAlerts.value);
      final idx = next.indexWhere(
        (s) => s.id == incomingSos.id || s.dedupeKey == incomingSos.dedupeKey,
      );
      if (!incomingSos.isActiveAt(now)) {
        if (idx >= 0) next.removeAt(idx);
      } else if (idx >= 0) {
        next[idx] = _mergeNearbySos(next[idx], incomingSos);
      } else {
        next.insert(0, incomingSos);
      }
      _nearbySosAlerts.value = next;

      final incomingCid = incomingSos.clientSosId;
      if (incomingCid != null && incomingCid.isNotEmpty) {
        unawaited(
          _sosOutboxStore.attachServerSosIdToResponderAction(
            incomingCid,
            incomingSos.id,
          ),
        );
      }

      final fix = _currentGeoFix();
      final responding = _activeRespondingSos();
      if (fix != null && responding != null) {
        _recomputeRescueRoute(fix, responding, syncWithServer: false);
      } else if (responding == null && _rescueRouteNotifier.value != null) {
        _rescueRouteNotifier.value = null;
        _pushRescueSource(null);
      }
    }

    final sseMember = event.groupMember;
    if (event.type == TrailLiveSseEvent.groupMemberUpdate &&
        sseMember != null) {
      final session = _groupSession.value;
      if (session != null &&
          (event.groupCode == null || event.groupCode == session.code)) {
        final incoming = sseMember.copyWith(
          isSelf: sseMember.memberId == session.selfMemberId,
          updatedAt: sseMember.updatedAt ?? now.toUtc(),
        );
        final nextMembers = _mergeGroupMembersWithBle(
          serverMembers: <GroupMemberModel>[
            for (final m in session.members)
              if (m.memberId == incoming.memberId) incoming else m,
            if (!session.members.any((m) => m.memberId == incoming.memberId))
              incoming,
          ],
          selfMemberId: session.selfMemberId,
        );
        _groupSession.value = session.copyWith(members: nextMembers);
        if (_selectedGroupMember.value?.memberId == incoming.memberId) {
          _selectedGroupMember.value = incoming;
        }
      }
    } else if (event.type == TrailLiveSseEvent.groupMemberLeft &&
        event.leftMemberId != null) {
      final leftId = event.leftMemberId!;
      final session = _groupSession.value;
      if (session != null &&
          (event.groupCode == null || event.groupCode == session.code)) {
        _bleGroupPeers.remove(leftId);
        final nextMembers = session.members
            .where((m) => m.memberId != leftId)
            .toList(growable: false);
        _groupSession.value = session.copyWith(members: nextMembers);
        if (_selectedGroupMember.value?.memberId == leftId) {
          _selectedGroupMember.value = null;
        }
      }
    }
  }

  List<GroupMemberModel> _mergeGroupMembersWithBle({
    required List<GroupMemberModel> serverMembers,
    required String selfMemberId,
  }) {
    final nowUtc = DateTime.now().toUtc();
    _bleGroupPeers.removeWhere((_, peer) {
      final ts = peer.updatedAt;
      return ts != null && nowUtc.difference(ts).inSeconds > 120;
    });

    final byId = <String, GroupMemberModel>{};
    for (final m in serverMembers) {
      byId[m.memberId] = m.memberId == selfMemberId ? m.copyWith(isSelf: true) : m;
    }

    for (final blePeer in _bleGroupPeers.values) {
      if (blePeer.memberId == selfMemberId) continue;
      final existing = byId[blePeer.memberId];
      if (existing == null) {
        byId[blePeer.memberId] = blePeer;
      } else {
        final existingTs = existing.updatedAt;
        final bleTs = blePeer.updatedAt;
        final preferBleCoords =
            bleTs != null && (existingTs == null || bleTs.isAfter(existingTs));
        byId[blePeer.memberId] = preferBleCoords
            ? blePeer.copyWith(
                alongTrackM: blePeer.alongTrackM ?? existing.alongTrackM,
              )
            : existing.copyWith(
                viaBluetooth: true,
                bleHopCount: blePeer.bleHopCount,
              );
      }
    }

    return byId.values.toList(growable: false);
  }

  void _configureBleForActiveGroup(GroupSessionModel? session) {
    if (session == null) {
      _bleGroupPeers.clear();
      _bleMeshEngine.configureGroupSession(groupCode: null);
      _syncBleRadioMode();
      return;
    }
    _bleMeshEngine.configureGroupSession(
      groupCode: session.code,
      selfMemberIdHex: session.selfMemberId,
    );
    unawaited(
      _ensureBlePermissions().then((_) {
        if (!mounted) return;
        _syncBleRadioMode();
        final fix = _currentGeoFix();
        if (fix != null && _groupSession.value?.code == session.code) {
          final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
          final pkt = BleGroupPosPacket(
            memberIdHex: session.selfMemberId,
            lat: fix.lat,
            lon: fix.lon,
            eleM: (_lastKnownAltitudeM ?? 0.0).round(),
            accuracyM: (_lastRawSelfFix?.accuracy ?? 15.0).round().clamp(1, 255),
            inNavigation: true,
            headingDeg: _lastRawHeading ?? _smoothedHeading,
            speedMps: _lastRawSpeed,
            displayName: _selfGroupDisplayName,
            timestampSec: nowSec,
          );
          unawaited(_bleMeshEngine.publishLocalGroupPosition(pkt));
        }
      }),
    );
  }

  void _syncGroupPingTimer() {
    final session = _groupSession.value;
    _configureBleForActiveGroup(session);
    if (session == null) {
      _selectedGroupMember.value = null;
      _lastCoLocatedPeerIds = <String>{};
    }
    _radioScheduler.updateState(hasActiveGroup: session != null);
    if (session != null && !session.isOfflineBleGroup) {
      unawaited(
        _radioScheduler.triggerImmediateBurst(reason: 'group_session_changed'),
      );
    }
    final pos = _currentGeoFix();
    if (pos != null && _uiVisible) {
      _connectLiveSse(pos);
    }
  }

  Future<GroupSessionModel> _buildOfflineBleGroupSession({
    required String code,
    required String displayName,
  }) async {
    final token = await _resolveDeviceToken();
    final normCode = code.trim().toUpperCase();
    final selfId = deriveOfflineGroupMemberId(
      groupCode: normCode,
      deviceToken: token,
    );
    final fix = _currentGeoFix();
    final selfMember = GroupMemberModel(
      memberId: selfId,
      displayName: displayName,
      colorHex: deriveBleMemberColor(selfId),
      lat: fix?.lat ?? 0.0,
      lon: fix?.lon ?? 0.0,
      ele: _lastKnownAltitudeM ?? 0.0,
      accuracy: _lastRawSelfFix?.accuracy ?? 15.0,
      alongTrackM: _lastMatchedAlongTrackM,
      inNavigation: true,
      isSelf: true,
      viaBluetooth: true,
      updatedAt: DateTime.now().toUtc(),
    );
    return GroupSessionModel(
      code: normCode,
      trailId: widget.isRecording || widget.id.isEmpty ? null : widget.id,
      selfMemberId: selfId,
      isOfflineBleGroup: true,
      members: <GroupMemberModel>[selfMember],
    );
  }

  Future<GroupSessionModel?> _handleCreateGroup(String displayName) async {
    _selfGroupDisplayName = displayName.trim().isNotEmpty
        ? displayName.trim()
        : (_isRo ? 'Drumeț' : 'Hiker');
    final service = _liveService;
    GroupSessionModel session;
    if (service != null &&
        service.isConfigured &&
        ref.read(onlineStatusProvider)) {
      try {
        session = await service.createGroup(
          trailId: widget.isRecording || widget.id.isEmpty ? null : widget.id,
          displayName: _selfGroupDisplayName,
        );
      } catch (_) {
        session = await _buildOfflineBleGroupSession(
          code: generateOfflineGroupCode(),
          displayName: _selfGroupDisplayName,
        );
      }
    } else {
      session = await _buildOfflineBleGroupSession(
        code: generateOfflineGroupCode(),
        displayName: _selfGroupDisplayName,
      );
    }
    if (!mounted) return session;
    _bleGroupPeers.clear();
    _groupSession.value = session;
    _syncGroupPingTimer();
    return session;
  }

  Future<GroupSessionModel?> _handleJoinGroup(
    String code,
    String displayName,
  ) async {
    _selfGroupDisplayName = displayName.trim().isNotEmpty
        ? displayName.trim()
        : (_isRo ? 'Drumeț' : 'Hiker');
    final normCode = code.trim().toUpperCase();
    final service = _liveService;
    GroupSessionModel session;
    if (service != null &&
        service.isConfigured &&
        ref.read(onlineStatusProvider)) {
      try {
        session = await service.joinGroup(
          code: normCode,
          displayName: _selfGroupDisplayName,
        );
      } catch (_) {
        // Offline or joining a group created offline on the mountain over BLE.
        session = await _buildOfflineBleGroupSession(
          code: normCode,
          displayName: _selfGroupDisplayName,
        );
      }
    } else {
      session = await _buildOfflineBleGroupSession(
        code: normCode,
        displayName: _selfGroupDisplayName,
      );
    }
    if (!mounted) return session;
    _bleGroupPeers.clear();
    _groupSession.value = session;
    _syncGroupPingTimer();
    return session;
  }

  Future<void> _handleLeaveGroup() async {
    final session = _groupSession.value;
    if (session != null && _bleMeshEngine.isSupportedPlatform) {
      final fix = _currentGeoFix();
      if (fix != null) {
        final leavePkt = BleGroupPosPacket(
          memberIdHex: session.selfMemberId,
          lat: fix.lat,
          lon: fix.lon,
          memberLeft: true,
          displayName: _selfGroupDisplayName,
          timestampSec: DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
        );
        await _bleMeshEngine.publishLocalGroupPosition(leavePkt);
      }
    }
    _groupSession.value = null;
    _syncGroupPingTimer();
    final service = _liveService;
    if (session == null ||
        session.isOfflineBleGroup ||
        service == null ||
        !service.isConfigured) {
      return;
    }
    try {
      await service.leaveGroup(session.code);
    } catch (_) {}
  }

  void _onGroupMemberTapped(GroupMemberModel member) {
    _selectedGroupMember.value =
        _selectedGroupMember.value?.memberId == member.memberId ? null : member;
    _controller?.animateCamera(
      center: ml.Geographic(lat: member.lat, lon: member.lon),
      nativeDuration: const Duration(milliseconds: 300),
    );
  }

  Future<void> _openLiveGroupSheet(BuildContext context) async {
    unawaited(_bleMeshEngine.getState());
    final currentUser = ref.read(authProvider).value;
    final prefName = currentUser?.preferredUsername.trim() ?? '';
    final initialName = prefName.isNotEmpty
        ? prefName
        : (currentUser?.username.trim() ?? '');
    final rawServer = currentUser?.serverUrl.trim() ?? '';
    final cleanServer = rawServer.endsWith('/')
        ? rawServer.substring(0, rawServer.length - 1)
        : rawServer;
    final shareUrlBase =
        (cleanServer.isNotEmpty && !widget.isRecording && widget.id.isNotEmpty)
        ? '$cleanServer/trail/${widget.id}'
        : null;

    if (!context.mounted) return;
    await showLiveGroupSheet(
      context,
      sessionListenable: _groupSession,
      busyListenable: _liveActionBusy,
      bleAdapterOnListenable: _bleMeshEngine.isSupportedPlatform
          ? _bleMeshEngine.adapterOnListenable
          : null,
      isOnline: ref.read(onlineStatusProvider),
      initialDisplayName: initialName,
      userAlongTrackM: _lastMatchedAlongTrackM,
      userPosition: _currentGeoFix(),
      shareUrlBase: shareUrlBase,
      onCreateGroup: _handleCreateGroup,
      onJoinGroup: _handleJoinGroup,
      onLeaveGroup: _handleLeaveGroup,
      onFocusMember: (member) {
        _selectedGroupMember.value = member;
        _onPanStart();
        _controller?.animateCamera(
          center: ml.Geographic(lat: member.lat, lon: member.lon),
          nativeDuration: const Duration(milliseconds: 300),
        );
      },
      isRo: _isRo,
    );
  }

  void _refreshNearbyWazePrompt(ml.Geographic fix) {
    final reports = _liveReports.value;
    if (reports.isEmpty) {
      if (_nearbyPromptReport.value != null) {
        _nearbyPromptReport.value = null;
        _pinnedPromptReportId = null;
      }
      return;
    }

    if (_pinnedPromptReportId != null) {
      final pinned = reports.firstWhereOrNull(
        (r) => r.id == _pinnedPromptReportId,
      );
      if (pinned != null) {
        final d = ml.SphericalGreatCircle(
          fix,
        ).distanceTo(ml.Geographic(lat: pinned.lat, lon: pinned.lon));
        _nearbyPromptReport.value = (report: pinned, distanceM: d);
        return;
      }
      _pinnedPromptReportId = null;
    }

    TrailReportModel? closest;
    double closestDist = double.infinity;
    for (final r in reports) {
      if (_snoozedOrVotedReportIds.contains(r.id)) continue;
      final d = ml.SphericalGreatCircle(
        fix,
      ).distanceTo(ml.Geographic(lat: r.lat, lon: r.lon));
      if (d <= 150.0 && d < closestDist) {
        closest = r;
        closestDist = d;
      }
    }

    if (closest == null) {
      if (_nearbyPromptReport.value != null) {
        _nearbyPromptReport.value = null;
      }
    } else {
      final prev = _nearbyPromptReport.value;
      if (prev == null ||
          prev.report.id != closest.id ||
          ((prev.distanceM ?? 0) - closestDist).abs() >= 5.0) {
        _nearbyPromptReport.value = (report: closest, distanceM: closestDist);
      }
    }
  }

  void _onReportMarkerTapped(TrailReportModel report) {
    _pinnedPromptReportId = report.id;
    final fix = _currentGeoFix();
    final d = fix == null
        ? null
        : ml.SphericalGreatCircle(
            fix,
          ).distanceTo(ml.Geographic(lat: report.lat, lon: report.lon));
    _nearbyPromptReport.value = (report: report, distanceM: d);
  }

  void _onSosMarkerTapped(SosAlertModel sos) {
    _controller?.animateCamera(
      center: ml.Geographic(lat: sos.lat, lon: sos.lon),
      nativeDuration: const Duration(milliseconds: 300),
    );
  }

  Future<void> _openWazeReportSheet(BuildContext context) async {
    final pos = _currentGeoFix();
    if (pos == null) return;
    final submission = await showWazeReportSheet(
      context,
      isRo: _isRo,
      userLat: pos.lat,
      userLon: pos.lon,
    );
    if (submission == null || !mounted) return;

    final service = _liveService;
    if (service == null || !service.isConfigured) return;

    _liveActionBusy.value = true;
    try {
      final created = await service.createReport(
        trailId: widget.isRecording || widget.id.isEmpty ? null : widget.id,
        category: submission.category,
        note: submission.note,
        lat: pos.lat,
        lon: pos.lon,
        ele: _lastKnownAltitudeM,
        alongTrackM: _lastMatchedAlongTrackM,
        photoJpegBytes: submission.photoJpegBytes,
        photoVerified: submission.photoVerified,
      );
      if (!mounted) return;
      _snoozedOrVotedReportIds.add(created.id);
      final next = <TrailReportModel>[
        created,
        for (final r in _liveReports.value)
          if (r.id != created.id) r,
      ];
      _liveReports.value = next;
    } catch (e) {
      debugPrint('NavigationScreen: createReport failed — $e');
    } finally {
      if (mounted) _liveActionBusy.value = false;
    }
  }

  Future<void> _handleVoteReport(
    TrailReportModel report,
    TrailReportVoteType vote,
  ) async {
    _snoozedOrVotedReportIds.add(report.id);
    if (_pinnedPromptReportId == report.id) {
      _pinnedPromptReportId = null;
    }

    // Optimistic local update (extends expiresAt immediately on confirm!).
    final optimistic = report.applyLocalVote(vote);
    final now = DateTime.now();
    final optimisticList = <TrailReportModel>[];
    for (final r in _liveReports.value) {
      if (r.id == report.id) {
        if (optimistic.isVisibleAt(now)) {
          optimisticList.add(optimistic);
        }
      } else {
        optimisticList.add(r);
      }
    }
    _liveReports.value = optimisticList;
    _nearbyPromptReport.value = null;

    final service = _liveService;
    if (service == null || !service.isConfigured) return;
    _liveActionBusy.value = true;
    try {
      final updated = await service.voteReport(
        reportId: report.id,
        vote: vote,
      );
      if (!mounted) return;
      final syncNow = DateTime.now();
      final synced = <TrailReportModel>[];
      for (final r in _liveReports.value) {
        if (r.id == updated.id) {
          if (updated.isVisibleAt(syncNow)) {
            synced.add(updated);
          }
        } else {
          synced.add(r);
        }
      }
      _liveReports.value = synced;
    } catch (e) {
      debugPrint('NavigationScreen: voteReport failed — $e');
    } finally {
      if (mounted) _liveActionBusy.value = false;
    }
  }

  Future<void> _onSosButtonPressed(BuildContext context) async {
    final pos = _currentGeoFix();
    if (pos == null) return;
    final currentUser = ref.read(authProvider).value;
    final prefName = currentUser?.preferredUsername.trim() ?? '';
    final initialName = prefName.isNotEmpty
        ? prefName
        : (currentUser?.username.trim() ?? '');
    final isOnline = ref.read(onlineStatusProvider);
    final salvamontDs = ref.read(salvamontDatasetProvider).value;
    final salvamontRes = salvamontDs == null
        ? null
        : resolveNearestSalvamont(
            salvamontDs,
            pos.lat,
            pos.lon,
            userEle: _lastKnownAltitudeM,
            localeCode: _localeCode,
          );
    final submission = await showSosTriggerDialog(
      context,
      initialName: initialName,
      isOnline: isOnline,
      isRo: _isRo,
      salvamontResolution: salvamontRes,
      onRouteToSalvamont: _handleRouteToSalvamontBase,
      userLat: pos.lat,
      userLon: pos.lon,
      userEle: _lastKnownAltitudeM,
      userAccuracy: _effectiveGpsAccuracy.value,
      demGrid: _demGrid,
      trailPoints: _navTrackPoints.map((p) => p.geographic).toList(growable: false),
    );
    if (submission == null || !mounted) return;

    // 1. Offline-first: mint Lamport credentials and start BLE emergency broadcast BEFORE network await!
    final deviceToken = await _resolveDeviceToken();
    if (!mounted) return;
    final creds = SosOriginCredentials.mint(deviceToken);
    final nowUtc = DateTime.now().toUtc();
    final nowEpochSec = nowUtc.millisecondsSinceEpoch ~/ 1000;
    final trailId = widget.isRecording || widget.id.isEmpty ? null : widget.id;
    final ele = _lastKnownAltitudeM ?? 0.0;

    _bleAckResponderIds.clear();
    final localSos = SosAlertModel(
      id: 'local-${creds.clientSosId}',
      clientSosId: creds.clientSosId,
      trailId: trailId,
      status: 'active',
      reason: submission.reason,
      message: submission.message,
      requesterName: submission.requesterName,
      lat: pos.lat,
      lon: pos.lon,
      ele: ele,
      isMine: true,
      viaBluetooth: true,
      localClaimSecret: creds.sosClaimSecret,
      createdAt: nowUtc,
    );
    _myActiveSos.value = localSos;
    _lastSosBroadcastPos = pos;
    _lastSosBroadcastAt = DateTime.now();

    await _sosOutboxStore.setMyPendingSos(
      PendingMySosEntry(
        clientSosId: creds.clientSosId,
        sosClaimSecret: creds.sosClaimSecret,
        sosClaimHash: creds.sosClaimHash,
        trailId: trailId,
        status: 'active',
        reason: submission.reason,
        message: submission.message,
        requesterName: submission.requesterName,
        lat: pos.lat,
        lon: pos.lon,
        ele: ele,
        createdEpochSec: nowEpochSec,
      ),
    );

    final bleAlert = BleSosAlertPacket(
      clientSosId: creds.clientSosId,
      sosClaimHash: creds.sosClaimHash,
      reason: submission.reason,
      isStationary: _frozen,
      lat: pos.lat,
      lon: pos.lon,
      eleM: ele.round(),
      createdEpochSec: nowEpochSec,
      shortMsg: BleSosAlertPacket.composeShortMsg(
        requesterName: submission.requesterName,
        message: submission.message,
      ),
    );
    unawaited(
      _ensureBlePermissions().then((_) {
        if (!mounted) return;
        unawaited(
          _bleMeshEngine.publishLocalSosAlert(
            bleAlert,
            activateEmergencyMode: true,
          ),
        );
      }),
    );

    // 2. Attempt online server broadcast / ownership registration in parallel.
    final service = _liveService;
    if (service == null || !service.isConfigured) {
      _showCalmOfflineSosConfirmation();
      return;
    }

    _liveActionBusy.value = true;
    try {
      final serverSos = await service.triggerSos(
        trailId: trailId,
        reason: submission.reason,
        message: submission.message,
        requesterName: submission.requesterName,
        lat: pos.lat,
        lon: pos.lon,
        ele: ele,
        clientSosId: creds.clientSosId,
        sosClaimSecret: creds.sosClaimSecret,
      );
      if (!mounted) return;
      await _sosOutboxStore.markMySosSyncedOnline(serverSosId: serverSos.id);
      final cur = _myActiveSos.value;
      if (cur != null && cur.clientSosId == creds.clientSosId) {
        _myActiveSos.value = _mergeIntoMyActiveSos(cur, serverSos);
      }
      // Keep BleRadioMode.sosEmergencyActive active so nearby offline hikers still receive SOS!
    } catch (e) {
      debugPrint('NavigationScreen: triggerSos offline fallback active — $e');
      if (mounted) {
        _showCalmOfflineSosConfirmation();
      }
    } finally {
      if (mounted) _liveActionBusy.value = false;
    }
  }

  void _showCalmOfflineSosConfirmation() {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        backgroundColor: AppColors.primaryLight,
        behavior: SnackBarBehavior.floating,
        content: Text(
          _isRo
              ? 'SOS fără semnal activat · alerta se transmite prin Bluetooth către drumeții din apropiere.'
              : 'Offline SOS active · broadcasting via Bluetooth to nearby hikers.',
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }

  Future<void> _handleResolveMySos(SosAlertModel sos) async {
    final nowEpochSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final pendingMine = _sosOutboxStore.myPendingSos;
    final cid = sos.clientSosId ?? pendingMine?.clientSosId;
    final secret = sos.localClaimSecret ?? pendingMine?.sosClaimSecret;

    // 1. Clear UI immediately (works 100% offline!).
    _myActiveSos.value = null;
    _bleAckResponderIds.clear();

    final fallbackMode = _groupSession.value != null
        ? BleRadioMode.groupMeshNormal
        : BleRadioMode.passiveTrailGuard;

    if (cid != null && secret != null && cid.isNotEmpty && secret.isNotEmpty) {
      try {
        final resolvedPkt = BleSosResolvedPacket.fromHexSecret(
          clientSosId: cid,
          resolvedEpochSec: nowEpochSec,
          sosClaimSecretHex: secret,
        );
        unawaited(
          _bleMeshEngine.publishLocalSosResolved(
            resolvedPkt,
            fallbackModeAfterBroadcast: fallbackMode,
          ),
        );
      } catch (e) {
        debugPrint('NavigationScreen: failed to encode BLE SOS_RESOLVED — $e');
      }
    }
    if (_bleMeshEngine.isSupportedPlatform) {
      unawaited(_bleMeshEngine.setRadioMode(fallbackMode));
    }

    await _sosOutboxStore.markMySosPendingResolve(
      status: 'resolved',
      resolvedEpochSec: nowEpochSec,
    );

    final service = _liveService;
    if (service == null || !service.isConfigured) {
      return;
    }

    _liveActionBusy.value = true;
    try {
      if (!sos.id.startsWith('local-')) {
        await service.updateSosStatus(
          sosId: sos.id,
          status: 'resolved',
          sosClaimSecret: secret,
        );
        await _sosOutboxStore.clearMyPendingSos();
      } else {
        await _flushSosOutboxAndRelayQueue();
      }
    } catch (e) {
      debugPrint('NavigationScreen: resolve SOS queued for 4G sync — $e');
    } finally {
      if (mounted) _liveActionBusy.value = false;
    }
  }

  Future<void> _handleRespondComing(SosAlertModel sos) async {
    final pos = _currentGeoFix();
    if (pos == null) return;
    final route = _recomputeRescueRoute(pos, sos, syncWithServer: false);

    final updatedLocal = sos.copyWith(
      amResponding: true,
      responderCount: sos.amResponding
          ? sos.responderCount
          : sos.responderCount + 1,
    );
    _nearbySosAlerts.value = <SosAlertModel>[
      for (final s in _nearbySosAlerts.value)
        if (s.dedupeKey == sos.dedupeKey)
          updatedLocal
        else
          s.copyWith(amResponding: false),
    ];

    final cid = sos.clientSosId;
    final nowEpochSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    if (cid != null && cid.isNotEmpty) {
      final token = await _resolveDeviceToken();
      if (!mounted) return;
      final respIdHex = deriveBleResponderIdHex(
        clientSosId: cid,
        responderDeviceToken: token,
      );
      final etaMin = route != null
          ? max(1, (route.estimatedSeconds / 60.0).round())
          : null;
      final distM = route?.distanceM.round();
      final ackPkt = BleSosAckPacket(
        clientSosId: cid,
        responderIdHex: respIdHex,
        etaMin: etaMin,
        distM: distM,
        comingToHelp: true,
        ackEpochSec: nowEpochSec,
      );
      _lastBleResponderAckAt = DateTime.now();
      unawaited(
        _ensureBlePermissions().then((_) {
          if (!mounted) return;
          unawaited(_bleMeshEngine.publishLocalSosAck(ackPkt));
        }),
      );
      await _sosOutboxStore.setPendingResponderAction(
        PendingResponderAction(
          clientSosId: cid,
          serverSosId: sos.id.startsWith('ble-') ? null : sos.id,
          status: 'coming',
          lat: pos.lat,
          lon: pos.lon,
          ele: _lastKnownAltitudeM ?? 0.0,
          distanceM: route?.distanceM,
          etaSec: route?.estimatedSeconds,
          createdEpochSec: nowEpochSec,
        ),
      );
    }

    final service = _liveService;
    if (service == null ||
        !service.isConfigured ||
        sos.id.startsWith('ble-') ||
        sos.id.startsWith('local-')) {
      return;
    }

    _liveActionBusy.value = true;
    try {
      final synced = await service.respondToSos(
        sosId: sos.id,
        status: 'coming',
        lat: pos.lat,
        lon: pos.lon,
        ele: _lastKnownAltitudeM,
        distanceM: route?.distanceM,
        etaSec: route?.estimatedSeconds,
      );
      await _sosOutboxStore.clearPendingResponderAction();
      if (!mounted) return;
      _lastResponderSyncAt = DateTime.now();
      _nearbySosAlerts.value = <SosAlertModel>[
        for (final s in _nearbySosAlerts.value)
          if (s.dedupeKey == synced.dedupeKey || s.id == synced.id)
            _mergeNearbySos(s, synced).copyWith(amResponding: true)
          else
            s,
      ];
    } catch (e) {
      debugPrint('NavigationScreen: respondToSos queued offline — $e');
    } finally {
      if (mounted) _liveActionBusy.value = false;
    }
  }

  Future<void> _handleCancelRespond(SosAlertModel sos) async {
    _rescueRouteNotifier.value = null;
    _pushRescueSource(null);
    _nearbySosAlerts.value = <SosAlertModel>[
      for (final s in _nearbySosAlerts.value)
        if (s.dedupeKey == sos.dedupeKey)
          s.copyWith(amResponding: false)
        else
          s,
    ];

    final pos = _currentGeoFix();
    final cid = sos.clientSosId;
    final nowEpochSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    if (cid != null && cid.isNotEmpty) {
      final token = await _resolveDeviceToken();
      if (!mounted) return;
      final respIdHex = deriveBleResponderIdHex(
        clientSosId: cid,
        responderDeviceToken: token,
      );
      final cancelAck = BleSosAckPacket(
        clientSosId: cid,
        responderIdHex: respIdHex,
        cancelled: true,
        ackEpochSec: nowEpochSec,
      );
      unawaited(_bleMeshEngine.publishLocalSosAck(cancelAck));
      if (pos != null) {
        await _sosOutboxStore.setPendingResponderAction(
          PendingResponderAction(
            clientSosId: cid,
            serverSosId: sos.id.startsWith('ble-') ? null : sos.id,
            status: 'cancelled',
            lat: pos.lat,
            lon: pos.lon,
            ele: _lastKnownAltitudeM ?? 0.0,
            createdEpochSec: nowEpochSec,
          ),
        );
      } else {
        await _sosOutboxStore.clearPendingResponderAction();
      }
    }

    final service = _liveService;
    if (pos == null ||
        service == null ||
        !service.isConfigured ||
        sos.id.startsWith('ble-') ||
        sos.id.startsWith('local-')) {
      return;
    }
    _liveActionBusy.value = true;
    try {
      final synced = await service.respondToSos(
        sosId: sos.id,
        status: 'cancelled',
        lat: pos.lat,
        lon: pos.lon,
        ele: _lastKnownAltitudeM,
      );
      await _sosOutboxStore.clearPendingResponderAction();
      if (!mounted) return;
      _nearbySosAlerts.value = <SosAlertModel>[
        for (final s in _nearbySosAlerts.value)
          if (s.dedupeKey == synced.dedupeKey || s.id == synced.id)
            _mergeNearbySos(s, synced).copyWith(amResponding: false)
          else
            s,
      ];
    } catch (e) {
      debugPrint('NavigationScreen: cancel respondToSos queued offline — $e');
    } finally {
      if (mounted) _liveActionBusy.value = false;
    }
  }

  void _onBleGroupPosReceived(BleGroupPosPacket pkt) {
    if (!mounted) return;
    final session = _groupSession.value;
    if (session == null) return;
    if (pkt.memberIdHex == session.selfMemberId) return;

    if (pkt.memberLeft) {
      _bleGroupPeers.remove(pkt.memberIdHex);
      final remaining = session.members
          .where((m) => m.memberId != pkt.memberIdHex)
          .toList(growable: false);
      _groupSession.value = session.copyWith(members: remaining);
      if (_selectedGroupMember.value?.memberId == pkt.memberIdHex) {
        _selectedGroupMember.value = null;
      }
      return;
    }

    final matcher = _trackMatcher;
    final matchedAlong = matcher
        ?.matchDetailed(
          ml.Geographic(lat: pkt.lat, lon: pkt.lon),
          accuracy: pkt.accuracyM.toDouble(),
        )
        ?.alongTrackMeters;

    // Anchor updatedAt to receiver's current clock so offline phone clock skew
    // never trips CooperativeGpsFusion's 12s freshness gate!
    final member = GroupMemberModel(
      memberId: pkt.memberIdHex,
      displayName: pkt.displayName.isNotEmpty
          ? pkt.displayName
          : (_isRo ? 'Drumeț' : 'Hiker'),
      colorHex: pkt.colorHex,
      lat: pkt.lat,
      lon: pkt.lon,
      ele: pkt.eleM.toDouble(),
      accuracy: pkt.accuracyM.toDouble(),
      heading: pkt.headingDeg,
      speed: pkt.speedMps,
      alongTrackM: matchedAlong,
      inNavigation: pkt.inNavigation,
      isSelf: false,
      viaBluetooth: true,
      bleHopCount: pkt.hopCount,
      updatedAt: DateTime.now().toUtc(),
    );

    _bleGroupPeers[member.memberId] = member;
    final nextMembers = _mergeGroupMembersWithBle(
      serverMembers: session.members,
      selfMemberId: session.selfMemberId,
    );
    _groupSession.value = session.copyWith(members: nextMembers);
    if (_selectedGroupMember.value?.memberId == member.memberId) {
      _selectedGroupMember.value = member;
    }
  }

  void _onBleSosAlertReceived(BleSosAlertPacket pkt) {
    if (!mounted) return;
    final mySos = _myActiveSos.value;
    if (mySos != null && mySos.clientSosId == pkt.clientSosId) {
      return;
    }

    final split = pkt.splitRequesterAndMessage();
    final incomingModel = SosAlertModel(
      id: 'ble-${pkt.clientSosId}',
      clientSosId: pkt.clientSosId,
      trailId: widget.isRecording || widget.id.isEmpty ? null : widget.id,
      status: 'active',
      reason: pkt.reason,
      message: split.message,
      requesterName: split.requesterName,
      lat: pkt.lat,
      lon: pkt.lon,
      ele: pkt.eleM.toDouble(),
      isMine: false,
      viaBluetooth: true,
      bleHopCount: pkt.hopCount,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        pkt.createdEpochSec * 1000,
        isUtc: true,
      ),
    );

    final next = List<SosAlertModel>.of(_nearbySosAlerts.value);
    final idx = next.indexWhere((s) => s.dedupeKey == incomingModel.dedupeKey);
    if (idx >= 0) {
      next[idx] = _mergeNearbySos(next[idx], incomingModel);
    } else {
      next.insert(0, incomingModel);
    }
    _nearbySosAlerts.value = next;

    final fix = _currentGeoFix();
    final service = _liveService;
    if (service != null) {
      unawaited(
        service.notifyBleNearbySos(
          incomingModel,
          userLat: fix?.lat,
          userLon: fix?.lon,
          isRo: _isRo,
        ),
      );
    } else if (_fallbackNotifiedSosKeys.add(incomingModel.dedupeKey)) {
      final distM = fix != null
          ? ml.SphericalGreatCircle(
              fix,
            ).distanceTo(ml.Geographic(lat: pkt.lat, lon: pkt.lon))
          : null;
      unawaited(
        _fallbackSosNotifier.showNearbySosNotification(
          sos: incomingModel,
          distanceMeters: distM,
          isRo: _isRo,
        ),
      );
    }

    if (fix != null) {
      final responding = _activeRespondingSos();
      if (responding != null && responding.clientSosId == pkt.clientSosId) {
        _recomputeRescueRoute(fix, responding, syncWithServer: false);
      }
    }

    unawaited(
      _sosOutboxStore
          .upsertRelayedAlert(
            clientSosId: pkt.clientSosId,
            sosClaimHash: pkt.sosClaimHash,
            trailId: widget.isRecording || widget.id.isEmpty ? null : widget.id,
            reason: pkt.reason,
            message: split.message,
            requesterName: split.requesterName,
            lat: pkt.lat,
            lon: pkt.lon,
            ele: pkt.eleM.toDouble(),
            packetEpochSec: pkt.createdEpochSec,
            hopCount: pkt.hopCount,
          )
          .then((_) => _flushSosOutboxAndRelayQueue()),
    );
  }

  void _onBleSosAckReceived(BleSosAckPacket pkt) {
    if (!mounted) return;
    final mine = _myActiveSos.value;
    if (mine == null || mine.clientSosId != pkt.clientSosId) {
      return;
    }

    if (pkt.cancelled) {
      _bleAckResponderIds.remove(pkt.responderIdHex);
    } else if (pkt.comingToHelp) {
      _bleAckResponderIds.add(pkt.responderIdHex);
    }

    final nextAckCount = _bleAckResponderIds.length;
    final nextServerConfirmed = mine.bleServerConfirmed || pkt.uploadedToServer;

    final curEta = mine.bleNearestEtaMin;
    final pktEta = pkt.etaMin;
    final int? nextEta = switch ((curEta, pktEta)) {
      (final int a, final int b) => min(a, b),
      (final int a, null) => a,
      (null, final int b) => b,
      (null, null) => null,
    };

    final curDist = mine.bleNearestDistanceM;
    final pktDist = pkt.distM?.toDouble();
    final double? nextDist = switch ((curDist, pktDist)) {
      (final double a, final double b) => min(a, b),
      (final double a, null) => a,
      (null, final double b) => b,
      (null, null) => null,
    };

    _myActiveSos.value = mine.copyWith(
      bleAckCount: nextAckCount,
      bleServerConfirmed: nextServerConfirmed,
      bleNearestEtaMin: nextEta,
      bleNearestDistanceM: nextDist,
    );
  }

  void _onBleSosResolvedReceived(BleSosResolvedPacket pkt) {
    if (!mounted) return;
    _nearbySosAlerts.value = _nearbySosAlerts.value
        .where((s) => s.clientSosId != pkt.clientSosId)
        .toList(growable: false);

    if (_activeRespondingSos() == null && _rescueRouteNotifier.value != null) {
      _rescueRouteNotifier.value = null;
      _pushRescueSource(null);
    }

    unawaited(
      _sosOutboxStore
          .applyVerifiedResolution(
            clientSosId: pkt.clientSosId,
            sosRevealTokenHex: pkt.sosRevealTokenHex,
            resolvedEpochSec: pkt.resolvedEpochSec,
          )
          .then((applied) {
            if (applied) {
              return _flushSosOutboxAndRelayQueue();
            }
            return Future<void>.value();
          }),
    );
  }

  Future<void> _flushSosOutboxAndRelayQueue() async {
    if (_sosOutboxFlushInFlight || !mounted) return;
    final service = _liveService;
    if (service == null || !service.isConfigured) return;

    _sosOutboxFlushInFlight = true;
    try {
      await _sosOutboxStore.ensureLoaded();
      if (!mounted) return;

      // 1. Flush own pending offline SOS (claim/create or resolve).
      final mine = _sosOutboxStore.myPendingSos;
      if (mine != null) {
        if (mine.needsServerResolve) {
          final srvId = mine.serverSosId;
          if (srvId != null && srvId.isNotEmpty) {
            try {
              await service.updateSosStatus(
                sosId: srvId,
                status: mine.status,
                sosClaimSecret: mine.sosClaimSecret,
              );
              await _sosOutboxStore.clearMyPendingSos();
            } catch (_) {}
          } else {
            try {
              await service.relaySos(<String, dynamic>{
                'clientSosId': mine.clientSosId,
                'sosClaimHash': mine.sosClaimHash,
                'status': 'resolved',
                'sosClaimSecret': mine.sosClaimSecret,
                'packetEpochSec': mine.resolvedEpochSec ?? mine.createdEpochSec,
              });
              await _sosOutboxStore.clearMyPendingSos();
            } catch (_) {
              // If 404 (never relayed by any mule while active), clear cleanly.
              await _sosOutboxStore.clearMyPendingSos();
            }
          }
        } else if (mine.needsServerCreateOrClaim && mine.isActive) {
          try {
            final claimed = await service.triggerSos(
              trailId: mine.trailId,
              reason: mine.reason,
              message: mine.message,
              requesterName: mine.requesterName,
              lat: mine.lat,
              lon: mine.lon,
              ele: mine.ele,
              clientSosId: mine.clientSosId,
              sosClaimSecret: mine.sosClaimSecret,
            );
            await _sosOutboxStore.markMySosSyncedOnline(
              serverSosId: claimed.id,
            );
            if (mounted) {
              final cur = _myActiveSos.value;
              if (cur != null && cur.clientSosId == mine.clientSosId) {
                _myActiveSos.value = _mergeIntoMyActiveSos(cur, claimed);
              }
            }
          } catch (_) {}
        }
      }

      // 2. Store-and-Forward Mule flush: upload relayed BLE SOS packets to `/live/sos/relay`.
      final pendingRelays = _sosOutboxStore.pendingRelayUploads;
      for (final item in pendingRelays) {
        if (!mounted) break;
        try {
          final relayedSos = await service.relaySos(item.toRelayApiJson());
          await _sosOutboxStore.markRelayedUploaded(
            item.clientSosId,
            serverSosId: relayedSos?.id,
            resolved: item.isResolved,
          );
          if (!mounted) break;

          if (relayedSos != null && !item.isResolved) {
            // Upgrade BLE-only nearby alert ID to server ID in place.
            _nearbySosAlerts.value = <SosAlertModel>[
              for (final s in _nearbySosAlerts.value)
                if (s.clientSosId == item.clientSosId)
                  _mergeNearbySos(s, relayedSos)
                else
                  s,
            ];

            // Emit PKT_SOS_ACK(uploadedToServer: true) back over BLE so an offline
            // victim nearby learns their alert reached the server!
            if (_bleMeshEngine.isSupportedPlatform) {
              final token = await _resolveDeviceToken();
              if (!mounted) break;
              final respIdHex = deriveBleResponderIdHex(
                clientSosId: item.clientSosId,
                responderDeviceToken: token,
              );
              final fix = _currentGeoFix();
              final distM = fix != null
                  ? ml.SphericalGreatCircle(
                      fix,
                    ).distanceTo(ml.Geographic(lat: item.lat, lon: item.lon))
                  : null;
              final ack = BleSosAckPacket(
                clientSosId: item.clientSosId,
                responderIdHex: respIdHex,
                distM: (distM != null && distM.isFinite) ? distM.round() : null,
                uploadedToServer: true,
                ackEpochSec:
                    DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
              );
              unawaited(_bleMeshEngine.publishLocalSosAck(ack));
            }
          }
        } catch (_) {}
      }

      // 3. Flush pending offline responder action once serverSosId is known.
      final pendingResp = _sosOutboxStore.pendingResponderAction;
      final respServerId = pendingResp?.serverSosId;
      if (pendingResp != null &&
          respServerId != null &&
          respServerId.isNotEmpty) {
        try {
          await service.respondToSos(
            sosId: respServerId,
            status: pendingResp.status,
            lat: pendingResp.lat,
            lon: pendingResp.lon,
            ele: pendingResp.ele,
            distanceM: pendingResp.distanceM,
            etaSec: pendingResp.etaSec,
          );
          await _sosOutboxStore.clearPendingResponderAction();
        } catch (_) {}
      }

      // 4. Upgrade offline-created BLE group to hybrid Server + BLE using `preferredCode`.
      final curGroup = _groupSession.value;
      if (curGroup != null && curGroup.isOfflineBleGroup) {
        try {
          final upgraded = await service.createGroup(
            trailId: curGroup.trailId,
            displayName: _selfGroupDisplayName,
            preferredCode: curGroup.code,
          );
          if (mounted && _groupSession.value?.code == curGroup.code) {
            final nextSelfId = upgraded.selfMemberId.isNotEmpty
                ? upgraded.selfMemberId
                : curGroup.selfMemberId;
            final mergedSession = upgraded.copyWith(
              isOfflineBleGroup: false,
              selfMemberId: nextSelfId,
              members: _mergeGroupMembersWithBle(
                serverMembers: upgraded.members,
                selfMemberId: nextSelfId,
              ),
            );
            _groupSession.value = mergedSession;
            _bleMeshEngine.configureGroupSession(
              groupCode: mergedSession.code,
              selfMemberIdHex: mergedSession.selfMemberId,
            );
            final fix = _currentGeoFix();
            if (fix != null && _uiVisible) {
              _connectLiveSse(fix);
            }
          }
        } catch (_) {}
      }
    } finally {
      _sosOutboxFlushInFlight = false;
    }
  }

  OffTrailRerouteResult? _recomputeRescueRoute(
    ml.Geographic userPos,
    SosAlertModel sos, {
    required bool syncWithServer,
  }) {
    final targetPos = ml.Geographic(lat: sos.lat, lon: sos.lon);
    if (!_rescueDemPrefetchStarted &&
        ref.read(onlineStatusProvider) &&
        (_demGrid.sampleElevation(userPos.lat, userPos.lon) == null ||
            _demGrid.sampleElevation(targetPos.lat, targetPos.lon) == null)) {
      _rescueDemPrefetchStarted = true;
      unawaited(
        _demGrid.prefetchCorridor([userPos, targetPos]).then((_) {
          if (!mounted) return;
          final active = _activeRespondingSos();
          final cur = _currentGeoFix();
          if (active != null && cur != null) {
            _recomputeRescueRoute(cur, active, syncWithServer: false);
          }
        }),
      );
    }

    final route = OffTrailRouter.computeDirectRescueRoute(
      userPos: userPos,
      userEleM: _lastKnownAltitudeM,
      targetPos: targetPos,
      targetEleM: sos.ele > 0 ? sos.ele : null,
      referencePoints: _navTrackPoints,
      sampler: _demGrid.sampleElevation,
      mode: _offTrailMode,
      localeCode: _localeCode,
      isCycling: _etaCalculator?.isCycling ?? false,
    );

    final now = DateTime.now();
    _lastRescueCalcPos = userPos;
    _lastRescueCalcAt = now;
    _rescueRouteNotifier.value = route;
    _pushRescueSource(route);

    if (syncWithServer && route != null) {
      // Broadcast updated live BLE responder ETA/distance >= every 30s when offline/BLE.
      final cid = sos.clientSosId;
      final lastBleAck = _lastBleResponderAckAt;
      if (cid != null &&
          cid.isNotEmpty &&
          _bleMeshEngine.isSupportedPlatform &&
          (lastBleAck == null ||
              now.difference(lastBleAck).inSeconds >= 32)) {
        _lastBleResponderAckAt = now;
        unawaited(
          _resolveDeviceToken().then((token) {
            if (!mounted) return;
            final respIdHex = deriveBleResponderIdHex(
              clientSosId: cid,
              responderDeviceToken: token,
            );
            final ack = BleSosAckPacket(
              clientSosId: cid,
              responderIdHex: respIdHex,
              etaMin: max(1, (route.estimatedSeconds / 60.0).round()),
              distM: route.distanceM.round(),
              comingToHelp: true,
              ackEpochSec: now.toUtc().millisecondsSinceEpoch ~/ 1000,
            );
            unawaited(_bleMeshEngine.publishLocalSosAck(ack));
          }),
        );
      }

      final lastSync = _lastResponderSyncAt;
      final sinceSync = lastSync == null
          ? 999
          : now.difference(lastSync).inSeconds;
      final service = _liveService;
      if (sinceSync >= 20 &&
          service != null &&
          service.isConfigured &&
          !sos.id.startsWith('ble-') &&
          !sos.id.startsWith('local-')) {
        _lastResponderSyncAt = now;
        unawaited(
          service
              .respondToSos(
                sosId: sos.id,
                status: 'coming',
                lat: userPos.lat,
                lon: userPos.lon,
                ele: _lastKnownAltitudeM,
                distanceM: route.distanceM,
                etaSec: route.estimatedSeconds,
              )
              .catchError((Object _) => sos),
        );
      }
    }
    return route;
  }

  void _pushRescueSource(OffTrailRerouteResult? rescueRoute) {
    if (!_uiVisible) return;
    final style = _controller?.style ?? _loadedStyle;
    if (style == null) return;
    style
        .updateGeoJsonSource(
          id: 'sos-rescue-route',
          data: _offTrailGeoJson(rescueRoute),
        )
        .catchError((Object e) {
          debugPrint('NavigationScreen: failed to update sos-rescue-route — $e');
        });
  }

  void _handleRouteToSalvamontBase(SalvamontPoint target) {
    final pos = _currentGeoFix();
    if (pos == null) return;
    final targetGeo = ml.Geographic(lat: target.lat, lon: target.lon);
    if (ref.read(onlineStatusProvider) &&
        (_demGrid.sampleElevation(pos.lat, pos.lon) == null ||
            _demGrid.sampleElevation(targetGeo.lat, targetGeo.lon) == null)) {
      unawaited(
        _demGrid.prefetchCorridor([pos, targetGeo]).then((_) {
          if (!mounted) return;
          final cur = _currentGeoFix();
          if (cur == null) return;
          final refreshed = OffTrailRouter.computeDirectRescueRoute(
            userPos: cur,
            userEleM: _lastKnownAltitudeM,
            targetPos: targetGeo,
            targetEleM: target.ele.toDouble(),
            referencePoints: _navTrackPoints,
            sampler: _demGrid.sampleElevation,
            mode: _offTrailMode,
            localeCode: _localeCode,
            isCycling: _etaCalculator?.isCycling ?? false,
          );
          _rescueRouteNotifier.value = refreshed;
          _pushRescueSource(refreshed);
        }),
      );
    }

    final route = OffTrailRouter.computeDirectRescueRoute(
      userPos: pos,
      userEleM: _lastKnownAltitudeM,
      targetPos: targetGeo,
      targetEleM: target.ele.toDouble(),
      referencePoints: _navTrackPoints,
      sampler: _demGrid.sampleElevation,
      mode: _offTrailMode,
      localeCode: _localeCode,
      isCycling: _etaCalculator?.isCycling ?? false,
    );
    _rescueRouteNotifier.value = route;
    _pushRescueSource(route);
    _controller?.animateCamera(
      center: targetGeo,
      nativeDuration: const Duration(milliseconds: 500),
    );
  }

  void _maybeUpdateSolarForecast({bool force = false}) {
    if (widget.isRecording || _navTrackPoints.isEmpty) return;
    final calc = _etaCalculator;
    if (calc == null) return;
    final now = DateTime.now();
    if (!force &&
        _lastSolarCalcAt != null &&
        now.difference(_lastSolarCalcAt!).inSeconds < 60) {
      return;
    }
    _lastSolarCalcAt = now;
    _solarForecastNotifier.value = computeTrailSolarForecast(
      points: _navTrackPoints,
      etaCalc: calc,
      dem: _demGrid,
      alongTrackM: _lastMatchedAlongTrackM ?? 0.0,
      now: now,
      offTrailDurationSec: _offTrailNotifier.value?.estimatedSeconds,
      rejoinAlongTrackM: _offTrailNotifier.value?.rejoinAlongTrackM,
    );
  }

  Future<void> _openPeakFinderSheet(BuildContext context) async {
    await _peakFinder.ensureLoaded();
    if (!mounted) return;
    final center =
        _currentGeoFix() ??
        _navTrackPoints.firstOrNull?.geographic ??
        const ml.Geographic(lat: 45.4457, lon: 25.4563);
    if (ref.read(onlineStatusProvider) &&
        _demGrid.sampleElevation(center.lat, center.lon) == null) {
      await _demGrid.prefetchCorridor([center]);
      if (!mounted) return;
    }
    final panorama = _peakFinder.computePanorama(
      _demGrid,
      center.lat,
      center.lon,
      _lastKnownAltitudeM,
      localeCode: _localeCode,
    );
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => PeakFinderSheet(
        panorama: panorama,
        finder: _peakFinder,
        onSelectPeak: (peak) {
          Navigator.of(ctx).pop();
          _controller?.animateCamera(
            center: ml.Geographic(lat: peak.lat, lon: peak.lon),
            nativeDuration: const Duration(milliseconds: 500),
          );
        },
      ),
    );
  }

  Future<void> _syncTerrainIntelLayers(
    ml.StyleController style, {
    required bool showAvalancheSlope,
    required bool showSolarShadows,
    required DateTime solarTime,
    required ml.Geographic center,
  }) async {
    String proxyBase;
    try {
      proxyBase = ref.read(tileProxyBaseUrlProvider);
    } catch (_) {
      return;
    }
    if (proxyBase.isEmpty) return;

    Future<void> safeRemove(String layerId, String sourceId) async {
      try {
        await style.removeLayer(layerId);
      } catch (_) {}
      try {
        await style.removeSource(sourceId);
      } catch (_) {}
    }

    await safeRemove('avalanche-slope-layer', 'avalanche-slope');
    if (showAvalancheSlope) {
      await style.addSource(
        ml.RasterSource(
          id: 'avalanche-slope',
          tiles: ['$proxyBase/slope/{z}/{x}/{y}.png'],
          tileSize: 256,
          minZoom: 12,
          maxZoom: 13,
        ),
      );
      await style.addLayer(
        const ml.RasterStyleLayer(
          id: 'avalanche-slope-layer',
          sourceId: 'avalanche-slope',
          paint: {'raster-opacity': 0.62},
        ),
      );
    }

    await safeRemove('solar-shadows-layer', 'solar-shadows');
    if (showSolarShadows) {
      final sun = getSunPosition(solarTime, center.lat, center.lon);
      await style.addSource(
        ml.RasterSource(
          id: 'solar-shadows',
          tiles: [
            '$proxyBase/shade/{z}/{x}/{y}.png?az=${sun.azimuthDeg.round()}&alt=${sun.altitudeDeg.round()}',
          ],
          tileSize: 256,
          minZoom: 12,
          maxZoom: 13,
        ),
      );
      await style.addLayer(
        const ml.RasterStyleLayer(
          id: 'solar-shadows-layer',
          sourceId: 'solar-shadows',
          paint: {'raster-opacity': 0.78},
        ),
      );
    }
  }

  /// Body of the Android foreground-service notification for this session.
  ///
  /// Recording says what it is doing; navigating names the trail being
  /// followed, which is the only thing that distinguishes the two sessions
  /// from the notification shade. Falls back to the recording wording while
  /// the trail model is still loading (or failed to load) — the listener in
  /// [initState] rewrites the text if the name lands later.
  String _notificationText(AppLocalizations localizations) {
    if (widget.isRecording) {
      return localizations.location_tracking_notification_text;
    }
    final name = ref.read(trailProvider(widget.id)).value?.name;
    return name == null || name.isEmpty
        ? localizations.location_tracking_notification_text
        : localizations.location_tracking_notification_text_navigating(name);
  }

  void _syncCompassSamplingRate() {
    final rateCfg = resolveCompassRatePolicy(
      uiVisible: _uiVisible,
      headingUp: _headingUp,
      isStationary: _powerEngine.isStationarySleep,
      expeditionMode: _powerEngine.effectiveExpeditionMode,
    );
    _compassRateCfg = rateCfg;
    final desired = rateCfg.sensorEnabled ? rateCfg.samplingPeriod : null;
    if (desired == _appliedCompassPeriod &&
        (desired == null) == (_headingSub == null)) {
      return;
    }
    _appliedCompassPeriod = desired;
    _headingSub?.cancel();
    _headingSub = null;

    if (desired != null && RotationSensor.isPlatformSupported) {
      RotationSensor.samplingPeriod = desired;
      RotationSensor.coordinateSystem = CoordinateSystem.display();
      _headingSub = RotationSensor.orientationStream.listen(
        (event) => _onHeading(event.eulerAngles.azimuth * 180 / pi),
        onError: (Object error) {
          debugPrint('NavigationScreen: heading sensor error — $error');
        },
      );
    }
    _syncBearingFollowTicker();
  }

  void _syncCoasterTimer() {
    if (widget.isRecording) return;
    final shouldTick =
        _uiVisible && !_frozen && !_powerEngine.isStationarySleep;
    if (shouldTick && _coasterTimer == null) {
      _coasterTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _onCoasterTick(),
      );
    } else if (!shouldTick && _coasterTimer != null) {
      _coasterTimer?.cancel();
      _coasterTimer = null;
    }
  }

  /// Records a new raw GPS fix as the position-tween target and (re)starts the
  /// short tween toward it — mirrors `flutter_map_location_marker`'s
  /// `CurrentLocationLayer`, which disposed/restarted its own per-fix tween
  /// the same way, so overlapping fixes never fight each other.
  void _onFix(
    geo.Position pos, {
    double? latOverride,
    double? lonOverride,
    double? accuracyOverride,
  }) {
    final targetLat = latOverride ?? pos.latitude;
    final targetLon = lonOverride ?? pos.longitude;
    final targetAcc = accuracyOverride ?? pos.accuracy;
    _animateMarkerTo(targetLat, targetLon, targetAcc);
    if (_smoothedHeading == null &&
        pos.heading.isFinite &&
        pos.heading >= 0 &&
        pos.speed > 0.5) {
      _onHeading(pos.heading);
    }
  }

  void _animateMarkerTo(double lat, double lon, double accuracy) {
    _animStartLat = _lastLat ?? lat;
    _animStartLon = _lastLon ?? lon;
    _animTargetLat = lat;
    _animTargetLon = lon;
    _animAccuracy = accuracy;
    _positionAnimController.forward(from: 0);
  }

  /// Low-pass smooths the raw sensor heading (jittery magnetometer) into
  /// [_smoothedHeading] and pushes it to the marker, on the sensor's own
  /// ~15Hz cadence, independent of GPS. In heading-up follow, the camera
  /// bearing itself is eased toward this value every rendered frame by
  /// [_bearingFollowTicker] rather than snapped here — see that ticker's
  /// docs for why.
  void _onHeading(double rawDegrees) {
    final normalized = rawDegrees % 360 + (rawDegrees < 0 ? 360 : 0);
    final previous = _smoothedHeading;
    _smoothedHeading = previous == null
        ? normalized
        : _lerpBearing(previous, normalized, _kHeadingSmoothingAlpha);
    if (previous != null &&
        _bearingDelta(previous, _smoothedHeading!).abs() <
            _compassRateCfg.deadbandDeg) {
      return;
    }
    // Updates ONLY the isolated LocationPuck cone — zero ml.WidgetLayer rebuild!
    _headingNotifier.value = _smoothedHeading;
  }

  /// Per-frame tick for [_bearingFollowTicker] — eases [_mapBearing] toward
  /// the live [_smoothedHeading] target using an elapsed-time-based alpha
  /// (frame-rate independent), decoupling the camera's update rate from the
  /// heading sensor's throttled ~15Hz cadence so rotation reads as smooth as
  /// a native gesture instead of stepping once per sensor sample.
  void _onBearingFollowTick(Duration elapsed) {
    final target = _smoothedHeading;
    // Don't fight an in-flight compass-triggered transition — it owns
    // _mapBearing until it finishes, then this ticker resumes from there.
    if (target == null || _bearingTransitionController.isAnimating) {
      _lastBearingFollowElapsed = elapsed;
      return;
    }
    final last = _lastBearingFollowElapsed;
    _lastBearingFollowElapsed = elapsed;
    if (last == null) return;
    final dtSeconds =
        (elapsed - last).inMicroseconds / Duration.microsecondsPerSecond;
    if (dtSeconds <= 0) return;
    final alpha = 1 - exp(-dtSeconds / _kBearingFollowTauSeconds);
    final previous = _mapBearing;
    _mapBearing = _lerpBearing(_mapBearing, target, alpha);
    // Converged: once the per-frame easing step falls below ~0.02° the
    // rotation is done to sub-pixel precision — skip the JNI camera push.
    // Without this the ticker issues a native moveCamera every display frame
    // (60–120 Hz) for the entire heading-up session even while standing
    // still. The position tween pushes the camera independently, so centering
    // never depends on this.
    if (_bearingDelta(previous, _mapBearing).abs() < 0.02) return;
    _pushCamera();
  }

  /// Starts/stops [_bearingFollowTicker] to match whether continuous
  /// heading-up follow should currently be live — called after every change
  /// to [_followEnabled], [_headingUp], or [_headingSub].
  void _syncBearingFollowTicker() {
    final shouldRun = _followEnabled && _headingUp && _headingSub != null;
    if (shouldRun && !_bearingFollowTicker.isTicking) {
      _lastBearingFollowElapsed = null;
      _bearingFollowTicker.start();
    } else if (!shouldRun && _bearingFollowTicker.isTicking) {
      _bearingFollowTicker.stop();
    }
  }

  /// Shortest-path angular interpolation so the marker/camera never spin the
  /// long way around a 359°→1° wraparound. Reused for both per-frame bearing
  /// lerp and per-event heading smoothing.
  double _lerpBearing(double from, double to, double t) {
    var diff = (to - from) % 360;
    if (diff > 180) diff -= 360;
    if (diff < -180) diff += 360;
    return (from + diff * t) % 360;
  }

  /// Shortest-path signed angular difference in degrees ([-180, 180]) —
  /// the wraparound-safe companion to [_lerpBearing], used for the
  /// below-visible-threshold guards in [_onHeading] and
  /// [_onBearingFollowTick].
  double _bearingDelta(double from, double to) {
    var diff = (to - from) % 360;
    if (diff > 180) diff -= 360;
    if (diff < -180) diff += 360;
    return diff;
  }

  /// Composes the latest interpolated position with the latest smoothed
  /// heading into the marker's [ValueNotifier]. Called from both the position
  /// tween ([_applyAnimatedFrame]) and heading sensor ([_onHeading]) so marker
  /// position and rotation stay independently live.
  void _publishMarker() {
    final lat = _lastLat;
    final lon = _lastLon;
    if (lat == null || lon == null) return;
    _currentPosition.value = LocationMarkerPosition(
      latitude: lat,
      longitude: lon,
      accuracy: _animAccuracy,
      heading: _smoothedHeading,
      // LocationPuck.hasValidHeading requires a non-negative accuracy; the
      // sensor reports -1 on iOS, so pass a synthetic 0 whenever a heading is
      // available — the wedge is a direction indicator, not an accuracy gauge.
      headingAccuracy: _smoothedHeading == null ? null : 0,
    );
  }

  /// Ticks every frame of the position tween, advancing the interpolated
  /// position and (when following) the camera center — `moveCamera` is an
  /// instant, non-animated set so nothing fights this Flutter-side tween the
  /// way native `animateCamera` did.
  void _applyAnimatedFrame() {
    final targetLat = _animTargetLat;
    final targetLon = _animTargetLon;
    if (targetLat == null || targetLon == null) return;

    _lastLat = lerpDouble(_animStartLat, targetLat, _positionCurve.value)!;
    _lastLon = lerpDouble(_animStartLon, targetLon, _positionCurve.value)!;
    _publishMarker();
    _pushCamera(force: _positionAnimController.value >= 1.0);
  }

  /// Advances the bearing-transition tween, driving the same explicit
  /// [_mapBearing]/[_pushCamera] path everything else uses.
  void _applyBearingTransition() {
    _mapBearing = _lerpBearing(
      _bearingTransitionStart,
      _bearingTransitionTarget,
      _bearingTransitionCurve.value,
    );
    _pushCamera(force: _bearingTransitionController.value >= 1.0);
  }

  /// Smoothly animates [_mapBearing] to [target] — used for the two discrete
  /// compass-triggered transitions (enter/exit heading-up).
  void _animateBearingTo(double target) {
    _bearingTransitionStart = _mapBearing;
    _bearingTransitionTarget = target;
    _bearingTransitionController.forward(from: 0);
  }

  /// Pushes an explicit center+bearing to the map when following — never a
  /// partial update, since this MapLibre version doesn't reliably treat an
  /// omitted field as "unchanged" (see [_mapBearing]'s doc comment).
  void _pushCamera({bool force = false}) {
    if (!_followEnabled) return;
    final lat = _lastLat;
    final lon = _lastLon;
    if (lat == null || lon == null) return;
    final nowElapsed = Duration(
      microseconds: DateTime.now().microsecondsSinceEpoch,
    );
    if (!_cameraPushThrottle.shouldPush(nowElapsed, isFinalFrame: force)) {
      return;
    }
    _controller?.moveCamera(
      center: ml.Geographic(lat: lat, lon: lon),
      bearing: _mapBearing,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _uiVisible = true;
        _powerEngine.setUiForeground(true);
        _radioScheduler.updateState(uiForeground: true);
        unawaited(_positionSource.setForeground(true));
        _syncCompassSamplingRate();
        _syncCoasterTimer();
        // Catch the paused native map up on everything recorded while
        // backgrounded — per-fix pushes are skipped while !_uiVisible.
        _pushBreadcrumbSources(ref.read(_navProviderInstance).breadcrumb);
        if (!widget.isRecording) {
          _pushOffTrailSource(_offTrailNotifier.value);
        }
        _pushRescueSource(_rescueRouteNotifier.value);
        unawaited(
          _radioScheduler.triggerImmediateBurst(
            reason: 'app_resumed',
            forceHeartbeat: true,
          ),
        );
        final curFix = _currentGeoFix();
        if (curFix != null && _firstHeartbeatSent) {
          _connectLiveSse(curFix);
        }
      case AppLifecycleState.inactive:
        // Transient (notification shade, incoming call, app-switcher peek) —
        // treating it as background used to bounce tracelet through a full
        // native setConfig round-trip and kill/restart the heading sensor on
        // every shade pull. A real background always delivers paused/hidden
        // right after, so doing nothing here loses nothing.
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _uiVisible = false;
        _powerEngine.setUiForeground(false);
        _radioScheduler.updateState(uiForeground: false);
        unawaited(_positionSource.setForeground(false));
        _syncCompassSamplingRate();
        _syncCoasterTimer();
        _disconnectLiveSse();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hibernationContainer
        ?.read(navSessionHibernationProvider.notifier)
        .exitNavigationSession();
    _myActiveSos.removeListener(_syncSosPowerOverride);
    _nearbySosAlerts.removeListener(_syncSosPowerOverride);
    _sub?.cancel();
    _headingSub?.cancel();
    _motionSub?.cancel();
    unawaited(_motionChannel.dispose());
    _powerWatchdogTimer?.cancel();
    _powerEngine.dispose();
    _radioScheduler.dispose();
    unawaited(_terrainWorker?.dispose());
    final proxy = ref.read(tileProxyServerProvider);
    if (proxy != null && identical(proxy.terrainDemGrid, _demGrid)) {
      proxy.terrainDemGrid = null;
    }
    _solarForecastNotifier.dispose();
    unawaited(_demGrid.closeArchives());
    _persistTimer?.cancel();
    _coasterTimer?.cancel();
    for (final s in _bleSubscriptions) {
      s.cancel();
    }
    _bleSubscriptions.clear();
    unawaited(_bleMeshEngine.dispose());
    _valhallaRerouteCancelToken?.cancel('dispose');
    _disconnectLiveSse();
    if (_groupSessionSyncListener != null) {
      _groupSession.removeListener(_groupSessionSyncListener!);
      _groupSessionSyncListener = null;
    }
    if (active_nav.read(_store) == null) {
      final service = _liveService;
      if (service != null && service.isConfigured) {
        unawaited(service.clearHeartbeat());
      }
    }
    _positionAnimController.dispose();
    _bearingTransitionController.dispose();
    _bearingFollowTicker.dispose();
    // A surviving session row means this screen is going away while tracking
    // is meant to continue — the task was swiped off recents, or the route was
    // popped mid-recording. Stopping tracelet here killed the foreground
    // service and recorded nothing until the app was reopened. The finish
    // paths clear the row before popping, so a completed session still stops.
    unawaited(
      active_nav.read(_store) != null
          ? _positionSource.detach()
          : _positionSource.dispose(),
    );
    _headingNotifier.dispose();
    _powerStateNotifier.dispose();
    _currentPosition.dispose();
    _liveTrackMeters.dispose();
    _etaNotifier.dispose();
    _offTrailNotifier.dispose();
    _offTrailChartSpots.dispose();
    _gpsSignalState.dispose();
    _effectiveGpsAccuracy.dispose();
    _farPreviewDistanceM.dispose();
    _accessRouteLoading.dispose();
    _groupSession.dispose();
    _selectedGroupMember.dispose();
    _activeHikers30m.dispose();
    _liveReports.dispose();
    _nearbyPromptReport.dispose();
    _myActiveSos.dispose();
    _nearbySosAlerts.dispose();
    _rescueRouteNotifier.dispose();
    _liveActionBusy.dispose();
    _sheetController.dispose();
    _waypointSheetController.dispose();
    super.dispose();
  }

  /// Persists a snapshot of the current navigation progress + stats +
  /// breadcrumb to the single active-session row, updating (never
  /// duplicating) the row via [_activeRowObxId]. Best-effort — see
  /// `active_navigation_store`'s swallow-all semantics.
  void _persistNow({bool force = false}) {
    final navState = ref.read(_navProviderInstance);
    final stats = ref.read(_statsProviderInstance);
    final count = navState.breadcrumb.length;
    final elapsedSec = stats.elapsed.inSeconds;

    if (!force &&
        count == _lastPersistedPointCount &&
        elapsedSec == _lastPersistedElapsedSec &&
        stats.isPaused == _lastPersistedPaused) {
      return; // Zero disk/ObjectBox I/O while resting at cabană!
    }

    _lastPersistedPointCount = count;
    _lastPersistedElapsedSec = elapsedSec;
    _lastPersistedPaused = stats.isPaused;

    final slab = _breadcrumbSlab;
    final usedSlab = slab != null;
    if (usedSlab) {
      slab.appendFromBreadcrumb(navState.breadcrumb);
    }

    final entity = ActiveNavigationEntity(
      obxId: _activeRowObxId,
      sessionType: widget.isRecording
          ? ActiveSessionType.rec
          : ActiveSessionType.nav,
      trailId: widget.isRecording ? null : widget.id,
      recordingCosting: widget.isRecording ? _recordingCosting : null,
      navResponseJson: _sessionNavJson,
      currentManeuverIndex: navState.currentManeuverIndex,
      // When BreadcrumbSlabStore is active, omit O(N) polyline + list copies!
      breadcrumbPolyline: usedSlab
          ? ''
          : PolylineUtil.encode(
              navState.breadcrumb
                  .map((wpt) => ml.Geographic(lon: wpt.lon!, lat: wpt.lat!))
                  .toList(),
            ),
      elevations: usedSlab
          ? null
          : navState.breadcrumb.map((wpt) => wpt.ele ?? 0.0).toList(),
      timestampsUtc: usedSlab
          ? null
          : navState.breadcrumb
                .map(
                  (wpt) => (wpt.time ?? DateTime.now())
                      .toUtc()
                      .millisecondsSinceEpoch,
                )
                .toList(),
      distanceMeters: stats.distanceMeters,
      elevationGainMeters: stats.elevationGainMeters,
      elevationLossMeters: stats.elevationLossMeters,
      currentElapsedSeconds: elapsedSec,
      pausedAccumSeconds: _statsNotifier.pausedAccum.inSeconds,
      isPaused: stats.isPaused,
      updatedAtUtc: DateTime.now().toUtc(),
    );
    _activeRowObxId = active_nav.save(_store, entity);
  }

  /// Whether the recorded breadcrumb has enough points for "Save track" to be
  /// offered at all — a 0-1 point track has nothing meaningful to convert.
  /// Gates the option's *visibility* on the completion banner and exit
  /// dialog, rather than accepting the tap and no-op'ing inside
  /// [_saveRecordedTrack].
  bool _hasSavableTrack() {
    return ref.read(_navProviderInstance).breadcrumb.length >= 2;
  }

  /// Builds a stub [Trail] from the recorded breadcrumb (via the same
  /// on-device conversion the Route Planner and GPX-file import use — see
  /// `buildDraftTrail`) and hands off to `trail_create_screen`.
  /// Callers must only invoke this with a breadcrumb of >=2 points (see the
  /// completion-banner and exit-dialog guards) — the conversion isn't
  /// meaningful for a near-empty track.
  ///
  /// Reads `navState` via `ref.read` with the IDENTICAL family seed args used
  /// everywhere else in this file — a different seed would resolve a
  /// different (split-brain) provider instance.
  ///
  /// Durability: the converted trail is first written as a local
  /// [TrailSyncState.draft] row and only THEN is the active-navigation row
  /// cleared ([persistDraftThenClearSession]), so the recording survives the
  /// OS killing the app before the user taps Save in the create form. The
  /// form opens on that draft's localId, and its save promotes the same row
  /// to pending.
  ///
  /// Guarded by [_savingTrack] so a double-tap can't fire two concurrent
  /// conversions/navigations (mirrors `route_planner_screen.dart`'s
  /// `_finishing`). On failure (e.g. offline), shows an error toast and
  /// leaves the session intact (this includes a failed draft write) so the user can retry — matching
  /// `import_trail_file.dart`'s `importTrailFile` precedent for this same
  /// toast-and-stay behaviour.
  ///
  /// The breadcrumb is saved unchanged and also kept on the draft as its
  /// original track, so "Follow roads" / "Recalculate heights" are applied
  /// (and undone) in the editor rather than here.
  Future<void> _saveRecordedTrack(BuildContext context) async {
    if (_savingTrack) return;
    setState(() => _savingTrack = true);

    try {
      final navState = ref.read(_navProviderInstance);
      final navStats = ref.read(_statsProviderInstance);

      final originalTrail = ref.read(trailProvider(widget.id)).value;

      // The full recorded breadcrumb, times and all, doubling as the
      // draft's original track.
      final gpx = buildGpxFromPoints(navState.breadcrumb);

      // For a real trail, keep its own category/subcategory. For a trail-less
      // recording, derive a (sub)category from the chosen travel profile
      // (the same settings-driven pre-fill the route planner uses) rather
      // than always leaving it unset.
      //
      // Precision limit: `_recordingCosting` only ever carries the binary
      // `'bicycle'`/`'pedestrian'` Valhalla costing string (captured via
      // `bucket.costing` in trail_source_select_screen's `_openRecorder`),
      // not the full RouteTravelBucket — so a recording started on
      // MTB/Gravel/Road collapses to the generic Hybrid bike bucket here.
      // That is a pre-existing limitation, not a new regression: widening it
      // needs ActiveNavigationEntity/router_provider schema changes, which
      // are out of scope for this task.
      final recordingBucket = _recordingCosting == null
          ? null
          : (_recordingCosting == 'bicycle'
                ? RouteTravelBucket.bikingHybrid
                : RouteTravelBucket.hiking);
      final selection = recordingBucket == null
          ? null
          : categorySelectionForBucket(
              recordingBucket,
              ref.read(categoryProvider).value ?? const [],
              ref.read(subcategoryProvider),
              // Never auto-assign a subcategory the user has hidden.
              subcategoryPrefs:
                  ref.read(subcategoryPreferenceProvider).value ?? const [],
            );

      final category = originalTrail?.categoryId ?? selection?.categoryId;
      final subcategory =
          originalTrail?.subcategoryId ?? selection?.subcategoryId;

      // NavigationStats.elapsed is already moving time — the 1-second
      // tick is a no-op while isPaused || isStationary, and it is already
      // the value shown to the user during the session, so no second
      // derivation is invented here. No planner-style estimated duration
      // fallback is passed either — `duration` must come from the
      // GPX so a later web recompute reproduces it.
      final draft = await buildDraftTrail(
        ref,
        gpx,
        category: category,
        subcategory: subcategory,
        movingDuration: navStats.elapsed,
      );
      final trail = draft.copyWith(
        originalGpxData: draft.expand?.gpxData ?? '',
      );

      // Durability ordering: the draft row is written BEFORE the session row
      // is released, so an OS kill in between can never lose the recording.
      final localId = persistDraftThenClearSession(
        writeDraft: () {
          // Read fresh at the point of use, never from a cached field.
          final accountId = currentAccountId(_store);
          if (accountId == null) {
            throw StateError(
              'navigation_screen: no signed-in account for a recording draft',
            );
          }
          return saveNewLocalTrail(
            _store,
            trail: trail,
            ownerAccountId: accountId,
            authorActorId: ref.read(authProvider).value?.actorId,
            localId: mintLocalId(),
            trailLocalPhotos: const [],
            waypointLocalPhotosByKey: const {},
            asDraft: true,
          );
        },
        clearSession: () {
          // Stops the periodic _persistNow from re-writing the session row
          // during the pushReplacement transition. Kept inside clearSession
          // so a failed draft write leaves the timer running.
          _persistTimer?.cancel();
          active_nav.clear(_store);
          _breadcrumbSlab?.clear();
        },
      );

      final draftTrail = trail.copyWith(
        localId: localId,
        syncState: TrailSyncState.draft,
      );

      ref.invalidate(trailLibraryProvider);
      final username = ref.read(authProvider).value?.preferredUsername;
      if (username != null) {
        ref.invalidate(profileTrailsProvider('@$username'));
      }

      pendingImportedTrail = draftTrail;
      if (context.mounted) {
        context.pushReplacement('/trail/create/edit', extra: draftTrail);
      }
    } catch (_) {
      if (!context.mounted) return;
      ref
          .read(toastProvider.notifier)
          .add(
            ToastMessage(
              type: ToastType.error,
              icon: FontAwesomeIcons.circleExclamation,
              text: AppLocalizations.of(context)!.error_saving_trail,
            ),
          );
    } finally {
      if (mounted) setState(() => _savingTrack = false);
    }
  }

  void _onWaypointSelected(Waypoint wp) {
    setState(() => _selectedWaypoint = wp);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _waypointSheetController.isAttached) {
        _waypointSheetController.animateTo(
          0.35,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _onPanStart() {
    if (_followEnabled) {
      setState(() => _followEnabled = false);
      _syncBearingFollowTicker();
    }
  }

  void _onRecenter() {
    setState(() => _followEnabled = true);
    _syncBearingFollowTicker();
    final pos = _currentPosition.value;
    if (pos == null) return;
    // Restores prior heading-up state — recenter never forces north. Synced
    // into _mapBearing immediately so a position tick landing mid-animation
    // pushes the same value instead of a stale/ambiguous one (see
    // _mapBearing's doc comment).
    _mapBearing = _headingUp ? (_smoothedHeading ?? _mapBearing) : 0;
    _controller?.animateCamera(
      center: ml.Geographic(lat: pos.latitude, lon: pos.longitude),
      bearing: _mapBearing,
      nativeDuration: const Duration(milliseconds: 300),
    );
  }

  /// Composes the style JSON to hand to the map, always via
  /// [rewriteStyleForProxy].
  /// Returns null while [baseJson] is still resolving — the caller
  /// then shows the loading passthrough (initStyle path) or leaves the
  /// mounted style unchanged (`_swapStyle` path).
  ///
  /// One style is composed on one code path and always routed through the
  /// loopback proxy, which resolves coverage per tile
  /// (`tile_proxy_server.dart`) and redirects an uncovered tile to the
  /// operator's upstream template — so a session started without service
  /// fills in as soon as the radio returns, with no widget-level mode to
  /// flip. This screen's camera moves freely across a session, unlike
  /// `TrailMap`'s fixed trail bounds, but the proxy's per-request resolution
  /// means no viewport parameter is needed here either.
  String? _composeStyle(String? baseJson) {
    if (baseJson == null) return null;
    try {
      final decoded = jsonDecode(baseJson) as Map<String, dynamic>;
      final offlineStyle = rewriteStyleForProxy(
        decoded,
        proxyBaseUrl: ref.read(tileProxyBaseUrlProvider),
        dark:
            effectiveBrightness(ref.read(themeModeProvider)) == Brightness.dark,
      );
      return jsonEncode(offlineStyle);
    } catch (e) {
      debugPrint('NavigationScreen: offline style rewrite failed — $e');
      return null;
    }
  }

  /// Recomposes the (proxy-rewritten) style from current provider state and
  /// swaps it onto the mounted controller in place. Theme path only
  /// (unchanged mechanism) — the static proxy source is baked into every
  /// composed style by construction, so no separate region-swap path is
  /// needed here.
  void _swapStyle() {
    final controller = _controller;
    if (controller == null) return;
    final baseJson = ref.read(mapStyleJsonProvider).value;
    final json = _composeStyle(baseJson);
    if (json != null && json != _lastStyleJson) {
      _lastStyleJson = json;
      controller.setStyle(json);
    }
  }

  /// JSON-encodes the breadcrumb as a single LineString Feature. Never string
  /// concatenation — keeps the geometry structurally isolated.
  ///
  /// A GeoJSON `LineString` requires at least 2 coordinates (RFC 7946
  /// §3.1.4) — the native MapLibre parser rejects a 0/1-point one, which
  /// would throw on the very first `addSource` call (before any GPS fix has
  /// landed) and permanently skip creating the `breadcrumb`
  /// source/`breadcrumb-route` layer for the rest of the session. So below
  /// 2 points this returns an empty (but valid) FeatureCollection instead,
  /// which renders nothing until real geometry is available.
  String _breadcrumbGeoJson(List<Wpt> pts) {
    if (pts.length < 2) {
      return jsonEncode(<String, Object?>{
        'type': 'FeatureCollection',
        'features': <Object?>[],
      });
    }
    return jsonEncode(<String, Object?>{
      'type': 'Feature',
      'properties': <String, Object?>{},
      'geometry': <String, Object?>{
        'type': 'LineString',
        'coordinates': <List<double>>[
          for (final p in pts) <double>[p.lon!, p.lat!],
        ],
      },
    });
  }

  /// Pushes the breadcrumb to the map across its two native sources: the
  /// `breadcrumb` (frozen) source holding points `[0.._frozenCount)`, updated
  /// only when the tail rolls over, and the `breadcrumb-tail` source holding
  /// the still-growing remainder (sharing one overlap point so the line reads
  /// as continuous), re-serialized per fix. Bounds per-fix serialization +
  /// platform-channel traffic to O([_kBreadcrumbTailMax]) — pushing the whole
  /// track per fix was quadratic over a session. The roll itself is O(track),
  /// amortized to O(1)-per-fix by the chunk size.
  ///
  /// Idempotent against arbitrary gaps: passing the full current list after
  /// any number of skipped pushes (style reload, backgrounded interval)
  /// converges both sources — callers never need to replay missed fixes.
  void _pushBreadcrumbSources(List<Wpt> pts) {
    final style = _controller?.style;
    if (style == null) return;
    if (pts.length - _frozenCount >= _kBreadcrumbTailMax) {
      style
          .updateGeoJsonSource(id: 'breadcrumb', data: _breadcrumbGeoJson(pts))
          .catchError((Object e) {
            debugPrint('NavigationScreen: failed to update breadcrumb — $e');
          });
      _frozenCount = pts.length;
    }
    final tailStart = _frozenCount == 0 ? 0 : _frozenCount - 1;
    style
        .updateGeoJsonSource(
          id: 'breadcrumb-tail',
          data: _breadcrumbGeoJson(pts.sublist(tailStart)),
        )
        .catchError((Object e) {
          debugPrint('NavigationScreen: failed to update breadcrumb tail — $e');
        });
  }

  String _offTrailGeoJson(OffTrailRerouteResult? reroute) {
    if (reroute == null || reroute.points.length < 2) {
      return jsonEncode(<String, Object?>{
        'type': 'FeatureCollection',
        'features': <Object?>[],
      });
    }
    return jsonEncode(<String, Object?>{
      'type': 'Feature',
      'properties': <String, Object?>{},
      'geometry': <String, Object?>{
        'type': 'LineString',
        'coordinates': <List<double>>[
          for (final p in reroute.points) <double>[p.lon, p.lat],
        ],
      },
    });
  }

  void _pushOffTrailSource(OffTrailRerouteResult? reroute) {
    if (!_uiVisible) return;
    final style = _controller?.style ?? _loadedStyle;
    if (style == null) return;
    style
        .updateGeoJsonSource(
          id: 'off-trail-reroute',
          data: _offTrailGeoJson(reroute),
        )
        .catchError((Object e) {
          debugPrint(
            'NavigationScreen: failed to update off-trail reroute — $e',
          );
        });
  }

  /// Adds the trail outline, if the trail is available and it is not already
  /// on this style.
  ///
  /// `trailProvider` is read rather than awaited because on a warm open —
  /// arriving from the trail screen — it already holds the trail. A session
  /// resumed after a cold start has nothing warm, so the read returns null and
  /// the outline never appeared at all: `_onStyleLoaded` runs once and never
  /// retried. The listener in [build] covers that case by calling back here
  /// when the trail lands.
  Future<void> _addTrailOutline(ml.StyleController style) async {
    if (_trailLayerAdded) return;
    final trail = ref.read(trailProvider(widget.id)).value;
    if (trail?.expand?.gpx == null) return;
    // Claimed before the await so a style load and a late-arriving trail
    // cannot both get past the guard and add a duplicate source.
    _trailLayerAdded = true;
    await _trailLayer.add(style, trail!);
  }

  /// Re-arms everything that binds to the current native `Style` object:
  /// `setStyle` (used for theme swaps) drops added layers/sources, so this
  /// must run after every style load, not just once at `onMapCreated`. The
  /// location marker itself is a Flutter `_LocationMarkerLayer` (not a
  /// native style layer), so it survives style swaps untouched.
  Future<void> _onStyleLoaded(ml.StyleController style) async {
    _loadedStyle = style;
    _trailLayerAdded = false;
    try {
      await _addTrailOutline(style);

      final breadcrumb = ref.read(_navProviderInstance).breadcrumb;
      // Two-source split: everything so far seeds the frozen source; the
      // tail source starts empty and takes the per-fix updates — see
      // [_pushBreadcrumbSources].
      await style.addSource(
        ml.GeoJsonSource(
          id: 'breadcrumb',
          data: _breadcrumbGeoJson(breadcrumb),
        ),
      );
      _frozenCount = breadcrumb.length;
      await style.addSource(
        ml.GeoJsonSource(
          id: 'breadcrumb-tail',
          data: _breadcrumbGeoJson(const []),
        ),
      );
      // Style-spec defaults to butt cap / miter join, which reads as
      // angular at turns — round both so the trail renders as a
      // continuously smooth line, matching the pre-migration
      // flutter_map `Polyline`'s auto-rounded rendering. Both breadcrumb
      // layers share identical paint so the frozen/tail split is invisible.
      const breadcrumbPaint = {'line-color': '#DC2626', 'line-width': 3.5};
      const breadcrumbLayout = {'line-cap': 'round', 'line-join': 'round'};
      await style.addLayer(
        const ml.LineStyleLayer(
          id: 'breadcrumb-route',
          sourceId: 'breadcrumb',
          paint: breadcrumbPaint,
          layout: breadcrumbLayout,
        ),
      );
      await style.addLayer(
        const ml.LineStyleLayer(
          id: 'breadcrumb-route-tail',
          sourceId: 'breadcrumb-tail',
          paint: breadcrumbPaint,
          layout: breadcrumbLayout,
        ),
      );

      if (!widget.isRecording) {
        await style.addSource(
          ml.GeoJsonSource(
            id: 'off-trail-reroute',
            data: _offTrailGeoJson(_offTrailNotifier.value),
          ),
        );
        await style.addLayer(
          const ml.LineStyleLayer(
            id: 'off-trail-reroute-casing',
            sourceId: 'off-trail-reroute',
            layout: <String, Object>{
              'line-cap': 'round',
              'line-join': 'round',
            },
            paint: <String, Object>{
              'line-color': '#FFFFFF',
              'line-width': 6.0,
            },
          ),
        );
        await style.addLayer(
          const ml.LineStyleLayer(
            id: 'off-trail-reroute',
            sourceId: 'off-trail-reroute',
            layout: <String, Object>{
              'line-cap': 'round',
              'line-join': 'round',
            },
            paint: <String, Object>{
              'line-color': '#B45309',
              'line-width': 3.5,
            },
          ),
        );
      }

      await style.addSource(
        ml.GeoJsonSource(
          id: 'sos-rescue-route',
          data: _offTrailGeoJson(_rescueRouteNotifier.value),
        ),
      );
      await style.addLayer(
        const ml.LineStyleLayer(
          id: 'sos-rescue-route-casing',
          sourceId: 'sos-rescue-route',
          layout: <String, Object>{
            'line-cap': 'round',
            'line-join': 'round',
          },
          paint: <String, Object>{
            'line-color': '#FFFFFF',
            'line-width': 8.0,
          },
        ),
      );
      await style.addLayer(
        const ml.LineStyleLayer(
          id: 'sos-rescue-route-line',
          sourceId: 'sos-rescue-route',
          layout: <String, Object>{
            'line-cap': 'round',
            'line-join': 'round',
          },
          paint: <String, Object>{
            'line-color': '#EF4444',
            'line-width': 4.5,
            'line-dasharray': [1.5, 1.2],
          },
        ),
      );

      final localSettings = ref.read(localSettingsProvider);
      await _syncTerrainIntelLayers(
        style,
        showAvalancheSlope: localSettings.showAvalancheSlope,
        showSolarShadows: localSettings.showSolarShadows,
        solarTime: _simulatedSolarTime ?? DateTime.now(),
        center:
            _currentGeoFix() ??
            _navTrackPoints.firstOrNull?.geographic ??
            const ml.Geographic(lat: 45.4457, lon: 25.4563),
      );
    } catch (e) {
      debugPrint('NavigationScreen: onStyleLoaded failed — $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Live style swap: theme toggle swaps the composed style in place on
    // the already-mounted map. One style is composed on one path and always
    // routed through the loopback proxy, which resolves coverage per tile
    // and redirects an uncovered tile to the operator's upstream template —
    // so a session started without service fills in when the radio returns,
    // with no mode flip: a newly-downloaded region's tiles resolve the next
    // time MapLibre requests them (confirmed on-device, no remount needed),
    // no separate region-change listener is required.
    // The trail can resolve after the style has loaded: a resumed session
    // starts cold, with nothing having warmed `trailProvider`, so the read in
    // [_addTrailOutline] finds nothing and the blue outline never appears.
    // Add it when it lands instead of only at style-load time. Skipped while
    // recording, which has no trail id to resolve.
    if (!widget.isRecording && widget.id.isNotEmpty) {
      ref.listen(trailProvider(widget.id), (_, next) {
        final trail = next.value;
        if (trail?.expand?.gpx == null) return;
        _initTrailNavigation(trail!);
        final style = _loadedStyle;
        if (style == null) return;
        unawaited(
          _addTrailOutline(style).catchError((Object e) {
            debugPrint('NavigationScreen: failed to add trail outline — $e');
          }),
        );
      });
    }

    ref.listen(mapStyleJsonProvider, (_, _) => _swapStyle());

    ref.listen(showAvalancheSlopeProvider, (_, next) {
      final style = _loadedStyle;
      if (style == null) return;
      unawaited(
        _syncTerrainIntelLayers(
          style,
          showAvalancheSlope: next,
          showSolarShadows: ref.read(showSolarShadowsProvider),
          solarTime: _simulatedSolarTime ?? DateTime.now(),
          center:
              _currentGeoFix() ??
              _navTrackPoints.firstOrNull?.geographic ??
              const ml.Geographic(lat: 45.4457, lon: 25.4563),
        ),
      );
    });

    ref.listen(showSolarShadowsProvider, (_, next) {
      final style = _loadedStyle;
      if (style == null) return;
      unawaited(
        _syncTerrainIntelLayers(
          style,
          showAvalancheSlope: ref.read(showAvalancheSlopeProvider),
          showSolarShadows: next,
          solarTime: _simulatedSolarTime ?? DateTime.now(),
          center:
              _currentGeoFix() ??
              _navTrackPoints.firstOrNull?.geographic ??
              const ml.Geographic(lat: 45.4457, lon: 25.4563),
        ),
      );
    });

    // Breadcrumb in-place update: swap the native tail source's data on every
    // new position fix, never remove/re-add sources. Keyed on
    // breadcrumbLength — the list object itself is identity-stable by design
    // (see NavigationState.breadcrumb). Skipped while backgrounded: the
    // native map is paused, [_pushBreadcrumbSources] catches it up on resume.
    ref.listen(_navProviderInstance, (prev, next) {
      if (prev?.breadcrumbLength == next.breadcrumbLength) return;
      if (!_uiVisible) return;
      _pushBreadcrumbSources(next.breadcrumb);
    });

    // Deliberately NOT a whole-state watch: navigation state changes per GPS
    // fix and stats tick at 1 Hz — a whole-state watch rebuilt this entire
    // screen (map included) at ≥1 Hz for the whole session. The banner only
    // needs the maneuver index; the stats sheet and pause button watch their
    // own slices via scoped Consumers below.
    final currentIndex = ref.watch(
      _navProviderInstance.select((s) => s.currentManeuverIndex),
    );
    final trailAsync = ref.watch(trailProvider(widget.id));
    // `.value`, not `.requireValue`: the latter throws while `logout()`
    // holds a value-less AsyncLoading, which a rejected session can now
    // reach mid-recording. WaypointSheet already takes a nullable user.
    final user = ref.watch(authProvider).value;
    final localizations = AppLocalizations.of(context)!;
    _localeCode = localizations.localeName;
    final unit = ref.watch(unitProvider);

    final baseAsync = ref.watch(mapStyleJsonProvider);
    final baseJson = baseAsync.value;
    final error = baseAsync.error;

    // Memoized on input identity: the compose is a full style-JSON
    // decode → rewrite → encode round-trip (100s of KB), far too heavy to
    // re-run on every incidental rebuild of this screen.
    if (!identical(baseJson, _composeBaseInput)) {
      _composeBaseInput = baseJson;
      _composeOutput = _composeStyle(baseJson);
    }
    final composed = _composeOutput;
    if (composed != null) _lastStyleJson = composed;
    final styleJson = _lastStyleJson;

    if (styleJson != null &&
        !widget.isRecording &&
        _showingElevation &&
        !_didAutoExpandSheet) {
      _didAutoExpandSheet = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _showingElevation && _sheetController.isAttached) {
          _sheetController.animateTo(
            _elevationSheetSize,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }

    final maneuvers = widget.response.maneuvers;
    final isArrived =
        currentIndex >= maneuvers.length - 1 && maneuvers.isNotEmpty;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmExit(context, localizations);
      },
      child: Scaffold(
        body: styleJson == null
            ? (error != null
                  ? Center(child: Text(error.toString()))
                  : const Center(child: CircularProgressIndicator()))
            : Stack(
                children: [
                  // ----------------------------------------------------------
                  // Full-screen map
                  // ----------------------------------------------------------
                  Listener(
                    onPointerDown: (_) => _activePointers++,
                    onPointerUp: (_) =>
                        _activePointers = (_activePointers - 1).clamp(0, 10),
                    onPointerCancel: (_) =>
                        _activePointers = (_activePointers - 1).clamp(0, 10),
                    child: ml.MapLibreMap(
                      options: _mapOptions ??= ml.MapOptions(
                        initStyle: styleJson,
                        initCenter:
                            widget.initialCenter ??
                            (widget.response.shapeAsGeographic.isNotEmpty
                                ? widget.response.shapeAsGeographic.first
                                : const ml.Geographic(lat: 0, lon: 0)),
                        initZoom: 15,
                        androidForegroundLoadColor: Theme.of(
                          context,
                        ).colorScheme.surface,
                        // See TrailMap for why texture mode is off and `hc`
                        // is pinned.
                        androidTextureMode: false,
                        androidMode: ml.AndroidPlatformViewMode.hc,
                      ),
                      onMapCreated: (controller) {
                        _controller = controller;
                        final pending = _pendingStyle;
                        if (pending != null) {
                          _pendingStyle = null;
                          _onStyleLoaded(pending);
                        }
                      },
                      onStyleLoaded: (style) {
                        if (_controller == null) {
                          _pendingStyle = style;
                          return;
                        }
                        _onStyleLoaded(style);
                      },
                      onEvent: (event) {
                        if (event is ml.MapEventClick) {
                          _selectedGroupMember.value = null;
                          setState(() => _selectedWaypoint = null);
                        } else if (event is ml.MapEventStartMoveCamera &&
                            event.reason == ml.CameraChangeReason.apiGesture &&
                            _activePointers <= 1 &&
                            _followEnabled) {
                          // CameraChangeReason.apiGesture fires identically
                          // for pan/pinch/rotate (no native
                          // sub-classification exists); _activePointers <= 1
                          // is the compensating heuristic so only a
                          // single-finger drag breaks follow.
                          _onPanStart();
                        }
                      },
                      children: [
                        if (trailAsync.value?.expand?.gpx != null)
                          TrailMarkerLayer(
                            trail: trailAsync.value!,
                            selectedWaypoint: _selectedWaypoint,
                            onWaypointTap: _onWaypointSelected,
                          ),
                        _LiveCommunityMarkerLayer(
                          reports: _liveReports,
                          sosAlerts: _nearbySosAlerts,
                          groupSession: _groupSession,
                          selectedGroupMember: _selectedGroupMember,
                          userAlongTrackM: _liveTrackMeters,
                          userPosition: _currentPosition,
                          isRo: _isRo,
                          onReportTap: _onReportMarkerTapped,
                          onSosTap: _onSosMarkerTapped,
                          onGroupMemberTap: _onGroupMemberTapped,
                        ),
                        SalvamontMapLayer(
                          isRo: _isRo,
                          onRouteToPoint: _handleRouteToSalvamontBase,
                        ),
                        _LocationMarkerLayer(
                          position: _currentPosition,
                          headingListenable: _headingNotifier,
                          headingUp: _headingUp,
                          mapBearing: _mapBearing,
                        ),

                        Positioned(
                          top: widget.isRecording ? 8 : 128,
                          left: 8,
                          child: SafeArea(
                            child: const WandererMapScalebar(
                              alignment: Alignment.topLeft,
                            ),
                          ),
                        ),
                        WandererAttribution(
                          alignment: Alignment.bottomLeft,
                          padding: EdgeInsets.only(
                            left: 10,
                            bottom:
                                MediaQuery.of(context).size.height *
                                _kSheetMinSize,
                          ),
                        ), //
                        Positioned(
                          top: widget.isRecording ? 8 : 128,
                          right: 8,
                          child: SafeArea(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                WandererMapCompass(
                                  hideIfRotatedNorth: false,
                                  rotateNorthOnPressed: false,
                                  onPressed: () {
                                    // Continuous rotation via
                                    // [_bearingFollowTicker] is gated on
                                    // `_followEnabled && _headingUp` — without
                                    // re-enabling follow here, the transition
                                    // below would be the only rotation that
                                    // ever happens if follow was already (or
                                    // becomes) broken.
                                    setState(() {
                                      _headingUp = !_headingUp;
                                      if (_headingUp) _followEnabled = true;
                                    });
                                    _syncCompassSamplingRate();
                                    _syncBearingFollowTicker();
                                    // Animates via [_mapBearing]/[_pushCamera]
                                    // rather than a native `animateCamera` —
                                    // that native animation could get
                                    // interrupted/reset mid-flight by a
                                    // concurrent position-tick camera push,
                                    // occasionally leaving it stuck partway.
                                    _animateBearingTo(
                                      _headingUp ? (_smoothedHeading ?? 0) : 0,
                                    );
                                  },
                                ),
                                const SizedBox(height: 8),
                                IconButton(
                                  onPressed: _followEnabled
                                      ? null
                                      : _onRecenter,
                                  icon: FaIcon(
                                    FontAwesomeIcons.locationCrosshairs,
                                    size: 18,
                                    color: _followEnabled
                                        ? Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: 0.38)
                                        : Theme.of(
                                            context,
                                          ).colorScheme.onSurface,
                                  ),
                                  style: IconButton.styleFrom(
                                    backgroundColor: Theme.of(context)
                                        .colorScheme
                                        .surface
                                        .withValues(alpha: 0.94),
                                    disabledBackgroundColor: Theme.of(context)
                                        .colorScheme
                                        .surface
                                        .withValues(alpha: 0.94),
                                    side: BorderSide(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .outline
                                          .withValues(alpha: 0.55),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                ValueListenableBuilder<GroupSessionModel?>(
                                  valueListenable: _groupSession,
                                  builder: (context, group, _) {
                                    final theme = Theme.of(context);
                                    final count = group?.members.length ?? 0;
                                    return Stack(
                                      clipBehavior: Clip.none,
                                      children: [
                                        IconButton(
                                          key: const ValueKey('nav-group-btn'),
                                          tooltip: _isRo
                                              ? 'Grup live'
                                              : 'Live group',
                                          onPressed: () =>
                                              _openLiveGroupSheet(context),
                                          icon: Icon(
                                            Icons.group_outlined,
                                            color: theme.colorScheme.onSurface,
                                            size: 21,
                                          ),
                                          style: IconButton.styleFrom(
                                            backgroundColor: theme
                                                .colorScheme
                                                .surface
                                                .withValues(alpha: 0.94),
                                            side: BorderSide(
                                              color: theme.colorScheme.outline
                                                  .withValues(alpha: 0.55),
                                            ),
                                          ),
                                        ),
                                        if (count > 0)
                                          Positioned(
                                            right: 0,
                                            top: -2,
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 5,
                                                    vertical: 1.5,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: AppColors.primaryLight,
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                                border: Border.all(
                                                  color: Colors.white,
                                                  width: 1.5,
                                                ),
                                              ),
                                              child: Text(
                                                '$count',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    );
                                  },
                                ),
                                const SizedBox(height: 8),
                                IconButton(
                                  key: const ValueKey('nav-waze-report-btn'),
                                  tooltip: _isRo
                                      ? 'Raportează pe traseu'
                                      : 'Report on trail',
                                  onPressed: () =>
                                      _openWazeReportSheet(context),
                                  icon: Icon(
                                    Icons.add_location_alt_outlined,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface,
                                    size: 21,
                                  ),
                                  style: IconButton.styleFrom(
                                    backgroundColor: Theme.of(context)
                                        .colorScheme
                                        .surface
                                        .withValues(alpha: 0.94),
                                    side: BorderSide(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .outline
                                          .withValues(alpha: 0.55),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                IconButton(
                                  key: const ValueKey('nav-map-layers-btn'),
                                  tooltip: _isRo ? 'Straturi hartă' : 'Map layers',
                                  onPressed: () => showMapLayersSheet(context),
                                  icon: FaIcon(
                                    FontAwesomeIcons.layerGroup,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface,
                                    size: 18,
                                  ),
                                  style: IconButton.styleFrom(
                                    backgroundColor: Theme.of(context)
                                        .colorScheme
                                        .surface
                                        .withValues(alpha: 0.94),
                                    side: BorderSide(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .outline
                                          .withValues(alpha: 0.55),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                IconButton(
                                  key: const ValueKey('nav-peak-finder-btn'),
                                  tooltip: _isRo ? 'Ce vârf văd?' : 'Peak Finder',
                                  onPressed: () =>
                                      _openPeakFinderSheet(context),
                                  icon: Icon(
                                    Icons.landscape_outlined,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface,
                                    size: 21,
                                  ),
                                  style: IconButton.styleFrom(
                                    backgroundColor: Theme.of(context)
                                        .colorScheme
                                        .surface
                                        .withValues(alpha: 0.94),
                                    side: BorderSide(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .outline
                                          .withValues(alpha: 0.55),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                ValueListenableBuilder<SosAlertModel?>(
                                  valueListenable: _myActiveSos,
                                  builder: (context, mine, _) =>
                                      SosFloatingButton(
                                        isActive: mine != null,
                                        isRo: _isRo,
                                        onPressed: () =>
                                            _onSosButtonPressed(context),
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!widget.isRecording)
                            _buildBanner(
                              context,
                              localizations,
                              maneuvers,
                              currentIndex,
                              isArrived,
                              unit,
                            ),
                          _buildLiveSosOverlays(context),
                          ValueListenableBuilder<TrailSolarForecast?>(
                            valueListenable: _solarForecastNotifier,
                            builder: (context, forecast, _) {
                              final ridge = forecast?.finishRidgeSunset.ridgeSunset;
                              if (forecast == null ||
                                  ridge == null ||
                                  forecast.status ==
                                      LightSafetyStatus.daylightSafe) {
                                return const SizedBox.shrink();
                              }
                              final local = ridge.toLocal();
                              final hh = local.hour.toString().padLeft(2, '0');
                              final mm = local.minute.toString().padLeft(2, '0');
                              final Color pillBg = switch (forecast.status) {
                                LightSafetyStatus.nightDanger =>
                                  const Color(0xFFDC2626),
                                LightSafetyStatus.twilightWarning =>
                                  const Color(0xFFD97706),
                                LightSafetyStatus.ridgeShade =>
                                  const Color(0xFF92400E),
                                LightSafetyStatus.daylightSafe =>
                                  const Color(0xFF242734),
                              };
                              return Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Container(
                                  key: const ValueKey('ridge-sunset-warning'),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: pillBg.withValues(alpha: 0.92),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.wb_twilight,
                                        color: Colors.white,
                                        size: 15,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        _isRo
                                            ? 'Apus creastă $hh:$mm · frontala pregătită'
                                            : 'Ridge sunset $hh:$mm · pack headlamp',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),

                  Consumer(
                    builder: (context, ref, _) {
                      final showSlope = ref.watch(showAvalancheSlopeProvider);
                      final showShade = ref.watch(showSolarShadowsProvider);
                      if (!showSlope && !showShade) {
                        return const SizedBox.shrink();
                      }
                      final center =
                          _currentGeoFix() ??
                          _navTrackPoints.firstOrNull?.geographic ??
                          const ml.Geographic(lat: 45.4457, lon: 25.4563);
                      return Positioned(
                        left: 12,
                        bottom:
                            MediaQuery.of(context).size.height *
                                _kSheetMinSize +
                            14,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (showSlope) SlopeLegendPill(isRo: _isRo),
                            if (showSlope && showShade)
                              const SizedBox(height: 6),
                            if (showShade)
                              SolarTimeScrubberCard(
                                lat: center.lat,
                                lon: center.lon,
                                simulatedTime:
                                    _simulatedSolarTime ?? DateTime.now(),
                                onChanged: (nextTime) {
                                  setState(
                                    () => _simulatedSolarTime = nextTime,
                                  );
                                  final style = _loadedStyle;
                                  if (style != null) {
                                    unawaited(
                                      _syncTerrainIntelLayers(
                                        style,
                                        showAvalancheSlope: showSlope,
                                        showSolarShadows: showShade,
                                        solarTime: nextTime,
                                        center: center,
                                      ),
                                    );
                                  }
                                },
                              ),
                          ],
                        ),
                      );
                    },
                  ),

                  Positioned(
                    left: 16,
                    right: 16,
                    bottom:
                        MediaQuery.of(context).size.height * _kSheetMinSize +
                        10,
                    child: _buildNearbyWazePromptOverlay(context),
                  ),

                  _buildStatsSheet(context, localizations, trailAsync, unit),

                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: MediaQuery.of(context).padding.bottom,
                    child: _buildButtonRow(context, localizations),
                  ),

                  if (_selectedWaypoint != null)
                    WaypointSheet(
                      waypoint: _selectedWaypoint!,
                      user: user,
                      controller: _waypointSheetController,
                      onClose: () => setState(() => _selectedWaypoint = null),
                    ),
                ],
              ),
      ),
    );
  }

  void _confirmExit(BuildContext context, AppLocalizations localizations) {
    showDialog<_NavExitChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(
          widget.isRecording
              ? localizations.stop_recording_confirm
              : localizations.stop_navigation_confirm,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_NavExitChoice.cancel),
            child: Text(localizations.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_NavExitChoice.exit),
            child: Text(localizations.exit_navigation),
          ),
          if (_hasSavableTrack())
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(_NavExitChoice.saveTrack),
              child: Text(localizations.save_track),
            ),
        ],
      ),
    ).then((choice) {
      switch (choice) {
        case _NavExitChoice.saveTrack:
          if (context.mounted) _saveRecordedTrack(context);
        case _NavExitChoice.exit:
          // Deliberate exit — best-effort clear so no stale resume prompt
          // appears on next launch.
          active_nav.clear(_store);
          _breadcrumbSlab?.clear();
          if (context.mounted) {
            context.pop();
          }
        case _NavExitChoice.cancel:
        case null:
          // Cancel, or barrier dismiss — do nothing.
          break;
      }
    });
  }

  /// Maps a Valhalla maneuver type (0–38) to the closest Material icon.
  /// https://valhalla.github.io/valhalla/api/turn-by-turn/api-reference/#maneuver-types
  static IconData _iconForManeuverType(int type) => switch (type) {
    1 || 2 || 3 => Icons.navigation, // start / start-right / start-left
    4 || 5 || 6 => Icons.flag, // destination
    7 || 8 => Icons.straight, // becomes / continue
    9 => Icons.turn_slight_right,
    10 => Icons.turn_right,
    11 => Icons.turn_sharp_right,
    12 => Icons.u_turn_right,
    13 => Icons.u_turn_left,
    14 => Icons.turn_sharp_left,
    15 => Icons.turn_left,
    16 => Icons.turn_slight_left,
    17 || 22 => Icons.straight, // ramp straight / stay straight
    18 ||
    20 ||
    23 => Icons.turn_slight_right, // ramp-right / exit-right / stay-right
    19 ||
    21 ||
    24 => Icons.turn_slight_left, // ramp-left / exit-left / stay-left
    26 || 27 => Icons.roundabout_right, // roundabout enter / exit
    28 || 29 => Icons.directions_boat, // ferry
    37 => Icons.turn_slight_right, // merge right
    38 => Icons.turn_slight_left, // merge left
    _ => Icons.navigation,
  };

  Widget _buildBanner(
    BuildContext context,
    AppLocalizations localizations,
    List<NavigateManeuver> maneuvers,
    int currentIndex,
    bool isArrived,
    String unit,
  ) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<double?>(
      valueListenable: _farPreviewDistanceM,
      builder: (context, farDist, _) {
        return ValueListenableBuilder<OffTrailRerouteResult?>(
          valueListenable: _offTrailNotifier,
          builder: (context, reroute, _) {
            return Card(
              key: const ValueKey('nav-banner'),
              elevation: 3,
              shadowColor: Colors.black.withValues(alpha: 0.14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: theme.colorScheme.outline.withValues(alpha: 0.55),
                ),
              ),
              color: theme.colorScheme.surface.withValues(alpha: 0.95),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14.0,
                  vertical: 10.0,
                ),
                child: (reroute != null && farDist == null)
                    ? _buildOffTrailBannerContent(
                        context,
                        reroute,
                        unit,
                      )
                    : (isArrived
                          ? _buildCompletionBannerContent(
                              context,
                              localizations,
                            )
                          : _buildActiveBannerContent(
                              context,
                              localizations,
                              maneuvers,
                              currentIndex,
                              unit,
                            )),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildOffTrailBannerContent(
    BuildContext context,
    OffTrailRerouteResult reroute,
    String unit,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final distText = formatDistance(reroute.distanceM, unit: unit);
    final climbPart = reroute.ascentM >= 3.0
        ? ' · +${reroute.ascentM.round()} m'
        : '';
    final headline = _isRo
        ? '$distText până la potecă$climbPart'
        : '$distText to trail$climbPart';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ValueListenableBuilder<double?>(
          valueListenable: _headingNotifier,
          builder: (context, liveHeading, _) {
            final heading = liveHeading ?? _smoothedHeading ?? 0.0;
            final relDeg = shortestAngleDelta(
              heading,
              reroute.initialBearingDeg,
            );
            return Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: const Color(0xFFD97706).withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: Transform.rotate(
                  angle: relDeg * pi / 180.0,
                  child: Icon(
                    Icons.navigation_rounded,
                    color: isDark
                        ? const Color(0xFFFCD34D)
                        : const Color(0xFFB45309),
                    size: 20,
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                headline,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w800,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                reroute.instruction,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildActiveBannerContent(
    BuildContext context,
    AppLocalizations localizations,
    List<NavigateManeuver> maneuvers,
    int currentIndex,
    String unit,
  ) {
    if (maneuvers.isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final safeIndex = currentIndex.clamp(0, maneuvers.length - 1);
    final maneuver = maneuvers[safeIndex];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppColors.primaryLight,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Icon(
            _iconForManeuverType(maneuver.type),
            color: Colors.white,
            size: 20,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                maneuver.instruction,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                localizations.in_distance(
                  formatDistance(maneuver.length * 1000, unit: unit),
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
        if (!ref.watch(onlineStatusProvider)) ...[
          const SizedBox(width: 8),
          Icon(
            Icons.cloud_off,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
            size: 19,
          ),
        ],
      ],
    );
  }

  Widget _buildCompletionBannerContent(
    BuildContext context,
    AppLocalizations localizations,
  ) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.primaryLight,
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.flag_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    localizations.you_have_arrived,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    localizations.reached_end_of_trail,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (_hasSavableTrack()) ...[
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _savingTrack ? null : () => _saveRecordedTrack(context),
            icon: _savingTrack
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const FaIcon(FontAwesomeIcons.floppyDisk, size: 16),
            label: Text(localizations.save_track),
          ),
        ],
      ],
    );
  }

  Widget _buildStatsSheet(
    BuildContext context,
    AppLocalizations localizations,
    AsyncValue<Trail> trailAsync,
    String unit,
  ) {
    final theme = Theme.of(context);
    final maxSize = _sheetAtElevationSize
        ? _elevationSheetSize
        : _kSheetStatsSize;

    return DraggableScrollableSheet(
      controller: _sheetController,
      initialChildSize: _kSheetMinSize,
      minChildSize: _kSheetMinSize,
      maxChildSize: maxSize,
      snap: true,
      snapSizes: [_kSheetMinSize, maxSize],
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: theme.canvasColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 10,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: SingleChildScrollView(
            controller: scrollController,
            // Scoped stats watch: the 1 Hz tick and per-fix stat updates
            // rebuild only this sheet content, never the screen (see the
            // build() comment where the whole-state watches used to live).
            child: Consumer(
              builder: (context, ref, _) {
                final stats = ref.watch(_statsProviderInstance);
                return _buildStatsSheetContent(
                  context,
                  localizations,
                  stats,
                  trailAsync,
                  unit,
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildStatsSheetContent(
    BuildContext context,
    AppLocalizations localizations,
    NavigationStats stats,
    AsyncValue<Trail> trailAsync,
    String unit,
  ) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Drag handle.
        Center(
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),

        // Always-visible top stats row.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Row(
            children: [
              _buildStatCell(
                context,
                localizations.time_in_motion,
                formatElapsed(stats.elapsed),
              ),
              _buildStatCell(
                context,
                localizations.distance,
                formatDistance(stats.distanceMeters, unit: unit),
              ),
              _buildStatCell(
                context,
                localizations.elevation_gain,
                formatElevation(stats.elevationGainMeters, unit: unit),
              ),
            ],
          ),
        ),

        ValueListenableBuilder<int?>(
          valueListenable: _activeHikers30m,
          builder: (context, activeCount, _) {
            if (activeCount == null || activeCount <= 0) {
              return const SizedBox.shrink();
            }
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: ActiveHikersBadge(
                  countOverride: activeCount,
                  compact: true,
                ),
              ),
            );
          },
        ),

        if (!widget.isRecording)
          _buildNavigationContextStrip(context, localizations, unit),

        // Additional content fades in as the sheet expands.
        AnimatedBuilder(
          animation: _sheetController,
          builder: (ctx, child) {
            final targetSize = _showingElevation
                ? _elevationSheetSize
                : _kSheetStatsSize;
            final t = _sheetController.isAttached
                ? ((_sheetController.size - _kSheetMinSize) /
                          (targetSize - _kSheetMinSize))
                      .clamp(0.0, 1.0)
                : (_showingElevation ? 1.0 : 0.0);
            return Opacity(opacity: t, child: child);
          },
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: _showingElevation
                ? (widget.isRecording
                      ? SizedBox(
                          key: const ValueKey('elevation'),
                          height: 216,
                          child: _buildElevationPage(context, trailAsync),
                        )
                      : Column(
                          key: const ValueKey('elevation'),
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildTripSummaryRow(context, localizations, unit),
                            SizedBox(
                              height: 196,
                              child: _buildElevationPage(context, trailAsync),
                            ),
                          ],
                        ))
                : SizedBox(
                    key: const ValueKey('stats'),
                    child: _buildAdditionalStats(
                      context,
                      localizations,
                      stats,
                      unit,
                    ),
                  ),
          ),
        ),

        // Clearance so content does not hide behind the button overlay.
        const SizedBox(height: 80),
      ],
    );
  }

  Widget _buildNavigationContextStrip(
    BuildContext context,
    AppLocalizations localizations,
    String unit,
  ) {
    final theme = Theme.of(context);
    final expeditionEnabled = ref.watch(expeditionBatteryModeProvider);
    return ValueListenableBuilder<MountainPowerState>(
      valueListenable: _powerStateNotifier,
      builder: (context, powerState, _) {
        final isCabanaSleep =
            powerState == MountainPowerState.stationaryCabanaSleep;
        return ValueListenableBuilder<double?>(
          valueListenable: _farPreviewDistanceM,
          builder: (context, farDist, _) {
            return ValueListenableBuilder<OffTrailRerouteResult?>(
              valueListenable: _offTrailNotifier,
              builder: (context, reroute, _) {
                return ValueListenableBuilder<GpsSignalState>(
                  valueListenable: _gpsSignalState,
                  builder: (context, sigState, _) {
                    return ValueListenableBuilder<double>(
                      valueListenable: _effectiveGpsAccuracy,
                      builder: (context, effAcc, _) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (isCabanaSleep)
                                Container(
                                  key: const ValueKey(
                                    'nav-stationary-sleep-pill',
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primaryContainer
                                        .withValues(alpha: 0.85),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    _isRo
                                        ? '💤 Popas activ · GPS în repaus (repornește la primii pași)'
                                        : '💤 Rest sleep · GPS paused (wakes on first step)',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              _buildContextModeChip(
                                context,
                                key: const ValueKey('nav-expedition-mode-chip'),
                                label: _isRo
                                    ? '🔋 Mod Expediție'
                                    : '🔋 Expedition Mode',
                                selected: expeditionEnabled,
                                onTap: () {
                                  unawaited(
                                    ref
                                        .read(localSettingsProvider.notifier)
                                        .setExpeditionBatteryMode(
                                          !expeditionEnabled,
                                        ),
                                  );
                                },
                              ),
                              if (farDist != null) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.06,
                                ),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: theme.colorScheme.outline.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                              ),
                              child: Text(
                                _isRo
                                    ? 'La ${formatDistance(farDist, unit: unit)} de start · Mod previzualizare'
                                    : '${formatDistance(farDist, unit: unit)} from start · Preview mode',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            ValueListenableBuilder<bool>(
                              valueListenable: _accessRouteLoading,
                              builder: (context, loading, _) {
                                return OutlinedButton.icon(
                                  key: const ValueKey('nav-access-route-btn'),
                                  style: OutlinedButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  onPressed: loading
                                      ? null
                                      : _toggleFarPreviewAccessRoute,
                                  icon: loading
                                      ? const SizedBox(
                                          width: 12,
                                          height: 12,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 1.8,
                                          ),
                                        )
                                      : Icon(
                                          _showingAccessRoute
                                              ? Icons.visibility_off_outlined
                                              : Icons.alt_route_rounded,
                                          size: 14,
                                        ),
                                  label: Text(
                                    _showingAccessRoute
                                        ? (_isRo
                                              ? 'Ascunde ruta'
                                              : 'Hide route')
                                        : (_isRo
                                              ? 'Rută de acces'
                                              : 'Access route'),
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                          if (reroute != null && farDist == null) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFFD97706,
                                ).withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                _isRo
                                    ? 'Abatere · +${reroute.ascentM.round()} m'
                                    : 'Detour · +${reroute.ascentM.round()} m',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.brightness == Brightness.dark
                                      ? const Color(0xFFFCD34D)
                                      : const Color(0xFF92400E),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            _buildContextModeChip(
                              context,
                              key: const ValueKey('offtrail-mode-min-climb'),
                              label: localizations.nav_min_climb,
                              selected: reroute.mode == OffTrailMode.minClimb,
                              onTap: () =>
                                  _selectOffTrailMode(OffTrailMode.minClimb),
                            ),
                            _buildContextModeChip(
                              context,
                              key: const ValueKey(
                                'offtrail-mode-shortest-safe',
                              ),
                              label: _isRo
                                  ? 'Drum scurt'
                                  : localizations.nav_shortest_path,
                              selected:
                                  reroute.mode == OffTrailMode.shortestSafe,
                              onTap: () => _selectOffTrailMode(
                                OffTrailMode.shortestSafe,
                              ),
                            ),
                          ],
                          if (sigState == GpsSignalState.degraded ||
                              sigState == GpsSignalState.coasting)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.06,
                                ),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: theme.colorScheme.outline.withValues(
                                    alpha: 0.45,
                                  ),
                                ),
                              ),
                              child: Text(
                                _isRo
                                    ? 'GPS slab · estimat după ritm'
                                    : 'Weak GPS · pace estimated',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurface.withValues(
                                    alpha: 0.8,
                                  ),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            )
                          else if (sigState == GpsSignalState.cooperative)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.06,
                                ),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: theme.colorScheme.outline.withValues(
                                    alpha: 0.45,
                                  ),
                                ),
                              ),
                              child: Text(
                                _isRo
                                    ? 'GPS grup · ±${effAcc.round()} m'
                                    : 'Group GPS · ±${effAcc.round()} m',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurface.withValues(
                                    alpha: 0.8,
                                  ),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
      },
    );
  }

  Widget _buildContextModeChip(
    BuildContext context, {
    required Key key,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final selectedBg = theme.brightness == Brightness.dark
        ? theme.colorScheme.primary
        : AppColors.primaryLight;
    return Material(
      color: selected
          ? selectedBg
          : theme.colorScheme.onSurface.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          child: Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: selected
                  ? Colors.white
                  : theme.colorScheme.onSurface.withValues(alpha: 0.82),
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTripSummaryRow(
    BuildContext context,
    AppLocalizations localizations,
    String unit,
  ) {
    return ValueListenableBuilder<EtaSnapshot?>(
      valueListenable: _etaNotifier,
      builder: (context, eta, _) {
        final theme = Theme.of(context);
        final remTimeText = eta == null
            ? '—'
            : _formatCompactDuration(eta.remainingDuration);
        final arrivalText = eta?.arrivalTimeFormatted ?? '—';
        final remDistText = eta == null
            ? '—'
            : formatDistance(eta.remainingDistanceM, unit: unit);
        final remClimbText = eta == null
            ? '—'
            : '+${formatElevation(eta.remainingAscentM, unit: unit)}';

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.45,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                _buildTripSummaryCell(
                  context,
                  localizations.nav_remaining,
                  remTimeText,
                ),
                _buildTripSummaryCell(
                  context,
                  localizations.nav_arrival,
                  arrivalText,
                ),
                _buildTripSummaryCell(
                  context,
                  localizations.distance,
                  remDistText,
                ),
                _buildTripSummaryCell(
                  context,
                  localizations.nav_climb_left,
                  remClimbText,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTripSummaryCell(
    BuildContext context,
    String label,
    String value,
  ) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  String _formatCompactDuration(Duration d) {
    final totalMinutes = d.inSeconds <= 0
        ? 0
        : max(1, (d.inSeconds / 60).round());
    if (totalMinutes < 60) {
      return '$totalMinutes min';
    }
    final hours = totalMinutes ~/ 60;
    final mins = totalMinutes % 60;
    return mins == 0
        ? '${hours}h'
        : '${hours}h ${mins.toString().padLeft(2, '0')}m';
  }

  Widget _buildAdditionalStats(
    BuildContext context,
    AppLocalizations localizations,
    NavigationStats stats,
    String unit,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Row(
            children: [
              _buildStatCell(
                context,
                localizations.elevation_loss,
                formatElevation(stats.elevationLossMeters, unit: unit),
              ),
              _buildStatCell(
                context,
                localizations.speed,
                formatSpeed(stats.currentSpeedKmh, unit: unit),
              ),
              _buildStatCell(
                context,
                localizations.average_speed,
                formatSpeed(stats.averageSpeedKmh, unit: unit),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatCell(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  /// Page 1: the reused [ElevationProfile] chart with a top-left back control
  /// returning to the stats page. The map behind the sheet stays interactive.
  ///
  /// Recording mode has no saved trail/GPX to profile (`trailProvider('')`
  /// would resolve to AsyncError) — it builds a LIVE `Gpx` from the
  /// in-progress `navState.breadcrumb` instead, via the same
  /// [buildGpxFromPoints] helper `_saveRecordedTrack` uses for the identical
  /// breadcrumb. Scoped in its own [Consumer] selecting `breadcrumbLength`
  /// (never `breadcrumb` itself — see [NavigationState.breadcrumb]'s
  /// stable-identity doc comment, a `select` on the list would never fire)
  /// so only this page rebuilds per GPS fix, not the whole screen — mirrors
  /// every other scoped watch in this file (see the build() comment on
  /// whole-state watches).
  Widget _buildElevationPage(
    BuildContext context,
    AsyncValue<Trail> trailAsync,
  ) {
    if (widget.isRecording) {
      return Consumer(
        builder: (context, ref, _) {
          // Both watches are deliberately COARSE. Every rebuild of this
          // subtree costs two full O(n) passes over the whole recording so
          // far — buildElevationTrackPoints (via didUpdateWidget) and
          // computeTrailMetrics (in ElevationProfile.build, since trail is
          // null here) — each with a haversine per point. Measured at 1 Hz
          // recording: ~11 ms per rebuild at 4 h of track on a desktop, so
          // several times that on a phone, on the UI thread, growing with
          // recording length. Rebuilding per GPS fix (and, worse, per
          // stats-clock tick) made the chart page the most expensive thing
          // on screen late in a hike, for pixels that did not change.
          ref.watch(
            _navProviderInstance.select(
              (s) => liveElevationChartRevision(s.breadcrumbLength),
            ),
          );
          // The header renders this at DurationTersity.minute, so watching
          // whole minutes produces byte-identical output while dropping 59
          // of every 60 rebuilds. Watching `elapsed` itself would rebuild
          // once a second regardless of the stride above, since the stats
          // clock ticks independently of GPS.
          final elapsedMinutes = ref.watch(
            _statsProviderInstance.select((s) => s.elapsed.inMinutes),
          );

          final live = ref.read(_navProviderInstance).breadcrumb;
          // Length-checked BEFORE copying, so the not-enough-points case
          // costs nothing. (This used to read `gpx.allPoints.length`, which
          // allocated a fresh Geographic per recorded point just to compare
          // a count.)
          if (live.length < 2) {
            return const SizedBox.shrink();
          }
          // SNAPSHOT, not the live view. `breadcrumb` is an identity-stable
          // UnmodifiableListView over a grow-in-place list, so feeding it
          // straight in makes every rebuild's Gpx wrap the SAME list instance
          // as the previous one — and gpx 2.3.0's Gpx/Trkseg `==` delegates to
          // ListEquality, which short-circuits on `identical`. The two Gpx
          // objects would compare EQUAL no matter how many fixes arrived, so
          // ElevationProfile.didUpdateWidget would never re-parse and the
          // chart would freeze at its first two points. Copying gives each
          // rebuild a distinct list whose differing length fails that
          // equality check cheaply (length is compared before any element).
          final gpx = buildGpxFromPoints(List<Wpt>.of(live));
          return Padding(
            padding: const EdgeInsets.all(16.0),
            child: ElevationProfile(
              trail: null,
              gpx: gpx,
              enableLineTouch: false,
              durationOverride: Duration(minutes: elapsedMinutes),
            ),
          );
        },
      );
    }
    return trailAsync.when(
      data: (trail) {
        final gpx = trail.expand?.gpx;
        if (gpx == null) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: ElevationProfile(
            trail: trail,
            gpx: gpx,
            chartHeight: 140,
            enableLineTouch: false,
            livePositionMeters: _liveTrackMeters,
            splitLiveProgress: true,
            offTrailPreviewSpots: _offTrailChartSpots,
          ),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text(
          AppLocalizations.of(context)!.error_reading_file,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
    );
  }

  /// Dominant Pause/Resume, icon-only FAB — shared verbatim between nav mode
  /// (center slot) and recording mode (left slot). Reflects only the manual
  /// [NavigationStats.isPaused] flag — isStationary (auto-freeze by
  /// tracelet's motion engine) still freezes the timer/breadcrumb but must
  /// not flip this button to its "paused" state, since the user never asked
  /// to pause and onPressed always toggles the manual flag regardless of
  /// isStationary.
  Widget _buildPauseFab(AppLocalizations localizations) {
    // Scoped isPaused watch — the FAB flips on pause toggles without the
    // screen watching the whole (1 Hz-ticking) stats state.
    return Consumer(
      builder: (context, ref, _) {
        final isPaused = ref.watch(
          _statsProviderInstance.select((s) => s.isPaused),
        );
        return FloatingActionButton(
          heroTag: 'nav_pause',
          tooltip: isPaused ? localizations.resume : localizations.pause,
          elevation: 2,
          shape: StadiumBorder(),
          onPressed: () {
            _statsNotifier.togglePause();
            _persistNow();
          },
          child: FaIcon(
            isPaused ? FontAwesomeIcons.play : FontAwesomeIcons.pause,
          ),
        );
      },
    );
  }

  /// Toggle between additional stats and elevation profile — unchanged
  /// between nav and recording mode, always the right-most button.
  Widget _buildElevationFab(AppLocalizations localizations) {
    return FloatingActionButton.small(
      heroTag: 'nav_elevation',
      tooltip: localizations.elevation_profile,
      shape: const StadiumBorder(),
      elevation: 2,
      backgroundColor: Theme.of(context).colorScheme.surface,
      onPressed: () {
        if (!_showingElevation) {
          // Stats → elevation: raise ceiling first, then expand + switch.
          setState(() {
            _sheetAtElevationSize = true;
            _showingElevation = true;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _sheetController.animateTo(
                _elevationSheetSize,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
              );
            }
          });
        } else {
          // Elevation → stats: switch content + shrink simultaneously;
          // lower the ceiling only after the animation completes so the
          // sheet is never clamped mid-animation.
          setState(() => _showingElevation = false);
          _sheetController.animateTo(
            _kSheetStatsSize,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
          Future.delayed(const Duration(milliseconds: 300), () {
            if (mounted) setState(() => _sheetAtElevationSize = false);
          });
        }
      },
      child: FaIcon(
        _showingElevation
            ? FontAwesomeIcons.chartSimple
            : FontAwesomeIcons.chartArea,
        color: Theme.of(context).colorScheme.onSurface,
        size: 18,
      ),
    );
  }

  Widget _buildButtonRow(BuildContext context, AppLocalizations localizations) {
    if (widget.isRecording) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            // Left — Pause/Resume toggle.
            _buildPauseFab(localizations),

            // Center — dominant red Stop button; the ONLY finish trigger for
            // a recording session (isArrived is structurally always false
            // with empty maneuvers, so there is no auto-arrival banner).
            FloatingActionButton(
              heroTag: 'rec_stop',
              tooltip: localizations.stop_recording,
              elevation: 2,
              shape: StadiumBorder(),
              backgroundColor: Colors.redAccent,
              onPressed: _savingTrack
                  ? null
                  : () => _confirmExit(context, localizations),
              child: _savingTrack
                  ? SizedBox(
                      height: 24,
                      width: 24,
                      child: const CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const FaIcon(FontAwesomeIcons.stop),
            ),

            // Right — toggle between additional stats and elevation profile.
            _buildElevationFab(localizations),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          // Left — Exit prompts for confirmation before popping.
          FloatingActionButton.small(
            heroTag: 'nav_exit',
            tooltip: localizations.exit_navigation,
            elevation: 2,
            shape: StadiumBorder(),
            backgroundColor: Theme.of(context).colorScheme.surface,
            onPressed: () => _confirmExit(context, localizations),
            child: FaIcon(
              FontAwesomeIcons.xmark,
              color: Theme.of(context).colorScheme.onSurface,
              size: 18,
            ),
          ),

          // Center — dominant Pause/Resume.
          _buildPauseFab(localizations),

          // Right — toggle between additional stats and elevation profile.
          _buildElevationFab(localizations),
        ],
      ),
    );
  }

  Widget _buildLiveSosOverlays(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final isOnline = ref.watch(onlineStatusProvider);
        return ValueListenableBuilder<bool>(
          valueListenable: _liveActionBusy,
          builder: (context, isBusy, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ValueListenableBuilder<SosAlertModel?>(
                  valueListenable: _myActiveSos,
                  builder: (context, mine, _) {
                    if (mine == null) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: MyActiveSosBanner(
                        sos: mine,
                        isOnline: isOnline,
                        isSubmitting: isBusy,
                        isRo: _isRo,
                        onResolve: () => _handleResolveMySos(mine),
                      ),
                    );
                  },
                ),
            ValueListenableBuilder<List<SosAlertModel>>(
              valueListenable: _nearbySosAlerts,
              builder: (context, alerts, _) {
                if (alerts.isEmpty) return const SizedBox.shrink();
                final target =
                    alerts.firstWhereOrNull((s) => s.amResponding) ??
                    alerts.first;
                return ValueListenableBuilder<OffTrailRerouteResult?>(
                  valueListenable: _rescueRouteNotifier,
                  builder: (context, rescueRoute, _) {
                    return ValueListenableBuilder<LocationMarkerPosition?>(
                      valueListenable: _currentPosition,
                      builder: (context, markerPos, _) {
                        double? directDist;
                        if (markerPos != null) {
                          directDist = ml.SphericalGreatCircle(
                            ml.Geographic(
                              lat: markerPos.latitude,
                              lon: markerPos.longitude,
                            ),
                          ).distanceTo(
                            ml.Geographic(lat: target.lat, lon: target.lon),
                          );
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: NearbySosResponderBanner(
                            sos: target,
                            directDistanceMeters: directDist,
                            rescueRoute: target.amResponding
                                ? rescueRoute
                                : null,
                            userHeadingDeg:
                                markerPos?.heading ?? _smoothedHeading,
                            isOnline: isOnline,
                            isSubmitting: isBusy,
                            isRo: _isRo,
                            onRespondComing: () => _handleRespondComing(target),
                            onCancelRespond: () => _handleCancelRespond(target),
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ],
        );
      },
    );
      },
    );
  }

  Widget _buildNearbyWazePromptOverlay(BuildContext context) {
    return ValueListenableBuilder<
      ({TrailReportModel report, double? distanceM})?
    >(
      valueListenable: _nearbyPromptReport,
      builder: (context, entry, _) {
        if (entry == null) return const SizedBox.shrink();
        return ValueListenableBuilder<bool>(
          valueListenable: _liveActionBusy,
          builder: (context, isBusy, _) {
            return WazeNearbyPrompt(
              report: entry.report,
              distanceMeters: entry.distanceM,
              isSubmitting: isBusy,
              isRo: _isRo,
              serverBaseUrl: ref.read(apiProvider).options.baseUrl,
              onVote: (vote) => _handleVoteReport(entry.report, vote),
              onClose: () {
                _snoozedOrVotedReportIds.add(entry.report.id);
                if (_pinnedPromptReportId == entry.report.id) {
                  _pinnedPromptReportId = null;
                }
                _nearbyPromptReport.value = null;
              },
            );
          },
        );
      },
    );
  }
}

class _RelativeConeHeadingListenable extends ValueNotifier<double?> {
  _RelativeConeHeadingListenable(
    this._source, {
    required bool headingUp,
    required double effectiveBearing,
  }) : _headingUp = headingUp,
       _effectiveBearing = effectiveBearing,
       super(_compute(_source.value, headingUp, effectiveBearing)) {
    _source.addListener(_onSourceChanged);
  }

  final ValueListenable<double?> _source;
  bool _headingUp;
  double _effectiveBearing;

  static double? _compute(
    double? raw,
    bool headingUp,
    double effectiveBearing,
  ) {
    if (headingUp) return 0.0;
    if (raw == null || !raw.isFinite) return null;
    return normalizeHeading(raw - effectiveBearing);
  }

  void updateCamera({required bool headingUp, required double effectiveBearing}) {
    if (_headingUp == headingUp &&
        (_effectiveBearing - effectiveBearing).abs() < 0.25) {
      return;
    }
    _headingUp = headingUp;
    _effectiveBearing = effectiveBearing;
    value = _compute(_source.value, _headingUp, _effectiveBearing);
  }

  void _onSourceChanged() {
    value = _compute(_source.value, _headingUp, _effectiveBearing);
  }

  @override
  void dispose() {
    _source.removeListener(_onSourceChanged);
    super.dispose();
  }
}

/// Custom location marker replacing the native MapLibre location puck, sized
/// at `96x96` (`48px` radius) so `_FlashlightConePainter`'s directional beam
/// extends cleanly beyond the `20px` blue dot on both light and dark tiles.
class _LocationMarkerLayer extends StatefulWidget {
  const _LocationMarkerLayer({
    required this.position,
    required this.headingListenable,
    required this.headingUp,
    this.mapBearing = 0.0,
  });

  final ValueNotifier<LocationMarkerPosition?> position;
  final ValueListenable<double?> headingListenable;
  final bool headingUp;
  final double mapBearing;

  @override
  State<_LocationMarkerLayer> createState() => _LocationMarkerLayerState();
}

class _LocationMarkerLayerState extends State<_LocationMarkerLayer> {
  late _RelativeConeHeadingListenable _coneHeading;

  @override
  void initState() {
    super.initState();
    _coneHeading = _RelativeConeHeadingListenable(
      widget.headingListenable,
      headingUp: widget.headingUp,
      effectiveBearing: widget.mapBearing,
    );
  }

  @override
  void didUpdateWidget(covariant _LocationMarkerLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.headingListenable != widget.headingListenable) {
      _coneHeading.dispose();
      _coneHeading = _RelativeConeHeadingListenable(
        widget.headingListenable,
        headingUp: widget.headingUp,
        effectiveBearing: widget.mapBearing,
      );
    }
  }

  @override
  void dispose() {
    _coneHeading.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveBearing =
        ml.MapCamera.maybeOf(context)?.bearing ?? widget.mapBearing;
    _coneHeading.updateCamera(
      headingUp: widget.headingUp,
      effectiveBearing: effectiveBearing,
    );
    return ValueListenableBuilder<LocationMarkerPosition?>(
      valueListenable: widget.position,
      builder: (context, pos, _) {
        if (pos == null) return const SizedBox.shrink();
        return ml.WidgetLayer(
          markers: [
            ml.Marker(
              point: ml.Geographic(lat: pos.latitude, lon: pos.longitude),
              size: const Size(96, 96),
              child: LocationPuck(
                size: 96,
                dotSize: 20,
                headingListenable: _coneHeading,
                headingAccuracy: pos.headingAccuracy,
                showHeading: true,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Renders active community Waze reports, permanent landmarks, nearby SOS
/// emergency pins, and live hiking group friends on the navigation map using
/// [ScreenMarkerLayer] (`projectBatched` $O(1)$ camera-frame cost).
class _LiveCommunityMarkerLayer extends StatefulWidget {
  const _LiveCommunityMarkerLayer({
    required this.reports,
    required this.sosAlerts,
    required this.groupSession,
    required this.selectedGroupMember,
    required this.userAlongTrackM,
    required this.userPosition,
    required this.isRo,
    required this.onReportTap,
    required this.onSosTap,
    required this.onGroupMemberTap,
  });

  final ValueNotifier<List<TrailReportModel>> reports;
  final ValueNotifier<List<SosAlertModel>> sosAlerts;
  final ValueNotifier<GroupSessionModel?> groupSession;
  final ValueNotifier<GroupMemberModel?> selectedGroupMember;
  final ValueNotifier<double?> userAlongTrackM;
  final ValueNotifier<LocationMarkerPosition?> userPosition;
  final bool isRo;
  final ValueChanged<TrailReportModel> onReportTap;
  final ValueChanged<SosAlertModel> onSosTap;
  final ValueChanged<GroupMemberModel> onGroupMemberTap;

  @override
  State<_LiveCommunityMarkerLayer> createState() =>
      _LiveCommunityMarkerLayerState();
}

class _LiveCommunityMarkerLayerState extends State<_LiveCommunityMarkerLayer> {
  List<TrailReportModel>? _lastReports;
  List<SosAlertModel>? _lastSos;
  GroupSessionModel? _lastSession;
  GroupMemberModel? _lastSelectedFriend;
  bool? _lastIsRo;
  Brightness? _lastBrightness;
  List<ml.Marker> _cachedMarkers = const <ml.Marker>[];

  List<ml.Marker> _resolveMarkers(
    ThemeData theme,
    List<TrailReportModel> reportList,
    List<SosAlertModel> sosList,
    GroupSessionModel? session,
    GroupMemberModel? selectedFriend,
  ) {
    if (identical(_lastReports, reportList) &&
        identical(_lastSos, sosList) &&
        identical(_lastSession, session) &&
        identical(_lastSelectedFriend, selectedFriend) &&
        _lastIsRo == widget.isRo &&
        _lastBrightness == theme.brightness) {
      return _cachedMarkers;
    }

    _lastReports = reportList;
    _lastSos = sosList;
    _lastSession = session;
    _lastSelectedFriend = selectedFriend;
    _lastIsRo = widget.isRo;
    _lastBrightness = theme.brightness;

    final peers = session?.peers ?? const <GroupMemberModel>[];
    final userPosVal = widget.userPosition.value;
    final userGeo = userPosVal != null
        ? ml.Geographic(lat: userPosVal.latitude, lon: userPosVal.longitude)
        : null;

    _cachedMarkers = <ml.Marker>[
      for (final report in reportList)
        ml.Marker(
          point: ml.Geographic(lat: report.lat, lon: report.lon),
          size: const Size(38, 38),
          child: GestureDetector(
            key: ValueKey<String>('rep-${report.id}'),
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onReportTap(report),
            child: Opacity(
              opacity: report.isDryOrClosed ? 0.65 : 1.0,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: categoryAccentColor(report.category),
                    width: 2.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.28),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: Text(
                  report.category.emoji,
                  style: const TextStyle(fontSize: 18),
                ),
              ),
            ),
          ),
        ),
      for (final friend in peers)
        ml.Marker(
          point: ml.Geographic(lat: friend.lat, lon: friend.lon),
          size: selectedFriend?.memberId == friend.memberId
              ? const Size(164, 62)
              : const Size(36, 36),
          child: GestureDetector(
            key: ValueKey<String>('peer-${friend.memberId}'),
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onGroupMemberTap(friend),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (selectedFriend?.memberId == friend.memberId)
                  Container(
                    margin: const EdgeInsets.only(bottom: 3),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface.withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: theme.colorScheme.outline.withValues(alpha: 0.55),
                      ),
                    ),
                    child: Text(
                      () {
                        final rel = formatRelativeGroupDistance(
                          member: friend,
                          userAlongTrackM: widget.userAlongTrackM.value,
                          userPos: userGeo,
                          isRo: widget.isRo,
                        );
                        final restSuffix = friend.isStationary ? ' · 💤' : '';
                        return rel.isNotEmpty
                            ? '${friend.displayName} · $rel$restSuffix'
                            : '${friend.displayName}$restSuffix';
                      }(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontSize: 10.5,
                      ),
                    ),
                  ),
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: parseGroupHexColor(friend.colorHex),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2.5),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.25),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    friend.isStationary ? '💤' : friend.initials,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      for (final sos in sosList)
        ml.Marker(
          point: ml.Geographic(lat: sos.lat, lon: sos.lon),
          size: const Size(46, 46),
          child: GestureDetector(
            key: ValueKey<String>('sos-${sos.id}'),
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onSosTap(sos),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFDC2626),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFDC2626).withValues(alpha: 0.55),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: const Text('🆘', style: TextStyle(fontSize: 20)),
            ),
          ),
        ),
    ];
    return _cachedMarkers;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<List<TrailReportModel>>(
      valueListenable: widget.reports,
      builder: (context, reportList, _) {
        return ValueListenableBuilder<List<SosAlertModel>>(
          valueListenable: widget.sosAlerts,
          builder: (context, sosList, _) {
            return ValueListenableBuilder<GroupSessionModel?>(
              valueListenable: widget.groupSession,
              builder: (context, session, _) {
                return ValueListenableBuilder<GroupMemberModel?>(
                  valueListenable: widget.selectedGroupMember,
                  builder: (context, selectedFriend, _) {
                    final markers = _resolveMarkers(
                      theme,
                      reportList,
                      sosList,
                      session,
                      selectedFriend,
                    );
                    if (markers.isEmpty) return const SizedBox.shrink();
                    return ScreenMarkerLayer(markers: markers);
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}
