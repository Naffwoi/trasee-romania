import 'dart:async';
import 'dart:math' as math;

class RadioBurstContext {
  const RadioBurstContext({
    required this.reason,
    required this.isStationary,
    required this.sosActive,
    required this.includeHeartbeat,
  });

  final String reason;
  final bool isStationary;
  final bool sosActive;
  final bool includeHeartbeat;
}

/// Coalesces all `/api/v1/live/*` HTTP traffic (group ping, trail heartbeat,
/// and SOS/relay outbox flush) into a single cellular RRC_CONNECTED window,
/// eliminating 7–12s LTE/3G tail energy waste between uncoordinated timers and
/// replacing the 6s offline group connect storm with jittered backoff.
class RadioSyncScheduler {
  RadioSyncScheduler({
    required this.onCoalescedBurst,
    DateTime Function()? clock,
    math.Random? random,
    this.jitterFactor = 0.15,
  }) : _clock = clock ?? DateTime.now,
       _rng = random ?? math.Random();

  final Future<bool> Function(RadioBurstContext context) onCoalescedBurst;
  final DateTime Function() _clock;
  final math.Random _rng;
  final double jitterFactor;

  Timer? _timer;
  bool _started = false;
  bool _disposed = false;
  bool _inFlight = false;

  bool _isOnline = true;
  bool _uiForeground = true;
  bool _hasActiveGroup = false;
  bool _isStationary = false;
  bool _expeditionMode = false;
  bool _sosActive = false;

  int _consecutiveFailures = 0;
  DateTime? _lastHeartbeatAt;

  static Duration computeBaseInterval({
    required bool sosActive,
    required bool isStationary,
    required bool hasActiveGroup,
    required bool uiForeground,
    required bool expeditionMode,
  }) {
    if (sosActive) return const Duration(seconds: 10);
    if (isStationary) return const Duration(seconds: 300);
    if (hasActiveGroup) {
      return (uiForeground && !expeditionMode)
          ? const Duration(seconds: 15)
          : const Duration(seconds: 30);
    }
    return (uiForeground && !expeditionMode)
        ? const Duration(seconds: 60)
        : const Duration(seconds: 180);
  }

  Duration offlineProbeDelayForFailure(int failureCount) {
    final baseSec = switch (failureCount) {
      <= 1 => 15,
      2 => 30,
      3 => 60,
      _ => 180,
    };
    return _applyJitter(Duration(seconds: baseSec));
  }

  Duration nextSseReconnectDelay(int failureCount) {
    final baseSec = switch (failureCount) {
      <= 1 => 3,
      2 => 8,
      3 => 20,
      4 => 45,
      _ => 90,
    };
    return _applyJitter(Duration(seconds: baseSec));
  }

  Duration _applyJitter(Duration base) {
    if (jitterFactor <= 0.0) return base;
    final delta = (2.0 * _rng.nextDouble() - 1.0) * jitterFactor;
    final ms = (base.inMilliseconds * (1.0 + delta)).round();
    return Duration(milliseconds: math.max(1000, ms));
  }

  void start() {
    if (_disposed || _started) return;
    _started = true;
    _scheduleNext();
  }

  void stop() {
    _started = false;
    _timer?.cancel();
    _timer = null;
  }

  void updateState({
    bool? isOnline,
    bool? uiForeground,
    bool? hasActiveGroup,
    bool? isStationary,
    bool? expeditionMode,
    bool? sosActive,
  }) {
    if (_disposed) return;
    final wasOffline = !_isOnline;
    final wasStationary = _isStationary;
    final wasSos = _sosActive;

    if (isOnline != null) _isOnline = isOnline;
    if (uiForeground != null) _uiForeground = uiForeground;
    if (hasActiveGroup != null) _hasActiveGroup = hasActiveGroup;
    if (isStationary != null) _isStationary = isStationary;
    if (expeditionMode != null) _expeditionMode = expeditionMode;
    if (sosActive != null) _sosActive = sosActive;

    if (!_started) return;

    if ((wasOffline && _isOnline) || (!wasSos && _sosActive)) {
      _consecutiveFailures = 0;
      unawaited(
        triggerImmediateBurst(
          reason: _sosActive ? 'sos_preempt' : 'online_restored',
        ),
      );
      return;
    }

    // Entering or leaving Stationary Sleep sends one immediate status sync so
    // group peers see the hiker's cabană rest badge before the 300s sleep.
    if (wasStationary != _isStationary && _isOnline) {
      unawaited(
        triggerImmediateBurst(
          reason: _isStationary ? 'enter_stationary' : 'exit_stationary',
          forceHeartbeat: true,
        ),
      );
      return;
    }

    _scheduleNext();
  }

  Future<void> triggerImmediateBurst({
    required String reason,
    bool forceHeartbeat = false,
  }) async {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    await _runBurst(reason: reason, forceHeartbeat: forceHeartbeat);
    if (_started && !_disposed) {
      _scheduleNext();
    }
  }

  void _scheduleNext() {
    _timer?.cancel();
    _timer = null;
    if (!_started || _disposed) return;

    if (!_isOnline && !_sosActive) {
      // Zero periodic polling when OS reports no network interface; we still
      // arm a conservative 180s probe only if an offline BLE group exists.
      if (!_hasActiveGroup) return;
      _timer = Timer(offlineProbeDelayForFailure(4), () {
        unawaited(_onTimerFired());
      });
      return;
    }

    final Duration delay;
    if (_consecutiveFailures > 0 && !_sosActive) {
      delay = offlineProbeDelayForFailure(_consecutiveFailures);
    } else {
      delay = _applyJitter(
        computeBaseInterval(
          sosActive: _sosActive,
          isStationary: _isStationary,
          hasActiveGroup: _hasActiveGroup,
          uiForeground: _uiForeground,
          expeditionMode: _expeditionMode,
        ),
      );
    }

    _timer = Timer(delay, () {
      unawaited(_onTimerFired());
    });
  }

  Future<void> _onTimerFired() async {
    await _runBurst(reason: 'scheduled');
    if (_started && !_disposed) {
      _scheduleNext();
    }
  }

  Future<void> _runBurst({
    required String reason,
    bool forceHeartbeat = false,
  }) async {
    if (_disposed || _inFlight) return;
    _inFlight = true;
    try {
      final now = _clock();
      final minHbGap = _isStationary
          ? const Duration(seconds: 280)
          : (_uiForeground
                ? const Duration(seconds: 55)
                : const Duration(seconds: 170));
      final includeHb =
          forceHeartbeat ||
          _lastHeartbeatAt == null ||
          now.difference(_lastHeartbeatAt!) >= minHbGap;

      final ok = await onCoalescedBurst(
        RadioBurstContext(
          reason: reason,
          isStationary: _isStationary,
          sosActive: _sosActive,
          includeHeartbeat: includeHb,
        ),
      );
      if (ok) {
        _consecutiveFailures = 0;
        if (includeHb) {
          _lastHeartbeatAt = now;
        }
      } else {
        _consecutiveFailures = math.min(10, _consecutiveFailures + 1);
      }
    } catch (_) {
      _consecutiveFailures = math.min(10, _consecutiveFailures + 1);
    } finally {
      _inFlight = false;
    }
  }

  void dispose() {
    _disposed = true;
    stop();
  }
}
