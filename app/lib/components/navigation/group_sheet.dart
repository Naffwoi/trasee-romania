import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maplibre/maplibre.dart' as ml;
import 'package:share_plus/share_plus.dart';
import 'package:wanderer/models/live/trail_live_models.dart';
import 'package:wanderer/services/ble/sos_crypto_and_outbox.dart'
    show generateOfflineGroupCode;
import 'package:wanderer/theme/colors.dart';

Color parseGroupHexColor(String? rawHex) {
  if (rawHex == null) return AppColors.primaryLight;
  final cleaned = rawHex.trim().replaceFirst('#', '');
  if (cleaned.length == 6) {
    final parsed = int.tryParse('FF$cleaned', radix: 16);
    if (parsed != null) return Color(parsed);
  } else if (cleaned.length == 8) {
    final parsed = int.tryParse(cleaned, radix: 16);
    if (parsed != null) return Color(parsed);
  }
  return AppColors.primaryLight;
}

String _fmtMeters(double meters) {
  if (!meters.isFinite || meters <= 0.0) return '0 m';
  if (meters >= 1000.0) {
    return '${(meters / 1000.0).toStringAsFixed(1)} km';
  }
  return '${meters.round()} m';
}

String formatRelativeGroupDistance({
  required GroupMemberModel member,
  double? userAlongTrackM,
  ml.Geographic? userPos,
  bool isRo = true,
}) {
  if (member.isSelf) {
    return isRo ? 'Tu' : 'You';
  }
  final memberAlong = member.alongTrackM;
  if (userAlongTrackM != null &&
      userAlongTrackM.isFinite &&
      memberAlong != null &&
      memberAlong.isFinite) {
    final delta = memberAlong - userAlongTrackM;
    if (delta.abs() < 15.0) {
      return isRo ? 'Lângă tine' : 'Next to you';
    }
    if (delta > 0.0) {
      return isRo
          ? '+${_fmtMeters(delta)} în față'
          : '+${_fmtMeters(delta)} ahead';
    }
    return isRo
        ? '-${_fmtMeters(delta.abs())} în urmă'
        : '-${_fmtMeters(delta.abs())} behind';
  }
  if (userPos != null && member.lat.isFinite && member.lon.isFinite) {
    final d = ml.SphericalGreatCircle(
      userPos,
    ).distanceTo(ml.Geographic(lat: member.lat, lon: member.lon));
    if (d.isFinite) {
      return isRo ? 'la ${_fmtMeters(d)}' : '${_fmtMeters(d)} away';
    }
  }
  return '';
}

Future<void> showLiveGroupSheet(
  BuildContext context, {
  required ValueListenable<GroupSessionModel?> sessionListenable,
  ValueListenable<bool>? busyListenable,
  ValueListenable<bool>? bleAdapterOnListenable,
  bool isOnline = true,
  bool isBleAdapterOn = true,
  String initialDisplayName = '',
  double? userAlongTrackM,
  ml.Geographic? userPosition,
  String? shareUrlBase,
  required Future<GroupSessionModel?> Function(String displayName)
  onCreateGroup,
  required Future<GroupSessionModel?> Function(String code, String displayName)
  onJoinGroup,
  required Future<void> Function() onLeaveGroup,
  ValueChanged<GroupMemberModel>? onFocusMember,
  bool isRo = true,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => LiveGroupSheet(
      sessionListenable: sessionListenable,
      busyListenable: busyListenable,
      bleAdapterOnListenable: bleAdapterOnListenable,
      isOnline: isOnline,
      isBleAdapterOn: isBleAdapterOn,
      initialDisplayName: initialDisplayName,
      userAlongTrackM: userAlongTrackM,
      userPosition: userPosition,
      shareUrlBase: shareUrlBase,
      onCreateGroup: onCreateGroup,
      onJoinGroup: onJoinGroup,
      onLeaveGroup: onLeaveGroup,
      onFocusMember: onFocusMember,
      isRo: isRo,
    ),
  );
}

class LiveGroupSheet extends StatefulWidget {
  const LiveGroupSheet({
    super.key,
    required this.sessionListenable,
    this.busyListenable,
    this.bleAdapterOnListenable,
    this.isOnline = true,
    this.isBleAdapterOn = true,
    this.initialDisplayName = '',
    this.userAlongTrackM,
    this.userPosition,
    this.shareUrlBase,
    required this.onCreateGroup,
    required this.onJoinGroup,
    required this.onLeaveGroup,
    this.onFocusMember,
    this.isRo = true,
  });

  final ValueListenable<GroupSessionModel?> sessionListenable;
  final ValueListenable<bool>? busyListenable;
  final ValueListenable<bool>? bleAdapterOnListenable;
  final bool isOnline;
  final bool isBleAdapterOn;
  final String initialDisplayName;
  final double? userAlongTrackM;
  final ml.Geographic? userPosition;
  final String? shareUrlBase;
  final Future<GroupSessionModel?> Function(String displayName) onCreateGroup;
  final Future<GroupSessionModel?> Function(String code, String displayName)
  onJoinGroup;
  final Future<void> Function() onLeaveGroup;
  final ValueChanged<GroupMemberModel>? onFocusMember;
  final bool isRo;

  @override
  State<LiveGroupSheet> createState() => _LiveGroupSheetState();
}

class _LiveGroupSheetState extends State<LiveGroupSheet> {
  late final TextEditingController _nameController;
  final TextEditingController _codeController = TextEditingController();
  bool _localBusy = false;
  bool _copiedFeedback = false;
  String? _errorText;
  GroupSessionModel? _localOfflineFallbackSession;

  static final RegExp _validGroupCode = RegExp(r'^[A-HJ-NP-Z2-9]{6}$');

  @override
  void initState() {
    super.initState();
    final seedName = widget.initialDisplayName.trim();
    _nameController = TextEditingController(
      text: seedName.isNotEmpty ? seedName : (widget.isRo ? 'Drumeț' : 'Hiker'),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  String _effectiveName() {
    final trimmed = _nameController.text.trim();
    if (trimmed.isNotEmpty) return trimmed;
    return widget.isRo ? 'Drumeț' : 'Hiker';
  }

  GroupSessionModel _buildOfflineFallbackSession(String code, String name) {
    final pos = widget.userPosition;
    return GroupSessionModel(
      code: code,
      selfMemberId: 'ble-self',
      isOfflineBleGroup: true,
      members: <GroupMemberModel>[
        GroupMemberModel(
          memberId: 'ble-self',
          displayName: name,
          colorHex: '#242734',
          lat: pos?.lat ?? 0.0,
          lon: pos?.lon ?? 0.0,
          alongTrackM: widget.userAlongTrackM,
          inNavigation: true,
          isSelf: true,
          viaBluetooth: true,
          updatedAt: DateTime.now().toUtc(),
        ),
      ],
    );
  }

  void _assignFallbackSession(GroupSessionModel fallback) {
    final listenable = widget.sessionListenable;
    if (listenable is ValueNotifier<GroupSessionModel?>) {
      listenable.value = fallback;
    } else {
      setState(() {
        _localOfflineFallbackSession = fallback;
      });
    }
  }

  Future<void> _handleCreate() async {
    if (_localBusy) return;
    final name = _effectiveName();
    setState(() {
      _localBusy = true;
      _errorText = null;
    });
    try {
      final created = await widget.onCreateGroup(name);
      if (!mounted) return;
      if (created == null) {
        final fallback = _buildOfflineFallbackSession(
          generateOfflineGroupCode(),
          name,
        );
        _assignFallbackSession(fallback);
      }
    } catch (_) {
      if (!mounted) return;
      final fallback = _buildOfflineFallbackSession(
        generateOfflineGroupCode(),
        name,
      );
      _assignFallbackSession(fallback);
    } finally {
      if (mounted) setState(() => _localBusy = false);
    }
  }

  Future<void> _handleJoin() async {
    if (_localBusy) return;
    final code = _codeController.text.trim().toUpperCase();
    if (!_validGroupCode.hasMatch(code)) {
      setState(() {
        _errorText = widget.isRo
            ? 'Introdu un cod valid de 6 caractere.'
            : 'Enter a valid 6-character code.';
      });
      return;
    }
    final name = _effectiveName();
    setState(() {
      _localBusy = true;
      _errorText = null;
    });
    try {
      final joined = await widget.onJoinGroup(code, name);
      if (!mounted) return;
      if (joined == null) {
        final fallback = _buildOfflineFallbackSession(code, name);
        _assignFallbackSession(fallback);
      }
    } catch (_) {
      if (!mounted) return;
      final fallback = _buildOfflineFallbackSession(code, name);
      _assignFallbackSession(fallback);
    } finally {
      if (mounted) setState(() => _localBusy = false);
    }
  }

  Future<void> _handleLeave() async {
    if (_localBusy) return;
    setState(() {
      _localBusy = true;
      _errorText = null;
      _localOfflineFallbackSession = null;
    });
    try {
      await widget.onLeaveGroup();
    } finally {
      if (mounted) setState(() => _localBusy = false);
    }
  }

  String _sharePayload(String code) {
    final base = widget.shareUrlBase?.trim() ?? '';
    if (base.isNotEmpty) {
      final sep = base.contains('?') ? '&' : '?';
      return '$base${sep}group=$code';
    }
    return widget.isRo
        ? 'Intră în grupul meu live pe traseu — cod: $code'
        : 'Join my live hiking group — code: $code';
  }

  Future<void> _copyCode(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    setState(() => _copiedFeedback = true);
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copiedFeedback = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRo = widget.isRo;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final busySource =
        widget.busyListenable ?? const _ConstantBoolListenable(false);
    final bleAdapterSource =
        widget.bleAdapterOnListenable ??
        _ConstantBoolListenable(widget.isBleAdapterOn);

    return ValueListenableBuilder<GroupSessionModel?>(
      valueListenable: widget.sessionListenable,
      builder: (context, externalSession, _) {
        final session = externalSession ?? _localOfflineFallbackSession;
        return ValueListenableBuilder<bool>(
          valueListenable: busySource,
          builder: (context, externalBusy, _) {
            return ValueListenableBuilder<bool>(
              valueListenable: bleAdapterSource,
              builder: (context, adapterOn, _) {
                final isBusy = _localBusy || externalBusy;
                final isOfflineBleOnly =
                    session != null &&
                    (session.isOfflineBleGroup || !widget.isOnline);
                return Padding(
                  padding: EdgeInsets.only(
                    left: 16,
                    right: 16,
                    top: 10,
                    bottom: 18 + bottomInset,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: Container(
                            width: 36,
                            height: 4,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.22,
                              ),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: AppColors.primaryLight,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(
                                Icons.group_outlined,
                                color: Colors.white,
                                size: 19,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    isRo
                                        ? 'Grup live pe traseu'
                                        : 'Live trail group',
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w800),
                                  ),
                                  Text(
                                    !widget.isOnline
                                        ? (isRo
                                              ? 'Grup prin Bluetooth · funcționează și fără semnal'
                                              : 'Bluetooth group · works offline too')
                                        : (isRo
                                              ? 'Prieteni pe hartă · GPS cooperativ în pădure'
                                              : 'Friends on map · Cooperative canopy GPS'),
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.65),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(Icons.close, size: 20),
                            ),
                          ],
                        ),
                        if (!adapterOn) ...[
                          const SizedBox(height: 10),
                          Container(
                            key: const ValueKey('group-ble-off-notice'),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 9,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.primaryLight.withValues(
                                alpha: theme.brightness == Brightness.dark
                                    ? 0.45
                                    : 0.08,
                              ),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: theme.colorScheme.outline.withValues(
                                  alpha: 0.55,
                                ),
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.bluetooth_disabled_rounded,
                                  size: 17,
                                  color: theme.colorScheme.onSurface.withValues(
                                    alpha: 0.85,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    isRo
                                        ? 'Pornește Bluetooth pentru conectare directă fără semnal'
                                        : 'Turn on Bluetooth for direct offline connection',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 14),
                        if (session == null)
                          _buildCreateOrJoinBody(context, isBusy: isBusy)
                        else
                          _buildActiveSessionBody(
                            context,
                            session,
                            isBusy: isBusy,
                            isOfflineBleOnly: isOfflineBleOnly,
                          ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildCreateOrJoinBody(BuildContext context, {required bool isBusy}) {
    final theme = Theme.of(context);
    final isRo = widget.isRo;
    final err = _errorText;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('group-name-input'),
          controller: _nameController,
          maxLength: 24,
          textInputAction: TextInputAction.next,
          style: theme.textTheme.bodyMedium,
          decoration: InputDecoration(
            isDense: true,
            counterText: '',
            labelText: isRo ? 'Numele tău în grup' : 'Your display name',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const ValueKey('group-create-btn'),
          style: FilledButton.styleFrom(
            backgroundColor: theme.brightness == Brightness.dark
                ? theme.colorScheme.primary
                : AppColors.primaryLight,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 13),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          onPressed: isBusy ? null : _handleCreate,
          icon: const Icon(Icons.add_circle_outline, size: 18),
          label: Text(
            isRo ? 'Creează grup nou' : 'Create new group',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            const Expanded(child: Divider()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                isRo ? 'sau intră cu cod' : 'or join with code',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
            const Expanded(child: Divider()),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('group-code-input'),
                controller: _codeController,
                maxLength: 6,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9]')),
                ],
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 3.0,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  counterText: '',
                  hintText: 'K7M4P9',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onSubmitted: (_) => _handleJoin(),
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton(
              key: const ValueKey('group-join-btn'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 14,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: isBusy ? null : _handleJoin,
              child: Text(
                isRo ? 'Intră' : 'Join',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        if (err != null) ...[
          const SizedBox(height: 10),
          Text(
            err,
            style: theme.textTheme.bodySmall?.copyWith(
              color: const Color(0xFFDC2626),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildActiveSessionBody(
    BuildContext context,
    GroupSessionModel session, {
    required bool isBusy,
    required bool isOfflineBleOnly,
  }) {
    final theme = Theme.of(context);
    final isRo = widget.isRo;
    final modeBadgeText = isOfflineBleOnly
        ? (isRo
              ? 'Grup prin Bluetooth · fără semnal'
              : 'Bluetooth Group · offline')
        : (isRo
              ? 'Grup activ · Server + Bluetooth'
              : 'Active Group · Server + Bluetooth');

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            key: const ValueKey('group-mode-badge'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.primaryLight,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isOfflineBleOnly
                      ? Icons.bluetooth_connected_rounded
                      : Icons.bluetooth_rounded,
                  size: 13,
                  color: Colors.white,
                ),
                const SizedBox(width: 6),
                Text(
                  modeBadgeText,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: theme.colorScheme.outline.withValues(alpha: 0.55),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isRo ? 'COD GRUP ACTIV' : 'ACTIVE GROUP CODE',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.6,
                        ),
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      session.code,
                      key: const ValueKey('group-active-code'),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: 4.0,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: const ValueKey('group-copy-code-btn'),
                tooltip: isRo ? 'Copiază codul' : 'Copy code',
                onPressed: () => _copyCode(session.code),
                icon: Icon(
                  _copiedFeedback ? Icons.check_rounded : Icons.copy_rounded,
                  size: 20,
                ),
              ),
              IconButton(
                key: const ValueKey('group-share-code-btn'),
                tooltip: isRo ? 'Trimite colegilor' : 'Share with friends',
                onPressed: () {
                  SharePlus.instance.share(
                    ShareParams(text: _sharePayload(session.code)),
                  );
                },
                icon: const Icon(Icons.ios_share_rounded, size: 20),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Text(
          isRo
              ? 'Membri activi (${session.members.length})'
              : 'Active members (${session.members.length})',
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        for (final member in session.members)
          _buildMemberRow(context, member),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const ValueKey('group-leave-btn'),
          style: OutlinedButton.styleFrom(
            foregroundColor: theme.colorScheme.onSurface.withValues(
              alpha: 0.82,
            ),
            side: BorderSide(
              color: theme.colorScheme.outline.withValues(alpha: 0.7),
            ),
            padding: const EdgeInsets.symmetric(vertical: 11),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          onPressed: isBusy ? null : _handleLeave,
          icon: const Icon(Icons.logout_rounded, size: 18),
          label: Text(
            isRo ? 'Părăsește grupul' : 'Leave group',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }

  Widget _buildMemberRow(BuildContext context, GroupMemberModel member) {
    final theme = Theme.of(context);
    final isRo = widget.isRo;
    final badgeColor = parseGroupHexColor(member.colorHex);
    final focusCallback = widget.onFocusMember;
    final relText = formatRelativeGroupDistance(
      member: member,
      userAlongTrackM: widget.userAlongTrackM,
      userPos: widget.userPosition,
      isRo: isRo,
    );
    final accText = '±${member.accuracy.round()} m';
    final subtitleParts = <String>[
      if (relText.isNotEmpty) relText,
      accText,
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.035),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: (!member.isSelf && focusCallback != null)
              ? () {
                  focusCallback(member);
                  Navigator.of(context).pop();
                }
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: badgeColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    member.initials,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              member.isSelf
                                  ? '${member.displayName} (${isRo ? 'Tu' : 'You'})'
                                  : member.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (member.viaBluetooth && !member.isSelf) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.primaryLight,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.bluetooth_rounded,
                                    size: 11,
                                    color: Colors.white,
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    'Bluetooth',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                      Text(
                        subtitleParts.join(' · '),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.65,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (!member.isSelf && focusCallback != null)
                  Icon(
                    Icons.my_location_rounded,
                    size: 17,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ConstantBoolListenable extends ValueListenable<bool> {
  const _ConstantBoolListenable(this._value);

  final bool _value;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  bool get value => _value;
}
