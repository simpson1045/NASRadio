import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'api_service.dart';
import 'app_logger.dart';

/// Info about an available update
class UpdateInfo {
  final String version;
  final int buildNumber;
  final String changelog;
  final int sizeBytes;
  final String releasedAt;

  UpdateInfo({
    required this.version,
    required this.buildNumber,
    required this.changelog,
    required this.sizeBytes,
    required this.releasedAt,
  });
}

/// Handles checking, downloading, and applying app updates.
class UpdateService {
  UpdateService._();

  /// Check if a newer version is available on the server.
  /// Returns [UpdateInfo] if an update exists, null if up-to-date.
  static Future<UpdateInfo?> checkForUpdate() async {
    final log = AppLogger.instance;
    try {
      // Fetch our own version FIRST so we can tell the server which build we're
      // on — it returns the cumulative changelog for every version between ours
      // and the latest (not just the newest section).
      final info = await PackageInfo.fromPlatform();
      final currentVersion = info.version; // e.g. "1.0.0"
      final currentBuild = int.tryParse(info.buildNumber) ?? 0;

      final response = await http.get(
        Uri.parse('${ApiService.baseHost}/api/update/check?since=$currentBuild'),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body);
      if (data['status'] != 'ok') return null;

      final serverVersion = data['version'] as String? ?? '0.0.0';
      final serverBuild = (data['build_number'] as num?)?.toInt() ?? 0;

      if (!_isNewer(serverVersion, serverBuild, currentVersion, currentBuild)) {
        log.info('App is up to date (v$currentVersion+$currentBuild)');
        return null;
      }

      final sizeKey = Platform.isWindows
          ? 'windows_size'
          : Platform.isLinux
              ? 'linux_size'
              : 'android_size';
      log.info(
        'Update available: v$serverVersion+$serverBuild '
        '(current: v$currentVersion+$currentBuild)',
      );

      return UpdateInfo(
        version: serverVersion,
        buildNumber: data['build_number'] ?? 0,
        changelog: data['changelog'] ?? '',
        sizeBytes: data[sizeKey] ?? 0,
        releasedAt: data['released_at'] ?? '',
      );
    } catch (e) {
      log.warning('Update check failed: $e');
      return null;
    }
  }

  /// Compare versions. Returns true if the server build is newer than the
  /// installed one. Semver is compared first; build number breaks ties when
  /// semver is equal (so 1.0.1+2 → 1.0.1+3 is treated as an update).
  static bool _isNewer(
    String serverVersion,
    int serverBuild,
    String currentVersion,
    int currentBuild,
  ) {
    final s = serverVersion.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final c = currentVersion.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    while (s.length < 3) { s.add(0); }
    while (c.length < 3) { c.add(0); }
    for (var i = 0; i < 3; i++) {
      if (s[i] > c[i]) return true;
      if (s[i] < c[i]) return false;
    }
    return serverBuild > currentBuild;
  }

  /// Download the update file for the current platform.
  /// Calls [onProgress] with 0.0..1.0 as bytes arrive.
  /// Returns the path to the downloaded file.
  static Future<String> downloadUpdate({
    required void Function(double progress) onProgress,
  }) async {
    final log = AppLogger.instance;
    // Backend serves three artifact slots: android/windows/linux. The
    // download endpoint maps these to the file name on disk.
    final String platform;
    final String ext;
    if (Platform.isWindows) {
      platform = 'windows';
      ext = '.zip';
    } else if (Platform.isLinux) {
      platform = 'linux';
      ext = '.tar.xz';
    } else {
      platform = 'android';
      ext = '.apk';
    }

    final request = http.Request(
      'GET',
      Uri.parse('${ApiService.baseHost}/api/update/download/$platform'),
    );

    final client = http.Client();
    try {
      final response = await client.send(request);
      final contentLength = response.contentLength ?? 0;

      final dir = await getTemporaryDirectory();
      final filePath = '${dir.path}/nasradio-update$ext';
      final file = File(filePath);
      final sink = file.openWrite();

      var received = 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (contentLength > 0) {
          onProgress(received / contentLength);
        }
      }
      await sink.close();

      log.info('Update downloaded: $filePath (${(received / 1024 / 1024).toStringAsFixed(1)} MB)');
      return filePath;
    } catch (e) {
      log.error('Update download failed: $e');
      rethrow;
    } finally {
      client.close();
    }
  }

  /// Apply the downloaded update.
  /// - Android: opens the APK with the system installer
  /// - Windows: extracts zip, writes update script, launches it, exits app
  static Future<void> applyUpdate(String filePath) async {
    final log = AppLogger.instance;

    if (Platform.isAndroid) {
      log.info('Opening APK installer...');
      await OpenFilex.open(filePath);
    } else if (Platform.isWindows) {
      await _applyWindowsUpdate(filePath);
    } else if (Platform.isLinux) {
      await _applyLinuxUpdate(filePath);
    }
  }

  /// Windows-specific update: extract zip, write batch script, relaunch.
  ///
  /// The hard part of a Windows in-place update is overwriting the
  /// running .exe and its locked DLLs. Windows holds an exclusive
  /// lock on a running executable, so any copy attempt before the
  /// process has fully released its handles silently skips those
  /// files — and the restart launches the OLD binary unchanged
  /// (which is exactly the "update banner stays after install" bug
  /// simpson1045 was hitting).
  ///
  /// The old script used `xcopy /Y` with a 2-second `timeout` before
  /// the copy. That was too short on a typical desktop with audio
  /// services + several Flutter plugin DLLs to tear down, and
  /// xcopy's exit code doesn't reliably surface "couldn't open
  /// destination" — it returned 0 and the restart launched the
  /// stale build. Replaced with `robocopy /R:30 /W:1` (30 retries,
  /// 1s wait — handles transient locks for up to 30s), a longer
  /// initial wait, and a log file so the next "update didn't take"
  /// can be diagnosed by looking at %TEMP%\\nasradio-update.log.
  static Future<void> _applyWindowsUpdate(String zipPath) async {
    final log = AppLogger.instance;

    final exePath = Platform.resolvedExecutable;
    final installDir = File(exePath).parent.path;
    final tempDir = (await getTemporaryDirectory()).path;
    final extractDir = '$tempDir\\nasradio-update-extracted';

    log.info('Extracting update to $extractDir');

    // Extract zip
    final zipBytes = await File(zipPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(zipBytes);

    final extractDirObj = Directory(extractDir);
    if (await extractDirObj.exists()) {
      await extractDirObj.delete(recursive: true);
    }
    await extractDirObj.create(recursive: true);

    for (final file in archive) {
      final outPath = '$extractDir\\${file.name}';
      if (file.isFile) {
        final outFile = File(outPath);
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(file.content as List<int>);
      } else {
        await Directory(outPath).create(recursive: true);
      }
    }

    // Write update batch script.
    //
    // robocopy notes:
    //   /E  — copy subdirs including empty
    //   /NFL /NDL /NP — suppress per-file/dir/percent spam in the log
    //   /R:30 /W:1 — 30 retries with 1s between (handles "running
    //                exe still has the .exe file locked" by simply
    //                waiting it out; total worst-case wait ~30s)
    //   /XF nasradio-update.bat nasradio-update.log — don't try to
    //                copy our own running script/log over itself
    // robocopy exit codes 0..7 are success (0=nothing copied, 1=files
    // copied OK, 2-7=harmless extras); 8+ are real errors. The bat
    // checks `if errorlevel 8` so a partial-failure surfaces.
    final batPath = '$tempDir\\nasradio-update.bat';
    final logPath = '$tempDir\\nasradio-update.log';
    final exeName = File(exePath).uri.pathSegments.last;
    final batContent = '''@echo off
setlocal enabledelayedexpansion
echo === NASRadio update started at %DATE% %TIME% === > "$logPath"
echo Updating NASRadio...
echo Waiting for nasradio.exe to fully exit and release file locks...
echo Wait phase starting >> "$logPath"
REM Poll for the process exiting. tasklist is cheap (~10ms) and lets
REM us proceed the instant the lock is released instead of guessing
REM with a fixed sleep. Cap at 30s so a wedged process can't hang
REM the update forever.
set /a _waited=0
:wait_for_exit
tasklist /FI "IMAGENAME eq $exeName" 2>nul | find /I "$exeName" >nul
if errorlevel 1 goto exit_done
if !_waited! GEQ 30 goto exit_timeout
timeout /t 1 /nobreak >nul
set /a _waited+=1
goto wait_for_exit
:exit_timeout
echo WARN: $exeName still running after 30s, attempting copy anyway >> "$logPath"
:exit_done
echo Exit-wait done after !_waited!s >> "$logPath"

echo Copying new files from "$extractDir" to "$installDir" ...
echo robocopy starting >> "$logPath"
robocopy "$extractDir" "$installDir" /E /NFL /NDL /NP /R:30 /W:1 ^
  /XF "nasradio-update.bat" "nasradio-update.log" >> "$logPath" 2>&1
set _rc=!errorlevel!
echo robocopy exit code: !_rc! >> "$logPath"

REM robocopy: 0..7 success, 8+ failure.
if !_rc! GEQ 8 (
  echo === UPDATE FAILED — see "$logPath" === >> "$logPath"
  echo NASRadio update FAILED — see "$logPath" for details.
  echo Press any key to close...
  pause >nul
  goto cleanup
)

echo === UPDATE OK === >> "$logPath"
echo Launching updated NASRadio...
start "" "$installDir\\$exeName"

:cleanup
rmdir /S /Q "$extractDir" 2>nul
REM Intentionally NOT deleting "$logPath" — kept so the user can
REM inspect the most recent update attempt if anything looked off.
del "$batPath"
''';

    await File(batPath).writeAsString(batContent);
    log.info('Launching update script and exiting (log: $logPath)...');

    // Launch the batch script through `start` so it gets a REAL console.
    // ProcessStartMode.detached spawns cmd console-less, and in that
    // state the script's `tasklist | find` pipeline wedges forever —
    // find never sees EOF, the window sits empty until the user
    // Ctrl+C's it (which killed find, faked "app exited", and let the
    // update proceed — the bug every desktop update showed for months).
    // `start` allocates a fresh console: pipelines work, the user can
    // actually see the progress echoes, and the window closes itself.
    await Process.start(
      'cmd',
      ['/c', 'start', 'NASRadio Update', 'cmd', '/c', batPath],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }

  /// Linux-specific update: extract tar.xz, write bash script, relaunch.
  ///
  /// Linux is simpler than Windows here because you CAN overwrite a
  /// running ELF (the kernel keeps the old inode for the running
  /// process via the still-open exec fd; the new file just replaces
  /// the dirent). So we don't need a "wait for handles to release"
  /// dance — we can swap in new files immediately, then restart.
  ///
  /// One catch: the artifact ships as `bundle/frontend` + `data/` +
  /// `lib/`. The user's running install lives at
  /// `Platform.resolvedExecutable`'s parent dir (e.g. ~/Apps/NASRadio/).
  /// The tar.xz top-level layout depends on release-linux.sh: we
  /// expect the script to package the bundle's CONTENTS without a
  /// wrapping directory, so extracting straight into the install dir
  /// drops files at the right place. Verified against the
  /// release-linux.sh in backend/release-linux.sh.
  static Future<void> _applyLinuxUpdate(String archivePath) async {
    final log = AppLogger.instance;

    final exePath = Platform.resolvedExecutable;
    final installDir = File(exePath).parent.path;
    final tempDir = (await getTemporaryDirectory()).path;
    final extractDir = '$tempDir/nasradio-update-extracted';
    final scriptPath = '$tempDir/nasradio-update.sh';
    final logPath = '$tempDir/nasradio-update.log';
    final exeName = File(exePath).uri.pathSegments.last;

    // Stage the extract dir cleanly. We invoke `tar` from the script
    // (not here) so a partial-extract from a prior failed update is
    // wiped first.
    log.info('Staging Linux update; extract → $extractDir, install → $installDir');

    // Write the update script. Uses `cp -a` (preserve attributes,
    // recursive) rather than `mv` so a copy-into-existing-dir layout
    // works cleanly with both first-install AND subsequent updates
    // (mv would fail on non-empty subdirs without --backup-and-replace
    // gymnastics). Bash is more tolerant of timing than the Windows
    // equivalent here — the running process can be replaced
    // mid-flight.
    final scriptContent = '''#!/bin/bash
# Auto-generated by NASRadio update_service.dart Linux branch.
# Drops the new artifact onto the existing install, relaunches.
set -u
exec > "$logPath" 2>&1
echo "=== NASRadio update started at \$(date) ==="

# Wait briefly for the previous nasradio process to exit. Not strictly
# required (overwriting a running ELF is legal on Linux) but it gives
# the audio service / GUI a clean shutdown before we restart it.
for i in 1 2 3 4 5; do
  if ! pgrep -x "$exeName" >/dev/null 2>&1; then break; fi
  echo "Waiting for $exeName to exit (attempt \$i)..."
  sleep 1
done

# Wipe + recreate extract dir, untar into it.
echo "Cleaning extract dir..."
rm -rf "$extractDir"
mkdir -p "$extractDir"

echo "Extracting $archivePath..."
tar -xJf "$archivePath" -C "$extractDir"
if [ \$? -ne 0 ]; then
  echo "=== TAR EXTRACT FAILED ==="
  echo "NASRadio update failed during extract. See $logPath" >&2
  exit 1
fi

# Copy contents into install dir. The tar is packaged
# bundle-contents-at-root (no enclosing directory), so a plain `cp -a
# */ <dest>/` works AND a wildcard match catches dotfiles via `.*` is
# not needed (Flutter bundles don't ship dotfiles).
echo "Copying new files to $installDir..."
cp -a "$extractDir"/* "$installDir"/
if [ \$? -ne 0 ]; then
  echo "=== COPY FAILED ==="
  echo "NASRadio update failed during copy. See $logPath" >&2
  exit 1
fi

# Cleanup
rm -rf "$extractDir"
echo "=== UPDATE OK at \$(date) ==="

# Relaunch detached so this script can exit cleanly.
nohup "$installDir/$exeName" </dev/null >/dev/null 2>&1 &
disown

# Self-delete on the way out — script lives in /tmp anyway but no
# point leaving stale copies.
rm -f "$scriptPath"
exit 0
''';

    await File(scriptPath).writeAsString(scriptContent);
    // chmod +x so bash can run it directly.
    await Process.run('chmod', ['+x', scriptPath]);
    log.info('Launching update script and exiting (log: $logPath)...');

    // Launch detached and exit. nohup ensures the script keeps running
    // after our process dies; ProcessStartMode.detached makes Dart not
    // wait for the child.
    await Process.start(
      'bash',
      [scriptPath],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }
}
