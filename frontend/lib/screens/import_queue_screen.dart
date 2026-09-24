import '../layout_context.dart';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import '../widgets/artwork_picker_dialog.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:url_launcher/url_launcher.dart';
import 'dart:io';
import 'dart:convert';
import '../services/auth_http_client.dart';
import '../widgets/mb_submit_dialog.dart';

class ImportQueueScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;

  const ImportQueueScreen({super.key, required this.audioPlayerService});

  @override
  State<ImportQueueScreen> createState() => _ImportQueueScreenState();
}

class _ImportQueueScreenState extends State<ImportQueueScreen> {
  final ApiService _apiService = ApiService();
  final TextEditingController _searchController = TextEditingController();

  List<Map<String, dynamic>> _pending = [];
  Map<String, Map<String, dynamic>> _duplicates = {};
  bool _isLoading = true;
  bool _isDeletingDuplicates = false;
  String? _error;
  String _searchQuery = '';
  String _filterSource = 'all';

  @override
  void initState() {
    super.initState();
    _loadPending();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool get _isMobile {
    final width =
        WidgetsBinding
            .instance
            .platformDispatcher
            .views
            .first
            .physicalSize
            .width /
        WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
    return width < 600;
  }

  Future<void> _loadPending() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final result = await _apiService.getPendingImports();
      // Widget can be disposed during the await (user navigates away
      // mid-fetch). setState on a disposed State throws "Null check
      // operator used on a null value" at State.setState — caught a
      // 2026-05-20 crash from this exact callsite.
      if (!mounted) return;
      if (result['success'] == true) {
        final pending = List<Map<String, dynamic>>.from(
          result['pending'] ?? [],
        );
        setState(() {
          _pending = pending;
          _isLoading = false;
        });
        _checkDuplicates();
      } else {
        throw Exception(result['error'] ?? 'Unknown error');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _checkDuplicates() async {
    if (_pending.isEmpty) return;

    try {
      final result = await _apiService.checkImportDuplicates(_pending);
      if (!mounted) return;
      if (result['success'] == true) {
        setState(() {
          _duplicates = Map<String, Map<String, dynamic>>.from(
            (result['results'] as Map).map(
              (key, value) =>
                  MapEntry(key.toString(), Map<String, dynamic>.from(value)),
            ),
          );
        });
      }
    } catch (e) {
      // Silent fail
    }
  }

  Future<void> _deleteDuplicates() async {
    final duplicatePaths = _duplicates.entries
        .where((e) => e.value['in_library'] == true)
        .map((e) => e.key)
        .toList();

    if (duplicatePaths.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: const Text('Delete All Duplicates?'),
        content: Text(
          'This will permanently delete ${duplicatePaths.length} folders that already exist in your library.\n\nThis cannot be undone!',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isDeletingDuplicates = true);

    try {
      final result = await _apiService.bulkDeleteImportFolders(duplicatePaths);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Deleted ${result['deleted_count']} duplicate folders',
            ),
            backgroundColor: Colors.green,
          ),
        );
        _loadPending();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      setState(() => _isDeletingDuplicates = false);
    }
  }

  bool _hasSubfolders(Map<String, dynamic> item) {
    // Check if multi_disc_info indicates subfolders exist
    final multiDiscInfo = item['multi_disc_info'] as Map<String, dynamic>?;
    if (multiDiscInfo != null) {
      final discs = multiDiscInfo['discs'] as List?;
      if (discs != null && discs.isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  Future<void> _deleteFolder(Map<String, dynamic> item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: const Text('Delete Folder?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('This will permanently delete:'),
            const SizedBox(height: 8),
            Text(
              item['folder_name'] ?? '',
              style: const TextStyle(color: Colors.orange, fontSize: 12),
            ),
            const SizedBox(height: 12),
            const Text(
              'This cannot be undone!',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _apiService.deleteImportFolder(item['path']);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Folder deleted'),
            backgroundColor: Colors.green,
          ),
        );
        _loadPending();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _showOrganizeFilesDialog(Map<String, dynamic> item) async {
    _showFolderNavigator(item['path'], item['folder_name'] ?? 'Root');
  }

  void _showFolderNavigator(String currentPath, String currentName) async {
    try {
      final subfoldersResult = await _apiService.listImportSubfolders(
        currentPath,
      );
      final subfolders =
          (subfoldersResult['subfolders'] as List?)
              ?.cast<Map<String, dynamic>>() ??
          [];

      // Also analyze this folder for splittable files
      final analysisResult = await _apiService.analyzeImportSplit(currentPath);
      final canSplit = analysisResult['can_split'] == true;
      final proposedFolders =
          (analysisResult['proposed_folders'] as List?)
              ?.cast<Map<String, dynamic>>() ??
          [];
      final unmatchedFiles =
          (analysisResult['unmatched_files'] as List?)
              ?.cast<Map<String, dynamic>>() ??
          [];
      final hasFiles = proposedFolders.isNotEmpty || unmatchedFiles.isNotEmpty;

      if (!mounted) return;

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF1a2332),
          title: Row(
            children: [
              const Icon(Icons.folder_copy, color: Colors.blue),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  currentName,
                  style: const TextStyle(fontSize: 16),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Show organize option if there are files to split
                  if (canSplit) ...[
                    Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: Colors.green.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Colors.green.withOpacity(0.3),
                        ),
                      ),
                      child: ListTile(
                        dense: true,
                        leading: const Icon(
                          Icons.auto_fix_high,
                          color: Colors.green,
                        ),
                        title: const Text(
                          'Auto-organize files in this folder',
                          style: TextStyle(
                            color: Colors.green,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: Text(
                          '${proposedFolders.length} disc(s) detected',
                          style: const TextStyle(
                            color: Colors.green,
                            fontSize: 11,
                          ),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        onTap: () {
                          Navigator.pop(context);
                          _showSplitPreviewDialog(
                            {'path': currentPath, 'name': currentName},
                            proposedFolders,
                            unmatchedFiles,
                          );
                        },
                      ),
                    ),
                  ] else if (hasFiles && !canSplit) ...[
                    Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Colors.orange.withOpacity(0.3),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.info_outline,
                            color: Colors.orange,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${unmatchedFiles.length} file(s) found but no disc numbers detected',
                              style: const TextStyle(
                                color: Colors.orange,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  if (subfolders.isNotEmpty) ...[
                    Text(
                      subfolders.isNotEmpty && (canSplit || hasFiles)
                          ? 'Or navigate to a subfolder:'
                          : 'Select a subfolder:',
                      style: TextStyle(color: Colors.grey[400], fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    ...subfolders.map(
                      (subfolder) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          dense: true,
                          leading: Icon(
                            Icons.folder,
                            color: (subfolder['has_cue'] == true)
                                ? Colors.purple
                                : Colors.blue,
                          ),
                          title: Text(
                            subfolder['name'] as String,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                            ),
                          ),
                          subtitle: Row(
                            children: [
                              if (subfolder['has_cue'] == true)
                                Container(
                                  margin: const EdgeInsets.only(right: 6),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.purple.withOpacity(0.3),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: const Text(
                                    'CUE',
                                    style: TextStyle(
                                      color: Colors.purple,
                                      fontSize: 9,
                                    ),
                                  ),
                                ),
                              Text(
                                '${subfolder['audio_count']} audio files',
                                style: const TextStyle(
                                  color: Colors.grey,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                          trailing: const Icon(
                            Icons.chevron_right,
                            color: Colors.grey,
                            size: 20,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          tileColor: const Color(0xFF0d1b2a),
                          onTap: () {
                            Navigator.pop(context);
                            _showFolderNavigator(
                              subfolder['path'] as String,
                              subfolder['name'] as String,
                            );
                          },
                        ),
                      ),
                    ),
                  ],

                  if (subfolders.isEmpty && !hasFiles)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0d1b2a),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.info_outline, color: Colors.grey),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'This folder is empty or has no audio files',
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                  // Move Up option for subfolders
                  const SizedBox(height: 16),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.cyan.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.cyan.withOpacity(0.3)),
                    ),
                    child: ListTile(
                      dense: true,
                      leading: const Icon(
                        Icons.drive_file_move,
                        color: Colors.cyan,
                      ),
                      title: const Text(
                        'Move this folder up one level',
                        style: TextStyle(color: Colors.cyan, fontSize: 13),
                      ),
                      subtitle: const Text(
                        'With optional rename (e.g. to CD3)',
                        style: TextStyle(color: Colors.cyan, fontSize: 11),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        _showMoveUpDialog(currentPath, currentName);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _showMoveUpDialog(String folderPath, String currentName) {
    final controller = TextEditingController(text: currentName);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: const Row(
          children: [
            Icon(Icons.drive_file_move, color: Colors.cyan),
            SizedBox(width: 8),
            Text('Move Folder Up'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Move "$currentName" up one level.',
              style: TextStyle(color: Colors.grey[400], fontSize: 13),
            ),
            const SizedBox(height: 16),
            const Text(
              'New folder name:',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                filled: true,
                fillColor: const Color(0xFF0d1b2a),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                hintText: 'e.g. CD3',
                hintStyle: TextStyle(color: Colors.grey[600]),
              ),
              style: const TextStyle(color: Colors.white),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              controller.dispose();
              Navigator.pop(context);
            },
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              final newName = controller.text.trim();
              if (newName.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Please enter a folder name'),
                    backgroundColor: Colors.orange,
                  ),
                );
                return;
              }

              try {
                final result = await _apiService.moveFolderUp(
                  folderPath,
                  newName: newName != currentName ? newName : null,
                );

                if (mounted) {
                  controller.dispose();
                  Navigator.pop(context);

                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Moved to ${result['new_name']}'),
                      backgroundColor: Colors.green,
                    ),
                  );

                  _loadPending();
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            icon: const Icon(Icons.check, size: 18),
            label: const Text('Move'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.cyan,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  void _showSplitPreviewDialog(
    Map<String, dynamic> selectedFolder,
    List<Map<String, dynamic>> proposedFolders,
    List<Map<String, dynamic>> unmatchedFiles,
  ) {
    // Create editable state for folder names
    final folderControllers = <int, TextEditingController>{};
    final folderFiles = <int, List<String>>{};

    for (final folder in proposedFolders) {
      final discNum = folder['disc_number'] as int;
      folderControllers[discNum] = TextEditingController(
        text: folder['folder_name'] as String,
      );
      folderFiles[discNum] = (folder['files'] as List)
          .map((f) => f['name'] as String)
          .toList();
    }

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1a2332),
          title: Row(
            children: [
              const Icon(Icons.auto_fix_high, color: Colors.blue),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Split Preview', style: TextStyle(fontSize: 18)),
                    Text(
                      selectedFolder['name'] as String,
                      style: TextStyle(color: Colors.grey[400], fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (proposedFolders.isNotEmpty) ...[
                    Text(
                      'These files will be moved into new folders:',
                      style: TextStyle(color: Colors.grey[400], fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    ...proposedFolders.map((folder) {
                      final discNum = folder['disc_number'] as int;
                      final files = folder['files'] as List;

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0d1b2a),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Colors.blue.withOpacity(0.3),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.folder,
                                  color: Colors.blue,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: TextField(
                                    controller: folderControllers[discNum],
                                    decoration: InputDecoration(
                                      isDense: true,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 8,
                                          ),
                                      filled: true,
                                      fillColor: const Color(0xFF1a2332),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(6),
                                        borderSide: BorderSide.none,
                                      ),
                                      hintText: 'Folder name',
                                      hintStyle: TextStyle(
                                        color: Colors.grey[600],
                                      ),
                                    ),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            ...files.map(
                              (file) => Padding(
                                padding: const EdgeInsets.only(
                                  left: 28,
                                  top: 4,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      (file['extension'] as String) == '.cue'
                                          ? Icons.queue_music
                                          : Icons.audiotrack,
                                      size: 14,
                                      color:
                                          (file['extension'] as String) ==
                                              '.cue'
                                          ? Colors.purple
                                          : Colors.cyan,
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        file['name'] as String,
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 12,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                  if (unmatchedFiles.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Colors.orange.withOpacity(0.3),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(
                                Icons.warning_amber,
                                color: Colors.orange,
                                size: 18,
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Unmatched files (will not be moved):',
                                style: TextStyle(
                                  color: Colors.orange,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          ...unmatchedFiles.map(
                            (file) => Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                file['name'] as String,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (proposedFolders.isEmpty) ...[
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.info_outline, color: Colors.orange),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Could not detect disc numbers in filenames. Use the manual file manager to organize files.',
                              style: TextStyle(
                                color: Colors.orange,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                for (final c in folderControllers.values) {
                  c.dispose();
                }
                Navigator.pop(context);
              },
              child: const Text('Cancel'),
            ),
            if (proposedFolders.isNotEmpty)
              ElevatedButton.icon(
                onPressed: () async {
                  // Build the folders list for the API
                  final foldersToCreate = <Map<String, dynamic>>[];
                  for (final folder in proposedFolders) {
                    final discNum = folder['disc_number'] as int;
                    final folderName =
                        folderControllers[discNum]?.text.trim() ?? 'CD$discNum';
                    final files = folderFiles[discNum] ?? [];

                    if (folderName.isNotEmpty && files.isNotEmpty) {
                      foldersToCreate.add({
                        'folder_name': folderName,
                        'files': files,
                      });
                    }
                  }

                  if (foldersToCreate.isEmpty) {
                    Navigator.pop(context);
                    return;
                  }

                  try {
                    final result = await _apiService.performImportSplit(
                      selectedFolder['path'] as String,
                      foldersToCreate,
                    );

                    if (mounted) {
                      Navigator.pop(context);

                      final results = result['results'] as List? ?? [];
                      final successCount = results
                          .where((r) => r['success'] == true)
                          .length;

                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Created $successCount folder(s) and moved files',
                          ),
                          backgroundColor: Colors.green,
                        ),
                      );

                      _loadPending();
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Error: $e'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  } finally {
                    for (final c in folderControllers.values) {
                      c.dispose();
                    }
                  }
                },
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Split'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showRenameDiscsDialog(Map<String, dynamic> item) async {
    // Fetch subfolders directly from the API
    try {
      final result = await _apiService.listImportSubfolders(item['path']);
      final subfolders =
          (result['subfolders'] as List?)?.cast<Map<String, dynamic>>() ?? [];

      if (subfolders.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No subfolders found to rename'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      if (!mounted) return;

      // Use all subfolders - user can decide what to rename
      final discFolders = subfolders;

      // Create controllers for each folder with smart suggestions
      final controllers = <String, TextEditingController>{};
      int nextDiscNum = 1;

      for (final subfolder in discFolders) {
        final name = subfolder['name'] as String;

        // Try to detect disc number(s) from folder name
        // Matches: CD1, CD 1, Disc1, CD1-CD2, CD3-CD4, CD 3-4, etc.
        final rangeMatch = RegExp(
          r'(?:CD|Disc|D)\s*(\d+)\s*[-&]\s*(?:CD|Disc|D)?\s*(\d+)',
          caseSensitive: false,
        ).firstMatch(name);

        final singleMatch = RegExp(
          r'(?:CD|Disc|D)\s*(\d+)',
          caseSensitive: false,
        ).firstMatch(name);

        String suggestion;
        if (rangeMatch != null) {
          // It's a range like CD3-CD4
          suggestion = 'CD${rangeMatch.group(1)}-CD${rangeMatch.group(2)}';
          nextDiscNum = int.parse(rangeMatch.group(2)!) + 1;
        } else if (singleMatch != null) {
          // Single disc number detected
          suggestion = 'CD${singleMatch.group(1)}';
          nextDiscNum = int.parse(singleMatch.group(1)!) + 1;
        } else {
          // Fallback to sequential numbering
          suggestion = 'CD$nextDiscNum';
          nextDiscNum++;
        }

        controllers[name] = TextEditingController(text: suggestion);
      }

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF1a2332),
          title: const Row(
            children: [
              Icon(Icons.drive_file_rename_outline, color: Colors.orange),
              SizedBox(width: 8),
              Text('Rename Disc Folders'),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Rename folders to simple disc names for proper detection.',
                    style: TextStyle(color: Colors.grey[400], fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  ...discFolders.asMap().entries.map((entry) {
                    final subfolder = entry.value;
                    final name = subfolder['name'] as String;
                    final audioCount = subfolder['audio_count'] as int? ?? 0;
                    final hasCue = subfolder['has_cue'] as bool? ?? false;

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                flex: 2,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      name,
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 2),
                                    Row(
                                      children: [
                                        if (hasCue)
                                          Container(
                                            margin: const EdgeInsets.only(
                                              right: 6,
                                            ),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 4,
                                              vertical: 1,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.purple.withOpacity(
                                                0.3,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(3),
                                            ),
                                            child: const Text(
                                              'CUE',
                                              style: TextStyle(
                                                color: Colors.purple,
                                                fontSize: 9,
                                              ),
                                            ),
                                          ),
                                        Text(
                                          '$audioCount audio',
                                          style: TextStyle(
                                            color: Colors.grey[600],
                                            fontSize: 10,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 8),
                                child: Icon(
                                  Icons.arrow_forward,
                                  color: Colors.grey,
                                  size: 16,
                                ),
                              ),
                              Expanded(
                                child: TextField(
                                  controller: controllers[name],
                                  decoration: InputDecoration(
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 8,
                                    ),
                                    filled: true,
                                    fillColor: const Color(0xFF0d1b2a),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(6),
                                      borderSide: BorderSide.none,
                                    ),
                                  ),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                for (final c in controllers.values) {
                  c.dispose();
                }
                Navigator.pop(context);
              },
              child: const Text('Cancel'),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                // Build renames list
                final renames = <Map<String, String>>[];
                for (final entry in controllers.entries) {
                  final oldName = entry.key;
                  final newName = entry.value.text.trim();
                  if (newName.isNotEmpty && newName != oldName) {
                    renames.add({'old_name': oldName, 'new_name': newName});
                  }
                }

                if (renames.isEmpty) {
                  Navigator.pop(context);
                  return;
                }

                try {
                  final result = await _apiService.renameImportSubfolders(
                    item['path'],
                    renames,
                  );

                  if (mounted) {
                    Navigator.pop(context);

                    final results = result['results'] as List? ?? [];
                    final successCount = results
                        .where((r) => r['success'] == true)
                        .length;

                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Renamed $successCount folder(s)'),
                        backgroundColor: Colors.green,
                      ),
                    );

                    // Refresh the list
                    _loadPending();
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Error: $e'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                } finally {
                  for (final c in controllers.values) {
                    c.dispose();
                  }
                }
              },
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Rename'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading subfolders: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showCueSplitDialog(Map<String, dynamic> item) {
    final multiDiscInfo = item['multi_disc_info'] as Map<String, dynamic>?;
    final cueVariants = multiDiscInfo?['cue_variants'] as List?;
    String? selectedCue = multiDiscInfo?['selected_cue'] as String?;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1a2332),
          title: const Row(
            children: [
              Icon(Icons.content_cut, color: Colors.purple),
              SizedBox(width: 8),
              Text('CUE Split Required'),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item['folder_name'] ?? '',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                Builder(
                  builder: (context) {
                    final isMultiDisc = multiDiscInfo?['is_multi_disc'] == true;
                    final discCount =
                        (multiDiscInfo?['discs'] as List?)?.length ?? 1;

                    if (isMultiDisc) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'This is a $discCount-disc album with CUE sheets. Each disc needs to be split into individual tracks before importing.',
                            style: const TextStyle(color: Colors.grey),
                          ),
                          const SizedBox(height: 12),
                          ...(multiDiscInfo!['discs'] as List).map(
                            (disc) => Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.album,
                                    size: 16,
                                    color: Colors.purple.withOpacity(0.7),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Disc ${disc['disc_number']}: ${disc['track_count']} tracks',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      );
                    } else {
                      return const Text(
                        'This album contains a single FLAC file with a CUE sheet. It needs to be split into individual tracks before importing.',
                        style: TextStyle(color: Colors.grey),
                      );
                    }
                  },
                ),
                // CUE file selector (when multiple variants exist)
                if (cueVariants != null && cueVariants.length > 1) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'Select CUE File',
                    style: TextStyle(
                      color: Colors.grey,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ...cueVariants.map((variant) {
                    final cuePath = variant['cue_file'] as String? ?? '';
                    final cueName = variant['cue_name'] as String? ?? '';
                    final audioExists = variant['audio_file_exists'] == true;
                    final audioRef = variant['audio_file_ref'] as String?;
                    final hasIsrc = variant['has_isrc'] == true;
                    final trackCount = variant['track_count'] as int? ?? 0;
                    final isSelected = selectedCue == cuePath;

                    return GestureDetector(
                      onTap: () {
                        setDialogState(() {
                          selectedCue = cuePath;
                        });
                      },
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? Colors.purple.withOpacity(0.2)
                              : const Color(0xFF0d1b2a),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isSelected
                                ? Colors.purple
                                : audioExists
                                ? Colors.green.withOpacity(0.3)
                                : Colors.red.withOpacity(0.3),
                            width: isSelected ? 2 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              isSelected
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_off,
                              color: isSelected ? Colors.purple : Colors.grey,
                              size: 20,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    cueName,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 4,
                                    children: [
                                      // Audio file status
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: audioExists
                                              ? Colors.green.withOpacity(0.2)
                                              : Colors.red.withOpacity(0.2),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              audioExists
                                                  ? Icons.check_circle
                                                  : Icons.error,
                                              size: 10,
                                              color: audioExists
                                                  ? Colors.green
                                                  : Colors.red,
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              audioExists
                                                  ? 'Audio found'
                                                  : 'Audio missing',
                                              style: TextStyle(
                                                color: audioExists
                                                    ? Colors.green
                                                    : Colors.red,
                                                fontSize: 10,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      // ISRC badge
                                      if (hasIsrc)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.blue.withOpacity(0.2),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: const Text(
                                            'ISRC',
                                            style: TextStyle(
                                              color: Colors.blue,
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      // Track count
                                      Text(
                                        '$trackCount tracks',
                                        style: TextStyle(
                                          color: Colors.grey[500],
                                          fontSize: 10,
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (audioRef != null) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      'References: $audioRef',
                                      style: TextStyle(
                                        color: Colors.grey[600],
                                        fontSize: 10,
                                        fontStyle: FontStyle.italic,
                                      ),
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
                  }),
                ],
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.purple.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.info_outline,
                        color: Colors.purple,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${item['audio_file_count']} audio file(s) • ${item['size_formatted']}',
                          style: const TextStyle(
                            color: Colors.purple,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton.icon(
              onPressed: () {
                Navigator.pop(context);
                _showImportDialog(item);
              },
              icon: const Icon(Icons.download_done),
              label: const Text('Import As-Is'),
              style: TextButton.styleFrom(foregroundColor: Colors.orange),
            ),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => _CueSplitScreen(
                      item: item,
                      apiService: _apiService,
                      audioPlayerService: widget.audioPlayerService,
                      onComplete: () => _loadPending(),
                      selectedCueFile: selectedCue,
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.content_cut),
              label: const Text('Split Tracks'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.purple,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Map<String, dynamic>> get _filteredPending {
    return _pending.where((item) {
      if (_filterSource != 'all' && item['source'] != _filterSource) {
        return false;
      }
      if (_searchQuery.isNotEmpty) {
        final name = (item['folder_name'] as String? ?? '').toLowerCase();
        if (!name.contains(_searchQuery.toLowerCase())) return false;
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredPending;
    final nasradioCount = _pending
        .where((p) => p['source'] == 'nasradio')
        .length;
    final lidarrCount = _pending.where((p) => p['source'] == 'lidarr').length;
    final duplicateCount = _duplicates.values
        .where((d) => d['in_library'] == true)
        .length;

    // Layout verdict from the shell-level scope (spec §3); the old
    // platform-size heuristic survives only as a scope-less fallback.
    final isDesktop = LayoutScope.maybeOf(context)?.isDesktop ?? !_isMobile;
    if (!isDesktop) {
      return _buildMobileLayout(
        filtered,
        nasradioCount,
        lidarrCount,
        duplicateCount,
      );
    }
    return _buildDesktopLayout(
      filtered,
      nasradioCount,
      lidarrCount,
      duplicateCount,
    );
  }

  Widget _buildMobileLayout(
    List<Map<String, dynamic>> filtered,
    int nasradioCount,
    int lidarrCount,
    int duplicateCount,
  ) {
    return Scaffold(
      backgroundColor: const Color(0xFF0a1929),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 200,
            collapsedHeight: 60,
            pinned: true,
            backgroundColor: const Color(0xFF0d1b2a),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _loadPending,
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              centerTitle: true,
              title: const Text('Import Queue', style: TextStyle(fontSize: 16)),
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF1a2332), Color(0xFF0d1b2a)],
                  ),
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 50, bottom: 40),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildStatItem(
                          Icons.folder,
                          Colors.white,
                          '${_pending.length}',
                          'Total',
                        ),
                        GestureDetector(
                          onTap: () => setState(
                            () => _filterSource = _filterSource == 'nasradio'
                                ? 'all'
                                : 'nasradio',
                          ),
                          child: _buildStatItem(
                            Icons.radio,
                            _filterSource == 'nasradio'
                                ? const Color(0xFF00d4ff)
                                : Colors.green,
                            '$nasradioCount',
                            'NASRadio',
                            selected: _filterSource == 'nasradio',
                          ),
                        ),
                        GestureDetector(
                          onTap: () => setState(
                            () => _filterSource = _filterSource == 'lidarr'
                                ? 'all'
                                : 'lidarr',
                          ),
                          child: _buildStatItem(
                            Icons.music_note,
                            _filterSource == 'lidarr'
                                ? const Color(0xFF00d4ff)
                                : Colors.orange,
                            '$lidarrCount',
                            'Lidarr',
                            selected: _filterSource == 'lidarr',
                          ),
                        ),
                        _buildStatItem(
                          Icons.copy,
                          Colors.red,
                          '$duplicateCount',
                          'Dupes',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          SliverPersistentHeader(
            pinned: true,
            delegate: _ImportSearchBarDelegate(
              searchQuery: _searchQuery,
              onChanged: (value) => setState(() => _searchQuery = value),
              onClear: () {
                _searchController.clear();
                setState(() => _searchQuery = '');
              },
            ),
          ),
          if (duplicateCount > 0)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isDeletingDuplicates ? null : _deleteDuplicates,
                    icon: _isDeletingDuplicates
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.delete_sweep),
                    label: Text(
                      _isDeletingDuplicates
                          ? 'Deleting...'
                          : 'Delete $duplicateCount Duplicates',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          if (_filterSource != 'all' || _searchQuery.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Text(
                      'Showing ${filtered.length} of ${_pending.length}',
                      style: TextStyle(color: Colors.grey[500], fontSize: 12),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _filterSource = 'all';
                          _searchQuery = '';
                          _searchController.clear();
                        });
                      },
                      child: const Text(
                        'Clear filters',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_isLoading)
            const SliverFillRemaining(
              child: Center(
                child: CircularProgressIndicator(color: Color(0xFF00d4ff)),
              ),
            )
          else if (_error != null)
            SliverFillRemaining(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: Colors.red,
                      size: 48,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Error: $_error',
                      style: const TextStyle(color: Colors.red),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _loadPending,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            )
          else if (filtered.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.inbox, size: 64, color: Colors.grey[700]),
                    const SizedBox(height: 16),
                    Text(
                      _pending.isEmpty
                          ? 'No pending imports'
                          : 'No matching imports',
                      style: TextStyle(color: Colors.grey[600], fontSize: 16),
                    ),
                  ],
                ),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: _buildImportCard(filtered[index]),
                ),
                childCount: filtered.length,
              ),
            ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 80)),
        ],
      ),
    );
  }

  Widget _statChip(
    IconData icon,
    Color color,
    String count,
    String label, {
    VoidCallback? onTap,
    bool selected = false,
  }) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: selected
            ? const Color(0xFF00d4ff).withOpacity(0.15)
            : const Color(0xFF1a2332),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: selected
              ? const Color(0xFF00d4ff)
              : Colors.white.withOpacity(0.06),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: selected ? const Color(0xFF00d4ff) : color),
          const SizedBox(width: 6),
          Text(
            count,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(fontSize: 11.5, color: Colors.grey[500]),
          ),
        ],
      ),
    );
    if (onTap == null) return chip;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap, child: chip),
    );
  }

  /// Desktop import queue (DESKTOP_UX_SPEC.md restoration): gutter-
  /// constrained content, search + stat chips in one header row, no
  /// phone tab bar. This method predates the phone port - restored
  /// 2026-08-25 from its decayed stretched-stats form.
  Widget _buildDesktopLayout(
    List<Map<String, dynamic>> filtered,
    int nasradioCount,
    int lidarrCount,
    int duplicateCount,
  ) {
    return Scaffold(
      backgroundColor: const Color(0xFF0a1929),
      appBar: AppBar(
        title: const Text('Import Queue'),
        backgroundColor: const Color(0xFF0d1b2a),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadPending),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1600),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _searchController,
                              decoration: InputDecoration(
                                hintText: 'Search pending imports...',
                                hintStyle:
                                    TextStyle(color: Colors.grey[600]),
                                prefixIcon: const Icon(Icons.search,
                                    color: Color(0xFF00d4ff)),
                                suffixIcon: _searchQuery.isNotEmpty
                                    ? IconButton(
                                        icon: const Icon(Icons.clear,
                                            color: Colors.grey),
                                        onPressed: () {
                                          _searchController.clear();
                                          setState(
                                              () => _searchQuery = '');
                                        },
                                      )
                                    : null,
                                filled: true,
                                fillColor: const Color(0xFF1a2332),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                                contentPadding:
                                    const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 12),
                              ),
                              style: const TextStyle(color: Colors.white),
                              onChanged: (value) =>
                                  setState(() => _searchQuery = value),
                            ),
                          ),
                          const SizedBox(width: 14),
                          _statChip(Icons.folder, Colors.white,
                              '${_pending.length}', 'Total'),
                          const SizedBox(width: 8),
                          _statChip(
                            Icons.radio,
                            Colors.green,
                            '$nasradioCount',
                            'NASRadio',
                            selected: _filterSource == 'nasradio',
                            onTap: () => setState(
                              () => _filterSource =
                                  _filterSource == 'nasradio'
                                      ? 'all'
                                      : 'nasradio',
                            ),
                          ),
                          const SizedBox(width: 8),
                          _statChip(
                            Icons.music_note,
                            Colors.orange,
                            '$lidarrCount',
                            'Lidarr',
                            selected: _filterSource == 'lidarr',
                            onTap: () => setState(
                              () => _filterSource =
                                  _filterSource == 'lidarr'
                                      ? 'all'
                                      : 'lidarr',
                            ),
                          ),
                          const SizedBox(width: 8),
                          _statChip(Icons.copy, Colors.red,
                              '$duplicateCount', 'Duplicates'),
                          if (duplicateCount > 0) ...[
                            const SizedBox(width: 14),
                            ElevatedButton.icon(
                              onPressed: _isDeletingDuplicates
                                  ? null
                                  : _deleteDuplicates,
                              icon: _isDeletingDuplicates
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.delete_sweep,
                                      size: 18),
                              label: Text(
                                _isDeletingDuplicates
                                    ? 'Deleting...'
                                    : 'Delete $duplicateCount',
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.red,
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (_filterSource != 'all' || _searchQuery.isNotEmpty)
                      Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Text(
                              'Showing ${filtered.length} of ${_pending.length}',
                              style: TextStyle(
                                  color: Colors.grey[500], fontSize: 12),
                            ),
                            const Spacer(),
                            TextButton(
                              onPressed: () {
                                setState(() {
                                  _filterSource = 'all';
                                  _searchQuery = '';
                                  _searchController.clear();
                                });
                              },
                              child: const Text(
                                'Clear filters',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    Expanded(
                      child: _isLoading
                          ? const Center(
                              child: CircularProgressIndicator(
                                  color: Color(0xFF00d4ff)),
                            )
                          : _error != null
                              ? Center(
                                  child: Column(
                                    mainAxisAlignment:
                                        MainAxisAlignment.center,
                                    children: [
                                      const Icon(
                                        Icons.error_outline,
                                        color: Colors.red,
                                        size: 48,
                                      ),
                                      const SizedBox(height: 16),
                                      Text(
                                        'Error: $_error',
                                        style: const TextStyle(
                                            color: Colors.red),
                                      ),
                                      const SizedBox(height: 16),
                                      ElevatedButton(
                                        onPressed: _loadPending,
                                        child: const Text('Retry'),
                                      ),
                                    ],
                                  ),
                                )
                              : filtered.isEmpty
                                  ? Center(
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Icon(Icons.inbox,
                                              size: 64,
                                              color: Colors.grey[700]),
                                          const SizedBox(height: 16),
                                          Text(
                                            _pending.isEmpty
                                                ? 'No pending imports'
                                                : 'No matching imports',
                                            style: TextStyle(
                                              color: Colors.grey[600],
                                              fontSize: 16,
                                            ),
                                          ),
                                        ],
                                      ),
                                    )
                                  : RefreshIndicator(
                                      onRefresh: _loadPending,
                                      child: ListView.builder(
                                        padding: const EdgeInsets
                                            .symmetric(horizontal: 16),
                                        itemCount: filtered.length,
                                        itemBuilder: (context, index) =>
                                            _buildImportCard(
                                                filtered[index]),
                                      ),
                                    ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }


  Widget _buildStatItem(
    IconData icon,
    Color color,
    String value,
    String label, {
    bool selected = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: selected
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF00d4ff), width: 2),
            )
          : null,
      child: Column(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(label, style: TextStyle(color: Colors.grey[500], fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildImportCard(Map<String, dynamic> item) {
    final source = item['source'] as String? ?? 'unknown';
    final audioCount = item['audio_file_count'] as int? ?? 0;
    final sizeFormatted = item['size_formatted'] as String? ?? '';
    final sourceColor = source == 'nasradio' ? Colors.green : Colors.orange;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1a2332),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sourceColor.withOpacity(0.3)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        leading: Stack(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: sourceColor.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.folder, color: sourceColor),
            ),
            if (_duplicates[item['path']]?['in_library'] == true)
              Positioned(
                right: 0,
                top: 0,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.copy, color: Colors.white, size: 12),
                ),
              ),
          ],
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                item['folder_name'] ?? '',
                style: const TextStyle(color: Colors.white),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (item['needs_cue_split'] == true)
              Container(
                margin: const EdgeInsets.only(left: 8),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.purple.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.purple.withOpacity(0.5)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.content_cut, size: 12, color: Colors.purple),
                    SizedBox(width: 4),
                    Text(
                      'CUE',
                      style: TextStyle(
                        color: Colors.purple,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: sourceColor.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      source.toUpperCase(),
                      style: TextStyle(
                        color: sourceColor,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.audiotrack, size: 12, color: Colors.grey[500]),
                      const SizedBox(width: 4),
                      Text(
                        '$audioCount',
                        style: TextStyle(color: Colors.grey[500], fontSize: 11),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.storage, size: 12, color: Colors.grey[500]),
                      const SizedBox(width: 4),
                      Text(
                        sizeFormatted,
                        style: TextStyle(color: Colors.grey[500], fontSize: 11),
                      ),
                    ],
                  ),
                ],
              ),
              if (_duplicates[item['path']]?['in_library'] == true) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.grey.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'HAVE: ${_duplicates[item['path']]?['existing_format'] ?? '?'}',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const Icon(
                      Icons.arrow_forward,
                      size: 12,
                      color: Colors.grey,
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: _duplicates[item['path']]?['is_upgrade'] == true
                            ? Colors.green.withOpacity(0.2)
                            : Colors.orange.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'NEW: ${_duplicates[item['path']]?['pending_format'] ?? '?'}',
                        style: TextStyle(
                          color:
                              _duplicates[item['path']]?['is_upgrade'] == true
                              ? Colors.green
                              : Colors.orange,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (_duplicates[item['path']]?['is_upgrade'] == true) ...[
                      const Icon(
                        Icons.arrow_upward,
                        size: 12,
                        color: Colors.green,
                      ),
                      const Text(
                        'UPGRADE',
                        style: TextStyle(
                          color: Colors.green,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, color: Colors.grey),
          color: const Color(0xFF1a2332),
          onSelected: (value) {
            switch (value) {
              case 'import':
                _showImportDialog(item);
                break;
              case 'split':
                _showCueSplitDialog(item);
                break;
              case 'rename_discs':
                _showRenameDiscsDialog(item);
                break;
              case 'organize_files':
                _showOrganizeFilesDialog(item);
                break;
              case 'delete':
                _deleteFolder(item);
                break;
            }
          },
          itemBuilder: (context) => [
            if (item['needs_cue_split'] == true)
              const PopupMenuItem(
                value: 'split',
                child: Row(
                  children: [
                    Icon(Icons.content_cut, color: Colors.purple, size: 20),
                    SizedBox(width: 12),
                    Text('Split CUE', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            if (item['needs_cue_split'] == true || _hasSubfolders(item))
              const PopupMenuItem(
                value: 'rename_discs',
                child: Row(
                  children: [
                    Icon(
                      Icons.drive_file_rename_outline,
                      color: Colors.orange,
                      size: 20,
                    ),
                    SizedBox(width: 12),
                    Text('Rename Discs', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            if (item['needs_cue_split'] == true || _hasSubfolders(item))
              const PopupMenuItem(
                value: 'organize_files',
                child: Row(
                  children: [
                    Icon(Icons.folder_copy, color: Colors.blue, size: 20),
                    SizedBox(width: 12),
                    Text(
                      'Organize Files',
                      style: TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
            PopupMenuItem(
              value: 'import',
              child: Row(
                children: [
                  Icon(
                    (_duplicates[item['path']]?['is_upgrade'] == true)
                        ? Icons.upgrade
                        : Icons.download_done,
                    color: (_duplicates[item['path']]?['is_upgrade'] == true)
                        ? Colors.green
                        : const Color(0xFF00d4ff),
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    (_duplicates[item['path']]?['is_upgrade'] == true)
                        ? 'Upgrade'
                        : 'Import',
                    style: const TextStyle(color: Colors.white),
                  ),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: Row(
                children: [
                  Icon(Icons.delete_outline, color: Colors.red, size: 20),
                  SizedBox(width: 12),
                  Text('Delete', style: TextStyle(color: Colors.red)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showImportDialog(Map<String, dynamic> item) {
    final folderName = item['folder_name'] as String? ?? '';
    String parsedArtist = '';
    String parsedAlbum = '';
    int? parsedYear;

    String clean = folderName;
    final yearMatch = RegExp(r'\(?(19|20)(\d{2})\)?').firstMatch(folderName);
    if (yearMatch != null) {
      parsedYear = int.tryParse(yearMatch.group(1)! + yearMatch.group(2)!);
    }

    clean = clean.replaceAll(RegExp(r'\[.*?\]'), '');
    clean = clean.replaceAll(RegExp(r'\((?:19|20)\d{2}\)'), '');
    clean = clean.replaceAll(RegExp(r'^(?:19|20)\d{2}[.\-_\s]+'), '');
    clean = clean.trim();

    if (clean.contains(' - ')) {
      final parts = clean.split(' - ');
      parsedArtist = parts[0].trim();
      parsedAlbum = parts.sublist(1).join(' - ').trim();
    } else {
      parsedAlbum = clean;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => _ImportDetailScreen(
          item: item,
          initialArtist: parsedArtist,
          initialAlbum: parsedAlbum,
          initialYear: parsedYear,
          apiService: _apiService,
          onImportComplete: () => _loadPending(),
          audioPlayerService: widget.audioPlayerService,
        ),
      ),
    );
  }
}

// ============================================================================
// Import Detail Screen
// ============================================================================

/// Open the import page for a folder that already sits in the downloads
/// folder, e.g. one the artist page just uploaded. [item] is an
/// /api/imports/pending-shaped entry. MBIDs, when known, pre-select the
/// MusicBrainz match so the import lands on the right release group.
Future<void> openImportDetail(
  BuildContext context, {
  required Map<String, dynamic> item,
  required String artist,
  required String album,
  int? year,
  String? artistMbid,
  String? albumMbid,
  required AudioPlayerService audioPlayerService,
  VoidCallback? onImportComplete,
}) {
  return Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) => _ImportDetailScreen(
        item: item,
        initialArtist: artist,
        initialAlbum: album,
        initialYear: year,
        initialArtistMbid: artistMbid,
        initialAlbumMbid: albumMbid,
        apiService: ApiService(),
        onImportComplete: onImportComplete ?? () {},
        audioPlayerService: audioPlayerService,
      ),
    ),
  );
}

class _ImportDetailScreen extends StatefulWidget {
  final Map<String, dynamic> item;
  final String initialArtist;
  final String initialAlbum;
  final int? initialYear;
  final String? initialArtistMbid;
  final String? initialAlbumMbid;
  final ApiService apiService;
  final VoidCallback onImportComplete;
  final AudioPlayerService audioPlayerService;

  const _ImportDetailScreen({
    required this.item,
    required this.initialArtist,
    required this.initialAlbum,
    required this.initialYear,
    this.initialArtistMbid,
    this.initialAlbumMbid,
    required this.apiService,
    required this.onImportComplete,
    required this.audioPlayerService,
  });

  @override
  State<_ImportDetailScreen> createState() => _ImportDetailScreenState();
}

class _ImportDetailScreenState extends State<_ImportDetailScreen> {
  late TextEditingController _artistController;
  late TextEditingController _albumController;
  late TextEditingController _yearController;

  List<Map<String, dynamic>> _mbResults = [];
  int _mbShown = 5;
  // Release-group drill-down (spec §10 point 6): expanded groups and
  // their fetched release lists (null = fetch in flight).
  final Set<String> _rgExpanded = {};
  final Map<String, List<Map<String, dynamic>>?> _rgReleases = {};
  bool _isSearching = false;
  bool _isImporting = false;
  bool _isDeleting = false;
  bool _isOpeningMbSubmit = false;
  String? _selectedArtistMbid;
  String? _selectedAlbumMbid;
  String? _error;
  bool _isReadingTags = false;
  List<String>? _selectedFiles;

  // Desktop layout: the folder's contents inline (best-effort).
  List<Map<String, dynamic>>? _folderFiles;

  // Album editions (ALBUM_EDITIONS_SPEC.md §3): when the duplicate
  // check says "album exists but this is a different mix", offer to
  // attach this import as a new edition of that album.
  Map<String, dynamic>? _mixMatch;
  bool _attachAsEdition = true;

  // Import progress
  io.Socket? _socket;
  int _importProgress = 0;
  int _importTotal = 0;
  String _importMessage = '';

  @override
  void initState() {
    super.initState();
    _artistController = TextEditingController(text: widget.initialArtist);
    _albumController = TextEditingController(text: widget.initialAlbum);
    _yearController = TextEditingController(
      text: widget.initialYear?.toString() ?? '',
    );
    _selectedArtistMbid = widget.initialArtistMbid;
    _selectedAlbumMbid = widget.initialAlbumMbid;

    _connectSocket();

    // Auto-read tags from files (will also auto-search MusicBrainz if successful)
    _readTags();
    _loadFolderFiles();
    _checkMixMatch();
  }

  void _connectSocket() {
    _socket = io.io(
      ApiService.baseHost,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .build(),
    );

    _socket!.on('import_progress', (data) {
      if (mounted) {
        setState(() {
          _importProgress = data['current'] ?? 0;
          _importTotal = data['total'] ?? 0;
          _importMessage = data['message'] ?? '';
        });
      }
    });

    _socket!.connect();
  }

  @override
  void dispose() {
    _socket?.disconnect();
    _socket?.dispose();
    _artistController.dispose();
    _albumController.dispose();
    _yearController.dispose();
    super.dispose();
  }

  /// "Not listed? Add it now" — fetch the file-derived prefill, let the
  /// user edit everything in the modal, then stage the handoff and open
  /// MusicBrainz's release editor for the final submit. The new MBID
  /// comes back through the backend callback (a musicbrainz.mbid file
  /// lands in this staging folder).
  Future<void> _loadFolderFiles() async {
    try {
      final response = await appHttpClient.post(
        Uri.parse('${ApiService.baseUrl}/imports/folder-contents'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'path': widget.item['path'], 'subpath': ''}),
      );
      if (response.statusCode == 200 && mounted) {
        final data = json.decode(response.body);
        setState(() => _folderFiles =
            List<Map<String, dynamic>>.from(data['files'] ?? []));
      }
    } catch (_) {
      // Inline file list is best-effort; the folder card still opens
      // the full browser dialog.
    }
  }

  Future<void> _openMbSubmitModal() async {
    setState(() {
      _isOpeningMbSubmit = true;
      _error = null;
    });
    try {
      final seed = await widget.apiService.getMbSeedData(
        path: widget.item['path'],
      );
      if (!mounted) return;
      setState(() => _isOpeningMbSubmit = false);

      final result = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => MbSubmitDialog(
          data: Map<String, dynamic>.from(seed['data']),
        ),
      );
      if (result == null || !mounted) return;

      final url = await widget.apiService.createMbHandoff(
        Map<String, dynamic>.from(result['data']),
        Map<String, dynamic>.from(seed['target']),
        result['comment'] ?? '',
      );
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Finish on MusicBrainz — NASRadio captures the new MBID '
              'automatically when you submit.',
            ),
            duration: Duration(seconds: 6),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isOpeningMbSubmit = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _searchMusicBrainz() async {
    final artist = _artistController.text.trim();
    final album = _albumController.text.trim();
    if (artist.isEmpty && album.isEmpty) return;

    setState(() {
      _isSearching = true;
      _error = null;
    });

    try {
      final result = await widget.apiService.searchMusicBrainz(artist, album);
      setState(() {
        _mbResults = List<Map<String, dynamic>>.from(result['results'] ?? []);
        _mbShown = 5;
        _isSearching = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isSearching = false;
      });
    }
  }

  Future<void> _readTags() async {
    setState(() {
      _isReadingTags = true;
      _error = null;
    });

    try {
      final result = await widget.apiService.readFolderTags(
        widget.item['path'],
      );
      if (result['success'] == true) {
        setState(() {
          if (result['artist'] != null &&
              result['artist'].toString().isNotEmpty) {
            _artistController.text = result['artist'];
          }
          if (result['album'] != null &&
              result['album'].toString().isNotEmpty) {
            _albumController.text = result['album'];
          }
          if (result['year'] != null && result['year'].toString().isNotEmpty) {
            _yearController.text = result['year'].toString();
          }
          _isReadingTags = false;
        });
        // Auto-search MusicBrainz if we got artist and album — with
        // the CLEAN album name (the search reads the controller now,
        // before the edition suffix lands below).
        if (_artistController.text.isNotEmpty &&
            _albumController.text.isNotEmpty) {
          _searchMusicBrainz();
        }
        _applyEditionSuffix();
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isReadingTags = false;
      });
      _applyEditionSuffix();
    }
  }

  Future<void> _checkMixMatch() async {
    try {
      final result = await widget.apiService.checkImportDuplicates([
        {
          'folder_name': widget.item['folder_name'],
          'path': widget.item['path'],
        }
      ]);
      final match = (result['results'] as Map?)?[widget.item['path']];
      if (mounted &&
          match != null &&
          match['match_type'] == 'different_mix') {
        setState(() => _mixMatch = Map<String, dynamic>.from(match));
      }
    } catch (_) {
      // Best-effort; without it the import simply behaves as before.
    }
  }

  /// Edition label for the attach path — same detection family as the
  /// title suffix and the MB disambiguation prefill.
  String _editionLabelGuess() {
    final source =
        '${widget.item['folder_name'] ?? ''} ${_albumController.text}';
    if (RegExp(r'atmos', caseSensitive: false).hasMatch(source)) {
      return 'Dolby Atmos';
    }
    final m = RegExp(r'\(([^)]+)\)\s*$')
        .firstMatch(_albumController.text.trim());
    if (m != null) return m.group(1)!;
    return 'Alternate mix';
  }

  List<Widget> _editionChoiceSection() {
    final m = _mixMatch;
    if (m == null) return const [];
    return [
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF00d4ff).withOpacity(0.06),
          borderRadius: BorderRadius.circular(8),
          border:
              Border.all(color: const Color(0xFF00d4ff).withOpacity(0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.library_music,
                    size: 16, color: Color(0xFF00d4ff)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "Your library already has '${m['album_title']}' — "
                    'this folder is a different mix.',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _editionChoiceRow(
              true,
              'Add as a new edition of that album',
              'One album page, multiple formats (${_editionLabelGuess()})',
            ),
            _editionChoiceRow(false, 'Import as a separate album', null),
          ],
        ),
      ),
    ];
  }

  Widget _editionChoiceRow(bool value, String title, String? subtitle) {
    final selected = _attachAsEdition == value;
    return InkWell(
      onTap: () => setState(() => _attachAsEdition = value),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
              size: 16,
              color: selected ? const Color(0xFF00d4ff) : Colors.grey[600],
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 12.5)),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      style:
                          TextStyle(fontSize: 10.5, color: Colors.grey[500]),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The album TITLE carries the edition — an Atmos rip imports as
  /// "Thriller (Dolby Atmos)", a separate album from stereo Thriller
  /// (the library's twin-mix naming convention; see the Piano Man
  /// incident). Tags say just "Thriller" because Apple doesn't put
  /// the edition in the album tag; the folder name announces it.
  void _applyEditionSuffix() {
    final source =
        '${widget.item['folder_name'] ?? ''} ${widget.item['path'] ?? ''}';
    if (!RegExp(r'atmos', caseSensitive: false).hasMatch(source)) return;
    final album = _albumController.text.trim();
    if (album.isEmpty ||
        RegExp(r'atmos', caseSensitive: false).hasMatch(album)) {
      return;
    }
    setState(() => _albumController.text = '$album (Dolby Atmos)');
  }

  void _selectMbResult(Map<String, dynamic> result) {
    setState(() {
      _artistController.text = result['artist'] ?? result['artist_name'] ?? '';
      _albumController.text = result['title'] ?? '';
      if (result['year'] != null && result['year'].toString().isNotEmpty) {
        _yearController.text = result['year'].toString();
      }
      _selectedArtistMbid = result['artist_mbid'];
      _selectedAlbumMbid = result['mbid'];
    });
  }

  void _showManualMbidDialog() {
    final artistMbidController = TextEditingController(
      text: _selectedArtistMbid ?? '',
    );
    final albumMbidController = TextEditingController(
      text: _selectedAlbumMbid ?? '',
    );

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: const Row(
          children: [
            Icon(Icons.link, color: Color(0xFF00d4ff)),
            SizedBox(width: 8),
            Text('Manual MBID Link'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter MusicBrainz IDs manually. You can find these on musicbrainz.org',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(height: 16),
              const Text(
                'Artist MBID',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: artistMbidController,
                decoration: InputDecoration(
                  hintText: 'e.g. 12345678-1234-1234-1234-123456789012',
                  hintStyle: TextStyle(color: Colors.grey[700], fontSize: 12),
                  filled: true,
                  fillColor: const Color(0xFF0d1b2a),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              const SizedBox(height: 16),
              const Text(
                'Album/Release Group MBID',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: albumMbidController,
                decoration: InputDecoration(
                  hintText: 'e.g. 12345678-1234-1234-1234-123456789012',
                  hintStyle: TextStyle(color: Colors.grey[700], fontSize: 12),
                  filled: true,
                  fillColor: const Color(0xFF0d1b2a),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.blue, size: 16),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Tip: On MusicBrainz, the MBID is the UUID in the URL after /artist/ or /release-group/',
                        style: TextStyle(color: Colors.blue, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              artistMbidController.dispose();
              albumMbidController.dispose();
              Navigator.pop(context);
            },
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final artistMbid = artistMbidController.text.trim();
              final albumMbid = albumMbidController.text.trim();

              // Basic UUID validation
              final uuidRegex = RegExp(
                r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
                caseSensitive: false,
              );

              if (artistMbid.isNotEmpty && !uuidRegex.hasMatch(artistMbid)) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Invalid Artist MBID format'),
                    backgroundColor: Colors.red,
                  ),
                );
                return;
              }

              if (albumMbid.isNotEmpty && !uuidRegex.hasMatch(albumMbid)) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Invalid Album MBID format'),
                    backgroundColor: Colors.red,
                  ),
                );
                return;
              }

              setState(() {
                if (artistMbid.isNotEmpty) {
                  _selectedArtistMbid = artistMbid;
                }
                if (albumMbid.isNotEmpty) {
                  _selectedAlbumMbid = albumMbid;
                }
              });

              artistMbidController.dispose();
              albumMbidController.dispose();
              Navigator.pop(context);

              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('MBID(s) linked manually'),
                  backgroundColor: Colors.green,
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00d4ff),
              foregroundColor: Colors.black,
            ),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }

  Future<void> _doImport() async {
    final artist = _artistController.text.trim();
    final album = _albumController.text.trim();
    final yearText = _yearController.text.trim();
    final year = yearText.isNotEmpty ? int.tryParse(yearText) : null;

    if (artist.isEmpty || album.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Artist and album are required'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _isImporting = true;
      _error = null;
    });

    try {
      final result = await widget.apiService.importAlbum(
        sourcePath: widget.item['path'],
        artistName: artist,
        albumTitle: album,
        year: year,
        artistMbid: _selectedArtistMbid,
        albumMbid: _selectedAlbumMbid,
        selectedFiles: _selectedFiles,
        attachToAlbumId: (_attachAsEdition && _mixMatch != null)
            ? _mixMatch!['album_id'] as int?
            : null,
        editionLabel: (_attachAsEdition && _mixMatch != null)
            ? _editionLabelGuess()
            : null,
      );

      print('=== IMPORT RESULT ===');
      print(result);
      print('=====================');

      if (result['success'] == true) {
        widget.onImportComplete();
        if (mounted) {
          final albumId = result['album_id'];
          final localImages = result['local_images'] as List<dynamic>? ?? [];

          if (albumId != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  localImages.isNotEmpty
                      ? 'Album imported! Select artwork...'
                      : 'Album imported! Now select artwork...',
                ),
                backgroundColor: Colors.green,
                duration: const Duration(seconds: 1),
              ),
            );
            await showDialog(
              context: context,
              builder: (context) => ArtworkPickerDialog(
                albumId: albumId,
                albumTitle: _albumController.text,
                artistName: _artistController.text,
                localImages: localImages.cast<Map<String, dynamic>>(),
              ),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(result['message'] ?? 'Import complete!'),
                backgroundColor: Colors.green,
              ),
            );
          }
          Navigator.pop(context);
        }
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isImporting = false;
      });
    }
  }

  Future<void> _deleteFolder() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: const Text('Delete Folder?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('This will permanently delete:'),
            const SizedBox(height: 8),
            Text(
              widget.item['folder_name'] ?? '',
              style: const TextStyle(color: Colors.orange, fontSize: 12),
            ),
            const SizedBox(height: 12),
            const Text(
              'This cannot be undone!',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isDeleting = true);

    try {
      final result = await widget.apiService.deleteImportFolder(
        widget.item['path'],
      );
      if (result['success'] == true) {
        print('Import result: $result'); // DEBUG
        print('Local images: ${result['local_images']}'); // DEBUG
        widget.onImportComplete();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Folder deleted'),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.pop(context);
        }
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isDeleting = false;
      });
    }
  }

  void _showFolderContents() async {
    final result = await showDialog<List<String>>(
      context: context,
      builder: (context) => _FileBrowserDialog(
        basePath: widget.item['path'],
        folderName: widget.item['folder_name'] ?? 'Folder',
        apiService: widget.apiService,
      ),
    );

    if (result != null && result.isNotEmpty) {
      setState(() {
        _selectedFiles = result;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Selected ${result.length} files for import'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }


  // ── Import screen layouts (DESKTOP_UX_SPEC.md, screen #8) ─────────
  // One set of section builders, two arrangements: the phone stacks
  // them; the desktop puts the metadata/actions beside the
  // MusicBrainz results instead of stretching fields across 27".

  List<Widget> _formSection() {
    return [
      ..._folderCardSection(),
      ..._metaSection(),
      ..._editionChoiceSection(),
      ..._actionsSection(),
    ];
  }

  List<Widget> _folderCardSection() {
    return [
                  // Source info - tappable to show folder contents
                  GestureDetector(
                    onTap: () => _showFolderContents(),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1a2332),
                        borderRadius: BorderRadius.circular(8),
                        border: _selectedFiles != null
                            ? Border.all(
                                color: const Color(0xFF00d4ff).withOpacity(0.5),
                              )
                            : null,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _selectedFiles != null
                                ? Icons.checklist
                                : Icons.folder,
                            color: _selectedFiles != null
                                ? const Color(0xFF00d4ff)
                                : Colors.orange,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.item['folder_name'] ?? '',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                if (_selectedFiles != null)
                                  Text(
                                    '${_selectedFiles!.length} files selected (tap to change)',
                                    style: const TextStyle(
                                      color: Color(0xFF00d4ff),
                                      fontSize: 12,
                                    ),
                                  )
                                else
                                  Text(
                                    '${widget.item['audio_file_count']} tracks • ${widget.item['size_formatted']}',
                                    style: TextStyle(
                                      color: Colors.grey[500],
                                      fontSize: 12,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (_selectedFiles != null)
                            IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              color: Colors.grey,
                              onPressed: () =>
                                  setState(() => _selectedFiles = null),
                              tooltip: 'Clear selection',
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            )
                          else
                            Icon(
                              Icons.chevron_right,
                              color: Colors.grey[600],
                              size: 20,
                            ),
                        ],
                      ),
                    ),
                  ),
    ];
  }

  List<Widget> _metaSection() {
    return [
                  const SizedBox(height: 16),
                  const Text(
                    'Artist',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _artistController,
                    decoration: InputDecoration(
                      hintText: 'Artist name',
                      filled: true,
                      fillColor: const Color(0xFF1a2332),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    style: const TextStyle(color: Colors.white),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Album',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _albumController,
                    decoration: InputDecoration(
                      hintText: 'Album title',
                      filled: true,
                      fillColor: const Color(0xFF1a2332),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    style: const TextStyle(color: Colors.white),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Year',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _yearController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      hintText: 'Release year',
                      filled: true,
                      fillColor: const Color(0xFF1a2332),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    style: const TextStyle(color: Colors.white),
                  ),
                  const SizedBox(height: 16),
                  if (_selectedAlbumMbid != null || _selectedArtistMbid != null)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.green.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Colors.green.withOpacity(0.3),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(
                                Icons.check_circle,
                                color: Colors.green,
                                size: 16,
                              ),
                              SizedBox(width: 8),
                              Text(
                                'MusicBrainz Matched',
                                style: TextStyle(
                                  color: Colors.green,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          if (_selectedArtistMbid != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              'Artist: ${_selectedArtistMbid!.substring(0, 8)}...',
                              style: TextStyle(
                                color: Colors.grey[500],
                                fontSize: 11,
                              ),
                            ),
                          ],
                          if (_selectedAlbumMbid != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Album: ${_selectedAlbumMbid!.substring(0, 8)}...',
                              style: TextStyle(
                                color: Colors.grey[500],
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
    ];
  }

  List<Widget> _actionsSection() {
    return [
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _isReadingTags ? null : _readTags,
                          icon: _isReadingTags
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.label),
                          label: const Text('Read Tags'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orange,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _isSearching ? null : _searchMusicBrainz,
                          icon: _isSearching
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.search),
                          label: const Text('Search'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1a2332),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: _showManualMbidDialog,
                        icon: const Icon(Icons.link),
                        tooltip: 'Manual MBID',
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0xFF1a2332),
                          foregroundColor: const Color(0xFF00d4ff),
                          padding: const EdgeInsets.all(12),
                        ),
                      ),
                    ],
                  ),
    ];
  }

  List<Widget> _mbResultsSection() {
    return [
                  const SizedBox(height: 16),
                  if (_mbResults.isNotEmpty) ...[
                    const Text(
                      'MusicBrainz Results',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    ..._mbResults
                        .take(_mbShown)
                        .map((result) => _buildMbResultCard(result)),
                    if (_mbResults.length > _mbShown)
                      Center(
                        child: TextButton.icon(
                          onPressed: () => setState(() => _mbShown += 10),
                          icon: const Icon(Icons.expand_more, size: 18),
                          label: Text(
                            'See more (${_mbResults.length - _mbShown} hidden)',
                          ),
                        ),
                      ),
                  ],
                  // The album genuinely isn't on MusicBrainz (common for
                  // spatial/WEB editions) — open the prefilled submission
                  // modal (spec §10).
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed:
                          _isOpeningMbSubmit ? null : _openMbSubmitModal,
                      icon: _isOpeningMbSubmit
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.library_add, size: 18),
                      label: const Text('Not listed? Add it to MusicBrainz'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF00d4ff),
                        side: const BorderSide(color: Color(0xFF00d4ff)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
    ];
  }

  List<Widget> _errorSection() {
    return [
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.error,
                                color: Colors.red,
                                size: 16,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _error!.replaceAll('Exception: ', ''),
                                  style: const TextStyle(
                                    color: Colors.red,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (_error!.contains('already exists')) ...[
                            const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: _isDeleting ? null : _deleteFolder,
                                icon: _isDeleting
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Icon(Icons.delete_forever),
                                label: Text(
                                  _isDeleting
                                      ? 'Deleting...'
                                      : 'Delete Duplicate Folder',
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.red,
                                  foregroundColor: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
    ];
  }

  Widget _mobileBody() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ..._formSection(),
          ..._mbResultsSection(),
          ..._errorSection(),
        ],
      ),
    );
  }

  Widget _panel(String title, List<Widget> children,
      {List<Widget> actions = const []}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: const Color(0xFF101f33),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  style: const TextStyle(
                    color: Color(0xFF00d4ff),
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.3,
                  ),
                ),
              ),
              ...actions,
            ],
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }

  Widget _fileRow(Map<String, dynamic> f) {
    final isDir = f['is_dir'] == true || f['type'] == 'directory';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(isDir ? Icons.folder : Icons.audio_file,
              size: 15,
              color: isDir ? Colors.orange : const Color(0xFF00d4ff)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              f['name']?.toString() ?? '',
              style: const TextStyle(fontSize: 12.5, color: Colors.white70),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (f['size_formatted'] != null)
            Text(
              f['size_formatted'].toString(),
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
        ],
      ),
    );
  }

  /// Fill-height panel: header + a child that expands to the panel's
  /// full height (the child brings its own scrolling). Desktop pattern:
  /// fixed columns, scrolling interiors — no bottom void.
  Widget _panelFill(String title, Widget child,
      {List<Widget> actions = const []}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: const Color(0xFF101f33),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  style: const TextStyle(
                    color: Color(0xFF00d4ff),
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.3,
                  ),
                ),
              ),
              ...actions,
            ],
          ),
          const SizedBox(height: 8),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _mbPanelScrollable() {
    return ListView(
      children: [
        const SizedBox(height: 4),
        if (_mbResults.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              'No matches yet — Read Tags searches automatically, or use '
              'the search button above.',
              style: TextStyle(color: Colors.grey[600], fontSize: 12.5),
              textAlign: TextAlign.center,
            ),
          )
        else ...[
          ..._mbResults.take(_mbShown).map(_buildMbResultCard),
          if (_mbResults.length > _mbShown)
            Center(
              child: TextButton.icon(
                onPressed: () => setState(() => _mbShown += 10),
                icon: const Icon(Icons.expand_more, size: 18),
                label:
                    Text('See more (${_mbResults.length - _mbShown} hidden)'),
              ),
            ),
        ],
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _isOpeningMbSubmit ? null : _openMbSubmitModal,
          icon: _isOpeningMbSubmit
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.library_add, size: 18),
          label: const Text('Not listed? Add it to MusicBrainz'),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF00d4ff),
            side: const BorderSide(color: Color(0xFF00d4ff)),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      ],
    );
  }

  List<Widget> _mbPanelActions() {
    return [
      IconButton(
        onPressed: _isSearching ? null : _searchMusicBrainz,
        icon: _isSearching
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.search, size: 19),
        tooltip: 'Search MusicBrainz',
        color: const Color(0xFF00d4ff),
      ),
      IconButton(
        onPressed: _showManualMbidDialog,
        icon: const Icon(Icons.link, size: 19),
        tooltip: 'Manual MBID',
        color: const Color(0xFF00d4ff),
      ),
    ];
  }

  /// Ultra-wide (>=1700 logical): three full-height columns —
  /// folder + release details | files | MusicBrainz — each with its
  /// own interior scrolling. The width gets USED, not centered-around.
  Widget _desktopThreeColumn() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 2100),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 5,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ..._folderCardSection(),
                      const SizedBox(height: 16),
                      _panel('Release details', [
                        ..._metaSection(),
      ..._editionChoiceSection(),
                        const SizedBox(height: 4),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _isReadingTags ? null : _readTags,
                            icon: _isReadingTags
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.label),
                            label: const Text('Read Tags'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.orange,
                              foregroundColor: Colors.white,
                              padding:
                                  const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                      ]),
                      ..._errorSection(),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                flex: 4,
                child: _panelFill(
                  _folderFiles == null
                      ? 'Files'
                      : 'Files · ${_folderFiles!.length}',
                  _folderFiles == null
                      ? const Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _folderFiles!.length,
                          itemBuilder: (context, i) =>
                              _fileRow(_folderFiles![i]),
                        ),
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                flex: 6,
                child: _panelFill(
                  'MusicBrainz match',
                  _mbPanelScrollable(),
                  actions: _mbPanelActions(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _desktopBody() {
    return MediaQuery.of(context).size.width >= 1700
        ? _desktopThreeColumn()
        : _desktopTwoColumn();
  }

  Widget _desktopTwoColumn() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1500),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 2,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 20, 12, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ..._folderCardSection(),
                    const SizedBox(height: 16),
                    _panel('Release details', [
                      ..._metaSection(),
      ..._editionChoiceSection(),
                      const SizedBox(height: 4),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _isReadingTags ? null : _readTags,
                          icon: _isReadingTags
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : const Icon(Icons.label),
                          label: const Text('Read Tags'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orange,
                            foregroundColor: Colors.white,
                            padding:
                                const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 16),
                    _panel(
                      _folderFiles == null
                          ? 'Files'
                          : 'Files · ${_folderFiles!.length}',
                      [
                        if (_folderFiles == null)
                          const Padding(
                            padding: EdgeInsets.all(14),
                            child: Center(
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              ),
                            ),
                          )
                        else
                          ..._folderFiles!.map(_fileRow),
                      ],
                    ),
                    ..._errorSection(),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Container(width: 1, color: Colors.white10),
            ),
            Expanded(
              flex: 3,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 20, 24, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _panel(
                      'MusicBrainz match',
                      [
                        const SizedBox(height: 4),
                        if (_mbResults.isEmpty)
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(vertical: 24),
                            child: Text(
                              'No matches yet — Read Tags searches '
                              'automatically, or use the search button '
                              'above.',
                              style: TextStyle(
                                  color: Colors.grey[600], fontSize: 12.5),
                              textAlign: TextAlign.center,
                            ),
                          )
                        else ...[
                          ..._mbResults
                              .take(_mbShown)
                              .map(_buildMbResultCard),
                          if (_mbResults.length > _mbShown)
                            Center(
                              child: TextButton.icon(
                                onPressed: () =>
                                    setState(() => _mbShown += 10),
                                icon: const Icon(Icons.expand_more,
                                    size: 18),
                                label: Text(
                                  'See more (${_mbResults.length - _mbShown} hidden)',
                                ),
                              ),
                            ),
                        ],
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _isOpeningMbSubmit
                                ? null
                                : _openMbSubmitModal,
                            icon: _isOpeningMbSubmit
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.library_add, size: 18),
                            label: const Text(
                                'Not listed? Add it to MusicBrainz'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF00d4ff),
                              side: const BorderSide(
                                  color: Color(0xFF00d4ff)),
                              padding: const EdgeInsets.symmetric(
                                  vertical: 12),
                            ),
                          ),
                        ),
                      ],
                      actions: [
                        IconButton(
                          onPressed:
                              _isSearching ? null : _searchMusicBrainz,
                          icon: _isSearching
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : const Icon(Icons.search, size: 19),
                          tooltip: 'Search MusicBrainz',
                          color: const Color(0xFF00d4ff),
                        ),
                        IconButton(
                          onPressed: _showManualMbidDialog,
                          icon: const Icon(Icons.link, size: 19),
                          tooltip: 'Manual MBID',
                          color: const Color(0xFF00d4ff),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0a1929),
      appBar: AppBar(
        title: const Text('Import Album'),
        backgroundColor: const Color(0xFF0d1b2a),
      ),
      body: Column(
        children: [
          Expanded(
            child: (LayoutScope.maybeOf(context)?.isDesktop ?? false)
                ? _desktopBody()
                : _mobileBody(),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(color: Color(0xFF0d1b2a)),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: (LayoutScope.maybeOf(context)?.isDesktop ?? false)
                      ? 560
                      : double.infinity,
                ),
                child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isImporting ? null : _doImport,
                icon: _isImporting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black,
                        ),
                      )
                    : const Icon(Icons.download_done),
                label: Text(
                  _isImporting
                      ? (_importTotal > 0
                            ? 'Importing $_importProgress/$_importTotal'
                            : 'Importing...')
                      : 'Import Album',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00d4ff),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMbResultCard(Map<String, dynamic> result) {
    final isSelected = _selectedAlbumMbid == result['mbid'];
    final coverUrl = result['cover_url'] as String?;
    final rgid = result['mbid'] as String?;
    final expanded = rgid != null && _rgExpanded.contains(rgid);
    final releases = rgid == null ? null : _rgReleases[rgid];

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1a2332),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isSelected ? const Color(0xFF00d4ff) : Colors.transparent,
          width: 2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onTap: () => _selectMbResult(result),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0d1b2a),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: coverUrl != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: Image.network(
                              coverUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) =>
                                  const Icon(
                                    Icons.album,
                                    color: Colors.grey,
                                    size: 24,
                                  ),
                            ),
                          )
                        : const Icon(Icons.album,
                            color: Colors.grey, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          result['title'] ?? '',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${result['artist'] ?? result['artist_name'] ?? 'Unknown'}${result['year'] != null ? ' • ${result['year']}' : ''}${result['type'] != null ? ' • ${result['type']}' : ''}',
                          style: TextStyle(
                              color: Colors.grey[500], fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  if (isSelected)
                    const Icon(Icons.check_circle, color: Color(0xFF00d4ff)),
                  if (rgid != null)
                    IconButton(
                      onPressed: () => _toggleRgExpand(rgid),
                      icon: Icon(
                        expanded ? Icons.expand_less : Icons.expand_more,
                        size: 20,
                      ),
                      color: Colors.grey[500],
                      tooltip: expanded
                          ? 'Hide releases'
                          : 'Show the releases in this group',
                    ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            Container(
              height: 1,
              margin: const EdgeInsets.symmetric(horizontal: 10),
              color: Colors.white.withOpacity(0.06),
            ),
            if (releases == null)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (releases.isEmpty)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'No releases listed in this group.',
                  style: TextStyle(color: Colors.grey[600], fontSize: 11.5),
                ),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 12, 0),
                child: Text(
                  '${releases.length} releases in this group — tap one to '
                  'link it directly:',
                  style: TextStyle(color: Colors.grey[600], fontSize: 10.5),
                ),
              ),
              ...List.generate(
                  releases.length,
                  (i) => _rgReleaseRow(releases[i], i)),
            ],
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }

  void _toggleRgExpand(String rgid) {
    setState(() {
      if (_rgExpanded.contains(rgid)) {
        _rgExpanded.remove(rgid);
        return;
      }
      _rgExpanded.add(rgid);
    });
    if (_rgExpanded.contains(rgid) && !_rgReleases.containsKey(rgid)) {
      _rgReleases[rgid] = null;
      widget.apiService.getMbRgReleases(rgid).then((list) {
        if (mounted) setState(() => _rgReleases[rgid] = list);
      }).catchError((_) {
        if (mounted) setState(() => _rgReleases[rgid] = []);
      });
    }
  }

  /// (icon, color) identity per physical format so the release list
  /// scans by eye instead of blending into a phonebook.
  static (IconData, Color) _formatIdentity(String fmt) {
    final f = fmt.toLowerCase();
    if (f.contains('digital')) {
      return (Icons.cloud_queue, const Color(0xFF00d4ff));
    }
    if (f.contains('vinyl')) return (Icons.album, Colors.orange);
    if (f.contains('sacd')) {
      return (Icons.workspace_premium, const Color(0xFFFFD700));
    }
    if (f.contains('dvd') || f.contains('blu')) {
      return (Icons.movie_outlined, const Color(0xFFB39DDB));
    }
    if (f.contains('cd')) return (Icons.album, const Color(0xFF90A4AE));
    if (f.contains('cassette')) {
      return (Icons.voicemail, const Color(0xFFA1887F));
    }
    return (Icons.category_outlined, const Color(0xFF78909C));
  }

  Widget _rgReleaseRow(Map<String, dynamic> r, int index) {
    final selected = _selectedAlbumMbid == r['id'];
    final dis = (r['disambiguation'] ?? '') as String;
    final formats = (r['formats'] as List?)?.cast<String>() ?? const [];
    final fmtText = formats.join(', ');
    final (fmtIcon, fmtColor) = _formatIdentity(
        formats.isEmpty ? '' : formats.first);
    final date = (r['date'] ?? '') as String;
    final tail = [
      if ((r['track_count'] ?? 0) != 0) '${r['track_count']} trk',
      if ((r['country'] ?? '') != '') r['country'],
    ].join(' • ');

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      decoration: BoxDecoration(
        color: selected
            ? const Color(0xFF00d4ff).withOpacity(0.08)
            : index.isOdd
                ? Colors.white.withOpacity(0.025)
                : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () {
          setState(() => _selectedAlbumMbid = r['id'] as String?);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Linked release: ${r['title']}'
                '${dis.isNotEmpty ? ' ($dis)' : ''}',
              ),
              duration: const Duration(seconds: 2),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                size: 13,
                color:
                    selected ? const Color(0xFF00d4ff) : Colors.grey[700],
              ),
              const SizedBox(width: 10),
              Icon(fmtIcon, size: 14, color: fmtColor),
              const SizedBox(width: 8),
              SizedBox(
                width: 78,
                child: Text(
                  date.isEmpty ? '—' : date,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: date.isEmpty ? Colors.grey[700] : Colors.white70,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: fmtText.isEmpty ? 'Unknown format' : fmtText,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: fmtColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (tail.isNotEmpty)
                        TextSpan(
                          text: '  ·  $tail',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey[500],
                          ),
                        ),
                    ],
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (dis.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00d4ff).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    dis,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xFF00d4ff),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// CUE Split Screen
// ============================================================================

class _CueSplitScreen extends StatefulWidget {
  final Map<String, dynamic> item;
  final ApiService apiService;
  final AudioPlayerService audioPlayerService;
  final VoidCallback onComplete;
  final String? selectedCueFile;

  const _CueSplitScreen({
    required this.item,
    required this.apiService,
    required this.audioPlayerService,
    required this.onComplete,
    this.selectedCueFile,
  });

  @override
  State<_CueSplitScreen> createState() => _CueSplitScreenState();
}

class _CueSplitScreenState extends State<_CueSplitScreen> {
  List<Map<String, dynamic>> _tracks = [];
  bool _isLoading = true;
  bool _isSplitting = false;
  bool _isSearchingMb = false;
  bool _isFetchingTracks = false;
  String? _error;
  int _splitProgress = 0;
  int _splitTotal = 0;
  String _splitMessage = '';
  io.Socket? _socket;
  String? _albumPerformer;
  String? _albumTitle;
  List<Map<String, dynamic>> _mbResults = [];
  bool _hasGenericTitles = false;

  @override
  void initState() {
    super.initState();
    _loadCueInfo();
    _connectSocket();
  }

  @override
  void dispose() {
    _socket?.disconnect();
    _socket?.dispose();
    super.dispose();
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
      print('CUE split socket connected');
    });

    _socket!.onConnectError((error) {
      print('CUE split socket error: $error');
    });

    _socket!.onConnect((_) {
      if (mounted) {
        setState(() {
          _splitMessage = 'Socket connected, waiting for progress...';
        });
      }
    });

    _socket!.on('cue_split_progress', (data) {
      if (mounted) {
        setState(() {
          if (data['status'] == 'cancelled') {
            _isSplitting = false;
            _splitMessage = '';
            _splitProgress = 0;
            _splitTotal = 0;
          } else {
            _splitProgress = data['current'] ?? 0;
            _splitTotal = data['total'] ?? 0;
            _splitMessage = data['message'] ?? '';
          }
        });
      }
    });

    _socket!.connect();
  }

  Future<void> _loadCueInfo() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Check if this is a multi-disc album
      final multiDiscInfo =
          widget.item['multi_disc_info'] as Map<String, dynamic>?;
      final isMultiDisc = multiDiscInfo?['is_multi_disc'] == true;

      if (isMultiDisc && multiDiscInfo != null) {
        // For multi-disc, parse each CUE file and combine tracks
        final discs = List<Map<String, dynamic>>.from(
          multiDiscInfo['discs'] ?? [],
        );
        final allTracks = <Map<String, dynamic>>[];
        String? firstPerformer;
        String? firstTitle;

        for (final disc in discs) {
          final cueFile = disc['cue_file'] as String?;
          if (cueFile == null) continue;

          // Parse this disc's CUE file
          final result = await widget.apiService.parseCueFile(
            widget.item['path'],
            cueFile: cueFile,
          );

          if (result['success'] == true) {
            final discTracks = List<Map<String, dynamic>>.from(
              result['tracks'] ?? [],
            );
            final discNumber = disc['disc_number'] as int? ?? 1;

            // Add disc number to each track
            for (final track in discTracks) {
              track['disc_number'] = discNumber;
              allTracks.add(track);
            }

            // Capture album info from first disc
            firstPerformer ??= result['album_performer'];
            firstTitle ??= result['album_title'];
          }
        }

        // Check for generic titles
        int genericCount = 0;
        for (final track in allTracks) {
          final title = (track['title'] as String? ?? '').toLowerCase();
          if (title.isEmpty ||
              RegExp(r'^track\s*\d+$').hasMatch(title) ||
              RegExp(r'^audio\s*track\s*\d+$').hasMatch(title)) {
            genericCount++;
          }
        }

        setState(() {
          _tracks = allTracks;
          _albumPerformer = firstPerformer;
          _albumTitle = firstTitle;
          _hasGenericTitles = genericCount > allTracks.length / 2;
          _isLoading = false;
        });

        if (_hasGenericTitles &&
            (firstPerformer != null || firstTitle != null)) {
          _searchMusicBrainz();
        }
      } else {
        // Single disc - use selected CUE file if provided
        final result = await widget.apiService.parseCueFile(
          widget.item['path'],
          cueFile: widget.selectedCueFile,
        );
        if (result['success'] == true) {
          final tracks = List<Map<String, dynamic>>.from(
            result['tracks'] ?? [],
          );

          // Check for generic titles like "Track01", "Track 1", etc.
          int genericCount = 0;
          for (final track in tracks) {
            final title = (track['title'] as String? ?? '').toLowerCase();
            if (title.isEmpty ||
                RegExp(r'^track\s*\d+$').hasMatch(title) ||
                RegExp(r'^audio\s*track\s*\d+$').hasMatch(title)) {
              genericCount++;
            }
          }

          setState(() {
            _tracks = tracks;
            _albumPerformer = result['album_performer'];
            _albumTitle = result['album_title'];
            _hasGenericTitles = genericCount > tracks.length / 2;
            _isLoading = false;
          });

          // Auto-search MusicBrainz if we have generic titles and album info
          if (_hasGenericTitles &&
              (_albumPerformer != null || _albumTitle != null)) {
            _searchMusicBrainz();
          }
        } else {
          throw Exception(result['error'] ?? 'Failed to parse CUE file');
        }
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _searchMusicBrainz() async {
    if (_albumPerformer == null && _albumTitle == null) return;

    setState(() {
      _isSearchingMb = true;
    });

    try {
      final result = await widget.apiService.searchMusicBrainz(
        _albumPerformer ?? '',
        _albumTitle ?? '',
      );
      setState(() {
        _mbResults = List<Map<String, dynamic>>.from(result['results'] ?? []);
        _isSearchingMb = false;
      });
    } catch (e) {
      setState(() {
        _isSearchingMb = false;
      });
    }
  }

  Future<void> _applyMbTracks(String releaseGroupId) async {
    setState(() {
      _isFetchingTracks = true;
    });

    try {
      final result = await widget.apiService.getMusicBrainzTracks(
        releaseGroupId,
      );
      if (result['success'] == true) {
        final mbTracks = List<Map<String, dynamic>>.from(
          result['tracks'] ?? [],
        );

        // Update track titles from MusicBrainz
        setState(() {
          for (int i = 0; i < _tracks.length && i < mbTracks.length; i++) {
            _tracks[i]['title'] = mbTracks[i]['title'];
          }
          _hasGenericTitles = false;
          _mbResults = [];
          _isFetchingTracks = false;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Applied ${mbTracks.length} track names from MusicBrainz',
              ),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e) {
      setState(() {
        _isFetchingTracks = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _splitTracks() async {
    setState(() {
      _isSplitting = true;
      _error = null;
    });

    try {
      final result = await widget.apiService.splitCueFile(widget.item['path']);
      if (result['success'] == true) {
        widget.onComplete();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Split ${result['tracks_created']} tracks successfully!',
              ),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.pop(context);
        }
      } else {
        throw Exception(result['error'] ?? 'Failed to split tracks');
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isSplitting = false;
      });
    }
  }

  String _formatDuration(int? seconds) {
    if (seconds == null) return '--:--';
    final mins = seconds ~/ 60;
    final secs = seconds % 60;
    return '$mins:${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0a1929),
      appBar: AppBar(
        title: const Text('Split CUE Tracks'),
        backgroundColor: const Color(0xFF0d1b2a),
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: const Color(0xFF1a2332),
            child: Row(
              children: [
                const Icon(Icons.folder, color: Colors.purple, size: 32),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.item['folder_name'] ?? '',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${widget.item['size_formatted']}',
                        style: TextStyle(color: Colors.grey[500], fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.error, color: Colors.red, size: 48),
                        const SizedBox(height: 16),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          child: Text(
                            _error!.replaceAll('Exception: ', ''),
                            style: const TextStyle(color: Colors.red),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: _loadCueInfo,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.purple.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Colors.purple.withOpacity(0.3),
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.queue_music, color: Colors.purple),
                            const SizedBox(width: 8),
                            Text(
                              '${_tracks.length} tracks found in CUE sheet',
                              style: const TextStyle(
                                color: Colors.purple,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Generic titles warning and MusicBrainz lookup
                      if (_hasGenericTitles) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.orange.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: Colors.orange.withOpacity(0.3),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(
                                children: [
                                  Icon(
                                    Icons.warning_amber,
                                    color: Colors.orange,
                                    size: 20,
                                  ),
                                  SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Generic track names detected',
                                      style: TextStyle(
                                        color: Colors.orange,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _albumPerformer != null || _albumTitle != null
                                    ? 'Detected: ${_albumPerformer ?? "Unknown"} - ${_albumTitle ?? "Unknown"}'
                                    : 'The CUE sheet has generic titles.',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'Look up real track names from MusicBrainz?',
                                style: TextStyle(
                                  color: Colors.grey,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 12),
                              if (_isSearchingMb)
                                const Center(
                                  child: SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              else if (_mbResults.isNotEmpty)
                                ..._mbResults
                                    .take(3)
                                    .map(
                                      (result) => GestureDetector(
                                        onTap: _isFetchingTracks
                                            ? null
                                            : () => _applyMbTracks(
                                                result['mbid'],
                                              ),
                                        child: Container(
                                          margin: const EdgeInsets.only(
                                            bottom: 8,
                                          ),
                                          padding: const EdgeInsets.all(10),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF1a2332),
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          child: Row(
                                            children: [
                                              Container(
                                                width: 40,
                                                height: 40,
                                                decoration: BoxDecoration(
                                                  color: const Color(
                                                    0xFF0d1b2a,
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                ),
                                                child: const Icon(
                                                  Icons.album,
                                                  color: Colors.grey,
                                                  size: 24,
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      result['title'] ?? '',
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 13,
                                                      ),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                    Text(
                                                      '${result['artist'] ?? 'Unknown'}${result['year'] != null ? ' • ${result['year']}' : ''}',
                                                      style: TextStyle(
                                                        color: Colors.grey[500],
                                                        fontSize: 11,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              if (_isFetchingTracks)
                                                const SizedBox(
                                                  width: 20,
                                                  height: 20,
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                      ),
                                                )
                                              else
                                                const Icon(
                                                  Icons.chevron_right,
                                                  color: Colors.grey,
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    )
                              else
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton.icon(
                                    onPressed: _searchMusicBrainz,
                                    icon: const Icon(Icons.search, size: 18),
                                    label: const Text('Search MusicBrainz'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.orange,
                                      foregroundColor: Colors.white,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      const SizedBox(height: 4),
                      ..._tracks.asMap().entries.expand((entry) {
                        final index = entry.key;
                        final track = entry.value;
                        final discNumber = track['disc_number'] as int?;
                        final prevDiscNumber = index > 0
                            ? _tracks[index - 1]['disc_number'] as int?
                            : null;
                        final showDiscHeader =
                            discNumber != null &&
                            (index == 0 || discNumber != prevDiscNumber);

                        return [
                          // Disc header when disc number changes
                          if (showDiscHeader)
                            Container(
                              margin: EdgeInsets.only(
                                top: index == 0 ? 0 : 16,
                                bottom: 8,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.cyan.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: Colors.cyan.withOpacity(0.3),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.album,
                                    color: Colors.cyan,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Disc $discNumber',
                                    style: const TextStyle(
                                      color: Colors.cyan,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '(${_tracks.where((t) => t['disc_number'] == discNumber).length} tracks)',
                                    style: TextStyle(
                                      color: Colors.cyan.withOpacity(0.7),
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          // Track item
                          Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1a2332),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: Colors.purple.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Center(
                                    child: Text(
                                      '${track['number'] ?? index + 1}',
                                      style: const TextStyle(
                                        color: Colors.purple,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        track['title'] ?? 'Track ${index + 1}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                      ),
                                      if (track['performer'] != null)
                                        Text(
                                          track['performer'],
                                          style: TextStyle(
                                            color: Colors.grey[500],
                                            fontSize: 12,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                Text(
                                  _formatDuration(track['duration']),
                                  style: TextStyle(
                                    color: Colors.grey[500],
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ];
                      }),
                    ],
                  ),
          ),
          if (!_isLoading && _error == null && _tracks.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(color: Color(0xFF0d1b2a)),
              child: Row(
                children: [
                  if (_isSplitting)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: SizedBox(
                        height: 48,
                        child: ElevatedButton(
                          onPressed: () async {
                            await widget.apiService.cancelCueSplit();
                            setState(() {
                              _isSplitting = false;
                              _splitMessage = '';
                            });
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade700,
                            foregroundColor: Colors.white,
                          ),
                          child: const Icon(Icons.stop),
                        ),
                      ),
                    ),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _isSplitting ? null : _splitTracks,
                      icon: _isSplitting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.content_cut),
                      label: Text(
                        _isSplitting
                            ? 'Splitting... $_splitProgress/$_splitTotal'
                            : 'Split into ${_tracks.length} Tracks',
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.purple,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ============================================================================
// Search Bar Delegate
// ============================================================================

class _ImportSearchBarDelegate extends SliverPersistentHeaderDelegate {
  final String searchQuery;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  _ImportSearchBarDelegate({
    required this.searchQuery,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      color: const Color(0xFF0d1b2a),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: TextField(
        onChanged: onChanged,
        decoration: InputDecoration(
          hintText: 'Search pending imports...',
          hintStyle: TextStyle(color: Colors.grey[600]),
          prefixIcon: const Icon(Icons.search, color: Color(0xFF00d4ff)),
          suffixIcon: searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, color: Colors.grey),
                  onPressed: onClear,
                )
              : null,
          filled: true,
          fillColor: const Color(0xFF1a2332),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 0),
        ),
      ),
    );
  }

  @override
  double get maxExtent => 56;

  @override
  double get minExtent => 56;

  @override
  bool shouldRebuild(covariant _ImportSearchBarDelegate oldDelegate) =>
      searchQuery != oldDelegate.searchQuery;
}

// ============================================================================
// File Browser Dialog
// ============================================================================

class _FileBrowserDialog extends StatefulWidget {
  final String basePath;
  final String folderName;
  final ApiService apiService;

  const _FileBrowserDialog({
    required this.basePath,
    required this.folderName,
    required this.apiService,
  });

  @override
  State<_FileBrowserDialog> createState() => _FileBrowserDialogState();
}

class _FileBrowserDialogState extends State<_FileBrowserDialog> {
  String _currentSubpath = '';
  List<Map<String, dynamic>> _files = [];
  List<Map<String, dynamic>> _breadcrumbs = [];
  final Set<String> _selectedFiles = {};
  List<String> _formatsFound = [];
  String? _activeFormatFilter;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadContents();
  }

  Future<void> _loadContents([String? subpath]) async {
    setState(() {
      _isLoading = true;
      _error = null;
      if (subpath != null) {
        _currentSubpath = subpath;
      }
    });

    try {
      final response = await appHttpClient.post(
        Uri.parse('${ApiService.baseUrl}/imports/folder-contents'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'path': widget.basePath,
          'subpath': _currentSubpath,
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _files = List<Map<String, dynamic>>.from(data['files'] ?? []);
          _breadcrumbs = List<Map<String, dynamic>>.from(
            data['breadcrumbs'] ?? [],
          );
          _formatsFound = List<String>.from(data['formats_found'] ?? []);
          _isLoading = false;
        });
      } else {
        throw Exception('Failed to load folder contents');
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _navigateToFolder(String subpath) {
    _selectedFiles.clear();
    _activeFormatFilter = null;
    _loadContents(subpath);
  }

  void _navigateUp() {
    if (_currentSubpath.isEmpty) return;
    final parts = _currentSubpath.split(Platform.pathSeparator);
    parts.removeLast();
    _navigateToFolder(parts.join(Platform.pathSeparator));
  }

  void _toggleFileSelection(String path) {
    setState(() {
      if (_selectedFiles.contains(path)) {
        _selectedFiles.remove(path);
      } else {
        _selectedFiles.add(path);
      }
    });
  }

  void _selectAllAudio() {
    setState(() {
      for (final file in _files) {
        if (file['is_directory'] != true && _isAudioFile(file['extension'])) {
          if (_activeFormatFilter == null ||
              file['extension'].toString().toUpperCase().replaceAll('.', '') ==
                  _activeFormatFilter) {
            _selectedFiles.add(file['path']);
          }
        }
      }
    });
  }

  void _deselectAll() {
    setState(() {
      _selectedFiles.clear();
    });
  }

  void _filterByFormat(String? format) {
    setState(() {
      _activeFormatFilter = format;
      _selectedFiles.clear();
      if (format != null) {
        for (final file in _files) {
          if (file['is_directory'] != true &&
              file['extension'].toString().toUpperCase().replaceAll('.', '') ==
                  format) {
            _selectedFiles.add(file['path']);
          }
        }
      }
    });
  }

  bool _isAudioFile(String? ext) {
    if (ext == null) return false;
    return [
      '.flac',
      '.mp3',
      '.m4a',
      '.wav',
      '.ogg',
      '.opus',
      '.ape',
      '.wv',
      '.aiff',
      '.aif',
    ].contains(ext.toLowerCase());
  }

  void _showCueContents(String path) async {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: Row(
          children: [
            const Icon(Icons.queue_music, color: Colors.purple),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                path.split(Platform.pathSeparator).last,
                style: const TextStyle(fontSize: 14),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: FutureBuilder<Map<String, dynamic>>(
            future: widget.apiService.readCueContents(path),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(
                  child: CircularProgressIndicator(color: Color(0xFF00d4ff)),
                );
              }
              if (snapshot.hasError) {
                return Center(
                  child: Text(
                    'Error: ${snapshot.error}',
                    style: const TextStyle(color: Colors.red),
                  ),
                );
              }
              final content = snapshot.data?['content'] ?? '';
              return SingleChildScrollView(
                child: SelectableText(
                  content,
                  style: const TextStyle(
                    color: Colors.white,
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final audioFiles = _files
        .where((f) => f['is_directory'] != true && _isAudioFile(f['extension']))
        .toList();
    final selectedCount = _selectedFiles.length;

    return AlertDialog(
      backgroundColor: const Color(0xFF1a2332),
      contentPadding: EdgeInsets.zero,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.folder_open, color: Colors.orange),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.folderName,
                  style: const TextStyle(fontSize: 16),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (_breadcrumbs.isNotEmpty) ...[
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  InkWell(
                    onTap: () => _navigateToFolder(''),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        'Root',
                        style: TextStyle(
                          color: Color(0xFF00d4ff),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                  ..._breadcrumbs.map(
                    (crumb) => Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 4),
                          child: Icon(
                            Icons.chevron_right,
                            size: 16,
                            color: Colors.grey,
                          ),
                        ),
                        InkWell(
                          onTap: () => _navigateToFolder(crumb['path']),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Text(
                              crumb['name'],
                              style: TextStyle(
                                color: crumb == _breadcrumbs.last
                                    ? Colors.white
                                    : const Color(0xFF00d4ff),
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 450,
        child: Column(
          children: [
            // Format filter chips
            if (_formatsFound.length > 1) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      const Text(
                        'Filter: ',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                      const SizedBox(width: 8),
                      FilterChip(
                        label: const Text('All'),
                        selected: _activeFormatFilter == null,
                        onSelected: (_) => _filterByFormat(null),
                        backgroundColor: const Color(0xFF0d1b2a),
                        selectedColor: const Color(0xFF00d4ff).withOpacity(0.3),
                        labelStyle: TextStyle(
                          color: _activeFormatFilter == null
                              ? const Color(0xFF00d4ff)
                              : Colors.grey,
                          fontSize: 12,
                        ),
                        visualDensity: VisualDensity.compact,
                      ),
                      const SizedBox(width: 8),
                      ..._formatsFound.map(
                        (format) => Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: FilterChip(
                            label: Text(format),
                            selected: _activeFormatFilter == format,
                            onSelected: (_) => _filterByFormat(
                              _activeFormatFilter == format ? null : format,
                            ),
                            backgroundColor: const Color(0xFF0d1b2a),
                            selectedColor: _getFormatColor(
                              format,
                            ).withOpacity(0.3),
                            labelStyle: TextStyle(
                              color: _activeFormatFilter == format
                                  ? _getFormatColor(format)
                                  : Colors.grey,
                              fontSize: 12,
                            ),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            // Selection actions
            if (audioFiles.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Text(
                      '$selectedCount selected',
                      style: TextStyle(color: Colors.grey[500], fontSize: 12),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: _selectAllAudio,
                      child: Text(
                        _activeFormatFilter != null
                            ? 'Select All $_activeFormatFilter'
                            : 'Select All',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: _deselectAll,
                      child: const Text(
                        'Deselect',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            const Divider(height: 1, color: Color(0xFF2a3a4a)),
            // File list
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFF00d4ff),
                      ),
                    )
                  : _error != null
                  ? Center(
                      child: Text(
                        'Error: $_error',
                        style: const TextStyle(color: Colors.red),
                      ),
                    )
                  : _files.isEmpty
                  ? const Center(
                      child: Text(
                        'Folder is empty',
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _files.length,
                      itemBuilder: (context, index) =>
                          _buildFileItem(_files[index]),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (_selectedFiles.isNotEmpty)
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(context, _selectedFiles.toList()),
            icon: const Icon(Icons.check, size: 18),
            label: Text('Apply (${_selectedFiles.length} files)'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00d4ff),
              foregroundColor: Colors.black,
            ),
          ),
      ],
    );
  }

  Widget _buildFileItem(Map<String, dynamic> file) {
    final isDir = file['is_directory'] == true;
    final ext = file['extension'] as String? ?? '';
    final isAudio = _isAudioFile(ext);
    final isCue = ext.toLowerCase() == '.cue';
    final isSelected = _selectedFiles.contains(file['path']);
    final formatDisplay = file['format_display'] as String?;

    // Apply format filter
    if (_activeFormatFilter != null && !isDir) {
      final fileFormat = ext.toUpperCase().replaceAll('.', '');
      if (fileFormat != _activeFormatFilter && isAudio) {
        return const SizedBox.shrink();
      }
    }

    return InkWell(
      onTap: isDir
          ? () => _navigateToFolder(
              _currentSubpath.isEmpty
                  ? file['name']
                  : '$_currentSubpath${Platform.pathSeparator}${file['name']}',
            )
          : isCue
          ? () => _showCueContents(file['path'])
          : isAudio
          ? () => _toggleFileSelection(file['path'])
          : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF00d4ff).withOpacity(0.1) : null,
        ),
        child: Row(
          children: [
            // Checkbox for audio files
            if (isAudio && !isDir)
              Checkbox(
                value: isSelected,
                onChanged: (_) => _toggleFileSelection(file['path']),
                activeColor: const Color(0xFF00d4ff),
                visualDensity: VisualDensity.compact,
              )
            else
              const SizedBox(width: 40),
            // Icon
            Icon(
              isDir
                  ? Icons.folder
                  : isAudio
                  ? Icons.audiotrack
                  : isCue
                  ? Icons.queue_music
                  : Icons.insert_drive_file,
              color: isDir
                  ? Colors.orange
                  : isAudio
                  ? _getFormatColor(ext.toUpperCase().replaceAll('.', ''))
                  : isCue
                  ? Colors.purple
                  : Colors.grey,
              size: 20,
            ),
            const SizedBox(width: 12),
            // File info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file['name'] ?? '',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (isDir &&
                      file['audio_count'] != null &&
                      file['audio_count'] > 0)
                    Text(
                      '${file['audio_count']} audio files',
                      style: TextStyle(color: Colors.grey[600], fontSize: 11),
                    )
                  else if (formatDisplay != null)
                    Text(
                      formatDisplay,
                      style: TextStyle(
                        color: _getFormatColor(
                          ext.toUpperCase().replaceAll('.', ''),
                        ).withOpacity(0.8),
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ),
            // Size / Duration
            if (!isDir)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    file['size_formatted'] ?? '',
                    style: TextStyle(color: Colors.grey[600], fontSize: 11),
                  ),
                  if (file['duration_formatted'] != null)
                    Text(
                      file['duration_formatted'],
                      style: TextStyle(color: Colors.grey[600], fontSize: 11),
                    ),
                ],
              )
            else
              const Icon(Icons.chevron_right, color: Colors.grey, size: 20),
          ],
        ),
      ),
    );
  }

  Color _getFormatColor(String format) {
    switch (format.toUpperCase()) {
      case 'FLAC':
        return const Color(0xFF00d4ff);
      case 'MP3':
        return Colors.orange;
      case 'WAV':
      case 'WAVE':
        return Colors.blue;
      case 'M4A':
      case 'AAC':
        return Colors.purple;
      case 'OGG':
      case 'OPUS':
        return Colors.green;
      case 'WV':
        return const Color(0xFF9C27B0);
      case 'APE':
        return const Color(0xFF8BC34A);
      case 'AIFF':
      case 'AIF':
        return const Color(0xFF03A9F4);
      case 'DSF':
      case 'DFF':
        return const Color(0xFFFFD700);
      default:
        return Colors.grey;
    }
  }
}
