import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_service.dart';

/// Every image (and PDF booklet) kept in an album's folder: scans, back
/// covers, band photos. Grid of thumbnails; tap for a swipeable,
/// pinch-zoomable full-screen viewer. PDFs open in the system viewer.
class AlbumImagesScreen extends StatelessWidget {
  final int albumId;
  final String albumTitle;
  final List<Map<String, dynamic>> images;

  const AlbumImagesScreen({
    super.key,
    required this.albumId,
    required this.albumTitle,
    required this.images,
  });

  List<Map<String, dynamic>> get _pictures =>
      images.where((i) => i['kind'] != 'pdf').toList();

  Future<void> _open(BuildContext context, Map<String, dynamic> item) async {
    final path = item['path'] as String;
    if (item['kind'] == 'pdf') {
      final ok = await launchUrl(
        Uri.parse(ApiService.localImageUrl(albumId, path)),
        mode: LaunchMode.externalApplication,
      );
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't open the PDF")),
        );
      }
      return;
    }
    final pics = _pictures;
    final start = pics.indexWhere((p) => p['path'] == path);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ImageViewer(
          albumId: albumId,
          images: pics,
          initialIndex: start < 0 ? 0 : start,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0d1b2a),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0d1b2a),
        foregroundColor: Colors.white,
        title: Text('$albumTitle · Images', overflow: TextOverflow.ellipsis),
      ),
      body: GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 180,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 0.82,
        ),
        itemCount: images.length,
        itemBuilder: (context, i) {
          final item = images[i];
          final isPdf = item['kind'] == 'pdf';
          return InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _open(context, item),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: isPdf
                        ? Container(
                            color: const Color(0xFF1a2332),
                            child: const Icon(Icons.picture_as_pdf,
                                size: 48, color: Colors.redAccent),
                          )
                        : Image.network(
                            ApiService.localImageUrl(
                                albumId, item['path'] as String,
                                thumb: true),
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              color: const Color(0xFF1a2332),
                              child: const Icon(Icons.broken_image,
                                  color: Colors.grey),
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  item['path'] as String,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ImageViewer extends StatefulWidget {
  final int albumId;
  final List<Map<String, dynamic>> images;
  final int initialIndex;

  const _ImageViewer({
    required this.albumId,
    required this.images,
    required this.initialIndex,
  });

  @override
  State<_ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<_ImageViewer> {
  late final PageController _pages =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.images[_index];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          '${item['path']}  ·  ${_index + 1} / ${widget.images.length}',
          style: const TextStyle(fontSize: 14),
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: PageView.builder(
        controller: _pages,
        itemCount: widget.images.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (context, i) => InteractiveViewer(
          minScale: 1,
          maxScale: 6,
          child: Center(
            child: Image.network(
              ApiService.localImageUrl(
                  widget.albumId, widget.images[i]['path'] as String),
              fit: BoxFit.contain,
              loadingBuilder: (context, child, progress) => progress == null
                  ? child
                  : const Center(child: CircularProgressIndicator()),
              errorBuilder: (_, __, ___) => const Icon(Icons.broken_image,
                  color: Colors.grey, size: 64),
            ),
          ),
        ),
      ),
    );
  }
}
