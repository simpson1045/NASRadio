import 'package:flutter/material.dart';

import '../services/admin_settings_service.dart';
import 'integration_cards.dart';

/// Settings → Integrations, admin half: every server integration as the
/// same Test/Save cards the first-run wizard uses. Loads the schema once
/// and refreshes it from each Save's response.
class AdminIntegrationsPanel extends StatefulWidget {
  const AdminIntegrationsPanel({super.key});

  @override
  State<AdminIntegrationsPanel> createState() => _AdminIntegrationsPanelState();
}

class _AdminIntegrationsPanelState extends State<AdminIntegrationsPanel> {
  Map<String, AdminSetting>? _schema;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final list = await AdminSettingsService.instance.getSettings();
      if (!mounted) return;
      setState(() => _schema = {for (final s in list) s.key: s});
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _onSaved(List<AdminSetting> updated) {
    setState(() => _schema = {for (final s in updated) s.key: s});
  }

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 10),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: Color(0xFF00d4ff),
            letterSpacing: 1.5,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Row(
        children: [
          Expanded(child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
          TextButton(onPressed: _load, child: const Text('Retry')),
        ],
      );
    }
    final s = _schema;
    if (s == null) {
      return const Center(
        child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator()),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Server integrations',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        const Text(
          'Admin only. Changes apply immediately, no restart. Test checks the values in the '
          'fields before you save them.',
          style: TextStyle(fontSize: 13, color: Colors.grey),
        ),
        const SizedBox(height: 12),
        _heading('LIBRARY'),
        ...integrationCards(IntegrationSection.library, s, _onSaved, compact: true),
        _heading('DOWNLOADS'),
        ...integrationCards(IntegrationSection.downloads, s, _onSaved, compact: true),
        _heading('METADATA & ARTWORK'),
        ...integrationCards(IntegrationSection.metadata, s, _onSaved, compact: true),
        _heading('SERVER & SERVICES'),
        ...integrationCards(IntegrationSection.server, s, _onSaved, compact: true),
        _heading('LIVING ROOM'),
        ...integrationCards(IntegrationSection.livingRoom, s, _onSaved, compact: true),
      ],
    );
  }
}
