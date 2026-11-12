import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;

import 'package:collection/collection.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'log.dart';
import 'cache.dart';
import 'models/track.dart';

enum Script { latin, hangul, kana, han, cyrillic, arabic, hebrew, thai, devanagari, greek }

class LyricsResult {
  final String lyrics;
  final bool isSynced;
  final String source; // 'lrclib', 'youtube_captions', or 'youtube_music'

  const LyricsResult({
    required this.lyrics,
    required this.isSynced,
    required this.source,
  });
}

class LyricsCandidate {
  final String title;
  final String artist;
  const LyricsCandidate(this.title, this.artist);
}

/// Lyrics lookup that makes no assumption about "the" language of a song.
///
/// The old version guessed ONE language per song (from the title / a hard-coded
/// artist list, defaulting to English) and then rejected or preferred lyrics by
/// script. For multilingual songs that guess is wrong by construction: an
/// English-titled K-pop/J-pop/C-pop song was "English", so its correct lyrics
/// were thrown away and a wrong-language version won; any Arabic lyrics were
/// always rejected; and speech-recognition captions (one language for the whole
/// song) outranked correct plain lyrics.
///
/// Now a candidate is accepted because it IS this recording (duration within a
/// few seconds + title/artist similarity), never because of its script. Script
/// is only a small tie-breaking bonus.
class LyricsService {
  static const _userAgent = 'Wax/1.0 (https://github.com/wax)';

  // ---------------------------------------------------------------- scripts

  static Script? scriptOf(int r) {
    if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A) || (r >= 0xC0 && r <= 0x24F)) {
      return Script.latin;
    }
    if ((r >= 0xAC00 && r <= 0xD7AF) || (r >= 0x1100 && r <= 0x11FF) || (r >= 0x3130 && r <= 0x318F)) {
      return Script.hangul;
    }
    if ((r >= 0x3040 && r <= 0x30FF) || (r >= 0x31F0 && r <= 0x31FF)) return Script.kana;
    if ((r >= 0x4E00 && r <= 0x9FFF) || (r >= 0x3400 && r <= 0x4DBF)) return Script.han;
    if (r >= 0x400 && r <= 0x4FF) return Script.cyrillic;
    if ((r >= 0x600 && r <= 0x6FF) || (r >= 0x750 && r <= 0x77F)) return Script.arabic;
    if (r >= 0x590 && r <= 0x5FF) return Script.hebrew;
    if (r >= 0xE00 && r <= 0xE7F) return Script.thai;
    if (r >= 0x900 && r <= 0x97F) return Script.devanagari;
    if (r >= 0x370 && r <= 0x3FF) return Script.greek;
    return null;
  }

  static final _lrcStamp = RegExp(r'\[\d+:\d+(?:[.:]\d+)?\]');

  /// Share of letters per script (timestamps, digits, punctuation ignored).
  static Map<Script, double> scriptShares(String text) {
    final counts = <Script, int>{};
    var total = 0;
    for (final r in text.replaceAll(_lrcStamp, '').runes) {
      final s = scriptOf(r);
      if (s == null) continue;
      counts[s] = (counts[s] ?? 0) + 1;
      total++;
    }
    if (total == 0) return const {};
    return {for (final e in counts.entries) e.key: e.value / total};
  }

  /// Non-Latin scripts visible in the title/channel (empty for Latin-only).
  static Set<Script> hintScripts(Track t) {
    final counts = <Script, int>{};
    for (final r in '${t.title} ${t.author}'.runes) {
      final s = scriptOf(r);
      if (s != null && s != Script.latin) counts[s] = (counts[s] ?? 0) + 1;
    }
    return {for (final e in counts.entries) if (e.value >= 2) e.key};
  }

  static bool _agrees(String lyrics, Set<Script> hints) {
    if (hints.isEmpty) return false;
    final s = scriptShares(lyrics);
    return hints.any((h) => (s[h] ?? 0) >= 0.02);
  }

  // ------------------------------------------------------------- similarity

  static String _norm(String s) => stripAllBrackets(s)
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

  /// 0..1 similarity that works for any script (character-bigram Dice).
  static double similarity(String a, String b) => _sim(a, b);
  static double _sim(String a, String b) {
    final x = _norm(a), y = _norm(b);
    if (x.isEmpty || y.isEmpty) return 0;
    if (x == y) return 1;
    if (x.length >= 3 && y.length >= 3 && (x.contains(y) || y.contains(x))) {
      return 0.85;
    }
    Set<String> bi(String s) => s.length < 2
        ? {s}
        : {for (var i = 0; i < s.length - 1; i++) s.substring(i, i + 2)};
    final p = bi(x), q = bi(y);
    return 2 * p.intersection(q).length / (p.length + q.length);
  }

  /// Clean artist name from channel noise (VEVO, Official prefix, etc.)
  static String cleanArtist(String artist) {
    var a = cleanForSearch(artist);
    if (a.toLowerCase().startsWith('official') && a.length > 8) {
      final stripped = a.substring(8).trim();
      if (stripped.isNotEmpty) a = stripped;
    }
    a = a
        .replaceFirst(
          RegExp(
            r'\s*(VEVO|Official|Records|Entertainment)$',
            caseSensitive: false,
          ),
          '',
        )
        .trim();

    // If artist contains descriptive Chinese/non-Latin prefix before Latin artist name (e.g. "深夜聆聽 Seafret")
    final mixedMatch = RegExp(r'^(?:[^\x00-\x7F\s]+\s+)+([a-zA-Z0-9\s]+)$').firstMatch(a);
    if (mixedMatch != null) {
      final cand = mixedMatch.group(1)!.trim();
      if (cand.isNotEmpty) return cand;
    }
    return a;
  }

  /// Clean artist and title for higher search matching accuracy
  static String cleanForSearch(String input) {
    var s = input
        .replaceFirst(
          RegExp(
            r'^\s*(\d+[\.\-\s_]+|track\s*\d+[\.\-\s_]*)',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'\s*[\(\[【（][^\)\]】）]*(feat\.|ft\.|with|prod\.|official|video|audio|lyrics?|mv|hd|4k|radio edit|edit|clean|explicit|version|soundtrack|ost|animation|remaster|visuali[sz]er)[^\)\]】）]*[\)\]】）]',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(
          RegExp(r'\b(feat\.|ft\.)\s+[^\s,]+', caseSensitive: false),
          '',
        )
        .replaceAll(
          RegExp(r'[\-\–\—\s]*(中文歌詞|动态歌词|動態歌詞|歌词|歌詞|lyrics?|lyric video|official video|color coded)[\-\–\—\s]*', caseSensitive: false),
          ' ',
        )
        .replaceAll(RegExp(r'["“”‘’【】]'), '')
        .replaceAll(RegExp(r'[\u{1F300}-\u{1FAD6}\u{2600}-\u{27BF}]', unicode: true), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    s = s.replaceAll(RegExp(r'^[\-\–\—\s]+|[\-\–\—\s]+$'), '').trim();
    return s;
  }

  static String stripAllBrackets(String input) {
    return input.replaceAll(RegExp(r'\s*[\(\[【（].*?[\)\]】）]'), '').trim();
  }

  /// Generates plausible candidate (title, artist) pairs from YouTube metadata.
  static List<LyricsCandidate> generateCandidates(Track track) {
    final candidates = <LyricsCandidate>[];
    final seen = <String>{};

    void add(String title, String artist) {
      final t = title.trim();
      final a = artist.trim();
      if (t.isEmpty) return;
      final key = '${t.toLowerCase()}|${a.toLowerCase()}';
      if (seen.add(key)) {
        candidates.add(LyricsCandidate(t, a));
      }
    }

    final rawTitle = track.title;
    final rawAuthor =
        track.author.replaceAll(RegExp(r'\s*-\s*Topic$'), '').trim();

    // 1. Standard tagArtist and tagTitle
    final baseTitle = cleanForSearch(track.tagTitle);
    final rawArtist = cleanForSearch(track.tagArtist);
    final baseArtist = cleanArtist(track.tagArtist);
    add(baseTitle, baseArtist);
    if (baseArtist != rawArtist) add(baseTitle, rawArtist);

    // 2. Strip all parenthetical / bracketed info from title
    final noParenTitle = cleanForSearch(stripAllBrackets(track.tagTitle));
    if (noParenTitle.isNotEmpty) {
      add(noParenTitle, baseArtist);
      if (baseArtist != rawArtist) add(noParenTitle, rawArtist);
    }

    // 3. Strip leading track numbering (e.g. "01. ", "1 - ", "10 ")
    final strippedNumTitle = cleanForSearch(
      track.tagTitle.replaceFirst(
        RegExp(
          r'^\s*(\d+[\.\-\s_]+|track\s*\d+[\.\-\s_]*)',
          caseSensitive: false,
        ),
        '',
      ),
    );
    if (strippedNumTitle.isNotEmpty) {
      add(strippedNumTitle, baseArtist);
      add(cleanForSearch(stripAllBrackets(strippedNumTitle)), baseArtist);
      if (baseArtist != rawArtist) {
        add(strippedNumTitle, rawArtist);
      }
    }

    // 4. Try parsing from raw title if it contains dashes, brackets or quotes
    // e.g. "Artist - Title", "Artist – Title", "Artist — Title"
    final dashMatch = RegExp(r'^(.*?)\s*[\-\–\—]\s*(.*)$').firstMatch(rawTitle);
    if (dashMatch != null) {
      final candArt = cleanArtist(dashMatch.group(1)!);
      final rawCandArt = cleanForSearch(dashMatch.group(1)!);
      final candTit = cleanForSearch(dashMatch.group(2)!);
      add(candTit, candArt);
      if (candArt != rawCandArt) add(candTit, rawCandArt);
      add(cleanForSearch(stripAllBrackets(candTit)), candArt);
    }

    // Check for multi-dash titles: e.g. "深夜聆聽🪐Seafret - Atlantis - 中文歌詞 -"
    final dashParts = rawTitle.split(RegExp(r'\s*[\-\–\—]\s*')).where((p) => p.trim().isNotEmpty).toList();
    if (dashParts.length >= 3) {
      final p0 = cleanArtist(dashParts[0]);
      final p1 = cleanForSearch(dashParts[1]);
      add(p1, p0);
      final p0Words = dashParts[0]
          .split(RegExp(r'[\s\u{1F300}-\u{1FAD6}\u{2600}-\u{27BF}]+', unicode: true))
          .where((w) => w.trim().isNotEmpty)
          .toList();
      if (p0Words.isNotEmpty) {
        add(p1, cleanArtist(p0Words.last));
      }
    }

    // Check for brackets like Artist【Title】 or Artist [Title]
    final bracketMatch = RegExp(
      r'^([^【\[\(]+)[【\[\(](.*?)[】\]\)](.*)$',
    ).firstMatch(rawTitle);
    if (bracketMatch != null) {
      final candArt = cleanArtist(bracketMatch.group(1)!);
      final inside = bracketMatch.group(2)!.trim();
      add(cleanForSearch(inside), candArt);
      final firstToken = inside.split(' ').first;
      if (firstToken.isNotEmpty && firstToken != inside) {
        add(cleanForSearch(firstToken), candArt);
      }
    }

    // Check for quotes like Artist 'Title' or Artist "Title"
    final quoteMatch = RegExp("['\"‘“](.*?)['\"’”]").firstMatch(rawTitle);
    if (quoteMatch != null) {
      final insideQuote = cleanForSearch(quoteMatch.group(1)!);
      add(insideQuote, baseArtist);
      final cleanedAuthor = cleanArtist(rawAuthor);
      if (cleanedAuthor.isNotEmpty) add(insideQuote, cleanedAuthor);
    }

    // 5. Try title alone (for cases where author is a record label or playlist curator)
    if (baseTitle.isNotEmpty) add(baseTitle, '');
    if (noParenTitle.isNotEmpty) add(noParenTitle, '');
    if (strippedNumTitle.isNotEmpty) add(strippedNumTitle, '');

    return candidates;
  }

  /// Format a Duration into standard LRC timestamp: [mm:ss.xx]
  static String formatTimestamp(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final cs =
        (d.inMilliseconds.remainder(1000) ~/ 10).toString().padLeft(2, '0');
    return '[$m:$s.$cs]';
  }

  static final _captionNoise = RegExp(
    r'^(music|applause|laughter|singing|instrumental|音楽|音乐|音樂|음악|拍手|박수)$',
    caseSensitive: false,
  );

  /// Converts YouTube closed captions to synchronized LRC format, dropping
  /// "[Music]" / ♪ fillers and immediately repeated lines.
  static String captionsToLrc(Iterable<ClosedCaption> captions) {
    final sb = StringBuffer();
    String? prev;
    for (final c in captions) {
      final text = c.text.replaceAll('\n', ' ').trim();
      final bare = text.replaceAll(RegExp(r'[\[\]\(\)（）【】♪♫♬\s]'), '');
      if (bare.isEmpty || _captionNoise.hasMatch(bare)) continue;
      if (text == prev) continue;
      prev = text;
      sb.writeln('${formatTimestamp(c.offset)} $text');
    }
    return sb.toString().trim();
  }

  // ------------------------------------------------------------------ fetch

  static final Map<String, LyricsResult?> _cache = {};

  static void clearCache() => _cache.clear();

  static void setCached(String trackId, LyricsResult result) =>
      putBounded(_cache, trackId, result, max: 200);

  /// LRCLIB (synchronized) -> NetEase (synchronized) -> manual YouTube captions (verified against reference) ->
  /// YouTube Music plain -> LRCLIB plain -> NetEase plain.
  static Future<LyricsResult?> fetch(
    Track track, {
    YoutubeExplode? yt,
    Duration timeout = const Duration(seconds: 15),
    bool bypassCache = false,
    String? localPath,
  }) async {
    if (!bypassCache && _cache.containsKey(track.id)) {
      AppLog.info('lyrics ${track.id}: served from cache');
      return _cache[track.id];
    }

    // 0. Check local .lrc file if localPath is available
    if (localPath != null && localPath.isNotEmpty) {
      final lrcPath = localPath.replaceAll(RegExp(r'\.[^.]+$'), '.lrc');
      try {
        final lrcFile = File(lrcPath);
        if (lrcFile.existsSync() &&
            lrcFile.lengthSync() > 0 &&
            lrcFile.lengthSync() <= 1024 * 1024) {
          final content = lrcFile.readAsStringSync();
          if (content.trim().isNotEmpty) {
            final isSynced = content.contains(RegExp(r'\[\d{2}:\d{2}'));
            final res = LyricsResult(lyrics: content, isSynced: isSynced, source: 'local_lrc');
            putBounded(_cache, track.id, res, max: 200);
            AppLog.info('lyrics ${track.id}: loaded from local .lrc file');
            return res;
          }
        }
      } catch (e) {
        AppLog.info('lyrics ${track.id}: failed to read local .lrc: $e');
      }
    }

    // 1. Fetch authoritative reference lyrics from YouTube Music (skip if local-only track).
    // YouTube Music provides official label-verified lyrics (LyricFind / Musixmatch)
    // in the song's authentic language(s) and native script (e.g. Hangul for K-pop).
    LyricsResult? ytm;
    if (!track.id.startsWith('local_')) {
      try {
        ytm = await _fetchFromYouTubeMusic(track).timeout(const Duration(seconds: 4));
      } catch (e) {
        AppLog.info('lyrics ${track.id}: YouTube Music lookup failed: $e');
      }
    }

    String? refText = (ytm != null && ytm.lyrics.isNotEmpty) ? ytm.lyrics : null;

    // Detect non-Latin scripts present in the song (e.g. Hangul, Kana, Han, Cyrillic, Arabic).
    final targetScripts = <Script>{...hintScripts(track)};
    if (refText != null) {
      final shares = scriptShares(refText);
      for (final entry in shares.entries) {
        if (entry.key != Script.latin && entry.value >= 0.05) {
          targetScripts.add(entry.key);
        }
      }
    }

    // 2. Fetch synchronized lyrics from LRCLIB, matching against refText and targetScripts.
    LyricsResult? lrclib;
    try {
      lrclib = await _fetchFromLrclib(
        track,
        refLyrics: refText,
        targetScripts: targetScripts,
      ).timeout(timeout);
      if (lrclib != null && lrclib.isSynced) {
        AppLog.info('lyrics ${track.id}: synchronized via LRCLIB');
        putBounded(_cache, track.id, lrclib, max: 200);
        return lrclib;
      }
    } catch (e) {
      AppLog.info('lyrics ${track.id}: LRCLIB lookup failed: $e');
    }

    // 3. Fetch synchronized lyrics from NetEase.
    LyricsResult? netease;
    try {
      netease = await _fetchFromNetEase(
        track,
        refLyrics: refText,
        targetScripts: targetScripts,
      ).timeout(timeout);
      if (netease != null && netease.isSynced) {
        AppLog.info('lyrics ${track.id}: synchronized via NetEase');
        putBounded(_cache, track.id, netease, max: 200);
        return netease;
      }
    } catch (e) {
      AppLog.info('lyrics ${track.id}: NetEase lookup failed: $e');
    }

    // If refText was not found from YTM, check if LRCLIB or NetEase gave authentic plain lyrics.
    refText ??= (lrclib != null && lrclib.lyrics.isNotEmpty)
        ? lrclib.lyrics
        : (netease != null && netease.lyrics.isNotEmpty)
            ? netease.lyrics
            : null;

    if (refText != null && targetScripts.isEmpty) {
      final shares = scriptShares(refText);
      for (final entry in shares.entries) {
        if (entry.key != Script.latin && entry.value >= 0.05) {
          targetScripts.add(entry.key);
        }
      }
    }

    // 4. Fetch synchronized captions from YouTube, validating against reference lyrics.
    if (yt != null) {
      try {
        final r = await _fetchFromYouTube(
          track,
          yt,
          refLyrics: refText,
          targetScripts: targetScripts,
        ).timeout(timeout);
        if (r != null) {
          AppLog.info('lyrics ${track.id}: synchronized via manual YouTube captions');
          putBounded(_cache, track.id, r, max: 200);
          return r;
        }
      } catch (e) {
        AppLog.info('lyrics ${track.id}: YouTube captions lookup failed: $e');
      }
    }

    // 5. Authentic plain lyrics fallback: YouTube Music > LRCLIB > NetEase.
    LyricsResult? finalResult;
    if (ytm != null && ytm.lyrics.isNotEmpty) {
      AppLog.info('lyrics ${track.id}: found via YouTube Music');
      finalResult = ytm;
    } else if (lrclib != null && lrclib.lyrics.isNotEmpty) {
      AppLog.info('lyrics ${track.id}: plain lyrics from LRCLIB');
      finalResult = lrclib;
    } else if (netease != null && netease.lyrics.isNotEmpty) {
      AppLog.info('lyrics ${track.id}: plain lyrics from NetEase');
      finalResult = netease;
    }

    putBounded(_cache, track.id, finalResult, max: 200);
    return finalResult;
  }

  static Future<Object?> _getJson(
    HttpClient client,
    Uri uri, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    try {
      final req = await client.getUrl(uri).timeout(timeout);
      req.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      final res = await req.close().timeout(timeout);
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      // Cap the body so a hostile or broken server can't exhaust memory.
      if (res.contentLength > 2 * 1024 * 1024) {
        await res.drain<void>();
        return null;
      }
      var size = 0;
      final body = await res
          .map((chunk) {
            size += chunk.length;
            if (size > 2 * 1024 * 1024) {
              throw const FormatException('response too large');
            }
            return chunk;
          })
          .transform(utf8.decoder)
          .join();
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  /// Null = this LRCLIB entry is not this recording. Otherwise higher = better.
  static double? _scoreHit(
    Map<String, dynamic> h,
    String lyrics,
    List<LyricsCandidate> cands,
    Track track,
    int? dur,
    Set<Script> hints, {
    String? refLyrics,
    Set<Script> targetScripts = const {},
  }) {
    final hitTitle = (h['trackName'] ?? h['name'] ?? '').toString();
    final hitArtist = (h['artistName'] ?? '').toString();
    final hd = (h['duration'] as num?)?.toDouble();
    final durKnown = dur != null && hd != null;
    var diff = 0.0;
    if (durKnown) {
      diff = (hd - dur).abs();
      // Other-language versions / remixes / live cuts differ by more than this.
      if (diff > 3.5) return null;
    }
    var titleSim = 0.0, artistSim = 0.0;
    for (final c in cands) {
      titleSim = max(titleSim, _sim(hitTitle, c.title));
      if (c.artist.isNotEmpty) artistSim = max(artistSim, _sim(hitArtist, c.artist));
    }
    artistSim = max(artistSim, _sim(hitArtist, track.author));

    final plainText = lyrics.replaceAll(_lrcStamp, '').trim();

    // If official reference lyrics are available, require text similarity!
    double? refSim;
    if (refLyrics != null && refLyrics.isNotEmpty) {
      refSim = _sim(plainText, refLyrics);
      // If refLyrics exist and similarity is low (< 0.40), this is NOT the same song!
      if (refSim < 0.40) return null;
    }

    final ok = durKnown
        ? (titleSim >= 0.4 || (artistSim >= 0.6 && diff <= 1.5))
        : titleSim >= 0.6;
    if (!ok) return null;

    final effectiveTargetScripts = <Script>{
      ...targetScripts,
      ...hints,
    };

    var score = 2 * titleSim + artistSim - 0.3 * diff;

    if (refSim != null) {
      score += 4.0 * refSim;
    }

    final hitShares = scriptShares(plainText);

    if (effectiveTargetScripts.isNotEmpty) {
      final hasTargetScript = effectiveTargetScripts.any(
        (s) => (hitShares[s] ?? 0) >= 0.02,
      );
      if (hasTargetScript) {
        score += 2.5; // Authentic native script present
      } else {
        score -= 4.0; // Heavily penalize Romanization/translation lacking native script
      }
    } else {
      if (_agrees(lyrics, hints)) score += 1.0;
    }

    return score;
  }

  static LyricsResult? _best(
    List<Map<String, dynamic>> hits,
    List<LyricsCandidate> cands,
    Track track,
    int? dur,
    Set<Script> hints, {
    required bool synced,
    String? refLyrics,
    Set<Script> targetScripts = const {},
  }) {
    final key = synced ? 'syncedLyrics' : 'plainLyrics';
    String? bestText;
    var bestScore = -1e9;
    for (final h in hits) {
      if (h['instrumental'] == true) continue;
      final text = (h[key] as String?)?.trim() ?? '';
      if (text.isEmpty) continue;
      final s = _scoreHit(
        h,
        text,
        cands,
        track,
        dur,
        hints,
        refLyrics: refLyrics,
        targetScripts: targetScripts,
      );
      if (s != null && s > bestScore) {
        bestScore = s;
        bestText = text;
      }
    }
    return bestText == null
        ? null
        : LyricsResult(lyrics: bestText, isSynced: synced, source: 'lrclib');
  }

  static Future<LyricsResult?> _fetchFromLrclib(
    Track track, {
    String? refLyrics,
    Set<Script> targetScripts = const {},
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    final cands = generateCandidates(track);
    final dur = track.duration?.inSeconds;
    final hints = hintScripts(track);
    final hits = <Map<String, dynamic>>[];
    final seen = <Object?>{};

    void collect(Object? j) {
      final list = j is List ? j : [j];
      for (final e in list) {
        if (e is Map<String, dynamic> && seen.add(e['id'] ?? e.hashCode)) {
          hits.add(e);
        }
      }
    }

    try {
      // Query both exact lookup and search concurrently so all candidates (including
      // native-script versions that may only appear in search) are collected.
      await Future.wait([
        for (final c in cands.where((c) => c.artist.isNotEmpty).take(3))
          _getJson(
            client,
            Uri.https('lrclib.net', '/api/get', {
              'track_name': c.title,
              'artist_name': c.artist,
              if (dur != null) 'duration': '$dur',
            }),
          ).then(collect),
        for (final c in cands.take(5))
          _getJson(
            client,
            Uri.https('lrclib.net', '/api/search', {
              'q': c.artist.isNotEmpty ? '${c.title} ${c.artist}' : c.title,
            }),
          ).then(collect),
      ]);
    } finally {
      client.close(force: true);
    }

    return _best(
          hits,
          cands,
          track,
          dur,
          hints,
          synced: true,
          refLyrics: refLyrics,
          targetScripts: targetScripts,
        ) ??
        _best(
          hits,
          cands,
          track,
          dur,
          hints,
          synced: false,
          refLyrics: refLyrics,
          targetScripts: targetScripts,
        );
  }

  static Future<LyricsResult?> _fetchFromNetEase(
    Track track, {
    String? refLyrics,
    Set<Script> targetScripts = const {},
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    final cands = generateCandidates(track);
    final dur = track.duration?.inSeconds;

    try {
      for (final c in cands.take(3)) {
        final query = c.artist.isNotEmpty ? '${c.artist} ${c.title}' : c.title;
        final searchUri = Uri.parse(
          'https://music.163.com/api/search/get/web?csrf_token=&hlpretag=&hlposttag=&s=${Uri.encodeComponent(query)}&type=1&offset=0&total=true&limit=5',
        );
        final searchReq = await client.getUrl(searchUri).timeout(const Duration(seconds: 4));
        searchReq.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36');
        searchReq.headers.set('Referer', 'https://music.163.com');
        searchReq.headers.set('Cookie', 'os=pc');

        final searchRes = await searchReq.close().timeout(const Duration(seconds: 4));
        if (searchRes.statusCode != 200) {
          await searchRes.drain<void>();
          continue;
        }

        final searchBody = jsonDecode(await searchRes.transform(utf8.decoder).join()) as Map<String, dynamic>?;
        final songs = searchBody?['result']?['songs'] as List<dynamic>?;
        if (songs == null || songs.isEmpty) continue;

        for (final s in songs) {
          if (s is! Map<String, dynamic>) continue;
          final songId = s['id'];
          final songName = s['name']?.toString() ?? '';
          final songArtists = (s['artists'] as List<dynamic>?)
                  ?.map((a) => a['name']?.toString() ?? '')
                  .join(', ') ??
              '';
          final songDurMs = s['duration'] as num?;

          // Check duration match within 4 seconds if duration is known
          if (dur != null && songDurMs != null) {
            final diff = (songDurMs / 1000 - dur).abs();
            if (diff > 4) continue;
          }

          // Check title / artist similarity
          final tSim = _sim(songName, c.title);
          final aSim = c.artist.isNotEmpty ? _sim(songArtists, c.artist) : 0.5;
          if (tSim < 0.35 && aSim < 0.35) continue;

          // Fetch lyric
          final lyricUri = Uri.parse('https://music.163.com/api/song/lyric?os=pc&id=$songId&lv=-1&kv=-1&tv=-1');
          final lyricReq = await client.getUrl(lyricUri).timeout(const Duration(seconds: 4));
          lyricReq.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36');
          lyricReq.headers.set('Referer', 'https://music.163.com');

          final lyricRes = await lyricReq.close().timeout(const Duration(seconds: 4));
          if (lyricRes.statusCode != 200) {
            await lyricRes.drain<void>();
            continue;
          }

          final lyricBody = jsonDecode(await lyricRes.transform(utf8.decoder).join()) as Map<String, dynamic>?;
          final lrcText = lyricBody?['lrc']?['lyric']?.toString().trim();
          if (lrcText != null && lrcText.isNotEmpty) {
            // Check target scripts if known
            if (targetScripts.isNotEmpty) {
              final shares = scriptShares(lrcText);
              final hasTarget = targetScripts.any((ts) => (shares[ts] ?? 0) >= 0.02);
              if (!hasTarget) continue;
            }
            final isSynced = lrcText.contains(RegExp(r'\[\d{2}:\d{2}'));
            return LyricsResult(lyrics: lrcText, isSynced: isSynced, source: 'netease');
          }
        }
      }
    } catch (e) {
      AppLog.info('lyrics ${track.id}: NetEase lookup error: $e');
    } finally {
      client.close(force: true);
    }
    return null;
  }

  /// Selects the synchronized caption track that matches the authentic song lyrics,
  /// strictly rejecting foreign-language community translations (e.g. English/Spanish/Arabic
  /// subtitles on a Korean/Japanese music video, or Arabic/Chinese subtitles on Queen).
  static Future<LyricsResult?> _fetchFromYouTube(
    Track track,
    YoutubeExplode yt, {
    String? refLyrics,
    Set<Script> targetScripts = const {},
  }) async {
    final manifest = await yt.videos.closedCaptions.getManifest(track.id);
    final manual = manifest.tracks.where((t) => !t.isAutoGenerated).toList();
    if (manual.isEmpty) return null;

    // Deduplicate by primary language code to avoid fetching redundant formats (srv1, srv2...)
    final byLang = <String, ClosedCaptionTrackInfo>{};
    for (final t in manual) {
      final code = t.language.code.toLowerCase().split(RegExp(r'[-_]')).first;
      byLang.putIfAbsent(code, () => t);
    }

    // Determine target non-Latin scripts from reference lyrics, targetScripts, or track hints
    Set<Script> targetNonLatin = {...targetScripts};
    if (refLyrics != null && refLyrics.isNotEmpty) {
      final shares = scriptShares(refLyrics);
      for (final entry in shares.entries) {
        if (entry.key != Script.latin && entry.value >= 0.05) {
          targetNonLatin.add(entry.key);
        }
      }
    }
    if (targetNonLatin.isEmpty) {
      targetNonLatin = hintScripts(track);
    }

    // If we have refLyrics, score candidate caption tracks against it
    if (refLyrics != null && refLyrics.isNotEmpty) {
      ClosedCaptionTrackInfo? bestTrack;
      String? bestLrc;
      double highestSim = 0.0;

      for (final t in byLang.values) {
        try {
          final cc = await yt.videos.closedCaptions.get(t);
          final lrc = captionsToLrc(cc.captions);
          final plainCaption = lrc.replaceAll(_lrcStamp, '').trim();
          if (plainCaption.split('\n').length < 4) continue;

          final captionShares = scriptShares(plainCaption);

          if (targetNonLatin.isNotEmpty) {
            // Target song contains non-Latin scripts (e.g. Hangul for K-pop).
            // Reject any translation caption track that lacks this script!
            final hasTargetScript =
                targetNonLatin.any((s) => (captionShares[s] ?? 0) >= 0.05);
            if (!hasTargetScript) continue;
          } else {
            // Target song is purely Latin (English/Spanish/etc.).
            // Reject any caption track that contains substantial non-Latin scripts!
            final hasAlienScript = captionShares.keys.any(
              (s) => s != Script.latin && (captionShares[s] ?? 0) >= 0.1,
            );
            if (hasAlienScript) continue;
          }

          final sim = _sim(plainCaption, refLyrics);
          if (sim > highestSim) {
            highestSim = sim;
            bestTrack = t;
            bestLrc = lrc;
          }
        } catch (_) {}
      }

      if (bestLrc != null && highestSim >= 0.5) {
        AppLog.info('lyrics ${track.id}: matched caption track "${bestTrack?.language.name}" (${bestTrack?.language.code}) with sim ${highestSim.toStringAsFixed(2)}');
        return LyricsResult(
          lyrics: bestLrc,
          isSynced: true,
          source: 'youtube_captions',
        );
      }
    }

    // Fallback when refLyrics is not available or didn't match:
    final wantedCodes = <String>{
      if (targetNonLatin.contains(Script.hangul)) 'ko',
      if (targetNonLatin.contains(Script.kana)) 'ja',
      if (targetNonLatin.contains(Script.han) &&
          !targetNonLatin.contains(Script.kana))
        'zh',
      if (targetNonLatin.contains(Script.arabic)) 'ar',
      if (targetNonLatin.contains(Script.cyrillic)) 'ru',
    };

    final candidates = wantedCodes.isNotEmpty
        ? byLang.values.where(
            (t) => wantedCodes.contains(
              t.language.code.toLowerCase().split(RegExp(r'[-_]')).first,
            ),
          )
        : byLang.values.where((t) => t.language.code.toLowerCase().startsWith('en'));

    for (final t in candidates) {
      try {
        final cc = await yt.videos.closedCaptions.get(t);
        final lrc = captionsToLrc(cc.captions);
        if (lrc.split('\n').length < 4) continue;
        if (targetNonLatin.isNotEmpty && !_agrees(lrc, targetNonLatin)) continue;
        return LyricsResult(
          lyrics: lrc,
          isSynced: true,
          source: 'youtube_captions',
        );
      } catch (_) {}
    }
    return null;
  }

  static Future<LyricsResult?> _fetchFromYouTubeMusic(Track track) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    // Always English UI: the lyrics tab is titled by locale ("가사", "歌詞"...),
    // so a localized request never found it. The lyrics text itself is in the
    // song's own language(s) regardless.
    Map<String, dynamic> ctx() => {
          'client': {
            'clientName': 'WEB_REMIX',
            'clientVersion': '1.20240401.01.00',
            'hl': 'en',
            'gl': 'US',
          },
        };
    Future<Map<String, dynamic>?> post(String path, Map<String, dynamic> body) async {
      final req = await client
          .postUrl(Uri.parse('https://music.youtube.com/youtubei/v1/$path'))
          .timeout(const Duration(seconds: 4));
      req.headers.set('Content-Type', 'application/json');
      req.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      req.add(utf8.encode(jsonEncode({'context': ctx(), ...body})));
      final res = await req.close().timeout(const Duration(seconds: 4));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      return jsonDecode(await res.transform(utf8.decoder).join())
          as Map<String, dynamic>;
    }

    try {
      final next = await post('next', {'videoId': track.id, 'isAudioOnly': true});
      final tabs = next?['contents']?['singleColumnMusicWatchNextResultsRenderer']
              ?['tabbedRenderer']?['watchNextTabbedResultsRenderer']?['tabs']
          as List<dynamic>?;
      if (tabs == null) return null;

      String? browseId;
      for (final t in tabs) {
        final tab = t['tabRenderer'] as Map<String, dynamic>?;
        final id = tab?['endpoint']?['browseEndpoint']?['browseId'] as String?;
        if (id != null &&
            (id.startsWith('MPLYt') ||
                (tab?['title'] as String?)?.toLowerCase() == 'lyrics')) {
          browseId = id;
          break;
        }
      }
      if (browseId == null || browseId.isEmpty) return null;

      final browse = await post('browse', {'browseId': browseId});
      final contents =
          browse?['contents']?['sectionListRenderer']?['contents'] as List<dynamic>?;
      final runs = contents?.firstOrNull?['musicDescriptionShelfRenderer']
          ?['description']?['runs'] as List<dynamic>?;
      final text = runs?.map((r) => r['text'] as String? ?? '').join().trim();
      if (text != null && text.isNotEmpty) {
        return LyricsResult(lyrics: text, isSynced: false, source: 'youtube_music');
      }
    } catch (e) {
      AppLog.info('lyrics ${track.id}: YouTube Music error: $e');
    } finally {
      client.close(force: true);
    }
    return null;
  }
}
