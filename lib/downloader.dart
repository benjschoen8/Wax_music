import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'browser_auth.dart';
import 'cache.dart';
import 'client_retry.dart';
import 'files.dart';
import 'log.dart';
import 'lyrics.dart';
import 'media_store.dart';
import 'models/track.dart';
import 'strings.dart';
import 'ytm_search.dart';

/// Thrown when the user cancels a download.
class Cancelled implements Exception {
  const Cancelled();
}

/// Everything that touches the network, FFmpeg and the file system.
/// [AppState] only decides *what* to download and *when*.
class Downloader {
  Downloader(this.yt);

  final YoutubeExplode yt;

  // YouTube periodically blocks one client's audio streams (HTTP 403), so each
  // retry uses a different API client:
  // 1. Android (fastest: ~450ms direct player endpoint, 6 audio streams, no watchpage)
  // 2. visionOS (Apple RealityDevice + watchpage fallback: full streams, no SABR lock)
  // 3. library default (Android SDK-less)
  // 4. iOS
  // 5. mobile web
  // 6. TV
  static final List<(List<YoutubeApiClient>?, bool)> _clientSets = [
    ([YoutubeApiClient.visionos], true),
    ([YoutubeApiClient.android], false),
    (null, false),
    ([YoutubeApiClient.ios], false),
    ([YoutubeApiClient.mweb], false),
    ([YoutubeApiClient.tv], true),
  ];

  static const _clientNames = [
    'visionos',
    'android',
    'default',
    'ios',
    'mweb',
    'tv',
  ];

  /// In-memory cache for stream manifests to make re-plays and pre-warmed tracks 0ms instantaneous.
  static final Map<String, ({StreamManifest manifest, int clientIndex, DateTime cachedAt})>
      _manifestCache = {};

  static void evictManifest(String id) => _manifestCache.remove(id);

  /// The user agent YouTube expects for a stream URL: the one of the API
  /// client that issued it (named in the URL's `c=` parameter). The library's
  /// own stream download sends a desktop-Chrome agent instead, which makes
  /// YouTube stall the request, and it swallows the error.
  static String _uaFor(Uri url) {
    const fallback =
        'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip';
    final c = url.queryParameters['c'];
    for (final cl in [
      YoutubeApiClient.android,
      YoutubeApiClient.androidSdkless,
      YoutubeApiClient.androidVr,
      YoutubeApiClient.androidMusic,
      YoutubeApiClient.ios,
      YoutubeApiClient.visionos,
      YoutubeApiClient.mweb,
      YoutubeApiClient.tv,
    ]) {
      try {
        final ctx = cl.payload['context']['client'];
        if (ctx['clientName'] == c && ctx['userAgent'] is String) {
          return ctx['userAgent'] as String;
        }
      } catch (_) {}
    }
    return fallback;
  }

  /// Returns the matching User-Agent for the stream client.
  static String uaFor(Uri url) => _uaFor(url);

  /// Audio streams only ever come from YouTube's CDN over TLS.
  static bool isTrustedStreamUrl(Uri u) {
    final h = u.host.toLowerCase();
    return u.scheme == 'https' &&
        (h == 'googlevideo.com' || h.endsWith('.googlevideo.com'));
  }

  /// Largest audio stream we agree to download (1 GiB).
  static const maxAudioBytes = 1024 * 1024 * 1024;

  /// Downloads [s] in ranged requests with the matching user agent. Unlike
  /// the library's stream, it reports the real HTTP status and never hangs
  /// silently. [cap] stops early (used by previews).
  static Stream<List<int>> rawStream(
    AudioStreamInfo s, {
    int? cap,
    Duration step = const Duration(seconds: 20),
  }) async* {
    final total = s.size.totalBytes;
    // Audio only ever comes from YouTube's CDN over TLS; refuse anything else
    // (and absurd sizes) instead of fetching whatever a manifest points at.
    if (!isTrustedStreamUrl(s.url)) {
      throw const HttpException('Refused audio stream from untrusted host');
    }
    if (total <= 0 || total > maxAudioBytes) {
      throw const HttpException('Refused audio stream with invalid size');
    }
    final ua = _uaFor(s.url);
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    final watch = Stopwatch()..start();
    try {
      var pos = 0;
      const chunk = 512 * 1024;
      while (pos < total && (cap == null || pos < cap)) {
        final end = (pos + chunk < total ? pos + chunk : total) - 1;
        final req = await http.getUrl(s.url).timeout(step);
        req.headers.set(HttpHeaders.userAgentHeader, ua);
        req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        req.headers.set('Range', 'bytes=$pos-$end');
        final rs = await req.close().timeout(step);
        if (pos == 0) {
          AppLog.info(
            'stream ${s.videoId}: HTTP ${rs.statusCode} after ${watch.elapsedMilliseconds}ms',
          );
        }
        if (rs.statusCode != 200 && rs.statusCode != 206) {
          await rs.drain<void>();
          throw HttpException('YouTube refused the audio (HTTP ${rs.statusCode})');
        }
        var got = 0;
        await for (final data in rs.timeout(step)) {
          got += data.length;
          yield data;
        }
        if (got == 0) throw const HttpException('Empty audio response');
        pos += got;
      }
    } finally {
      http.close(force: true);
    }
  }

  /// Stream manifest for [id], trying clients starting from [startClient].
  /// Returns both the manifest and which client index produced it, so a
  /// caller that hits a download-time 403 can resume from the next client.
  static Future<({StreamManifest manifest, int clientIndex})> manifestFor(
    YoutubeExplode yt,
    String id,
    Duration perTry, {
    int startClient = 0,
    bool useCache = true,
  }) async {
    if (startClient == 0 && useCache) {
      final cached = _manifestCache[id];
      if (cached != null && DateTime.now().difference(cached.cachedAt).inMinutes < 20) {
        AppLog.info('manifest $id: OK via cache (client ${cached.clientIndex})');
        return (manifest: cached.manifest, clientIndex: cached.clientIndex);
      }
    }
    return runClientAttempts<({StreamManifest manifest, int clientIndex})>(
      start: startClient,
      count: _clientSets.length,
      isBlocked: isBlocked,
      attempt: (i) async {
        final (clients, watchPage) = _clientSets[i];
        final label = 'client ${i + 1}/${_clientSets.length} '
            '(${_clientNames[i]}${watchPage ? ' +watchpage' : ''})';
        if (i > 0 && BrowserAuth.isSupported && BrowserAuth.poTokenFor(id) == null) {
          await BrowserAuth.getOrFetchPoToken(id);
        }
        final manifest = await yt.videos.streamsClient
            .getManifest(id, ytClients: clients, requireWatchPage: watchPage)
            .timeout(perTry);
        if (manifest.audioOnly.isEmpty) {
          throw const HttpException('no audio streams in manifest');
        }
        putBounded(_manifestCache, id, (manifest: manifest, clientIndex: i, cachedAt: DateTime.now()), max: 100);
        AppLog.info('manifest $id: OK via $label');
        return (manifest: manifest, clientIndex: i);
      },
      onFailure: (i, error) {
        final why = error.toString().split('\n')
            .where((line) => line.startsWith('Reason')).firstOrNull ??
            error.toString().split('\n').first;
        AppLog.info('manifest $id: client ${_clientNames[i]} failed ($why)');
      },
    );
  }

  /// True when the exception came from [rawStream] getting HTTP 403.
  static bool is403(Object e) =>
      e is HttpException && e.message.contains('403');

  /// How many client sets are available (for callers that rotate on 403).
  static int get clientCount => _clientSets.length;

  Future<void> init() async {
    // Drop cached downloads that were never finished with (older than a day).
    try {
      final d = Directory('${(await getTemporaryDirectory()).path}/wax_dl');
      if (await d.exists()) {
        final cutoff = DateTime.now().subtract(const Duration(days: 1));
        await for (final f in d.list()) {
          if (f is File && (await f.lastModified()).isBefore(cutoff)) {
            await f.delete();
          }
        }
      }
    } catch (_) {}
  }

  /// YouTube has flagged this connection: rate limit or "confirm you're not a bot".
  static bool isBlocked(Object e) {
    if (e is RequestLimitExceededException) return true;
    final m = e.toString().toLowerCase();
    return m.contains('not a bot') ||
        m.contains('needs to be reloaded') ||
        m.contains('sign in to confirm');
  }

  static String friendly(Object e) {
    if (e is Cancelled) return tr('Cancelled');
    if (e is TimeoutException) return tr('Network stalled. Tap retry.');
    if (e is FileSystemException) {
      return tr(
        'Storage error. Check free space and the save folder in Settings.',
      );
    }
    if (isBlocked(e)) {
      return tr(
        'YouTube is limiting this connection. Wait 15-30 minutes or switch between Wi-Fi and mobile data, then tap retry.',
      );
    }
    final m = e.toString();
    if (m.contains('SocketException') || m.contains('ClientException')) {
      return tr('No connection. Tap retry.');
    }
    return m.replaceFirst('Exception: ', '').split('\n').first;
  }

  /// Downloads [t], tags it, saves it into [dir] and returns the saved path.
  /// [onProgress] gets 0..1 whenever the whole-percent value changes;
  /// [onStatus] gets a short message ('' to clear it).
  Future<String> fetch(
    Track t,
    int attempt, {
    required String dir,
    required bool tagging,
    bool lyrics = true,
    required void Function(double fraction) onProgress,
    required void Function(String message) onStatus,
  }) async {
    const stall = Duration(seconds: 30);
    final tmpDir = await (await getTemporaryDirectory()).createTemp('wax');
    try {
      // Try each client until one actually delivers audio bytes. The manifest
      // fetch never probes: YouTube serves 1 KB probes on clients whose real
      // downloads it blocks, so the only reliable test is the download itself.
      var nextClient = 0;
      // The id actually downloaded. Normally t.id; swapped for the audio
      // ("- Topic") release when t.id turns out to be a music video whose
      // length does not match the listed track (e.g. 5:27 MV vs 4:40 song).
      var srcId = t.id;
      var audioCheckDone = false;
      var triedAlternate = false;
      for (;;) {
        final ({StreamManifest manifest, int clientIndex}) result;
        try {
          result = await manifestFor(yt, srcId, stall, startClient: nextClient);
        } catch (error) {
          // A particular video may be unavailable even when other songs work.
          // Try an independently matched official recording once.
          if (!triedAlternate && srcId == t.id) {
            audioCheckDone = true;
            triedAlternate = true;
            final alternate = await YtmSearchService.resolveAudioId(t);
            if (alternate != null && alternate != srcId) {
              AppLog.info('download ${t.id}: original unavailable, trying matching audio $alternate');
              srcId = alternate;
              nextClient = 0;
              continue;
            }
          }
          rethrow;
        }
        final (:manifest, :clientIndex) = result;
        final aac =
            manifest.audioOnly
                .where((s) => s.container == StreamContainer.mp4)
                .toList()
              ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
        final isAac = aac.isNotEmpty;
        final stream = isAac
            ? aac.first
            : manifest.audioOnly.withHighestBitrate();
        // Guard: the listed length (from the YouTube Music album/song data) must
        // match the stream. If it is clearly longer/shorter, the id points at a
        // music video, so look up the audio release and retry with that id.
        final expected = t.duration;
        if (!audioCheckDone) {
          audioCheckDone = true;
          var suspect = false;
          if (expected != null && stream.bitrate.kiloBitsPerSecond > 0) {
            final estSec = stream.size.totalBytes * 8 /
                (stream.bitrate.kiloBitsPerSecond * 1000);
            final diff = (estSec - expected.inSeconds).abs();
            suspect = diff > 6 && diff > expected.inSeconds * 0.025;
            if (suspect) {
              AppLog.info(
                'download ${t.id}: stream is ~${estSec.round()}s but track is '
                '${expected.inSeconds}s (likely a music video)',
              );
            }
          } else if (!t.author.endsWith('- Topic')) {
            // No length to compare and not a known audio release: look anyway.
            suspect = true;
          }
          if (suspect) {
            triedAlternate = true;
            final alt = await YtmSearchService.resolveAudioId(t);
            if (alt != null && alt != srcId) {
              AppLog.info('download ${t.id}: using YouTube Music audio version $alt');
              srcId = alt;
              nextClient = 0;
              continue; // fetch the manifest of the audio release
            }
            AppLog.info('download ${t.id}: no audio version found, keeping original');
          }
        }
        // Completed downloads are cached by video id, so a retry (or restart)
        // after a tagging/saving failure doesn't download the audio again.
        // Name it after what it really is (a WebM must not pose as .m4a).
        final cacheDir = Directory(
          '${(await getTemporaryDirectory()).path}/wax_dl',
        );
        await cacheDir.create(recursive: true);
        AppLog.info(
          'download ${t.id}: ${stream.container.name} '
          '${stream.bitrate.kiloBitsPerSecond.round()}kbps '
          '${stream.size.totalBytes} bytes via ${stream.url.host}',
        );
        final ext = isAac ? 'm4a' : stream.container.name;
        final cached = File('${cacheDir.path}/$srcId.$ext');
        final total = stream.size.totalBytes;
        final File src;
        if (total > 0 &&
            await cached.exists() &&
            await cached.length() == total) {
          onProgress(1);
          src = cached;
        } else {
          final part = File('${cached.path}.part');
          final sink = part.openWrite();
          var got = 0, lastPct = -1;
          try {
            await for (final chunk
                in rawStream(stream, step: stall)) {
              if (t.cancelled) throw const Cancelled();
              got += chunk.length;
              sink.add(chunk);
              final pct = total > 0 ? (got * 100 / total).floor() : 0;
              if (pct != lastPct) {
                lastPct = pct;
                onProgress(total > 0 ? got / total : 0);
              }
            }
            await sink.flush();
          } on HttpException catch (e) {
            await sink.close();
            try { await part.delete(); } catch (_) {}
            // 403 on this client's stream: refresh cookies and try next client.
            if (is403(e)) {
              if (BrowserAuth.isSupported) {
                AppLog.info('download ${t.id}: stream 403, refreshing poToken and session');
                await BrowserAuth.refreshPoToken(srcId);
                await BrowserAuth.refreshCookies();
              }
              if (clientIndex + 1 < _clientSets.length) {
                AppLog.info(
                  'download ${t.id}: client ${_clientNames[clientIndex]} '
                  'refused the stream, trying next',
                );
                nextClient = clientIndex + 1;
                continue; // retry with next client
              }
              if (!triedAlternate && srcId == t.id) {
                triedAlternate = true;
                final alternate = await YtmSearchService.resolveAudioId(t);
                if (alternate != null && alternate != srcId) {
                  AppLog.info('download ${t.id}: streams refused, trying matching audio $alternate');
                  srcId = alternate;
                  nextClient = 0;
                  continue;
                }
              }
            }
            rethrow;
          } catch (_) {
            await sink.close();
            try { await part.delete(); } catch (_) {}
            rethrow;
          }
          await sink.close();
          AppLog.info('download ${t.id}: got $got bytes');
          if (got == 0) throw Exception('The audio download returned no data');
          src = await part.rename(cached.path);
        }

        // Tag (stream copy). A non-AAC source *must* be converted to AAC, or an
        // .m4a with Opus inside would be saved; in that case failure is an error.
        var toSave = src;
        String? lyricsText;
        File? coverImg;
        if (tagging || !isAac || lyrics) {
          onStatus(tr(isAac ? 'Tagging…' : 'Converting…'));
          AppLog.info('download ${t.id}: tagging with FFmpeg (lyrics=$lyrics)');
          final tagged = await _tag(
            t,
            src,
            tmpDir,
            convert: !isAac,
            fetchLyrics: lyrics,
          );
          toSave = tagged.file;
          lyricsText = tagged.lyrics;
          coverImg = tagged.cover;
          if (!isAac && identical(toSave, src)) {
            throw Exception(tr('Conversion failed'));
          }
          onStatus('');
        }
        AppLog.info('download ${t.id}: saving to $dir');
        final saved = await _save(t, toSave, tmpDir, dir, lyrics: lyricsText, cover: coverImg);
        AppLog.info('download ${t.id}: saved $saved');
        try {
          await cached.delete(); // saved: the cache copy is no longer needed
        } catch (_) {}
        return saved;
      }
    } finally {
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Saves into Music/... through MediaStore (the supported way on Android
  /// 10+: no storage permission, and music apps see the file immediately).
  /// Any other folder uses plain file I/O.
  Future<String> _save(
    Track t,
    File file,
    Directory tmp,
    String dir, {
    String? lyrics,
    File? cover,
  }) async {
    final cleanDir = dir.replaceAll(RegExp(r'/+$'), '');
    final rel = musicRelative(cleanDir);
    if (rel != null && await MediaStoreBridge.supported()) {
      final base = await uniqueName(
        t.fileName,
        (n) => MediaStoreBridge.exists('$n.m4a', rel),
      );
      final fileName = '$base.m4a';
      assert(!fileName.contains('/'));
      final named = await file.copy('${tmp.path}/$fileName');
      final savedPath = await MediaStoreBridge.save(named.path, fileName, rel);
      AppLog.info('mediastore: rel="$rel" name="$fileName" -> $savedPath');
      if (lyrics != null && lyrics.isNotEmpty) {
        try {
          final lrc = File('$cleanDir/$base.lrc');
          await lrc.writeAsString(lyrics);
        } catch (_) {}
      }
      if (cover != null && await cover.exists() && await cover.length() > 0) {
        try {
          final img = File('$cleanDir/$base.jpg');
          await cover.copy(img.path);
        } catch (_) {}
      }
      return savedPath.startsWith('/') ? savedPath : '$cleanDir/$fileName';
    }

    await Directory(cleanDir).create(recursive: true);
    final name = await uniqueName(
      t.fileName,
      (n) async => File('$cleanDir/$n.m4a').exists(),
    );
    final dest = '$cleanDir/$name.m4a';
    final part = File('$dest.part');
    try {
      // Partial file + rename: a half-copied file never looks like a song.
      await file.copy(part.path);
      await part.rename(dest);
    } on FileSystemException {
      // Some folders refuse unknown extensions: write the final name directly.
      try {
        await part.delete();
      } catch (_) {}
      await file.copy(dest);
    }
    if (lyrics != null && lyrics.isNotEmpty) {
      try {
        final lrc = File('$cleanDir/$name.lrc');
        await lrc.writeAsString(lyrics);
      } catch (_) {}
    }
    if (cover != null && await cover.exists() && await cover.length() > 0) {
      try {
        final img = File('$cleanDir/$name.jpg');
        await cover.copy(img.path);
      } catch (_) {}
    }
    return dest;
  }

  Future<File?> _cover(Track t, Directory d) async {
    for (final u in [
      'https://i.ytimg.com/vi/${t.id}/maxresdefault.jpg',
      'https://i.ytimg.com/vi/${t.id}/sddefault.jpg',
      'https://i.ytimg.com/vi/${t.id}/hqdefault.jpg',
      'https://i.ytimg.com/vi/${t.id}/mqdefault.jpg',
      if (t.thumb.isNotEmpty) t.thumb,
    ]) {
      final uri = Uri.tryParse(u);
      if (uri == null || uri.scheme != 'https') continue;
      final host = uri.host.toLowerCase();
      // Only permit official YouTube, Google, Apple Music, and NetEase image CDNs
      final isTrustedCdn =
          host.endsWith('.ytimg.com') ||
          host.endsWith('.googleusercontent.com') ||
          host.endsWith('.ggpht.com') ||
          host.endsWith('.mzstatic.com') ||
          host.endsWith('.126.net');
      if (!isTrustedCdn) continue;

      final c = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      try {
        final req = await c.getUrl(uri).timeout(const Duration(seconds: 5));
        // A trusted CDN must not be able to bounce us to an untrusted host.
        req.followRedirects = false;
        final rs = await req.close().timeout(const Duration(seconds: 15));
        if (rs.statusCode == 200) {
          if (rs.contentLength > 10 * 1024 * 1024) {
            await rs.drain<void>();
            continue;
          }
          final f = File('${d.path}/cover.jpg');
          var written = 0;
          await rs
              .map((chunk) {
                written += chunk.length;
                if (written > 10 * 1024 * 1024) {
                  throw const HttpException('cover image too large');
                }
                return chunk;
              })
              .pipe(f.openWrite());
          // Ensure it's not a 0-byte or placeholder image
          if (await f.exists() && await f.length() > 1024) {
            return f;
          }
        }
        await rs.drain();
      } catch (_) {
      } finally {
        c.close();
      }
    }
    return null;
  }

  static String _cleanMeta(String s) =>
      s.replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]'), '');

  /// Writes title/artist/album/source metadata + square cover + lyrics. The audio is copied
  /// untouched unless [convert] is set (WebM/Opus -> AAC). On any failure the
  /// untagged source is returned, so tagging never makes a download fail by itself.
  Future<({File file, String? lyrics, File? cover})> _tag(
    Track t,
    File src,
    Directory tmp, {
    required bool convert,
    required bool fetchLyrics,
  }) async {
    File? cover;
    try {
      final needDetails = (t.album == null || t.album!.isEmpty) || t.uploadYear == null;
      final results = await Future.wait([
        _cover(t, tmp),
        if (fetchLyrics) LyricsService.fetch(t, yt: yt) else Future.value(null),
        if (needDetails)
          YtmSearchService.fetchDetails(
            t.id,
            queryHint: '${t.tagArtist} ${t.tagTitle}',
          )
        else
          Future.value(null),
      ]);
      cover = results[0] as File?;
      final lyricsRes = fetchLyrics ? results[1] as LyricsResult? : null;
      final lyricsText = lyricsRes?.lyrics;
      final details = needDetails ? results[2] as ({String? album, String? year})? : null;

      final albumTag = (t.album != null && t.album!.isNotEmpty)
          ? t.album!
          : (details?.album != null && details!.album!.isNotEmpty)
              ? details.album!
              : t.tagAlbum;
      final yearTag = t.uploadYear ?? details?.year;

      final out = File('${tmp.path}/tagged.m4a');
      final sourceUrl = t.sourceUrl;

      // An argument list (not one command string) so titles containing quotes
      // or backslashes need no escaping.
      final args = <String>[
        '-y',
        '-protocol_whitelist',
        'file',
        '-i',
        src.path,
        if (cover != null) ...[
          '-protocol_whitelist',
          'file',
          '-i',
          cover.path,
          '-map',
          '0:a',
          '-map',
          '1:v',
          '-c:v',
          'mjpeg',
          '-vf',
          'crop=ih:ih',
          '-disposition:v:0',
          'attached_pic',
          '-metadata:s:v',
          'title=Album cover',
        ] else
          '-vn',
        ...(convert ? ['-c:a', 'aac', '-b:a', '160k'] : ['-c:a', 'copy']),
        '-metadata',
        'title=${_cleanMeta(t.tagTitle)}',
        '-metadata',
        'artist=${_cleanMeta(t.tagArtist)}',
        '-metadata',
        'album=${_cleanMeta(albumTag)}',
        '-metadata',
        'comment=${_cleanMeta(sourceUrl)}',
        '-metadata',
        'description=${_cleanMeta(t.thumb.isNotEmpty ? t.thumb : sourceUrl)}',
        '-metadata',
        'purl=${_cleanMeta(sourceUrl)}',
        '-metadata',
        'synopsis=${_cleanMeta(t.id)}',
        if (yearTag != null && yearTag.isNotEmpty) ...[
          '-metadata',
          'date=${_cleanMeta(yearTag)}',
        ],
        if (lyricsText != null && lyricsText.isNotEmpty) ...[
          '-metadata',
          'lyrics=${_cleanMeta(lyricsText)}',
        ],
        '-metadata',
        'media_type=1',
        out.path,
      ];
      final session = await FFmpegKit.executeWithArguments(args);
      if (ReturnCode.isSuccess(await session.getReturnCode()) &&
          await out.exists() &&
          await out.length() > 0) {
        return (file: out, lyrics: lyricsText, cover: cover);
      }
      final log = (await session.getOutput()) ?? '';
      AppLog.info(
        'tagging failed for ${t.id}: '
        '${log.length > 300 ? log.substring(log.length - 300) : log}',
      );
    } catch (e, st) {
      AppLog.error('tagging ${t.id}', e, st);
    }
    return (file: src, lyrics: null, cover: cover);
  }

  /// Rewrites title/artist/album metadata on an existing local audio file.
  ///
  /// Safe against failure: the new file is built in the app's temp folder and
  /// verified first, the original is only moved aside (never deleted) until
  /// the replacement is in place, and it is restored if anything goes wrong.
  /// Returns true only when the file now carries the new tags.
  Future<bool> retagFile(
    File file, {
    required String title,
    required String artist,
    String? album,
  }) async {
    final path = file.path;
    if (!isSafeAudioPath(path)) {
      AppLog.info('retag refused: unsafe or non-audio path');
      return false;
    }
    // A '.bak' suffix keeps MediaStore from indexing the backup as a song.
    final backup = File('$path.bak');
    File? tmp;
    try {
      if (!await file.exists()) return false;
      final dot = path.lastIndexOf('.');
      final ext = dot >= 0 ? path.substring(dot) : '.m4a';
      final tmpDir = await getTemporaryDirectory();
      final built = File(
        '${tmpDir.path}/retag_${DateTime.now().millisecondsSinceEpoch}$ext',
      );
      tmp = built;
      final args = <String>[
        '-y',
        // Local files only: a crafted "audio" file (e.g. an HLS/concat playlist)
        // must not make FFmpeg read other files or open network connections.
        '-protocol_whitelist',
        'file',
        '-i',
        path,
        '-c',
        'copy',
        '-metadata',
        'title=${_cleanMeta(title)}',
        '-metadata',
        'artist=${_cleanMeta(artist)}',
        if (album != null && album.isNotEmpty) ...[
          '-metadata',
          'album=${_cleanMeta(album)}',
        ],
        built.path,
      ];
      final session = await FFmpegKit.executeWithArguments(args);
      if (!ReturnCode.isSuccess(await session.getReturnCode()) ||
          !await built.exists() ||
          await built.length() == 0) {
        return false;
      }
      // Replace: move the original aside, copy the new file in, then clean up.
      if (await backup.exists()) await backup.delete();
      await file.rename(backup.path);
      try {
        await built.copy(path);
        if (!await file.exists() || await file.length() == 0) {
          throw const FileSystemException('retag copy is empty');
        }
      } catch (e, st) {
        AppLog.error('retagFile replace $path', e, st);
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
        await backup.rename(path); // restore the original
        return false;
      }
      await backup.delete();
      return true;
    } catch (e, st) {
      AppLog.error('retagFile $path', e, st);
      // If we failed after moving the original aside, put it back.
      try {
        if (await backup.exists() && !await file.exists()) {
          await backup.rename(path);
        }
      } catch (_) {}
      return false;
    } finally {
      try {
        final t = tmp;
        if (t != null && await t.exists()) await t.delete();
      } catch (_) {}
    }
  }
}
