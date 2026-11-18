import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wanderer/components/navigation/group_sheet.dart';
import 'package:wanderer/models/live/trail_live_models.dart';
import 'package:wanderer/provider/auth_provider.dart';
import 'package:wanderer/provider/local_settings_provider.dart';
import 'package:wanderer/provider/online_status_provider.dart';
import 'package:wanderer/services/ble/sos_crypto_and_outbox.dart'
    show
        deriveBleMemberColor,
        deriveOfflineGroupMemberId,
        generateOfflineGroupCode;
import 'package:wanderer/services/trail_live_service.dart';

class GlobalGroupSessionController extends Notifier<GroupSessionModel?> {
  final ValueNotifier<GroupSessionModel?> sessionNotifier =
      ValueNotifier<GroupSessionModel?>(null);
  final ValueNotifier<bool> busyNotifier = ValueNotifier<bool>(false);
  String _selfDisplayName = 'Drumeț';

  @override
  GroupSessionModel? build() {
    ref.onDispose(() {
      sessionNotifier.dispose();
      busyNotifier.dispose();
    });
    return null;
  }

  String get selfDisplayName => _selfDisplayName;

  void syncExternalSession(GroupSessionModel? session) {
    if (identical(state, session) || state == session) return;
    state = session;
    sessionNotifier.value = session;
  }

  Future<GroupSessionModel> _buildOfflineBleGroup({
    required String code,
    required String displayName,
    String? trailId,
  }) async {
    final token = await LiveDeviceTokenStore.getOrCreateToken();
    final normCode = code.trim().toUpperCase();
    final selfId = deriveOfflineGroupMemberId(
      groupCode: normCode,
      deviceToken: token,
    );
    final selfMember = GroupMemberModel(
      memberId: selfId,
      displayName: displayName,
      colorHex: deriveBleMemberColor(selfId),
      lat: 0.0,
      lon: 0.0,
      inNavigation: false,
      isSelf: true,
      viaBluetooth: true,
      updatedAt: DateTime.now().toUtc(),
    );
    return GroupSessionModel(
      code: normCode,
      trailId: trailId,
      selfMemberId: selfId,
      isOfflineBleGroup: true,
      members: <GroupMemberModel>[selfMember],
    );
  }

  Future<GroupSessionModel?> createGroup(
    String displayName, {
    String? trailId,
  }) async {
    final name = displayName.trim().isNotEmpty ? displayName.trim() : 'Drumeț';
    _selfDisplayName = name;
    busyNotifier.value = true;
    try {
      final service = ref.read(trailLiveServiceProvider);
      final isOnline = ref.read(onlineStatusProvider);
      GroupSessionModel session;
      if (service != null && service.isConfigured && isOnline) {
        try {
          session = await service.createGroup(
            trailId: (trailId != null && trailId.isNotEmpty) ? trailId : null,
            displayName: name,
          );
        } catch (_) {
          session = await _buildOfflineBleGroup(
            code: generateOfflineGroupCode(),
            displayName: name,
            trailId: trailId,
          );
        }
      } else {
        session = await _buildOfflineBleGroup(
          code: generateOfflineGroupCode(),
          displayName: name,
          trailId: trailId,
        );
      }
      state = session;
      sessionNotifier.value = session;
      return session;
    } finally {
      busyNotifier.value = false;
    }
  }

  Future<GroupSessionModel?> joinGroup(
    String code,
    String displayName,
  ) async {
    final name = displayName.trim().isNotEmpty ? displayName.trim() : 'Drumeț';
    _selfDisplayName = name;
    final normCode = code.trim().toUpperCase();
    busyNotifier.value = true;
    try {
      final service = ref.read(trailLiveServiceProvider);
      final isOnline = ref.read(onlineStatusProvider);
      GroupSessionModel session;
      if (service != null && service.isConfigured && isOnline) {
        try {
          session = await service.joinGroup(code: normCode, displayName: name);
        } catch (_) {
          session = await _buildOfflineBleGroup(
            code: normCode,
            displayName: name,
          );
        }
      } else {
        session = await _buildOfflineBleGroup(
          code: normCode,
          displayName: name,
        );
      }
      state = session;
      sessionNotifier.value = session;
      return session;
    } finally {
      busyNotifier.value = false;
    }
  }

  Future<void> leaveGroup() async {
    final prev = state;
    state = null;
    sessionNotifier.value = null;
    if (prev == null || prev.isOfflineBleGroup) return;
    final service = ref.read(trailLiveServiceProvider);
    if (service == null || !service.isConfigured) return;
    try {
      await service.leaveGroup(prev.code);
    } catch (_) {}
  }
}

final globalGroupSessionProvider =
    NotifierProvider<GlobalGroupSessionController, GroupSessionModel?>(
      GlobalGroupSessionController.new,
    );

class PendingGroupJoinCodeNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void setCode(String code) {
    final norm = code.trim().toUpperCase();
    if (RegExp(r'^[A-HJ-NP-Z2-9]{6}$').hasMatch(norm)) {
      state = norm;
    }
  }

  String? take() {
    final val = state;
    state = null;
    return val;
  }
}

final pendingGroupJoinCodeProvider =
    NotifierProvider<PendingGroupJoinCodeNotifier, String?>(
      PendingGroupJoinCodeNotifier.new,
    );

Future<void> openGlobalGroupSheet(
  BuildContext context,
  WidgetRef ref, {
  String? trailId,
  String? trailName,
  String? initialJoinCode,
  int initialTab = 0,
}) async {
  final controller = ref.read(globalGroupSessionProvider.notifier);
  controller.sessionNotifier.value = ref.read(globalGroupSessionProvider);

  final currentUser = ref.read(authProvider).value;
  final prefName = currentUser?.preferredUsername.trim() ?? '';
  final initialName = prefName.isNotEmpty
      ? prefName
      : (currentUser?.username.trim() ?? '');
  final rawServer = currentUser?.serverUrl.trim() ?? '';
  final cleanServer = rawServer.endsWith('/')
      ? rawServer.substring(0, rawServer.length - 1)
      : rawServer;
  final shareUrlBase = (cleanServer.isNotEmpty && trailId != null && trailId.isNotEmpty)
      ? '$cleanServer/map/trail/$trailId'
      : (cleanServer.isNotEmpty ? '$cleanServer/map' : null);

  final langCode = ref.read(localeProvider)?.languageCode ?? 'ro';
  final isRo = !langCode.toLowerCase().startsWith('en');

  if (!context.mounted) return;
  await showLiveGroupSheet(
    context,
    sessionListenable: controller.sessionNotifier,
    busyListenable: controller.busyNotifier,
    isOnline: ref.read(onlineStatusProvider),
    initialDisplayName: initialName,
    shareUrlBase: shareUrlBase,
    initialTrailName: trailName,
    initialJoinCode: initialJoinCode,
    initialTab: initialTab,
    onCreateGroup: (name) => controller.createGroup(name, trailId: trailId),
    onJoinGroup: controller.joinGroup,
    onLeaveGroup: controller.leaveGroup,
    isRo: isRo,
  );
}
