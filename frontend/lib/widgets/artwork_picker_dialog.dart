import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../services/api_service.dart';

class ArtworkPickerDialog extends StatefulWidget {
  final int albumId;
  final String albumTitle;
  final String artistName;
  final List<Map<String, dynamic>> localImages;

  const ArtworkPickerDialog({
    super.key,
    required this.albumId,
    required this.albumTitle,
    required this.artistName,
    this.localImages = const [],
  });

  @override
  State<ArtworkPickerDialog> createState() => _ArtworkPickerDialogState();
}

class _ArtworkPickerDialogState extends State<ArtworkPickerDialog> {
  final ApiService _apiService = ApiService();
  final TextEditingController _mbidController = TextEditingController();

  List<dynamic> _options = [];
  bool _isLoading = true;
  bool _isSaving = false;
  bool _isLookingUpMbid = false;
  String? _error;
  int? _selectedIndex;
  final Set<String> _failedImages = {};

  // MBID lookup can return single result or multiple releases
  Map<String, dynamic>? _mbidSingleResult;
  List<dynamic>? _mbidReleases;
  int? _selectedMbidIndex;

  // Local image selection
  int? _selectedLocalIndex;

  @override
  void initState() {
    super.initState();
    _searchArtwork();
  }

  @override
  void dispose() {
    _mbidController.dispose();
    super.dispose();
  }

  Future<void> _searchArtwork() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final result = await _apiService.searchArtwork(widget.albumId);
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

  Future<void> _lookupMbid() async {
    final mbid = _mbidController.text.trim();
    if (mbid.isEmpty) return;

    setState(() {
      _isLookingUpMbid = true;
      _mbidSingleResult = null;
      _mbidReleases = null;
      _selectedMbidIndex = null;
    });

    try {
      final result = await _apiService.getArtworkByMbid(mbid);
      setState(() {
        if (result['is_single'] == true) {
          // Single release result
          _mbidSingleResult = result;
          _mbidReleases = null;
        } else {
          // Multiple releases from release-group
          _mbidSingleResult = null;
          _mbidReleases = result['releases'];
          if (_mbidReleases != null && _mbidReleases!.isNotEmpty) {
            _selectedMbidIndex = 0; // Select first by default
          }
        }
        _isLookingUpMbid = false;
        _selectedIndex = null; // Deselect grid items
      });
    } catch (e) {
      setState(() {
        _isLookingUpMbid = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('MBID not found: $e')));
      }
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

        await _apiService.uploadArtwork(widget.albumId, bytes, filename);

        if (mounted) {
          Navigator.of(context).pop(true);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Artwork uploaded successfully!'),
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
    // Handle local image selection
    if (_selectedLocalIndex != null) {
      await _saveLocalImage();
      return;
    }

    String? releaseId;

    if (_mbidSingleResult != null) {
      releaseId = _mbidSingleResult!['release_id'];
    } else if (_mbidReleases != null && _selectedMbidIndex != null) {
      releaseId = _mbidReleases![_selectedMbidIndex!]['release_id'];
    } else if (_selectedIndex != null) {
      releaseId = _options[_selectedIndex!]['release_id'];
    }

    if (releaseId == null) return;

    setState(() {
      _isSaving = true;
    });

    try {
      await _apiService.selectArtwork(widget.albumId, releaseId);

      if (mounted) {
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Artwork saved successfully!'),
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
            content: Text('Error saving artwork: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Color _getConfidenceColor(int confidence) {
    if (confidence >= 80) return Colors.green;
    if (confidence >= 50) return Colors.orange;
    return Colors.red;
  }

  String _getConfidenceLabel(int confidence) {
    if (confidence >= 80) return 'High match';
    if (confidence >= 50) return 'Partial match';
    return 'Low match';
  }

  bool get _hasSelection {
    return _selectedIndex != null ||
        _mbidSingleResult != null ||
        (_mbidReleases != null && _selectedMbidIndex != null) ||
        _selectedLocalIndex != null;
  }

  Future<void> _saveLocalImage() async {
    if (_selectedLocalIndex == null) return;

    final localImage = widget.localImages[_selectedLocalIndex!];
    final filename = localImage['filename'] as String;

    setState(() {
      _isSaving = true;
    });

    try {
      final response = await _apiService.setLocalArtwork(
        widget.albumId,
        filename,
      );

      if (mounted) {
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Artwork saved successfully!'),
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
            content: Text('Error saving artwork: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Widget _buildReleaseInfo(
    Map<String, dynamic> release, {
    bool showConfidence = true,
  }) {
    final format = release['format'];
    final countryDate = release['country_date'];
    final confidence = release['confidence'] as int? ?? 100;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          release['title'] ?? 'Unknown',
          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          '${release['artist'] ?? 'Unknown'} ${release['year'] != null ? '(${release['year']})' : ''}',
          style: const TextStyle(fontSize: 9, color: Colors.grey),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (format != null || countryDate != null) ...[
          const SizedBox(height: 2),
          Text(
            [format, countryDate].where((s) => s != null).join(' • '),
            style: const TextStyle(fontSize: 8, color: Colors.grey),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        const SizedBox(height: 2),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            color: _getConfidenceColor(confidence).withOpacity(0.2),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(
            showConfidence ? _getConfidenceLabel(confidence) : 'MBID Lookup',
            style: TextStyle(
              fontSize: 8,
              color: _getConfidenceColor(confidence),
            ),
          ),
        ),
      ],
    );
  }

  void _showEnlargedImage(String imageUrl, String? title) {
    // Convert Cover Art Archive thumbnails to appropriate size
    // Use front-500 on mobile, full size on desktop
    final isMobile = MediaQuery.of(context).size.width < 600;
    String fullSizeUrl = imageUrl;
    if (imageUrl.contains('coverartarchive.org')) {
      final targetSize = isMobile ? '/front-500' : '/front';
      fullSizeUrl = imageUrl
          .replaceAll('/front-250', targetSize)
          .replaceAll('/front-500', targetSize)
          .replaceAll('/front-1200', targetSize);
    }

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
                    fullSizeUrl,
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
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: const BorderRadius.vertical(
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

  Widget _buildArtworkTile(
    Map<String, dynamic> option,
    bool isSelected,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
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
                      option['artwork_url'],
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        // Mark this image as failed and trigger rebuild
                        final releaseId = option['release_id'] as String?;
                        if (releaseId != null &&
                            !_failedImages.contains(releaseId)) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) {
                              setState(() {
                                _failedImages.add(releaseId);
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
                      onTap: () => _showEnlargedImage(
                        option['artwork_url'],
                        '${option['title']} - ${option['artist']}',
                      ),
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
                borderRadius: BorderRadius.vertical(bottom: Radius.circular(5)),
              ),
              child: _buildReleaseInfo(option),
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
          const Text('Select Artwork'),
          const SizedBox(height: 4),
          Text(
            '${widget.artistName} - ${widget.albumTitle}',
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
        height: MediaQuery.of(context).size.height * 0.75,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Local Images Section (from imported folder)
              if (widget.localImages.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1a2332),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.green.withOpacity(0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.folder,
                            color: Colors.green,
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'Local Images',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.green,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '${widget.localImages.length} found',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.grey[500],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 100,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: widget.localImages.length,
                          itemBuilder: (context, index) {
                            final image = widget.localImages[index];
                            final isSelected = _selectedLocalIndex == index;
                            final imageUrl =
                                '${ApiService.baseUrl}/album/${widget.albumId}/local-image/${image['filename']}';

                            return Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: GestureDetector(
                                onTap: () {
                                  setState(() {
                                    _selectedLocalIndex = index;
                                    _selectedIndex = null;
                                    _mbidSingleResult = null;
                                    _mbidReleases = null;
                                    _selectedMbidIndex = null;
                                  });
                                },
                                child: Container(
                                  width: 100,
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: isSelected
                                          ? Colors.green
                                          : Colors.grey.shade700,
                                      width: isSelected ? 2 : 1,
                                    ),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Expanded(
                                        child: Stack(
                                          fit: StackFit.expand,
                                          children: [
                                            ClipRRect(
                                              borderRadius:
                                                  const BorderRadius.vertical(
                                                    top: Radius.circular(5),
                                                  ),
                                              child: Image.network(
                                                imageUrl,
                                                fit: BoxFit.cover,
                                                errorBuilder:
                                                    (ctx, err, stack) {
                                                      return Container(
                                                        color: const Color(
                                                          0xFF0d1b2a,
                                                        ),
                                                        child: const Icon(
                                                          Icons.broken_image,
                                                          color: Colors.grey,
                                                        ),
                                                      );
                                                    },
                                              ),
                                            ),
                                            Positioned(
                                              top: 4,
                                              right: 4,
                                              child: GestureDetector(
                                                onTap: () => _showEnlargedImage(
                                                  imageUrl,
                                                  image['filename'],
                                                ),
                                                child: Container(
                                                  padding: const EdgeInsets.all(
                                                    4,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: Colors.black54,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          4,
                                                        ),
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
                                        padding: const EdgeInsets.all(4),
                                        decoration: const BoxDecoration(
                                          color: Color(0xFF0d1b2a),
                                          borderRadius: BorderRadius.vertical(
                                            bottom: Radius.circular(5),
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              image['filename'] ?? '',
                                              style: const TextStyle(
                                                fontSize: 8,
                                                fontWeight: FontWeight.bold,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            Text(
                                              image['size_formatted'] ?? '',
                                              style: TextStyle(
                                                fontSize: 8,
                                                color: Colors.grey[500],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
              // MBID Lookup Section
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1a2332),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Manual MBID Lookup',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF00d4ff),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Enter a Release ID or Release Group ID',
                      style: TextStyle(fontSize: 10, color: Colors.grey),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _mbidController,
                            decoration: const InputDecoration(
                              hintText:
                                  'e.g. 12345678-1234-1234-1234-123456789012',
                              hintStyle: TextStyle(fontSize: 11),
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                            ),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: _isLookingUpMbid ? null : _lookupMbid,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00d4ff),
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                          ),
                          child: _isLookingUpMbid
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.black,
                                  ),
                                )
                              : const Text(
                                  'Lookup',
                                  style: TextStyle(fontSize: 12),
                                ),
                        ),
                      ],
                    ),
                    // Single MBID Result
                    if (_mbidSingleResult != null) ...[
                      const SizedBox(height: 12),
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _selectedIndex = null;
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: const Color(0xFF00d4ff),
                              width: 2,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: Image.network(
                                  _mbidSingleResult!['artwork_url'],
                                  width: 60,
                                  height: 60,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) {
                                    return Container(
                                      width: 60,
                                      height: 60,
                                      color: const Color(0xFF0d1b2a),
                                      child: const Icon(
                                        Icons.broken_image,
                                        color: Colors.grey,
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _mbidSingleResult!['title'],
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                    Text(
                                      '${_mbidSingleResult!['artist']} ${_mbidSingleResult!['year'] != null ? '(${_mbidSingleResult!['year']})' : ''}',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey,
                                      ),
                                    ),
                                    if (_mbidSingleResult!['format'] != null ||
                                        _mbidSingleResult!['country_date'] !=
                                            null)
                                      Text(
                                        [
                                          _mbidSingleResult!['format'],
                                          _mbidSingleResult!['country_date'],
                                        ].where((s) => s != null).join(' • '),
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: Colors.grey,
                                        ),
                                      ),
                                    const SizedBox(height: 4),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.green.withOpacity(0.2),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: const Text(
                                        'Manual MBID',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: Colors.green,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(
                                Icons.check_circle,
                                color: Color(0xFF00d4ff),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    // Multiple MBID Results (Release Group)
                    if (_mbidReleases != null && _mbidReleases!.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Found ${_mbidReleases!.length} releases in group:',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 140,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: _mbidReleases!.length,
                          itemBuilder: (context, index) {
                            final release = _mbidReleases![index];
                            final isSelected = _selectedMbidIndex == index;
                            return Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: GestureDetector(
                                onTap: () {
                                  setState(() {
                                    _selectedMbidIndex = index;
                                    _selectedIndex = null;
                                  });
                                },
                                child: Container(
                                  width: 100,
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: isSelected
                                          ? const Color(0xFF00d4ff)
                                          : Colors.grey.shade700,
                                      width: isSelected ? 2 : 1,
                                    ),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Expanded(
                                        child: ClipRRect(
                                          borderRadius:
                                              const BorderRadius.vertical(
                                                top: Radius.circular(5),
                                              ),
                                          child: Image.network(
                                            release['artwork_url'],
                                            fit: BoxFit.cover,
                                            errorBuilder: (ctx, err, stack) {
                                              return Container(
                                                color: const Color(0xFF0d1b2a),
                                                child: const Icon(
                                                  Icons.broken_image,
                                                  color: Colors.grey,
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.all(4),
                                        decoration: const BoxDecoration(
                                          color: Color(0xFF0d1b2a),
                                          borderRadius: BorderRadius.vertical(
                                            bottom: Radius.circular(5),
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            if (release['format'] != null)
                                              Text(
                                                release['format'],
                                                style: const TextStyle(
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            if (release['country_date'] != null)
                                              Text(
                                                release['country_date'],
                                                style: const TextStyle(
                                                  fontSize: 8,
                                                  color: Colors.grey,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
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
                  'Search Results',
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
                            onPressed: _searchArtwork,
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
                            'No results found',
                            style: TextStyle(color: Colors.grey, fontSize: 12),
                          ),
                          Text(
                            'Try MBID lookup or upload an image',
                            style: TextStyle(color: Colors.grey, fontSize: 11),
                          ),
                        ],
                      ),
                    )
                  : GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: gridColumns,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                        childAspectRatio: 0.65,
                      ),
                      itemCount: _options.length,
                      itemBuilder: (context, index) {
                        final option = _options[index];
                        final isSelected =
                            _selectedIndex == index &&
                            _mbidSingleResult == null &&
                            _selectedMbidIndex == null;

                        return _buildArtworkTile(option, isSelected, () {
                          setState(() {
                            _selectedIndex = index;
                            _mbidSingleResult = null;
                            _mbidReleases = null;
                            _selectedMbidIndex = null;
                          });
                        });
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
          onPressed: _hasSelection && !_isSaving ? _saveSelection : null,
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
