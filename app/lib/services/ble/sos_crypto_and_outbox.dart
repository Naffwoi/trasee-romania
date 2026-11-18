import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart'
    show debugPrint, kIsWeb, visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:wanderer/models/live/trail_live_models.dart' show SosReason;

/// Unambiguous 32-character uppercase alphabet (excludes 0, O, 1, I),
/// matching `groupCodeAlphabet` in `db/routes/trail_live_groups.go`.
const String kOfflineGroupCodeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/// Exact 6-color group member avatar palette matching `groupMemberPalette` in
/// `db/routes/trail_live_groups.go`.
const List<String> kBleGroupMemberPalette = <String>[
  '#242734',
  '#0f766e',
  '#3730a3',
  '#0369a1',
  '#4d7c0f',
  '#6d28d9',
];

final RegExp _hex16Pattern = RegExp(r'^[0-9a-f]{16}$');
final RegExp _hex32Pattern = RegExp(r'^[0-9a-f]{32}$');

/// Encodes [bytes] as lowercase hexadecimal.
String bytesToHexLower(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write((b & 0xFF).toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// Decodes an even-length hexadecimal string into a [Uint8List], returning
/// `null` if [hex] contains non-hex characters or has an odd length.
Uint8List? tryHexToBytes(String hex, {int? expectedByteLength}) {
  final cleaned = hex.trim().toLowerCase();
  if (cleaned.isEmpty || cleaned.length.isOdd) return null;
  final byteLen = cleaned.length ~/ 2;
  if (expectedByteLength != null && byteLen != expectedByteLength) {
    return null;
  }
  final out = Uint8List(byteLen);
  for (var i = 0; i < byteLen; i++) {
    final hi = _hexDigitValue(cleaned.codeUnitAt(i * 2));
    final lo = _hexDigitValue(cleaned.codeUnitAt(i * 2 + 1));
    if (hi < 0 || lo < 0) return null;
    out[i] = (hi << 4) | lo;
  }
  return out;
}

int _hexDigitValue(int codeUnit) {
  if (codeUnit >= 0x30 && codeUnit <= 0x39) return codeUnit - 0x30;
  if (codeUnit >= 0x61 && codeUnit <= 0x66) return codeUnit - 0x61 + 10;
  if (codeUnit >= 0x41 && codeUnit <= 0x46) return codeUnit - 0x41 + 10;
  return -1;
}

/// Constant-time comparison of two byte sequences.
bool constantTimeBytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= (a[i] ^ b[i]) & 0xFF;
  }
  return diff == 0;
}

/// Computes the 8-byte public Lamport commitment from a 16-byte secret preimage:
/// `SHA-256("trasee-sos-claim-v1:" || secret16B)[0..8]`.
///
/// Matches `db/routes/trail_live_sos_relay.go` byte-for-byte.
Uint8List computeSosClaimHashBytes(Uint8List secret16B) {
  if (secret16B.length != 16) {
    throw ArgumentError.value(
      secret16B.length,
      'secret16B',
      'SOS secret preimage must be exactly 16 bytes',
    );
  }
  final prefix = utf8.encode('trasee-sos-claim-v1:');
  final payload = Uint8List(prefix.length + 16);
  payload.setRange(0, prefix.length, prefix);
  payload.setRange(prefix.length, prefix.length + 16, secret16B);
  final digest = sha256.convert(payload);
  return Uint8List.fromList(digest.bytes.sublist(0, 8));
}

/// Verifies in constant time that [reveal16B] hashes to [expectedHash8B] under
/// the canonical Lamport commitment `SHA-256("trasee-sos-claim-v1:" || reveal16B)[0..8]`.
bool verifyPreimageBytes(Uint8List reveal16B, Uint8List expectedHash8B) {
  if (reveal16B.length != 16 || expectedHash8B.length != 8) {
    return false;
  }
  final computed = computeSosClaimHashBytes(reveal16B);
  return constantTimeBytesEqual(computed, expectedHash8B);
}

/// Verifies in constant time that 32-hex [secretHex32] hashes to 16-hex
/// [expectedHashHex16] under the canonical Lamport commitment.
bool verifyPreimageHex(String secretHex32, String expectedHashHex16) {
  final secretBytes = tryHexToBytes(secretHex32, expectedByteLength: 16);
  final expectedBytes = tryHexToBytes(expectedHashHex16, expectedByteLength: 8);
  if (secretBytes == null || expectedBytes == null) {
    return false;
  }
  return verifyPreimageBytes(secretBytes, expectedBytes);
}

/// Derives a deterministic 6-byte responder identifier per `(clientSosId, responderDeviceToken)`
/// so an offline victim accurately counts distinct nearby responders without exposing
/// raw device tokens over BLE.
Uint8List deriveBleResponderIdBytes({
  required String clientSosId,
  required String responderDeviceToken,
}) {
  final normId = clientSosId.trim().toLowerCase();
  final digest = sha256.convert(
    utf8.encode('trasee-sos-resp-v1:$normId:${responderDeviceToken.trim()}'),
  );
  return Uint8List.fromList(digest.bytes.sublist(0, 6));
}

/// Hex-encoded 12-char form of [deriveBleResponderIdBytes].
String deriveBleResponderIdHex({
  required String clientSosId,
  required String responderDeviceToken,
}) {
  return bytesToHexLower(
    deriveBleResponderIdBytes(
      clientSosId: clientSosId,
      responderDeviceToken: responderDeviceToken,
    ),
  );
}

/// Generates an unambiguous 6-character uppercase group code for offline group creation.
String generateOfflineGroupCode({math.Random? random}) {
  final rng = random ?? math.Random.secure();
  final sb = StringBuffer();
  for (var i = 0; i < 6; i++) {
    sb.write(
      kOfflineGroupCodeAlphabet[rng.nextInt(kOfflineGroupCodeAlphabet.length)],
    );
  }
  return sb.toString();
}

/// Derives a deterministic 12-char lowercase hex `memberId` (`6` bytes) for
/// an offline-created group before server sync.
String deriveOfflineGroupMemberId({
  required String groupCode,
  required String deviceToken,
}) {
  final code = groupCode.trim().toUpperCase();
  final digest = sha256.convert(
    utf8.encode('ble-group-member:$code:${deviceToken.trim()}'),
  );
  return bytesToHexLower(digest.bytes.sublist(0, 6));
}

/// Deterministically maps a 6-byte (`12` hex chars) `memberId` to the exact
/// same 6-color palette index (`uint32BE(memberId[0..4]) % 6`) used by
/// `deriveGroupMemberColor` in `db/routes/trail_live_groups.go`.
String deriveBleMemberColor(String memberIdHex) {
  final bytes = tryHexToBytes(memberIdHex);
  if (bytes == null || bytes.length < 4) {
    return kBleGroupMemberPalette.first;
  }
  final bd = ByteData.sublistView(bytes, 0, 4);
  final u32 = bd.getUint32(0, Endian.big);
  return kBleGroupMemberPalette[u32 % kBleGroupMemberPalette.length];
}

/// Deterministic Lamport ownership credentials for a single SOS incident.
///
/// - [clientSosId]: 16 lowercase hex chars (`8` random bytes).
/// - [sosSecretBytes] / [sosClaimSecret]: 16 bytes (`32` lowercase hex chars)
///   derived via `HMAC-SHA256(deviceToken, "trasee-sos-v1:$clientSosId")[0..16]`.
///   Kept private on the victim's phone while the SOS is active; revealed only
///   in `PKT_SOS_RESOLVED (0x04)` or when claiming/resolving on the server.
/// - [sosClaimHashBytes] / [sosClaimHash]: 8 bytes (`16` lowercase hex chars)
///   derived via `SHA-256("trasee-sos-claim-v1:" || sosSecretBytes)[0..8]`.
///   Broadcast publicly in `PKT_SOS_ALERT (0x02)` and uploaded by Store-and-Forward mules.
class SosOriginCredentials {
  SosOriginCredentials._({
    required this.clientSosId,
    required Uint8List clientSosIdBytes,
    required Uint8List sosSecretBytes,
    required this.sosClaimSecret,
    required Uint8List sosClaimHashBytes,
    required this.sosClaimHash,
  }) : _clientSosIdBytes = Uint8List.fromList(clientSosIdBytes),
       _sosSecretBytes = Uint8List.fromList(sosSecretBytes),
       _sosClaimHashBytes = Uint8List.fromList(sosClaimHashBytes);

  final String clientSosId;
  final Uint8List _clientSosIdBytes;
  final Uint8List _sosSecretBytes;
  final String sosClaimSecret;
  final Uint8List _sosClaimHashBytes;
  final String sosClaimHash;

  Uint8List get clientSosIdBytes => Uint8List.fromList(_clientSosIdBytes);
  Uint8List get sosSecretBytes => Uint8List.fromList(_sosSecretBytes);
  Uint8List get sosClaimHashBytes => Uint8List.fromList(_sosClaimHashBytes);

  /// Mints a fresh random 8-byte [clientSosId] and derives its Lamport
  /// secret preimage and public claim hash from [deviceToken].
  factory SosOriginCredentials.mint(
    String deviceToken, {
    math.Random? random,
  }) {
    final rng = random ?? math.Random.secure();
    final idBytes = Uint8List(8);
    for (var i = 0; i < 8; i++) {
      idBytes[i] = rng.nextInt(256);
    }
    return SosOriginCredentials.derive(
      deviceToken: deviceToken,
      clientSosId: bytesToHexLower(idBytes),
    );
  }

  /// Deterministically re-derives the exact Lamport credentials from
  /// [deviceToken] and an existing 16-hex [clientSosId].
  factory SosOriginCredentials.derive({
    required String deviceToken,
    required String clientSosId,
  }) {
    final normId = clientSosId.trim().toLowerCase();
    final idBytes = tryHexToBytes(normId, expectedByteLength: 8);
    if (idBytes == null || !_hex16Pattern.hasMatch(normId)) {
      throw ArgumentError.value(
        clientSosId,
        'clientSosId',
        'Must be 16 hexadecimal characters (8 bytes)',
      );
    }
    final tokenBytes = utf8.encode(deviceToken);
    final mac = Hmac(sha256, tokenBytes).convert(
      utf8.encode('trasee-sos-v1:$normId'),
    );
    final secretBytes = Uint8List.fromList(mac.bytes.sublist(0, 16));
    final secretHex = bytesToHexLower(secretBytes);
    final claimHashBytes = computeSosClaimHashBytes(secretBytes);
    final claimHashHex = bytesToHexLower(claimHashBytes);

    return SosOriginCredentials._(
      clientSosId: normId,
      clientSosIdBytes: idBytes,
      sosSecretBytes: secretBytes,
      sosClaimSecret: secretHex,
      sosClaimHashBytes: claimHashBytes,
      sosClaimHash: claimHashHex,
    );
  }

  static bool verifyPreimage(String secretHex32, String expectedHashHex16) =>
      verifyPreimageHex(secretHex32, expectedHashHex16);

  static bool verifyBytes(Uint8List reveal16B, Uint8List expectedHash8B) =>
      verifyPreimageBytes(reveal16B, expectedHash8B);
}

/// Persisted state of the local user's own active or pending-resolution SOS
/// so ownership (`sosClaimSecret`) and offline status changes survive app restarts.
class PendingMySosEntry {
  const PendingMySosEntry({
    required this.clientSosId,
    required this.sosClaimSecret,
    required this.sosClaimHash,
    this.serverSosId,
    this.trailId,
    this.status = 'active',
    this.reason = SosReason.other,
    this.message = '',
    this.requesterName = '',
    required this.lat,
    required this.lon,
    this.ele = 0.0,
    required this.createdEpochSec,
    this.resolvedEpochSec,
    this.needsServerCreateOrClaim = true,
    this.needsServerResolve = false,
  });

  final String clientSosId;
  final String sosClaimSecret;
  final String sosClaimHash;
  final String? serverSosId;
  final String? trailId;
  final String status;
  final SosReason reason;
  final String message;
  final String requesterName;
  final double lat;
  final double lon;
  final double ele;
  final int createdEpochSec;
  final int? resolvedEpochSec;
  final bool needsServerCreateOrClaim;
  final bool needsServerResolve;

  bool get isActive => status == 'active';

  bool isExpiredAt(int nowEpochSec, {int ttlSec = SosOutboxAndRelayStore.kSosRelayTtlSec}) {
    return nowEpochSec - createdEpochSec > ttlSec;
  }

  PendingMySosEntry copyWith({
    String? clientSosId,
    String? sosClaimSecret,
    String? sosClaimHash,
    String? serverSosId,
    String? trailId,
    String? status,
    SosReason? reason,
    String? message,
    String? requesterName,
    double? lat,
    double? lon,
    double? ele,
    int? createdEpochSec,
    int? resolvedEpochSec,
    bool? needsServerCreateOrClaim,
    bool? needsServerResolve,
  }) {
    return PendingMySosEntry(
      clientSosId: clientSosId ?? this.clientSosId,
      sosClaimSecret: sosClaimSecret ?? this.sosClaimSecret,
      sosClaimHash: sosClaimHash ?? this.sosClaimHash,
      serverSosId: serverSosId ?? this.serverSosId,
      trailId: trailId ?? this.trailId,
      status: status ?? this.status,
      reason: reason ?? this.reason,
      message: message ?? this.message,
      requesterName: requesterName ?? this.requesterName,
      lat: lat ?? this.lat,
      lon: lon ?? this.lon,
      ele: ele ?? this.ele,
      createdEpochSec: createdEpochSec ?? this.createdEpochSec,
      resolvedEpochSec: resolvedEpochSec ?? this.resolvedEpochSec,
      needsServerCreateOrClaim:
          needsServerCreateOrClaim ?? this.needsServerCreateOrClaim,
      needsServerResolve: needsServerResolve ?? this.needsServerResolve,
    );
  }

  static PendingMySosEntry? tryFromJson(Map<String, dynamic> json) {
    final id = (json['clientSosId'] ?? '').toString().trim().toLowerCase();
    final secret =
        (json['sosClaimSecret'] ?? '').toString().trim().toLowerCase();
    final hash = (json['sosClaimHash'] ?? '').toString().trim().toLowerCase();
    if (!_hex16Pattern.hasMatch(id) ||
        !_hex32Pattern.hasMatch(secret) ||
        !_hex16Pattern.hasMatch(hash)) {
      return null;
    }
    return PendingMySosEntry(
      clientSosId: id,
      sosClaimSecret: secret,
      sosClaimHash: hash,
      serverSosId: _optStr(json['serverSosId']),
      trailId: _optStr(json['trailId']),
      status: _optStr(json['status']) ?? 'active',
      reason: SosReason.fromApi(_optStr(json['reason'])),
      message: (json['message'] ?? '').toString(),
      requesterName: (json['requesterName'] ?? '').toString(),
      lat: _numDouble(json['lat']),
      lon: _numDouble(json['lon']),
      ele: _numDouble(json['ele']),
      createdEpochSec: _numInt(json['createdEpochSec']),
      resolvedEpochSec: _optInt(json['resolvedEpochSec']),
      needsServerCreateOrClaim: _boolVal(
        json['needsServerCreateOrClaim'],
        true,
      ),
      needsServerResolve: _boolVal(json['needsServerResolve'], false),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'clientSosId': clientSosId,
    'sosClaimSecret': sosClaimSecret,
    'sosClaimHash': sosClaimHash,
    if (serverSosId != null) 'serverSosId': serverSosId,
    if (trailId != null) 'trailId': trailId,
    'status': status,
    'reason': reason.apiValue,
    'message': message,
    'requesterName': requesterName,
    'lat': lat,
    'lon': lon,
    'ele': ele,
    'createdEpochSec': createdEpochSec,
    if (resolvedEpochSec != null) 'resolvedEpochSec': resolvedEpochSec,
    'needsServerCreateOrClaim': needsServerCreateOrClaim,
    'needsServerResolve': needsServerResolve,
  };
}

/// Store-and-Forward SOS packet received over BLE from another hiker, queued
/// for upload to `POST /api/v1/live/sos/relay` when mobile connectivity returns.
class RelayedSosEntry {
  const RelayedSosEntry({
    required this.clientSosId,
    required this.sosClaimHash,
    this.status = 'active',
    this.sosClaimSecret,
    this.trailId,
    this.reason = SosReason.other,
    this.message = '',
    this.requesterName = '',
    required this.lat,
    required this.lon,
    this.ele = 0.0,
    required this.packetEpochSec,
    this.hopCount = 0,
    required this.receivedAtEpochSec,
    this.uploadedActiveToServer = false,
    this.uploadedResolvedToServer = false,
    this.serverSosId,
  });

  final String clientSosId;
  final String sosClaimHash;
  final String status;
  final String? sosClaimSecret;
  final String? trailId;
  final SosReason reason;
  final String message;
  final String requesterName;
  final double lat;
  final double lon;
  final double ele;
  final int packetEpochSec;
  final int hopCount;
  final int receivedAtEpochSec;
  final bool uploadedActiveToServer;
  final bool uploadedResolvedToServer;
  final String? serverSosId;

  bool get isResolved => status == 'resolved' || status == 'cancelled';

  bool get needsServerUpload =>
      isResolved ? !uploadedResolvedToServer : !uploadedActiveToServer;

  bool isExpiredAt(
    int nowEpochSec, {
    int ttlSec = SosOutboxAndRelayStore.kSosRelayTtlSec,
  }) {
    return nowEpochSec - receivedAtEpochSec > ttlSec;
  }

  RelayedSosEntry copyWith({
    String? clientSosId,
    String? sosClaimHash,
    String? status,
    String? sosClaimSecret,
    String? trailId,
    SosReason? reason,
    String? message,
    String? requesterName,
    double? lat,
    double? lon,
    double? ele,
    int? packetEpochSec,
    int? hopCount,
    int? receivedAtEpochSec,
    bool? uploadedActiveToServer,
    bool? uploadedResolvedToServer,
    String? serverSosId,
  }) {
    return RelayedSosEntry(
      clientSosId: clientSosId ?? this.clientSosId,
      sosClaimHash: sosClaimHash ?? this.sosClaimHash,
      status: status ?? this.status,
      sosClaimSecret: sosClaimSecret ?? this.sosClaimSecret,
      trailId: trailId ?? this.trailId,
      reason: reason ?? this.reason,
      message: message ?? this.message,
      requesterName: requesterName ?? this.requesterName,
      lat: lat ?? this.lat,
      lon: lon ?? this.lon,
      ele: ele ?? this.ele,
      packetEpochSec: packetEpochSec ?? this.packetEpochSec,
      hopCount: hopCount ?? this.hopCount,
      receivedAtEpochSec: receivedAtEpochSec ?? this.receivedAtEpochSec,
      uploadedActiveToServer:
          uploadedActiveToServer ?? this.uploadedActiveToServer,
      uploadedResolvedToServer:
          uploadedResolvedToServer ?? this.uploadedResolvedToServer,
      serverSosId: serverSosId ?? this.serverSosId,
    );
  }

  /// Exact JSON payload expected by `POST /api/v1/live/sos/relay`.
  Map<String, dynamic> toRelayApiJson() {
    final secret = sosClaimSecret;
    final tid = trailId;
    return <String, dynamic>{
      'clientSosId': clientSosId,
      'sosClaimHash': sosClaimHash,
      'status': isResolved ? 'resolved' : 'active',
      if (secret != null && secret.isNotEmpty) 'sosClaimSecret': secret,
      if (tid != null && tid.isNotEmpty) 'trailId': tid,
      'reason': reason.apiValue,
      'message': message,
      'requesterName': requesterName,
      'lat': lat,
      'lon': lon,
      'ele': ele,
      'packetEpochSec': packetEpochSec,
      'hopCount': hopCount,
    };
  }

  static RelayedSosEntry? tryFromJson(Map<String, dynamic> json) {
    final id = (json['clientSosId'] ?? '').toString().trim().toLowerCase();
    final hash = (json['sosClaimHash'] ?? '').toString().trim().toLowerCase();
    if (!_hex16Pattern.hasMatch(id) || !_hex16Pattern.hasMatch(hash)) {
      return null;
    }
    final rawSecret = _optStr(json['sosClaimSecret'])?.toLowerCase();
    final validSecret =
        (rawSecret != null && _hex32Pattern.hasMatch(rawSecret))
        ? rawSecret
        : null;
    return RelayedSosEntry(
      clientSosId: id,
      sosClaimHash: hash,
      status: _optStr(json['status']) ?? 'active',
      sosClaimSecret: validSecret,
      trailId: _optStr(json['trailId']),
      reason: SosReason.fromApi(_optStr(json['reason'])),
      message: (json['message'] ?? '').toString(),
      requesterName: (json['requesterName'] ?? '').toString(),
      lat: _numDouble(json['lat']),
      lon: _numDouble(json['lon']),
      ele: _numDouble(json['ele']),
      packetEpochSec: _numInt(json['packetEpochSec']),
      hopCount: _numInt(json['hopCount']),
      receivedAtEpochSec: _numInt(
        json['receivedAtEpochSec'] ?? json['packetEpochSec'],
      ),
      uploadedActiveToServer: _boolVal(json['uploadedActiveToServer'], false),
      uploadedResolvedToServer: _boolVal(
        json['uploadedResolvedToServer'],
        false,
      ),
      serverSosId: _optStr(json['serverSosId']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'clientSosId': clientSosId,
    'sosClaimHash': sosClaimHash,
    'status': status,
    if (sosClaimSecret != null) 'sosClaimSecret': sosClaimSecret,
    if (trailId != null) 'trailId': trailId,
    'reason': reason.apiValue,
    'message': message,
    'requesterName': requesterName,
    'lat': lat,
    'lon': lon,
    'ele': ele,
    'packetEpochSec': packetEpochSec,
    'hopCount': hopCount,
    'receivedAtEpochSec': receivedAtEpochSec,
    'uploadedActiveToServer': uploadedActiveToServer,
    'uploadedResolvedToServer': uploadedResolvedToServer,
    if (serverSosId != null) 'serverSosId': serverSosId,
  };
}

/// Offline responder intent ("Pot să vin să ajut" / cancelled) queued until the
/// server `sosId` is known and mobile connectivity returns.
class PendingResponderAction {
  const PendingResponderAction({
    required this.clientSosId,
    this.serverSosId,
    this.status = 'coming',
    required this.lat,
    required this.lon,
    this.ele = 0.0,
    this.distanceM,
    this.etaSec,
    required this.createdEpochSec,
  });

  final String clientSosId;
  final String? serverSosId;
  final String status;
  final double lat;
  final double lon;
  final double ele;
  final double? distanceM;
  final int? etaSec;
  final int createdEpochSec;

  bool isExpiredAt(
    int nowEpochSec, {
    int ttlSec = SosOutboxAndRelayStore.kSosRelayTtlSec,
  }) {
    return nowEpochSec - createdEpochSec > ttlSec;
  }

  PendingResponderAction copyWith({
    String? clientSosId,
    String? serverSosId,
    String? status,
    double? lat,
    double? lon,
    double? ele,
    double? distanceM,
    int? etaSec,
    int? createdEpochSec,
  }) {
    return PendingResponderAction(
      clientSosId: clientSosId ?? this.clientSosId,
      serverSosId: serverSosId ?? this.serverSosId,
      status: status ?? this.status,
      lat: lat ?? this.lat,
      lon: lon ?? this.lon,
      ele: ele ?? this.ele,
      distanceM: distanceM ?? this.distanceM,
      etaSec: etaSec ?? this.etaSec,
      createdEpochSec: createdEpochSec ?? this.createdEpochSec,
    );
  }

  static PendingResponderAction? tryFromJson(Map<String, dynamic> json) {
    final id = (json['clientSosId'] ?? '').toString().trim().toLowerCase();
    if (!_hex16Pattern.hasMatch(id)) return null;
    return PendingResponderAction(
      clientSosId: id,
      serverSosId: _optStr(json['serverSosId']),
      status: _optStr(json['status']) ?? 'coming',
      lat: _numDouble(json['lat']),
      lon: _numDouble(json['lon']),
      ele: _numDouble(json['ele']),
      distanceM: _optDouble(json['distanceM']),
      etaSec: _optInt(json['etaSec']),
      createdEpochSec: _numInt(json['createdEpochSec']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'clientSosId': clientSosId,
    if (serverSosId != null) 'serverSosId': serverSosId,
    'status': status,
    'lat': lat,
    'lon': lon,
    'ele': ele,
    if (distanceM != null) 'distanceM': distanceM,
    if (etaSec != null) 'etaSec': etaSec,
    'createdEpochSec': createdEpochSec,
  };
}

/// Persistent Store-and-Forward outbox in
/// `<ApplicationSupportDirectory>/wanderer_sos_relay_outbox.json`.
///
/// Falls back cleanly to in-memory storage on Web or in unit tests where
/// `path_provider` is unavailable.
class SosOutboxAndRelayStore {
  SosOutboxAndRelayStore({
    File? customFile,
    Future<Directory> Function()? directoryProvider,
    int Function()? nowEpochSec,
  }) : _customFile = customFile,
       _directoryProvider = directoryProvider ?? getApplicationSupportDirectory,
       _nowEpochSec = nowEpochSec ?? _defaultNowEpochSec;

  static const String fileName = 'wanderer_sos_relay_outbox.json';
  static const int kSosRelayTtlSec = 6 * 3600;

  final File? _customFile;
  final Future<Directory> Function() _directoryProvider;
  final int Function() _nowEpochSec;

  PendingMySosEntry? _myPendingSos;
  final Map<String, RelayedSosEntry> _relayById = <String, RelayedSosEntry>{};
  PendingResponderAction? _pendingResponderAction;
  bool _loaded = false;
  Future<void>? _inFlightLoad;

  static int _defaultNowEpochSec() =>
      DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;

  PendingMySosEntry? get myPendingSos => _myPendingSos;

  PendingResponderAction? get pendingResponderAction => _pendingResponderAction;

  /// Snapshot of non-expired relayed SOS entries ordered by `packetEpochSec`.
  List<RelayedSosEntry> get relayQueue {
    _pruneExpiredInMemory(_nowEpochSec());
    final list = _relayById.values.toList(growable: false);
    return list;
  }

  /// Relayed SOS entries that still need a `POST /api/v1/live/sos/relay` flush.
  List<RelayedSosEntry> get pendingRelayUploads {
    _pruneExpiredInMemory(_nowEpochSec());
    return _relayById.values
        .where((e) => e.needsServerUpload)
        .toList(growable: false);
  }

  /// Returns the known `sosClaimHash` for [clientSosId], checking both
  /// `myPendingSos` and `relayQueue`.
  String? lookupClaimHash(String clientSosId) {
    final norm = clientSosId.trim().toLowerCase();
    final mine = _myPendingSos;
    if (mine != null && mine.clientSosId == norm) {
      return mine.sosClaimHash;
    }
    return _relayById[norm]?.sosClaimHash;
  }

  Future<void> ensureLoaded() {
    if (_loaded) return Future<void>.value();
    final existing = _inFlightLoad;
    if (existing != null) return existing;
    final future = _loadFromDisk().whenComplete(() {
      _inFlightLoad = null;
      _loaded = true;
    });
    _inFlightLoad = future;
    return future;
  }

  @visibleForTesting
  Future<void> reloadFromDisk() async {
    _loaded = false;
    await ensureLoaded();
  }

  Future<File?> _resolveFile() async {
    final explicit = _customFile;
    if (explicit != null) return explicit;
    if (kIsWeb) return null;
    try {
      final dir = await _directoryProvider();
      return File('${dir.path}${Platform.pathSeparator}$fileName');
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadFromDisk() async {
    try {
      final file = await _resolveFile();
      if (file == null || !await file.exists()) {
        return;
      }
      final raw = (await file.readAsString()).trim();
      if (raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final map = Map<String, dynamic>.from(decoded);

      final rawMine = map['myPendingSos'];
      if (rawMine is Map) {
        _myPendingSos = PendingMySosEntry.tryFromJson(
          Map<String, dynamic>.from(rawMine),
        );
      } else {
        _myPendingSos = null;
      }

      _relayById.clear();
      final rawQueue = map['relayQueue'];
      if (rawQueue is List) {
        for (final item in rawQueue) {
          if (item is Map) {
            final parsed = RelayedSosEntry.tryFromJson(
              Map<String, dynamic>.from(item),
            );
            if (parsed != null) {
              _relayById[parsed.clientSosId] = parsed;
            }
          }
        }
      }

      final rawResp = map['pendingResponderAction'];
      if (rawResp is Map) {
        _pendingResponderAction = PendingResponderAction.tryFromJson(
          Map<String, dynamic>.from(rawResp),
        );
      } else {
        _pendingResponderAction = null;
      }

      _pruneExpiredInMemory(_nowEpochSec());
    } catch (e) {
      debugPrint('SosOutboxAndRelayStore: failed to read outbox — $e');
    }
  }

  void _pruneExpiredInMemory(int nowSec) {
    final mine = _myPendingSos;
    if (mine != null && mine.isExpiredAt(nowSec)) {
      _myPendingSos = null;
    }
    _relayById.removeWhere((_, entry) => entry.isExpiredAt(nowSec));
    final resp = _pendingResponderAction;
    if (resp != null && resp.isExpiredAt(nowSec)) {
      _pendingResponderAction = null;
    }
  }

  Future<void> _persist() async {
    _pruneExpiredInMemory(_nowEpochSec());
    try {
      final file = await _resolveFile();
      if (file == null) return;
      await file.parent.create(recursive: true);
      final mine = _myPendingSos;
      final resp = _pendingResponderAction;
      final payload = <String, dynamic>{
        'version': 1,
        if (mine != null) 'myPendingSos': mine.toJson(),
        'relayQueue': _relayById.values
            .map((e) => e.toJson())
            .toList(growable: false),
        if (resp != null) 'pendingResponderAction': resp.toJson(),
      };
      await file.writeAsString(jsonEncode(payload), flush: true);
    } catch (e) {
      debugPrint('SosOutboxAndRelayStore: failed to persist outbox — $e');
    }
  }

  Future<void> setMyPendingSos(PendingMySosEntry? entry) async {
    await ensureLoaded();
    _myPendingSos = entry;
    await _persist();
  }

  Future<void> markMySosSyncedOnline({required String serverSosId}) async {
    await ensureLoaded();
    final current = _myPendingSos;
    if (current == null) return;
    _myPendingSos = current.copyWith(
      serverSosId: serverSosId,
      needsServerCreateOrClaim: false,
    );
    await _persist();
  }

  Future<void> markMySosPendingResolve({
    String status = 'resolved',
    int? resolvedEpochSec,
  }) async {
    await ensureLoaded();
    final current = _myPendingSos;
    if (current == null) return;
    _myPendingSos = current.copyWith(
      status: status,
      resolvedEpochSec: resolvedEpochSec ?? _nowEpochSec(),
      needsServerResolve: true,
    );
    await _persist();
  }

  Future<void> clearMyPendingSos() async {
    await ensureLoaded();
    if (_myPendingSos == null) return;
    _myPendingSos = null;
    await _persist();
  }

  /// Inserts or updates a BLE-received SOS alert in `relayQueue`, deduplicating
  /// by `clientSosId`.
  ///
  /// Returns the stored [RelayedSosEntry], or `null` if rejected (e.g. invalid
  /// hex, mismatched `sosClaimHash`, or already resolved/tombstoned).
  Future<RelayedSosEntry?> upsertRelayedAlert({
    required String clientSosId,
    required String sosClaimHash,
    String? trailId,
    SosReason reason = SosReason.other,
    String message = '',
    String requesterName = '',
    required double lat,
    required double lon,
    double ele = 0.0,
    required int packetEpochSec,
    int hopCount = 0,
  }) async {
    await ensureLoaded();
    final nowSec = _nowEpochSec();
    _pruneExpiredInMemory(nowSec);

    final normId = clientSosId.trim().toLowerCase();
    final normHash = sosClaimHash.trim().toLowerCase();
    if (!_hex16Pattern.hasMatch(normId) || !_hex16Pattern.hasMatch(normHash)) {
      return null;
    }

    final existing = _relayById[normId];
    if (existing != null) {
      if (existing.sosClaimHash != normHash) {
        return null;
      }
      if (existing.isResolved) {
        return null;
      }
      if (packetEpochSec <= existing.packetEpochSec) {
        return existing;
      }
      final updated = existing.copyWith(
        trailId: trailId ?? existing.trailId,
        reason: reason,
        message: message.isNotEmpty ? message : existing.message,
        requesterName: requesterName.isNotEmpty
            ? requesterName
            : existing.requesterName,
        lat: lat,
        lon: lon,
        ele: ele,
        packetEpochSec: packetEpochSec,
        hopCount: hopCount,
        receivedAtEpochSec: nowSec,
        uploadedActiveToServer: false,
      );
      _relayById[normId] = updated;
      await _persist();
      return updated;
    }

    final created = RelayedSosEntry(
      clientSosId: normId,
      sosClaimHash: normHash,
      trailId: trailId,
      reason: reason,
      message: message,
      requesterName: requesterName,
      lat: lat,
      lon: lon,
      ele: ele,
      packetEpochSec: packetEpochSec,
      hopCount: hopCount,
      receivedAtEpochSec: nowSec,
    );
    _relayById[normId] = created;
    await _persist();
    return created;
  }

  /// Verifies [sosRevealTokenHex] (`32` hex chars = `16` bytes) against the
  /// stored `sosClaimHash` (or [expectedClaimHashHex]) in constant time and
  /// transitions the entry to `status: 'resolved'` for 4G upload + 6h tombstoning.
  Future<bool> applyVerifiedResolution({
    required String clientSosId,
    required String sosRevealTokenHex,
    required int resolvedEpochSec,
    String? expectedClaimHashHex,
  }) async {
    await ensureLoaded();
    final nowSec = _nowEpochSec();
    _pruneExpiredInMemory(nowSec);

    final normId = clientSosId.trim().toLowerCase();
    final normSecret = sosRevealTokenHex.trim().toLowerCase();
    final secretBytes = tryHexToBytes(normSecret, expectedByteLength: 16);
    if (!_hex16Pattern.hasMatch(normId) || secretBytes == null) {
      return false;
    }

    final existing = _relayById[normId];
    final targetHash =
        existing?.sosClaimHash ?? expectedClaimHashHex?.trim().toLowerCase();
    if (targetHash != null) {
      if (!verifyPreimageHex(normSecret, targetHash)) {
        return false;
      }
    }

    final derivedHash = bytesToHexLower(computeSosClaimHashBytes(secretBytes));
    if (existing != null) {
      _relayById[normId] = existing.copyWith(
        status: 'resolved',
        sosClaimSecret: normSecret,
        packetEpochSec: math.max(existing.packetEpochSec, resolvedEpochSec),
        receivedAtEpochSec: nowSec,
        uploadedResolvedToServer: false,
      );
    } else {
      _relayById[normId] = RelayedSosEntry(
        clientSosId: normId,
        sosClaimHash: derivedHash,
        status: 'resolved',
        sosClaimSecret: normSecret,
        lat: 0.0,
        lon: 0.0,
        packetEpochSec: resolvedEpochSec,
        receivedAtEpochSec: nowSec,
      );
    }
    await _persist();
    return true;
  }

  /// Marks a relayed SOS entry as uploaded to `/api/v1/live/sos/relay` while
  /// keeping its deduplication/tombstone record in `relayQueue` until 6h expiry.
  Future<void> markRelayedUploaded(
    String clientSosId, {
    String? serverSosId,
    bool resolved = false,
  }) async {
    await ensureLoaded();
    final normId = clientSosId.trim().toLowerCase();
    final existing = _relayById[normId];
    if (existing == null) return;
    _relayById[normId] = existing.copyWith(
      serverSosId: serverSosId ?? existing.serverSosId,
      uploadedActiveToServer: resolved ? existing.uploadedActiveToServer : true,
      uploadedResolvedToServer: resolved
          ? true
          : existing.uploadedResolvedToServer,
    );
    final resp = _pendingResponderAction;
    if (resp != null &&
        resp.clientSosId == normId &&
        serverSosId != null &&
        serverSosId.isNotEmpty) {
      _pendingResponderAction = resp.copyWith(serverSosId: serverSosId);
    }
    await _persist();
  }

  Future<void> setPendingResponderAction(PendingResponderAction? action) async {
    await ensureLoaded();
    _pendingResponderAction = action;
    await _persist();
  }

  Future<void> attachServerSosIdToResponderAction(
    String clientSosId,
    String serverSosId,
  ) async {
    await ensureLoaded();
    final current = _pendingResponderAction;
    if (current == null) return;
    if (current.clientSosId != clientSosId.trim().toLowerCase()) return;
    _pendingResponderAction = current.copyWith(serverSosId: serverSosId);
    await _persist();
  }

  Future<void> clearPendingResponderAction() async {
    await ensureLoaded();
    if (_pendingResponderAction == null) return;
    _pendingResponderAction = null;
    await _persist();
  }
}

String? _optStr(Object? raw) {
  if (raw == null) return null;
  final s = raw.toString().trim();
  return s.isEmpty ? null : s;
}

double _numDouble(Object? raw, [double fallback = 0.0]) {
  if (raw is num) {
    final d = raw.toDouble();
    return d.isFinite ? d : fallback;
  }
  if (raw is String) {
    final d = double.tryParse(raw.trim());
    if (d != null && d.isFinite) return d;
  }
  return fallback;
}

double? _optDouble(Object? raw) {
  if (raw == null) return null;
  if (raw is num) {
    final d = raw.toDouble();
    return d.isFinite ? d : null;
  }
  if (raw is String) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    final d = double.tryParse(s);
    return (d != null && d.isFinite) ? d : null;
  }
  return null;
}

int _numInt(Object? raw, [int fallback = 0]) {
  if (raw is int) return raw;
  if (raw is num) return raw.isFinite ? raw.round() : fallback;
  if (raw is String) return int.tryParse(raw.trim()) ?? fallback;
  return fallback;
}

int? _optInt(Object? raw) {
  if (raw == null) return null;
  if (raw is int) return raw;
  if (raw is num) return raw.isFinite ? raw.round() : null;
  if (raw is String) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    return int.tryParse(s);
  }
  return null;
}

bool _boolVal(Object? raw, [bool fallback = false]) {
  if (raw is bool) return raw;
  if (raw is num) return raw != 0;
  if (raw is String) {
    final l = raw.trim().toLowerCase();
    if (l == 'true' || l == '1') return true;
    if (l == 'false' || l == '0') return false;
  }
  return fallback;
}
