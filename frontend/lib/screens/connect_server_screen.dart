import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../widgets/server_settings_dialog.dart';

/// First-run screen: the app ships with no server address, so before login
/// we ask where the NASRadio backend lives. One field, a Test button, and
/// Continue. Saving bumps [ApiService.serverConfigChanged], which makes the
/// auth gate move on to setup/login — no manual navigation needed.
///
/// An https address is stored as the remote host, anything else as the LAN
/// host; the gear icon opens the full two-address dialog for people who
/// want both from the start.
class ConnectServerScreen extends StatefulWidget {
  const ConnectServerScreen({super.key});

  @override
  State<ConnectServerScreen> createState() => _ConnectServerScreenState();
}

class _ConnectServerScreenState extends State<ConnectServerScreen> {
  final _controller = TextEditingController();
  bool _busy = false;
  bool? _reachable; // null = not tested yet
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<bool> _test() async {
    final host = ApiService.normalizeHost(_controller.text);
    if (host.isEmpty) {
      setState(() {
        _error = 'Enter your server address';
        _reachable = null;
      });
      return false;
    }
    setState(() {
      _busy = true;
      _error = null;
      _reachable = null;
    });
    final ok = await ApiService.probeHost(host);
    if (!mounted) return ok;
    setState(() {
      _busy = false;
      _reachable = ok;
      _error = ok
          ? null
          : 'No NASRadio server answered at $host. Check the address and '
              'that the backend is running (port 5002 by default).';
    });
    return ok;
  }

  Future<void> _continue() async {
    if (_reachable != true) {
      final ok = await _test();
      if (!ok) return;
    }
    final host = ApiService.normalizeHost(_controller.text);
    setState(() => _busy = true);
    final remote = host.startsWith('https://');
    await ApiService.saveServerConfig(
      lanHost: remote ? '' : host,
      wanHost: remote ? host : '',
    );
    // saveServerConfig bumps serverConfigChanged; the gate takes it from here.
  }

  Future<void> _openAdvanced() async {
    await showDialog<bool>(
      context: context,
      builder: (_) => const ServerSettingsDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0a0e27),
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.28),
                radius: 1.15,
                colors: [Color(0xFF132549), Color(0xFF0a0e27)],
              ),
            ),
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Image.asset(
                          'assets/images/nasradio_logo.png',
                          width: 96,
                          height: 96,
                          filterQuality: FilterQuality.high,
                        ),
                      ),
                      const SizedBox(height: 18),
                      const Center(
                        child: Text(
                          'Connect to your NASRadio server',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Center(
                        child: Text(
                          'Enter the address of the backend you (or your household) run. '
                          'You can change it later from the gear on the sign-in screen.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, color: Colors.grey),
                        ),
                      ),
                      const SizedBox(height: 26),
                      TextField(
                        controller: _controller,
                        enabled: !_busy,
                        autofocus: true,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: 'Server address',
                          hintText: 'http://192.168.1.20:5002',
                          helperText:
                              'LAN IP or hostname with port, or your https:// address',
                          prefixIcon: const Icon(Icons.dns_outlined),
                          border: const OutlineInputBorder(),
                          suffixIcon: _reachable == null
                              ? null
                              : Icon(
                                  _reachable! ? Icons.check_circle : Icons.cancel,
                                  color: _reachable! ? Colors.greenAccent : Colors.red,
                                ),
                        ),
                        onChanged: (_) {
                          if (_reachable != null || _error != null) {
                            setState(() {
                              _reachable = null;
                              _error = null;
                            });
                          }
                        },
                        onSubmitted: (_) => _continue(),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.red.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.red),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.error_outline, color: Colors.red, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(_error!, style: const TextStyle(color: Colors.red)),
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (_reachable == true) ...[
                        const SizedBox(height: 14),
                        const Row(
                          children: [
                            Icon(Icons.check_circle, color: Colors.greenAccent, size: 18),
                            SizedBox(width: 8),
                            Text('Server found', style: TextStyle(color: Colors.greenAccent)),
                          ],
                        ),
                      ],
                      const SizedBox(height: 22),
                      Row(
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: 48,
                              child: OutlinedButton(
                                onPressed: _busy ? null : _test,
                                child: const Text('Test'),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 2,
                            child: SizedBox(
                              height: 48,
                              child: ElevatedButton(
                                onPressed: _busy ? null : _continue,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF00d4ff),
                                  foregroundColor: Colors.black,
                                ),
                                child: _busy
                                    ? const SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.black,
                                        ),
                                      )
                                    : const Text(
                                        'Continue',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      const Center(
                        child: Text(
                          "Don't have a server yet? NASRadio is self-hosted: run the backend "
                          'on a NAS or any machine with your music, then come back here.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: SafeArea(
              child: IconButton(
                icon: const Icon(Icons.settings_outlined, color: Colors.grey),
                tooltip: 'Local and remote addresses',
                onPressed: _busy ? null : _openAdvanced,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
