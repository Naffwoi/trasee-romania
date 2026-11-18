import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:wanderer/models/live/trail_live_models.dart' show SosReason;
import 'package:wanderer/services/ble/sos_crypto_and_outbox.dart'
    show
        bytesToHexLower,
        computeSosClaimHashBytes,
        constantTimeBytesEqual,
        deriveBleMemberColor,
        tryHexToBytes,
        verifyPreimageBytes;

/// Protocol v1 magic/version byte (`'T'` = `0x54`: magic `0x5`, version `0x4` = v1).
const int kBleProtocolMagicVer = 0x54;

/// Maximum packed GATT characteristic payload (`CHAR_SYNC_READ`, negotiated MTU 185).
const int kBleMaxSyncBufferBytes = 180;

/// Default multi-hop TTL for group position beacons (max 3 hops).
const int kDefaultGroupTtl = 3;

/// Default multi-hop TTL for emergency SOS / ACK / Resolved frames (max 5 hops).
const int kDefaultSosTtl = 5;

/// Superseding window in seconds for updated SOS alerts and identical-flag ACKs.
const int kBleSupersedeWindowSec = 30;

/// Tombstone retention window in seconds after a verified `PKT_SOS_RESOLVED` (6h).
const int kBleTombstoneWindowSec = 6 * 3600;

/// Maximum allowed forward clock skew for `PKT_GROUP_POS` timestamps (120s).
const int kBleMaxFutureSkewSec = 120;

/// Wire packet type identifiers (`byte[1]` of the 4-byte envelope header).
enum BlePacketType {
  groupPos(0x01),
  sosAlert(0x02),
  sosAck(0x03),
  sosResolved(0x04);

  const BlePacketType(this.wireValue);
  final int wireValue;

  static BlePacketType? fromWire(int byteValue) => switch (byteValue) {
    0x01 => BlePacketType.groupPos,
    0x02 => BlePacketType.sosAlert,
    0x03 => BlePacketType.sosAck,
    0x04 => BlePacketType.sosResolved,
    _ => null,
  };

  /// Packing priority inside `CHAR_SYNC_READ` (`SOS_ALERT` -> `SOS_RESOLVED` ->
  /// `SOS_ACK` -> `GROUP_POS`).
  int get syncPriority => switch (this) {
    BlePacketType.sosAlert => 0,
    BlePacketType.sosResolved => 1,
    BlePacketType.sosAck => 2,
    BlePacketType.groupPos => 3,
  };
}

/// Packs `hopCount` (`0..15`) and `ttlRemaining` (`0..15`) into header `byte[2]`.
int packTtlHops({required int hopCount, required int ttlRemaining}) {
  final h = hopCount.clamp(0, 15);
  final t = ttlRemaining.clamp(0, 15);
  return ((h & 0x0F) << 4) | (t & 0x0F);
}

/// Extracts `hopCount` (`0..15`) from header `byte[2]`.
int extractHopCount(int ttlHops) => (ttlHops >> 4) & 0x0F;

/// Extracts `ttlRemaining` (`0..15`) from header `byte[2]`.
int extractTtlRemaining(int ttlHops) => ttlHops & 0x0F;

/// Truncates [input] to at most [maxBytes] of valid UTF-8 without ever splitting
/// a multi-byte Unicode scalar value (e.g. Romanian diacritics `ăâîșț` or emojis).
Uint8List truncateUtf8RuneSafe(String input, int maxBytes) {
  if (maxBytes <= 0 || input.isEmpty) {
    return Uint8List(0);
  }
  final builder = BytesBuilder(copy: false);
  for (final rune in input.runes) {
    final runeBytes = utf8.encode(String.fromCharCode(rune));
    if (builder.length + runeBytes.length > maxBytes) {
      break;
    }
    builder.add(runeBytes);
  }
  return builder.toBytes();
}

/// Inspects the 4-byte envelope header of [raw] and returns its [BlePacketType]
/// if the magic byte and `bodyLen` match `raw.length` (`30..88` bytes).
BlePacketType? inspectBleFrameType(Uint8List raw) {
  if (raw.length < 30 || raw.length > 88) return null;
  if (raw[0] != kBleProtocolMagicVer) return null;
  final pktType = BlePacketType.fromWire(raw[1]);
  if (pktType == null) return null;
  final bodyLen = raw[3];
  if (bodyLen < 26 || bodyLen > 84 || 4 + bodyLen != raw.length) {
    return null;
  }
  return pktType;
}

/// Increments `hopCount` and decrements `ttlRemaining` in `byte[2]` for
/// multi-hop relaying without invalidating any packet MAC or integrity hash.
///
/// Returns `null` if [raw] is malformed, `ttlRemaining == 0`, or `hopCount >= 15`.
Uint8List? decrementTtlForRelay(Uint8List raw) {
  if (inspectBleFrameType(raw) == null) return null;
  final hops = extractHopCount(raw[2]);
  final ttl = extractTtlRemaining(raw[2]);
  if (ttl <= 0 || hops >= 15) return null;
  final relayed = Uint8List.fromList(raw);
  relayed[2] = packTtlHops(hopCount: hops + 1, ttlRemaining: ttl - 1);
  return relayed;
}

/// Packs multiple BLE mesh frames into a single `<= maxBytes` (`180B` default)
/// GATT buffer `[frameCount: uint8][frame1...][frame2...]` ordered by emergency
/// priority (`SOS_ALERT` -> `SOS_RESOLVED` -> `SOS_ACK` -> `GROUP_POS`).
Uint8List packSyncBuffer(
  List<Uint8List> frames, {
  int maxBytes = kBleMaxSyncBufferBytes,
}) {
  if (maxBytes <= 1 || frames.isEmpty) {
    return Uint8List.fromList(const <int>[0]);
  }

  final valid = <({BlePacketType type, int index, Uint8List bytes})>[];
  for (var i = 0; i < frames.length; i++) {
    final f = frames[i];
    final t = inspectBleFrameType(f);
    if (t != null) {
      valid.add((type: t, index: i, bytes: f));
    }
  }
  if (valid.isEmpty) {
    return Uint8List.fromList(const <int>[0]);
  }

  valid.sort((a, b) {
    final cmp = a.type.syncPriority.compareTo(b.type.syncPriority);
    return cmp != 0 ? cmp : a.index.compareTo(b.index);
  });

  final selected = <Uint8List>[];
  var usedBytes = 1; // 1 byte for leading count
  for (final item in valid) {
    if (selected.length >= 255) break;
    if (usedBytes + item.bytes.length > maxBytes) {
      continue;
    }
    selected.add(item.bytes);
    usedBytes += item.bytes.length;
  }

  if (selected.isEmpty) {
    return Uint8List.fromList(const <int>[0]);
  }

  final out = Uint8List(usedBytes);
  out[0] = selected.length;
  var offset = 1;
  for (final frame in selected) {
    out.setRange(offset, offset + frame.length, frame);
    offset += frame.length;
  }
  return out;
}

/// Unpacks a GATT sync buffer formatted by [packSyncBuffer] (`[count][frame1...]`)
/// into self-delimited raw frames, stopping safely if truncated or malformed.
List<Uint8List> unpackSyncBuffer(Uint8List buf) {
  if (buf.isEmpty) return const <Uint8List>[];
  final count = buf[0];
  if (count == 0 || buf.length < 31) return const <Uint8List>[];

  final out = <Uint8List>[];
  var offset = 1;
  while (out.length < count && offset + 4 <= buf.length) {
    if (buf[offset] != kBleProtocolMagicVer) {
      break;
    }
    final pktType = BlePacketType.fromWire(buf[offset + 1]);
    if (pktType == null) {
      break;
    }
    final bodyLen = buf[offset + 3];
    final frameLen = 4 + bodyLen;
    if (bodyLen < 26 || bodyLen > 84 || offset + frameLen > buf.length) {
      break;
    }
    out.add(Uint8List.fromList(buf.sublist(offset, offset + frameLen)));
    offset += frameLen;
  }
  return out;
}

/// Computes the 8-byte connectionless state digest advertised in Android
/// `ServiceData` (`0x7A4E`): `[flags 1B][sosDigest 3B][groupDigest 4B]`.
///
/// - `flags`: `bit0 = hasSos` (`0x02`/`0x04`), `bit1 = hasAck` (`0x03`),
///   `bit2 = hasGroup` (`0x01`).
/// - `byte[2]` (`ttlHops`) is zeroed during hashing so hop count differences
///   do not trigger redundant GATT connections between already-synced peers.
Uint8List computeSyncDigest8B(List<Uint8List> frames) {
  final out = Uint8List(8);
  if (frames.isEmpty) return out;

  var flags = 0;
  final sosBuilder = BytesBuilder(copy: false);
  final grpBuilder = BytesBuilder(copy: false);
  var hasAnySosDomain = false;
  var hasAnyGroupDomain = false;

  for (final f in frames) {
    final pktType = inspectBleFrameType(f);
    if (pktType == null) continue;
    final canonical = Uint8List.fromList(f);
    canonical[2] = 0;

    switch (pktType) {
      case BlePacketType.sosAlert:
      case BlePacketType.sosResolved:
        flags |= 0x01;
        if (!hasAnySosDomain) {
          sosBuilder.add(utf8.encode('trasee-sync-sos-v1'));
          hasAnySosDomain = true;
        }
        sosBuilder.add(canonical);
      case BlePacketType.sosAck:
        flags |= 0x02;
        if (!hasAnySosDomain) {
          sosBuilder.add(utf8.encode('trasee-sync-sos-v1'));
          hasAnySosDomain = true;
        }
        sosBuilder.add(canonical);
      case BlePacketType.groupPos:
        flags |= 0x04;
        if (!hasAnyGroupDomain) {
          grpBuilder.add(utf8.encode('trasee-sync-grp-v1'));
          hasAnyGroupDomain = true;
        }
        grpBuilder.add(canonical);
    }
  }

  out[0] = flags;
  if (hasAnySosDomain) {
    final sosHash = sha256.convert(sosBuilder.toBytes()).bytes;
    out[1] = sosHash[0];
    out[2] = sosHash[1];
    out[3] = sosHash[2];
  }
  if (hasAnyGroupDomain) {
    final grpHash = sha256.convert(grpBuilder.toBytes()).bytes;
    out[4] = grpHash[0];
    out[5] = grpHash[1];
    out[6] = grpHash[2];
    out[7] = grpHash[3];
  }
  return out;
}

/// HKDF-SHA256 key schedule and Encrypt-then-MAC cipher for `PKT_GROUP_POS` (`0x01`).
///
/// Derived purely from the 6-character group code:
/// - `PRK = HMAC-SHA256("trasee-ble-salt-v1", "trasee-ble-group-v1:" + code)`
/// - `kEnc = HMAC-SHA256(PRK, "enc\x01")`
/// - `kMac = HMAC-SHA256(PRK, "mac\x01")`
class GroupBleCipher {
  GroupBleCipher._({
    required this.groupCode,
    required Uint8List kEnc,
    required Uint8List kMac,
  }) : _kEnc = kEnc,
       _kMac = kMac;

  final String groupCode;
  final Uint8List _kEnc;
  final Uint8List _kMac;

  factory GroupBleCipher.fromGroupCode(String groupCode) {
    final code = groupCode.trim().toUpperCase();
    if (code.isEmpty) {
      throw ArgumentError.value(
        groupCode,
        'groupCode',
        'Group code must not be empty',
      );
    }
    final saltBytes = utf8.encode('trasee-ble-salt-v1');
    final ikmBytes = utf8.encode('trasee-ble-group-v1:$code');
    final prk = Hmac(sha256, saltBytes).convert(ikmBytes).bytes;
    final kEnc = Uint8List.fromList(
      Hmac(sha256, prk).convert(const <int>[0x65, 0x6E, 0x63, 0x01]).bytes,
    );
    final kMac = Uint8List.fromList(
      Hmac(sha256, prk).convert(const <int>[0x6D, 0x61, 0x63, 0x01]).bytes,
    );
    return GroupBleCipher._(groupCode: code, kEnc: kEnc, kMac: kMac);
  }

  Uint8List computeKeystream32(Uint8List nonce8B) {
    final blockInput = Uint8List(9);
    blockInput.setRange(0, 8, nonce8B);
    blockInput[8] = 0x01;
    final digest = Hmac(sha256, _kEnc).convert(blockInput);
    return Uint8List.fromList(digest.bytes);
  }

  Uint8List computeMac4B({
    required Uint8List nonce8B,
    required Uint8List ciphertext32,
  }) {
    final macInput = Uint8List(3 + 8 + 32);
    macInput[0] = kBleProtocolMagicVer;
    macInput[1] = BlePacketType.groupPos.wireValue;
    macInput[2] = 44;
    macInput.setRange(3, 11, nonce8B);
    macInput.setRange(11, 43, ciphertext32);
    final digest = Hmac(sha256, _kMac).convert(macInput);
    return Uint8List.fromList(digest.bytes.sublist(0, 4));
  }
}

/// Packet `0x01`: Authenticated & encrypted group member position (`48` bytes fixed).
class BleGroupPosPacket {
  const BleGroupPosPacket({
    required this.memberIdHex,
    required this.lat,
    required this.lon,
    this.eleM = 0,
    this.accuracyM = 15,
    this.inNavigation = true,
    this.lowBattery = false,
    this.memberLeft = false,
    this.headingDeg,
    this.speedMps,
    required this.displayName,
    required this.timestampSec,
    this.nonceSalt,
    this.hopCount = 0,
    this.ttlRemaining = kDefaultGroupTtl,
    this.rssi,
    this.peerId,
  });

  static const int wireByteLength = 48;
  static const int bodyByteLength = 44;

  static const int flagInNavigation = 0x01;
  static const int flagHasHeading = 0x02;
  static const int flagHasSpeed = 0x04;
  static const int flagLowBattery = 0x08;
  static const int flagMemberLeft = 0x10;

  final String memberIdHex;
  final double lat;
  final double lon;
  final int eleM;
  final int accuracyM;
  final bool inNavigation;
  final bool lowBattery;
  final bool memberLeft;
  final double? headingDeg;
  final double? speedMps;
  final String displayName;
  final int timestampSec;
  final int? nonceSalt;
  final int hopCount;
  final int ttlRemaining;
  final int? rssi;
  final String? peerId;

  String get colorHex => deriveBleMemberColor(memberIdHex);

  int get flags {
    var f = 0;
    if (inNavigation) f |= flagInNavigation;
    final h = headingDeg;
    if (h != null && h.isFinite) f |= flagHasHeading;
    final s = speedMps;
    if (s != null && s.isFinite && s >= 0) f |= flagHasSpeed;
    if (lowBattery) f |= flagLowBattery;
    if (memberLeft) f |= flagMemberLeft;
    return f;
  }

  Uint8List encode(GroupBleCipher cipher, {math.Random? random}) {
    final memberBytes =
        tryHexToBytes(memberIdHex, expectedByteLength: 6) ??
        Uint8List.fromList(
          sha256.convert(utf8.encode(memberIdHex.trim())).bytes.sublist(0, 6),
        );

    final salt =
        nonceSalt ??
        (() {
          final rng = random ?? math.Random.secure();
          return (rng.nextInt(0x10000) << 16) | rng.nextInt(0x10000);
        })();

    final nonce8B = Uint8List(8);
    final nonceBd = ByteData.sublistView(nonce8B);
    nonceBd.setUint32(0, timestampSec.toUnsigned(32), Endian.big);
    nonceBd.setUint32(4, salt.toUnsigned(32), Endian.big);

    final plaintext = Uint8List(32);
    plaintext.setRange(0, 6, memberBytes);
    final ptBd = ByteData.sublistView(plaintext);
    final latE7 = (lat.clamp(-90.0, 90.0) * 1e7).round();
    final lonE7 = (lon.clamp(-180.0, 180.0) * 1e7).round();
    ptBd.setInt32(6, latE7, Endian.big);
    ptBd.setInt32(10, lonE7, Endian.big);
    ptBd.setInt16(14, eleM.clamp(-1000, 9000), Endian.big);
    plaintext[16] = accuracyM.clamp(1, 255);
    plaintext[17] = flags;

    final h = headingDeg;
    if (h != null && h.isFinite) {
      final normDeg = ((h % 360.0) + 360.0) % 360.0;
      plaintext[18] = (normDeg / 2.0).round() % 180;
    } else {
      plaintext[18] = 0xFF;
    }

    final s = speedMps;
    if (s != null && s.isFinite && s >= 0) {
      plaintext[19] = (s * 10.0).round().clamp(0, 254);
    } else {
      plaintext[19] = 0xFF;
    }

    final nameBytes = truncateUtf8RuneSafe(displayName.trim(), 12);
    plaintext.setRange(20, 20 + nameBytes.length, nameBytes);

    final ks32 = cipher.computeKeystream32(nonce8B);
    final ciphertext32 = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      ciphertext32[i] = plaintext[i] ^ ks32[i];
    }

    final mac4B = cipher.computeMac4B(
      nonce8B: nonce8B,
      ciphertext32: ciphertext32,
    );

    final frame = Uint8List(wireByteLength);
    frame[0] = kBleProtocolMagicVer;
    frame[1] = BlePacketType.groupPos.wireValue;
    frame[2] = packTtlHops(hopCount: hopCount, ttlRemaining: ttlRemaining);
    frame[3] = bodyByteLength;
    frame.setRange(4, 12, nonce8B);
    frame.setRange(12, 44, ciphertext32);
    frame.setRange(44, 48, mac4B);
    return frame;
  }

  static BleGroupPosPacket? decode(
    Uint8List raw, {
    required GroupBleCipher cipher,
    int? rssi,
    String? peerId,
  }) {
    if (raw.length != wireByteLength) return null;
    if (raw[0] != kBleProtocolMagicVer ||
        raw[1] != BlePacketType.groupPos.wireValue ||
        raw[3] != bodyByteLength) {
      return null;
    }

    final nonce8B = Uint8List.sublistView(raw, 4, 12);
    final ciphertext32 = Uint8List.sublistView(raw, 12, 44);
    final receivedMac = Uint8List.sublistView(raw, 44, 48);
    final expectedMac = cipher.computeMac4B(
      nonce8B: nonce8B,
      ciphertext32: ciphertext32,
    );
    if (!constantTimeBytesEqual(receivedMac, expectedMac)) {
      return null;
    }

    final ks32 = cipher.computeKeystream32(nonce8B);
    final plaintext = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      plaintext[i] = ciphertext32[i] ^ ks32[i];
    }

    final nonceBd = ByteData.sublistView(nonce8B);
    final tsSec = nonceBd.getUint32(0, Endian.big);
    final salt = nonceBd.getUint32(4, Endian.big);

    final ptBd = ByteData.sublistView(plaintext);
    final memberIdHex = bytesToHexLower(Uint8List.sublistView(plaintext, 0, 6));
    final latE7 = ptBd.getInt32(6, Endian.big);
    final lonE7 = ptBd.getInt32(10, Endian.big);
    final eleM = ptBd.getInt16(14, Endian.big);
    final accuracyM = plaintext[16] == 0 ? 1 : plaintext[16];
    final pktFlags = plaintext[17];
    final rawHeading = plaintext[18];
    final rawSpeed = plaintext[19];

    final lat = latE7 / 1e7;
    final lon = lonE7 / 1e7;
    if (lat < -90.0 || lat > 90.0 || lon < -180.0 || lon > 180.0) {
      return null;
    }

    double? headingDeg;
    if ((pktFlags & flagHasHeading) != 0 && rawHeading < 180) {
      headingDeg = (rawHeading * 2).toDouble();
    }

    double? speedMps;
    if ((pktFlags & flagHasSpeed) != 0 && rawSpeed <= 254) {
      speedMps = rawSpeed / 10.0;
    }

    var nameEnd = 32;
    while (nameEnd > 20 && plaintext[nameEnd - 1] == 0) {
      nameEnd--;
    }
    final decodedName = nameEnd > 20
        ? utf8.decode(
            Uint8List.sublistView(plaintext, 20, nameEnd),
            allowMalformed: true,
          )
        : '';

    return BleGroupPosPacket(
      memberIdHex: memberIdHex,
      lat: lat,
      lon: lon,
      eleM: eleM,
      accuracyM: accuracyM,
      inNavigation: (pktFlags & flagInNavigation) != 0,
      lowBattery: (pktFlags & flagLowBattery) != 0,
      memberLeft: (pktFlags & flagMemberLeft) != 0,
      headingDeg: headingDeg,
      speedMps: speedMps,
      displayName: decodedName,
      timestampSec: tsSec,
      nonceSalt: salt,
      hopCount: extractHopCount(raw[2]),
      ttlRemaining: extractTtlRemaining(raw[2]),
      rssi: rssi,
      peerId: peerId,
    );
  }
}

/// Packet `0x02`: Public emergency SOS broadcast (`40..88` bytes) carrying the
/// 8-byte Lamport commitment `sosClaimHash` and 4-byte SHA-256 integrity tag.
class BleSosAlertPacket {
  const BleSosAlertPacket({
    required this.clientSosId,
    required this.sosClaimHash,
    this.reason = SosReason.other,
    this.batteryCritical = false,
    this.isStationary = false,
    required this.lat,
    required this.lon,
    this.eleM = 0,
    required this.createdEpochSec,
    this.shortMsg = '',
    this.hopCount = 0,
    this.ttlRemaining = kDefaultSosTtl,
    this.rssi,
    this.peerId,
  });

  static const int minWireByteLength = 40;
  static const int maxWireByteLength = 88;
  static const int maxShortMsgBytes = 48;

  static const int flagBatteryCritical = 0x10;
  static const int flagIsStationary = 0x20;

  final String clientSosId;
  final String sosClaimHash;
  final SosReason reason;
  final bool batteryCritical;
  final bool isStationary;
  final double lat;
  final double lon;
  final int eleM;
  final int createdEpochSec;
  final String shortMsg;
  final int hopCount;
  final int ttlRemaining;
  final int? rssi;
  final String? peerId;

  int get reasonAndFlags {
    final nibble = switch (reason) {
      SosReason.lost => 0,
      SosReason.injury => 1,
      SosReason.exhaustion => 2,
      SosReason.other => 3,
    };
    var out = nibble;
    if (batteryCritical) out |= flagBatteryCritical;
    if (isStationary) out |= flagIsStationary;
    return out;
  }

  /// Packs optional `requesterName` and `message` into a single `<= 48`-byte
  /// UTF-8 `shortMsg` (`"Name: message"` when both are present).
  static String composeShortMsg({
    String requesterName = '',
    String message = '',
  }) {
    final cleanName = requesterName.trim();
    final cleanMsg = message.trim();
    final combined = switch ((cleanName.isNotEmpty, cleanMsg.isNotEmpty)) {
      (true, true) => '$cleanName: $cleanMsg',
      (true, false) => '$cleanName:',
      (false, true) => cleanMsg,
      (false, false) => '',
    };
    final truncated = truncateUtf8RuneSafe(combined, maxShortMsgBytes);
    return utf8.decode(truncated, allowMalformed: true);
  }

  /// Splits `shortMsg` back into `(requesterName, message)` when formatted via
  /// [composeShortMsg].
  ({String requesterName, String message}) splitRequesterAndMessage() {
    final text = shortMsg.trim();
    if (text.isEmpty) return (requesterName: '', message: '');
    final colonIdx = text.indexOf(':');
    if (colonIdx > 0 && colonIdx <= 24) {
      final candidateName = text.substring(0, colonIdx).trim();
      final rest = text.substring(colonIdx + 1).trim();
      return (requesterName: candidateName, message: rest);
    }
    return (requesterName: '', message: text);
  }

  Uint8List encode() {
    final idBytes = tryHexToBytes(clientSosId, expectedByteLength: 8);
    final hashBytes = tryHexToBytes(sosClaimHash, expectedByteLength: 8);
    if (idBytes == null) {
      throw ArgumentError.value(
        clientSosId,
        'clientSosId',
        'Must be 16 hex characters (8 bytes)',
      );
    }
    if (hashBytes == null) {
      throw ArgumentError.value(
        sosClaimHash,
        'sosClaimHash',
        'Must be 16 hex characters (8 bytes)',
      );
    }

    final msgBytes = truncateUtf8RuneSafe(shortMsg, maxShortMsgBytes);
    final msgLen = msgBytes.length;
    final bodyLen = 36 + msgLen;
    final totalLen = 4 + bodyLen;

    final frame = Uint8List(totalLen);
    frame[0] = kBleProtocolMagicVer;
    frame[1] = BlePacketType.sosAlert.wireValue;
    frame[2] = packTtlHops(hopCount: hopCount, ttlRemaining: ttlRemaining);
    frame[3] = bodyLen;
    frame.setRange(4, 12, idBytes);
    frame.setRange(12, 20, hashBytes);
    frame[20] = reasonAndFlags;

    final bd = ByteData.sublistView(frame);
    bd.setInt32(21, (lat.clamp(-90.0, 90.0) * 1e7).round(), Endian.big);
    bd.setInt32(25, (lon.clamp(-180.0, 180.0) * 1e7).round(), Endian.big);
    bd.setInt16(29, eleM.clamp(-1000, 9000), Endian.big);
    bd.setUint32(31, createdEpochSec.toUnsigned(32), Endian.big);
    frame[35] = msgLen;
    if (msgLen > 0) {
      frame.setRange(36, 36 + msgLen, msgBytes);
    }

    final tag4B = _computeIntegrity4B(
      domainAscii: 'trasee-ble-sos-v1',
      pktType: BlePacketType.sosAlert.wireValue,
      bodyLen: bodyLen,
      payloadWithoutTag: Uint8List.sublistView(frame, 4, 36 + msgLen),
    );
    frame.setRange(36 + msgLen, 40 + msgLen, tag4B);
    return frame;
  }

  static BleSosAlertPacket? decode(
    Uint8List raw, {
    int? rssi,
    String? peerId,
  }) {
    if (raw.length < minWireByteLength || raw.length > maxWireByteLength) {
      return null;
    }
    if (raw[0] != kBleProtocolMagicVer ||
        raw[1] != BlePacketType.sosAlert.wireValue) {
      return null;
    }
    final msgLen = raw[35];
    if (msgLen > maxShortMsgBytes) return null;
    final bodyLen = 36 + msgLen;
    if (raw[3] != bodyLen || raw.length != 4 + bodyLen) {
      return null;
    }

    final expectedTag = _computeIntegrity4B(
      domainAscii: 'trasee-ble-sos-v1',
      pktType: BlePacketType.sosAlert.wireValue,
      bodyLen: bodyLen,
      payloadWithoutTag: Uint8List.sublistView(raw, 4, 36 + msgLen),
    );
    final actualTag = Uint8List.sublistView(raw, 36 + msgLen, 40 + msgLen);
    if (!constantTimeBytesEqual(actualTag, expectedTag)) {
      return null;
    }

    final bd = ByteData.sublistView(raw);
    final lat = bd.getInt32(21, Endian.big) / 1e7;
    final lon = bd.getInt32(25, Endian.big) / 1e7;
    if (lat < -90.0 || lat > 90.0 || lon < -180.0 || lon > 180.0) {
      return null;
    }
    final eleM = bd.getInt16(29, Endian.big);
    final createdEpochSec = bd.getUint32(31, Endian.big);

    final rf = raw[20];
    final reason = switch (rf & 0x0F) {
      0 => SosReason.lost,
      1 => SosReason.injury,
      2 => SosReason.exhaustion,
      _ => SosReason.other,
    };

    final decodedMsg = msgLen > 0
        ? utf8.decode(
            Uint8List.sublistView(raw, 36, 36 + msgLen),
            allowMalformed: true,
          )
        : '';

    return BleSosAlertPacket(
      clientSosId: bytesToHexLower(Uint8List.sublistView(raw, 4, 12)),
      sosClaimHash: bytesToHexLower(Uint8List.sublistView(raw, 12, 20)),
      reason: reason,
      batteryCritical: (rf & flagBatteryCritical) != 0,
      isStationary: (rf & flagIsStationary) != 0,
      lat: lat,
      lon: lon,
      eleM: eleM,
      createdEpochSec: createdEpochSec,
      shortMsg: decodedMsg,
      hopCount: extractHopCount(raw[2]),
      ttlRemaining: extractTtlRemaining(raw[2]),
      rssi: rssi,
      peerId: peerId,
    );
  }
}

/// Packet `0x03`: Two-way responder / Store-and-Forward mule confirmation (`30` bytes fixed).
class BleSosAckPacket {
  const BleSosAckPacket({
    required this.clientSosId,
    required this.responderIdHex,
    this.etaMin,
    this.distM,
    this.comingToHelp = false,
    this.uploadedToServer = false,
    this.cancelled = false,
    required this.ackEpochSec,
    this.hopCount = 0,
    this.ttlRemaining = kDefaultSosTtl,
    this.rssi,
    this.peerId,
  });

  static const int wireByteLength = 30;
  static const int bodyByteLength = 26;

  static const int flagComingToHelp = 0x01;
  static const int flagUploadedToServer = 0x02;
  static const int flagCancelled = 0x04;

  final String clientSosId;
  final String responderIdHex;
  final int? etaMin;
  final int? distM;
  final bool comingToHelp;
  final bool uploadedToServer;
  final bool cancelled;
  final int ackEpochSec;
  final int hopCount;
  final int ttlRemaining;
  final int? rssi;
  final String? peerId;

  int get ackFlags {
    var f = 0;
    if (comingToHelp) f |= flagComingToHelp;
    if (uploadedToServer) f |= flagUploadedToServer;
    if (cancelled) f |= flagCancelled;
    return f;
  }

  Uint8List encode() {
    final idBytes = tryHexToBytes(clientSosId, expectedByteLength: 8);
    final respBytes = tryHexToBytes(responderIdHex, expectedByteLength: 6);
    if (idBytes == null) {
      throw ArgumentError.value(
        clientSosId,
        'clientSosId',
        'Must be 16 hex characters (8 bytes)',
      );
    }
    if (respBytes == null) {
      throw ArgumentError.value(
        responderIdHex,
        'responderIdHex',
        'Must be 12 hex characters (6 bytes)',
      );
    }

    final frame = Uint8List(wireByteLength);
    frame[0] = kBleProtocolMagicVer;
    frame[1] = BlePacketType.sosAck.wireValue;
    frame[2] = packTtlHops(hopCount: hopCount, ttlRemaining: ttlRemaining);
    frame[3] = bodyByteLength;
    frame.setRange(4, 12, idBytes);
    frame.setRange(12, 18, respBytes);

    final eta = etaMin;
    frame[18] = (eta != null && eta >= 0) ? eta.clamp(0, 254) : 255;

    final bd = ByteData.sublistView(frame);
    final d = distM;
    final wireDist = (d != null && d >= 0) ? d.clamp(0, 65534) : 65535;
    bd.setUint16(19, wireDist.toUnsigned(16), Endian.big);
    frame[21] = ackFlags;
    bd.setUint32(22, ackEpochSec.toUnsigned(32), Endian.big);

    final tag4B = _computeIntegrity4B(
      domainAscii: 'trasee-ble-ack-v1',
      pktType: BlePacketType.sosAck.wireValue,
      bodyLen: bodyByteLength,
      payloadWithoutTag: Uint8List.sublistView(frame, 4, 26),
    );
    frame.setRange(26, 30, tag4B);
    return frame;
  }

  static BleSosAckPacket? decode(
    Uint8List raw, {
    int? rssi,
    String? peerId,
  }) {
    if (raw.length != wireByteLength) return null;
    if (raw[0] != kBleProtocolMagicVer ||
        raw[1] != BlePacketType.sosAck.wireValue ||
        raw[3] != bodyByteLength) {
      return null;
    }

    final expectedTag = _computeIntegrity4B(
      domainAscii: 'trasee-ble-ack-v1',
      pktType: BlePacketType.sosAck.wireValue,
      bodyLen: bodyByteLength,
      payloadWithoutTag: Uint8List.sublistView(raw, 4, 26),
    );
    final actualTag = Uint8List.sublistView(raw, 26, 30);
    if (!constantTimeBytesEqual(actualTag, expectedTag)) {
      return null;
    }

    final bd = ByteData.sublistView(raw);
    final rawEta = raw[18];
    final rawDist = bd.getUint16(19, Endian.big);
    final flags = raw[21];
    final ackEpochSec = bd.getUint32(22, Endian.big);

    return BleSosAckPacket(
      clientSosId: bytesToHexLower(Uint8List.sublistView(raw, 4, 12)),
      responderIdHex: bytesToHexLower(Uint8List.sublistView(raw, 12, 18)),
      etaMin: rawEta == 255 ? null : rawEta,
      distM: rawDist == 65535 ? null : rawDist,
      comingToHelp: (flags & flagComingToHelp) != 0,
      uploadedToServer: (flags & flagUploadedToServer) != 0,
      cancelled: (flags & flagCancelled) != 0,
      ackEpochSec: ackEpochSec,
      hopCount: extractHopCount(raw[2]),
      ttlRemaining: extractTtlRemaining(raw[2]),
      rssi: rssi,
      peerId: peerId,
    );
  }
}

/// Packet `0x04`: Preimage-authenticated SOS resolution/cancellation (`37` bytes fixed).
///
/// Carries the victim's 16-byte `sosRevealToken` (`sosClaimSecret`), allowing
/// every BLE peer and Store-and-Forward server to verify
/// `SHA-256("trasee-sos-claim-v1:" || sosRevealToken)[0..8] == sosClaimHash`.
class BleSosResolvedPacket {
  BleSosResolvedPacket({
    required this.clientSosId,
    this.status = statusResolved,
    required this.resolvedEpochSec,
    required Uint8List sosRevealToken,
    this.hopCount = 0,
    this.ttlRemaining = kDefaultSosTtl,
    this.rssi,
    this.peerId,
  }) : _sosRevealToken = Uint8List.fromList(sosRevealToken) {
    if (_sosRevealToken.length != 16) {
      throw ArgumentError.value(
        sosRevealToken.length,
        'sosRevealToken',
        'Must be exactly 16 bytes',
      );
    }
  }

  factory BleSosResolvedPacket.fromHexSecret({
    required String clientSosId,
    int status = statusResolved,
    required int resolvedEpochSec,
    required String sosClaimSecretHex,
    int hopCount = 0,
    int ttlRemaining = kDefaultSosTtl,
    int? rssi,
    String? peerId,
  }) {
    final tokenBytes = tryHexToBytes(sosClaimSecretHex, expectedByteLength: 16);
    if (tokenBytes == null) {
      throw ArgumentError.value(
        sosClaimSecretHex,
        'sosClaimSecretHex',
        'Must be 32 hex characters (16 bytes)',
      );
    }
    return BleSosResolvedPacket(
      clientSosId: clientSosId,
      status: status,
      resolvedEpochSec: resolvedEpochSec,
      sosRevealToken: tokenBytes,
      hopCount: hopCount,
      ttlRemaining: ttlRemaining,
      rssi: rssi,
      peerId: peerId,
    );
  }

  static const int wireByteLength = 37;
  static const int bodyByteLength = 33;

  static const int statusResolved = 0x01;
  static const int statusCancelled = 0x02;

  final String clientSosId;
  final int status;
  final int resolvedEpochSec;
  final Uint8List _sosRevealToken;
  final int hopCount;
  final int ttlRemaining;
  final int? rssi;
  final String? peerId;

  Uint8List get sosRevealToken => Uint8List.fromList(_sosRevealToken);

  String get sosRevealTokenHex => bytesToHexLower(_sosRevealToken);

  Uint8List encode() {
    final idBytes = tryHexToBytes(clientSosId, expectedByteLength: 8);
    if (idBytes == null) {
      throw ArgumentError.value(
        clientSosId,
        'clientSosId',
        'Must be 16 hex characters (8 bytes)',
      );
    }
    if (status != statusResolved && status != statusCancelled) {
      throw ArgumentError.value(
        status,
        'status',
        'Must be statusResolved (0x01) or statusCancelled (0x02)',
      );
    }

    final frame = Uint8List(wireByteLength);
    frame[0] = kBleProtocolMagicVer;
    frame[1] = BlePacketType.sosResolved.wireValue;
    frame[2] = packTtlHops(hopCount: hopCount, ttlRemaining: ttlRemaining);
    frame[3] = bodyByteLength;
    frame.setRange(4, 12, idBytes);
    frame[12] = status;

    final bd = ByteData.sublistView(frame);
    bd.setUint32(13, resolvedEpochSec.toUnsigned(32), Endian.big);
    frame.setRange(17, 33, _sosRevealToken);

    final tag4B = _computeIntegrity4B(
      domainAscii: 'trasee-ble-res-v1',
      pktType: BlePacketType.sosResolved.wireValue,
      bodyLen: bodyByteLength,
      payloadWithoutTag: Uint8List.sublistView(frame, 4, 33),
    );
    frame.setRange(33, 37, tag4B);
    return frame;
  }

  static BleSosResolvedPacket? decode(
    Uint8List raw, {
    int? rssi,
    String? peerId,
  }) {
    if (raw.length != wireByteLength) return null;
    if (raw[0] != kBleProtocolMagicVer ||
        raw[1] != BlePacketType.sosResolved.wireValue ||
        raw[3] != bodyByteLength) {
      return null;
    }
    final wireStatus = raw[12];
    if (wireStatus != statusResolved && wireStatus != statusCancelled) {
      return null;
    }

    final expectedTag = _computeIntegrity4B(
      domainAscii: 'trasee-ble-res-v1',
      pktType: BlePacketType.sosResolved.wireValue,
      bodyLen: bodyByteLength,
      payloadWithoutTag: Uint8List.sublistView(raw, 4, 33),
    );
    final actualTag = Uint8List.sublistView(raw, 33, 37);
    if (!constantTimeBytesEqual(actualTag, expectedTag)) {
      return null;
    }

    final bd = ByteData.sublistView(raw);
    final resolvedEpochSec = bd.getUint32(13, Endian.big);

    return BleSosResolvedPacket(
      clientSosId: bytesToHexLower(Uint8List.sublistView(raw, 4, 12)),
      status: wireStatus,
      resolvedEpochSec: resolvedEpochSec,
      sosRevealToken: Uint8List.sublistView(raw, 17, 33),
      hopCount: extractHopCount(raw[2]),
      ttlRemaining: extractTtlRemaining(raw[2]),
      rssi: rssi,
      peerId: peerId,
    );
  }
}

Uint8List _computeIntegrity4B({
  required String domainAscii,
  required int pktType,
  required int bodyLen,
  required Uint8List payloadWithoutTag,
}) {
  final domain = utf8.encode(domainAscii);
  final buf = Uint8List(domain.length + 3 + payloadWithoutTag.length);
  buf.setRange(0, domain.length, domain);
  buf[domain.length] = kBleProtocolMagicVer;
  buf[domain.length + 1] = pktType;
  buf[domain.length + 2] = bodyLen;
  buf.setRange(
    domain.length + 3,
    domain.length + 3 + payloadWithoutTag.length,
    payloadWithoutTag,
  );
  final digest = sha256.convert(buf);
  return Uint8List.fromList(digest.bytes.sublist(0, 4));
}

/// Outcome of evaluating an incoming BLE mesh packet through [BlePacketDeduplicator].
enum BleDedupStatus {
  acceptNew,
  superseded,
  duplicate,
  tombstoned,
  futureSkew,
  invalidAuth,
}

class BleDedupDecision {
  const BleDedupDecision({
    required this.status,
    required this.accepted,
    required this.shouldRelay,
  });

  final BleDedupStatus status;
  final bool accepted;
  final bool shouldRelay;

  static const BleDedupDecision duplicate = BleDedupDecision(
    status: BleDedupStatus.duplicate,
    accepted: false,
    shouldRelay: false,
  );

  static const BleDedupDecision tombstoned = BleDedupDecision(
    status: BleDedupStatus.tombstoned,
    accepted: false,
    shouldRelay: false,
  );

  static const BleDedupDecision futureSkew = BleDedupDecision(
    status: BleDedupStatus.futureSkew,
    accepted: false,
    shouldRelay: false,
  );

  static const BleDedupDecision invalidAuth = BleDedupDecision(
    status: BleDedupStatus.invalidAuth,
    accepted: false,
    shouldRelay: false,
  );
}

class _DedupSlot {
  const _DedupSlot({
    required this.originEpochSec,
    this.claimHashHex,
    this.ackFlags,
  });

  final int originEpochSec;
  final String? claimHashHex;
  final int? ackFlags;
}

/// 256-slot LRU ring buffer deduplicator with `+30s` superseding and 6-hour
/// preimage-verified tombstoning for `PKT_SOS_RESOLVED`.
class BlePacketDeduplicator {
  BlePacketDeduplicator({
    this.maxSlots = 256,
    int Function()? nowEpochSec,
  }) : assert(maxSlots > 0),
       _nowEpochSec = nowEpochSec ?? _defaultNowSec;

  final int maxSlots;
  final int Function() _nowEpochSec;

  final LinkedHashMap<String, _DedupSlot> _lru =
      LinkedHashMap<String, _DedupSlot>();
  final LinkedHashMap<String, int> _tombstoneExpiryByKey =
      LinkedHashMap<String, int>();

  static int _defaultNowSec() =>
      DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;

  int get length => _lru.length;

  void _putLru(String key, _DedupSlot slot) {
    _lru.remove(key);
    _lru[key] = slot;
    while (_lru.length > maxSlots) {
      _lru.remove(_lru.keys.first);
    }
  }

  _DedupSlot? _touchLru(String key) {
    final existing = _lru.remove(key);
    if (existing != null) {
      _lru[key] = existing;
    }
    return existing;
  }

  void _pruneTombstones(int nowSec) {
    _tombstoneExpiryByKey.removeWhere((_, expiresAt) => nowSec >= expiresAt);
  }

  /// Registers a locally originated SOS commitment so echoes are suppressed and
  /// resolutions can be verified.
  void registerKnownSosCommitment({
    required String clientSosId,
    required String sosClaimHash,
    int? createdEpochSec,
  }) {
    final id = clientSosId.trim().toLowerCase();
    final hash = sosClaimHash.trim().toLowerCase();
    _putLru(
      '0x02:$id',
      _DedupSlot(
        originEpochSec: createdEpochSec ?? _nowEpochSec(),
        claimHashHex: hash,
      ),
    );
  }

  /// Marks `(clientSosId, sosClaimHash)` as tombstoned for 6 hours.
  void markSosTombstoned({
    required String clientSosId,
    required String sosClaimHash,
    int? nowEpochSec,
  }) {
    final nowSec = nowEpochSec ?? _nowEpochSec();
    _pruneTombstones(nowSec);
    final id = clientSosId.trim().toLowerCase();
    final hash = sosClaimHash.trim().toLowerCase();
    _tombstoneExpiryByKey.remove('$id:$hash');
    _tombstoneExpiryByKey['$id:$hash'] = nowSec + kBleTombstoneWindowSec;
    while (_tombstoneExpiryByKey.length > maxSlots) {
      _tombstoneExpiryByKey.remove(_tombstoneExpiryByKey.keys.first);
    }
  }

  /// Returns `true` if [clientSosId] has an active 6-hour tombstone (matching
  /// [sosClaimHash] when provided).
  bool isSosTombstoned(
    String clientSosId, {
    String? sosClaimHash,
    int? nowEpochSec,
  }) {
    final nowSec = nowEpochSec ?? _nowEpochSec();
    _pruneTombstones(nowSec);
    final id = clientSosId.trim().toLowerCase();
    if (sosClaimHash != null) {
      final hash = sosClaimHash.trim().toLowerCase();
      return _tombstoneExpiryByKey.containsKey('$id:$hash');
    }
    final prefix = '$id:';
    for (final k in _tombstoneExpiryByKey.keys) {
      if (k.startsWith(prefix)) return true;
    }
    return false;
  }

  /// Fast-drop check on `(0x01, nonce8B || mac4B)` for encrypted group packets
  /// relayed by non-group nodes.
  bool shouldAcceptRawGroupFrame(Uint8List raw, {int? nowEpochSec}) {
    if (raw.length != BleGroupPosPacket.wireByteLength ||
        raw[0] != kBleProtocolMagicVer ||
        raw[1] != BlePacketType.groupPos.wireValue) {
      return false;
    }
    final nonceHex = bytesToHexLower(Uint8List.sublistView(raw, 4, 12));
    final macHex = bytesToHexLower(Uint8List.sublistView(raw, 44, 48));
    final key = '0x01:raw:$nonceHex:$macHex';
    if (_touchLru(key) != null) {
      return false;
    }
    _putLru(
      key,
      _DedupSlot(originEpochSec: nowEpochSec ?? _nowEpochSec()),
    );
    return true;
  }

  /// Deduplicates a decrypted `PKT_GROUP_POS` by `memberIdHex`, requiring strictly
  /// newer `timestampSec` and rejecting timestamps `> now + 120s`.
  BleDedupDecision evaluateGroupPos(
    BleGroupPosPacket pkt, {
    int? nowEpochSec,
  }) {
    final nowSec = nowEpochSec ?? _nowEpochSec();
    if (pkt.timestampSec > nowSec + kBleMaxFutureSkewSec) {
      return BleDedupDecision.futureSkew;
    }
    final key = '0x01:mem:${pkt.memberIdHex}';
    final prev = _touchLru(key);
    if (prev != null && pkt.timestampSec <= prev.originEpochSec) {
      return BleDedupDecision.duplicate;
    }
    _putLru(key, _DedupSlot(originEpochSec: pkt.timestampSec));
    return BleDedupDecision(
      status: prev == null ? BleDedupStatus.acceptNew : BleDedupStatus.superseded,
      accepted: true,
      shouldRelay: pkt.ttlRemaining > 0,
    );
  }

  /// Evaluates `PKT_SOS_ALERT` (`0x02`): rejects 6h tombstones and mismatched
  /// `sosClaimHash`, drops duplicates within `< +30s`, and supersedes at `>= +30s`.
  BleDedupDecision evaluateSosAlert(
    BleSosAlertPacket pkt, {
    int? nowEpochSec,
  }) {
    final nowSec = nowEpochSec ?? _nowEpochSec();
    final id = pkt.clientSosId.trim().toLowerCase();
    final hash = pkt.sosClaimHash.trim().toLowerCase();

    if (isSosTombstoned(id, sosClaimHash: hash, nowEpochSec: nowSec)) {
      return BleDedupDecision.tombstoned;
    }

    final key = '0x02:$id';
    final prev = _touchLru(key);
    if (prev != null) {
      if (prev.claimHashHex != null && prev.claimHashHex != hash) {
        return BleDedupDecision.invalidAuth;
      }
      if (pkt.createdEpochSec < prev.originEpochSec + kBleSupersedeWindowSec) {
        return BleDedupDecision.duplicate;
      }
      _putLru(
        key,
        _DedupSlot(originEpochSec: pkt.createdEpochSec, claimHashHex: hash),
      );
      return BleDedupDecision(
        status: BleDedupStatus.superseded,
        accepted: true,
        shouldRelay: pkt.ttlRemaining > 0,
      );
    }

    _putLru(
      key,
      _DedupSlot(originEpochSec: pkt.createdEpochSec, claimHashHex: hash),
    );
    return BleDedupDecision(
      status: BleDedupStatus.acceptNew,
      accepted: true,
      shouldRelay: pkt.ttlRemaining > 0,
    );
  }

  /// Evaluates `PKT_SOS_ACK` (`0x03`): deduplicates per `(clientSosId, responderIdHex)`,
  /// superseding at `>= +30s` or when `ackFlags` transitions (e.g. `uploadedToServer`).
  BleDedupDecision evaluateSosAck(
    BleSosAckPacket pkt, {
    int? nowEpochSec,
  }) {
    final nowSec = nowEpochSec ?? _nowEpochSec();
    final id = pkt.clientSosId.trim().toLowerCase();
    if (isSosTombstoned(id, nowEpochSec: nowSec)) {
      return BleDedupDecision.tombstoned;
    }

    final key = '0x03:$id:${pkt.responderIdHex.trim().toLowerCase()}';
    final prev = _touchLru(key);
    if (prev != null) {
      final flagsChanged =
          prev.ackFlags != null &&
          prev.ackFlags != pkt.ackFlags &&
          pkt.ackEpochSec >= prev.originEpochSec;
      if (!flagsChanged &&
          pkt.ackEpochSec < prev.originEpochSec + kBleSupersedeWindowSec) {
        return BleDedupDecision.duplicate;
      }
      _putLru(
        key,
        _DedupSlot(originEpochSec: pkt.ackEpochSec, ackFlags: pkt.ackFlags),
      );
      return BleDedupDecision(
        status: BleDedupStatus.superseded,
        accepted: true,
        shouldRelay: pkt.ttlRemaining > 0,
      );
    }

    _putLru(
      key,
      _DedupSlot(originEpochSec: pkt.ackEpochSec, ackFlags: pkt.ackFlags),
    );
    return BleDedupDecision(
      status: BleDedupStatus.acceptNew,
      accepted: true,
      shouldRelay: pkt.ttlRemaining > 0,
    );
  }

  /// Evaluates `PKT_SOS_RESOLVED` (`0x04`): verifies the Lamport preimage
  /// `sosRevealToken` in constant time against the known `sosClaimHash` (from
  /// `0x02` or [expectedClaimHashHex]) and tombstones the SOS for 6 hours.
  BleDedupDecision evaluateSosResolved(
    BleSosResolvedPacket pkt, {
    String? expectedClaimHashHex,
    int? nowEpochSec,
  }) {
    final nowSec = nowEpochSec ?? _nowEpochSec();
    final id = pkt.clientSosId.trim().toLowerCase();
    final revealBytes = pkt.sosRevealToken;
    if (revealBytes.length != 16) {
      return BleDedupDecision.invalidAuth;
    }

    final cachedSos = _touchLru('0x02:$id');
    final targetHashHex =
        expectedClaimHashHex?.trim().toLowerCase() ?? cachedSos?.claimHashHex;

    if (targetHashHex != null) {
      final targetHashBytes = tryHexToBytes(
        targetHashHex,
        expectedByteLength: 8,
      );
      if (targetHashBytes == null ||
          !verifyPreimageBytes(revealBytes, targetHashBytes)) {
        return BleDedupDecision.invalidAuth;
      }
    }

    final derivedHashHex = bytesToHexLower(
      computeSosClaimHashBytes(revealBytes),
    );
    final resKey = '0x04:$id:$derivedHashHex';
    if (_touchLru(resKey) != null) {
      return BleDedupDecision.duplicate;
    }

    _putLru(
      resKey,
      _DedupSlot(
        originEpochSec: pkt.resolvedEpochSec,
        claimHashHex: derivedHashHex,
      ),
    );
    markSosTombstoned(
      clientSosId: id,
      sosClaimHash: derivedHashHex,
      nowEpochSec: nowSec,
    );
    return BleDedupDecision(
      status: BleDedupStatus.acceptNew,
      accepted: true,
      shouldRelay: pkt.ttlRemaining > 0,
    );
  }
}
