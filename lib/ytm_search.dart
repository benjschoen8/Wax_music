import 'dart:convert';
import 'dart:io';

import 'browser_auth.dart';
import 'cache.dart';
import 'log.dart';
import 'models/track.dart';

/// Searches YouTube Music directly for official song releases (Topic tracks).
///
/// Querying YouTube Music directly avoids the clutter of standard YouTube
/// (music videos, fan edits, dance practices, reaction videos) and returns
/// official audio tracks even when YouTube merges artist channels.
class YtmSearchService {
  static final HttpClient _client = HttpClient()
    ..autoUncompress = true
    ..idleTimeout = const Duration(seconds: 60)
    ..connectionTimeout = const Duration(seconds: 5);

  static final Map<String, (DateTime, List<Track>)> _searchCache = {};
  static final Map<String, (DateTime, ({String? album, String? year}))> _detailsCache = {};
  static const Duration _cacheTtl = Duration(minutes: 5);

  static final RegExp _yearRegex = RegExp(r'^\b(20\d\d|19\d\d)\b$');
  static final RegExp _thumbRegex = RegExp(r'=w\d+-h\d+.*$');

  static const _desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  static void _applyYtmHeaders(HttpClientRequest req) {
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.headers.set(HttpHeaders.userAgentHeader, _desktopUserAgent);
    req.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip, deflate');
    req.headers.set('Origin', 'https://music.youtube.com');
    req.headers.set('Referer', 'https://music.youtube.com/');
    if (BrowserAuth.cookies.isNotEmpty) {
      // Cookie is only ever sent to music.youtube.com; don't follow a redirect elsewhere.
      req.followRedirects = false;
      req.headers.set(HttpHeaders.cookieHeader, BrowserAuth.cookies);
    }
  }

  static Map<String, dynamic> _buildContext() => {
    'client': {
      'clientName': 'WEB_REMIX',
      'clientVersion': '1.20240401.01.00',
      'hl': 'en',
      'gl': 'US',
      if (BrowserAuth.visitorData.isNotEmpty)
        'visitorData': BrowserAuth.visitorData,
    },
  };

  static void clearCache() {
    _searchCache.clear();
    _detailsCache.clear();
  }

  static Future<List<Track>> search(
    String query, {
    int limit = 20,
    bool verifiedOnly = false,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    final cacheKey = '$q|$limit|$verifiedOnly';
    final cached = _searchCache[cacheKey];
    if (cached != null && DateTime.now().difference(cached.$1) < _cacheTtl) {
      return cached.$2;
    }

    final ctx = _buildContext();

    final results = <Track>[];
    String? continuationToken;

    try {
      final req = await _client
          .postUrl(Uri.parse('https://music.youtube.com/youtubei/v1/search'))
          .timeout(const Duration(seconds: 8));
      _applyYtmHeaders(req);
      req.add(utf8.encode(jsonEncode({
        'context': ctx,
        'query': q,
        'params': 'EgWKAQIIAWoQEAMQBBAJEAoQBRAREBAQFQ%3D%3D', // Filter: Songs
      })));

      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        AppLog.info('ytm search HTTP ${res.statusCode} for "$q"');
        return const [];
      }
      final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;

      final sections = body['contents']?['tabbedSearchResultsRenderer']?['tabs']?[0]?['tabRenderer']?['content']?['sectionListRenderer']?['contents'] as List?;

      for (final s in sections ?? const []) {
        final shelf = s['musicShelfRenderer'];
        if (shelf != null) {
          final contents = shelf['contents'] as List?;
          for (final item in contents ?? const []) {
            final track = _parseItem(item, verifiedOnly: verifiedOnly);
            if (track != null) results.add(track);
          }
          final continuations = shelf['continuations'] as List?;
          if (continuations != null && continuations.isNotEmpty) {
            continuationToken = continuations[0]?['nextContinuationData']?['continuation']?.toString();
          }
        }
      }

      // Fetch continuation if user requested more than returned on page 1
      if (results.length < limit && continuationToken != null && continuationToken.isNotEmpty) {
        final req2 = await _client.postUrl(Uri.parse(
          'https://music.youtube.com/youtubei/v1/search?continuation=$continuationToken&ctoken=$continuationToken',
        )).timeout(const Duration(seconds: 8));
        _applyYtmHeaders(req2);
        req2.add(utf8.encode(jsonEncode({'context': ctx})));
        final res2 = await req2.close().timeout(const Duration(seconds: 8));
        if (res2.statusCode == 200) {
          final body2 = jsonDecode(await res2.transform(utf8.decoder).join()) as Map<String, dynamic>;
          final contItems = body2['continuationContents']?['musicShelfContinuation']?['contents'] as List?;
          for (final item in contItems ?? const []) {
            final track = _parseItem(item, verifiedOnly: verifiedOnly);
            if (track != null) results.add(track);
          }
        }
      }
    } catch (e, st) {
      AppLog.error('ytm search error for "$q"', e, st);
    }

    final atvOnly = results.where((t) => t.author.endsWith('- Topic')).toList();
    final effectiveResults = (verifiedOnly && atvOnly.isNotEmpty) ? atvOnly : results;
    final out = effectiveResults.take(limit).toList();
    if (out.isNotEmpty) {
      if (_searchCache.length > 60) _searchCache.remove(_searchCache.keys.first);
      putBounded(_searchCache, cacheKey, (DateTime.now(), out), max: 100);
    }
    return out;
  }

  static String _normTitle(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[\(\[]\s*(?:official\s+)?(?:music\s+)?(?:audio|video|lyrics?|mv|hd|4k|visuali[sz]er)\s*[\)\]]', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();

  /// Finds the audio-only YouTube Music release ("- Topic" / ATV) of [t] when
  /// [t.id] turned out to be a music video (different cut, intro/outro).
  ///
  /// A candidate is accepted only if it is an audio release, has the same
  /// normalised title, and (when [t.duration] is known) its length is within
  /// [tolerance] of it. Returns null if nothing matches, so callers keep the
  /// original id.
  static Future<String?> resolveAudioId(
    Track t, {
    Duration tolerance = const Duration(seconds: 3),
  }) async {
    try {
      final cands = await search(
        '${t.tagTitle} ${t.tagArtist}',
        limit: 10,
        verifiedOnly: true,
      );
      return findAudioCandidate(t, cands, tolerance: tolerance)?.id;
    } catch (e, st) {
      AppLog.error('resolve audio id for "${t.title}"', e, st);
      return null;
    }
  }

  /// Selects only the same artist and recording; edits and live versions differ.
  static Track? findAudioCandidate(Track t, Iterable<Track> candidates, {
    Duration tolerance = const Duration(seconds: 3),
  }) {
    final want = _normTitle(t.tagTitle);
    final artist = _normTitle(t.tagArtist);
    final wantAlbum = t.album?.trim().toLowerCase();
    Track? best;
    for (final c in candidates) {
      if (c.id == t.id || !c.author.endsWith('- Topic')) continue;
      if (_normTitle(c.tagTitle) != want || _normTitle(c.tagArtist) != artist) continue;
      final d = t.duration, cd = c.duration;
      if (d != null && cd != null &&
          (d.inSeconds - cd.inSeconds).abs() > tolerance.inSeconds) {
        continue;
      }
      final sameAlbum = wantAlbum != null && wantAlbum.isNotEmpty &&
          c.album?.trim().toLowerCase() == wantAlbum;
      if (best == null || sameAlbum) best = c;
      if (sameAlbum) break;
    }
    return best;
  }

  /// Uses the exact video when possible, otherwise a matching audio release.
  static Track? findAlbumTrack(Track track, Iterable<Track> candidates) {
    final withAlbum = candidates.where((t) => t.album?.trim().isNotEmpty == true).toList();
    for (final candidate in withAlbum) {
      if (candidate.id == track.id) return candidate;
    }
    return findAudioCandidate(track, withAlbum);
  }

  /// Resolves the album name and release year for any track via YouTube Music.
  static Future<({String? album, String? year})> fetchDetails(
    String videoId, {
    String? queryHint,
  }) async {
    final cached = _detailsCache[videoId];
    if (cached != null && DateTime.now().difference(cached.$1) < _cacheTtl) {
      return cached.$2;
    }

    String? foundAlbum, foundYear;
    try {
      final ctx = _buildContext();
      final req = await _client
          .postUrl(Uri.parse('https://music.youtube.com/youtubei/v1/next'))
          .timeout(const Duration(seconds: 4));
      _applyYtmHeaders(req);
      req.add(utf8.encode(jsonEncode({
        'context': ctx,
        'videoId': videoId,
        'isAudioOnly': true,
      })));
      final res = await req.close().timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>?;
        final tabs = body?['contents']?['singleColumnMusicWatchNextResultsRenderer']?['tabbedRenderer']?['watchNextTabbedResultsRenderer']?['tabs'] as List<dynamic>?;
        final upNext = tabs?[0]?['tabRenderer']?['content']?['musicQueueRenderer']?['content']?['playlistPanelRenderer']?['contents'] as List<dynamic>?;
        if (upNext != null && upNext.isNotEmpty) {
          final runs = upNext[0]?['playlistPanelVideoRenderer']?['longBylineText']?['runs'] as List<dynamic>?;
          for (final r in runs ?? const []) {
            final pt = r['navigationEndpoint']?['browseEndpoint']?['browseEndpointContextSupportedConfigs']?['browseEndpointContextMusicConfig']?['pageType'];
            final text = r['text']?.toString().trim() ?? '';
            if (pt == 'MUSIC_PAGE_TYPE_ALBUM') {
              foundAlbum = text;
            } else if (_yearRegex.hasMatch(text)) {
              foundYear = text;
            }
          }
          if (foundAlbum != null && foundAlbum.isNotEmpty) {
            final result = (album: foundAlbum, year: foundYear);
            if (_detailsCache.length > 100) _detailsCache.remove(_detailsCache.keys.first);
            putBounded(_detailsCache, videoId, (DateTime.now(), result), max: 200);
            return result;
          }
        }
      }
    } catch (_) {}

    // Fallback: if queryHint is provided and no album found via 'next', search YTM
    if (queryHint != null && queryHint.trim().isNotEmpty) {
      try {
        final cand = await search(queryHint, limit: 1);
        if (cand.isNotEmpty && cand.first.album != null && cand.first.album!.isNotEmpty) {
          final result = (album: cand.first.album, year: foundYear ?? cand.first.uploadYear);
          if (_detailsCache.length > 100) _detailsCache.remove(_detailsCache.keys.first);
          putBounded(_detailsCache, videoId, (DateTime.now(), result), max: 200);
          return result;
        }
      } catch (_) {}
    }

    final result = (album: foundAlbum, year: foundYear);
    if (foundAlbum != null || foundYear != null) {
      if (_detailsCache.length > 100) _detailsCache.remove(_detailsCache.keys.first);
      putBounded(_detailsCache, videoId, (DateTime.now(), result), max: 200);
    }
    return result;
  }

  static Track? _parseItem(dynamic item, {bool verifiedOnly = false}) {
    if (item is! Map<String, dynamic>) return null;
    final flex = item['musicResponsiveListItemRenderer'];
    if (flex is! Map<String, dynamic>) return null;

    final videoId = flex['playlistItemData']?['videoId']?.toString() ??
        flex['overlay']?['musicItemThumbnailOverlayRenderer']?['content']?['musicPlayButtonRenderer']?['playNavigationEndpoint']?['watchEndpoint']?['videoId']?.toString() ??
        (flex['flexColumns']?[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'] as List?)?[0]?['navigationEndpoint']?['watchEndpoint']?['videoId']?.toString();

    if (videoId == null || videoId.isEmpty) return null;

    final videoType = flex['overlay']?['musicItemThumbnailOverlayRenderer']?['content']?['musicPlayButtonRenderer']?['playNavigationEndpoint']?['watchEndpoint']?['watchEndpointMusicSupportedConfigs']?['watchEndpointMusicConfig']?['musicVideoType']?.toString() ??
        (flex['flexColumns']?[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'] as List?)?[0]?['navigationEndpoint']?['watchEndpoint']?['watchEndpointMusicSupportedConfigs']?['watchEndpointMusicConfig']?['musicVideoType']?.toString();

    final metaRuns = flex['flexColumns']?[1]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'] as List?;
    final isAtv = videoType == 'MUSIC_VIDEO_TYPE_ATV';
    final hasArtistPage = metaRuns?.any((r) {
      final pt = r['navigationEndpoint']?['browseEndpoint']?['browseEndpointContextSupportedConfigs']?['browseEndpointContextMusicConfig']?['pageType'];
      return pt == 'MUSIC_PAGE_TYPE_ARTIST';
    }) ?? false;

    if (verifiedOnly) {
      if (videoType == 'MUSIC_VIDEO_TYPE_OMV') return null;
      if (!isAtv && !hasArtistPage) return null;
    }

    final titleRuns = flex['flexColumns']?[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'] as List?;
    final title = titleRuns?.map((r) => r['text']?.toString() ?? '').join().trim() ?? '';
    if (title.isEmpty) return null;

    if (verifiedOnly) {
      final tLower = title.toLowerCase();
      if (tLower.contains('official video') ||
          tLower.contains('official music video') ||
          tLower.contains('music video') ||
          tLower.contains('[mv]') ||
          tLower.contains('(mv)')) {
        return null;
      }
    }
    String artist = '';
    String? album;
    String? albumBrowseId;
    String? artistBrowseId;
    Duration? duration;

    if (metaRuns != null) {
      final artistRuns = <String>[];
      for (final r in metaRuns) {
        final text = r['text']?.toString() ?? '';
        if (text.contains('•')) break;
        artistRuns.add(text);
        final pageType = r['navigationEndpoint']?['browseEndpoint']?['browseEndpointContextSupportedConfigs']?['browseEndpointContextMusicConfig']?['pageType'];
        if (pageType == 'MUSIC_PAGE_TYPE_ARTIST') {
          artistBrowseId ??= r['navigationEndpoint']?['browseEndpoint']?['browseId']?.toString();
        }
      }
      artist = artistRuns.join().trim();

      // Look for album name and album browseId
      for (final r in metaRuns) {
        final pageType = r['navigationEndpoint']?['browseEndpoint']?['browseEndpointContextSupportedConfigs']?['browseEndpointContextMusicConfig']?['pageType'];
        if (pageType == 'MUSIC_PAGE_TYPE_ALBUM') {
          album = r['text']?.toString().trim();
          albumBrowseId = r['navigationEndpoint']?['browseEndpoint']?['browseId']?.toString();
          break;
        }
      }
      if (album == null || album.isEmpty) {
        final bullets = <int>[];
        for (var i = 0; i < metaRuns.length; i++) {
          if (metaRuns[i]['text']?.toString().contains('•') == true) bullets.add(i);
        }
        if (bullets.length >= 2) {
          final albumRuns = metaRuns.sublist(bullets[0] + 1, bullets[1]);
          final candAlbum = albumRuns.map((r) => r['text']?.toString() ?? '').join().trim();
          if (candAlbum.isNotEmpty) album = candAlbum;
        }
      }

      for (final r in metaRuns.reversed) {
        final text = r['text']?.toString().trim() ?? '';
        final dur = _parseDuration(text);
        if (dur != null) {
          duration = dur;
          break;
        }
      }
    }

    if (artist.isEmpty) artist = 'Unknown';

    // Thumbnail extraction: pick highest resolution thumbnail available
    final thumbs = flex['thumbnail']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'] as List?;
    String thumbUrl = '';
    if (thumbs != null && thumbs.isNotEmpty) {
      thumbUrl = thumbs.last['url']?.toString() ?? '';
    }
    if (thumbUrl.contains('googleusercontent.com') && thumbUrl.contains('=')) {
      thumbUrl = thumbUrl.replaceFirst(_thumbRegex, '=w544-h544-l90-rj');
    }
    if (thumbUrl.isEmpty) {
      thumbUrl = 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';
    }

    final author = (isAtv && !artist.endsWith('- Topic')) ? '$artist - Topic' : artist;

    return Track(
      videoId,
      title,
      author,
      thumbUrl,
      duration,
      album: album,
      albumBrowseId: albumBrowseId,
      artistBrowseId: artistBrowseId,
    );
  }

  static Duration? _parseDuration(String text) {
    final parts = text.split(':').map((s) => int.tryParse(s.trim())).toList();
    if (parts.any((p) => p == null)) return null;
    if (parts.length == 2) {
      return Duration(minutes: parts[0]!, seconds: parts[1]!);
    } else if (parts.length == 3) {
      return Duration(hours: parts[0]!, minutes: parts[1]!, seconds: parts[2]!);
    }
    return null;
  }
}
