import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wanderer/models/emergency/salvamont_models.dart';
import 'package:wanderer/util/emergency/salvamont_resolver.dart';

void main() {
  late SalvamontDataset dataset;

  setUpAll(() {
    final raw = File('assets/data/salvamont_ro.json').readAsStringSync();
    dataset = SalvamontDataset.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  });

  test('validates bundled salvamont_ro.json E.164 phone integrity', () {
    expect(dataset.emergency112, '112');
    expect(dataset.nationalDispatchPhone, '+40725826668');
    expect(dataset.points.length, greaterThanOrEqualTo(55));
    final e164 = RegExp(r'^\+40[237]\d{8}$');
    for (final svc in dataset.services.values) {
      expect(e164.hasMatch(svc.primaryPhone), isTrue, reason: svc.id);
    }
  });

  test('detects multi-county ridge border at Vf. Omu (PH / DB / BV)', () {
    final res = resolveNearestSalvamont(
      dataset,
      45.4458,
      25.4563,
      userEle: 2505,
      localeCode: 'ro',
    );
    expect(res.isMountainZone, isTrue);
    expect(res.isRidgeBorderZone, isTrue);
    expect(res.activeServices.length, greaterThanOrEqualTo(2));
    expect(res.borderCountyCodes.toSet().length, greaterThanOrEqualTo(2));
  });

  test('detects Făgăraș crest border (SB / AG) and nearest refuge', () {
    final res = resolveNearestSalvamont(
      dataset,
      45.6005,
      24.6285,
      userEle: 2260,
      localeCode: 'ro',
    );
    expect(res.isRidgeBorderZone, isTrue);
    expect(res.borderCountyCodes, containsAll(<String>['SB', 'AG']));
    expect(res.nearestRefuge, isNotNull);
    expect(res.nearestRefuge!.point.name, contains('Fereastra Zmeilor'));
  });

  test('suppresses distant services in Munții Măcin (> 35 km)', () {
    final res = resolveNearestSalvamont(dataset, 45.2060, 28.1950);
    expect(res.isMountainZone, isFalse);
    expect(res.activeServices, isEmpty);
  });
}
