import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wanderer/models/emergency/salvamont_models.dart';

final salvamontDatasetProvider = FutureProvider<SalvamontDataset>((ref) async {
  ref.keepAlive();
  final raw = await rootBundle.loadString('assets/data/salvamont_ro.json');
  return SalvamontDataset.fromJson(jsonDecode(raw) as Map<String, dynamic>);
});
