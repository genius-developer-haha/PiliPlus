import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

enum ClipFormat {
  mp3('MP3', 'mp3'),
  wav('WAV', 'wav'),
  flac('FLAC', 'flac'),
  m4a('M4A', 'm4a'),
  ogg('OGG', 'ogg'),
  mp4('MP4', 'mp4'),
  mkv('MKV', 'mkv'),
  webm('WebM', 'webm');

  const ClipFormat(this.label, this.extension);

  final String label;
  final String extension;

  bool get isVideo => this == mp4 || this == mkv || this == webm;
}

class ClipExportResult {
  const ClipExportResult.success(this.filePath) : error = null;

  const ClipExportResult.failure(this.error) : filePath = null;

  final String? filePath;
  final String? error;

  bool get isSuccess => filePath != null;
}

Duration? parseTimecode(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final parts = trimmed.split(':');
  if (parts.length > 3) return null;
  double seconds = 0;
  for (final part in parts) {
    final value = double.tryParse(part.trim());
    if (value == null || value < 0) return null;
    seconds = seconds * 60 + value;
  }
  return Duration(milliseconds: (seconds * 1000).round());
}

String formatTimecode(Duration duration) {
  final total = duration.inSeconds;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  String two(int value) => value.toString().padLeft(2, '0');
  return hours > 0
      ? '${two(hours)}:${two(minutes)}:${two(seconds)}'
      : '${two(minutes)}:${two(seconds)}';
}

String _sanitizeFileName(String name) {
  var sanitized = name
      .replaceAll(RegExp(r'\|'), '-')
      .replaceAll(RegExp(r'[\\/:*?"<>]'), ' ')
      .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  while (sanitized.endsWith('.') || sanitized.endsWith(' ')) {
    sanitized = sanitized.substring(0, sanitized.length - 1).trimRight();
  }
  if (sanitized.length > 80) {
    sanitized = sanitized.substring(0, 80).trim();
  }
  return sanitized.isEmpty ? 'clip' : sanitized;
}

class ClipExporter {
  ClipExporter({this.onProgress});

  final void Function(double progress)? onProgress;

  static String? _cachedFfmpegPath;

  static const String _referer = 'https://www.bilibili.com/';
  static const String _userAgent = 'Bilibili Freedoooooom/MarkII';

  Process? _process;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _process?.kill();
  }

  static Future<String?> findFfmpeg() async {
    final cached = _cachedFfmpegPath;
    if (cached != null && File(cached).existsSync()) {
      return cached;
    }
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
      return null;
    }
    final execDir = path.dirname(Platform.resolvedExecutable);
    final localCandidates = [
      path.join(execDir, 'ffmpeg', 'ffmpeg.exe'),
      path.join(execDir, 'ffmpeg.exe'),
      path.join(execDir, 'ffmpeg', 'ffmpeg'),
      path.join(execDir, 'ffmpeg'),
    ];
    for (final candidate in localCandidates) {
      if (File(candidate).existsSync()) {
        _cachedFfmpegPath = candidate;
        return candidate;
      }
    }
    try {
      final result = await Process.run(
        Platform.isWindows ? 'where' : 'which',
        ['ffmpeg'],
      );
      if (result.exitCode == 0) {
        final lines = LineSplitter.split(result.stdout.toString())
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty);
        for (final line in lines) {
          if (File(line).existsSync()) {
            _cachedFfmpegPath = line;
            return line;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  static String sharedHeaders() =>
      'Referer: $_referer\r\nUser-Agent: $_userAgent\r\n';

  Future<ClipExportResult> export({
    required String title,
    required String? videoUrl,
    required String? audioUrl,
    required Duration start,
    required Duration end,
    required ClipFormat format,
    required String outputDir,
  }) async {
    _cancelled = false;

    final executable = await findFfmpeg();
    if (executable == null) {
      return const ClipExportResult.failure(
        'ffmpeg not found. Put ffmpeg.exe in the ffmpeg folder next to the '
        'application or install it into PATH.',
      );
    }

    if (end <= start) {
      return const ClipExportResult.failure('End time must be after start time.');
    }

    final duration = end - start;
    final durationSeconds = duration.inMilliseconds / 1000.0;
    final startSeconds = start.inMilliseconds / 1000.0;
    if (durationSeconds <= 0) {
      return const ClipExportResult.failure('Invalid time range.');
    }

    final hasAudioUrl = audioUrl != null && audioUrl.isNotEmpty;
    final hasVideoUrl = videoUrl != null && videoUrl.isNotEmpty;
    if (!format.isVideo && !hasAudioUrl && !hasVideoUrl) {
      return const ClipExportResult.failure('No playable stream URL available.');
    }
    if (format.isVideo && !hasVideoUrl) {
      return const ClipExportResult.failure('No video stream URL available.');
    }

    final safeStart = formatTimecode(start).replaceAll(':', '-');
    final safeEnd = formatTimecode(end).replaceAll(':', '-');
    final baseName = '${_sanitizeFileName(title)}_$safeStart-$safeEnd';
    final fileName = baseName.toLowerCase().endsWith('.${format.extension}')
        ? baseName
        : '$baseName.${format.extension}';
    final outputDirectory = Directory(outputDir);
    if (!outputDirectory.existsSync()) {
      await outputDirectory.create(recursive: true);
    }
    final outputPath = path.join(outputDir, fileName);

    final headers = sharedHeaders();
    final args = <String>[
      '-hide_banner',
      '-loglevel',
      'error',
      '-nostdin',
      '-y',
      '-progress',
      'pipe:1',
      '-stats_period',
      '0.5',
    ];

    List<String> inputArgs(String url) => [
      '-ss',
      startSeconds.toStringAsFixed(3),
      '-headers',
      headers,
      '-i',
      url,
    ];

    if (format.isVideo) {
      args.addAll(inputArgs(videoUrl!));
      if (hasAudioUrl) {
        args.addAll(inputArgs(audioUrl!));
      }
      args.addAll(['-t', durationSeconds.toStringAsFixed(3)]);
      args.addAll(['-map', '0:v:0']);
      if (hasAudioUrl) {
        args.addAll(['-map', '1:a:0']);
      }
      switch (format) {
        case ClipFormat.mp4:
          args.addAll(['-c:v', 'copy']);
          if (hasAudioUrl) {
            args.addAll(['-c:a', 'aac', '-b:a', '192k']);
          }
          args.addAll(['-movflags', '+faststart']);
          break;
        case ClipFormat.mkv:
          args.addAll(['-c:v', 'copy']);
          if (hasAudioUrl) {
            args.addAll(['-c:a', 'copy']);
          }
          break;
        case ClipFormat.webm:
          args.addAll([
            '-c:v',
            'libvpx-vp9',
            '-crf',
            '32',
            '-b:v',
            '0',
            '-row-mt',
            '1',
          ]);
          if (hasAudioUrl) {
            args.addAll(['-c:a', 'libopus', '-b:a', '128k']);
          }
          break;
        default:
          break;
      }
    } else {
      final sourceUrl = hasAudioUrl ? audioUrl! : videoUrl!;
      args.addAll(inputArgs(sourceUrl));
      args.addAll(['-t', durationSeconds.toStringAsFixed(3)]);
      args.addAll(['-vn', '-sn', '-dn', '-map', '0:a:0']);
      switch (format) {
        case ClipFormat.mp3:
          args.addAll(['-c:a', 'libmp3lame', '-q:a', '2']);
          break;
        case ClipFormat.wav:
          args.addAll(['-c:a', 'pcm_s16le']);
          break;
        case ClipFormat.flac:
          args.addAll(['-c:a', 'flac']);
          break;
        case ClipFormat.m4a:
          args.addAll(['-c:a', 'aac', '-b:a', '192k']);
          break;
        case ClipFormat.ogg:
          args.addAll(['-c:a', 'libvorbis', '-q:a', '5']);
          break;
        default:
          break;
      }
    }
    args.add(outputPath);

    final stderrBuffer = StringBuffer();
    try {
      final process = await Process.start(executable, args);
      _process = process;

      final progressCompleter = Completer<void>();
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (line.startsWith('out_time_us=') ||
            line.startsWith('out_time_ms=')) {
          final micros = int.tryParse(line.split('=').last);
          if (micros != null && durationSeconds > 0) {
            final ratio =
                (micros / 1000000.0 / durationSeconds).clamp(0.0, 1.0);
            onProgress?.call(ratio);
          }
        }
      }, onDone: () {
        if (!progressCompleter.isCompleted) progressCompleter.complete();
      }, onError: (Object _) {
        if (!progressCompleter.isCompleted) progressCompleter.complete();
      });

      process.stderr
          .transform(utf8.decoder)
          .listen(stderrBuffer.write, onError: (Object _) {});

      final exitCode = await process.exitCode;
      _process = null;
      if (_cancelled) {
        await _deletePartial(outputPath);
        return const ClipExportResult.failure('Export cancelled.');
      }
      if (exitCode != 0) {
        await _deletePartial(outputPath);
        final message = stderrBuffer.toString().trim();
        return ClipExportResult.failure(
          message.isEmpty ? 'ffmpeg exited with code $exitCode.' : message,
        );
      }
      if (!File(outputPath).existsSync()) {
        return const ClipExportResult.failure('Output file was not created.');
      }
      onProgress?.call(1.0);
      return ClipExportResult.success(outputPath);
    } catch (e) {
      _process = null;
      await _deletePartial(outputPath);
      return ClipExportResult.failure('Failed to start ffmpeg: $e');
    }
  }

  static Future<void> _deletePartial(String filePath) async {
    try {
      final file = File(filePath);
      if (file.existsSync()) {
        await file.delete();
      }
    } catch (_) {}
  }
}
