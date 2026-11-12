// Pure Dart (no Flutter / network imports) so it can be unit-tested.
import 'dart:convert';

enum Status { queued, downloading, done, error }

class Track {
  final String id, title, author, thumb;
  final Duration? duration;
  final String? uploadDate;
  final String? album;
  final String? albumBrowseId;
  final String? artistBrowseId;
  Status status = Status.queued;
  double progress = 0;
  String msg = '';
  bool cancelled = false; // set by the UI to abort an in-flight download

  Track(
    String id,
    this.title,
    this.author,
    String thumb,
    this.duration, {
    this.uploadDate,
    this.album,
    this.albumBrowseId,
    this.artistBrowseId,
  }) : id = sanitizeId(id),
       thumb = sanitizeThumb(thumb);

  static String sanitizeId(String raw) =>
      raw.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');

  /// Remote images may only come from YouTube / Google image CDNs and are
  /// always fetched over https. Anything else (an attacker-chosen host in a
  /// shared playlist or tampered saved data would otherwise make the app
  /// contact it and reveal the user's IP) becomes '' = placeholder.
  /// Local file paths / content:// URIs are returned unchanged.
  static String sanitizeThumb(String raw) {
    final s = raw.trim();
    final lower = s.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) return s;
    final uri = Uri.tryParse(s);
    if (uri == null || !uri.hasAuthority || uri.userInfo.isNotEmpty) return '';
    final h = uri.host.toLowerCase();
    final trusted =
        h == 'ytimg.com' ||
        h.endsWith('.ytimg.com') ||
        h == 'img.youtube.com' ||
        h.endsWith('.googleusercontent.com') ||
        h.endsWith('.ggpht.com');
    if (!trusted) return '';
    return uri.scheme == 'https' ? s : uri.replace(scheme: 'https').toString();
  }

  factory Track.fromJson(Map<String, dynamic> j) {
    final t = Track(
      j['id'],
      j['title'],
      j['author'],
      j['thumb'],
      j['dur'] == null ? null : Duration(seconds: j['dur']),
      uploadDate: j['uploadDate'] as String?,
      album: j['album'] as String?,
      albumBrowseId: j['albumBrowseId'] as String?,
      artistBrowseId: j['artistBrowseId'] as String?,
    );
    final s = Status.values[j['status'] ?? 0];
    t.status = s == Status.downloading ? Status.queued : s;
    if (t.status == Status.error) t.msg = j['msg'] ?? '';
    return t;
  }

  Track copyWith({
    String? id,
    String? title,
    String? author,
    String? thumb,
    Duration? duration,
    String? uploadDate,
    String? album,
    String? albumBrowseId,
    String? artistBrowseId,
    Status? status,
    String? msg,
  }) {
    final t = Track(
      id ?? this.id,
      title ?? this.title,
      author ?? this.author,
      thumb ?? this.thumb,
      duration ?? this.duration,
      uploadDate: uploadDate ?? this.uploadDate,
      album: album ?? this.album,
      albumBrowseId: albumBrowseId ?? this.albumBrowseId,
      artistBrowseId: artistBrowseId ?? this.artistBrowseId,
    );
    t.status = status ?? this.status;
    t.progress = progress;
    t.msg = msg ?? this.msg;
    t.cancelled = cancelled;
    return t;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'thumb': thumb,
    'dur': duration?.inSeconds,
    'uploadDate': uploadDate,
    'album': album,
    'albumBrowseId': albumBrowseId,
    'artistBrowseId': artistBrowseId,
    'status': status.index,
    'msg': msg,
  };

  String get sourceUrl => 'https://www.youtube.com/watch?v=$id';

  String? get uploadYear {
    if (uploadDate == null || uploadDate!.isEmpty) return null;
    final m = RegExp(r'\b(20\d\d|19\d\d)\b').firstMatch(uploadDate!);
    return m?.group(1);
  }

  String get durText {
    final d = duration;
    if (d == null) return '';
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    return h > 0
        ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
        : '$m:${s.toString().padLeft(2, '0')}';
  }

  // "(Official Video)", "[Lyrics]", "(HD)" ... add nothing to a file name or tag.
  static final _bracketed = RegExp(r'[\(\[]([^\)\]]*)[\)\]]');
  static final _noise = RegExp(
    r'\b(?:official\s+)?(?:music\s+)?(?:video|audio|lyrics?|mv|hd|4k|visuali[sz]er)\b',
    caseSensitive: false,
  );
  String get _title {
    final c = title.replaceAllMapped(_bracketed, (match) {
      final content = match.group(1)!;
      if (!_noise.hasMatch(content)) return match.group(0)!;
      final remaining = content
          .replaceAll(_noise, '')
          .replaceAll(RegExp(r'^[\s\-–—|:]+|[\s\-–—|:]+$'), '')
          .trim();
      if (remaining.isEmpty) return '';
      final bracket = match.group(0)!;
      return '${bracket[0]}$remaining${bracket[bracket.length - 1]}';
    }).trim();
    return c.isEmpty ? title : c;
  }

  String get _author => author.replaceAll(RegExp(r'\s*-\s*Topic$'), '');
  // Split only when the leading title segment actually identifies the artist.
  // A dash can instead be part of the song title, such as "Lucky - Live".
  bool get _split {
    if (author.endsWith('- Topic') || !_title.contains(' - ')) return false;
    final prefix = _title.split(' - ').first.trim().toLowerCase();
    final artist = _author
        .replaceAll(RegExp(r'\s*vevo$', caseSensitive: false), '')
        .trim()
        .toLowerCase();
    return prefix.isNotEmpty && artist.isNotEmpty && prefix == artist;
  }

  String get tagArtist => _split ? _title.split(' - ').first.trim() : _author;
  String get tagTitle =>
      _split ? _title.split(' - ').skip(1).join(' - ').trim() : _title;

  /// Effective album tag for audio metadata.
  /// If an explicit album is known (e.g. from YouTube Music), use it.
  /// Otherwise, default to [tagTitle] (standard for standalone singles / releases).
  String get tagAlbum {
    final a = album?.trim();
    if (a != null && a.isNotEmpty) return a;
    return tagTitle;
  }

  /// Safe file name: no illegal characters (also # and %, which would corrupt the
  /// name media_store_plus derives with Uri.parse), no leading dot (Android hides
  /// dot-files from the music library) and at most 180 UTF-8 bytes (file
  /// names are limited to 255 bytes; CJK characters take 3 bytes each).
  String get fileName {
    var base = '$tagArtist - $tagTitle'
        .replaceAll(RegExp(r'[\\/:*?"<>|#%\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'\.{2,}'), '_')
        .replaceFirst(RegExp(r'^[.\s]+'), '');
    base = _clipBytes(base, 180).replaceFirst(RegExp(r'[.\s]+$'), '');
    return base.isEmpty ? 'track' : base;
  }

  static String _clipBytes(String s, int max) {
    if (utf8.encode(s).length <= max) return s;
    final out = StringBuffer();
    var n = 0;
    for (final r in s.runes) {
      final c = String.fromCharCode(r);
      final b = utf8.encode(c).length;
      if (n + b > max) break;
      out.write(c);
      n += b;
    }
    return out.toString();
  }
}
