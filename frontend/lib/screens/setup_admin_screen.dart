import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../widgets/server_settings_dialog.dart';

/// First-run screen shown when the connected server has no users yet:
/// create the admin account. The backend accepts this exactly once and
/// returns a login token, so on success the auth gate drops straight into
/// the app (and, on the first admin's first visit, the setup wizard).
class SetupAdminScreen extends StatefulWidget {
  const SetupAdminScreen({super.key});

  @override
  State<SetupAdminScreen> createState() => _SetupAdminScreenState();
}

class _SetupAdminScreenState extends State<SetupAdminScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _passwordFocus = FocusNode();
  final _confirmFocus = FocusNode();
  bool _submitting = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _confirm.dispose();
    _passwordFocus.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final username = _username.text.trim();
    final password = _password.text;
    if (username.isEmpty) {
      setState(() => _error = 'Choose a username');
      return;
    }
    if (password.length < 8) {
      setState(() => _error = 'Password must be at least 8 characters');
      return;
    }
    if (password != _confirm.text) {
      setState(() => _error = 'Passwords don\'t match');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final error = await AuthService.instance.setupAdmin(username, password);
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _error = error; // null on success; the gate swaps us out
    });
  }

  Future<void> _openServerSettings() async {
    await showDialog<bool>(
      context: context,
      builder: (_) => const ServerSettingsDialog(),
    );
  }

  InputDecoration _decoration(String label, IconData icon, {Widget? suffix}) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon),
      border: const OutlineInputBorder(),
      suffixIcon: suffix,
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
                          'Welcome to NASRadio',
                          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Center(
                        child: Text(
                          'This server has no accounts yet. Create the admin account — '
                          'it manages the library, integrations and other users.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, color: Colors.grey),
                        ),
                      ),
                      const SizedBox(height: 26),
                      TextField(
                        controller: _username,
                        enabled: !_submitting,
                        autofocus: true,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.newUsername],
                        decoration: _decoration('Username', Icons.person_outline),
                        onSubmitted: (_) => _passwordFocus.requestFocus(),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _password,
                        focusNode: _passwordFocus,
                        enabled: !_submitting,
                        obscureText: _obscure,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.newPassword],
                        decoration: _decoration(
                          'Password (8+ characters)',
                          Icons.lock_outline,
                          suffix: IconButton(
                            icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                        onSubmitted: (_) => _confirmFocus.requestFocus(),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _confirm,
                        focusNode: _confirmFocus,
                        enabled: !_submitting,
                        obscureText: _obscure,
                        decoration: _decoration('Confirm password', Icons.lock_outline),
                        onSubmitted: (_) => _submit(),
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
                      const SizedBox(height: 22),
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: ElevatedButton(
                          onPressed: _submitting ? null : _submit,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00d4ff),
                            foregroundColor: Colors.black,
                          ),
                          child: _submitting
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.black,
                                  ),
                                )
                              : const Text(
                                  'Create admin account',
                                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                ),
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
                tooltip: 'Server address',
                onPressed: _submitting ? null : _openServerSettings,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
