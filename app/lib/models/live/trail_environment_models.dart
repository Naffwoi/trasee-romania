class MountainWeatherSummary {
  final double elevationM;
  final double temperatureC;
  final double apparentTempC;
  final double windGustsKmh;
  final double ridgeWindPeakKmh;
  final String ridgeWindSeverity;
  final double freezingLevelM;
  final bool freezingOnTrail;
  final double snowDepthCm;
  final bool thunderstormRisk;
  final String attribution;

  const MountainWeatherSummary({
    required this.elevationM,
    required this.temperatureC,
    required this.apparentTempC,
    required this.windGustsKmh,
    required this.ridgeWindPeakKmh,
    required this.ridgeWindSeverity,
    required this.freezingLevelM,
    required this.freezingOnTrail,
    required this.snowDepthCm,
    required this.thunderstormRisk,
    required this.attribution,
  });

  factory MountainWeatherSummary.fromJson(Map<String, dynamic> j) {
    return MountainWeatherSummary(
      elevationM: (j['elevationM'] as num?)?.toDouble() ?? 0,
      temperatureC: (j['temperatureC'] as num?)?.toDouble() ?? 0,
      apparentTempC: (j['apparentTempC'] as num?)?.toDouble() ?? 0,
      windGustsKmh: (j['windGustsKmh'] as num?)?.toDouble() ?? 0,
      ridgeWindPeakKmh: (j['ridgeWindPeakKmh'] as num?)?.toDouble() ?? 0,
      ridgeWindSeverity: (j['ridgeWindSeverity'] as String?) ?? 'none',
      freezingLevelM: (j['freezingLevelM'] as num?)?.toDouble() ?? 0,
      freezingOnTrail: j['freezingOnTrail'] == true,
      snowDepthCm: (j['snowDepthCm'] as num?)?.toDouble() ?? 0,
      thunderstormRisk: j['thunderstormRisk'] == true,
      attribution: (j['attribution'] as String?) ?? '',
    );
  }
}

class GorgeFloodSummary {
  final double forecastPeakM3s;
  final double ratioToMedian;
  final bool warning;
  final String severity;

  const GorgeFloodSummary({
    required this.forecastPeakM3s,
    required this.ratioToMedian,
    required this.warning,
    required this.severity,
  });

  factory GorgeFloodSummary.fromJson(Map<String, dynamic> j) {
    return GorgeFloodSummary(
      forecastPeakM3s: (j['forecastPeakM3s'] as num?)?.toDouble() ?? 0,
      ratioToMedian: (j['ratioToMedian'] as num?)?.toDouble() ?? 1,
      warning: j['warning'] == true,
      severity: (j['severity'] as String?) ?? 'none',
    );
  }
}

class EnvHazardItem {
  final String id;
  final String hazardType;
  final String severity;
  final String title;

  const EnvHazardItem({
    required this.id,
    required this.hazardType,
    required this.severity,
    required this.title,
  });

  factory EnvHazardItem.fromJson(Map<String, dynamic> j) {
    return EnvHazardItem(
      id: (j['id'] as String?) ?? '',
      hazardType: (j['hazardType'] as String?) ?? 'wildfire',
      severity: (j['severity'] as String?) ?? 'warning',
      title: (j['title'] as String?) ?? '',
    );
  }
}

class TrailEnvironmentPayload {
  final MountainWeatherSummary? weather;
  final GorgeFloodSummary? gorgeFlood;
  final List<EnvHazardItem> hazards;

  const TrailEnvironmentPayload({
    this.weather,
    this.gorgeFlood,
    this.hazards = const [],
  });

  factory TrailEnvironmentPayload.fromJson(Map<String, dynamic> j) {
    return TrailEnvironmentPayload(
      weather: j['weather'] is Map<String, dynamic>
          ? MountainWeatherSummary.fromJson(
              j['weather'] as Map<String, dynamic>,
            )
          : null,
      gorgeFlood: j['gorgeFlood'] is Map<String, dynamic>
          ? GorgeFloodSummary.fromJson(j['gorgeFlood'] as Map<String, dynamic>)
          : null,
      hazards: (j['hazards'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(EnvHazardItem.fromJson)
          .toList(),
    );
  }
}

class TrailheadStreetPhoto {
  final String id;
  final String provider;
  final String thumbUrl;
  final String fullUrl;
  final double heading;
  final String capturedAt;
  final double distanceM;
  final String attribution;

  const TrailheadStreetPhoto({
    required this.id,
    required this.provider,
    required this.thumbUrl,
    required this.fullUrl,
    required this.heading,
    required this.capturedAt,
    required this.distanceM,
    required this.attribution,
  });

  factory TrailheadStreetPhoto.fromJson(Map<String, dynamic> j) {
    return TrailheadStreetPhoto(
      id: (j['id'] as String?) ?? '',
      provider: (j['provider'] as String?) ?? 'kartaview',
      thumbUrl: (j['thumbUrl'] as String?) ?? '',
      fullUrl: (j['fullUrl'] as String?) ?? '',
      heading: (j['heading'] as num?)?.toDouble() ?? 0,
      capturedAt: (j['capturedAt'] as String?) ?? '',
      distanceM: (j['distanceM'] as num?)?.toDouble() ?? 0,
      attribution: (j['attribution'] as String?) ?? '',
    );
  }
}
