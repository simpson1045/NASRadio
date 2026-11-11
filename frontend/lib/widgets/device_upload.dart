import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/api_service.dart';

/// Audio (plus the .cue/.log that come with rips) the import accepts.
const kDeviceUploadExtensions = [
  'flac', 'mp3', 'm4a', 'wav', 'ogg', 'opus', 'aac', 'wma', 'ape', 'wv',
  'aiff', 'aif', 'dsf', 'dff', 'mpc', 'cue', 'log',
];

/// Pick music on THIS device (phone storage; on a PC also its drives and
/// network shares) and upload it into the NASRadio import inbox, the same
/// place downloads land, so the normal import takes it from there.
/// Returns the upload's import item (an /api/imports/pending entry), or null
/// if cancelled or it failed (a snackbar says why).
///
/// [folderName] names the folder in the inbox; null = the picked folder's
/// name, or the picked files' parent folder.
Future<Map<String, dynamic>?> pickAndUploadForImport(
  BuildContext context, {
  String? folderName,
  String? what,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  void say(String m) => messenger.showSnackBar(SnackBar(content: Text(m)));

  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: const Color(0xFF1a2332),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.audio_file_outlined, color: Color(0xFF00d4ff)),
            title: const Text('Pick files', style: TextStyle(color: Colors.white)),
            subtitle: Text(
              what == null ? 'One or more songs' : 'The file(s) for $what',
              style: const TextStyle(color: Colors.white38),
            ),
            onTap: () => Navigator.pop(ctx, 'files'),
          ),
          ListTile(
            leading: const Icon(Icons.folder_open, color: Color(0xFF00d4ff)),
            title: const Text('Pick a folder', style: TextStyle(color: Colors.white)),
            subtitle: Text(
              Platform.isAndroid
                  ? 'A whole album folder (if Android lets the app read it)'
                  : 'A whole album folder, on this PC or a network share',
              style: const TextStyle(color: Colors.white38),
            ),
            onTap: () => Navigator.pop(ctx, 'folder'),
          ),
        ],
      ),
    ),
  );
  if (choice == null) return null;

  final paths = <String>[];
  String? pickedFolder;
  try {
    if (choice == 'folder') {
      pickedFolder = await FilePicker.platform.getDirectoryPath(
        dialogTitle: what == null ? 'Pick a folder' : 'Pick the folder for $what',
      );
      if (pickedFolder == null) return null;
      await for (final e in Directory(pickedFolder).list(recursive: true)) {
        if (e is File &&
            kDeviceUploadExtensions.contains(e.path.split('.').last.toLowerCase())) {
          paths.add(e.path);
        }
      }
      paths.sort();
      if (paths.isEmpty) {
        say(Platform.isAndroid
            ? "Couldn't read music in that folder. Android may be blocking it; pick the files instead."
            : 'No music files in that folder.');
        return null;
      }
    } else {
      final r = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: kDeviceUploadExtensions,
        dialogTitle: what == null ? 'Pick music' : 'Pick the file(s) for $what',
      );
      if (r == null) return null;
      paths.addAll(r.paths.whereType<String>());
      if (paths.isEmpty) return null;
    }
  } catch (e) {
    say("Couldn't open the picker: $e");
    return null;
  }

  String baseName(String p) => p.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).last;
  final name = folderName ??
      (pickedFolder != null
          ? baseName(pickedFolder)
          : baseName(File(paths.first).parent.path));

  // Upload with a progress dialog (can't be dismissed mid-upload).
  final progress = ValueNotifier<double?>(null);
  if (!context.mounted) return null;
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        backgroundColor: const Color(0xFF1b2838),
        title: Text('Uploading ${paths.length} file${paths.length == 1 ? '' : 's'}'),
        content: ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (_, v, __) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: v),
              const SizedBox(height: 8),
              Text(v == null ? 'Starting…' : '${(v * 100).round()}%',
                  style: const TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      ),
    ),
  ));
  Map<String, dynamic>? item;
  try {
    item = await ApiService().uploadImportFiles(
      folder: name,
      paths: paths,
      onProgress: (sent, total) {
        if (total > 0) progress.value = sent / total;
      },
    );
  } catch (e) {
    say('Upload failed: $e');
  } finally {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
  return item;
}
