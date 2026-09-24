import 'package:flutter/material.dart';
import 'dart:convert';
import '../services/auth_http_client.dart';
import 'dart:async';
import 'dart:io' show Platform;
import '../services/api_service.dart';
import '../services/auth_service.dart';
import 'user_management.dart';
import 'admin_integrations_panel.dart';
import '../screens/artist_merge_screen.dart';
import '../screens/manual_merge_screen.dart';
import '../screens/album_merge_screen.dart';
import '../screens/lastfm_stats_screen.dart';
import 'package:file_picker/file_picker.dart';
import 'artwork_picker_dialog.dart';
import '../services/audio_player_service.dart';
import '../services/weather_service.dart';
import '../main.dart' show globalWeatherService;
import '../screens/exclusions_screen.dart';
import '../screens/alert_history_screen.dart';
import '../screens/duplicate_review_screen.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:audioplayers/audioplayers.dart' as audioplayers;
import 'package:url_launcher/url_launcher.dart';

class SettingsDialog extends StatefulWidget {
  final ApiService apiService;
  final VoidCallback onRescanComplete;
  final AudioPlayerService audioPlayerService;

  const SettingsDialog({
    super.key,
    required this.apiService,
    required this.onRescanComplete,
    required this.audioPlayerService,
  });

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  io.Socket? _socket;

  // Library scan state
  bool _isRescanning = false;
  String? _message;
  double _rescanProgress = 0.0;
  String? _currentOperationId;
  int _songsAdded = 0;
  int _albumsAdded = 0;
  int _artistsAdded = 0;

  // Folder scan state
  bool _isScanningFolder = false;
  String? _folderScanMessage;
  double _folderScanProgress = 0.0;
  String? _folderScanOperationId;
  String? _selectedFolderPath;
  final TextEditingController _folderPathController = TextEditingController();

  // Artwork state
  bool _isDownloadingArtwork = false;
  String? _artworkMessage;
  double _artworkProgress = 0.0;
  String? _artworkOperationId;
  bool _isUpgradingArtwork = false;
  String? _upgradeArtworkMessage;
  double _upgradeArtworkProgress = 0.0;
  String? _upgradeArtworkOperationId;

  // Artist images state
  bool _isDownloadingArtistImages = false;
  String? _artistImagesMessage;
  double _artistImagesProgress = 0.0;
  String? _artistImagesOperationId;

  // Cleanup state
  bool _isCleaningUp = false;
  String? _cleanupMessage;
  double _cleanupProgress = 0.0;
  String? _cleanupOperationId;

  // Audio Analysis state
  bool _isAnalyzing = false;
  String? _analysisMessage;
  double _analysisProgress = 0.0;
  String? _analysisEta;
  int _analyzedCount = 0;
  int _totalToAnalyze = 0;
  bool _essentiaOnline = false;
  bool _isStartingEssentia = false;
  String? _essentiaStartError;

  // Rolling buffer of recent per-song analysis results streamed from
  // the backend's `analysis_result` websocket event. Capped at 30 to
  // keep the UI snappy and memory bounded — Essentia can chew through
  // hundreds per hour on a fast machine.
  static const int _recentAnalysesMax = 30;
  final List<Map<String, dynamic>> _recentAnalyses = [];

  // Transcode state
  bool _isTranscoding = false;
  String? _transcodeMessage;
  double _transcodeProgress = 0.0;
  String? _transcodeEta;
  int _transcodedCount = 0;
  int _skippedCount = 0;
  int _failedCount = 0;
  int _cachedCount = 0;
  int _totalSongs = 0;
  bool _transcodeServiceOnline = false;
  String? _currentTranscodeSong;

  // MBID Backfill state (TEMP - remove after use)
  bool _isBackfillingMbids = false;
  String? _mbidBackfillMessage;
  double _mbidBackfillProgress = 0.0;
  String? _mbidBackfillOperationId;
  int _mbidUpdatedAlbums = 0;
  int _mbidUpdatedArtists = 0;
  int _mbidTotalAlbums = 0;
  Map<String, dynamic>? _mbidStats;

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  // Desktop sidebar index
  int _selectedSidebarIndex = 0;

  // City search state
  Timer? _searchDebounce;
  List<LocationResult> _locationResults = [];
  bool _isSearching = false;
  final TextEditingController _citySearchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 9, vsync: this);
    _checkAnalysisStatus();
    _checkTranscodeStatus();
    _loadMbidStats();
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

    _socket!.onConnect((_) {
      print('Settings socket connected');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('WebSocket connected'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }
    });

    _socket!.onConnectError((error) {
      print('Settings socket connection error: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('WebSocket error: $error'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 5),
          ),
        );
      }
    });

    _socket!.on('scan_progress', (data) {
      if (!mounted) return;

      final operationId = data['operation_id'];
      final current = data['current'] ?? 0;
      final total = data['total'] ?? 1;
      final message = data['message'] ?? '';
      final status = data['status'] ?? 'running';
      final songsAdded = data['songs_added'] ?? 0;
      final albumsAdded = data['albums_added'] ?? 0;
      final artistsAdded = data['artists_added'] ?? 0;

      // Check if this is for the current operation (library scan or folder scan)
      if (_currentOperationId == operationId) {
        setState(() {
          _rescanProgress = total > 0 ? current / total : 0.0;
          _message = '$message ($current/$total)';
          _songsAdded = songsAdded;
          _albumsAdded = albumsAdded;
          _artistsAdded = artistsAdded;

          if (status == 'complete' ||
              status == 'failed' ||
              status == 'cancelled') {
            _isRescanning = false;
            if (status == 'complete') {
              widget.onRescanComplete();
            }
          }
        });
      } else if (_folderScanOperationId == operationId) {
        setState(() {
          _folderScanProgress = total > 0 ? current / total : 0.0;
          _folderScanMessage = '$message ($current/$total)';
          _songsAdded = songsAdded;
          _albumsAdded = albumsAdded;
          _artistsAdded = artistsAdded;

          if (status == 'complete' ||
              status == 'failed' ||
              status == 'cancelled') {
            _isScanningFolder = false;
            if (status == 'complete') {
              widget.onRescanComplete();
              _showArtworkPickersForNewAlbums();
            }
          }
        });
      }
    });

    _socket!.on('cleanup_progress', (data) {
      if (!mounted) return;

      final operationId = data['operation_id'];
      final current = data['current'] ?? 0;
      final total = data['total'] ?? 1;
      final message = data['message'] ?? '';
      final status = data['status'] ?? 'running';

      if (_cleanupOperationId == operationId) {
        setState(() {
          _cleanupProgress = total > 0 ? current / total : 0.0;
          _cleanupMessage = message;

          if (status == 'complete' ||
              status == 'failed' ||
              status == 'cancelled') {
            _isCleaningUp = false;
            if (status == 'complete') {
              widget.onRescanComplete();
            }
          }
        });
      }
    });

    _socket!.on('artwork_progress', (data) {
      if (!mounted) return;

      final operationId = data['operation_id'];
      final current = data['current'] ?? 0;
      final total = data['total'] ?? 1;
      final message = data['message'] ?? '';
      final status = data['status'] ?? 'running';

      if (_artworkOperationId == operationId) {
        setState(() {
          _artworkProgress = total > 0 ? current / total : 0.0;
          _artworkMessage = '$message ($current/$total)';

          if (status == 'complete' ||
              status == 'failed' ||
              status == 'cancelled') {
            _isDownloadingArtwork = false;
            if (status == 'complete') {
              widget.onRescanComplete();
            }
          }
        });
      }
    });

    _socket!.on('artwork_upgrade_progress', (data) {
      if (!mounted) return;
      final status = data['status'] ?? 'running';
      final current = data['current'] ?? 0;
      final total = data['total'] ?? 1;
      final upgraded = data['upgraded'] ?? 0;
      final failed = data['failed'] ?? 0;
      final skipped = data['skipped'] ?? 0;
      final message = data['message'] ?? '';

      setState(() {
        _upgradeArtworkProgress = total > 0 ? current / total : 0.0;
        _upgradeArtworkMessage = '$message ($current/$total — $upgraded upgraded, $skipped skipped, $failed failed)';
        if (status == 'complete' || status == 'error' || status == 'cancelled') {
          _isUpgradingArtwork = false;
        }
      });
    });

    _socket!.on('artist_images_progress', (data) {
      if (!mounted) return;

      final operationId = data['operation_id'];
      final current = data['current'] ?? 0;
      final total = data['total'] ?? 1;
      final message = data['message'] ?? '';
      final status = data['status'] ?? 'running';

      if (_artistImagesOperationId == operationId) {
        setState(() {
          _artistImagesProgress = total > 0 ? current / total : 0.0;
          _artistImagesMessage = '$message ($current/$total)';

          if (status == 'complete' ||
              status == 'failed' ||
              status == 'cancelled') {
            _isDownloadingArtistImages = false;
            if (status == 'complete') {
              widget.onRescanComplete();
            }
          }
        });
      }
    });

    _socket!.on('analysis_progress', (data) {
      if (!mounted) return;

      final current = data['current'] ?? 0;
      final total = data['total'] ?? 1;
      final message = data['message'] ?? '';
      final status = data['status'] ?? 'running';
      final eta = data['eta'];
      final analyzed = data['analyzed'] ?? 0;

      setState(() {
        _analysisProgress = total > 0 ? current / total : 0.0;
        _analysisMessage = message;
        _analysisEta = eta;
        _analyzedCount = analyzed;

        if (status == 'complete' ||
            status == 'failed' ||
            status == 'cancelled') {
          _isAnalyzing = false;
          _analysisEta = null;
        } else {
          _isAnalyzing = true;
        }
      });
    });

    _socket!.on('analysis_result', (data) {
      if (!mounted) return;
      // Newest first; cap the list at _recentAnalysesMax so memory stays
      // bounded over long batches.
      setState(() {
        _recentAnalyses.insert(0, Map<String, dynamic>.from(data));
        if (_recentAnalyses.length > _recentAnalysesMax) {
          _recentAnalyses.removeRange(
            _recentAnalysesMax,
            _recentAnalyses.length,
          );
        }
      });
    });

    _socket!.on('transcode_progress', (data) {
      if (!mounted) return;

      final current = data['current'] ?? 0;
      final total = data['total'] ?? 1;
      final message = data['message'] ?? '';
      final status = data['status'] ?? 'running';
      final eta = data['eta'];
      final transcoded = data['transcoded'] ?? 0;
      final skipped = data['skipped'] ?? 0;
      final failed = data['failed'] ?? 0;
      final currentSong = data['current_song'] ?? '';

      setState(() {
        _transcodeProgress = total > 0 ? current / total : 0.0;
        _transcodeMessage = message;
        _transcodeEta = eta;
        _transcodedCount = transcoded;
        _skippedCount = skipped;
        _failedCount = failed;
        _currentTranscodeSong = currentSong;

        if (status == 'complete' ||
            status == 'failed' ||
            status == 'cancelled') {
          _isTranscoding = false;
          _transcodeEta = null;
          _checkTranscodeStatus(); // Refresh cached count
        } else {
          _isTranscoding = true;
        }
      });
    });

    _socket!.on('mbid_backfill_progress', (data) {
      if (!mounted) return;

      final operationId = data['operation_id'];
      if (_mbidBackfillOperationId != null &&
          operationId != _mbidBackfillOperationId) {
        return;
      }

      final current = data['current'] ?? 0;
      final total = data['total'] ?? 1;
      final message = data['message'] ?? '';
      final status = data['status'] ?? 'running';
      final updatedAlbums = data['updated_albums'] ?? 0;
      final updatedArtists = data['updated_artists'] ?? 0;

      setState(() {
        _mbidBackfillProgress = total > 0 ? current / total : 0.0;
        _mbidBackfillMessage = message;
        _mbidUpdatedAlbums = updatedAlbums;
        _mbidUpdatedArtists = updatedArtists;
        _mbidTotalAlbums = total;

        if (status == 'complete' ||
            status == 'error' ||
            status == 'cancelled') {
          _isBackfillingMbids = false;
          _loadMbidStats();
        }
      });
    });

    _socket!.connect();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _socket?.disconnect();
    _socket?.dispose();
    _folderPathController.dispose();
    _searchDebounce?.cancel();
    _citySearchController.dispose();
    super.dispose();
  }

  Future<void> _loadMbidStats() async {
    try {
      final response = await appHttpClient.get(
        Uri.parse('${ApiService.baseUrl}/mbid-stats'),
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        setState(() {
          _mbidStats = json.decode(response.body);
        });
      }
    } catch (e) {
      print('Error loading MBID stats: $e');
    }
  }

  Future<void> _startMbidBackfill() async {
    setState(() {
      _isBackfillingMbids = true;
      _mbidBackfillMessage = 'Starting MBID backfill...';
      _mbidBackfillProgress = 0.0;
      _mbidUpdatedAlbums = 0;
      _mbidUpdatedArtists = 0;
    });

    try {
      final response = await appHttpClient.post(
        Uri.parse('${ApiService.baseUrl}/backfill-mbids'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        _mbidBackfillOperationId = data['operation_id'];
      } else {
        setState(() {
          _isBackfillingMbids = false;
          _mbidBackfillMessage = 'Error starting backfill';
        });
      }
    } catch (e) {
      setState(() {
        _isBackfillingMbids = false;
        _mbidBackfillMessage = 'Error: ${e.toString()}';
      });
    }
  }

  Future<void> _cancelMbidBackfill() async {
    if (_mbidBackfillOperationId == null) return;

    try {
      await appHttpClient.post(
        Uri.parse(
          '${ApiService.baseUrl}/backfill-mbids/cancel/$_mbidBackfillOperationId',
        ),
      );
    } catch (e) {
      print('Error cancelling backfill: $e');
    }
  }

  Future<void> _checkAnalysisStatus() async {
    try {
      final response = await appHttpClient.get(
        Uri.parse('${ApiService.baseUrl}/analysis/status'),
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _essentiaOnline = data['service_online'] ?? false;
          _isAnalyzing = data['status'] == 'running';
          _analyzedCount = data['analyzed_songs'] ?? 0;
          _totalToAnalyze = data['total_songs'] ?? 0;

          if (_isAnalyzing) {
            _analysisProgress = data['total'] > 0
                ? (data['current'] ?? 0) / data['total']
                : 0.0;
            _analysisEta = data['eta'];
            _analysisMessage = 'Analyzing: ${data['current_song'] ?? ''}';
            // Websocket will handle ongoing progress updates
          }
        });
      }
    } catch (e) {
      print('Error checking analysis status: $e');
    }
  }

  Future<void> _startAnalysis() async {
    setState(() {
      _isAnalyzing = true;
      _analysisMessage = 'Starting audio analysis...';
      _analysisProgress = 0.0;
    });

    try {
      final response = await appHttpClient.post(
        Uri.parse('${ApiService.baseUrl}/analysis/start'),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode != 200) {
        final data = json.decode(response.body);
        setState(() {
          _isAnalyzing = false;
          _analysisMessage = 'Error: ${data['error'] ?? 'Failed to start'}';
        });
      }
      // Websocket will handle progress updates via 'analysis_progress' event
    } catch (e) {
      setState(() {
        _isAnalyzing = false;
        _analysisMessage = 'Error: ${e.toString()}';
      });
    }
  }

  Future<void> _cancelAnalysis() async {
    try {
      await appHttpClient.post(
        Uri.parse('${ApiService.baseUrl}/analysis/cancel'),
      );
      // Websocket will receive the cancelled status and update UI
    } catch (e) {
      print('Error cancelling analysis: $e');
    }
  }

  Future<void> _startEssentiaService() async {
    setState(() {
      _isStartingEssentia = true;
      _essentiaStartError = null;
    });

    try {
      // Long timeout: backend polls Essentia health for up to 90s after
      // spawning the launcher, plus a few seconds slack for the request
      // round-trip and any cold-start delay before the bat actually fires.
      final response = await appHttpClient
          .post(
            Uri.parse('${ApiService.baseUrl}/essentia/start'),
            headers: {'Content-Type': 'application/json'},
          )
          .timeout(const Duration(seconds: 120));

      if (!mounted) return;

      final data = json.decode(response.body);
      if (response.statusCode == 200 && data['success'] == true) {
        // Refresh status so the offline pill flips to green.
        await _checkAnalysisStatus();
      } else {
        setState(() {
          _essentiaStartError =
              data['error']?.toString() ?? 'Failed to start Essentia';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _essentiaStartError = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isStartingEssentia = false;
        });
      }
    }
  }

  Future<void> _checkTranscodeStatus() async {
    try {
      final response = await appHttpClient.get(
        Uri.parse('${ApiService.baseUrl}/transcode/status'),
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _transcodeServiceOnline = data['service_online'] ?? false;
          _cachedCount = data['cached_count'] ?? 0;
          _totalSongs = data['total_songs'] ?? 0;
          _isTranscoding = data['status'] == 'running';

          if (_isTranscoding) {
            final total = data['total'] ?? 0;
            final current = data['current'] ?? 0;
            _transcodeProgress = total > 0 ? current / total : 0.0;
            _transcodeEta = data['eta'];
            _transcodedCount = data['transcoded'] ?? 0;
            _skippedCount = data['skipped'] ?? 0;
            _failedCount = data['failed'] ?? 0;
            _currentTranscodeSong = data['current_song'] ?? '';
            _transcodeMessage = 'Transcoding: $_currentTranscodeSong';
          }
        });
      }
    } catch (e) {
      print('Error checking transcode status: $e');
    }
  }

  Future<void> _startTranscode() async {
    setState(() {
      _isTranscoding = true;
      _transcodeMessage = 'Starting batch transcode...';
      _transcodeProgress = 0.0;
    });

    try {
      final response = await appHttpClient.post(
        Uri.parse('${ApiService.baseUrl}/transcode/start'),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode != 200) {
        final data = json.decode(response.body);
        setState(() {
          _isTranscoding = false;
          _transcodeMessage = 'Error: ${data['error'] ?? 'Failed to start'}';
        });
      }
      // WebSocket will handle progress updates via 'transcode_progress' event
    } catch (e) {
      setState(() {
        _isTranscoding = false;
        _transcodeMessage = 'Error: ${e.toString()}';
      });
    }
  }

  Future<void> _cancelTranscode() async {
    try {
      await appHttpClient.post(
        Uri.parse('${ApiService.baseUrl}/transcode/cancel'),
      );
      // WebSocket will receive the cancelled status and update UI
    } catch (e) {
      print('Error cancelling transcode: $e');
    }
  }

  Future<void> _rescanLibrary() async {
    await _startScan(widget.apiService.rescanLibrary, 'full');
  }

  Future<void> _scanNewFiles() async {
    await _startScan(widget.apiService.scanNewFiles, 'incremental');
  }

  Future<void> _startScan(
    Future<Map<String, dynamic>> Function() scanFunction,
    String scanType,
  ) async {
    setState(() {
      _isRescanning = true;
      _message = 'Starting $scanType scan...';
      _rescanProgress = 0.0;
      _songsAdded = 0;
      _albumsAdded = 0;
      _artistsAdded = 0;
    });

    try {
      final response = await scanFunction();
      final operationId = response['operation_id'];
      _currentOperationId = operationId;
      // Websocket will handle progress updates via 'scan_progress' event
    } catch (e) {
      setState(() {
        _isRescanning = false;
        _message = 'Error: ${e.toString()}';
      });
    }
  }

  Future<void> _downloadArtwork() async {
    setState(() {
      _isDownloadingArtwork = true;
      _artworkMessage = 'Starting artwork download...';
      _artworkProgress = 0.0;
    });

    try {
      final response = await widget.apiService.downloadArtwork();
      final operationId = response['operation_id'];
      _artworkOperationId = operationId;
      // Websocket will handle progress updates via 'artwork_progress' event
    } catch (e) {
      setState(() {
        _isDownloadingArtwork = false;
        _artworkMessage = 'Error: ${e.toString()}';
      });
    }
  }

  Future<void> _upgradeArtwork() async {
    setState(() {
      _isUpgradingArtwork = true;
      _upgradeArtworkMessage = 'Starting full-resolution upgrade...';
      _upgradeArtworkProgress = 0.0;
    });

    try {
      final response = await appHttpClient.post(
        Uri.parse('${ApiService.baseUrl}/artwork/upgrade-all'),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        _upgradeArtworkOperationId = data['operation_id'];
      }
      // Websocket will handle progress updates via 'artwork_upgrade_progress' event
    } catch (e) {
      setState(() {
        _isUpgradingArtwork = false;
        _upgradeArtworkMessage = 'Error: ${e.toString()}';
      });
    }
  }

  Future<void> _downloadArtistImages() async {
    setState(() {
      _isDownloadingArtistImages = true;
      _artistImagesMessage = 'Starting artist image download...';
      _artistImagesProgress = 0.0;
    });

    try {
      final response = await widget.apiService.downloadArtistImages();
      final operationId = response['operation_id'];
      _artistImagesOperationId = operationId;
      // Websocket will handle progress updates via 'artist_images_progress' event
    } catch (e) {
      setState(() {
        _isDownloadingArtistImages = false;
        _artistImagesMessage = 'Error: ${e.toString()}';
      });
    }
  }

  Future<void> _cleanupMissingFiles() async {
    setState(() {
      _isCleaningUp = true;
      _cleanupMessage = 'Starting cleanup...';
      _cleanupProgress = 0.0;
    });

    try {
      final response = await appHttpClient.post(
        Uri.parse('${ApiService.baseUrl}/cleanup-missing'),
      );

      final data = json.decode(response.body);
      final operationId = data['operation_id'];
      _cleanupOperationId = operationId;
      // Websocket will handle progress updates via 'cleanup_progress' event
    } catch (e) {
      setState(() {
        _isCleaningUp = false;
        _cleanupMessage = 'Error: ${e.toString()}';
      });
    }
  }

  Future<void> _pickFolder() async {
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();

    if (selectedDirectory != null) {
      // Strip any leading \\server\share\ UNC prefix so the path is
      // relative to the music library root, regardless of whether the
      // share was mounted by hostname or IP.
      String relativePath = selectedDirectory
          .replaceFirst(RegExp(r'^\\\\[^\\]+\\[^\\]+\\?'), '')
          .replaceAll('\\', '/');

      setState(() {
        _selectedFolderPath = relativePath;
        _folderPathController.text = relativePath;
      });
    }
  }

  Future<void> _scanFolder() async {
    if (_selectedFolderPath == null || _selectedFolderPath!.isEmpty) {
      setState(() {
        _folderScanMessage = 'Please select a folder first';
      });
      return;
    }

    setState(() {
      _isScanningFolder = true;
      _folderScanMessage = 'Starting folder scan...';
      _folderScanProgress = 0.0;
      _songsAdded = 0;
      _albumsAdded = 0;
      _artistsAdded = 0;
    });

    try {
      final response = await appHttpClient.post(
        Uri.parse('${ApiService.baseUrl}/scan-folder'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'folder_path': _selectedFolderPath}),
      );

      final data = json.decode(response.body);
      final operationId = data['operation_id'];
      _folderScanOperationId = operationId;
      // Websocket will handle progress updates via 'scan_progress' event
    } catch (e) {
      setState(() {
        _isScanningFolder = false;
        _folderScanMessage = 'Error: ${e.toString()}';
      });
    }
  }

  Future<void> _showArtworkPickersForNewAlbums() async {
    try {
      final folderPath = Uri.encodeComponent(_selectedFolderPath ?? '');
      final response = await appHttpClient.get(
        Uri.parse(
          '${ApiService.baseUrl}/albums-without-artwork?folder_path=$folderPath',
        ),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final albums = data['albums'] as List;

        if (albums.isEmpty) return;

        for (var album in albums) {
          if (!mounted) break;

          final result = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (context) => ArtworkPickerDialog(
              albumId: album['id'],
              albumTitle: album['title'],
              artistName: album['artist_name'],
            ),
          );

          if (result != true) break;
        }
      }
    } catch (e) {
      print('Error fetching albums without artwork: $e');
    }
  }

  static const _sidebarItems = [
    (icon: Icons.play_circle, label: 'Playback'),
    (icon: Icons.library_music, label: 'Library'),
    (icon: Icons.image, label: 'Media'),
    (icon: Icons.merge, label: 'Merge'),
    (icon: Icons.psychology, label: 'Analysis'),
    (icon: Icons.sync_alt, label: 'Integrations'),
    (icon: Icons.cloud, label: 'Weather'),
    (icon: Icons.construction, label: 'Temp'),
    (icon: Icons.account_circle, label: 'Account'),
  ];

  Widget _getTabContent(int index) {
    switch (index) {
      case 0: return _buildPlaybackTab();
      case 1: return _buildLibraryTab();
      case 2: return _buildMediaTab();
      case 3: return _buildMergeTab();
      case 4: return _buildAnalysisTab();
      case 5: return _buildIntegrationsTab();
      case 6: return _buildWeatherTab();
      case 7: return _buildTempTab();
      case 8: return _buildAccountTab();
      default: return _buildPlaybackTab();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = Platform.isAndroid || Platform.isIOS;
    final dialogWidth = isMobile
        ? MediaQuery.of(context).size.width * 0.95
        : 700.0;
    final dialogHeight = isMobile
        ? MediaQuery.of(context).size.height * 0.8
        : 550.0;

    return Dialog(
      backgroundColor: const Color(0xFF0d1b2a),
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Color(0xFF1a2332), width: 1),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.settings, color: Color(0xFF00d4ff)),
                  const SizedBox(width: 12),
                  const Text(
                    'Settings',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.grey),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            // Content area
            Expanded(
              child: isMobile
                  ? _buildMobileLayout()
                  : _buildDesktopLayout(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileLayout() {
    return Column(
      children: [
        Container(
          color: const Color(0xFF1a2332),
          child: TabBar(
            controller: _tabController,
            isScrollable: true,
            indicatorColor: const Color(0xFF00d4ff),
            labelColor: const Color(0xFF00d4ff),
            unselectedLabelColor: Colors.grey,
            labelPadding: const EdgeInsets.symmetric(horizontal: 12),
            tabs: _sidebarItems
                .map((item) => Tab(icon: Icon(item.icon, size: 22)))
                .toList(),
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: List.generate(
              _sidebarItems.length,
              (i) => _getTabContent(i),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDesktopLayout() {
    return Row(
      children: [
        // Sidebar
        Container(
          width: 170,
          decoration: const BoxDecoration(
            color: Color(0xFF0d1b2a),
            border: Border(
              right: BorderSide(color: Color(0xFF1a2332), width: 1),
            ),
          ),
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: _sidebarItems.length,
            itemBuilder: (context, index) {
              final item = _sidebarItems[index];
              final isSelected = _selectedSidebarIndex == index;
              return InkWell(
                onTap: () {
                  setState(() {
                    _selectedSidebarIndex = index;
                  });
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? const Color(0xFF1a2332)
                        : Colors.transparent,
                    border: Border(
                      left: BorderSide(
                        color: isSelected
                            ? const Color(0xFF00d4ff)
                            : Colors.transparent,
                        width: 3,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        item.icon,
                        size: 20,
                        color: isSelected
                            ? const Color(0xFF00d4ff)
                            : Colors.grey,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        item.label,
                        style: TextStyle(
                          fontSize: 14,
                          color: isSelected
                              ? const Color(0xFF00d4ff)
                              : Colors.grey,
                          fontWeight: isSelected
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        // Content
        Expanded(
          child: _getTabContent(_selectedSidebarIndex),
        ),
      ],
    );
  }

  Widget _buildPlaybackTab() {
    return SingleChildScrollView(
      padding: EdgeInsets.all(_isMobile ? 16 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader('Crossfade'),
          const SizedBox(height: 12),
          _buildToggleRow(
            'Crossfade',
            'Smooth transition between tracks',
            widget.audioPlayerService.crossfadeEnabled,
            (value) {
              setState(() {
                widget.audioPlayerService.setCrossfadeEnabled(value);
              });
            },
          ),
          if (widget.audioPlayerService.crossfadeEnabled) ...[
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Duration', style: TextStyle(color: Colors.white)),
                Text(
                  '${widget.audioPlayerService.crossfadeDuration.inSeconds}s',
                  style: const TextStyle(
                    color: Color(0xFF00d4ff),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            Slider(
              value: widget.audioPlayerService.crossfadeDuration.inSeconds
                  .toDouble(),
              min: 1,
              max: 12,
              divisions: 11,
              activeColor: const Color(0xFF00d4ff),
              inactiveColor: const Color(0xFF1a2332),
              onChanged: (value) {
                setState(() {
                  widget.audioPlayerService.setCrossfadeDuration(
                    Duration(seconds: value.round()),
                  );
                });
              },
            ),
            const Text(
              'Use 1-2s for near-gapless albums like Pink Floyd',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ] else ...[
            const SizedBox(height: 8),
            const Text(
              'Note: There may be a brief pause between tracks.\nEnable crossfade with 1-2s for seamless playback.',
              style: TextStyle(fontSize: 11, color: Colors.orange),
            ),
          ],
          const SizedBox(height: 32),
          _buildSectionHeader('Volume Normalization'),
          const SizedBox(height: 12),
          _buildToggleRow(
            'ReplayGain',
            'Balance loudness across tracks',
            widget.audioPlayerService.replayGainEnabled,
            (value) {
              setState(() {
                widget.audioPlayerService.setReplayGainEnabled(value);
              });
            },
          ),
          if (widget.audioPlayerService.replayGainEnabled)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Requires audio analysis. Songs without analysis play at normal volume.',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
          if (Platform.isAndroid || Platform.isIOS) ...[
            const SizedBox(height: 32),
            _buildSectionHeader('Stream Quality'),
            const SizedBox(height: 12),
            _buildQualityOption('auto', 'Auto', 'Lossless on WiFi, AAC 320k on cellular'),
            _buildQualityOption('lossless', 'Lossless', 'Original file (FLAC/WAV) — best quality'),
            _buildQualityOption('high', 'High', 'AAC 320kbps — transparent quality'),
            _buildQualityOption('medium', 'Medium', 'AAC 128kbps — saves bandwidth'),
            _buildQualityOption('low', 'Low', 'MP3 96kbps — minimal bandwidth'),
            const SizedBox(height: 8),
            Text(
              'Current: ${widget.audioPlayerService.streamQuality} · Changes apply to next song',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ],
      ),
    );
  }

  /// Non-admins see this instead of maintenance controls the server would
  /// refuse with 403 anyway.
  Widget _adminOnlyNotice(String what) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.admin_panel_settings_outlined, size: 40, color: Colors.grey),
            const SizedBox(height: 12),
            Text(
              '$what is managed by an admin.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLibraryTab() {
    if (!AuthService.instance.isAdmin) return _adminOnlyNotice('Library scanning');
    return SingleChildScrollView(
      padding: EdgeInsets.all(_isMobile ? 16 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader('Library Scan'),
          const SizedBox(height: 8),
          const Text(
            'Import new songs or rescan your entire library.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          if (_message != null) _buildStatusMessage(_message!),
          if (_isRescanning)
            _buildProgressWithCancel(_rescanProgress, () async {
              if (_currentOperationId != null) {
                await appHttpClient.post(
                  Uri.parse(
                    '${ApiService.baseUrl}/cancel/$_currentOperationId',
                  ),
                );
                // Websocket will receive the cancelled status and update UI
              }
            })
          else ...[
            _buildButton(
              'Import New Files Only',
              Icons.add_circle_outline,
              _scanNewFiles,
              primary: true,
            ),
            const SizedBox(height: 8),
            _buildButton(
              'Full Library Rescan',
              Icons.refresh,
              _rescanLibrary,
              outlined: true,
            ),
          ],
          const SizedBox(height: 32),
          _buildSectionHeader('Scan Specific Folder'),
          const SizedBox(height: 8),
          const Text(
            'Scan a specific folder instead of your entire library.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          if (_folderScanMessage != null)
            _buildStatusMessage(_folderScanMessage!),
          if (_isScanningFolder)
            _buildProgressWithCancel(_folderScanProgress, () async {
              if (_folderScanOperationId != null) {
                await appHttpClient.post(
                  Uri.parse(
                    '${ApiService.baseUrl}/cancel/$_folderScanOperationId',
                  ),
                );
                // Websocket will receive the cancelled status and update UI
              }
            })
          else ...[
            TextField(
              controller: _folderPathController,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(
                hintText: 'Artist/Album Name',
                hintStyle: TextStyle(color: Colors.grey, fontSize: 13),
                labelText: 'Folder path (relative)',
                labelStyle: TextStyle(color: Color(0xFF00d4ff), fontSize: 13),
                border: OutlineInputBorder(),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.grey),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF00d4ff)),
                ),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
              onChanged: (value) {
                setState(() {
                  _selectedFolderPath = value.trim();
                });
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildButton('Browse', Icons.folder_open, _pickFolder),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildButton(
                    'Scan',
                    Icons.search,
                    _scanFolder,
                    primary: true,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 32),
          _buildSectionHeader('Cleanup'),
          const SizedBox(height: 8),
          const Text(
            'Remove songs whose files no longer exist.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          if (_cleanupMessage != null) _buildStatusMessage(_cleanupMessage!),
          if (_isCleaningUp)
            _buildProgressWithCancel(_cleanupProgress, () async {
              if (_cleanupOperationId != null) {
                await appHttpClient.post(
                  Uri.parse(
                    '${ApiService.baseUrl}/cancel/$_cleanupOperationId',
                  ),
                );
                // Websocket will receive the cancelled status and update UI
              }
            })
          else
            _buildButton(
              'Remove Missing Files',
              Icons.cleaning_services,
              _cleanupMissingFiles,
              color: Colors.orange,
            ),
          const SizedBox(height: 32),
          _buildSectionHeader('Excluded Files'),
          const SizedBox(height: 8),
          const Text(
            'View and restore manually deleted files.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          _buildButton('Manage Exclusions', Icons.block, () {
            Navigator.pop(context);
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ExclusionsScreen(
                  audioPlayerService: widget.audioPlayerService,
                ),
              ),
            );
          }),
          const SizedBox(height: 32),
          _buildSectionHeader('Duplicate Albums'),
          const SizedBox(height: 8),
          const Text(
            'Review and clean up duplicate album versions.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          _buildButton('Review Duplicates', Icons.content_copy, () {
            Navigator.pop(context);
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => DuplicateReviewScreen(
                  audioPlayerService: widget.audioPlayerService,
                ),
              ),
            );
          }, color: Colors.orange),
        ],
      ),
    );
  }

  Widget _buildMediaTab() {
    return SingleChildScrollView(
      padding: EdgeInsets.all(_isMobile ? 16 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader('Album Artwork'),
          const SizedBox(height: 8),
          const Text(
            'Download album artwork from MusicBrainz.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          if (_artworkMessage != null) _buildStatusMessage(_artworkMessage!),
          if (_isDownloadingArtwork)
            _buildProgressWithCancel(_artworkProgress, () async {
              if (_artworkOperationId != null) {
                await appHttpClient.post(
                  Uri.parse(
                    '${ApiService.baseUrl}/cancel/$_artworkOperationId',
                  ),
                );
                // Websocket will receive the cancelled status and update UI
              }
            })
          else
            _buildButton(
              'Download Album Artwork',
              Icons.image,
              _downloadArtwork,
              primary: true,
            ),
          const SizedBox(height: 12),
          if (_upgradeArtworkMessage != null)
            _buildStatusMessage(_upgradeArtworkMessage!),
          if (_isUpgradingArtwork)
            _buildProgressWithCancel(_upgradeArtworkProgress, () async {
              if (_upgradeArtworkOperationId != null) {
                await appHttpClient.post(
                  Uri.parse(
                    '${ApiService.baseUrl}/cancel/$_upgradeArtworkOperationId',
                  ),
                );
              }
            })
          else
            _buildButton(
              'Upgrade All to Full Resolution',
              Icons.high_quality,
              _upgradeArtwork,
            ),
          const SizedBox(height: 32),
          _buildSectionHeader('Artist Images'),
          const SizedBox(height: 8),
          const Text(
            'Download artist photos from Fanart.tv.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          if (_artistImagesMessage != null)
            _buildStatusMessage(_artistImagesMessage!),
          if (_isDownloadingArtistImages)
            _buildProgressWithCancel(_artistImagesProgress, () async {
              if (_artistImagesOperationId != null) {
                await appHttpClient.post(
                  Uri.parse(
                    '${ApiService.baseUrl}/cancel/$_artistImagesOperationId',
                  ),
                );
                // Websocket will receive the cancelled status and update UI
              }
            })
          else
            _buildButton(
              'Download Artist Images',
              Icons.person,
              _downloadArtistImages,
              primary: true,
            ),
        ],
      ),
    );
  }

  Widget _buildMergeTab() {
    return SingleChildScrollView(
      padding: EdgeInsets.all(_isMobile ? 16 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader('Artist Merge'),
          const SizedBox(height: 8),
          const Text(
            'Merge duplicate artists with different names or spellings.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          _buildButton('Auto-Detect Duplicates', Icons.auto_fix_high, () {
            Navigator.pop(context);
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const ArtistMergeScreen(),
              ),
            );
          }, primary: true),
          const SizedBox(height: 8),
          _buildButton('Manual Artist Merge', Icons.checklist, () {
            Navigator.pop(context);
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const ManualMergeScreen(),
              ),
            );
          }),
          const SizedBox(height: 32),
          _buildSectionHeader('Album Merge'),
          const SizedBox(height: 8),
          const Text(
            'Merge split albums (CD 1/CD 2) or multi-artist compilations.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          _buildButton('Merge Duplicate Albums', Icons.album, () {
            Navigator.pop(context);
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => AlbumMergeScreen(
                  audioPlayerService: widget.audioPlayerService,
                ),
              ),
            );
          }, color: Colors.orange),
        ],
      ),
    );
  }

  Widget _buildAnalysisTab() {
    if (!AuthService.instance.isAdmin) return _adminOnlyNotice('Audio analysis');
    return SingleChildScrollView(
      padding: EdgeInsets.all(_isMobile ? 16 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader('Audio Analysis'),
          const SizedBox(height: 8),
          const Text(
            'Analyze your library for genre, mood, BPM, key, and loudness using Essentia AI.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          // Service status
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1a2332),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(
                      _essentiaOnline ? Icons.check_circle : Icons.error,
                      color: _essentiaOnline ? Colors.green : Colors.red,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _essentiaOnline
                          ? 'Essentia service online'
                          : 'Essentia service offline',
                      style: TextStyle(
                        color: _essentiaOnline ? Colors.green : Colors.red,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.analytics, color: Colors.grey, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      '$_analyzedCount / $_totalToAnalyze songs analyzed',
                      style: const TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                  ],
                ),
                if (!_essentiaOnline) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed:
                          _isStartingEssentia ? null : _startEssentiaService,
                      icon: _isStartingEssentia
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor:
                                    AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            )
                          : const Icon(Icons.play_arrow, size: 18),
                      label: Text(
                        _isStartingEssentia
                            ? 'Starting Essentia (may take up to 90s)...'
                            : 'Start Essentia Service',
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00d4ff),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                  if (_essentiaStartError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _essentiaStartError!,
                      style: const TextStyle(
                        color: Colors.red,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (_analysisMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _analysisMessage!,
                style: TextStyle(
                  color: _analysisMessage!.contains('Error')
                      ? Colors.red
                      : const Color(0xFF00d4ff),
                  fontSize: 13,
                ),
              ),
            ),
          if (_isAnalyzing) ...[
            LinearProgressIndicator(
              value: _analysisProgress,
              backgroundColor: const Color(0xFF1a2332),
              valueColor: const AlwaysStoppedAnimation<Color>(
                Color(0xFF00d4ff),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${(_analysisProgress * 100).toStringAsFixed(1)}%',
                  style: const TextStyle(
                    color: Color(0xFF00d4ff),
                    fontSize: 12,
                  ),
                ),
                if (_analysisEta != null)
                  Text(
                    'ETA: $_analysisEta',
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _buildButton(
              'Cancel Analysis',
              Icons.cancel,
              _cancelAnalysis,
              color: Colors.red,
            ),
          ] else
            _buildButton(
              'Start Audio Analysis',
              Icons.psychology,
              _essentiaOnline ? _startAnalysis : null,
              primary: true,
              disabled: !_essentiaOnline,
            ),
          if (_recentAnalyses.isNotEmpty) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                const Icon(Icons.history, color: Color(0xFF00d4ff), size: 16),
                const SizedBox(width: 6),
                Text(
                  'Recent (last ${_recentAnalyses.length})',
                  style: const TextStyle(
                    color: Color(0xFF00d4ff),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF1a2332),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF2a3a4a)),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _recentAnalyses.length,
                itemBuilder: (ctx, i) {
                  final r = _recentAnalyses[i];
                  final parts = <String>[];
                  final bpm = r['bpm'];
                  if (bpm is num) parts.add('${bpm.toStringAsFixed(0)} BPM');
                  final key = r['key'];
                  if (key != null && key.toString().isNotEmpty) {
                    parts.add(key.toString());
                  }
                  final genre = r['top_genre'];
                  if (genre != null && genre.toString().isNotEmpty) {
                    parts.add(genre.toString());
                  }
                  final mood = r['top_mood'];
                  if (mood != null && mood.toString().isNotEmpty) {
                    parts.add(mood.toString());
                  }
                  final lufs = r['integrated_loudness_lufs'];
                  if (lufs is num) {
                    parts.add('${lufs.toStringAsFixed(1)} LUFS');
                  }
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 2, right: 6),
                          child: Icon(
                            Icons.check_circle,
                            color: Colors.green,
                            size: 12,
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                r['title']?.toString() ?? '(unknown)',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (parts.isNotEmpty)
                                Text(
                                  parts.join(' · '),
                                  style: const TextStyle(
                                    color: Colors.grey,
                                    fontSize: 11,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: 24),
          const Divider(color: Color(0xFF2a3a4a)),
          const SizedBox(height: 16),
          _buildSectionHeader('Mobile Transcode'),
          const SizedBox(height: 8),
          const Text(
            'Pre-transcode lossless files to AAC 320k for instant mobile cellular playback.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          // Service status
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1a2332),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(
                      _transcodeServiceOnline ? Icons.check_circle : Icons.error,
                      color: _transcodeServiceOnline ? Colors.green : Colors.red,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _transcodeServiceOnline
                          ? 'Transcode service online'
                          : 'Transcode service offline',
                      style: TextStyle(
                        color: _transcodeServiceOnline ? Colors.green : Colors.red,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.cached, color: Colors.grey, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      '$_cachedCount / $_totalSongs songs cached',
                      style: const TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (_transcodeMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _transcodeMessage!,
                style: TextStyle(
                  color: _transcodeMessage!.contains('Error')
                      ? Colors.red
                      : const Color(0xFFff9800),
                  fontSize: 13,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (_isTranscoding) ...[
            LinearProgressIndicator(
              value: _transcodeProgress,
              backgroundColor: const Color(0xFF1a2332),
              valueColor: const AlwaysStoppedAnimation<Color>(
                Color(0xFFff9800),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${(_transcodeProgress * 100).toStringAsFixed(1)}%',
                  style: const TextStyle(
                    color: Color(0xFFff9800),
                    fontSize: 12,
                  ),
                ),
                if (_transcodeEta != null)
                  Text(
                    'ETA: $_transcodeEta',
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Text(
                  '$_transcodedCount done',
                  style: const TextStyle(color: Colors.green, fontSize: 11),
                ),
                const SizedBox(width: 12),
                Text(
                  '$_skippedCount skipped',
                  style: const TextStyle(color: Colors.grey, fontSize: 11),
                ),
                if (_failedCount > 0) ...[
                  const SizedBox(width: 12),
                  Text(
                    '$_failedCount failed',
                    style: const TextStyle(color: Colors.red, fontSize: 11),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            _buildButton(
              'Cancel Transcode',
              Icons.cancel,
              _cancelTranscode,
              color: Colors.red,
            ),
          ] else
            _buildButton(
              'Start Batch Transcode',
              Icons.transform,
              _transcodeServiceOnline ? _startTranscode : null,
              primary: true,
              disabled: !_transcodeServiceOnline,
            ),
        ],
      ),
    );
  }

  Widget _buildIntegrationsTab() {
    return FutureBuilder<Map<String, dynamic>>(
      future: widget.apiService.getLastfmStatus(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(
            child: Text(
              'Failed to load Last.fm status',
              style: TextStyle(color: Colors.grey),
            ),
          );
        }

        final status = snapshot.data ?? {};
        final configured = status['configured'] as bool? ?? false;
        final authenticated = status['authenticated'] as bool? ?? false;
        final username = status['username'] as String?;
        final enabled = status['enabled'] as bool? ?? true;

        return StatefulBuilder(
          builder: (context, setLocalState) {
            final apiKeyController = TextEditingController();
            final apiSecretController = TextEditingController();
            String? statusMessage;
            bool isLoading = false;

            return SingleChildScrollView(
              padding: EdgeInsets.all(_isMobile ? 16 : 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionHeader('Last.fm Scrobbling'),
                  const SizedBox(height: 8),
                  const Text(
                    'Automatically scrobble songs you listen to on Last.fm.',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),

                  if (authenticated) ...[
                    // Connected state
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1a2332),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: const Color(0xFF00d4ff).withOpacity(0.3),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.check_circle,
                                color: Color(0xFF4CAF50),
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Connected as $username',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          _buildToggleRow(
                            'Scrobbling',
                            enabled
                                ? 'Songs are being scrobbled'
                                : 'Scrobbling is paused',
                            enabled,
                            (value) {
                              widget.apiService
                                  .toggleLastfmScrobbling(value)
                                  .then((_) {
                                setLocalState(() {});
                                // Refresh the whole FutureBuilder
                                setState(() {});
                              });
                            },
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.bar_chart, size: 18),
                              label: const Text('View My Stats'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF00d4ff),
                                foregroundColor: Colors.black,
                              ),
                              onPressed: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => LastfmStatsScreen(
                                      apiService: widget.apiService,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.link_off, size: 18),
                              label: const Text('Disconnect'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.red[300],
                                side: BorderSide(color: Colors.red[300]!),
                              ),
                              onPressed: () {
                                widget.apiService
                                    .disconnectLastfm()
                                    .then((_) {
                                  setState(() {});
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ] else if (configured) ...[
                    // API keys saved, needs authorization
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1a2332),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.warning_amber,
                                color: Colors.orange,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              const Text(
                                'API keys saved — authorization needed',
                                style: TextStyle(color: Colors.orange),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Step 1: Click "Authorize" to open Last.fm in your browser\n'
                            'Step 2: Grant access to NASRadio\n'
                            'Step 3: Come back here and click "Complete Authorization"',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                              height: 1.6,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton.icon(
                                  icon: const Icon(Icons.open_in_new, size: 18),
                                  label: const Text('Authorize'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF00d4ff),
                                    foregroundColor: Colors.black,
                                  ),
                                  onPressed: () async {
                                    final url = await widget.apiService
                                        .getLastfmAuthUrl();
                                    if (url != null) {
                                      launchUrl(Uri.parse(url));
                                    }
                                  },
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: OutlinedButton.icon(
                                  icon: const Icon(Icons.check, size: 18),
                                  label: const Text('Complete'),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: const Color(0xFF00d4ff),
                                    side: const BorderSide(
                                      color: Color(0xFF00d4ff),
                                    ),
                                  ),
                                  onPressed: () async {
                                    final result = await widget.apiService
                                        .completeLastfmAuth();
                                    if (result['success'] == true) {
                                      setState(() {});
                                    } else {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              result['error'] ??
                                                  'Authorization failed',
                                            ),
                                          ),
                                        );
                                      }
                                    }
                                  },
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ] else ...[
                    // Not configured — need API keys
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1a2332),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'To get started, create a Last.fm API application:',
                            style: TextStyle(fontSize: 13, color: Colors.grey),
                          ),
                          const SizedBox(height: 8),
                          GestureDetector(
                            onTap: () => launchUrl(
                              Uri.parse(
                                'https://www.last.fm/api/account/create',
                              ),
                            ),
                            child: const Text(
                              'last.fm/api/account/create',
                              style: TextStyle(
                                fontSize: 13,
                                color: Color(0xFF00d4ff),
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: apiKeyController,
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              labelText: 'API Key',
                              labelStyle: TextStyle(color: Colors.grey),
                              enabledBorder: OutlineInputBorder(
                                borderSide: BorderSide(color: Colors.grey),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderSide:
                                    BorderSide(color: Color(0xFF00d4ff)),
                              ),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: apiSecretController,
                            style: const TextStyle(color: Colors.white),
                            obscureText: true,
                            decoration: const InputDecoration(
                              labelText: 'Shared Secret',
                              labelStyle: TextStyle(color: Colors.grey),
                              enabledBorder: OutlineInputBorder(
                                borderSide: BorderSide(color: Colors.grey),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderSide:
                                    BorderSide(color: Color(0xFF00d4ff)),
                              ),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.save, size: 18),
                              label: const Text('Save API Keys'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF00d4ff),
                                foregroundColor: Colors.black,
                              ),
                              onPressed: () async {
                                final key = apiKeyController.text.trim();
                                final secret =
                                    apiSecretController.text.trim();
                                if (key.isEmpty || secret.isEmpty) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Both API Key and Shared Secret are required',
                                      ),
                                    ),
                                  );
                                  return;
                                }
                                try {
                                  await widget.apiService
                                      .configureLastfm(key, secret);
                                  setState(() {});
                                } catch (e) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content:
                                            Text('Failed to save: $e'),
                                      ),
                                    );
                                  }
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (AuthService.instance.isAdmin) ...[
                    const SizedBox(height: 28),
                    const Divider(color: Color(0xFF1a2332)),
                    const SizedBox(height: 16),
                    const AdminIntegrationsPanel(),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildWeatherTab() {
    return ListenableBuilder(
      listenable: globalWeatherService,
      builder: (context, child) {
        final ws = globalWeatherService;
        return SingleChildScrollView(
          padding: EdgeInsets.all(_isMobile ? 16 : 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSectionHeader('Weather'),
              const SizedBox(height: 12),
              _buildToggleRow(
                'Enable Weather',
                'Show current conditions and weather alerts',
                ws.enabled,
                (value) {
                  ws.setEnabled(value);
                },
              ),
              if (ws.enabled) ...[
                const SizedBox(height: 24),
                _buildSectionHeader('Location'),
                const SizedBox(height: 12),
                if (_isMobile) ...[
                  _buildToggleRow(
                    'Use GPS',
                    'Automatically detect your location',
                    ws.useGps,
                    (value) {
                      ws.setUseGps(value);
                    },
                  ),
                ],
                if (!_isMobile || !ws.useGps) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _citySearchController,
                    decoration: InputDecoration(
                      labelText: 'Search city...',
                      labelStyle: const TextStyle(color: Colors.grey),
                      prefixIcon: const Icon(Icons.search, color: Colors.grey, size: 20),
                      suffixIcon: _isSearching
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: Padding(
                                padding: EdgeInsets.all(12),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xFF00d4ff),
                                ),
                              ),
                            )
                          : null,
                      enabledBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF1a2332)),
                        borderRadius: BorderRadius.all(Radius.circular(8)),
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF00d4ff)),
                        borderRadius: BorderRadius.all(Radius.circular(8)),
                      ),
                      filled: true,
                      fillColor: const Color(0xFF1a2332),
                    ),
                    style: const TextStyle(color: Colors.white),
                    onChanged: (query) {
                      _searchDebounce?.cancel();
                      if (query.trim().length < 2) {
                        setState(() {
                          _locationResults = [];
                          _isSearching = false;
                        });
                        return;
                      }
                      setState(() => _isSearching = true);
                      _searchDebounce = Timer(
                        const Duration(milliseconds: 500),
                        () async {
                          final results =
                              await globalWeatherService.searchLocation(query);
                          if (mounted) {
                            setState(() {
                              _locationResults = results;
                              _isSearching = false;
                            });
                          }
                        },
                      );
                    },
                  ),
                  if (_locationResults.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 200),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1a2332),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: const Color(0xFF00d4ff).withValues(alpha: 0.3),
                        ),
                      ),
                      child: ListView.builder(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: _locationResults.length,
                        itemBuilder: (context, index) {
                          final result = _locationResults[index];
                          return InkWell(
                            onTap: () {
                              ws.setLocationFromSearch(result);
                              _citySearchController.clear();
                              setState(() {
                                _locationResults = [];
                              });
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 10),
                              child: Row(
                                children: [
                                  const Icon(Icons.location_on,
                                      color: Color(0xFF00d4ff), size: 18),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      result.shortName,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ],
                if (ws.locationName.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.my_location,
                          color: Color(0xFF00d4ff), size: 16),
                      const SizedBox(width: 6),
                      Text(
                        ws.locationName,
                        style: const TextStyle(
                          color: Color(0xFF00d4ff),
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 24),
                _buildSectionHeader('Alerts'),
                const SizedBox(height: 12),
                // Alert Mode
                Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Alert Mode',
                            style:
                                TextStyle(fontSize: 15, color: Colors.white),
                          ),
                          Text(
                            'How to notify you of weather alerts',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                    DropdownButton<String>(
                      value: ws.alertMode,
                      dropdownColor: const Color(0xFF1a2332),
                      style:
                          const TextStyle(color: Color(0xFF00d4ff), fontSize: 14),
                      underline:
                          Container(height: 1, color: const Color(0xFF00d4ff)),
                      items: const [
                        DropdownMenuItem(
                            value: 'voice_and_banner',
                            child: Text('Voice + Banner')),
                        DropdownMenuItem(
                            value: 'banner_only',
                            child: Text('Banner Only')),
                        DropdownMenuItem(
                            value: 'voice_only',
                            child: Text('Voice Only')),
                        DropdownMenuItem(
                            value: 'off', child: Text('Off')),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          ws.setAlertMode(value);
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // Alert Severity
                _buildToggleRow(
                  'Severe Only',
                  'Only alert for severe/extreme warnings',
                  ws.alertSeverity == 'severe_only',
                  (value) {
                    ws.setAlertSeverity(value ? 'severe_only' : 'all');
                  },
                ),
                const SizedBox(height: 16),
                // Ambient Sounds
                _buildToggleRow(
                  'Ambient Weather Sounds',
                  'Play subtle rain sounds when it\'s raining',
                  ws.ambientSounds,
                  (value) {
                    ws.setAmbientSounds(value);
                  },
                ),
                const SizedBox(height: 24),
                _buildSectionHeader('Testing'),
                const SizedBox(height: 12),
                Row(
                  children: [
                    ElevatedButton.icon(
                      onPressed: () {
                        globalWeatherService.fireTestAlert();
                      },
                      icon: const Icon(Icons.warning_amber_rounded, size: 18),
                      label: const Text('Test Alert'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFD32F2F),
                        foregroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const AlertHistoryScreen(),
                          ),
                        );
                      },
                      icon: const Icon(Icons.history, size: 18),
                      label: const Text('Alert History'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1a2332),
                        foregroundColor: const Color(0xFF00d4ff),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _buildSectionHeader('Preview Sounds'),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () async {
                        final player = audioplayers.AudioPlayer();
                        await player.play(audioplayers.AssetSource('sounds/alert_severe.wav'));
                        player.onPlayerComplete.listen((_) => player.dispose());
                      },
                      icon: const Icon(Icons.volume_up, size: 16),
                      label: const Text('Severe Chime'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFD32F2F),
                        side: const BorderSide(color: Color(0xFFD32F2F)),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final player = audioplayers.AudioPlayer();
                        await player.play(audioplayers.AssetSource('sounds/alert_moderate.wav'));
                        player.onPlayerComplete.listen((_) => player.dispose());
                      },
                      icon: const Icon(Icons.volume_up, size: 16),
                      label: const Text('Moderate Chime'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFF9A825),
                        side: const BorderSide(color: Color(0xFFF9A825)),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final player = audioplayers.AudioPlayer();
                        await player.setVolume(0.3);
                        await player.play(audioplayers.AssetSource('sounds/rain_ambient.wav'));
                        // Stop after 5 seconds preview
                        Future.delayed(const Duration(seconds: 5), () {
                          player.stop();
                          player.dispose();
                        });
                      },
                      icon: const Icon(Icons.water_drop, size: 16),
                      label: const Text('Rain (5s preview)'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF00d4ff),
                        side: const BorderSide(color: Color(0xFF00d4ff)),
                      ),
                    ),
                  ],
                ),
                if (ws.currentWeather != null) ...[
                  const SizedBox(height: 24),
                  _buildSectionHeader('Current Conditions'),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1a2332),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Text(
                          ws.currentWeather!.emoji,
                          style: const TextStyle(fontSize: 40),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${ws.currentWeather!.temperatureF?.round() ?? "--"}\u00b0F - ${ws.currentWeather!.description}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                ws.currentWeather!.locationName,
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (ws.error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    ws.error!,
                    style: const TextStyle(color: Colors.red, fontSize: 13),
                  ),
                ],
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildTempTab() {
    final albumsMissing = _mbidStats?['albums']?['missing'] ?? 0;
    final albumsTotal = _mbidStats?['albums']?['total'] ?? 0;
    final albumsWithMbid = _mbidStats?['albums']?['with_mbid'] ?? 0;
    final artistsMissing = _mbidStats?['artists']?['missing'] ?? 0;
    final artistsTotal = _mbidStats?['artists']?['total'] ?? 0;
    final artistsWithMbid = _mbidStats?['artists']?['with_mbid'] ?? 0;
    final albumTypes = _mbidStats?['album_types'] as List<dynamic>? ?? [];

    return SingleChildScrollView(
      padding: EdgeInsets.all(_isMobile ? 16 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.2),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.withOpacity(0.5)),
            ),
            child: const Row(
              children: [
                Icon(Icons.construction, color: Colors.orange, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Temporary tools - remove after use',
                    style: TextStyle(color: Colors.orange, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _buildSectionHeader('MBID Backfill'),
          const SizedBox(height: 8),
          const Text(
            'Populate MusicBrainz IDs for albums missing them.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1a2332),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Albums:',
                      style: TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                    Text(
                      '$albumsWithMbid / $albumsTotal',
                      style: TextStyle(
                        color: albumsMissing == 0
                            ? Colors.green
                            : const Color(0xFF00d4ff),
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Artists:',
                      style: TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                    Text(
                      '$artistsWithMbid / $artistsTotal',
                      style: TextStyle(
                        color: artistsMissing == 0
                            ? Colors.green
                            : const Color(0xFF00d4ff),
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                if (albumTypes.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Divider(color: Color(0xFF2a3a4a)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: albumTypes
                        .map(
                          (t) => Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF00d4ff).withOpacity(0.2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '${t['type']}: ${t['count']}',
                              style: const TextStyle(
                                color: Color(0xFF00d4ff),
                                fontSize: 11,
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (_mbidBackfillMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _mbidBackfillMessage!,
                style: TextStyle(
                  color: _mbidBackfillMessage!.contains('Error')
                      ? Colors.red
                      : const Color(0xFF00d4ff),
                  fontSize: 13,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (_isBackfillingMbids) ...[
            LinearProgressIndicator(
              value: _mbidBackfillProgress,
              backgroundColor: const Color(0xFF1a2332),
              valueColor: const AlwaysStoppedAnimation<Color>(
                Color(0xFF00d4ff),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${(_mbidBackfillProgress * 100).toStringAsFixed(1)}%',
                  style: const TextStyle(
                    color: Color(0xFF00d4ff),
                    fontSize: 12,
                  ),
                ),
                Text(
                  '$_mbidUpdatedAlbums albums, $_mbidUpdatedArtists artists',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '~${((_mbidTotalAlbums - (_mbidBackfillProgress * _mbidTotalAlbums).round()) / 60).toStringAsFixed(0)} min remaining',
              style: const TextStyle(color: Colors.grey, fontSize: 11),
            ),
            const SizedBox(height: 12),
            _buildButton(
              'Cancel',
              Icons.cancel,
              _cancelMbidBackfill,
              color: Colors.red,
            ),
          ] else ...[
            _buildButton(
              albumsMissing > 0
                  ? 'Backfill $albumsMissing Albums'
                  : 'All Done ✓',
              Icons.cloud_download,
              albumsMissing > 0 ? _startMbidBackfill : null,
              primary: albumsMissing > 0,
              disabled: albumsMissing == 0,
            ),
            const SizedBox(height: 8),
            _buildButton(
              'Refresh Stats',
              Icons.refresh,
              _loadMbidStats,
              outlined: true,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAccountTab() {
    final user = AuthService.instance.user;
    final username = user?['username'] ?? 'Unknown';
    final role = user?['role'] ?? 'user';
    return SingleChildScrollView(
      padding: EdgeInsets.all(_isMobile ? 16 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader('Account'),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1a2332),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.account_circle,
                    size: 40, color: Color(0xFF00d4ff)),
                const SizedBox(width: 14),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      username,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: (role == 'admin' ? Colors.amber : Colors.grey)
                            .withOpacity(0.18),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        role == 'admin' ? 'Administrator' : 'User',
                        style: TextStyle(
                          fontSize: 11,
                          color: role == 'admin' ? Colors.amber : Colors.grey,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _confirmLogout,
              icon: const Icon(Icons.logout, color: Colors.redAccent),
              label: const Text('Sign Out',
                  style: TextStyle(color: Colors.redAccent)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.redAccent),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          if (role == 'admin') ...[
            const SizedBox(height: 24),
            const UserManagement(),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0d1521),
        title: const Text('Sign Out'),
        content: const Text('Sign out of NASRadio on this device?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await AuthService.instance.logout();
      if (mounted) Navigator.of(context).pop(); // close settings → gate shows login
    }
  }

  // Helper widgets
  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.bold,
        color: Color(0xFF00d4ff),
      ),
    );
  }

  Widget _buildToggleRow(
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontSize: 15, color: Colors.white),
              ),
              Text(
                subtitle,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
        Switch(
          value: value,
          activeThumbColor: const Color(0xFF00d4ff),
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildQualityOption(String value, String label, String description) {
    final isSelected = widget.audioPlayerService.qualityPreference == value;
    return InkWell(
      onTap: () {
        setState(() {
          widget.audioPlayerService.setQualityPreference(value);
        });
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              color: isSelected ? const Color(0xFF00d4ff) : Colors.grey,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(
                    color: isSelected ? const Color(0xFF00d4ff) : Colors.white,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  )),
                  Text(description, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildButton(
    String label,
    IconData icon,
    VoidCallback? onPressed, {
    bool primary = false,
    bool outlined = false,
    Color? color,
    bool disabled = false,
  }) {
    if (outlined) {
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          icon: Icon(icon, size: 18),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.grey,
            side: const BorderSide(color: Colors.grey),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
          onPressed: disabled ? null : onPressed,
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          backgroundColor: disabled
              ? Colors.grey
              : (color ?? (primary ? const Color(0xFF00d4ff) : Colors.white)),
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
        onPressed: disabled ? null : onPressed,
      ),
    );
  }

  Widget _buildStatusMessage(String message) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        message,
        style: TextStyle(
          color: message.contains('Error')
              ? Colors.red
              : const Color(0xFF00d4ff),
          fontSize: 13,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildProgressWithCancel(double progress, VoidCallback onCancel) {
    return Column(
      children: [
        LinearProgressIndicator(
          value: progress,
          backgroundColor: const Color(0xFF1a2332),
          valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00d4ff)),
        ),
        const SizedBox(height: 8),
        Text(
          '${(progress * 100).toStringAsFixed(0)}%',
          style: const TextStyle(color: Color(0xFF00d4ff), fontSize: 12),
        ),
        const SizedBox(height: 8),
        _buildButton('Cancel', Icons.cancel, onCancel, color: Colors.red),
        const SizedBox(height: 16),
      ],
    );
  }
}
