import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'browser_auth.dart';
import 'downloader.dart';
import 'log.dart';
import 'models/track.dart';
import 'strings.dart';

/// Full-featured audio player supporting online streaming and instant offline playback.
///
/// If a song is saved locally on disk, Wax plays it with 0ms network latency.
/// If online, it streams directly via YouTube Explode with client rotation and buffering.
class Preview extends ChangeNotifier {
  static const _capBytes =
      1024 * 1024; // 1 MB: fast buffer for ~1.5+ min of audio
  final YoutubeExplode yt;
  final String? Function(String id)? getLocalPath;

  String? loadingId, playingId, error;
  Track? currentTrack;
  File? _current;

  // Queue & Player State
  final List<Track> queue = [];
  int currentIndex = -1;
  bool shuffle = false;
  List<int> _shuffleOrder = [];
  int _shufflePos = 0;
  LoopMode loopMode = LoopMode.off;

  Preview(this.yt, {this.getLocalPath});

  // Created on first use so the audio engine isn't started at app launch.
  AudioPlayer? _p;
  AudioPlayer get _player => _p ??= _createPlayer();

  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<PlayerState> get playerStateStream => _player.playerStateStream;
  Duration get position => _player.position;
  Duration? get duration => _player.duration;
  Duration get bufferedPosition => _p?.bufferedPosition ?? Duration.zero;
  bool get isPlaying => _player.playing;

  bool get hasNext {
    if (queue.isEmpty) return false;
    if (loopMode == LoopMode.all || loopMode == LoopMode.one) return true;
    if (shuffle) return _shufflePos + 1 < _shuffleOrder.length;
    return currentIndex + 1 < queue.length;
  }

  bool get hasPrevious {
    if (queue.isEmpty) return false;
    if (loopMode == LoopMode.all) return true;
    if (shuffle) return _shufflePos > 0;
    return currentIndex > 0;
  }

  Future<void> pause() async {
    await _player.pause();
    notifyListeners();
  }

  Future<void> resume() async {
    await _player.play();
    notifyListeners();
  }

  Future<void> seek(Duration pos) async {
    await _player.seek(pos);
    notifyListeners();
  }

  void toggleShuffle() {
    shuffle = !shuffle;
    if (shuffle) {
      _buildShuffleOrder();
    }
    notifyListeners();
  }

  void cycleLoopMode() {
    loopMode = switch (loopMode) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    notifyListeners();
  }

  Timer? _sleepTimer;
  DateTime? sleepTimerEnd;

  bool get isSleepTimerActive => _sleepTimer != null && _sleepTimer!.isActive;
  int? get sleepTimerMinutesRemaining {
    if (sleepTimerEnd == null) return null;
    final diff = sleepTimerEnd!.difference(DateTime.now()).inSeconds;
    return diff > 0 ? (diff / 60).ceil() : null;
  }

  void setSleepTimer(int minutes) {
    cancelSleepTimer();
    if (minutes <= 0) return;
    sleepTimerEnd = DateTime.now().add(Duration(minutes: minutes));
    _sleepTimer = Timer(Duration(minutes: minutes), () {
      pause();
      cancelSleepTimer();
    });
    notifyListeners();
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    sleepTimerEnd = null;
    notifyListeners();
  }

  double get speed => _p?.speed ?? 1.0;
  Future<void> setSpeed(double spd) async {
    await _player.setSpeed(spd);
    notifyListeners();
  }

  double get volume => _p?.volume ?? 1.0;
  Future<void> setVolume(double vol) async {
    await _player.setVolume(vol.clamp(0.0, 1.0));
    notifyListeners();
  }

  void _buildShuffleOrder() {
    _shuffleOrder = List.generate(queue.length, (i) => i)..shuffle();
    if (currentIndex >= 0 && currentIndex < queue.length) {
      _shuffleOrder.remove(currentIndex);
      _shuffleOrder.insert(0, currentIndex);
      _shufflePos = 0;
    } else {
      _shufflePos = 0;
    }
  }

  void _syncShufflePos() {
    final idx = _shuffleOrder.indexOf(currentIndex);
    if (idx >= 0) {
      _shufflePos = idx;
    }
  }

  void removeFromQueue(int index) {
    if (index < 0 || index >= queue.length) return;
    final removingCurrent = index == currentIndex;
    queue.removeAt(index);
    if (currentIndex > index) {
      currentIndex--;
    } else if (currentIndex >= queue.length) {
      currentIndex = queue.length - 1;
    }
    _buildShuffleOrder();
    if (removingCurrent) {
      if (queue.isNotEmpty && currentIndex >= 0) {
        _play(queue[currentIndex]);
      } else {
        stop();
      }
    } else {
      notifyListeners();
    }
  }

  void reorderQueue(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= queue.length) return;
    if (newIndex < 0 || newIndex > queue.length) return;
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final item = queue.removeAt(oldIndex);
    queue.insert(newIndex, item);
    if (currentIndex == oldIndex) {
      currentIndex = newIndex;
    } else if (currentIndex > oldIndex && currentIndex <= newIndex) {
      currentIndex--;
    } else if (currentIndex < oldIndex && currentIndex >= newIndex) {
      currentIndex++;
    }
    _buildShuffleOrder();
    notifyListeners();
  }

  void playNext(Track track) {
    final existingIdx = queue.indexWhere((t) => t.id == track.id);
    if (existingIdx != -1) {
      queue.removeAt(existingIdx);
      if (currentIndex > existingIdx) {
        currentIndex--;
      }
    }
    final insertIdx = (currentIndex >= 0 && currentIndex < queue.length)
        ? currentIndex + 1
        : queue.length;
    queue.insert(insertIdx, track);
    _buildShuffleOrder();
    notifyListeners();
  }

  void addToQueue(Track track) {
    final existingIdx = queue.indexWhere((t) => t.id == track.id);
    if (existingIdx != -1) return;
    queue.add(track);
    _buildShuffleOrder();
    notifyListeners();
  }

  void clearUpcoming() {
    if (queue.isEmpty) return;
    if (currentIndex >= 0 && currentIndex < queue.length - 1) {
      queue.removeRange(currentIndex + 1, queue.length);
    }
    _buildShuffleOrder();
    notifyListeners();
  }

  void clearQueue() {
    queue.clear();
    currentIndex = -1;
    _shuffleOrder.clear();
    _shufflePos = 0;
    notifyListeners();
  }

  AudioPlayer _createPlayer() {
    final p = AudioPlayer();
    p.setAndroidAudioAttributes(
      const AndroidAudioAttributes(
        contentType: AndroidAudioContentType.music,
        flags: AndroidAudioFlags.none,
        usage: AndroidAudioUsage.media,
      ),
    );
    AudioSession.instance.then((session) {
      session.configure(const AudioSessionConfiguration.music());
    }).catchError((Object e, StackTrace st) {
      AppLog.error('audio_session init', e, st);
    });
    p.playbackEventStream.listen(
      (_) {},
      onError: (Object e, StackTrace st) => AppLog.error('player', e, st),
    );
    p.durationStream.listen((d) {
      if (d != null) {
        notifyListeners();
      }
    });
    p.playerStateStream.listen((s) {
      AppLog.info('player: ${s.processingState.name} playing=${s.playing}');
      if (s.processingState == ProcessingState.completed) {
        if (loopMode == LoopMode.one) {
          p.seek(Duration.zero);
          p.play();
        } else if (hasNext) {
          next();
        } else {
          playingId = null;
          notifyListeners();
        }
      } else {
        notifyListeners();
      }
    });
    return p;
  }

  Future<({StreamManifest manifest, int clientIndex})> _manifest(
    String id, {int startClient = 0,}
  ) =>
      Downloader.manifestFor(
        yt, id, const Duration(seconds: 20), startClient: startClient,
      );

  Future<void> toggle(Track t, {List<Track>? contextTracks}) async {
    if (playingId == t.id) {
      if (isPlaying) {
        await pause();
      } else {
        await resume();
      }
      return;
    }
    if (loadingId == t.id) {
      return stop();
    }
    await playTrack(t, contextTracks: contextTracks);
  }

  Future<void> playTrack(Track t, {List<Track>? contextTracks}) async {
    if (contextTracks != null && contextTracks.isNotEmpty) {
      queue.clear();
      queue.addAll(contextTracks);
      currentIndex = queue.indexWhere((x) => x.id == t.id);
      if (currentIndex == -1) {
        queue.insert(0, t);
        currentIndex = 0;
      }
      _buildShuffleOrder();
    } else {
      if (!queue.any((x) => x.id == t.id)) {
        queue.add(t);
        currentIndex = queue.length - 1;
        _buildShuffleOrder();
      } else {
        currentIndex = queue.indexWhere((x) => x.id == t.id);
        _syncShufflePos();
      }
    }
    await _play(t);
  }

  Future<void> playList(
    List<Track> tracks, {
    int startIndex = 0,
    bool startShuffled = false,
  }) async {
    if (tracks.isEmpty) return;
    queue.clear();
    queue.addAll(tracks);
    if (startShuffled) {
      shuffle = true;
      _buildShuffleOrder();
      currentIndex = _shuffleOrder.isNotEmpty ? _shuffleOrder[0] : 0;
      _shufflePos = 0;
    } else {
      shuffle = false;
      currentIndex = startIndex.clamp(0, tracks.length - 1);
      _buildShuffleOrder();
    }
    await _play(queue[currentIndex]);
  }

  Future<void> jumpToIndex(int index) async {
    if (index < 0 || index >= queue.length) return;
    currentIndex = index;
    _syncShufflePos();
    await _play(queue[currentIndex]);
  }

  Future<void> next() async {
    if (queue.isEmpty) return;
    if (loopMode == LoopMode.one) {
      await seek(Duration.zero);
      await resume();
      return;
    }
    if (shuffle) {
      if (_shufflePos + 1 < _shuffleOrder.length) {
        _shufflePos++;
        currentIndex = _shuffleOrder[_shufflePos];
        await _play(queue[currentIndex]);
      } else if (loopMode == LoopMode.all && _shuffleOrder.isNotEmpty) {
        _shufflePos = 0;
        currentIndex = _shuffleOrder[_shufflePos];
        await _play(queue[currentIndex]);
      } else {
        await stop();
      }
    } else {
      if (currentIndex + 1 < queue.length) {
        currentIndex++;
        await _play(queue[currentIndex]);
      } else if (loopMode == LoopMode.all && queue.isNotEmpty) {
        currentIndex = 0;
        await _play(queue[currentIndex]);
      } else {
        await stop();
      }
    }
  }

  Future<void> previous() async {
    if (queue.isEmpty) return;
    if (position.inSeconds > 3) {
      await seek(Duration.zero);
      return;
    }
    if (shuffle) {
      if (_shufflePos > 0) {
        _shufflePos--;
        currentIndex = _shuffleOrder[_shufflePos];
        await _play(queue[currentIndex]);
      } else if (loopMode == LoopMode.all && _shuffleOrder.isNotEmpty) {
        _shufflePos = _shuffleOrder.length - 1;
        currentIndex = _shuffleOrder[_shufflePos];
        await _play(queue[currentIndex]);
      } else {
        await seek(Duration.zero);
      }
    } else {
      if (currentIndex > 0) {
        currentIndex--;
        await _play(queue[currentIndex]);
      } else if (loopMode == LoopMode.all && queue.isNotEmpty) {
        currentIndex = queue.length - 1;
        await _play(queue[currentIndex]);
      } else {
        await seek(Duration.zero);
      }
    }
  }

  void _prewarmNext() {
    if (!hasNext) return;
    int nextIdx;
    if (shuffle) {
      if (_shufflePos + 1 < _shuffleOrder.length) {
        nextIdx = _shuffleOrder[_shufflePos + 1];
      } else if (loopMode == LoopMode.all && _shuffleOrder.isNotEmpty) {
        nextIdx = _shuffleOrder[0];
      } else {
        return;
      }
    } else {
      if (currentIndex + 1 < queue.length) {
        nextIdx = currentIndex + 1;
      } else if (loopMode == LoopMode.all && queue.isNotEmpty) {
        nextIdx = 0;
      } else {
        return;
      }
    }
    if (nextIdx >= 0 && nextIdx < queue.length) {
      final nextTrack = queue[nextIdx];
      if (getLocalPath?.call(nextTrack.id) == null) {
        unawaited(_manifest(nextTrack.id).then((_) {}, onError: (_) {}));
      }
    }
  }

  MediaItem _buildMediaItem(Track t) {
    String thumb = t.thumb.trim();
    if (thumb.isEmpty ||
        thumb.endsWith('.m4a') ||
        thumb.endsWith('.mp3') ||
        thumb.endsWith('.opus') ||
        thumb.endsWith('.flac')) {
      final p = getLocalPath?.call(t.id);
      if (p != null) {
        final dot = p.lastIndexOf('.');
        final base = dot > 0 ? p.substring(0, dot) : p;
        for (final ext in const ['.jpg', '.png', '.jpeg', '.webp']) {
          final f = File('$base$ext');
          if (f.existsSync() && f.lengthSync() > 0) {
            thumb = f.path;
            break;
          }
        }
      }
    }
    return MediaItem(
      id: t.id,
      album: (t.album != null && t.album!.isNotEmpty) ? t.album! : 'Wax',
      title: t.title,
      artist: t.author.replaceAll(RegExp(r'\s*-\s*Topic$', caseSensitive: false), ''),
      artUri: _parseArtUri(thumb),
      duration: t.duration,
    );
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

  Future<void> _play(Track t) async {
    await _player.stop();
    try {
      final session = await AudioSession.instance;
      await session.setActive(true);
    } catch (_) {}
    currentTrack = t;
    loadingId = t.id;
    playingId = null;
    error = null;
    notifyListeners();

    // 1. Instant Offline Playback if downloaded locally
    final localPath = getLocalPath?.call(t.id);
    if (localPath != null) {
      final file = File(localPath);
      if (file.existsSync() && file.lengthSync() > 0) {
        try {
          AppLog.info('play ${t.id}: playing local file $localPath');
          final source = AudioSource.file(localPath, tag: _buildMediaItem(t));
          final len = await _player.setAudioSource(source);
          AppLog.info('play ${t.id}: loaded local file, length $len');
          if (loadingId != t.id) return;
          final old = _current;
          _current = null;
          if (old != null) await _delete(old);
          loadingId = null;
          playingId = t.id;
          notifyListeners();
          unawaited(
            _player.play().catchError((Object e, StackTrace st) {
              AppLog.error('play local ${t.id}', e, st);
            }),
          );
          _prewarmNext();
          return;
        } catch (e, st) {
          AppLog.error('play ${t.id}: failed local playback, falling back to stream', e, st);
        }
      }
    }

    // 2. Stream from YouTube
    File? file;
    try {
      var nextClient = 0;
      for (;;) {
        final (:manifest, :clientIndex) =
            await _manifest(t.id, startClient: nextClient);
        if (loadingId != t.id) return; // user moved on
        
        // Prioritize MP4/AAC streams: Android MediaCodec decodes MP4 containers
        // immediately without parsing fragmented WebM cluster headers.
        final aac = manifest.audioOnly
            .where((x) => x.container == StreamContainer.mp4)
            .toList()
          ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
        final isAac = aac.isNotEmpty;
        final s = isAac ? aac.first : manifest.audioOnly.withHighestBitrate();
        
        final ua = Downloader.uaFor(s.url);
        AppLog.info(
          'play ${t.id}: ${s.container.name} ${s.bitrate.kiloBitsPerSecond.round()}kbps '
          '${s.size.totalBytes} bytes via ${s.url.host} (client $clientIndex)',
        );

        final dir = await getTemporaryDirectory();

        // Fast path: direct progressive streaming via AudioSource.uri for instant playback (~200ms).
        try {
          if (!Downloader.isTrustedStreamUrl(s.url)) {
            throw const HttpException('Refused audio stream from untrusted host');
          }
          // Stream URLs are signed, so no account cookies are needed (or sent):
          // the Google session must never travel to the media CDN.
          final source = AudioSource.uri(
            s.url,
            headers: {'User-Agent': ua},
            tag: _buildMediaItem(t),
          );
          final setFuture = _player.setAudioSource(source);
          unawaited(
            _player.play().catchError((Object e, StackTrace st) {
              AppLog.error('play ${t.id}', e, st);
            }),
          );
          final len = await setFuture;
          AppLog.info('play ${t.id}: direct stream ready, length $len');
          if (loadingId != t.id) return;
          final old = _current;
          _current = null;
          if (old != null) await _delete(old);
          loadingId = null;
          playingId = t.id;
          notifyListeners();
          _prewarmNext();
          return;
        } catch (e) {
          AppLog.info('play ${t.id}: direct stream failed ($e)');
          final isHttpError = e.toString().contains('403') ||
              e.toString().contains('HttpDataSource') ||
              e.toString().contains('InvalidResponseCodeException');
          if (isHttpError) {
            Downloader.evictManifest(t.id);
            if (BrowserAuth.isSupported) {
              unawaited(BrowserAuth.refreshPoToken(t.id));
              unawaited(BrowserAuth.refreshCookies());
            }
            if (clientIndex + 1 < Downloader.clientCount) {
              AppLog.info('play ${t.id}: client stream error, rotating to next client');
              nextClient = clientIndex + 1;
              continue;
            }
          }
        }

        file = File('${dir.path}/preview_${t.id}.${s.container.name}');
        if (!await file.exists() || await file.length() == 0) {
          final sink = file.openWrite();
          var got = 0;
          try {
            await for (final chunk
                in Downloader.rawStream(s, cap: _capBytes)) {
              if (loadingId != t.id) break;
              sink.add(chunk);
              got += chunk.length;
              if (got >= _capBytes) break;
            }
          } on HttpException catch (e) {
            await sink.close();
            await _delete(file);
            file = null;
            // 403 on this client's stream: refresh cookies and try next client.
            if (Downloader.is403(e)) {
              if (BrowserAuth.isSupported) {
                AppLog.info('preview ${t.id}: stream 403, refreshing poToken and session');
                await BrowserAuth.refreshPoToken(t.id);
                await BrowserAuth.refreshCookies();
              }
              if (clientIndex + 1 < Downloader.clientCount) {
                AppLog.info(
                  'preview ${t.id}: client refused stream, trying next',
                );
                nextClient = clientIndex + 1;
                continue;
              }
            }
            rethrow;
          } catch (_) {
            await sink.close();
            rethrow;
          }
          await sink.close();
          AppLog.info('preview ${t.id}: downloaded $got bytes');
          if (loadingId != t.id) {
            await _delete(file); // cancelled: don't keep a partial file
            return;
          }
          if (got == 0) throw Exception('The audio download returned no data');
        }
        // Downloaded OK — break out of the client-rotation loop.
        break;
      }
      final source = AudioSource.file(file.path, tag: _buildMediaItem(t));
      final len = await _player.setAudioSource(source);
      AppLog.info('play ${t.id}: loaded, length $len');
      if (loadingId != t.id) return;
      final old = _current;
      _current = file;
      if (old != null && old.path != file.path) await _delete(old);
      loadingId = null;
      playingId = t.id;
      notifyListeners();
      unawaited(
        _player.play().catchError((Object e, StackTrace st) {
          AppLog.error('play ${t.id}', e, st);
        }),
      );
      _prewarmNext();
    } catch (e, st) {
      AppLog.error('play ${t.id}', e, st);
      if (file != null) await _delete(file);
      if (loadingId == t.id) {
        loadingId = null;
        playingId = null;
        error = Downloader.isBlocked(e)
            ? Downloader.friendly(e)
            : tr('Playback failed, try again');
        notifyListeners();
      }
    }
  }

  Future<void> _delete(File f) async {
    try {
      await f.delete();
    } catch (_) {}
  }

  Future<void> stop() async {
    if (loadingId == null && playingId == null && currentTrack == null) return;
    loadingId = null;
    playingId = null;
    notifyListeners();
    await _p?.pause();
  }

  @override
  void dispose() {
    _sleepTimer?.cancel();
    _p?.dispose();
    super.dispose();
  }
}
