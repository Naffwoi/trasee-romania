enum SalvamontPointKind { base, post, refuge, dispatchHq }

enum SalvamontPermanence { always24x7, seasonal, shelterUnmanned }

class SalvamontService {
  const SalvamontService({
    required this.id,
    required this.name,
    required this.shortName,
    required this.level,
    required this.countyCode,
    required this.ansmrId,
    required this.primaryPhone,
    required this.secondaryPhones,
    required this.phoneRoleRo,
    required this.massifs,
    this.website,
  });

  final String id;
  final String name;
  final String shortName;
  final String level;
  final String countyCode;
  final int? ansmrId;
  final String primaryPhone;
  final List<String> secondaryPhones;
  final String phoneRoleRo;
  final List<String> massifs;
  final String? website;

  factory SalvamontService.fromJson(Map<String, dynamic> json) {
    return SalvamontService(
      id: json['id'] as String,
      name: json['name'] as String,
      shortName: json['shortName'] as String,
      level: json['level'] as String,
      countyCode: json['countyCode'] as String,
      ansmrId: (json['ansmrId'] as num?)?.toInt(),
      primaryPhone: json['primaryPhone'] as String,
      secondaryPhones: List<String>.from(
        json['secondaryPhones'] as List? ?? const [],
      ),
      phoneRoleRo: json['phoneRoleRo'] as String? ?? '',
      massifs: List<String>.from(json['massifs'] as List? ?? const []),
      website: json['website'] as String?,
    );
  }
}

class SalvamontPoint {
  const SalvamontPoint({
    required this.id,
    required this.name,
    required this.kind,
    required this.permanence,
    required this.lat,
    required this.lon,
    required this.ele,
    required this.massif,
    required this.countyCode,
    required this.serviceId,
    this.backupCountyServiceId,
    this.directBasePhone,
    this.osmIds = const [],
  });

  final String id;
  final String name;
  final SalvamontPointKind kind;
  final SalvamontPermanence permanence;
  final double lat;
  final double lon;
  final int ele;
  final String massif;
  final String countyCode;
  final String serviceId;
  final String? backupCountyServiceId;
  final String? directBasePhone;
  final List<String> osmIds;

  bool get isRefuge => kind == SalvamontPointKind.refuge;

  factory SalvamontPoint.fromJson(Map<String, dynamic> json) {
    final kindStr = json['kind'] as String? ?? 'base';
    final permStr = json['permanence'] as String? ?? '24_7';
    return SalvamontPoint(
      id: json['id'] as String,
      name: json['name'] as String,
      kind: switch (kindStr) {
        'post' => SalvamontPointKind.post,
        'refuge' => SalvamontPointKind.refuge,
        'dispatch_hq' => SalvamontPointKind.dispatchHq,
        _ => SalvamontPointKind.base,
      },
      permanence: switch (permStr) {
        'seasonal' => SalvamontPermanence.seasonal,
        'shelter_unmanned' => SalvamontPermanence.shelterUnmanned,
        _ => SalvamontPermanence.always24x7,
      },
      lat: (json['lat'] as num).toDouble(),
      lon: (json['lon'] as num).toDouble(),
      ele: (json['ele'] as num?)?.toInt() ?? 0,
      massif: json['massif'] as String? ?? '',
      countyCode: json['countyCode'] as String? ?? '',
      serviceId: json['serviceId'] as String,
      backupCountyServiceId: json['backupCountyServiceId'] as String?,
      directBasePhone: json['directBasePhone'] as String?,
      osmIds: List<String>.from(json['osmIds'] as List? ?? const []),
    );
  }
}

class SalvamontDataset {
  const SalvamontDataset({
    required this.version,
    required this.emergency112,
    required this.nationalDispatchPhone,
    required this.nationalDispatchLabel,
    required this.services,
    required this.points,
  });

  final int version;
  final String emergency112;
  final String nationalDispatchPhone;
  final String nationalDispatchLabel;
  final Map<String, SalvamontService> services;
  final List<SalvamontPoint> points;

  factory SalvamontDataset.fromJson(Map<String, dynamic> json) {
    final rawServices = json['services'] as Map<String, dynamic>? ?? const {};
    final services = <String, SalvamontService>{
      for (final e in rawServices.entries)
        e.key: SalvamontService.fromJson(e.value as Map<String, dynamic>),
    };
    final rawPoints = json['points'] as List? ?? const [];
    return SalvamontDataset(
      version: (json['version'] as num?)?.toInt() ?? 1,
      emergency112: json['emergency112'] as String? ?? '112',
      nationalDispatchPhone:
          json['nationalDispatchPhone'] as String? ?? '+40725826668',
      nationalDispatchLabel:
          json['nationalDispatchLabel'] as String? ??
          '0-SALVAMONT (0725 826 668)',
      services: services,
      points: [
        for (final p in rawPoints)
          SalvamontPoint.fromJson(p as Map<String, dynamic>),
      ],
    );
  }
}
