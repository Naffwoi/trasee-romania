import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Reference-counted flag indicating at least one full-screen [NavigationScreen]
/// (turn-by-turn or GPS recording) is currently mounted.
///
/// While `true`, background map tabs (`MapScreen`) release their duplicate
/// foreground `Geolocator` stream, `50ms` `RotationSensor` subscription, and
/// Hybrid-Composition native `MapLibreMap` OpenGL surface.
final navSessionHibernationProvider =
    NotifierProvider<NavSessionHibernation, bool>(NavSessionHibernation.new);

class NavSessionHibernation extends Notifier<bool> {
  int _activeSessions = 0;

  @override
  bool build() => false;

  void enterNavigationSession() {
    _activeSessions++;
    if (!state) {
      state = true;
    }
  }

  void exitNavigationSession() {
    if (_activeSessions > 0) {
      _activeSessions--;
    }
    if (_activeSessions == 0 && state) {
      state = false;
    }
  }
}

/// Returns `true` only when the enclosing route is visibly active
/// (`TickerMode.of(context) == true`) AND no [NavigationScreen] owns the
/// dedicated tracking pipeline.
bool shouldAcquireForegroundMapSensors(BuildContext context, WidgetRef ref) {
  final tickersEnabled = TickerMode.of(context);
  final hibernating = ref.watch(navSessionHibernationProvider);
  return tickersEnabled && !hibernating;
}
