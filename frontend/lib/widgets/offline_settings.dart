import 'package:flutter/material.dart';

import '../services/offline_service.dart';
import '../screens/offline_downloads_screen.dart';

/// Settings -> Playback -> "Offline & Downloads" (Android).
class OfflineSettingsSection extends StatelessWidget {
  const OfflineSettingsSection({super.key});

  static const _accent = Color(0xFF00d4ff);
  static const _caps = [5, 10, 20, 50, 100];
  static const _formats = {
    'opus160': ('Opus 160', 'About 4.8 MB a song, sounds the same in a car (recommended)'),
    'high': ('AAC 320', 'About 9.6 MB a song'),
    'lossless': ('Lossless', 'The original files, about 28 MB a song'),
  };

  @override
  Widget build(BuildContext context) {
    final o = OfflineService.instance;
    return AnimatedBuilder(
      animation: o,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            activeColor: _accent,
            title: const Text('Pre-load for dead zones',
                style: TextStyle(color: Colors.white)),
            subtitle: const Text(
                'Keeps the next hour of what you\'re playing on the phone, '
                'and the last few hours you played for replays',
                style: TextStyle(color: Colors.grey)),
            value: o.preloadEnabled,
            onChanged: o.setPreload,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            activeColor: _accent,
            title: const Text('Use cellular data',
                style: TextStyle(color: Colors.white)),
            subtitle: const Text(
                'Off: downloads and pre-loading wait for Wi-Fi',
                style: TextStyle(color: Colors.grey)),
            value: o.useCellular,
            onChanged: o.setUseCellular,
          ),
          const SizedBox(height: 8),
          const Text('Download format',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          for (final f in _formats.entries)
            RadioListTile<String>(
              contentPadding: EdgeInsets.zero,
              dense: true,
              activeColor: _accent,
              value: f.key,
              groupValue: o.downloadFormat,
              onChanged: (v) => o.setDownloadFormat(v!),
              title: Text(f.value.$1, style: const TextStyle(color: Colors.white)),
              subtitle: Text(f.value.$2, style: const TextStyle(color: Colors.grey)),
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Storage limit for downloads',
                style: TextStyle(color: Colors.white)),
            subtitle: Text('About ${o.capGb * 200} songs at Opus 160',
                style: const TextStyle(color: Colors.grey)),
            trailing: DropdownButton<int>(
              value: _caps.contains(o.capGb) ? o.capGb : 20,
              dropdownColor: const Color(0xFF1b2838),
              items: [
                for (final c in _caps)
                  DropdownMenuItem(value: c, child: Text('$c GB')),
              ],
              onChanged: (v) => o.setCapGb(v!),
            ),
          ),
          Text(
            'Downloads: ${o.downloadedSongCount} songs, '
            '${OfflineService.formatBytes(o.downloadBytes)} · '
            'Replay cache: ${OfflineService.formatBytes(o.cacheBytes)}',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          if (o.problem != null) ...[
            const SizedBox(height: 4),
            Text(o.problem!,
                style: const TextStyle(fontSize: 12, color: Colors.orangeAccent)),
          ],
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: o.cacheBytes == 0 ? null : () => _confirmClear(context, o),
            icon: const Icon(Icons.cleaning_services_outlined, size: 18),
            label: const Text('Clear replay cache'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Color(0xFF2a3a4d)),
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.download_done, color: _accent),
            title: const Text('Downloads on this phone',
                style: TextStyle(color: Colors.white)),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const OfflineDownloadsScreen()),
            ),
          ),
          const Text(
            'Download a playlist or album with the Download button on its page.',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context, OfflineService o) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1b2838),
        title: const Text('Clear the replay cache?'),
        content: const Text(
            'Songs kept from what you played (and the pre-loaded hour) are '
            'deleted from the phone. Your downloads stay.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (yes == true) await o.clearCache();
  }
}
