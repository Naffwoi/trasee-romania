import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanderer/components/navigation/sos_banner_and_dialog.dart';
import 'package:wanderer/models/emergency/salvamont_models.dart';
import 'package:wanderer/util/emergency/salvamont_resolver.dart';

void main() {
  late SalvamontDataset dataset;

  setUpAll(() {
    final raw = File('assets/data/salvamont_ro.json').readAsStringSync();
    dataset = SalvamontDataset.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  });

  testWidgets(
    'SosTriggerDialog renders nearest Salvamont base and multi-county ridge phones at Vf. Omu',
    (tester) async {
      final omuRes = resolveNearestSalvamont(
        dataset,
        45.4458,
        25.4563,
        userEle: 2505,
        localeCode: 'ro',
      );
      SalvamontPoint? routedTarget;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SosTriggerDialog(
              isRo: true,
              salvamontResolution: omuRes,
              onRouteToSalvamont: (pt) => routedTarget = pt,
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('sos-call-112-btn')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('sos-call-salvamont-btn')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('sos-salvamont-nearest-card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('sos-ridge-border-badge')),
        findsOneWidget,
      );

      for (final svc in omuRes.activeServices) {
        expect(
          find.byKey(ValueKey('sos-call-local-${svc.service.id}')),
          findsOneWidget,
        );
      }

      await tester.tap(find.byKey(const ValueKey('sos-route-to-salvamont-btn')));
      await tester.pumpAndSettle();
      expect(routedTarget?.id, omuRes.nearestBases.first.point.id);
    },
  );
}
