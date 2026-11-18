import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanderer/components/navigation/rescue_coordinates_and_signal_card.dart';
import 'package:wanderer/components/navigation/waze_nearby_prompt.dart';
import 'package:wanderer/models/live/trail_live_models.dart';

void main() {
  testWidgets(
    'RescueCoordinatesAndSignalCard renders offline WGS84, DMS, UTM 35T, Plus Code and SMS 113',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: RescueCoordinatesAndSignalCard(
              lat: 45.445833,
              lon: 25.456389,
              elevationM: 2505,
              accuracyM: 6,
              reasonRo: 'Accidentare',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('35T 379287 E 5033638 N'), findsOneWidget);
      expect(find.textContaining('8GQ7CFW4+8HJ'), findsOneWidget);
      expect(find.byKey(const ValueKey('sos-sms-113-btn')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('sos-gsm-viewshed-btn')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'WazeNearbyPrompt displays verified on-site photo badge when photoVerified is true',
    (tester) async {
      final report = TrailReportModel.fromJson(const {
        'id': 'rep123456789012',
        'category': 'bear',
        'kind': 'hazard',
        'isPermanent': false,
        'conditionStatus': 'active',
        'note': 'Urs văzut pe potecă',
        'lat': 45.4458,
        'lon': 25.4563,
        'photoUrl':
            '/api/v1/files/trail_reports/rep123456789012/report.jpg?thumb=600x0',
        'photoThumbUrl':
            '/api/v1/files/trail_reports/rep123456789012/report.jpg?thumb=300x300',
        'photoVerified': true,
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WazeNearbyPrompt(
              report: report,
              distanceMeters: 65,
              serverBaseUrl: 'https://maps.example.com/api/v1',
              onVote: (_) {},
              onClose: () {},
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('report-photo-verified-badge')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Foto verificată la fața locului'),
        findsOneWidget,
      );
      final imgFinder = find.byType(Image);
      expect(imgFinder, findsOneWidget);
      final imageWidget = tester.widget<Image>(imgFinder);
      expect(
        (imageWidget.image as NetworkImage).url,
        'https://maps.example.com/api/v1/files/trail_reports/rep123456789012/report.jpg?thumb=300x300',
      );
      final normalized = report.withResolvedPhotoUrls(
        'https://maps.example.com/api/v1',
      );
      expect(
        normalized.photoUrl,
        'https://maps.example.com/api/v1/files/trail_reports/rep123456789012/report.jpg?thumb=600x0',
      );
      expect(
        normalized.photoThumbUrl,
        'https://maps.example.com/api/v1/files/trail_reports/rep123456789012/report.jpg?thumb=300x300',
      );
    },
  );
}
