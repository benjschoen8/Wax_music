import 'dart:async';

import 'package:shazam_identifier/shazam_identifier.dart';

import 'log.dart';

class DetectedMusic {
  final String title;
  final String artist;
  final String? videoId;
  final String? coverArtUrl;

  const DetectedMusic({
    required this.title,
    required this.artist,
    this.videoId,
    this.coverArtUrl,
  });

  /// Direct YouTube watch URL if resolved, otherwise null.
  String? get youtubeUrl => (videoId != null && videoId!.isNotEmpty)
      ? 'https://www.youtube.com/watch?v=$videoId'
      : null;

  /// Canonical search query: "Artist - Title".
  String get searchQuery => '$artist - $title';

  @override
  String toString() => '$artist - $title';
}

class MusicDetectionException implements Exception {
  final String message;
  const MusicDetectionException(this.message);
}

class MusicDetector {
  static MusicRecognitionService? _service;

  static Future<bool> hasPermission() async {
    try {
      final s = _service ??= MusicRecognitionService();
      return await s.hasRecordPermission();
    } catch (e) {
      AppLog.info('MusicDetector permission check failed: $e');
      return false;
    }
  }

  /// Listens to ambient music for ~6s and queries Shazam.
  /// Calls [onStateChange] with status ('listening', 'identifying').
  static Future<DetectedMusic?> detect({
    void Function(String state)? onStateChange,
  }) async {
    final service = MusicRecognitionService();
    _service = service;

    StreamSubscription? sub;
    try {
      sub = service.recognitionStatus.listen((s) {
        if (s.state == RecognitionStatusState.listening) {
          onStateChange?.call('listening');
        } else if (s.state == RecognitionStatusState.processing) {
          onStateChange?.call('identifying');
        }
      });

      final status = await service.recognize();

      return resultFromStatus(status);
    } on MusicDetectionException {
      rethrow;
    } catch (e, st) {
      AppLog.error('MusicDetector exception', e, st);
      throw const MusicDetectionException('recognition_failed');
    } finally {
      await sub?.cancel();
      service.dispose();
      if (_service == service) _service = null;
    }
  }

  static DetectedMusic? resultFromStatus(RecognitionStatus status) {
    if (status.state == RecognitionStatusState.success &&
        status.result != null) {
      final result = status.result!;
      return DetectedMusic(
        title: result.title,
        artist: result.artist,
        videoId: result.videoId,
        coverArtUrl: result.coverArtUrl,
      );
    }
    if (status.state == RecognitionStatusState.noMatch) return null;
    AppLog.info('MusicDetector failed: ${status.message}');
    final permission =
        status.message?.toLowerCase().contains('permission') ?? false;
    throw MusicDetectionException(
      permission ? 'permission' : 'recognition_failed',
    );
  }
}
