import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import '../widgets/mini_player.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

class SpotifyImportDialog extends StatefulWidget {
  final VoidCallback onImportComplete;
  final AudioPlayerService audioService;

  const SpotifyImportDialog({
    super.key,
    required this.onImportComplete,
    required this.audioService,
  });

  @override
  State<SpotifyImportDialog> createState() => _SpotifyImportDialogState();
}

class _SpotifyImportDialogState extends State<SpotifyImportDialog> {
  final ApiService _apiService = ApiService();
  final TextEditingController _urlController = TextEditingController();

  bool _isImporting = false;
  bool _createNew = true;
  bool _skipExisting = true;
  int? _selectedPlaylistId;
  List<Map<String, dynamic>> _existingPlaylists = [];
  Map<String, dynamic>? _importResult;
  String? _error;

  io.Socket? _socket;
  int _progressCurrent = 0;
  int _progressTotal = 0;
  String _progressMessage = 'Importing playlist...';
  int _matchedCount = 0;
  int _missingCount = 0;

  @override
  void initState() {
    super.initState();
    _loadPlaylists();
    _connectSocket();
  }

  void _connectSocket() {
    _socket = io.io(
      ApiService.baseHost,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .build(),
    );

    _socket!.on('spotify_import_progress', (data) {
      if (!mounted) return;
      setState(() {
        _progressCurrent = data['current'] ?? 0;
        _progressTotal = data['total'] ?? 0;
        _progressMessage = data['message'] ?? 'Importing...';
        _matchedCount = data['matched'] ?? 0;
        _missingCount = data['missing'] ?? 0;
      });
    });

    _socket!.connect();
  }

  Future<void> _loadPlaylists() async {
    try {
      final playlists = await _apiService.getPlaylists();
      if (mounted) {
        setState(() {
          _existingPlaylists = playlists
              .map((p) => {'id': p.id, 'name': p.name})
              .toList();
          if (_existingPlaylists.isNotEmpty) {
            _selectedPlaylistId = _existingPlaylists[0]['id'];
          }
        });
      }
    } catch (e) {
      // Ignore errors loading playlists
    }
  }

  @override
  void dispose() {
    _socket?.disconnect();
    _socket?.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    final url = _urlController.text.trim();

    if (url.isEmpty) {
      setState(() {
        _error = 'Please enter a Spotify playlist URL';
      });
      return;
    }

    if (!_createNew && _selectedPlaylistId == null) {
      setState(() {
        _error = 'Please select a playlist to update';
      });
      return;
    }

    setState(() {
      _isImporting = true;
      _error = null;
      _importResult = null;
    });

    try {
      final result = await _apiService.importSpotifyPlaylist(
        url,
        _createNew,
        existingPlaylistId: _createNew ? null : _selectedPlaylistId,
        skipExisting: !_createNew && _skipExisting,
      );

      if (mounted) {
        setState(() {
          _importResult = result;
          _isImporting = false;
        });
      }
    } catch (e) {
      if (mounted) {
        String errorMessage = e.toString();

        // Parse common Spotify errors into friendly messages
        if (errorMessage.contains('404') ||
            errorMessage.contains('Resource not found')) {
          errorMessage =
              'Playlist not found. It may be private, deleted, or the URL may be incorrect.';
        } else if (errorMessage.contains('401') ||
            errorMessage.contains('Unauthorized')) {
          errorMessage =
              'Authentication error. Please check Spotify API credentials.';
        } else if (errorMessage.contains('403') ||
            errorMessage.contains('Forbidden')) {
          errorMessage = 'Access denied. This playlist may be private.';
        } else if (errorMessage.contains('Exception:')) {
          // Clean up generic exception wrapper
          errorMessage = errorMessage
              .replaceAll('Exception: ', '')
              .replaceAll(RegExp(r'\{.*\}'), '')
              .trim();
          if (errorMessage.contains('Failed to import playlist:')) {
            errorMessage =
                'Could not access this playlist. Please check the URL and try again.';
          }
        }

        setState(() {
          _error = errorMessage;
          _isImporting = false;
        });
      }
    }
  }

  Future<void> _cancelImport() async {
    try {
      await _apiService.cancelSpotifyImport();
      if (mounted) {
        setState(() {
          _isImporting = false;
          _error = 'Import cancelled';
        });
      }
    } catch (e) {
      // Ignore errors cancelling
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.import_export, color: Color(0xFF00d4ff)),
          SizedBox(width: 8),
          Text('Import from Spotify'),
        ],
      ),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // URL Input
              if (_importResult == null) ...[
                const Text(
                  'Paste a Spotify playlist URL or URI:',
                  style: TextStyle(fontSize: 14, color: Colors.grey),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _urlController,
                  decoration: const InputDecoration(
                    hintText: 'https://open.spotify.com/playlist/...',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.link),
                  ),
                  maxLines: 2,
                  enabled: !_isImporting,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Supported formats:\n'
                  '• https://open.spotify.com/playlist/ID\n'
                  '• spotify:playlist:ID\n'
                  '• Just the playlist ID',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 16),

                // Create new vs Update existing
                RadioListTile<bool>(
                  title: const Text('Create new playlist'),
                  value: true,
                  groupValue: _createNew,
                  onChanged: _isImporting
                      ? null
                      : (value) {
                          setState(() {
                            _createNew = value!;
                          });
                        },
                ),
                RadioListTile<bool>(
                  title: const Text('Update existing playlist'),
                  value: false,
                  groupValue: _createNew,
                  onChanged: _isImporting
                      ? null
                      : (value) {
                          setState(() {
                            _createNew = value!;
                          });
                        },
                ),

                // Playlist dropdown (only when updating)
                if (!_createNew) ...[
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int>(
                    initialValue: _selectedPlaylistId,
                    decoration: const InputDecoration(
                      labelText: 'Select playlist',
                      border: OutlineInputBorder(),
                    ),
                    items: _existingPlaylists.map((playlist) {
                      return DropdownMenuItem<int>(
                        value: playlist['id'],
                        child: Text(playlist['name']),
                      );
                    }).toList(),
                    onChanged: _isImporting
                        ? null
                        : (value) {
                            setState(() {
                              _selectedPlaylistId = value;
                            });
                          },
                  ),
                  const SizedBox(height: 16),

                  // Skip existing checkbox (only when updating)
                  CheckboxListTile(
                    title: const Text('Skip songs already in playlist'),
                    subtitle: const Text(
                      'Only add songs that aren\'t already in this playlist',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    value: _skipExisting,
                    onChanged: _isImporting
                        ? null
                        : (value) {
                            setState(() {
                              _skipExisting = value ?? true;
                            });
                          },
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                ],
              ],

              // Loading State
              if (_isImporting) ...[
                const SizedBox(height: 24),
                Center(
                  child: Column(
                    children: [
                      if (_progressTotal > 0) ...[
                        LinearProgressIndicator(
                          value: _progressCurrent / _progressTotal,
                          backgroundColor: const Color(0xFF1a2332),
                          valueColor: const AlwaysStoppedAnimation<Color>(
                            Color(0xFF00d4ff),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '$_progressCurrent / $_progressTotal',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF00d4ff),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _progressMessage,
                          style: const TextStyle(fontSize: 13),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '✅ $_matchedCount matched  •  ❌ $_missingCount missing',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ] else ...[
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        const Text('Fetching playlist from Spotify...'),
                      ],
                      const SizedBox(height: 8),
                      const Text(
                        'This may take a while for large playlists',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Center(
                  child: ElevatedButton.icon(
                    onPressed: _cancelImport,
                    icon: const Icon(Icons.cancel),
                    label: const Text('Cancel Import'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                // Mini player while importing
                MiniPlayer(audioPlayerService: widget.audioService),
              ],

              // Error State
              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error, color: Colors.red),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_error!)),
                    ],
                  ),
                ),
              ],

              // Results
              if (_importResult != null) ...[_buildImportResults()],
            ],
          ),
        ),
      ),
      actions: [
        if (_importResult == null) ...[
          TextButton(
            onPressed: _isImporting ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: _isImporting ? null : _import,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00d4ff),
              foregroundColor: Colors.black,
            ),
            child: const Text('Import'),
          ),
        ] else ...[
          // Export button for missing songs
          if (_importResult!['missing_count'] > 0)
            TextButton.icon(
              onPressed: _exportMissingSongs,
              icon: const Icon(Icons.download),
              label: const Text('Export Missing Songs'),
            ),
          ElevatedButton(
            onPressed: () {
              widget.onImportComplete();
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00d4ff),
              foregroundColor: Colors.black,
            ),
            child: const Text('Done'),
          ),
        ],
      ],
    );
  }

  Widget _buildImportResults() {
    final playlistInfo = _importResult!['playlist_info'];
    final totalTracks = _importResult!['total_tracks'];
    final matchedCount = _importResult!['matched_count'];
    final missingCount = _importResult!['missing_count'];
    final skippedCount = _importResult!['skipped_count'] ?? 0;
    final mergedIntoExisting = _importResult!['merged_into_existing'] ?? false;
    final matched = _importResult!['matched'] as List;
    final missing = _importResult!['missing'] as List;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Success Header
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.green.withOpacity(0.2),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.green),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.green, size: 32),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          playlistInfo['name'],
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          mergedIntoExisting
                              ? 'Merged ${matchedCount + missingCount} new tracks into existing playlist'
                              : '$matchedCount/$totalTracks songs imported (${((matchedCount / totalTracks) * 100).toStringAsFixed(1)}%)',
                          style: const TextStyle(fontSize: 14),
                        ),
                        if (skippedCount > 0) ...[
                          const SizedBox(height: 2),
                          Text(
                            '$skippedCount tracks already in playlist (skipped)',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[400],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              if (playlistInfo['description'].toString().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  playlistInfo['description'],
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ],
          ),
        ),

        // Matched Songs (collapsed by default)
        if (matched.isNotEmpty) ...[
          const SizedBox(height: 16),
          ExpansionTile(
            title: Text('✅ Imported Songs ($matchedCount)'),
            initiallyExpanded: false,
            children: [
              Container(
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: matched.length,
                  itemBuilder: (context, index) {
                    final song = matched[index];
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.music_note, size: 16),
                      title: Text(
                        song['title'],
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${song['artists']} • ${song['album']}',
                            style: const TextStyle(fontSize: 11),
                          ),
                          if (song['mbid'] != null) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                const Icon(
                                  Icons.link,
                                  size: 10,
                                  color: Color(0xFF00d4ff),
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    'MBID: ${song['mbid']}',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: Color(0xFF00d4ff),
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                      trailing: song['mbid'] != null
                          ? IconButton(
                              icon: const Icon(
                                Icons.copy,
                                size: 16,
                                color: Color(0xFF00d4ff),
                              ),
                              tooltip: 'Copy MBID',
                              onPressed: () {
                                Clipboard.setData(
                                  ClipboardData(text: song['mbid']),
                                );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('MBID copied to clipboard'),
                                    duration: Duration(seconds: 1),
                                  ),
                                );
                              },
                            )
                          : null,
                    );
                  },
                ),
              ),
            ],
          ),
        ],

        // Missing Songs (expanded if any exist)
        if (missing.isNotEmpty) ...[
          const SizedBox(height: 16),
          ExpansionTile(
            title: Text(
              '❌ Missing Songs ($missingCount)',
              style: const TextStyle(color: Colors.orange),
            ),
            subtitle: const Text(
              'Add these to Lidarr to complete your playlist',
              style: TextStyle(fontSize: 12),
            ),
            initiallyExpanded: true,
            children: [
              Container(
                constraints: const BoxConstraints(maxHeight: 300),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: missing.length,
                  itemBuilder: (context, index) {
                    final song = missing[index];
                    return ListTile(
                      dense: true,
                      leading: const Icon(
                        Icons.warning,
                        size: 16,
                        color: Colors.orange,
                      ),
                      title: Text(
                        song['title'],
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${song['artists']} • ${song['album']}',
                            style: const TextStyle(fontSize: 11),
                          ),
                          if (song['mbid'] != null) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                const Icon(
                                  Icons.link,
                                  size: 10,
                                  color: Color(0xFF00d4ff),
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    'MBID: ${song['mbid']}',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: Color(0xFF00d4ff),
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                      trailing: song['mbid'] != null
                          ? IconButton(
                              icon: const Icon(
                                Icons.copy,
                                size: 16,
                                color: Color(0xFF00d4ff),
                              ),
                              tooltip: 'Copy MBID',
                              onPressed: () {
                                Clipboard.setData(
                                  ClipboardData(text: song['mbid']),
                                );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('MBID copied to clipboard'),
                                    duration: Duration(seconds: 1),
                                  ),
                                );
                              },
                            )
                          : null,
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Future<void> _exportMissingSongs() async {
    final missing = _importResult!['missing'] as List;
    final playlistName = _importResult!['playlist_info']['name'];

    // Build the text content
    final StringBuffer buffer = StringBuffer();
    buffer.writeln('Missing Songs from "$playlistName"');
    buffer.writeln('=' * 60);
    buffer.writeln('Total missing: ${missing.length}');
    buffer.writeln(
      'Songs with MBIDs: ${missing.where((s) => s['mbid'] != null).length}',
    );
    buffer.writeln('');
    buffer.writeln('Format: Title | Artist | Album | MBID');
    buffer.writeln('=' * 60);
    buffer.writeln('');

    for (final song in missing) {
      buffer.writeln(
        '${song['title']} | ${song['artists']} | ${song['album']} | ${song['mbid'] ?? 'No MBID'}',
      );
    }

    // Copy to clipboard
    await Clipboard.setData(ClipboardData(text: buffer.toString()));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${missing.length} missing songs copied to clipboard! Paste into a text file.',
          ),
          duration: const Duration(seconds: 3),
          action: SnackBarAction(label: 'OK', onPressed: () {}),
        ),
      );
    }
  }
}
