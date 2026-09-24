import 'package:flutter/material.dart';

import '../services/admin_settings_service.dart';
import '../widgets/integration_cards.dart';

/// First-run wizard, shown to an admin once per server (until it is finished
/// or skipped, which sets SETUP_COMPLETED on the server). Every card is the
/// same schema-driven [SettingsSectionCard] Settings → Integrations uses, so
/// nothing here is a one-off: Test checks the unsaved values, Save writes
/// them live, and skipping a page is always allowed.
///
/// Pages: Library → Downloads → Metadata → Server & sidecars → Living room →
/// Finish (services summary + "Scan library").
class SetupWizardScreen extends StatefulWidget {
  final VoidCallback onFinished;
  const SetupWizardScreen({super.key, required this.onFinished});

  @override
  State<SetupWizardScreen> createState() => _SetupWizardScreenState();
}

class _SetupWizardScreenState extends State<SetupWizardScreen> {
  static const _accent = Color(0xFF00d4ff);
  static const _titles = [
    'Your music',
    'Downloads',
    'Metadata & artwork',
    'Server & services',
    'Living room',
    'All set',
  ];

  Map<String, AdminSetting>? _schema;
  String? _loadError;
  int _page = 0;
  bool _finishing = false;
  String? _finishError;
  Map<String, dynamic>? _services;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loadError = null;
    });
    try {
      final list = await AdminSettingsService.instance.getSettings();
      if (!mounted) return;
      setState(() => _schema = {for (final s in list) s.key: s});
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _onSaved(List<AdminSetting> updated) {
    setState(() => _schema = {for (final s in updated) s.key: s});
  }

  Future<void> _loadServices() async {
    try {
      final data = await AdminSettingsService.instance.getServices();
      if (!mounted) return;
      setState(() => _services = data);
    } catch (_) {}
  }

  void _go(int page) {
    setState(() => _page = page.clamp(0, _titles.length - 1));
    if (_page == _titles.length - 1) _loadServices();
  }

  Future<void> _finish({required bool scan}) async {
    setState(() {
      _finishing = true;
      _finishError = null;
    });
    try {
      if (scan) await AdminSettingsService.instance.startLibraryScan();
      await AdminSettingsService.instance.markSetupCompleted();
      if (!mounted) return;
      widget.onFinished();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _finishing = false;
        _finishError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _skipAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF132549),
        title: const Text('Skip setup?'),
        content: const Text(
          'You can configure everything later under Settings → Integrations. '
          'The library stays empty until you set a music folder and scan it.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Back')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Skip')),
        ],
      ),
    );
    if (ok == true) await _finish(scan: false);
  }

  // ── Pages ──────────────────────────────────────────────────────────

  Widget _intro(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Text(text, style: const TextStyle(fontSize: 14, color: Colors.grey)),
      );

  Widget _pageLibrary(Map<String, AdminSetting> s) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _intro('Where does your music live? This is the folder the scanner walks. '
              'In Docker it is the container-side path of your bind mount, usually /music.'),
          ...integrationCards(IntegrationSection.library, s, _onSaved),
        ],
      );

  Widget _pageDownloads(Map<String, AdminSetting> s) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _intro('Optional. NASRadio can search indexers through Prowlarr, send torrents to '
              'Transmission and import finished downloads into the library. Skip this if you '
              'don\'t run them.'),
          ...integrationCards(IntegrationSection.downloads, s, _onSaved),
        ],
      );

  Widget _pageMetadata(Map<String, AdminSetting> s) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _intro('Optional, all free to register. Artwork and artist images come from Last.fm and '
              'fanart.tv; Spotify powers playlist import and discovery; Podcast Index powers '
              'podcast search; AcoustID identifies untagged files.'),
          ...integrationCards(IntegrationSection.metadata, s, _onSaved),
        ],
      );

  Widget _pageServer(Map<String, AdminSetting> s) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _intro('The public address is only needed for casting, party links and the '
              'MusicBrainz tool. The two sidecars are optional Docker services from this repo.'),
          ...integrationCards(IntegrationSection.server, s, _onSaved),
        ],
      );

  Widget _pageLivingRoom(Map<String, AdminSetting> s) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _intro('Optional and advanced. Lets the SERVER cast to a Chromecast/TV on its own '
              '(the "headless" cast used by voice assistants and automations) and drive a '
              'Denon/Marantz receiver over telnet. Casting from the app works without any of this.'),
          ...integrationCards(IntegrationSection.livingRoom, s, _onSaved),
        ],
      );

  Widget _serviceRow(String label, Map<String, dynamic>? info) {
    final configured = info?['configured'] == true;
    final reachable = info?['reachable'];
    final ok = reachable == null ? configured : (configured && reachable == true);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            configured ? (ok ? Icons.check_circle : Icons.warning_amber) : Icons.radio_button_unchecked,
            size: 18,
            color: configured ? (ok ? Colors.greenAccent : Colors.orangeAccent) : Colors.grey,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(label)),
          Text(
            !configured ? 'not set' : (reachable == null ? 'configured' : (ok ? 'reachable' : 'unreachable')),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _pageFinish() {
    final sv = (_services?['services'] as Map?)?.cast<String, dynamic>();
    final lib = sv?['library'] as Map<String, dynamic>?;
    final songs = lib?['song_count'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _intro('Here is what this server has. Anything marked "not set" can be added later '
            'under Settings → Integrations.'),
        Container(
          padding: const EdgeInsets.all(18),
          margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            color: const Color(0xFF0d1b2a).withOpacity(0.72),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withOpacity(0.07)),
          ),
          child: sv == null
              ? const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _serviceRow('Music library${lib?['exists'] == true ? '' : ' (folder not found)'}', lib),
                    _serviceRow('Transmission', sv['transmission'] as Map<String, dynamic>?),
                    _serviceRow('Prowlarr', sv['prowlarr'] as Map<String, dynamic>?),
                    _serviceRow('Lidarr', sv['lidarr'] as Map<String, dynamic>?),
                    _serviceRow('Last.fm artwork', sv['lastfm'] as Map<String, dynamic>?),
                    _serviceRow('fanart.tv', sv['fanart'] as Map<String, dynamic>?),
                    _serviceRow('Spotify', sv['spotify'] as Map<String, dynamic>?),
                    _serviceRow('Podcast Index', sv['podcast_index'] as Map<String, dynamic>?),
                    _serviceRow('Essentia', sv['essentia'] as Map<String, dynamic>?),
                    _serviceRow('Transcode', sv['transcode'] as Map<String, dynamic>?),
                    _serviceRow('Public address', sv['public_url'] as Map<String, dynamic>?),
                    _serviceRow('Cast device', sv['cast_device'] as Map<String, dynamic>?),
                    _serviceRow('AV receiver', sv['denon'] as Map<String, dynamic>?),
                    if (songs != null) ...[
                      const Divider(height: 24),
                      Text('$songs songs in the library',
                          style: const TextStyle(color: Colors.grey, fontSize: 13)),
                    ],
                  ],
                ),
        ),
        if (_finishError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_finishError!, style: const TextStyle(color: Colors.redAccent)),
          ),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: _finishing || lib?['exists'] != true ? null : () => _finish(scan: true),
                  style: ElevatedButton.styleFrom(backgroundColor: _accent, foregroundColor: Colors.black),
                  icon: const Icon(Icons.library_music),
                  label: const Text('Scan library and finish', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              height: 48,
              child: OutlinedButton(
                onPressed: _finishing ? null : () => _finish(scan: false),
                child: const Text('Finish without scanning'),
              ),
            ),
          ],
        ),
        if (lib?['exists'] != true)
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: Text('Set a music folder that exists on the server (page 1) to enable scanning.',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
      ],
    );
  }

  Widget _body(Map<String, AdminSetting> s) {
    switch (_page) {
      case 0:
        return _pageLibrary(s);
      case 1:
        return _pageDownloads(s);
      case 2:
        return _pageMetadata(s);
      case 3:
        return _pageServer(s);
      case 4:
        return _pageLivingRoom(s);
      default:
        return _pageFinish();
    }
  }

  @override
  Widget build(BuildContext context) {
    final last = _titles.length - 1;
    return Scaffold(
      backgroundColor: const Color(0xFF0a0e27),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0a0e27),
        elevation: 0,
        title: Text('Set up NASRadio · ${_page + 1}/${_titles.length}'),
        actions: [
          TextButton(
            onPressed: _finishing ? null : _skipAll,
            child: const Text('Skip setup', style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
      body: _schema == null
          ? Center(
              child: _loadError == null
                  ? const CircularProgressIndicator()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_loadError!, style: const TextStyle(color: Colors.redAccent)),
                        const SizedBox(height: 12),
                        OutlinedButton(onPressed: _load, child: const Text('Retry')),
                      ],
                    ),
            )
          : Column(
              children: [
                LinearProgressIndicator(
                  value: (_page + 1) / _titles.length,
                  minHeight: 3,
                  color: _accent,
                  backgroundColor: Colors.white12,
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 720),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_titles[_page],
                                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 10),
                            _body(_schema!),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (_page < last)
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                      child: Row(
                        children: [
                          if (_page > 0)
                            OutlinedButton(onPressed: () => _go(_page - 1), child: const Text('Back')),
                          const Spacer(),
                          ElevatedButton(
                            onPressed: () => _go(_page + 1),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _accent,
                              foregroundColor: Colors.black,
                            ),
                            child: Text(_page == 0 ? 'Next' : 'Next / skip'),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                      child: Row(
                        children: [
                          OutlinedButton(onPressed: () => _go(_page - 1), child: const Text('Back')),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
