import 'package:flutter/material.dart';

import '../services/admin_settings_service.dart';

/// Which unsaved field values a connection test should send, keyed the way
/// the backend's test endpoint expects (url, api_key, user, password, ...).
typedef TestOverridesBuilder = Map<String, dynamic> Function(Map<String, String> values);

/// One card of related settings (e.g. "Prowlarr": URL + API key) driven by
/// the schema the backend returns: labels, help, secret masking and field
/// types come from there, so adding a setting server-side needs no app work.
///
/// Test sends the CURRENT field values (unsaved) so you can check before you
/// save; Save writes them and reports the server's answer. Used by the
/// first-run wizard and by Settings → Integrations.
class SettingsSectionCard extends StatefulWidget {
  final String title;
  final String? description;
  final List<String> keys;
  final Map<String, AdminSetting> schema;
  final String? testService;
  final TestOverridesBuilder? testOverrides;
  final void Function(List<AdminSetting> updated)? onSaved;
  final bool compact;

  const SettingsSectionCard({
    super.key,
    required this.title,
    required this.keys,
    required this.schema,
    this.description,
    this.testService,
    this.testOverrides,
    this.onSaved,
    this.compact = false,
  });

  @override
  State<SettingsSectionCard> createState() => _SettingsSectionCardState();
}

class _SettingsSectionCardState extends State<SettingsSectionCard> {
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, bool> _bools = {};
  final Set<String> _revealed = {};
  bool _busy = false;
  ServiceTestResult? _test;
  String? _saveMessage;
  bool _saveOk = false;

  static const _accent = Color(0xFF00d4ff);

  @override
  void initState() {
    super.initState();
    for (final k in widget.keys) {
      final s = widget.schema[k];
      if (s == null) continue;
      if (s.type == 'bool') {
        _bools[k] = s.value == true || s.value.toString() == 'true';
      } else {
        // Secrets come back masked as '' — leave the field empty and show
        // "(saved)" so re-saving the card never wipes the stored value.
        _controllers[k] = TextEditingController(text: s.secret ? '' : s.valueText);
      }
    }
  }

  @override
  void didUpdateWidget(covariant SettingsSectionCard old) {
    super.didUpdateWidget(old);
    // Non-secret values may have been reloaded from the server.
    for (final k in widget.keys) {
      final s = widget.schema[k];
      if (s == null || s.secret) continue;
      final c = _controllers[k];
      if (c != null && !c.text.isNotEmpty && s.valueText.isNotEmpty) c.text = s.valueText;
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, String> _currentValues() => {
        for (final e in _controllers.entries) e.key: e.value.text.trim(),
        for (final e in _bools.entries) e.key: e.value.toString(),
      };

  Future<void> _runTest() async {
    final service = widget.testService;
    if (service == null) return;
    setState(() {
      _busy = true;
      _test = null;
      _saveMessage = null;
    });
    final overrides = widget.testOverrides?.call(_currentValues()) ?? const {};
    final result = await AdminSettingsService.instance.testService(service, overrides: overrides);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _test = result;
    });
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _saveMessage = null;
    });
    final payload = <String, dynamic>{};
    for (final k in widget.keys) {
      final s = widget.schema[k];
      if (s == null) continue;
      if (s.type == 'bool') {
        payload[k] = _bools[k] ?? false;
      } else {
        final text = _controllers[k]!.text.trim();
        // Empty secret = "leave it alone" (server skips it); empty non-secret
        // = clear the override so env/default applies again.
        payload[k] = (s.secret && text.isEmpty) ? '' : (text.isEmpty ? null : text);
      }
    }
    try {
      final updated = await AdminSettingsService.instance.saveSettings(payload);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _saveOk = true;
        _saveMessage = 'Saved';
      });
      widget.onSaved?.call(updated);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _saveOk = false;
        _saveMessage = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Widget _field(AdminSetting s) {
    if (s.type == 'bool') {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(s.label),
        subtitle: s.help.isNotEmpty ? Text(s.help, style: const TextStyle(fontSize: 12)) : null,
        value: _bools[s.key] ?? false,
        activeColor: _accent,
        onChanged: _busy ? null : (v) => setState(() => _bools[s.key] = v),
      );
    }
    final controller = _controllers[s.key]!;
    final hidden = s.secret && !_revealed.contains(s.key);
    String? helper = s.help.isNotEmpty ? s.help : null;
    if (s.secret && s.isSet && controller.text.isEmpty) {
      helper = '${helper ?? ''}${helper == null ? '' : ' · '}A value is saved; leave blank to keep it.';
    } else if (s.source == 'env' && !s.secret) {
      helper = '${helper ?? ''}${helper == null ? '' : ' · '}From .env; saving here overrides it.';
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: controller,
        enabled: !_busy,
        obscureText: hidden,
        autocorrect: false,
        keyboardType: s.type == 'int'
            ? TextInputType.number
            : (s.type == 'url' ? TextInputType.url : TextInputType.text),
        decoration: InputDecoration(
          labelText: s.label,
          helperText: helper,
          helperMaxLines: 3,
          border: const OutlineInputBorder(),
          isDense: widget.compact,
          suffixIcon: s.secret
              ? IconButton(
                  icon: Icon(hidden ? Icons.visibility : Icons.visibility_off, size: 20),
                  onPressed: () => setState(() {
                    if (!_revealed.add(s.key)) _revealed.remove(s.key);
                  }),
                )
              : null,
        ),
      ),
    );
  }

  Widget _banner({required bool ok, required String text, String? hint}) {
    final color = ok ? Colors.greenAccent : Colors.redAccent;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(ok ? Icons.check_circle : Icons.error_outline, color: color, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(text, style: TextStyle(color: color))),
            ],
          ),
          if (hint != null) ...[
            const SizedBox(height: 4),
            Text(hint, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fields = widget.keys.map((k) => widget.schema[k]).whereType<AdminSetting>().toList();
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF0d1b2a).withOpacity(0.72),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withOpacity(0.07)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          if (widget.description != null) ...[
            const SizedBox(height: 4),
            Text(widget.description!, style: const TextStyle(fontSize: 13, color: Colors.grey)),
          ],
          const SizedBox(height: 16),
          for (final s in fields) _field(s),
          if (_test != null) _banner(ok: _test!.ok, text: _test!.message, hint: _test!.hint),
          if (_saveMessage != null) _banner(ok: _saveOk, text: _saveMessage!),
          Row(
            children: [
              if (widget.testService != null)
                OutlinedButton.icon(
                  onPressed: _busy ? null : _runTest,
                  icon: const Icon(Icons.network_check, size: 18),
                  label: const Text('Test'),
                ),
              if (widget.testService != null) const SizedBox(width: 10),
              ElevatedButton.icon(
                onPressed: _busy ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.black,
                ),
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                      )
                    : const Icon(Icons.save_outlined, size: 18),
                label: const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
