import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import '../services/device_sync_service.dart';
import '../main.dart' show globalDeviceSyncService;

class DevicesSheet extends StatefulWidget {
  final AudioPlayerService audioPlayerService;

  const DevicesSheet({super.key, required this.audioPlayerService});

  @override
  State<DevicesSheet> createState() => _DevicesSheetState();
}

class _DevicesSheetState extends State<DevicesSheet> {
  final ApiService _apiService = ApiService();
  List<Map<String, dynamic>> _devices = [];
  bool _isLoading = true;
  bool _isResuming = false;
  io.Socket? _socket;

  DeviceSyncService get _syncService => globalDeviceSyncService;

  @override
  void initState() {
    super.initState();
    _loadDevices();
    _connectSocket();
    _syncService.addListener(_onSyncChanged);
  }

  @override
  void dispose() {
    _syncService.removeListener(_onSyncChanged);
    _socket?.disconnect();
    _socket?.dispose();
    super.dispose();
  }

  void _onSyncChanged() {
    if (!mounted) return;
    // Surface remote-control errors (previously swallowed with a print) so a
    // failed Control isn't silent.
    final err = _syncService.lastError;
    if (err != null) {
      _syncService.clearError();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(err),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    setState(() {});
  }

  void _connectSocket() {
    _socket = io.io(
      ApiService.baseHost,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .enableForceNew()
          .build(),
    );

    _socket!.on('playback_state_changed', (data) {
      if (!mounted) return;
      if (data['device_id'] != widget.audioPlayerService.deviceId) {
        _loadDevices();
      }
    });

    _socket!.connect();
  }

  Future<void> _loadDevices() async {
    try {
      final devices = await _apiService.getDevices();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  Future<void> _resumeFromDevice(String deviceId, String deviceName) async {
    setState(() => _isResuming = true);

    try {
      await widget.audioPlayerService.resumeFromDevice(deviceId);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Resumed from $deviceName'),
          backgroundColor: const Color(0xFF00d4ff),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isResuming = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to resume — device may have no active session'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _startRemoteControl(String deviceId) {
    _syncService.startRemoteControl(deviceId);
  }

  void _stopRemoteControl() {
    _syncService.stopRemoteControl();
  }

  Future<void> _createSyncGroup() async {
    final nameController = TextEditingController();
    final groupName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: const Text(
          'Create Sync Group',
          style: TextStyle(color: Colors.white),
        ),
        content: TextField(
          controller: nameController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'e.g. "Shop Music" or "House Party"',
            hintStyle: const TextStyle(color: Colors.white30),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(
                color: const Color(0xFF00d4ff).withValues(alpha: 0.3),
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            focusedBorder: OutlineInputBorder(
              borderSide: const BorderSide(color: Color(0xFF00d4ff)),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) Navigator.of(ctx).pop(value.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              final name = nameController.text.trim();
              if (name.isNotEmpty) Navigator.of(ctx).pop(name);
            },
            child: const Text('Create', style: TextStyle(color: Color(0xFF00d4ff))),
          ),
        ],
      ),
    );

    if (groupName == null || groupName.isEmpty) return;
    _syncService.createGroup(groupName);
  }

  Future<void> _deleteDevice(String deviceId, String deviceName) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: const Text('Remove Device', style: TextStyle(color: Colors.white)),
        content: Text(
          'Remove "$deviceName" from the device list?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await _apiService.deleteDevice(deviceId);
        _loadDevices();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to remove device: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  String _formatDuration(dynamic seconds) {
    if (seconds == null) return '--:--';
    final dur = Duration(seconds: seconds is int ? seconds : 0);
    final h = dur.inHours;
    final m = dur.inMinutes % 60;
    final s = dur.inSeconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  String _formatPosition(dynamic ms) {
    if (ms == null) return '--:--';
    final dur = Duration(milliseconds: ms is int ? ms : 0);
    final m = dur.inMinutes;
    final s = dur.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  String _timeAgo(String? updatedAt) {
    if (updatedAt == null) return '';
    try {
      final dt = DateTime.parse(updatedAt);
      final diff = DateTime.now().difference(dt);
      if (diff.inMinutes < 1) return 'just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24) return '${diff.inHours}h ago';
      return '${diff.inDays}d ago';
    } catch (_) {
      return '';
    }
  }

  Future<void> _renameDevice(String deviceId, String currentName, {bool isThisDevice = false}) async {
    final controller = TextEditingController(text: currentName);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: const Text('Rename Device', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Device name',
            hintStyle: const TextStyle(color: Colors.white30),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: const Color(0xFF00d4ff).withValues(alpha: 0.3)),
              borderRadius: BorderRadius.circular(8),
            ),
            focusedBorder: OutlineInputBorder(
              borderSide: const BorderSide(color: Color(0xFF00d4ff)),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) Navigator.of(ctx).pop(value.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) Navigator.of(ctx).pop(name);
            },
            child: const Text('Save', style: TextStyle(color: Color(0xFF00d4ff))),
          ),
        ],
      ),
    );

    if (newName == null || newName.isEmpty || newName == currentName) return;

    if (isThisDevice) {
      // Update local device name
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('device_name', newName);
      // Update in audio player service
      widget.audioPlayerService.updateDeviceName(newName);
      // Save state to update backend
      widget.audioPlayerService.savePlaybackState();
    }

    _loadDevices();
  }

  IconData _deviceIcon(String? name) {
    final n = (name ?? '').toLowerCase();
    if (n.contains('android') || n.contains('phone')) return Icons.phone_android;
    if (n.contains('iphone') || n.contains('ios')) return Icons.phone_iphone;
    if (n.contains('mac')) return Icons.laptop_mac;
    if (n.contains('linux')) return Icons.computer;
    return Icons.desktop_windows;
  }

  @override
  Widget build(BuildContext context) {
    final myDeviceId = widget.audioPlayerService.deviceId;
    final otherDevices = _devices.where((d) => d['device_id'] != myDeviceId).toList();
    final myDevice = _devices.where((d) => d['device_id'] == myDeviceId).toList();

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF1a2332),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(
              children: [
                const Icon(Icons.devices, color: Color(0xFF00d4ff), size: 22),
                const SizedBox(width: 10),
                const Text(
                  'Devices',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const Spacer(),
                if (_isLoading)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF00d4ff),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(color: Colors.white12, height: 1),

          // Remote control banner
          if (_syncService.isController) _buildRemoteControlBanner(),

          // Being controlled banner
          if (_syncService.isBeingControlled) _buildBeingControlledBanner(),

          // Group session banner
          if (_syncService.isInGroup) _buildGroupBanner(),

          // Start sync group button (when not in a group or remote session)
          if (!_syncService.isInGroup && !_syncService.isController && !_syncService.isBeingControlled && !_isLoading)
            _buildStartSyncButton(),

          // Device list
          if (_isLoading && _devices.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: CircularProgressIndicator(color: Color(0xFF00d4ff)),
            )
          else if (otherDevices.isEmpty && myDevice.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'No devices found',
                style: TextStyle(color: Colors.white54),
              ),
            )
          else
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  // This device first
                  if (myDevice.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                      child: Row(
                        children: [
                          const Text(
                            'THIS DEVICE',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.white38,
                              letterSpacing: 1,
                            ),
                          ),
                          const Spacer(),
                          const Text(
                            'Tap to rename',
                            style: TextStyle(fontSize: 10, color: Colors.white24),
                          ),
                        ],
                      ),
                    ),
                    ...myDevice.map((d) => _buildDeviceTile(d, isOther: false)),
                  ],
                  // Other devices
                  if (otherDevices.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                      child: Row(
                        children: [
                          const Text(
                            'OTHER DEVICES',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.white38,
                              letterSpacing: 1,
                            ),
                          ),
                          const Spacer(),
                          const Text(
                            'Long press to remove',
                            style: TextStyle(fontSize: 10, color: Colors.white24),
                          ),
                        ],
                      ),
                    ),
                    ...otherDevices.map((d) => _buildDeviceTile(d, isOther: true)),
                  ],
                ],
              ),
            ),

          SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
        ],
      ),
    );
  }

  // ==================
  // Banners
  // ==================

  Widget _buildRemoteControlBanner() {
    // The device we're controlling (for the play/pause state on the buttons).
    final target = _devices.firstWhere(
      (d) => d['device_id'] == _syncService.targetDeviceId,
      orElse: () => <String, dynamic>{},
    );
    final targetPlaying = target['is_playing'] == 1 || target['is_playing'] == true;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF00d4ff).withValues(alpha: 0.15),
            const Color(0xFF00d4ff).withValues(alpha: 0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF00d4ff).withValues(alpha: 0.3)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.gamepad, color: Color(0xFF00d4ff), size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Controlling ${_syncService.targetDeviceName ?? "device"}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: _stopRemoteControl,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text(
                  'Stop',
                  style: TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          // Working transport — these send commands to the controlled device.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.skip_previous, color: Colors.white, size: 30),
                onPressed: () => _syncService.sendRemoteCommand('previous'),
              ),
              const SizedBox(width: 12),
              IconButton(
                icon: Icon(
                  targetPlaying ? Icons.pause_circle : Icons.play_circle,
                  color: const Color(0xFF00d4ff),
                  size: 44,
                ),
                onPressed: () => _syncService.sendRemoteCommand('toggle_play_pause'),
              ),
              const SizedBox(width: 12),
              IconButton(
                icon: const Icon(Icons.skip_next, color: Colors.white, size: 30),
                onPressed: () => _syncService.sendRemoteCommand('next'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBeingControlledBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.orange.withValues(alpha: 0.15),
            Colors.orange.withValues(alpha: 0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.lock, color: Colors.orange, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Controlled by ${_syncService.controllerDeviceName ?? "device"}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const Text(
                  'Another device is controlling playback',
                  style: TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupBanner() {
    final groupName = _syncService.groupName ?? 'Sync Group';
    final memberCount = _syncService.groupMembers.length;
    final isLeader = _syncService.isGroupLeader;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF7b2ff7).withValues(alpha: 0.15),
            const Color(0xFF7b2ff7).withValues(alpha: 0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF7b2ff7).withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(
            isLeader ? Icons.star : Icons.link,
            color: const Color(0xFF7b2ff7),
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  groupName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                Text(
                  '${isLeader ? "Leading" : "Following"} · $memberCount device${memberCount == 1 ? '' : 's'}',
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => _syncService.leaveGroup(),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text(
              'Leave',
              style: TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStartSyncButton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: _createSyncGroup,
          icon: const Icon(Icons.link, size: 18),
          label: const Text('Start Sync Group'),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF7b2ff7),
            side: BorderSide(color: const Color(0xFF7b2ff7).withValues(alpha: 0.4)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      ),
    );
  }

  // ==================
  // Device Tiles
  // ==================

  Widget _buildDeviceTile(Map<String, dynamic> device, {required bool isOther}) {
    final isPlaying = device['is_playing'] == 1 || device['is_playing'] == true;
    final songTitle = device['song_title'] as String?;
    final artistName = device['artist_name'] as String?;
    final albumId = device['album_id'];
    final positionMs = device['position_ms'];
    final songDuration = device['song_duration'];
    final deviceName = device['device_name'] ?? 'Unknown Device';
    final deviceId = device['device_id'] as String;
    final updatedAt = device['updated_at']?.toString();
    final hasSong = songTitle != null && songTitle.isNotEmpty;
    final groupRole = device['group_role'] as String? ?? 'independent';
    final groupId = device['group_id'] as String?;
    final connected = device['connected'] == true;

    // Calculate progress fraction
    double progress = 0;
    if (positionMs != null && songDuration != null && songDuration > 0) {
      progress = (positionMs / 1000) / songDuration;
      if (progress > 1) progress = 1;
      if (progress < 0) progress = 0;
    }

    // Determine if this device is the one we're controlling
    final isControlTarget = _syncService.isController && _syncService.targetDeviceId == deviceId;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: GestureDetector(
        onLongPress: isOther
            ? () => _deleteDevice(deviceId, deviceName)
            : () => _renameDevice(deviceId, deviceName, isThisDevice: true),
        onTap: !isOther ? () => _renameDevice(deviceId, deviceName, isThisDevice: true) : null,
        child: Material(
          color: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF0f1729),
              borderRadius: BorderRadius.circular(12),
              border: isControlTarget
                  ? Border.all(color: const Color(0xFF00d4ff).withValues(alpha: 0.5))
                  : isOther && hasSong
                      ? Border.all(color: const Color(0xFF00d4ff).withValues(alpha: 0.2))
                      : null,
            ),
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Album art or device icon
                if (hasSong && albumId != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.network(
                      '${ApiService.baseUrl}/artwork/$albumId',
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _deviceIconContainer(deviceName, isOther),
                    ),
                  )
                else
                  _deviceIconContainer(deviceName, isOther),

                const SizedBox(width: 12),

                // Device info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Device name + status badges
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              deviceName,
                              style: TextStyle(
                                color: isOther ? Colors.white : Colors.white54,
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (isPlaying)
                            _statusBadge('Playing', const Color(0xFF00d4ff))
                          else if (hasSong)
                            _statusBadge('Paused', Colors.white54, bgOpacity: 0.08),
                          if (groupRole == 'leader') ...[
                            const SizedBox(width: 4),
                            _statusBadge('Leader', const Color(0xFF7b2ff7)),
                          ],
                          if (groupRole == 'follower') ...[
                            const SizedBox(width: 4),
                            _statusBadge('Synced', const Color(0xFF7b2ff7), icon: Icons.link),
                          ],
                          if (isControlTarget) ...[
                            const SizedBox(width: 4),
                            _statusBadge('Controlling', const Color(0xFF00d4ff), icon: Icons.gamepad),
                          ],
                        ],
                      ),
                      if (hasSong) ...[
                        const SizedBox(height: 4),
                        Text(
                          '$songTitle — $artistName',
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Text(_formatPosition(positionMs),
                                style: const TextStyle(color: Colors.white38, fontSize: 10)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(
                                  value: progress,
                                  minHeight: 3,
                                  backgroundColor: Colors.white12,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    isPlaying ? const Color(0xFF00d4ff) : Colors.white30,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(_formatDuration(songDuration),
                                style: const TextStyle(color: Colors.white38, fontSize: 10)),
                          ],
                        ),
                      ] else ...[
                        const SizedBox(height: 4),
                        Text(
                          updatedAt != null ? 'Last active ${_timeAgo(updatedAt)}' : 'No recent activity',
                          style: const TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                ),

                // Action buttons (only for other devices)
                if (isOther) ...[
                  const SizedBox(width: 8),
                  _buildActionButtons(
                    deviceId: deviceId,
                    deviceName: deviceName,
                    hasSong: hasSong,
                    connected: connected,
                    groupId: groupId,
                    groupRole: groupRole,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _deviceIconContainer(String deviceName, bool isOther) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: const Color(0xFF1a2332),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(
        _deviceIcon(deviceName),
        color: isOther ? const Color(0xFF00d4ff) : Colors.white38,
        size: 24,
      ),
    );
  }

  Widget _statusBadge(String text, Color color, {IconData? icon, double bgOpacity = 0.15}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: bgOpacity),
        borderRadius: BorderRadius.circular(4),
      ),
      child: icon != null
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 10, color: color),
                const SizedBox(width: 3),
                Text(text, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
              ],
            )
          : Text(text, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
    );
  }

  Widget _buildActionButtons({
    required String deviceId,
    required String deviceName,
    required bool hasSong,
    required bool connected,
    required String? groupId,
    required String groupRole,
  }) {
    // If we're controlling this device, show stop button
    if (_syncService.isController && _syncService.targetDeviceId == deviceId) {
      return _actionButton('Stop', Colors.redAccent, () => _stopRemoteControl());
    }

    // If this device is in a sync group we can join
    if (!_syncService.isInGroup && groupId != null && groupRole == 'leader') {
      return _actionButton('Join', const Color(0xFF7b2ff7), () => _syncService.joinGroup(groupId));
    }

    // Build the available actions. Control needs a LIVE socket connection;
    // Resume just replays the device's last session here, so it works even
    // when the device is offline.
    final buttons = <Widget>[];
    if (hasSong && !_syncService.isController) {
      if (connected) {
        buttons.add(_actionButton('Control', const Color(0xFF00d4ff),
            () => _startRemoteControl(deviceId), compact: true));
      }
      buttons.add(_actionButton('Resume', Colors.white70,
          () => _resumeFromDevice(deviceId, deviceName), compact: true, outlined: true));
    }

    if (buttons.isEmpty) {
      // Nothing actionable. For an offline device say so rather than leaving a gap.
      return connected
          ? const SizedBox.shrink()
          : const Text('Offline',
              style: TextStyle(color: Colors.white24, fontSize: 11, fontWeight: FontWeight.w600));
    }

    // Stacked vertically so long device names get the horizontal room back.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < buttons.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          buttons[i],
        ],
      ],
    );
  }

  Widget _actionButton(String label, Color color, VoidCallback onPressed,
      {bool compact = false, bool outlined = false}) {
    if (outlined) {
      return SizedBox(
        height: 32,
        child: OutlinedButton(
          onPressed: _isResuming ? null : onPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: color,
            side: BorderSide(color: color.withValues(alpha: 0.4)),
            padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            minimumSize: Size.zero,
          ),
          child: Text(label, style: TextStyle(fontSize: compact ? 11 : 13, fontWeight: FontWeight.w600)),
        ),
      );
    }

    return SizedBox(
      height: 32,
      child: ElevatedButton(
        onPressed: _isResuming ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: color == Colors.white70 ? const Color(0xFF0a0e27) : Colors.white,
          padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          minimumSize: Size.zero,
        ),
        child: _isResuming && label == 'Resume'
            ? const SizedBox(
                width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0a0e27)))
            : Text(label, style: TextStyle(fontSize: compact ? 11 : 13, fontWeight: FontWeight.w700)),
      ),
    );
  }
}
