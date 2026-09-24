import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../services/update_service.dart';

/// Banner shown at the top of the app when an update is available.
/// Handles the full lifecycle: info -> download -> install.
class UpdateBanner extends StatefulWidget {
  final UpdateInfo info;

  const UpdateBanner({super.key, required this.info});

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

enum _UpdateState { available, downloading, ready, error }

class _UpdateBannerState extends State<UpdateBanner> {
  _UpdateState _state = _UpdateState.available;
  double _progress = 0.0;
  String? _downloadedPath;
  String? _errorMessage;
  bool _dismissed = false;

  Future<void> _startDownload() async {
    setState(() {
      _state = _UpdateState.downloading;
      _progress = 0.0;
    });

    try {
      final path = await UpdateService.downloadUpdate(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (mounted) {
        setState(() {
          _state = _UpdateState.ready;
          _downloadedPath = path;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = _UpdateState.error;
          _errorMessage = e.toString();
        });
      }
    }
  }

  Future<void> _install() async {
    if (_downloadedPath != null) {
      await UpdateService.applyUpdate(_downloadedPath!);
    }
  }

  void _showChangelog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('What\'s New in v${widget.info.version}'),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: Markdown(
            data: widget.info.changelog,
            shrinkWrap: true,
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
    if (_dismissed) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF00D4FF).withOpacity(0.15),
        border: Border(
          bottom: BorderSide(color: const Color(0xFF00D4FF).withOpacity(0.3)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.system_update, color: Color(0xFF00D4FF), size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _state == _UpdateState.ready
                      ? 'Update v${widget.info.version} ready to install'
                      : 'Update v${widget.info.version} available',
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
              // What's New button
              TextButton(
                onPressed: _showChangelog,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text("What's New", style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 4),
              // Action button (Download / Install / Retry)
              _buildActionButton(),
              const SizedBox(width: 4),
              // Dismiss
              InkWell(
                onTap: () => setState(() => _dismissed = true),
                borderRadius: BorderRadius.circular(12),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.close, size: 16, color: Colors.grey),
                ),
              ),
            ],
          ),
          // Progress bar during download
          if (_state == _UpdateState.downloading)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                children: [
                  LinearProgressIndicator(
                    value: _progress,
                    backgroundColor: Colors.grey.withOpacity(0.2),
                    valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00D4FF)),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${(_progress * 100).toStringAsFixed(0)}%',
                    style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                  ),
                ],
              ),
            ),
          // Error message
          if (_state == _UpdateState.error && _errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Download failed: $_errorMessage',
                style: const TextStyle(fontSize: 11, color: Colors.red),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildActionButton() {
    switch (_state) {
      case _UpdateState.available:
        return ElevatedButton.icon(
          onPressed: _startDownload,
          icon: const Icon(Icons.download, size: 16),
          label: const Text('Download', style: TextStyle(fontSize: 12)),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF00D4FF),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            minimumSize: Size.zero,
          ),
        );
      case _UpdateState.downloading:
        return const SizedBox(
          width: 20, height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case _UpdateState.ready:
        return ElevatedButton.icon(
          onPressed: _install,
          icon: const Icon(Icons.restart_alt, size: 16),
          label: const Text('Install & Relaunch', style: TextStyle(fontSize: 12)),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            minimumSize: Size.zero,
          ),
        );
      case _UpdateState.error:
        return TextButton(
          onPressed: _startDownload,
          child: const Text('Retry', style: TextStyle(fontSize: 12)),
        );
    }
  }
}
