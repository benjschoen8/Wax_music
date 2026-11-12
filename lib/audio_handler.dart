import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';

import 'preview.dart';

class WaxAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  Preview? _preview;

  void attachPreview(Preview p) {
    if (_preview == p) return;
    _preview?.removeListener(_syncState);

    _preview = p;
    p.addListener(_syncState);
    _syncState();
  }

  void sync() => _syncState();

  void _syncState() {
    final p = _preview;
    if (p == null) return;

    final t = p.currentTrack;
    if (t != null) {
      final effectiveDuration = p.duration ?? t.duration;
      final item = MediaItem(
        id: t.id,
        album: (t.album != null && t.album!.isNotEmpty) ? t.album! : 'Wax',
        title: t.title,
        artist: t.author.replaceAll(RegExp(r'\s*-\s*Topic$', caseSensitive: false), ''),
        artUri: _parseArtUri(t.thumb),
        duration: effectiveDuration,
      );
      mediaItem.add(item);
    } else {
      mediaItem.add(null);
    }

    final queueItems = p.queue.map((track) => MediaItem(
      id: track.id,
      album: (track.album != null && track.album!.isNotEmpty) ? track.album! : 'Wax',
      title: track.title,
      artist: track.author.replaceAll(RegExp(r'\s*-\s*Topic$', caseSensitive: false), ''),
      artUri: _parseArtUri(track.thumb),
      duration: track.duration,
    )).toList();

    if (queue.value.length != queueItems.length ||
        (queueItems.isNotEmpty && queue.value.isNotEmpty && queue.value.first.id != queueItems.first.id)) {
      queue.add(queueItems);
    }

    final isPlaying = p.isPlaying;
    final isBuffering = p.loadingId != null;

    final controls = [
      MediaControl.skipToPrevious,
      if (isPlaying) MediaControl.pause else MediaControl.play,
      MediaControl.skipToNext,
    ];

    playbackState.add(PlaybackState(
      controls: controls,
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
        MediaAction.play,
        MediaAction.pause,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: isBuffering
          ? AudioProcessingState.buffering
          : (p.currentTrack != null
              ? AudioProcessingState.ready
              : AudioProcessingState.idle),
      playing: isPlaying,
      updatePosition: p.position,
      bufferedPosition: p.bufferedPosition,
      speed: isPlaying ? p.speed : 0.0,
      queueIndex: p.currentIndex >= 0 ? p.currentIndex : null,
    ));
  }

  @override
  Future<void> play() async {
    await _preview?.resume();
  }

  @override
  Future<void> pause() async {
    await _preview?.pause();
  }

  @override
  Future<void> stop() async {
    await _preview?.pause();
    playbackState.add(playbackState.value.copyWith(
      playing: false,
      processingState: _preview?.currentTrack != null
          ? AudioProcessingState.ready
          : AudioProcessingState.idle,
    ));
    await super.stop();
  }

  @override
  Future<void> skipToNext() async {
    await _preview?.next();
  }

  @override
  Future<void> skipToPrevious() async {
    await _preview?.previous();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    await _preview?.jumpToIndex(index);
  }

  @override
  Future<void> seek(Duration position) async {
    await _preview?.seek(position);
  }

  @override
  Future<void> onTaskRemoved() async {
    // User swiped the app away in the App Switcher / Recent Apps menu
    await stop();
    exit(0);
  }

  @override
  Future<void> onNotificationDeleted() async {
    // User swiped the notification away
    await _preview?.pause();
  }

  static Uri? _parseArtUri(String thumb) {
    final s = thumb.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('http://') || s.startsWith('https://') || s.startsWith('content://')) {
      return Uri.tryParse(s);
    }
    if (s.startsWith('file://')) {
      return Uri.tryParse(s);
    }
    return Uri.file(s);
  }
}
