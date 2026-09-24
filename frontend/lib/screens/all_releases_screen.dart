import 'package:flutter/material.dart';
import 'dart:io' show Platform;
import '../services/audio_player_service.dart';
import 'release_preview_screen.dart';
import 'package:cached_network_image/cached_network_image.dart';

class AllReleasesScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;
  final List<Map<String, dynamic>> upcomingReleases;
  final List<Map<String, dynamic>> recentReleases;
  final int initialTab;

  const AllReleasesScreen({
    super.key,
    required this.audioPlayerService,
    required this.upcomingReleases,
    required this.recentReleases,
    this.initialTab = 0,
  });

  @override
  State<AllReleasesScreen> createState() => _AllReleasesScreenState();
}

class _AllReleasesScreenState extends State<AllReleasesScreen> {
  late int _selectedTab;

  @override
  void initState() {
    super.initState();
    _selectedTab = widget.initialTab;
  }

  List<Map<String, dynamic>> get _currentReleases =>
      _selectedTab == 0 ? widget.upcomingReleases : widget.recentReleases;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0a1929),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0a1929),
        title: const Text(
          'Releases',
          style: TextStyle(
            color: Color(0xFF00d4ff),
            fontWeight: FontWeight.bold,
          ),
        ),
        iconTheme: const IconThemeData(color: Color(0xFF00d4ff)),
      ),
      body: Column(
        children: [
          _buildTabToggle(),
          const SizedBox(height: 12),
          Expanded(
            child: _currentReleases.isEmpty
                ? Center(
                    child: Text(
                      _selectedTab == 0
                          ? 'No upcoming releases'
                          : 'No recent releases',
                      style: const TextStyle(color: Colors.grey, fontSize: 16),
                    ),
                  )
                : _buildGrid(),
          ),
        ],
      ),
    );
  }

  Widget _buildTabToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1a2332),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            _buildTab('Coming Soon', 0),
            _buildTab('Recently Released', 1),
          ],
        ),
      ),
    );
  }

  Widget _buildTab(String label, int index) {
    final isSelected = _selectedTab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _selectedTab = index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFF00d4ff) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isSelected ? const Color(0xFF0a1929) : Colors.grey,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGrid() {
    final isDesktop = !Platform.isAndroid && !Platform.isIOS;
    final crossAxisCount = isDesktop ? 5 : 3;

    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.7,
      ),
      itemCount: _currentReleases.length,
      itemBuilder: (context, index) {
        final release = _currentReleases[index];
        return _buildReleaseCard(release);
      },
    );
  }

  String _formatReleaseDate(String dateStr) {
    if (dateStr.isEmpty) return '';
    try {
      final parts = dateStr.split('-');
      if (parts.length == 3) {
        const months = [
          '',
          'Jan',
          'Feb',
          'Mar',
          'Apr',
          'May',
          'Jun',
          'Jul',
          'Aug',
          'Sep',
          'Oct',
          'Nov',
          'Dec',
        ];
        final month = int.parse(parts[1]);
        final day = int.parse(parts[2]);
        final year = parts[0];
        return '${months[month]} $day, $year';
      }
      return dateStr;
    } catch (_) {
      return dateStr;
    }
  }

  Widget _buildReleaseCard(Map<String, dynamic> release) {
    final mbid = release['mbid'] ?? '';
    final releaseDate = release['release_date'] ?? '';
    final inLibrary = release['in_library'] == true;
    final artworkUrl = mbid.isNotEmpty
        ? 'https://coverartarchive.org/release-group/$mbid/front-250'
        : '';

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ReleasePreviewScreen(
              audioPlayerService: widget.audioPlayerService,
              release: release,
            ),
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: artworkUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: artworkUrl,
                          width: double.infinity,
                          height: double.infinity,
                          fit: BoxFit.cover,
                          placeholder: (context, url) => Container(
                            color: const Color(0xFF1a2332),
                            child: const Icon(
                              Icons.album,
                              color: Color(0xFF00d4ff),
                              size: 40,
                            ),
                          ),
                          errorWidget: (context, url, error) => Container(
                            color: const Color(0xFF1a2332),
                            child: const Icon(
                              Icons.album,
                              color: Color(0xFF00d4ff),
                              size: 40,
                            ),
                          ),
                        )
                      : Container(
                          color: const Color(0xFF1a2332),
                          child: const Icon(
                            Icons.album,
                            color: Color(0xFF00d4ff),
                            size: 40,
                          ),
                        ),
                ),
                if (inLibrary)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.green.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'IN LIBRARY',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            release['release_title'] ?? 'Unknown',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
          ),
          Text(
            '${release['artist_name'] ?? 'Unknown'} · ${release['release_type'] ?? ''} · ${_formatReleaseDate(releaseDate)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.grey, fontSize: 10),
          ),
        ],
      ),
    );
  }
}
