import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../../services/audio_player_service.dart';
import '../../services/update_service.dart';
import '../../widgets/mini_player.dart';
import '../../widgets/tv_focus.dart';
import '../../widgets/update_banner.dart';
import 'tv_dashboard_screen.dart';
import 'tv_library_screen.dart';

/// Top-level shell for the Fire TV / Android TV layout. A vertical
/// side rail on the left (always-expanded for now — auto-collapse can
/// come later) and an `IndexedStack` of TV-variant section screens on
/// the right. The phone shell `MainNavigationScreen` is unchanged.
///
/// Layout intentionally avoids the Row-of-equal-Expanded-children
/// pattern that triggered Flutter focus-traversal bug #115550 in the
/// previous Fire TV pass — the side rail is a Column of differently-
/// sized rows (icon + label), and the content area is a single child.
class TvMainNavigationScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;

  const TvMainNavigationScreen({super.key, required this.audioPlayerService});

  @override
  State<TvMainNavigationScreen> createState() => _TvMainNavigationScreenState();
}

class _TvMainNavigationScreenState extends State<TvMainNavigationScreen> {
  int _selectedIndex = 0;
  late final List<Widget> _screens;

  final ApiService _apiService = ApiService();
  bool _isServerOnline = true;
  int _consecutiveHealthFailures = 0;
  Timer? _healthCheckTimer;
  static const _failuresBeforeBanner = 2;

  UpdateInfo? _updateInfo;

  @override
  void initState() {
    super.initState();
    _screens = [
      TvDashboardScreen(audioPlayerService: widget.audioPlayerService),
      TvLibraryScreen(audioPlayerService: widget.audioPlayerService),
      const _TvComingSoonScreen(
        label: 'Search',
        sublabel: 'Voice search + Fire TV remote app keyboard',
      ),
      const _TvComingSoonScreen(
        label: 'Settings',
        sublabel: 'TV-oriented settings — coming soon',
      ),
    ];

    _checkServerHealth();
    _healthCheckTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkServerHealth(),
    );
    _checkForUpdate();
  }

  @override
  void dispose() {
    _healthCheckTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkServerHealth() async {
    final isOnline = await _apiService.checkServerHealth();
    if (!mounted) return;

    if (isOnline) {
      if (!_isServerOnline || _consecutiveHealthFailures != 0) {
        setState(() {
          _isServerOnline = true;
          _consecutiveHealthFailures = 0;
        });
      }
      return;
    }

    final newFailures = _consecutiveHealthFailures + 1;
    if (newFailures >= _failuresBeforeBanner && _isServerOnline) {
      setState(() {
        _consecutiveHealthFailures = newFailures;
        _isServerOnline = false;
      });
    } else {
      setState(() {
        _consecutiveHealthFailures = newFailures;
      });
    }
  }

  Future<void> _checkForUpdate() async {
    final info = await UpdateService.checkForUpdate();
    if (mounted && info != null) {
      setState(() => _updateInfo = info);
    }
  }

  void _onSelect(int index) {
    if (index == _selectedIndex) return;
    setState(() => _selectedIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            if (!_isServerOnline) _buildHealthBanner(),
            if (_updateInfo != null) UpdateBanner(info: _updateInfo!),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _TvSideRail(
                    selectedIndex: _selectedIndex,
                    onSelect: _onSelect,
                  ),
                  Expanded(
                    child: IndexedStack(
                      index: _selectedIndex,
                      children: _screens,
                    ),
                  ),
                ],
              ),
            ),
            MiniPlayer(audioPlayerService: widget.audioPlayerService),
          ],
        ),
      ),
    );
  }

  Widget _buildHealthBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      color: const Color(0xFFE65100),
      child: const Row(
        children: [
          Icon(Icons.cloud_off, color: Colors.white, size: 22),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Server unreachable. Check your connection.',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ],
      ),
    );
  }
}

class _TvSideRail extends StatelessWidget {
  final int selectedIndex;
  final void Function(int) onSelect;

  const _TvSideRail({required this.selectedIndex, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    const items = <(IconData, String)>[
      (Icons.home, 'Home'),
      (Icons.library_music, 'Library'),
      (Icons.search, 'Search'),
      (Icons.settings, 'Settings'),
    ];

    return Container(
      width: 260,
      decoration: const BoxDecoration(
        color: Color(0xFF0d1b2a),
        border: Border(
          right: BorderSide(color: Color(0x1AFFFFFF), width: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
            child: Row(
              children: [
                Image.asset(
                  'assets/images/nasradio_logo.png',
                  width: 44,
                  height: 44,
                  filterQuality: FilterQuality.medium,
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'NASRadio',
                    style: TextStyle(
                      color: Color(0xFF00d4ff),
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0x1AFFFFFF)),
          const SizedBox(height: 12),
          for (var i = 0; i < items.length; i++)
            _TvRailItem(
              icon: items[i].$1,
              label: items[i].$2,
              selected: i == selectedIndex,
              onTap: () => onSelect(i),
            ),
        ],
      ),
    );
  }
}

class _TvRailItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _TvRailItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        selected ? const Color(0xFF00d4ff) : Colors.white.withOpacity(0.7);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: TvFocusable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(
            color: selected
                ? const Color(0xFF00d4ff).withOpacity(0.18)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(icon, color: color, size: 26),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 17,
                    fontWeight:
                        selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TvComingSoonScreen extends StatelessWidget {
  final String label;
  final String sublabel;

  const _TvComingSoonScreen({required this.label, required this.sublabel});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.construction,
            color: Colors.white24,
            size: 96,
          ),
          const SizedBox(height: 28),
          Text(
            '$label coming soon',
            style: const TextStyle(
              color: Colors.white60,
              fontSize: 30,
              fontWeight: FontWeight.w300,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            sublabel,
            style: const TextStyle(
              color: Colors.white24,
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }
}
