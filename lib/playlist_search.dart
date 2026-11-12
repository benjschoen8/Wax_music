import 'dart:convert';
import 'dart:io';
import 'cache.dart';

import 'log.dart';
import 'models/track.dart';

/// Represents an artist's full page on YouTube Music (Spotify-like profile).
class ArtistDetails {
  final String id;
  final String name;
  final String? bannerThumb;
  final String? subscriberCount;
  final List<Track> topSongs;
  final List<PlaylistHit> albums;
  final List<PlaylistHit> singles;

  const ArtistDetails({
    required this.id,
    required this.name,
    this.bannerThumb,
    this.subscriberCount,
    this.topSongs = const [],
    this.albums = const [],
    this.singles = const [],
  });
}

/// Represents a playlist, album, or artist search hit with creator attribution and verification status.
class PlaylistHit {
  final String id;
  final String title;
  final String author;
  final bool isVerified;
  final int videoCount;
  final String thumbnail;
  final bool isAlbum;
  final bool isArtist;
  final String? year;

  const PlaylistHit({
    required this.id,
    required this.title,
    required this.author,
    required this.isVerified,
    required this.videoCount,
    required this.thumbnail,
    this.isAlbum = false,
    this.isArtist = false,
    this.year,
  });
}

/// Searches YouTube and YouTube Music for official albums and playlists,
/// extracting creator attribution, verified status, track count, and cover art.
class PlaylistSearchService {
  static PlaylistHit? matchAlbum(
    Iterable<PlaylistHit> hits, String album, String artist,
  ) {
    String key(String s) => s.toLowerCase().replaceAll(_reTopicSuffix, '')
        .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
        .trim();
    final wantedAlbum = key(album);
    final wantedArtist = key(artist);
    if (wantedAlbum.isEmpty || wantedArtist.isEmpty) return null;
    for (final hit in hits) {
      if (hit.isAlbum && key(hit.title) == wantedAlbum &&
          key(hit.author) == wantedArtist) {
        return hit;
      }
    }
    return null;
  }

  static final HttpClient _client = HttpClient()
    ..autoUncompress = true
    ..idleTimeout = const Duration(seconds: 60)
    ..connectionTimeout = const Duration(seconds: 5);

  static const Duration _cacheTtl = Duration(minutes: 5);

  static final Map<String, (DateTime, List<PlaylistHit>)> _searchCache = {};
  static final Map<String, (DateTime, List<PlaylistHit>)> _artistSearchCache = {};
  static final Map<String, (DateTime, ({String title, String artist, String? year, String thumb, List<Track> tracks}))> _albumCache = {};
  static final Map<String, (DateTime, ArtistDetails)> _artistCache = {};
  static final Map<String, (DateTime, List<String>)> _suggestionCache = {};

  static final RegExp _reFullAlbum = RegExp(
    r'\s*[\(\[](?:full\s+)?album(?:[^\)\]]*)?[\)\]]',
    caseSensitive: false,
  );
  static final RegExp _rePlaylist = RegExp(
    r'\s*[\(\[]playlist[\)\]]',
    caseSensitive: false,
  );
  static final RegExp _reComplete = RegExp(
    r'\s*[\(\[]complete[\)\]]',
    caseSensitive: false,
  );
  static final RegExp _reOst = RegExp(r'\s*[\(\[]ost[\)\]]', caseSensitive: false);
  static final RegExp _reDashAlbum = RegExp(
    r'\s*[\-\–]\s*(?:full\s+)?album',
    caseSensitive: false,
  );
  static final RegExp _reYear = RegExp(r'^\b(19\d\d|20\d\d)\b$');
  static final RegExp _reThumb = RegExp(r'=w\d+-h\d+.*$');
  static final RegExp _reVideoCount = RegExp(r'(\d+)\s*(?:videos?|tracks?)', caseSensitive: false);
  static final RegExp _reTopicSuffix = RegExp(r'\s*-\s*Topic$', caseSensitive: false);

  static void clearCache() {
    _searchCache.clear();
    _artistSearchCache.clear();
    _albumCache.clear();
    _artistCache.clear();
    _suggestionCache.clear();
  }

  /// Clean playlist/album titles like "Future Nostalgia [Full Album]" to "Future Nostalgia".
  static String cleanAlbumTitle(String title) {
    return title
        .replaceAll(_reFullAlbum, '')
        .replaceAll(_rePlaylist, '')
        .replaceAll(_reComplete, '')
        .replaceAll(_reOst, '')
        .replaceAll(_reDashAlbum, '')
        .trim();
  }

  /// Fetches fast autocomplete suggestions for a search query.
  static Future<List<String>> getSuggestions(String query) async {
    final q = query.trim();
    if (q.isEmpty || q.startsWith('http')) return const [];

    final cacheKey = q.toLowerCase();
    final cached = _suggestionCache[cacheKey];
    if (cached != null && DateTime.now().difference(cached.$1) < _cacheTtl) {
      return cached.$2;
    }

    try {
      final uri = Uri.parse(
        'https://suggestqueries.google.com/complete/search?client=firefox&ds=yt&q=${Uri.encodeComponent(q)}',
      );
      final req = await _client.getUrl(uri).timeout(const Duration(seconds: 2));
      req.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0');
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip, deflate');
      final res = await req.close().timeout(const Duration(seconds: 2));
      if (res.statusCode == 200) {
        final body = await res.transform(utf8.decoder).join();
        final data = jsonDecode(body);
        if (data is List && data.length > 1 && data[1] is List) {
          final list = (data[1] as List)
              .map((e) => e.toString().trim())
              .where((s) => s.isNotEmpty)
              .take(8)
              .toList();
          if (_suggestionCache.length > 100) _suggestionCache.remove(_suggestionCache.keys.first);
          _suggestionCache[cacheKey] = (DateTime.now(), list);
          return list;
        }
      }
    } catch (_) {}
    return const [];
  }

  static Future<List<PlaylistHit>> search(
    String query, {
    bool verifiedOnly = false,
    bool albumsOnly = false,
    int limit = 20,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    final cacheKey = '$q|$verifiedOnly|$albumsOnly|$limit';
    final cached = _searchCache[cacheKey];
    if (cached != null && DateTime.now().difference(cached.$1) < _cacheTtl) {
      return cached.$2;
    }

    final results = <PlaylistHit>[];
    final seen = <String>{};

    void addHit(PlaylistHit hit) {
      if (seen.add(hit.id)) {
        if (!verifiedOnly || hit.isVerified) {
          results.add(hit);
        }
      }
    }

    try {
      if (albumsOnly) {
        // Query official YouTube Music albums only
        await _searchYtmAlbums(q, addHit);
      } else {
        // Run YouTube Music albums, featured playlists, and YouTube playlists concurrently
        final albumHits = <PlaylistHit>[];
        final featuredHits = <PlaylistHit>[];
        final ytHits = <PlaylistHit>[];

        final futures = <Future<void>>[
          _searchYtmAlbums(q, albumHits.add),
          _searchYtmFeatured(q, featuredHits.add),
        ];
        if (!verifiedOnly) {
          futures.add(_searchYoutubePlaylists(q, ytHits.add, limit: limit));
        }

        await Future.wait(futures);

        // Priority merge: Official Albums first, then Curated Featured, then YouTube Playlists
        for (final h in albumHits) {
          addHit(h);
        }
        for (final h in featuredHits) {
          if (results.length >= limit) break;
          addHit(h);
        }
        for (final h in ytHits) {
          if (results.length >= limit) break;
          addHit(h);
        }
      }
    } catch (e, st) {
      AppLog.error('playlist search error for "$q"', e, st);
    }

    final out = results.take(limit).toList();
    if (out.isNotEmpty) {
      if (_searchCache.length > 60) _searchCache.remove(_searchCache.keys.first);
      putBounded(_searchCache, cacheKey, (DateTime.now(), out), max: 100);
    }
    return out;
  }

  /// Searches official albums and EPs on YouTube Music.
  static Future<void> _searchYtmAlbums(
    String query,
    void Function(PlaylistHit) onHit,
  ) async {
    final ctx = {
      'client': {
        'clientName': 'WEB_REMIX',
        'clientVersion': '1.20240401.01.00',
        'hl': 'en',
        'gl': 'US',
      },
    };

    try {
      final req = await _client
          .postUrl(Uri.parse('https://music.youtube.com/youtubei/v1/search'))
          .timeout(const Duration(seconds: 6));
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.headers.set(HttpHeaders.userAgentHeader, 'Wax/1.0');
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip, deflate');
      req.add(utf8.encode(jsonEncode({
        'context': ctx,
        'query': query,
        'params': 'EgWKAQIYAWoQEAMQBBAJEAoQBRAREBAQFQ%3D%3D', // Albums filter
      })));
      final res = await req.close().timeout(const Duration(seconds: 6));
      final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
      final sections = body['contents']?['tabbedSearchResultsRenderer']?['tabs']?[0]?['tabRenderer']?['content']?['sectionListRenderer']?['contents'] as List?;
      final shelf = sections?[0]['musicShelfRenderer'];
      for (final item in (shelf?['contents'] as List?) ?? const []) {
        final flex = item['musicResponsiveListItemRenderer'];
        if (flex != null) {
          final title = (flex['flexColumns']?[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'] as List?)
                  ?.map((r) => r['text']?.toString() ?? '')
                  .join()
                  .trim() ??
              '';
          final subRuns = flex['flexColumns']?[1]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'] as List?;
          String author = '';
          String? year;
          for (final r in subRuns ?? const []) {
            final t = r['text']?.toString().trim() ?? '';
            final pt = r['navigationEndpoint']?['browseEndpoint']?['browseEndpointContextSupportedConfigs']?['browseEndpointContextMusicConfig']?['pageType'];
            if (pt == 'MUSIC_PAGE_TYPE_ARTIST') {
              author = t;
            } else if (_reYear.hasMatch(t)) {
              year = t;
            }
          }
          if (author.isEmpty && subRuns != null && subRuns.isNotEmpty) {
            final nonBullets = subRuns
                .map((r) => r['text']?.toString().trim() ?? '')
                .where((t) => t != '•' && !t.toLowerCase().contains('album') && !t.toLowerCase().contains('single') && !t.toLowerCase().contains('ep'))
                .toList();
            for (final token in nonBullets) {
              if (_reYear.hasMatch(token)) {
                year = token;
              } else if (author.isEmpty && token.isNotEmpty) {
                author = token;
              }
            }
          }
          final browseId = flex['navigationEndpoint']?['browseEndpoint']?['browseId']?.toString();
          final thumbs = flex['thumbnail']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'] as List?;
          String thumb = (thumbs != null && thumbs.isNotEmpty) ? thumbs.last['url']?.toString() ?? '' : '';
          if (thumb.contains('googleusercontent.com') && thumb.contains('=')) {
            thumb = thumb.replaceFirst(_reThumb, '=w544-h544-l90-rj');
          }

          if (browseId != null && title.isNotEmpty) {
            onHit(PlaylistHit(
              id: browseId,
              title: title,
              author: author.isNotEmpty ? author : 'Official Release',
              isVerified: true,
              videoCount: 0,
              thumbnail: thumb,
              isAlbum: true,
              year: year,
            ));
          }
        }
      }
    } catch (_) {}
  }

  /// Loads an official album from YouTube Music by its browseId (e.g. "MPREb_iWdtzQKst5b" or "OLAK5uy_...").
  static Future<({String title, String artist, String? year, String thumb, List<Track> tracks})?> loadAlbum(String browseId) async {
    final cached = _albumCache[browseId];
    if (cached != null && DateTime.now().difference(cached.$1) < _cacheTtl) {
      return cached.$2;
    }

    final ctx = {
      'client': {
        'clientName': 'WEB_REMIX',
        'clientVersion': '1.20240401.01.00',
        'hl': 'en',
        'gl': 'US',
      },
    };

    final effId = browseId.startsWith('OLAK5') ? 'VL$browseId' : browseId;

    try {
      final req = await _client
          .postUrl(Uri.parse('https://music.youtube.com/youtubei/v1/browse'))
          .timeout(const Duration(seconds: 8));
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.headers.set(HttpHeaders.userAgentHeader, 'Wax/1.0');
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip, deflate');
      req.add(utf8.encode(jsonEncode({
        'context': ctx,
        'browseId': effId,
      })));

      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;

      final twoCol = body['contents']?['twoColumnBrowseResultsRenderer'] as Map<String, dynamic>?;
      final header = (twoCol?['tabs'] as List?)?[0]?['tabRenderer']?['content']?['sectionListRenderer']?['contents']?[0]?['musicResponsiveHeaderRenderer'] as Map<String, dynamic>?;

      final title = (header?['title']?['runs'] as List?)?.map((r) => r['text']?.toString() ?? '').join().trim() ?? '';
      final artist = (header?['straplineTextOne']?['runs'] as List?)?.map((r) => r['text']?.toString() ?? '').join().trim() ?? '';

      String? year;
      final subRuns = header?['subtitle']?['runs'] as List?;
      for (final r in subRuns ?? const []) {
        final t = r['text']?.toString().trim() ?? '';
        if (_reYear.hasMatch(t)) {
          year = t;
          break;
        }
      }

      final thumbs = header?['thumbnail']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'] as List?;
      String thumb = '';
      if (thumbs != null && thumbs.isNotEmpty) {
        thumb = thumbs.last['url']?.toString() ?? '';
        if (thumb.contains('googleusercontent.com') && thumb.contains('=')) {
          thumb = thumb.replaceFirst(_reThumb, '=w544-h544-l90-rj');
        }
      }

      final secContents = twoCol?['secondaryContents']?['sectionListRenderer']?['contents'] as List?;
      final shelf = (secContents?[0]?['musicShelfRenderer'] ?? secContents?[0]?['musicPlaylistShelfRenderer']) as Map<String, dynamic>?;
      final items = shelf?['contents'] as List?;

      final tracks = <Track>[];
      for (final it in items ?? const []) {
        if (it is! Map<String, dynamic>) continue;
        final flex = it['musicResponsiveListItemRenderer'] as Map<String, dynamic>?;
        if (flex == null) continue;

        // Album rows can expose two ids: the row's playlistItemData id and the
        // play button's watch id (which is tagged with its musicVideoType).
        // Use the play-button id when it is the audio release (ATV), so we
        // never queue the music-video cut of a song.
        final watch = flex['overlay']?['musicItemThumbnailOverlayRenderer']?['content']?['musicPlayButtonRenderer']?['playNavigationEndpoint']?['watchEndpoint'] as Map<String, dynamic>?;
        final watchId = watch?['videoId']?.toString();
        final watchType = watch?['watchEndpointMusicSupportedConfigs']?['watchEndpointMusicConfig']?['musicVideoType']?.toString();
        final itemId = flex['playlistItemData']?['videoId']?.toString();
        final videoId = (watchId != null && watchId.isNotEmpty && watchType == 'MUSIC_VIDEO_TYPE_ATV')
            ? watchId
            : (itemId != null && itemId.isNotEmpty ? itemId : watchId);
        if (videoId == null || videoId.isEmpty) continue;

        final tTitle = (flex['flexColumns']?[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'] as List?)
            ?.map((r) => r['text']?.toString() ?? '')
            .join()
            .trim() ?? '';
        if (tTitle.isEmpty) continue;

        final tSubRuns = flex['flexColumns']?[1]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'] as List?;
        String tArtist = '';
        if (tSubRuns != null && tSubRuns.isNotEmpty) {
          tArtist = tSubRuns.map((r) => r['text']?.toString() ?? '').join().trim();
        }
        if (tArtist.isEmpty) tArtist = artist.isNotEmpty ? artist : 'Unknown';

        Duration? dur;
        final fixedRuns = flex['fixedColumns']?[0]?['musicResponsiveListItemFixedColumnRenderer']?['text']?['runs'] as List?;
        if (fixedRuns != null && fixedRuns.isNotEmpty) {
          final durStr = fixedRuns[0]?['text']?.toString().trim() ?? '';
          dur = _parseDuration(durStr);
        }

        final tThumb = thumb.isNotEmpty ? thumb : 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';
        final tAuthor = tArtist.endsWith('- Topic') ? tArtist : '$tArtist - Topic';

        tracks.add(Track(
          videoId,
          tTitle,
          tAuthor,
          tThumb,
          dur,
          album: title.isNotEmpty ? title : null,
          uploadDate: year,
        ));
      }

      final result = (
        title: title,
        artist: artist,
        year: year,
        thumb: thumb,
        tracks: tracks,
      );
      if (_albumCache.length > 50) _albumCache.remove(_albumCache.keys.first);
      putBounded(_albumCache, browseId, (DateTime.now(), result), max: 50);
      return result;
    } catch (e, st) {
      AppLog.error('load album error for "$browseId"', e, st);
    }
    return null;
  }

  /// Loads an artist page from YouTube Music by their browseId (e.g. "UCzVb0SIXp9q9PeKCcFjsBtA").
  static Future<ArtistDetails?> loadArtist(String browseId) async {
    final cached = _artistCache[browseId];
    if (cached != null && DateTime.now().difference(cached.$1) < _cacheTtl) {
      return cached.$2;
    }

    final ctx = {
      'client': {
        'clientName': 'WEB_REMIX',
        'clientVersion': '1.20240401.01.00',
        'hl': 'en',
        'gl': 'US',
      },
    };

    try {
      final req = await _client
          .postUrl(Uri.parse('https://music.youtube.com/youtubei/v1/browse'))
          .timeout(const Duration(seconds: 8));
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.headers.set(HttpHeaders.userAgentHeader, 'Wax/1.0');
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip, deflate');
      req.add(utf8.encode(jsonEncode({
        'context': ctx,
        'browseId': browseId,
      })));

      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;

      final immHeader = body['header']?['musicImmersiveHeaderRenderer'] as Map<String, dynamic>?;
      final visHeader = body['header']?['musicVisualHeaderRenderer'] as Map<String, dynamic>?;
      final header = immHeader ?? visHeader;

      final name = (header?['title']?['runs'] as List?)
              ?.map((r) => r['text']?.toString() ?? '')
              .join()
              .trim() ??
          '';

      final subs = immHeader?['subscriptionButton']?['subscribeButtonRenderer']?['subscriberCountWithSubscribeText']?['runs']?[0]?['text']?.toString() ??
          immHeader?['subscriptionButton']?['subscribeButtonRenderer']?['longSubscriberCountText']?['runs']?[0]?['text']?.toString() ??
          visHeader?['subscriberCountText']?['runs']?[0]?['text']?.toString();

      final thumbs = (header?['thumbnail']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'] as List?) ??
          (header?['foregroundThumbnail']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'] as List?);
      String bannerThumb = '';
      if (thumbs != null && thumbs.isNotEmpty) {
        bannerThumb = thumbs.last['url']?.toString() ?? '';
      }

      final contents = body['contents']?['singleColumnBrowseResultsRenderer']?['tabs']?[0]?['tabRenderer']?['content']?['sectionListRenderer']?['contents'] as List?;

      final topSongs = <Track>[];
      final albums = <PlaylistHit>[];
      final singles = <PlaylistHit>[];

      for (final sec in contents ?? const []) {
        if (sec is! Map<String, dynamic>) continue;

        // 1. Top Songs shelf
        final shelf = sec['musicShelfRenderer'];
        if (shelf != null) {
          final sTitle = (shelf['title']?['runs'] as List?)
                  ?.map((r) => r['text']?.toString() ?? '')
                  .join()
                  .trim()
                  .toLowerCase() ??
              '';
          if (sTitle.contains('song')) {
            final items = shelf['contents'] as List?;
            for (final it in items ?? const []) {
              final flex = it['musicResponsiveListItemRenderer'];
              if (flex == null) continue;

              final videoId = flex['playlistItemData']?['videoId']?.toString() ??
                  flex['overlay']?['musicItemThumbnailOverlayRenderer']?['content']?['musicPlayButtonRenderer']?['playNavigationEndpoint']?['watchEndpoint']?['videoId']?.toString() ??
                  (flex['flexColumns']?[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'] as List?)?[0]?['navigationEndpoint']?['watchEndpoint']?['videoId']?.toString();
              if (videoId == null || videoId.isEmpty) continue;

              final tTitle = (flex['flexColumns']?[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'] as List?)
                      ?.map((r) => r['text']?.toString() ?? '')
                      .join()
                      .trim() ??
                  '';
              if (tTitle.isEmpty) continue;

              String? albumName;
              String? albumBrowseId;
              final fCols = flex['flexColumns'] as List?;
              for (final col in fCols ?? const []) {
                final runs = col['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'] as List?;
                for (final r in runs ?? const []) {
                  final pt = r['navigationEndpoint']?['browseEndpoint']?['browseEndpointContextSupportedConfigs']?['browseEndpointContextMusicConfig']?['pageType'];
                  if (pt == 'MUSIC_PAGE_TYPE_ALBUM') {
                    albumName = r['text']?.toString().trim();
                    albumBrowseId = r['navigationEndpoint']?['browseEndpoint']?['browseId']?.toString();
                  }
                }
              }

              final tThumbs = flex['thumbnail']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'] as List?;
              String tThumb = (tThumbs != null && tThumbs.isNotEmpty) ? tThumbs.last['url']?.toString() ?? '' : '';
              if (tThumb.contains('googleusercontent.com') && tThumb.contains('=')) {
                tThumb = tThumb.replaceFirst(_reThumb, '=w544-h544-l90-rj');
              }
              if (tThumb.isEmpty) {
                tThumb = 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';
              }

              Duration? dur;
              final fixedRuns = flex['fixedColumns']?[0]?['musicResponsiveListItemFixedColumnRenderer']?['text']?['runs'] as List?;
              if (fixedRuns != null && fixedRuns.isNotEmpty) {
                dur = _parseDuration(fixedRuns[0]?['text']?.toString().trim() ?? '');
              }

              topSongs.add(Track(
                videoId,
                tTitle,
                name.isNotEmpty ? '$name - Topic' : 'Unknown - Topic',
                tThumb,
                dur,
                album: albumName,
                albumBrowseId: albumBrowseId,
                artistBrowseId: browseId,
              ));
            }
          }
        }

        // 2. Carousel shelves: Albums, Singles & EPs
        final carousel = sec['musicCarouselShelfRenderer'];
        if (carousel != null) {
          final cTitle = (carousel['header']?['musicCarouselShelfBasicHeaderRenderer']?['title']?['runs'] as List?)
                  ?.map((r) => r['text']?.toString() ?? '')
                  .join()
                  .trim()
                  .toLowerCase() ??
              '';
          final isAlbums = cTitle.contains('album');
          final isSingles = cTitle.contains('single') || cTitle.contains('ep');

          if (isAlbums || isSingles) {
            final items = carousel['contents'] as List?;
            for (final it in items ?? const []) {
              final twoRow = it['musicTwoRowItemRenderer'];
              if (twoRow == null) continue;

              final title = (twoRow['title']?['runs'] as List?)
                      ?.map((r) => r['text']?.toString() ?? '')
                      .join()
                      .trim() ??
                  '';
              final albBrowseId = twoRow['navigationEndpoint']?['browseEndpoint']?['browseId']?.toString();
              if (title.isEmpty || albBrowseId == null) continue;

              final subRuns = twoRow['subtitle']?['runs'] as List?;
              String? year;
              for (final r in subRuns ?? const []) {
                final t = r['text']?.toString().trim() ?? '';
                if (_reYear.hasMatch(t)) {
                  year = t;
                  break;
                }
              }

              final cThumbs = twoRow['thumbnailRenderer']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'] as List?;
              String cThumb = (cThumbs != null && cThumbs.isNotEmpty) ? cThumbs.last['url']?.toString() ?? '' : '';
              if (cThumb.contains('googleusercontent.com') && cThumb.contains('=')) {
                cThumb = cThumb.replaceFirst(_reThumb, '=w544-h544-l90-rj');
              }

              final hit = PlaylistHit(
                id: albBrowseId,
                title: title,
                author: name,
                isVerified: true,
                videoCount: 0,
                thumbnail: cThumb,
                isAlbum: true,
                year: year,
              );

              if (isAlbums) {
                albums.add(hit);
              } else {
                singles.add(hit);
              }
            }
          }
        }
      }

      final result = ArtistDetails(
        id: browseId,
        name: name,
        bannerThumb: bannerThumb.isNotEmpty ? bannerThumb : null,
        subscriberCount: subs,
        topSongs: topSongs,
        albums: albums,
        singles: singles,
      );
      if (_artistCache.length > 50) _artistCache.remove(_artistCache.keys.first);
      putBounded(_artistCache, browseId, (DateTime.now(), result), max: 50);
      return result;
    } catch (e, st) {
      AppLog.error('load artist error for "$browseId"', e, st);
    }
    return null;
  }

  /// Searches YouTube Music for artists matching the query.
  static Future<List<PlaylistHit>> searchArtists(String query, {int limit = 10}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    final cacheKey = '$q|$limit';
    final cached = _artistSearchCache[cacheKey];
    if (cached != null && DateTime.now().difference(cached.$1) < _cacheTtl) {
      return cached.$2;
    }

    final ctx = {
      'client': {
        'clientName': 'WEB_REMIX',
        'clientVersion': '1.20240401.01.00',
        'hl': 'en',
        'gl': 'US',
      },
    };

    final results = <PlaylistHit>[];
    try {
      final req = await _client
          .postUrl(Uri.parse('https://music.youtube.com/youtubei/v1/search'))
          .timeout(const Duration(seconds: 6));
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.headers.set(HttpHeaders.userAgentHeader, 'Wax/1.0');
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip, deflate');
      req.add(utf8.encode(jsonEncode({
        'context': ctx,
        'query': q,
        'params': 'EgWKAQIgAWoSEAUQCRADEA4QBBAQEAoQFRAR', // Filter: Artists
      })));

      final res = await req.close().timeout(const Duration(seconds: 6));
      final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
      final sections = body['contents']?['tabbedSearchResultsRenderer']?['tabs']?[0]?['tabRenderer']?['content']?['sectionListRenderer']?['contents'] as List?;
      final shelf = sections?[0]['musicShelfRenderer'];

      for (final item in (shelf?['contents'] as List?) ?? const []) {
        final flex = item['musicResponsiveListItemRenderer'];
        if (flex != null) {
          final name = (flex['flexColumns']?[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'] as List?)
                  ?.map((r) => r['text']?.toString() ?? '')
                  .join()
                  .trim() ??
              '';
          final sub = (flex['flexColumns']?[1]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'] as List?)
                  ?.map((r) => r['text']?.toString() ?? '')
                  .join()
                  .trim() ??
              '';
          final browseId = flex['navigationEndpoint']?['browseEndpoint']?['browseId']?.toString();
          final thumbs = flex['thumbnail']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'] as List?;
          String thumb = (thumbs != null && thumbs.isNotEmpty) ? thumbs.last['url']?.toString() ?? '' : '';
          if (thumb.contains('googleusercontent.com') && thumb.contains('=')) {
            thumb = thumb.replaceFirst(_reThumb, '=w544-h544-l90-rj');
          }

          if (browseId != null && name.isNotEmpty) {
            results.add(PlaylistHit(
              id: browseId,
              title: name,
              author: sub.isNotEmpty ? sub : 'Artist',
              isVerified: true,
              videoCount: 0,
              thumbnail: thumb,
              isArtist: true,
            ));
          }
        }
      }
    } catch (e, st) {
      AppLog.error('search artists error for "$q"', e, st);
    }

    final out = results.take(limit).toList();
    if (out.isNotEmpty) {
      if (_artistSearchCache.length > 50) _artistSearchCache.remove(_artistSearchCache.keys.first);
      putBounded(_artistSearchCache, cacheKey, (DateTime.now(), out), max: 100);
    }
    return out;
  }

  /// Resolves an artist's browseId from their name.
  static Future<String?> findArtistBrowseId(String artistName) async {
    final clean = artistName.replaceAll(_reTopicSuffix, '').trim();
    if (clean.isEmpty) return null;
    final hits = await searchArtists(clean, limit: 1);
    return hits.isNotEmpty ? hits.first.id : null;
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

  static Future<void> _searchYtmFeatured(
    String query,
    void Function(PlaylistHit) onHit,
  ) async {
    final ctx = {
      'client': {
        'clientName': 'WEB_REMIX',
        'clientVersion': '1.20240401.01.00',
        'hl': 'en',
        'gl': 'US',
      },
    };

    // Query Featured playlists (curated by YouTube Music & official artists)
    try {
      final req = await _client
          .postUrl(Uri.parse('https://music.youtube.com/youtubei/v1/search'))
          .timeout(const Duration(seconds: 6));
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.headers.set(HttpHeaders.userAgentHeader, 'Wax/1.0');
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip, deflate');
      req.add(utf8.encode(jsonEncode({
        'context': ctx,
        'query': query,
        'params': 'EgeKAQQoADgBahIQBRADEAkQBBAKEBAQFRAOEBE%3D', // Featured playlists
      })));
      final res = await req.close().timeout(const Duration(seconds: 6));
      final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
      final sections = body['contents']?['tabbedSearchResultsRenderer']?['tabs']?[0]?['tabRenderer']?['content']?['sectionListRenderer']?['contents'] as List?;
      final shelf = sections?[0]['musicShelfRenderer'];
      for (final item in (shelf?['contents'] as List?) ?? const []) {
        final flex = item['musicResponsiveListItemRenderer'];
        if (flex != null) {
          final title = (flex['flexColumns']?[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'] as List?)
                  ?.map((r) => r['text']?.toString() ?? '')
                  .join()
                  .trim() ??
              '';
          final subRuns = flex['flexColumns']?[1]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'] as List?;
          final author = subRuns?.firstOrNull?['text']?.toString().trim() ?? 'YouTube Music';
          var plId = flex['navigationEndpoint']?['browseEndpoint']?['browseId']?.toString() ??
              flex['overlay']?['musicItemThumbnailOverlayRenderer']?['content']?['musicPlayButtonRenderer']?['playNavigationEndpoint']?['watchPlaylistEndpoint']?['playlistId']?.toString();
          if (plId != null && plId.startsWith('VL')) {
            plId = plId.substring(2);
          }
          final thumbs = flex['thumbnail']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'] as List?;
          final thumb = (thumbs != null && thumbs.isNotEmpty) ? thumbs.last['url']?.toString() ?? '' : '';

          if (plId != null && title.isNotEmpty) {
            onHit(PlaylistHit(
              id: plId,
              title: title,
              author: author,
              isVerified: true,
              videoCount: 0,
              thumbnail: thumb,
            ));
          }
        }
      }
    } catch (_) {}
  }

  static Future<void> _searchYoutubePlaylists(
    String query,
    void Function(PlaylistHit) onHit, {
    required int limit,
  }) async {
    final ctx = {
      'client': {
        'clientName': 'WEB',
        'clientVersion': '2.20240401.01.00',
        'hl': 'en',
        'gl': 'US',
      },
    };

    final req = await _client
        .postUrl(Uri.parse('https://www.youtube.com/youtubei/v1/search'))
        .timeout(const Duration(seconds: 8));
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)');
    req.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip, deflate');
    req.add(utf8.encode(jsonEncode({
      'context': ctx,
      'query': query,
      'params': 'EgIQAw%3D%3D', // Playlists filter
    })));

    final res = await req.close().timeout(const Duration(seconds: 8));
    final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;

    final contents = body['contents']?['twoColumnSearchResultsRenderer']?['primaryContents']?['sectionListRenderer']?['contents'] as List?;
    for (final sec in contents ?? const []) {
      final items = sec['itemSectionRenderer']?['contents'] as List?;
      for (final it in items ?? const []) {
        if (it is! Map<String, dynamic>) continue;
        final lockup = it['lockupViewModel'];
        if (lockup is Map<String, dynamic>) {
          final hit = _parseLockup(lockup);
          if (hit != null) onHit(hit);
        }
        final pl = it['playlistRenderer'];
        if (pl is Map<String, dynamic>) {
          final hit = _parsePlaylistRenderer(pl);
          if (hit != null) onHit(hit);
        }
      }
    }
  }

  static PlaylistHit? _parseLockup(Map<String, dynamic> lockup) {
    final contentId = lockup['contentId']?.toString();
    if (contentId == null || contentId.isEmpty) return null;

    final meta = lockup['metadata']?['lockupMetadataViewModel'];
    final title = meta?['title']?['content']?.toString() ?? '';
    if (title.isEmpty) return null;

    final rows = meta?['metadata']?['contentMetadataViewModel']?['metadataRows'] as List?;
    String author = '';
    bool isVerified = false;

    for (final row in rows ?? const []) {
      for (final part in row['metadataParts'] ?? const []) {
        final text = part['text']?['content']?.toString().trim() ?? '';
        final badge = part['badge'] ?? part['attachment'] ?? part['icon'];
        if (badge != null) {
          final badgeStr = jsonEncode(badge).toLowerCase();
          if (badgeStr.contains('verified') ||
              badgeStr.contains('check_circle') ||
              badgeStr.contains('artist')) {
            isVerified = true;
          }
        }
        if (author.isEmpty &&
            text.isNotEmpty &&
            text != 'Playlist' &&
            !text.contains('tracks') &&
            !text.contains('videos')) {
          author = text;
        }
      }
    }

    int videoCount = 0;
    final overlays = lockup['contentImage']?['collectionThumbnailViewModel']?['primaryThumbnail']?['thumbnailViewModel']?['overlays'] as List?;
    for (final ov in overlays ?? const []) {
      final badges = ov['thumbnailOverlayBadgeViewModel']?['thumbnailBadges'] as List?;
      for (final b in badges ?? const []) {
        final text = b['thumbnailBadgeViewModel']?['text']?.toString() ?? '';
        final m = _reVideoCount.firstMatch(text);
        if (m != null) {
          videoCount = int.tryParse(m.group(1)!) ?? 0;
          break;
        }
      }
    }

    String thumb = '';
    final thumbs = lockup['contentImage']?['collectionThumbnailViewModel']?['primaryThumbnail']?['thumbnailViewModel']?['image']?['sources'] as List?;
    if (thumbs != null && thumbs.isNotEmpty) {
      thumb = thumbs.last['url']?.toString() ?? '';
    }

    if (!isVerified) {
      final aLower = author.toLowerCase();
      if (aLower == 'youtube music' ||
          aLower == 'youtube' ||
          aLower.endsWith('- topic')) {
        isVerified = true;
      }
    }

    return PlaylistHit(
      id: contentId,
      title: title,
      author: author.isEmpty ? 'Unknown' : author,
      isVerified: isVerified,
      videoCount: videoCount,
      thumbnail: thumb,
    );
  }

  static PlaylistHit? _parsePlaylistRenderer(Map<String, dynamic> pl) {
    final id = pl['playlistId']?.toString();
    if (id == null || id.isEmpty) return null;

    final title = pl['title']?['simpleText']?.toString() ??
        (pl['title']?['runs'] as List?)?.map((r) => r['text']?.toString() ?? '').join() ??
        '';
    if (title.isEmpty) return null;

    final author = (pl['shortBylineText']?['runs'] as List?)
            ?.map((r) => r['text']?.toString() ?? '')
            .join()
            .trim() ??
        '';
    final badges = pl['ownerBadges'] as List?;
    bool isVerified = badges != null && badges.isNotEmpty;
    if (!isVerified) {
      final aLower = author.toLowerCase();
      if (aLower == 'youtube music' ||
          aLower == 'youtube' ||
          aLower.endsWith('- topic')) {
        isVerified = true;
      }
    }

    final videoCount = int.tryParse(pl['videoCount']?.toString() ?? '') ?? 0;
    final thumbs = pl['thumbnails'] as List?;
    final thumb = (thumbs != null && thumbs.isNotEmpty) ? thumbs.last['url']?.toString() ?? '' : '';

    return PlaylistHit(
      id: id,
      title: title,
      author: author.isEmpty ? 'Unknown' : author,
      isVerified: isVerified,
      videoCount: videoCount,
      thumbnail: thumb,
    );
  }
}
