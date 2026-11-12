// Pure Dart helpers (no Flutter / plugins) so they can be unit-tested.
import 'dart:io';

const musicRoot = '/storage/emulated/0/Music';

/// Path of [dir] below Music/ ('' for Music itself), or null if it is outside
/// Music/. Folders inside Music/ are written through MediaStore.
String? musicRelative(String dir) {
  final parts = dir
      .trim()
      .replaceAll('\\', '/')
      .split('/')
      .where((p) => p.isNotEmpty && p != '.' && p != '..')
      .toList();
  final root = musicRoot.split('/').where((p) => p.isNotEmpty).toList();
  if (parts.length < root.length) return null;
  for (var i = 0; i < root.length; i++) {
    if (parts[i] != root[i]) return null;
  }
  return parts.skip(root.length).join('/'); // '' for Music itself
}

/// First of "name", "name (2)", "name (3)"... for which [taken] is false,
/// so an existing file is never overwritten.
Future<String> uniqueName(
  String base,
  Future<bool> Function(String name) taken,
) async {
  var name = base;
  for (var i = 2; await taken(name); i++) {
    if (i > 999) throw Exception('Too many files named "$base"');
    name = '$base ($i)';
  }
  return name;
}

const _audioExts = {'m4a', 'mp3', 'opus', 'ogg', 'flac', 'wav', 'aac', 'webm'};

/// True only for an absolute, traversal-free path to an audio file under
/// shared storage. Gate for anything destructive (delete / rewrite) so a
/// corrupted or tampered saved path can never point it at another file.
bool isSafeAudioPath(String path) {
  if (!path.startsWith('/storage/') && !path.startsWith('/sdcard/')) {
    return false;
  }
  if (path.contains('\x00') || path.contains('\\')) return false;
  if (path.split('/').contains('..')) return false;
  final name = path.split('/').last;
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return false;
  return _audioExts.contains(name.substring(dot + 1).toLowerCase());
}

/// A save folder must be an absolute, traversal-free path on shared storage.
bool isAllowedSaveDir(String dir) {
  final d = dir.trim();
  if (d.contains('\x00') || d.contains('\\')) return false;
  if (d.split('/').contains('..')) return false;
  return d == '/sdcard' ||
      d.startsWith('/sdcard/') ||
      d.startsWith('/storage/');
}

/// Checks whether a host string belongs to an authentic YouTube domain.
bool isYouTubeHost(String host) {
  final h = host.toLowerCase();
  return h == 'youtu.be' || h == 'youtube.com' || h.endsWith('.youtube.com');
}

/// First http(s) link inside shared [text] (YouTube shares "Title\nhttps://youtu.be/…"),
/// validating that any URL points to a legitimate YouTube domain (youtube.com, youtu.be).
/// Untrusted non-YouTube URLs are rejected; clean search text is preserved.
String? extractUrl(String? text) {
  final t = text?.trim();
  if (t == null || t.isEmpty) return null;

  if (t.startsWith('wax://playlist')) {
    if (t.length > 65536) return null;
    return t.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), '');
  }

  final match = RegExp(r'https?://[^\s]+').firstMatch(t);
  if (match != null) {
    final candidate = match.group(0)!;
    final uri = Uri.tryParse(candidate);
    if (uri != null && uri.hasAuthority && isYouTubeHost(uri.host)) {
      return candidate;
    }
    // Reject untrusted URL; extract remaining non-URL search text if available
    final remainder = t
        .replaceAll(candidate, '')
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
        .trim();
    return remainder.isNotEmpty ? remainder : null;
  }

  // Plain search text: strip non-printable control characters
  final sanitized = t.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
  return sanitized.isNotEmpty ? sanitized : null;
}

/// Comparison key for "is this song already in the library?": a file name
/// without its audio extension or a trailing " (2)" copy marker, lower-cased.
String libraryKey(String name) => name
    .replaceFirst(
      RegExp(r'\.(m4a|mp3|opus|ogg|flac|wav|aac|webm)$', caseSensitive: false),
      '',
    )
    .replaceFirst(RegExp(r'\s*\(\d{1,3}\)$'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    .toLowerCase();

/// Normalized comparison key for matching video titles and file names.
String normalizeLibraryKey(String name) {
  var s = libraryKey(name);
  // Preserve version labels such as (Edit) and (Live): these can be distinct
  // recordings. Only discard common presentation-only labels.
  s = s.replaceAll(
    RegExp(
      r'[\(\[]\s*(?:official\s+)?(?:music\s+)?(?:audio|video|lyrics?|mv|hd|4k|visuali[sz]er)\s*[\)\]]',
      caseSensitive: false,
    ),
    ' ',
  );
  // Strip apostrophes and quotes directly so "don't" becomes "dont"
  s = s.replaceAll(RegExp(r"['’`´\x22]"), '');
  // Preserve letters, combining marks and numbers from all writing systems.
  s = s.replaceAll(RegExp(r'[^\p{L}\p{M}\p{N}_\s]', unicode: true), ' ');
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Attempts to extract the YouTube video ID or thumbnail URL embedded in an audio file's metadata.
/// Scans the first 128 KB and last 128 KB of the file (where MP4 and ID3 metadata atoms live).
String? extractEmbeddedThumbnailOrVideoId(File file) {
  try {
    if (!file.existsSync() || file.lengthSync() < 64) return null;
    final len = file.lengthSync();
    final readLen = len > 131072 ? 131072 : len;

    final raf = file.openSync();
    try {
      final headBytes = raf.readSync(readLen);
      final headStr = String.fromCharCodes(headBytes);

      // 1. Look for direct thumbnail URL: https://i.ytimg.com/vi/... or googleusercontent
      final thumbMatch = RegExp(
        r'https?://(?:i\.ytimg\.com/vi/[a-zA-Z0-9_-]+/(?:maxresdefault|sddefault|hqdefault|mqdefault|default)\.jpg|[a-zA-Z0-9.-]+\.googleusercontent\.com/[^\s\x00-\x1f\x22\x27<>]+)',
      ).firstMatch(headStr);
      if (thumbMatch != null) {
        return thumbMatch.group(0);
      }

      // 2. Look for YouTube watch URL or youtu.be URL
      final ytMatch = RegExp(
        r'(?:youtube\.com/watch\?v=|youtu\.be/)([a-zA-Z0-9_-]{11})',
      ).firstMatch(headStr);
      if (ytMatch != null) {
        final vid = ytMatch.group(1);
        return 'https://i.ytimg.com/vi/$vid/hqdefault.jpg';
      }

      // If file is large, metadata might be in the tail (e.g. ID3v1 or trailing atom)
      if (len > 262144) {
        raf.setPositionSync(len - 65536);
        final tailBytes = raf.readSync(65536);
        final tailStr = String.fromCharCodes(tailBytes);
        final tailThumb = RegExp(
          r'https?://(?:i\.ytimg\.com/vi/[a-zA-Z0-9_-]+/(?:maxresdefault|sddefault|hqdefault|mqdefault|default)\.jpg|[a-zA-Z0-9.-]+\.googleusercontent\.com/[^\s\x00-\x1f\x22\x27<>]+)',
        ).firstMatch(tailStr);
        if (tailThumb != null) return tailThumb.group(0);
        final tailYt = RegExp(
          r'(?:youtube\.com/watch\?v=|youtu\.be/)([a-zA-Z0-9_-]{11})',
        ).firstMatch(tailStr);
        if (tailYt != null) {
          final vid = tailYt.group(1);
          return 'https://i.ytimg.com/vi/$vid/hqdefault.jpg';
        }
      }
    } finally {
      raf.closeSync();
    }
  } catch (_) {}
  return null;
}
