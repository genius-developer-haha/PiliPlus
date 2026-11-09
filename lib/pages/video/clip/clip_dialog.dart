import 'dart:io';

import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/services/clip/clip_export_service.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;

const String _outputDirKey = 'clipExportDir';
const String _formatKey = 'clipExportFormat';

String _defaultOutputDir() {
  final profile = Platform.environment['USERPROFILE'];
  if (profile != null && profile.isNotEmpty) {
    return path.join(profile, 'Videos');
  }
  return appSupportDirPath;
}

ClipFormat _loadFormat() {
  final stored = GStorage.setting.get(_formatKey);
  if (stored is String) {
    for (final format in ClipFormat.values) {
      if (format.name == stored) return format;
    }
  }
  return ClipFormat.mp3;
}

String _loadOutputDir() {
  final stored = GStorage.setting.get(_outputDirKey);
  if (stored is String && stored.trim().isNotEmpty) {
    return stored;
  }
  return _defaultOutputDir();
}

Future<void> showClipDialog({
  required BuildContext context,
  required VideoDetailController controller,
  required String title,
  required Duration initialStart,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _ClipDialog(
      controller: controller,
      title: title,
      initialStart: initialStart,
    ),
  );
}

class _ClipDialog extends StatefulWidget {
  const _ClipDialog({
    required this.controller,
    required this.title,
    required this.initialStart,
  });

  final VideoDetailController controller;
  final String title;
  final Duration initialStart;

  @override
  State<_ClipDialog> createState() => _ClipDialogState();
}

class _ClipDialogState extends State<_ClipDialog> {
  late final TextEditingController _startController;
  late final TextEditingController _endController;
  late ClipFormat _format;
  late String _outputDir;

  ClipExporter? _exporter;
  bool _exporting = false;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _startController = TextEditingController(
      text: widget.initialStart.inSeconds > 0
          ? formatTimecode(widget.initialStart)
          : '',
    );
    _endController = TextEditingController();
    _format = _loadFormat();
    _outputDir = _loadOutputDir();
  }

  @override
  void dispose() {
    _startController.dispose();
    _endController.dispose();
    _exporter?.cancel();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    final picked = await FilePicker.getDirectoryPath(
      initialDirectory: Directory(_outputDir).existsSync() ? _outputDir : null,
    );
    if (picked == null || picked.trim().isEmpty) return;
    setState(() => _outputDir = picked);
    GStorage.setting.put(_outputDirKey, picked);
  }

  Future<void> _startExport() async {
    final start = parseTimecode(_startController.text);
    final end = parseTimecode(_endController.text);
    if (start == null) {
      SmartDialog.showToast('Invalid start time, use mm:ss or hh:mm:ss');
      return;
    }
    if (end == null) {
      SmartDialog.showToast('Invalid end time, use mm:ss or hh:mm:ss');
      return;
    }
    if (end <= start) {
      SmartDialog.showToast('End time must be after start time');
      return;
    }
    final videoUrl = widget.controller.videoUrl;
    final audioUrl = widget.controller.audioUrl;
    if (videoUrl == null || videoUrl.isEmpty) {
      SmartDialog.showToast('No available stream, wait for the video to load');
      return;
    }

    setState(() {
      _exporting = true;
      _progress = 0;
    });

    final exporter = ClipExporter(
      onProgress: (value) {
        if (!mounted) return;
        setState(() => _progress = value);
      },
    );
    _exporter = exporter;

    final result = await exporter.export(
      title: widget.title,
      videoUrl: videoUrl,
      audioUrl: audioUrl,
      start: start,
      end: end,
      format: _format,
      outputDir: _outputDir,
    );

    if (!mounted) return;
    setState(() => _exporting = false);
    _exporter = null;

    if (result.isSuccess) {
      Navigator.of(context).pop();
      SmartDialog.showToast('Saved: ${result.filePath}');
    } else {
      SmartDialog.showToast(result.error ?? 'Export failed');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return AlertDialog(
      title: const Row(
        spacing: 8,
        children: [
          Icon(Icons.content_cut, size: 22),
          Text('Clip & Convert'),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Download only the selected time range and convert it with '
              'ffmpeg. Time format: mm:ss or hh:mm:ss.',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              spacing: 12,
              children: [
                Expanded(
                  child: TextField(
                    controller: _startController,
                    enabled: !_exporting,
                    decoration: const InputDecoration(
                      labelText: 'Start',
                      hintText: 'mm:ss',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _endController,
                    enabled: !_exporting,
                    decoration: const InputDecoration(
                      labelText: 'End',
                      hintText: 'mm:ss',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Format',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<ClipFormat>(
                  value: _format,
                  isDense: true,
                  isExpanded: true,
                  items: ClipFormat.values
                      .map(
                        (format) => DropdownMenuItem(
                          value: format,
                          child: Text(
                            format.isVideo
                                ? '${format.label} (video)'
                                : '${format.label} (audio)',
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: _exporting
                      ? null
                      : (value) {
                          if (value == null) return;
                          setState(() => _format = value);
                          GStorage.setting.put(_formatKey, value.name);
                        },
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              spacing: 8,
              children: [
                Expanded(
                  child: Text(
                    _outputDir,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                OutlinedButton(
                  onPressed: _exporting ? null : _pickFolder,
                  child: const Text('Browse'),
                ),
              ],
            ),
            if (_exporting) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 6),
              Text(
                '${(_progress * 100).toStringAsFixed(0)}%',
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            if (_exporting) {
              _exporter?.cancel();
            } else {
              Navigator.of(context).pop();
            }
          },
          child: Text(_exporting ? 'Cancel task' : 'Cancel'),
        ),
        FilledButton.icon(
          onPressed: _exporting ? null : _startExport,
          icon: const Icon(Icons.download, size: 18),
          label: const Text('Download'),
        ),
      ],
    );
  }
}
