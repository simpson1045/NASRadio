import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import '../widgets/mini_player.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

/// Import a custom .m3u8 / .m3u playlist file. Tracks are matched against the
/// library exactly like the Spotify import; unmatched tracks become "missing"
/// entries that can be linked manually from the playlist detail screen.
class M3u8ImportDialog extends StatefulWidget {
  final VoidCallback onImportComplete;
  final AudioPlayerService audioService;

  const M3u8ImportDialog({
    super.key,
    required this.onImportComplete,
    required this.audioService,
  });

  @override
  State<M3u8ImportDialog> createState() => _M3u8ImportDialogState();
}

class _M3u8ImportDialogState extends State<M3u8ImportDialog> {
  final ApiService _apiService = ApiService();

  String? _fileContent;
  String? _fileName;

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

    _socket!.on('m3u8_import_progress', (data) {
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
    super.dispose();
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['m3u8', 'm3u'],
        withData: true,
      );

      if (result != null && result.files.single.bytes != null) {
        setState(() {
          _fileName = result.files.single.name;
          _fileContent = utf8.decode(
            result.files.single.bytes!,
            allowMalformed: true,
          );
          _error = null;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Could not read file: $e';
      });
    }
  }

  Future<void> _import() async {
    if (_fileContent == null) {
      setState(() {
        _error = 'Please choose a .m3u8 file first';
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
      final result = await _apiService.importM3u8Playlist(
        _fileContent!,
        filename: _fileName,
        createPlaylist: _createNew,
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
        String errorMessage = e.toString().replaceAll('Exception: ', '');
        setState(() {
          _error = errorMessage;
          _isImporting = false;
        });
      }
    }
  }

  Future<void> _cancelImport() async {
    try {
      await _apiService.cancelSpotifyImport(); // shared cancel flag on backend
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
          Icon(Icons.upload_file, color: Color(0xFF00d4ff)),
          SizedBox(width: 8),
          Text('Import from File'),
        ],
      ),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // File picker
              if (_importResult == null) ...[
                const Text(
                  'Choose an .m3u8 / .m3u playlist file. Each track is matched '
                  'against your library; anything not found is added as a '
                  'missing track you can link later.',
                  style: TextStyle(fontSize: 14, color: Colors.grey),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _isImporting ? null : _pickFile,
                  icon: const Icon(Icons.folder_open),
                  label: Text(_fileName ?? 'Choose file...'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF00d4ff),
                    side: const BorderSide(color: Color(0xFF00d4ff)),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Create new vs Update existing
                RadioListTile<bool>(
                  title: const Text('Create new playlist'),
                  subtitle: const Text(
                    'Uses the playlist name from the file',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  value: true,
                  groupValue: _createNew,
                  onChanged: _isImporting
                      ? null
                      : (value) => setState(() => _createNew = value!),
                ),
                RadioListTile<bool>(
                  title: const Text('Update existing playlist'),
                  value: false,
                  groupValue: _createNew,
                  onChanged: _isImporting
                      ? null
                      : (value) => setState(() => _createNew = value!),
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
                        : (value) =>
                              setState(() => _selectedPlaylistId = value),
                  ),
                  const SizedBox(height: 16),
                  CheckboxListTile(
                    title: const Text('Skip songs already in playlist'),
                    subtitle: const Text(
                      'Only add songs that aren\'t already in this playlist',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    value: _skipExisting,
                    onChanged: _isImporting
                        ? null
                        : (value) =>
                              setState(() => _skipExisting = value ?? true),
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
                        const Text('Reading playlist file...'),
                      ],
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
          child: Row(
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
                          : '$matchedCount/$totalTracks songs matched (${totalTracks > 0 ? ((matchedCount / totalTracks) * 100).toStringAsFixed(1) : 0}%)',
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
        ),

        // Matched Songs (collapsed by default)
        if (matched.isNotEmpty) ...[
          const SizedBox(height: 16),
          ExpansionTile(
            title: Text('✅ Matched Songs ($matchedCount)'),
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
                        song['title'] ?? '',
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        song['artist'] ?? song['spotify_artists'] ?? '',
                        style: const TextStyle(fontSize: 11),
                      ),
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
              'Not in your library yet — link them from the playlist',
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
                        song['title'] ?? '',
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        song['artists'] ?? '',
                        style: const TextStyle(fontSize: 11),
                      ),
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
}
