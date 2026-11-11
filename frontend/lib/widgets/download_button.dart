import 'dart:io';

import 'package:flutter/material.dart';

import '../services/offline_service.dart';

/// ⬇ Download for a playlist or album page (Android): Download ->
/// "Downloading 12 of 60" -> "Downloaded". Tapping a download offers to
/// remove it. Nothing on other platforms.
class DownloadButton extends StatelessWidget {
  const DownloadButton({super.key, required this.kind, required this.id});

  final String kind; // 'playlist' | 'album'
  final int id;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) return const SizedBox.shrink();
    final offline = OfflineService.instance;
    return AnimatedBuilder(
      animation: offline,
      builder: (context, _) {
        final st = offline.statusOf(kind, id);
        final IconData icon;
        final String label;
        Color fg = Colors.white;
        switch (st.state) {
          case OfflineState.none:
            icon = Icons.download_outlined;
            label = 'Download';
          case OfflineState.downloading:
            icon = Icons.downloading;
            label = 'Downloading ${st.done} of ${st.total}';
          case OfflineState.waiting:
            icon = Icons.pause_circle_outline;
            label = '${offline.problem ?? 'Waiting'} · ${st.done} of ${st.total}';
          case OfflineState.done:
            icon = Icons.download_done;
            label = 'Downloaded';
            fg = const Color(0xFF00d4ff);
        }
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.only(top: 8),
          child: OutlinedButton.icon(
            onPressed: !offline.isReady
                ? null
                : () => st.state == OfflineState.none
                    ? offline.download(kind, id)
                    : _confirmRemove(context, offline),
            icon: Icon(icon, size: 18),
            label: Text(label, overflow: TextOverflow.ellipsis),
            style: OutlinedButton.styleFrom(
              foregroundColor: fg,
              side: const BorderSide(color: Color(0xFF2a3a4d)),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        );
      },
    );
  }

  Future<void> _confirmRemove(BuildContext context, OfflineService offline) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1b2838),
        title: const Text('Remove download?'),
        content: Text(
          'The downloaded songs of this $kind are deleted from your phone. '
          'Songs another download uses stay. You can download it again any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (yes == true) await offline.remove(kind, id);
  }
}
