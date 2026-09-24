import 'package:flutter/material.dart';
import '../services/cast_service.dart';
import '../services/audio_player_service.dart';
import '../services/cast/cast_device.dart';
import '../models/saved_cast_device.dart';

/// Cast button that shows a Chromecast icon. Tapping opens a device picker.
/// Shows connected state with cyan color when casting.
class CastButton extends StatelessWidget {
  final CastService castService;
  final AudioPlayerService audioPlayerService;
  final double iconSize;

  const CastButton({
    super.key,
    required this.castService,
    required this.audioPlayerService,
    this.iconSize = 24,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: castService,
      builder: (context, _) {
        final isConnected = castService.isConnected;

        return IconButton(
          icon: Icon(
            isConnected ? Icons.cast_connected : Icons.cast,
            color: isConnected ? const Color(0xFF00d4ff) : Colors.white70,
            size: iconSize,
          ),
          tooltip: isConnected
              ? 'Casting to ${castService.deviceName}'
              : 'Cast to device',
          onPressed: () => _showDevicePicker(context),
        );
      },
    );
  }

  void _showDevicePicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1a2332),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _DevicePickerSheet(
        castService: castService,
        audioPlayerService: audioPlayerService,
      ),
    );
  }
}

class _DevicePickerSheet extends StatefulWidget {
  final CastService castService;
  final AudioPlayerService audioPlayerService;

  const _DevicePickerSheet({
    required this.castService,
    required this.audioPlayerService,
  });

  @override
  State<_DevicePickerSheet> createState() => _DevicePickerSheetState();
}

class _DevicePickerSheetState extends State<_DevicePickerSheet> {
  bool _isSearching = false;
  bool _isConnecting = false;
  String? _connectingDeviceName;

  @override
  void initState() {
    super.initState();
    // Rebuild whenever the cast service pushes a new device in
    // while discovery is still running — the list updates live.
    widget.castService.addListener(_onCastServiceChanged);
    // Load persisted "Recent" devices so they render above the scan
    // list even before any mDNS responses come back.
    widget.castService.loadSavedDevices();
    if (!widget.castService.isConnected) {
      _startDiscovery();
    }
  }

  @override
  void dispose() {
    widget.castService.removeListener(_onCastServiceChanged);
    super.dispose();
  }

  void _onCastServiceChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _startDiscovery() async {
    setState(() => _isSearching = true);
    await widget.castService.discoverDevices();
    if (mounted) setState(() => _isSearching = false);
  }

  // Name to show in the header while connected — respects a custom
  // rename if the user set one, otherwise falls back to the name
  // the Chromecast broadcasts.
  String _connectedDisplayName() {
    final connected = widget.castService.connectedDevice;
    if (connected == null) return widget.castService.deviceName;
    for (final s in widget.castService.savedDevices) {
      if (s.serviceName == connected.serviceName) return s.displayName;
    }
    return connected.name;
  }

  // Manual "connect by IP" — for when mDNS discovery fails but the
  // device's cast port is alive (seen live on the LG C2). Successful
  // connects are auto-remembered WITH the address, so afterwards the
  // device shows in Recent with direct connect available.
  Future<void> _showManualIpDialog() async {
    final ipController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: const Text('Connect by IP',
            style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "Enter the TV's IP address (check your router's device "
              'list, or the TV\'s network settings).',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ipController,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                  decimal: true),
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: '192.168.1.50',
                hintStyle: TextStyle(color: Colors.grey[600]),
                filled: true,
                fillColor: const Color(0xFF0d1b2a),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00d4ff)),
            onPressed: () =>
                Navigator.pop(context, ipController.text.trim()),
            child: const Text('Connect',
                style: TextStyle(color: Color(0xFF0d1b2a))),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty || !mounted) return;
    final ip = result;
    // Loose validation — IPv4-shaped is good enough; the connect itself
    // is the real test and fails fast on garbage.
    if (!RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(ip)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('That does not look like an IP address'),
      ));
      return;
    }
    _connectToDevice(CastDevice(
      serviceName: 'manual-$ip',
      name: 'TV @ $ip',
      host: ip,
      port: 8009,
      extras: const {},
    ));
  }

  // Saved devices sorted most-recently-connected first.
  List<SavedCastDevice> _sortedSavedDevices() {
    final list = List<SavedCastDevice>.from(widget.castService.savedDevices);
    list.sort((a, b) => b.lastSeenMillis.compareTo(a.lastSeenMillis));
    return list;
  }

  // Devices seen in the current scan that aren't already in the
  // "Recent" list — avoids showing them twice.
  List<CastDevice> _newlyDiscoveredDevices() {
    final savedIds = widget.castService.savedDevices
        .map((s) => s.serviceName)
        .toSet();
    return widget.castService.devices
        .where((d) => !savedIds.contains(d.serviceName))
        .toList();
  }

  // Small colored dot — green if the device is responding to this
  // scan, grey while we're still scanning, red if the scan finished
  // without it.
  Widget _statusDot({required bool isOnline, required bool isSearching}) {
    final color = isOnline
        ? Colors.green
        : (isSearching ? Colors.grey : Colors.red);
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: isOnline
            ? [
                BoxShadow(
                  color: Colors.green.withAlpha(180),
                  blurRadius: 6,
                ),
              ]
            : null,
      ),
    );
  }

  void _showSavedDeviceMenu(SavedCastDevice saved) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1a2332),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    Icon(iconForModel(saved.modelHint),
                        color: const Color(0xFF00d4ff)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        saved.displayName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.edit, color: Colors.white70),
                title: const Text('Rename',
                    style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _promptRename(saved);
                },
              ),
              if (saved.customName != null)
                ListTile(
                  leading: const Icon(Icons.restart_alt, color: Colors.white70),
                  title: const Text('Reset to original name',
                      style: TextStyle(color: Colors.white)),
                  subtitle: Text(saved.originalName,
                      style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await widget.castService
                        .renameSavedDevice(saved.serviceName, null);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('Remove from Recent',
                    style: TextStyle(color: Colors.red)),
                onTap: () async {
                  Navigator.pop(ctx);
                  await widget.castService
                      .removeSavedDevice(saved.serviceName);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _promptRename(SavedCastDevice saved) async {
    final controller = TextEditingController(text: saved.displayName);
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1a2332),
          title: const Text('Rename device',
              style: TextStyle(color: Colors.white)),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: saved.originalName,
              hintStyle: TextStyle(color: Colors.grey[600]),
              enabledBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: Color(0xFF2a3545)),
              ),
              focusedBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: Color(0xFF00d4ff)),
              ),
            ),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel',
                  style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Save',
                  style: TextStyle(color: Color(0xFF00d4ff))),
            ),
          ],
        );
      },
    );
    if (result != null) {
      await widget.castService.renameSavedDevice(saved.serviceName, result);
    }
  }

  Future<void> _connectToDevice(CastDevice device) async {
    setState(() {
      _isConnecting = true;
      _connectingDeviceName = device.name;
    });

    final success = await widget.castService.connectToDevice(device);

    if (mounted) {
      if (success) {
        final joined = widget.castService.joinedExisting;
        if (!joined) {
          // Send current song to Chromecast if one is playing
          widget.audioPlayerService.startCasting();
        }
        // Joined: the receiver keeps playing what it had; the app follows
        // it (AudioPlayerService.adoptRemoteSong via the cast listener).

        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(joined
                ? 'Joined the cast on ${device.name}'
                : 'Connected to ${device.name}'),
            backgroundColor: const Color(0xFF1a2332),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        setState(() {
          _isConnecting = false;
          _connectingDeviceName = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to connect to ${device.name}'),
            backgroundColor: Colors.red.shade800,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.castService,
      builder: (context, _) {
        return SafeArea(
          child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Icon(
                    widget.castService.isConnected
                        ? Icons.cast_connected
                        : Icons.cast,
                    color: const Color(0xFF00d4ff),
                    size: 28,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.castService.isConnected
                          ? 'Casting to ${_connectedDisplayName()}'
                          : 'Cast to device',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // If connected, show disconnect option.
              // Trailing three-dot menu lets you rename the device
              // while still casting to it — otherwise the rename UI
              // only appears in the Recent list, which is hidden
              // whenever you're actually connected.
              if (widget.castService.isConnected) ...[
                Builder(builder: (context) {
                  final connected = widget.castService.connectedDevice;
                  final saved = connected == null
                      ? null
                      : widget.castService.savedDevices.firstWhere(
                          (s) => s.serviceName == connected.serviceName,
                          orElse: () => SavedCastDevice(
                            serviceName: connected.serviceName,
                            originalName: connected.name,
                            modelHint: connected.extras['md'],
                            lastSeenMillis:
                                DateTime.now().millisecondsSinceEpoch,
                          ),
                        );
                  return ListTile(
                    leading: Icon(
                      iconForModel(saved?.modelHint ??
                          connected?.extras['md']),
                      color: const Color(0xFF00d4ff),
                    ),
                    title: Text(
                      saved?.displayName ?? widget.castService.deviceName,
                      style: const TextStyle(color: Colors.white),
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: const Text(
                      'Currently casting',
                      style: TextStyle(color: Color(0xFF00d4ff)),
                    ),
                    trailing: saved == null
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.more_vert,
                                color: Colors.grey),
                            tooltip: 'Rename or remove',
                            onPressed: () => _showSavedDeviceMenu(saved),
                          ),
                    onLongPress: saved == null
                        ? null
                        : () => _showSavedDeviceMenu(saved),
                  );
                }),
                const SizedBox(height: 8),
                if (widget.castService.joinedExisting) ...[
                  // Joined someone else's cast (usually Claude's). Two
                  // ways out that don't touch the TV's playback, plus the
                  // red Disconnect below which does stop it.
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () {
                        widget.audioPlayerService.takeOverCast();
                        Navigator.pop(context);
                      },
                      icon: const Icon(Icons.queue_music, size: 18),
                      label: const Text('Take over with my queue'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF00d4ff),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        widget.audioPlayerService.leaveJoinedCast();
                        Navigator.pop(context);
                      },
                      icon: const Icon(Icons.logout, size: 18),
                      label: const Text('Leave (TV keeps playing)'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      // resumeLocal: phone-side disconnect hands playback
                      // back to the phone, playing, from the TV's position.
                      widget.audioPlayerService.stopCasting(resumeLocal: true);
                      widget.castService.disconnect();
                      Navigator.pop(context);
                    },
                    icon: const Icon(Icons.close, color: Colors.red, size: 18),
                    label: const Text(
                      'Disconnect',
                      style: TextStyle(color: Colors.red),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: Colors.red.shade800),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ] else ...[
                // "Recent" — devices you've previously connected to.
                // Shows an online/offline dot based on whether the
                // device turned up in the current scan.
                if (widget.castService.savedDevices.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      'Recent',
                      style: TextStyle(
                        color: Colors.grey[500],
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                  ..._sortedSavedDevices().map((saved) {
                    final scanned = widget.castService
                        .scannedDeviceFor(saved.serviceName);
                    final isOnline = scanned != null;
                    // mDNS is a liar: the LG's cast stack can stop
                    // ADVERTISING while its CASTV2 port still answers
                    // (seen 2026-08-13 — TV invisible to every scanner
                    // on the LAN, port 8009 wide open). If we have the
                    // device's last known address, offer a direct
                    // connect instead of stranding the user.
                    final canDirect = !isOnline &&
                        saved.host != null &&
                        saved.host!.isNotEmpty;
                    final tappable = isOnline || canDirect;
                    final isConnecting = _isConnecting &&
                        _connectingDeviceName == saved.displayName;
                    return ListTile(
                      leading: Icon(
                        iconForModel(saved.modelHint),
                        color: tappable && !isConnecting
                            ? Colors.white70
                            : Colors.grey,
                      ),
                      title: Row(
                        children: [
                          Flexible(
                            child: Text(
                              saved.displayName,
                              style: TextStyle(
                                color: tappable && !isConnecting
                                    ? Colors.white
                                    : Colors.grey,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          _statusDot(
                            isOnline: isOnline,
                            isSearching: _isSearching,
                          ),
                        ],
                      ),
                      subtitle: Text(
                        isOnline
                            ? 'Online'
                            : (_isSearching
                                ? 'Checking…'
                                : canDirect
                                    ? 'Not in scan — tap to connect directly'
                                    : 'Offline'),
                        style: TextStyle(
                          color: isOnline
                              ? Colors.green[300]
                              : (_isSearching
                                  ? Colors.grey[500]
                                  : canDirect
                                      ? Colors.amber[300]
                                      : Colors.red[300]),
                          fontSize: 12,
                        ),
                      ),
                      trailing: isConnecting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFF00d4ff),
                              ),
                            )
                          : IconButton(
                              icon: const Icon(Icons.more_vert,
                                  color: Colors.grey),
                              tooltip: 'Rename or remove',
                              onPressed: () => _showSavedDeviceMenu(saved),
                            ),
                      onTap: isConnecting
                          ? null
                          : isOnline
                              ? () => _connectToDevice(scanned)
                              : canDirect
                                  ? () => _connectToDevice(CastDevice(
                                        serviceName: saved.serviceName,
                                        name: saved.displayName,
                                        host: saved.host!,
                                        port: saved.port ?? 8009,
                                        extras: const {},
                                      ))
                                  : null,
                      onLongPress: () => _showSavedDeviceMenu(saved),
                    );
                  }),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Divider(color: Color(0xFF2a3545), height: 1),
                  ),
                ],

                // Show discovered devices. While _isSearching is still
                // true, devices that have already resolved render in
                // the list above a "Still searching…" indicator, so
                // you can pick an early-found device without waiting
                // out the full scan. Filter out anything already shown
                // in the "Recent" section so we don't list it twice.
                if (_isSearching && _newlyDiscoveredDevices().isEmpty &&
                    widget.castService.savedDevices.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Column(
                        children: [
                          CircularProgressIndicator(color: Color(0xFF00d4ff)),
                          SizedBox(height: 12),
                          Text(
                            'Searching for devices...',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (!_isSearching &&
                    _newlyDiscoveredDevices().isEmpty &&
                    widget.castService.savedDevices.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Column(
                        children: [
                          const Icon(Icons.wifi_find, size: 48, color: Colors.grey),
                          const SizedBox(height: 12),
                          const Text(
                            'No devices found',
                            style: TextStyle(color: Colors.grey, fontSize: 16),
                          ),
                          const SizedBox(height: 12),
                          TextButton.icon(
                            onPressed: _startDiscovery,
                            icon: const Icon(Icons.refresh, color: Color(0xFF00d4ff)),
                            label: const Text(
                              'Search again',
                              style: TextStyle(color: Color(0xFF00d4ff)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else ...[
                  ..._newlyDiscoveredDevices().map((device) {
                    final isConnecting = _isConnecting &&
                        _connectingDeviceName == device.name;

                    return ListTile(
                      leading: Icon(
                        iconForModel(device.extras['md']),
                        color: isConnecting
                            ? Colors.grey
                            : Colors.white70,
                      ),
                      title: Text(
                        device.name,
                        style: TextStyle(
                          color: isConnecting ? Colors.grey : Colors.white,
                        ),
                      ),
                      trailing: isConnecting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFF00d4ff),
                              ),
                            )
                          : const Icon(Icons.chevron_right, color: Colors.grey),
                      onTap: isConnecting
                          ? null
                          : () => _connectToDevice(device),
                    );
                  }),
                  if (_isSearching)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(0xFF00d4ff),
                            ),
                          ),
                          SizedBox(width: 10),
                          Text(
                            'Still searching…',
                            style: TextStyle(color: Colors.grey, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                ],

                // Escape hatch for when discovery is lying: a cast
                // device's protocol port often answers even while its
                // mDNS advertiser is dead (LG, 2026-08-13). Manual IP
                // connect bypasses discovery entirely; a successful
                // connect saves the address so it's a one-time chore.
                ListTile(
                  leading:
                      const Icon(Icons.settings_ethernet, color: Colors.grey),
                  title: const Text(
                    'Connect by IP address…',
                    style: TextStyle(color: Colors.white70),
                  ),
                  onTap: _isConnecting ? null : _showManualIpDialog,
                ),
              ],

              const SizedBox(height: 8),
            ],
          ),
        ),
        );
      },
    );
  }
}
