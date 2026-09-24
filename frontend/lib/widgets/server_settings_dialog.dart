import 'package:flutter/material.dart';
import '../services/api_service.dart';

/// Server address configuration, reachable from the login screen's gear
/// icon. Both addresses are optional; clearing both sends the app back to
/// the first-run connect screen. Saved values live in SharedPreferences
/// (see ApiService.saveServerConfig).
class ServerSettingsDialog extends StatefulWidget {
  const ServerSettingsDialog({super.key});

  @override
  State<ServerSettingsDialog> createState() => _ServerSettingsDialogState();
}

class _ServerSettingsDialogState extends State<ServerSettingsDialog> {
  late final TextEditingController _lanController;
  late final TextEditingController _wanController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _lanController = TextEditingController(text: ApiService.lanHost);
    _wanController = TextEditingController(text: ApiService.wanHost);
  }

  @override
  void dispose() {
    _lanController.dispose();
    _wanController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await ApiService.saveServerConfig(
      lanHost: _lanController.text,
      wanHost: _wanController.text,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.of(context).pop(true);
  }

  void _clear() {
    _lanController.clear();
    _wanController.clear();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF132549),
      title: const Row(
        children: [
          Icon(Icons.dns_outlined, color: Color(0xFF00d4ff)),
          SizedBox(width: 10),
          Text('Server Address', style: TextStyle(color: Colors.white)),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Point the app at your NASRadio server. The app tries the '
              'local address first and falls back to the remote one when '
              'away from home.',
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _lanController,
              enabled: !_saving,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Local address (LAN)',
                hintText: 'http://192.168.1.20:5002',
                helperText: 'Your server\'s LAN IP or hostname, port 5002',
                prefixIcon: Icon(Icons.home_outlined),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _wanController,
              enabled: !_saving,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Remote address (optional)',
                hintText: 'https://music.example.com',
                helperText:
                    'Public HTTPS address for streaming away from home',
                prefixIcon: Icon(Icons.public),
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : _clear,
          child: const Text('Clear', style: TextStyle(color: Colors.grey)),
        ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _saving ? null : _save,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF00d4ff),
            foregroundColor: Colors.black,
          ),
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.black),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
