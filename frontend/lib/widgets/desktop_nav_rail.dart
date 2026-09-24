import 'package:flutter/material.dart';
import '../services/audio_player_service.dart';
import 'app_back_navigator.dart';

/// Desktop shell navigation rail (DESKTOP_UX_SPEC.md §4) — replaces the
/// phone bottom-tab bar on wide windows. Same six destinations, same
/// semantics: indexes 0–4 select tabs, index 5 opens Now Playing.
class DesktopNavRail extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final AudioPlayerService audioPlayerService;

  const DesktopNavRail({
    super.key,
    required this.selectedIndex,
    required this.onSelect,
    required this.audioPlayerService,
  });

  static const _accent = Color(0xFF00d4ff);

  Widget _navArrow({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(icon, size: 20, color: Colors.white70),
          ),
        ),
      ),
    );
  }

  Widget _entry({
    required BuildContext context,
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: selected ? _accent.withOpacity(0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          hoverColor: Colors.white.withOpacity(0.05),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 21,
                  color: selected ? _accent : Colors.white60,
                ),
                const SizedBox(width: 13),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13.5,
                    color: selected ? _accent : Colors.white70,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 216,
      decoration: BoxDecoration(
        color: const Color(0xFF0d1b2a),
        border: Border(
          right: BorderSide(color: Colors.white.withOpacity(0.06)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Brand
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 16, 18),
            child: Row(
              children: [
                Image.asset(
                  'assets/images/nasradio_logo.png',
                  width: 34,
                  height: 34,
                  filterQuality: FilterQuality.high,
                ),
                const SizedBox(width: 10),
                const Text(
                  'NASRadio',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: _accent,
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),
          ),
          // Back / forward — same history the mouse side-buttons walk.
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: Row(
              children: [
                _navArrow(
                  icon: Icons.arrow_back_rounded,
                  tooltip: 'Back',
                  onTap: NavBackController.back,
                ),
                const SizedBox(width: 4),
                _navArrow(
                  icon: Icons.arrow_forward_rounded,
                  tooltip: 'Forward',
                  onTap: NavBackController.forward,
                ),
              ],
            ),
          ),
          _entry(
            context: context,
            icon: Icons.home,
            label: 'Home',
            selected: selectedIndex == 0,
            onTap: () => onSelect(0),
          ),
          _entry(
            context: context,
            icon: Icons.library_music,
            label: 'Library',
            selected: selectedIndex == 1,
            onTap: () => onSelect(1),
          ),
          _entry(
            context: context,
            icon: Icons.search,
            label: 'Search',
            selected: selectedIndex == 2,
            onTap: () => onSelect(2),
          ),
          _entry(
            context: context,
            icon: Icons.playlist_play,
            label: 'Playlists',
            selected: selectedIndex == 3,
            onTap: () => onSelect(3),
          ),
          _entry(
            context: context,
            icon: Icons.favorite,
            label: 'Favorites',
            selected: selectedIndex == 4,
            onTap: () => onSelect(4),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(height: 1, color: Colors.white.withOpacity(0.06)),
          ),
          const SizedBox(height: 6),
          // Now Playing — an action, not a tab (mirrors bottom-bar item 5).
          ListenableBuilder(
            listenable: audioPlayerService,
            builder: (context, _) {
              final isPlaying = audioPlayerService.isPlaying;
              final hasSong = audioPlayerService.currentSong != null;
              return _entry(
                context: context,
                icon: isPlaying
                    ? Icons.pause_circle_filled
                    : hasSong
                    ? Icons.play_circle_filled
                    : Icons.play_circle_outline,
                label: 'Now Playing',
                selected: false,
                onTap: () => onSelect(5),
              );
            },
          ),
          const Spacer(),
          // Volume — desktop has a pointer; give it a slider.
          _RailVolume(audioPlayerService: audioPlayerService),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

class _RailVolume extends StatefulWidget {
  final AudioPlayerService audioPlayerService;
  const _RailVolume({required this.audioPlayerService});

  @override
  State<_RailVolume> createState() => _RailVolumeState();
}

class _RailVolumeState extends State<_RailVolume> {
  // Track the slider locally while dragging so remote-sync echoes
  // don't fight the thumb mid-gesture.
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.audioPlayerService,
      builder: (context, _) {
        final v = _dragging ?? widget.audioPlayerService.getVolume();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(
                v == 0
                    ? Icons.volume_off
                    : v < 0.5
                    ? Icons.volume_down
                    : Icons.volume_up,
                size: 18,
                color: Colors.white54,
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 12,
                    ),
                    activeTrackColor: const Color(0xFF00d4ff),
                    inactiveTrackColor: Colors.white24,
                    thumbColor: const Color(0xFF00d4ff),
                  ),
                  child: Slider(
                    value: v.clamp(0.0, 1.0),
                    onChanged: (nv) {
                      setState(() => _dragging = nv);
                      widget.audioPlayerService.setVolume(nv);
                    },
                    onChangeEnd: (nv) {
                      widget.audioPlayerService.setVolume(nv);
                      setState(() => _dragging = null);
                    },
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
