enum LocationTrackingMode {
  inactive,
  freeTracking,
  followNorthUp,
  followHeadingUp,
}

LocationTrackingMode nextLocationTrackingMode(
  LocationTrackingMode current, {
  required bool hasHeading,
}) {
  return switch (current) {
    LocationTrackingMode.inactive ||
    LocationTrackingMode.freeTracking => LocationTrackingMode.followNorthUp,
    LocationTrackingMode.followNorthUp =>
      hasHeading
          ? LocationTrackingMode.followHeadingUp
          : LocationTrackingMode.followNorthUp,
    LocationTrackingMode.followHeadingUp => LocationTrackingMode.followNorthUp,
  };
}
