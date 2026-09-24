import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../services/api_service.dart';

class ArtistImagePickerDialog extends StatefulWidget {
  final int artistId;
  final String artistName;

  const ArtistImagePickerDialog({
    super.key,
    required this.artistId,
    required this.artistName,
  });

  @override
  State<ArtistImagePickerDialog> createState() =>
      _ArtistImagePickerDialogState();
}

class _ArtistImagePickerDialogState extends State<ArtistImagePickerDialog> {
  final ApiService _apiService = ApiService();

  List<dynamic> _options = [];
  bool _isLoading = true;
  bool _isSaving = false;
  String? _error;
  int? _selectedIndex;
  final Set<int> _failedImages = {};

  @override
  void initState() {
    super.initState();
    _searchImages();
  }

  Future<void> _searchImages() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final result = await _apiService.searchArtistImages(widget.artistId);
      setState(() {
        _options = result['options'] ?? [];
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _uploadImage() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );

      if (result != null && result.files.single.bytes != null) {
        setState(() {
          _isSaving = true;
        });

        final bytes = result.files.single.bytes!;
        final filename = result.files.single.name;

        await _apiService.uploadArtistImage(
          widget.artistId,
          bytes,
          filename,
        );

        if (mounted) {
          Navigator.of(context).pop(true);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Artist image uploaded successfully!'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      setState(() {
        _isSaving = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error uploading: $e')));
      }
    }
  }

  Future<void> _saveSelection() async {
    if (_selectedIndex == null) return;

    final imageUrl = _options[_selectedIndex!]['url'];

    setState(() {
      _isSaving = true;
    });

    try {
      await _apiService.selectArtistImage(widget.artistId, imageUrl);

      if (mounted) {
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Artist image saved successfully!'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      setState(() {
        _isSaving = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving image: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Color _getSourceColor(String source) {
    switch (source) {
      case 'Spotify':
        return const Color(0xFF1DB954);
      case 'Fanart.tv':
        return const Color(0xFF00BFFF);
      case 'Last.fm':
        return const Color(0xFFD51007);
      default:
        return Colors.grey;
    }
  }

  void _showEnlargedImage(String imageUrl, String? title) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Stack(
          alignment: Alignment.center,
          children: [
            GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.9,
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.5),
                      blurRadius: 20,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    imageUrl,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) {
                      return Container(
                        width: 300,
                        height: 300,
                        color: const Color(0xFF1a2332),
                        child: const Icon(
                          Icons.broken_image,
                          size: 64,
                          color: Colors.grey,
                        ),
                      );
                    },
                    loadingBuilder: (context, child, loadingProgress) {
                      if (loadingProgress == null) return child;
                      return Container(
                        width: 300,
                        height: 300,
                        color: const Color(0xFF1a2332),
                        child: const Center(child: CircularProgressIndicator()),
                      );
                    },
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, color: Colors.white),
                style: IconButton.styleFrom(backgroundColor: Colors.black54),
              ),
            ),
            if (title != null)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: const BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.vertical(
                      bottom: Radius.circular(8),
                    ),
                  ),
                  child: Text(
                    title,
                    style: const TextStyle(color: Colors.white),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageTile(
    Map<String, dynamic> option,
    int index,
    bool isSelected,
  ) {
    final source = option['source'] ?? 'Unknown';
    final type = option['type'] ?? '';
    final url = option['url'] ?? '';
    final isFailed = _failedImages.contains(index);

    if (isFailed) return const SizedBox.shrink();

    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedIndex = index;
        });
      },
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: isSelected ? const Color(0xFF00d4ff) : Colors.grey.shade700,
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(5),
                    ),
                    child: Image.network(
                      url,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        if (!_failedImages.contains(index)) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) {
                              setState(() {
                                _failedImages.add(index);
                              });
                            }
                          });
                        }
                        return Container(
                          color: const Color(0xFF1a2332),
                          child: const Icon(
                            Icons.broken_image,
                            size: 32,
                            color: Colors.grey,
                          ),
                        );
                      },
                      loadingBuilder: (context, child, loadingProgress) {
                        if (loadingProgress == null) return child;
                        return Container(
                          color: const Color(0xFF1a2332),
                          child: const Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        );
                      },
                    ),
                  ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: GestureDetector(
                      onTap: () => _showEnlargedImage(url, '$source - $type'),
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Icon(
                          Icons.zoom_in,
                          size: 16,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.all(6),
              decoration: const BoxDecoration(
                color: Color(0xFF1a2332),
                borderRadius:
                    BorderRadius.vertical(bottom: Radius.circular(5)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: _getSourceColor(source).withOpacity(0.2),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      source,
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: _getSourceColor(source),
                      ),
                    ),
                  ),
                  if (type.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      type,
                      style: const TextStyle(fontSize: 8, color: Colors.grey),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 600;
    final dialogWidth = isMobile ? screenWidth * 0.9 : 550.0;
    final gridColumns = isMobile ? 2 : 3;

    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Choose Artist Image'),
          const SizedBox(height: 4),
          Text(
            widget.artistName,
            style: const TextStyle(
              fontSize: 14,
              color: Colors.grey,
              fontWeight: FontWeight.normal,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: dialogWidth,
        height: MediaQuery.of(context).size.height * 0.7,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Upload Button
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _isSaving ? null : _uploadImage,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Upload Custom Image'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF00d4ff),
                    side: const BorderSide(color: Color(0xFF00d4ff)),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 8),
              // Search Results Header
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Available Images',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF00d4ff),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // Search Results Grid
              _isLoading
                  ? const SizedBox(
                      height: 200,
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : _error != null
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text('Error: $_error'),
                              const SizedBox(height: 16),
                              ElevatedButton(
                                onPressed: _searchImages,
                                child: const Text('Retry'),
                              ),
                            ],
                          ),
                        )
                      : _options.isEmpty
                          ? const Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.image_not_supported,
                                    size: 48,
                                    color: Colors.grey,
                                  ),
                                  SizedBox(height: 8),
                                  Text(
                                    'No images found',
                                    style: TextStyle(
                                      color: Colors.grey,
                                      fontSize: 12,
                                    ),
                                  ),
                                  Text(
                                    'Try uploading a custom image',
                                    style: TextStyle(
                                      color: Colors.grey,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : GridView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: gridColumns,
                                crossAxisSpacing: 8,
                                mainAxisSpacing: 8,
                                childAspectRatio: 0.75,
                              ),
                              itemCount: _options.length,
                              itemBuilder: (context, index) {
                                final isSelected = _selectedIndex == index;
                                return _buildImageTile(
                                  _options[index],
                                  index,
                                  isSelected,
                                );
                              },
                            ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed:
              _selectedIndex != null && !_isSaving ? _saveSelection : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF00d4ff),
            foregroundColor: Colors.black,
          ),
          child: _isSaving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.black,
                  ),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
