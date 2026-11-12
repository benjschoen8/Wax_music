import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'browser_auth.dart';
import 'constants.dart';
import 'downloader.dart';
import 'files.dart';
import 'lyrics.dart';
import 'models/track.dart';
import 'models/user_playlist.dart';
import 'log.dart';
import 'media_store.dart';
import 'preview.dart';
import 'service.dart';
import 'strings.dart';

class AppState extends ChangeNotifier {
  late final yt = YoutubeExplode(httpClient: AuthenticatedYoutubeHttpClient());
  late final _dl = Downloader(yt);
  late final preview = Preview(yt, getLocalPath: getLocalTrackPath);

  String? getLocalTrackPath(String id) {
    final direct = downloaded[id];
    if (direct != null && File(direct).existsSync()) return direct;
    final inQ = queue.where((t) => t.id == id).firstOrNull;
    if (inQ != null) {
      for (final ext in const ['.m4a', '.mp3', '.flac', '.opus', '.ogg', '.wav', '']) {
        final p = '$dir/${inQ.fileName}$ext';
        if (File(p).existsSync()) return p;
      }
    }
    final inLib = libraryTracks.where((t) => t.id == id).firstOrNull;
    if (inLib != null) {
      for (final ext in const ['.m4a', '.mp3', '.flac', '.opus', '.ogg', '.wav', '']) {
        final p = '$dir/${inLib.fileName}$ext';
        if (File(p).existsSync()) return p;
      }
    }
    return null;
  }

  /// Resolves the cover art image for [t], returning a valid image path or URL.
  /// Never returns an audio path (.m4a/.mp3) so image widgets decode safely.
  String? getCoverArt(Track t) {
    // 1. If t.thumb is already a valid image URL or image file path
    final rawThumb = t.thumb.trim();
    if (rawThumb.isNotEmpty &&
        !rawThumb.endsWith('.m4a') &&
        !rawThumb.endsWith('.mp3') &&
        !rawThumb.endsWith('.opus') &&
        !rawThumb.endsWith('.flac') &&
        !rawThumb.endsWith('.ogg') &&
        !rawThumb.endsWith('.wav')) {
      if (rawThumb.startsWith('http://') || rawThumb.startsWith('https://')) {
        return rawThumb;
      }
      final clean = rawThumb.startsWith('file://') ? rawThumb.replaceFirst('file://', '') : rawThumb;
      try {
        final f = File(clean);
        if (f.existsSync() && f.lengthSync() > 0) {
          return clean;
        }
      } catch (_) {}
    }

    // 2. Check for companion image file next to the local audio file
    final audioPath = getLocalTrackPath(t.id);
    if (audioPath != null && audioPath.isNotEmpty) {
      final dot = audioPath.lastIndexOf('.');
      final base = dot > 0 ? audioPath.substring(0, dot) : audioPath;
      for (final ext in const ['.jpg', '.png', '.jpeg', '.webp']) {
        final img = File('$base$ext');
        if (img.existsSync() && img.lengthSync() > 0) {
          return img.path;
        }
      }
      // Check parent folder for cover.jpg / folder.jpg
      try {
        final parent = File(audioPath).parent;
        if (parent.existsSync()) {
          for (final cName in const ['cover.jpg', 'cover.png', 'folder.jpg', 'folder.png']) {
            final img = File('${parent.path}/$cName');
            if (img.existsSync() && img.lengthSync() > 0) {
              return img.path;
            }
          }
        }
      } catch (_) {}

      // 3. Extract embedded thumbnail URL or YouTube ID from audio metadata atoms
      try {
        final fromMeta = extractEmbeddedThumbnailOrVideoId(File(audioPath));
        if (fromMeta != null && fromMeta.isNotEmpty) {
          return fromMeta;
        }
      } catch (_) {}
    }

    // 4. Remote URL fallback from t.thumb
    if (rawThumb.startsWith('http://') || rawThumb.startsWith('https://')) {
      return rawThumb;
    }

    return null;
  }

  final queue = <Track>[];
  final libraryTracks = <Track>[];
  final userPlaylists = <UserPlaylist>[];
  String dir = defaultDir;
  bool running = false;
  bool _stop = false;
  String? dirProblem; // set when the save folder can't be written to
  final _exists = <String, bool>{}; // cache for isDownloaded()
  int durFilter = 0, limit = 20; // search filters, remembered between launches
  bool topicOnly = true;
  bool plMode = false; // search finds playlists instead of single songs
  bool albumMode = false; // search finds official YouTube Music albums
  bool artistMode = false; // search finds artists
  bool verifiedOnly = true; // only show results from verified sources

  void selectSongSearch() {
    plMode = false;
    albumMode = false;
    artistMode = false;
    saveFilters();
  }

  Set<String> _library = {}; // keys of songs already in the save folder
  Set<String> _libraryNormalized = {}; // normalized keys for smart duplicate detection
  Set<String> _unattributedTitles = {};
  Set<String> _unattributedTitlesNormalized = {};
  Completer<int>? _activeScanCompleter;
  bool get scanningLocalStorage => _activeScanCompleter != null;
  final recents = <String>[]; // recent searches, newest first
  bool tagging = true; // embed title/artist/cover via FFmpeg (stream copy)
  bool lyrics = true; // download synchronized (.lrc) lyrics
  bool wifiOnly = false; // wait for Wi-Fi/Ethernet before downloading
  int concurrency = 1; // downloads running at the same time (1-3)
  bool waitingForWifi = false;
  final sharedUrl = ValueNotifier<String?>(
    null,
  ); // link shared from another app
  int runSaved = 0, runFailed = 0; // counted for the "Done" summary
  final runFinished = ValueNotifier<({int saved, int failed})?>(null); // set when a run completes
  bool downloadAlerts = true; // show in-app completion alert
  Track? _lastRemoved;
  int _lastRemovedIndex = 0;
  // video id -> saved file path; survives clearing the queue.
  final downloaded = <String, String>{};
  SharedPreferences? prefs;
  final membership = ValueNotifier<int>(
    0,
  ); // bumps when queue membership changes

  Future<void> init() async {
    final p = prefs = await SharedPreferences.getInstance();
    await BrowserAuth.init(p);
    if (BrowserAuth.isSupported && BrowserAuth.cookies.isEmpty) {
      unawaited(BrowserAuth.refreshCookies());
    }
    final savedDir = p.getString('dir');
    if (savedDir == null ||
        !isAllowedSaveDir(savedDir) ||
        savedDir == '$musicDir/Crate' ||
        savedDir == '$musicDir/Wax') {
      dir = musicDir;
      await p.setString('dir', musicDir);
    } else {
      dir = savedDir;
    }
    tagging = p.getBool('tagging') ?? true;
    lyrics = p.getBool('lyrics') ?? true;
    downloadAlerts = p.getBool('download_alerts') ?? true;
    wifiOnly = p.getBool('wifiOnly') ?? false;
    concurrency = p.getInt('concurrency') ?? 1;
    durFilter = p.getInt('dur') ?? 0;
    limit = p.getInt('limit') ?? 20;
    topicOnly = p.getBool('topic') ?? true;
    plMode = p.getBool('plmode') ?? false;
    albumMode = p.getBool('albummode') ?? false;
    artistMode = p.getBool('artistmode') ?? false;
    verifiedOnly = p.getBool('verified') ?? true;
    recents.addAll(p.getStringList('recents') ?? const []);
    try {
      final h = p.getString('history_v2');
      if (h != null) {
        downloaded.addAll((jsonDecode(h) as Map).cast<String, String>());
      }
    } catch (e, st) {
      AppLog.error('load history', e, st);
    }
    try {
      final raw = p.getString('queue');
      if (raw != null) {
        queue.addAll(
          (jsonDecode(raw) as List).map(
            (j) => Track.fromJson(j as Map<String, dynamic>),
          ),
        );
      }
    } catch (e, st) {
      AppLog.error('load queue', e, st);
    }
    try {
      final rawLib = p.getString('library_tracks');
      if (rawLib != null) {
        libraryTracks.addAll(
          (jsonDecode(rawLib) as List).map(
            (j) => Track.fromJson(j as Map<String, dynamic>),
          ),
        );
      }
    } catch (e, st) {
      AppLog.error('load library_tracks', e, st);
    }
    // Migration: ensure done tracks in queue or history are in libraryTracks
    for (final t in queue.where((t) => t.status == Status.done)) {
      // Only if the file is still recorded: a song found deleted by the scan has its
      // path removed and must not come back on the next launch.
      if (downloaded.containsKey(t.id) && !libraryTracks.any((x) => x.id == t.id)) {
        libraryTracks.add(t);
      }
    }
    try {
      final rawPl = p.getString('user_playlists');
      if (rawPl != null) {
        userPlaylists.addAll(
          (jsonDecode(rawPl) as List).map(
            (j) => UserPlaylist.fromJson(j as Map<String, dynamic>),
          ),
        );
      }
    } catch (e, st) {
      AppLog.error('load user_playlists', e, st);
    }
    if (userPlaylists.isEmpty) {
      userPlaylists.add(
        UserPlaylist(
          id: 'favorites',
          title: 'Favorites',
          createdAt: DateTime.now(),
        ),
      );
      _savePlaylists();
    }
    membership.value++; // lets pages pick up the loaded settings
    notifyListeners();

    await _dl.init();
    dirProblem = await testDir(dir);
    notifyListeners();

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'wax_downloads',
        channelName: 'Downloads',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    // Resume anything left over if the app was swiped away mid-download.
    if (queue.any((t) => t.status == Status.queued)) run();

    // Scan local storage on startup so existing songs are recognized immediately
    unawaited(scanLocalStorage(force: true));
  }

  void _save() => prefs?.setString(
    'queue',
    jsonEncode(queue.map((t) => t.toJson()).toList()),
  );

  void _saveHistory() => prefs?.setString('history_v2', jsonEncode(downloaded));

  void _saveLibraryTracks() => prefs?.setString(
    'library_tracks',
    jsonEncode(libraryTracks.map((t) => t.toJson()).toList()),
  );

  void _savePlaylists() => prefs?.setString(
    'user_playlists',
    jsonEncode(userPlaylists.map((p) => p.toJson()).toList()),
  );

  int get pendingDownloads =>
      queue.where((t) => t.status == Status.queued || t.status == Status.downloading).length;

  void _addToLibraryTracks(Track t) {
    final idx = libraryTracks.indexWhere((x) => x.id == t.id);
    if (idx >= 0) {
      libraryTracks[idx] = t;
    } else {
      libraryTracks.insert(0, t);
    }
    _saveLibraryTracks();
  }

  /// Deletes a downloaded song from storage and from the library.
  ///
  /// Returns true only when the audio file is really gone. On failure nothing
  /// is removed from the library, so the list never disagrees with the disk.
  Future<bool> deleteFromLibrary(Track t) async {
    // Stop playback first so the player never points at a vanished file.
    final pv = preview;
    if (pv.currentTrack?.id == t.id ||
        pv.playingId == t.id ||
        pv.loadingId == t.id) {
      await pv.stop();
    }

    final path = getLocalTrackPath(t.id);
    if (path != null) {
      final gone = await MediaStoreBridge.delete(path);
      if (!gone) {
        AppLog.error('delete file $path', 'file still exists after delete', null);
        return false;
      }
      try {
        // `path` already passed isSafeAudioPath inside MediaStoreBridge.delete,
        // so it has an audio extension and the replacement below is well-defined.
        final lrc = File(path.replaceAll(RegExp(r'\.[^./]+$'), '.lrc'));
        if (await lrc.exists()) await lrc.delete();
      } catch (e, st) {
        AppLog.error('delete lyrics for $path', e, st);
      }
    }

    libraryTracks.removeWhere((x) => x.id == t.id);
    _saveLibraryTracks();
    downloaded.remove(t.id);
    _exists.remove(t.id);
    _saveHistory();
    _library.remove(libraryKey(t.fileName));
    _library.remove(libraryKey(t.tagTitle));
    _libraryNormalized.remove(normalizeLibraryKey(t.fileName));
    _libraryNormalized.remove(normalizeLibraryKey(t.tagTitle));
    _removeUnattributedTitleIfUnused(t);
    // Playlists keep the entry on purpose: it simply becomes streamable again.
    membership.value++;
    notifyListeners();
    return true;
  }

  /// Edits title/artist/album everywhere the app keeps the song and rewrites
  /// the tags inside the audio file. [retagFailed] is true when a local file
  /// exists but its tags could not be updated (the app-side edit still holds).
  Future<({Track track, bool retagFailed})> updateTrackMetadata(
    Track t, {
    required String newTitle,
    required String newArtist,
    String? newAlbum,
  }) async {
    // Bound user-entered tags (they end up in file names, FFmpeg args and saved data).
    String clip(String v) {
      final c = v.replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'), '').trim();
      return c.length > 200 ? c.substring(0, 200) : c;
    }

    final cleanTitle = clip(newTitle).isEmpty ? t.title : clip(newTitle);
    final cleanArtist = clip(newArtist).isEmpty ? t.author : clip(newArtist);
    final cleanAlbum = newAlbum == null ? null : clip(newAlbum);

    final updated = t.copyWith(
      title: cleanTitle,
      author: cleanArtist,
      album: cleanAlbum != null && cleanAlbum.isNotEmpty ? cleanAlbum : null,
    );

    // 1. Update in libraryTracks
    final libIdx = libraryTracks.indexWhere((x) => x.id == t.id);
    if (libIdx >= 0) {
      libraryTracks[libIdx] = updated;
      _saveLibraryTracks();
    }

    // 2. Update in queue
    final qIdx = queue.indexWhere((x) => x.id == t.id);
    if (qIdx >= 0) {
      queue[qIdx] = updated;
      _save();
    }

    // 3. Update in userPlaylists
    var plChanged = false;
    for (final pl in userPlaylists) {
      final pIdx = pl.tracks.indexWhere((x) => x.id == t.id);
      if (pIdx >= 0) {
        pl.tracks[pIdx] = updated;
        plChanged = true;
      }
    }
    if (plChanged) {
      _savePlaylists();
    }

    // 4. Update in Preview if active
    if (preview.currentTrack?.id == t.id) {
      preview.currentTrack = updated;
    }

    // 5. Retag local audio file if present
    var retagFailed = false;
    final localPath = getLocalTrackPath(t.id);
    if (localPath != null && File(localPath).existsSync()) {
      var ok = false;
      try {
        ok = await _dl.retagFile(
          File(localPath),
          title: cleanTitle,
          artist: cleanArtist,
          album: cleanAlbum ?? cleanTitle,
        );
      } catch (e, st) {
        AppLog.error('retag metadata for ${t.id}', e, st);
      }
      if (ok) {
        await MediaStoreBridge.rescan(localPath);
      } else {
        retagFailed = true;
      }
    }

    // Update search keys
    _library.remove(libraryKey(t.fileName));
    _library.remove(libraryKey(t.tagTitle));
    _library.add(libraryKey(updated.fileName));
    _library.add(libraryKey(updated.tagTitle));
    _libraryNormalized.add(normalizeLibraryKey(updated.fileName));
    _libraryNormalized.add(normalizeLibraryKey(updated.tagTitle));
    if (libIdx >= 0) {
      _removeUnattributedTitleIfUnused(t);
      if (_unknownArtist(updated.tagArtist)) {
        _unattributedTitles.add(libraryKey(updated.tagTitle));
        _unattributedTitlesNormalized.add(normalizeLibraryKey(updated.tagTitle));
      }
    }

    membership.value++;
    notifyListeners();
    return (track: updated, retagFailed: retagFailed);
  }

  UserPlaylist createPlaylist(String title) {
    final clean = title.trim().isEmpty ? 'New Playlist' : title.trim();
    final pl = UserPlaylist(
      id: 'pl_${DateTime.now().millisecondsSinceEpoch}',
      title: clean,
      createdAt: DateTime.now(),
    );
    userPlaylists.insert(0, pl);
    _savePlaylists();
    notifyListeners();
    return pl;
  }

  UserPlaylist importPlaylist(UserPlaylist pl) {
    final uniqueId = 'pl_${DateTime.now().millisecondsSinceEpoch}';
    final newPl = UserPlaylist(
      id: uniqueId,
      title: pl.title,
      tracks: List<Track>.from(pl.tracks),
      createdAt: DateTime.now(),
    );
    userPlaylists.insert(0, newPl);
    _savePlaylists();
    notifyListeners();
    return newPl;
  }

  void deletePlaylist(String playlistId) {
    userPlaylists.removeWhere((p) => p.id == playlistId);
    _savePlaylists();
    notifyListeners();
  }

  void renamePlaylist(String playlistId, String newTitle) {
    final pl = userPlaylists.where((p) => p.id == playlistId).firstOrNull;
    if (pl != null) {
      pl.title = newTitle.trim().isEmpty ? pl.title : newTitle.trim();
      _savePlaylists();
      notifyListeners();
    }
  }

  bool addTrackToPlaylist(String playlistId, Track track) {
    final pl = userPlaylists.where((p) => p.id == playlistId).firstOrNull;
    if (pl == null) return false;
    if (pl.containsTrack(track.id)) return false;
    pl.addTrack(track);
    _savePlaylists();
    notifyListeners();
    return true;
  }

  bool removeTrackFromPlaylist(String playlistId, String trackId) {
    final pl = userPlaylists.where((p) => p.id == playlistId).firstOrNull;
    if (pl == null) return false;
    pl.removeTrack(trackId);
    _savePlaylists();
    notifyListeners();
    return true;
  }

  void reorderTrackInPlaylist(String playlistId, int oldIndex, int newIndex) {
    final pl = userPlaylists.where((p) => p.id == playlistId).firstOrNull;
    if (pl == null) return;
    pl.reorderTrack(oldIndex, newIndex);
    _savePlaylists();
    notifyListeners();
  }

  bool isInPlaylist(String playlistId, String trackId) {
    final pl = userPlaylists.where((p) => p.id == playlistId).firstOrNull;
    return pl?.containsTrack(trackId) ?? false;
  }

  /// True only while the saved file still exists, so a track you deleted
  /// from the phone can be downloaded again.
  bool isDownloaded(String id) {
    final path = downloaded[id];
    if (path == null) return false;
    // Cached: this is called for every visible tile. Cleared on each search.
    return _exists.putIfAbsent(id, () => File(path).existsSync());
  }

  void refreshDownloaded() => _exists.clear();

  DateTime? _lastLibraryScan;

  /// True if the library filesystem hasn't been scanned in over 60 seconds.
  bool get isLibraryStale =>
      _lastLibraryScan == null ||
      DateTime.now().difference(_lastLibraryScan!).inSeconds > 60;

  /// Comprehensive scan of local storage (MediaStore and local directories)
  /// to index all existing songs, populate the Library tab, and prevent duplicate downloads.
  Future<int> scanLocalStorage({bool force = false}) async {
    if (_activeScanCompleter != null) {
      await _activeScanCompleter!.future;
      if (!force) return 0;
    }
    if (!force && !isLibraryStale) return 0;

    final completer = _activeScanCompleter = Completer<int>();
    notifyListeners();

    var discoveredCount = 0;
    _exists.clear();
    final keys = <String>{};
    final normKeys = <String>{};
    final unattributedTitles = <String>{};
    final unattributedTitlesNormalized = <String>{};

    try {
      // 1. Check/request audio permission if supported on Android
      if (await MediaStoreBridge.supported()) {
        if (!await MediaStoreBridge.canRead() &&
            !(prefs?.getBool('askedAudio') ?? false)) {
          await prefs?.setBool('askedAudio', true);
          await MediaStoreBridge.askRead();
        }
      }

      final items = <Map<String, dynamic>>[];

      // 2. Query MediaStore on Android (covers both internal storage and SD card)
      if (await MediaStoreBridge.supported()) {
        final msList = await MediaStoreBridge.listDetails();
        items.addAll(msList);
      }

      // 3. Scan filesystem in dir (and Music/Download directories if accessible)
      final dirsToScan = <String>{dir};
      final rel = musicRelative(dir);
      if (rel != null) {
        dirsToScan.add(musicRoot);
      }
      for (final dPath in dirsToScan) {
        final d = Directory(dPath);
        if (await d.exists()) {
          try {
            await for (final f in d.list(recursive: true, followLinks: false).handleError((_) {})) {
              if (f is File) {
                final path = f.path;
                final name = f.uri.pathSegments.isNotEmpty ? f.uri.pathSegments.last : '';
                if (name.startsWith('.') ||
                    name.endsWith('.part') ||
                    name.endsWith('.tmp') ||
                    name.endsWith('.lrc') ||
                    name.endsWith('.jpg') ||
                    name.endsWith('.png')) {
                  continue;
                }
                final dot = name.lastIndexOf('.');
                if (dot < 0) continue;
                final ext = name.substring(dot).toLowerCase();
                if (!const ['.m4a', '.mp3', '.flac', '.opus', '.ogg', '.wav', '.aac', '.webm'].contains(ext)) {
                  continue;
                }

                // If MediaStore already listed this exact path, skip duplicate
                if (items.any((it) => it['path'] == path)) continue;

                final base = name.substring(0, dot);
                var artist = '';
                var title = base;
                if (base.contains(' - ')) {
                  final parts = base.split(' - ');
                  artist = parts.first.trim();
                  title = parts.skip(1).join(' - ').trim();
                }

                // Check for accompanying local .lrc lyrics file
                String? lrcText;
                final lrcFile = File('$dPath/$base.lrc');
                if (lrcFile.existsSync() &&
                    lrcFile.lengthSync() > 0 &&
                    lrcFile.lengthSync() <= 1024 * 1024) {
                  try {
                    lrcText = lrcFile.readAsStringSync();
                  } catch (_) {}
                }

                // Check for accompanying local cover image file
                String? coverPath;
                for (final ext in const ['.jpg', '.png', '.jpeg', '.webp']) {
                  final img = File('$dPath/$base$ext');
                  if (img.existsSync() && img.lengthSync() > 0) {
                    coverPath = img.path;
                    break;
                  }
                }
                if (coverPath == null && f.parent.existsSync()) {
                  for (final cName in const ['cover.jpg', 'cover.png', 'folder.jpg', 'folder.png']) {
                    final img = File('${f.parent.path}/$cName');
                    if (img.existsSync() && img.lengthSync() > 0) {
                      coverPath = img.path;
                      break;
                    }
                  }
                }
                coverPath ??= extractEmbeddedThumbnailOrVideoId(f);

                items.add({
                  'id': 'fs_${path.hashCode.abs().toRadixString(16)}',
                  'displayName': name,
                  'title': title,
                  'artist': artist,
                  'album': '',
                  'durationMs': 0,
                  'path': path,
                  'coverPath': coverPath,
                  'lyrics': lrcText,
                });
              }
            }
          } catch (e, st) {
            AppLog.error('scan dir $dPath', e, st);
          }
        }
      }

      // 4. Index all discovered items into _library and libraryTracks
      for (final item in items) {
        final path = item['path']?.toString() ?? '';
        final displayName = item['displayName']?.toString() ?? '';
        var title = item['title']?.toString() ?? '';
        var artist = item['artist']?.toString() ?? '';
        final album = item['album']?.toString() ?? '';
        final durMs = (item['durationMs'] as num?)?.toInt() ?? 0;
        var coverPath = item['coverPath']?.toString() ?? '';
        final lyrics = item['lyrics']?.toString();

        if (coverPath.isEmpty && path.isNotEmpty) {
          coverPath = extractEmbeddedThumbnailOrVideoId(File(path)) ?? '';
        }

        if (displayName.isEmpty && path.isEmpty) continue;
        final baseName = displayName.isNotEmpty
            ? displayName
            : (path.contains('/') ? path.split('/').last : path);

        if (displayName.isNotEmpty) {
          keys.add(libraryKey(displayName));
          normKeys.add(normalizeLibraryKey(displayName));
        }
        if (title.isNotEmpty) {
          keys.add(libraryKey(title));
          normKeys.add(normalizeLibraryKey(title));
          if (_unknownArtist(artist)) {
            unattributedTitles.add(libraryKey(title));
            unattributedTitlesNormalized.add(normalizeLibraryKey(title));
          }
        }
        if (artist.isNotEmpty && title.isNotEmpty) {
          final clean = '$artist - $title';
          keys.add(libraryKey(clean));
          normKeys.add(normalizeLibraryKey(clean));
        }

        if (path.isNotEmpty) {
          // Check if an existing track in libraryTracks matches
          Track? matchedTrack;
          for (final entry in downloaded.entries) {
            if (entry.value == path) {
              matchedTrack = libraryTracks.where((t) => t.id == entry.key).firstOrNull ??
                  queue.where((t) => t.id == entry.key).firstOrNull;
              break;
            }
          }

          matchedTrack ??= libraryTracks.where((t) {
            final tKey = libraryKey(t.fileName);
            return tKey == libraryKey(baseName) ||
                (t.tagTitle.isNotEmpty &&
                    libraryKey(t.tagTitle) == libraryKey(title) &&
                    normalizeLibraryKey(t.tagArtist) == normalizeLibraryKey(artist));
          }).firstOrNull;

          if (matchedTrack != null) {
            downloaded[matchedTrack.id] = path;
            _exists[matchedTrack.id] = true;
            // Update thumb if previously empty or pointing to an audio file or missing local file
            final curThumb = matchedTrack.thumb.trim();
            final isCurThumbValid = curThumb.isNotEmpty &&
                !curThumb.endsWith('.m4a') &&
                !curThumb.endsWith('.mp3') &&
                !curThumb.endsWith('.opus') &&
                !curThumb.endsWith('.flac') &&
                (curThumb.startsWith('http') || File(curThumb).existsSync());
            if (!isCurThumbValid && coverPath.isNotEmpty) {
              final idx = libraryTracks.indexOf(matchedTrack);
              if (idx >= 0) {
                libraryTracks[idx] = matchedTrack.copyWith(thumb: coverPath);
              }
            }
            if (lyrics != null && lyrics.isNotEmpty) {
              LyricsService.setCached(
                matchedTrack.id,
                LyricsResult(
                  lyrics: lyrics,
                  isSynced: lyrics.contains(RegExp(r'\[\d{2}:\d{2}')),
                  source: 'local_lrc',
                ),
              );
            }
          } else {
            // New local track discovered from local storage
            final localId = 'local_${path.hashCode.abs().toRadixString(16)}';
            if (title.isEmpty) {
              final dot = baseName.lastIndexOf('.');
              final raw = dot > 0 ? baseName.substring(0, dot) : baseName;
              if (raw.contains(' - ')) {
                final pts = raw.split(' - ');
                artist = pts.first.trim();
                title = pts.skip(1).join(' - ').trim();
              } else {
                title = raw;
              }
            }
            if (artist.isEmpty) artist = 'Unknown Artist';

            final newTrack = Track(
              localId,
              title,
              artist,
              coverPath,
              durMs > 0 ? Duration(milliseconds: durMs) : null,
              album: album.isNotEmpty ? album : null,
            );
            newTrack.status = Status.done;

            libraryTracks.add(newTrack);
            downloaded[localId] = path;
            _exists[localId] = true;
            discoveredCount++;

            if (lyrics != null && lyrics.isNotEmpty) {
              LyricsService.setCached(
                localId,
                LyricsResult(
                  lyrics: lyrics,
                  isSynced: lyrics.contains(RegExp(r'\[\d{2}:\d{2}')),
                  source: 'local_lrc',
                ),
              );
            }
          }
        }
      }

      _lastLibraryScan = DateTime.now();
      _library = keys;
      _libraryNormalized = normKeys;
      _unattributedTitles = unattributedTitles;
      _unattributedTitlesNormalized = unattributedTitlesNormalized;

      // 5. Drop songs whose file was deleted outside the app (any song, not just
      // local_ ones). A song counts as present if this scan saw its path or the
      // file exists. If its folder is unreachable (SD card removed, permission
      // lost) it is kept, so a failed scan can never wipe the library.
      final seenPaths = <String>{
        for (final it in items) it['path']?.toString() ?? '',
      };
      bool gone(String? p) {
        if (p == null || p.isEmpty) return false;
        if (seenPaths.contains(p)) return false;
        try {
          if (File(p).existsSync()) return false;
          return File(p).parent.existsSync();
        } catch (_) {
          return false;
        }
      }
      var removed = 0;
      libraryTracks.removeWhere((t) {
        final p = downloaded[t.id];
        if (!gone(p)) return false;
        downloaded.remove(t.id);
        _exists.remove(t.id);
        removed++;
        return true;
      });
      // Done downloads kept in the queue/history whose file vanished.
      for (final t in queue) {
        if (t.status == Status.done && gone(downloaded[t.id])) {
          downloaded.remove(t.id);
          _exists.remove(t.id);
          removed++;
        }
      }
      if (removed > 0) AppLog.info('scanLocalStorage: removed $removed deleted songs');
      AppLog.info('scanLocalStorage: ${_library.length} keys, ${libraryTracks.length} tracks in library ($discoveredCount new)');
      _saveLibraryTracks();
      _saveHistory();
      completer.complete(discoveredCount);
    } catch (e, st) {
      completer.complete(0);
      AppLog.error('scanLocalStorage', e, st);
    } finally {
      _activeScanCompleter = null;
      membership.value++;
      notifyListeners();
    }
    return discoveredCount;
  }

  /// Scans the save folder and all nested subfolders so songs downloaded
  /// earlier (or placed in nested folders) are recognised by name.
  Future<void> refreshLibrary({bool force = false}) =>
      scanLocalStorage(force: force);

  static bool _unknownArtist(String artist) {
    final name = artist.trim().toLowerCase();
    return name.isEmpty || name == '<unknown>' || name == 'unknown artist';
  }

  void _removeUnattributedTitleIfUnused(Track track) {
    if (!_unknownArtist(track.tagArtist)) return;
    final key = libraryKey(track.tagTitle);
    final normalized = normalizeLibraryKey(track.tagTitle);
    final remaining = libraryTracks.where((t) => _unknownArtist(t.tagArtist));
    if (!remaining.any((t) => libraryKey(t.tagTitle) == key)) {
      _unattributedTitles.remove(key);
    }
    if (!remaining.any((t) => normalizeLibraryKey(t.tagTitle) == normalized)) {
      _unattributedTitlesNormalized.remove(normalized);
    }
  }

  /// True if a file with this song's name or title is already in the save folder (or any subfolder).
  bool inLibrary(Track t) {
    if (_library.contains(libraryKey(t.fileName))) return true;
    if (_unattributedTitles.contains(libraryKey(t.tagTitle))) return true;
    final clean = '${t.tagArtist} - ${t.tagTitle}';
    if (_library.contains(libraryKey(clean))) return true;

    // Smart normalized check
    final normClean = normalizeLibraryKey(clean);
    final normTitle = normalizeLibraryKey(t.tagTitle);
    if (normTitle.isNotEmpty && normClean.isNotEmpty && _libraryNormalized.contains(normClean)) return true;
    if (normTitle.isNotEmpty && _unattributedTitlesNormalized.contains(normTitle)) return true;
    if (normTitle.isNotEmpty && t.title.contains(' - ')) {
      final normFull = normalizeLibraryKey(t.title);
      if (normFull.isNotEmpty && _libraryNormalized.contains(normFull)) return true;
    }

    // Direct filesystem check in dir for fast local hit
    for (final ext in const ['m4a', 'mp3', 'flac', 'opus', 'ogg', 'wav']) {
      final p1 = '$dir/${t.fileName}.$ext';
      if (File(p1).existsSync()) {
        downloaded[t.id] = p1;
        _exists[t.id] = true;
        _library.add(libraryKey(t.fileName));
        _libraryNormalized.add(normalizeLibraryKey(t.fileName));
        return true;
      }
      final p2 = '$dir/$clean.$ext';
      if (File(p2).existsSync()) {
        downloaded[t.id] = p2;
        _exists[t.id] = true;
        _library.add(libraryKey(clean));
        _libraryNormalized.add(normalizeLibraryKey(clean));
        return true;
      }
    }

    return false;
  }

  /// Downloaded by Crate (and still there) or found in the folder by name.
  bool isSaved(Track t) => isDownloaded(t.id) || inLibrary(t);

  void saveFilters() {
    prefs?.setInt('dur', durFilter);
    prefs?.setInt('limit', limit);
    prefs?.setBool('topic', topicOnly);
    prefs?.setBool('plmode', plMode);
    prefs?.setBool('albummode', albumMode);
    prefs?.setBool('artistmode', artistMode);
    prefs?.setBool('verified', verifiedOnly);
  }

  void addRecent(String q) {
    recents.remove(q);
    recents.insert(0, q);
    if (recents.length > 10) recents.removeRange(10, recents.length);
    prefs?.setStringList('recents', recents);
    notifyListeners();
  }

  void clearRecents() {
    recents.clear();
    prefs?.setStringList('recents', recents);
    notifyListeners();
  }

  bool get askedNotifications => prefs?.getBool('askedNotif') ?? false;
  Future<void> markAskedNotifications() async =>
      prefs?.setBool('askedNotif', true);

  Future<void> setWifiOnly(bool v) async {
    wifiOnly = v;
    await prefs?.setBool('wifiOnly', v);
    notifyListeners();
  }

  Future<void> setConcurrency(int n) async {
    concurrency = n < 1 ? 1 : (n > 3 ? 3 : n);
    await prefs?.setInt('concurrency', concurrency);
    notifyListeners();
  }

  Future<void> setTagging(bool v) async {
    tagging = v;
    await prefs?.setBool('tagging', v);
    notifyListeners();
  }

  Future<void> setLyrics(bool v) async {
    lyrics = v;
    await prefs?.setBool('lyrics', v);
    notifyListeners();
  }

  Future<void> setDownloadAlerts(bool v) async {
    downloadAlerts = v;
    await prefs?.setBool('download_alerts', v);
    notifyListeners();
  }

  /// Clears the download history and returns the old entries so the UI can offer Undo.
  Map<String, String> forgetHistory() {
    final old = Map<String, String>.of(downloaded);
    downloaded.clear();
    _exists.clear();
    _saveHistory();
    membership.value++;
    notifyListeners();
    return old;
  }

  void restoreHistory(Map<String, String> old) {
    downloaded.addAll(old);
    _exists.clear();
    _saveHistory();
    membership.value++;
    notifyListeners();
  }

  Future<void> setDir(String d) async {
    final clean = d.trim().replaceAll(RegExp(r'\.{2,}'), '');
    dir = clean;
    dirProblem = null;
    await prefs?.setString('dir', clean);
    unawaited(refreshLibrary());
    notifyListeners();
  }

  Future<String?> testDir(String d) async {
    final clean = d.trim();
    if (clean.isEmpty || clean.contains('\x00') || clean.contains('..')) {
      return tr('Invalid folder path.');
    }
    // Allow-list instead of a deny-list: only shared storage is a valid target
    // (this also keeps /data, /system, /proc, app-private dirs etc. out).
    if (!isAllowedSaveDir(clean)) {
      return tr('Cannot write to that folder. Pick one inside Music or Download.');
    }

    // Folders inside Music/ are saved through MediaStore: no direct write needed.
    if (musicRelative(clean) != null) return null;
    try {
      await Directory(clean).create(recursive: true);
      final f = File('$clean/wax_write_test.tmp');
      await f.writeAsString('ok');
      await f.delete();
      return null;
    } catch (e, st) {
      AppLog.error('test folder $clean', e, st);
      return tr(
        'Cannot write to that folder. Pick one inside Music or Download.',
      );
    }
  }

  /// True while [id] is waiting, downloading or failed (a finished entry
  /// doesn't count: [isDownloaded] decides whether its file still exists).
  bool has(String id) =>
      queue.any((t) => t.id == id && t.status != Status.done);

  int add(Iterable<Track> tracks) {
    var n = 0;
    for (final t in tracks) {
      if (!has(t.id) && !isSaved(t)) {
        // A finished entry whose file was deleted is replaced by the new one.
        queue.removeWhere((x) => x.id == t.id && x.status == Status.done);
        queue.add(t);
        n++;
      }
    }
    _save();
    membership.value++;
    notifyListeners();
    return n;
  }

  void remove(Track t) {
    if (t.status == Status.downloading) return;
    _lastRemovedIndex = queue.indexOf(t);
    _lastRemoved = t;
    queue.remove(t);
    _save();
    membership.value++;
    notifyListeners();
  }

  /// Puts back the track removed last (the Undo action).
  void undoRemove() {
    final t = _lastRemoved;
    if (t == null || queue.contains(t)) return;
    queue.insert(_lastRemovedIndex.clamp(0, queue.length), t);
    _lastRemoved = null;
    _save();
    membership.value++;
    notifyListeners();
  }

  void retry(Track t) {
    t.status = Status.queued;
    t.msg = '';
    _save();
    notifyListeners();
    run();
  }

  /// Re-queues failed items and starts the worker.
  void startAll() {
    for (final t in queue) {
      if (t.status == Status.error) {
        t.status = Status.queued;
        t.msg = '';
      }
    }
    _save();
    notifyListeners();
    run();
  }

  void cancel(Track t) {
    if (t.status == Status.downloading) t.cancelled = true;
  }

  /// Aborts the current download and leaves the rest of the queue waiting.
  void stopAll() {
    _stop = true;
    for (final t in queue) {
      cancel(t);
    }
  }

  /// Moves a waiting track in front of the other waiting tracks.
  void prioritize(Track t) {
    if (t.status != Status.queued) return;
    queue.remove(t);
    final first = queue.indexWhere((x) => x.status == Status.queued);
    queue.insert(first < 0 ? queue.length : first, t);
    _save();
    notifyListeners();
  }

  void clearFinished() {
    queue.removeWhere(
      (t) => t.status == Status.done || t.status == Status.error,
    );
    _save();
    membership.value++;
    notifyListeners();
  }

  Future<void> _startService() async {
    try {
      if (!await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.startService(
          serviceId: 7,
          notificationTitle: 'Wax',
          notificationText: tr('Starting downloads…'),
          serviceTypes: [ForegroundServiceTypes.dataSync],
          callback: startCallback,
        );
      }
    } catch (e, st) {
      // Downloads still work in the foreground if the service can't start.
      AppLog.error('start service', e, st);
    }
  }

  Future<void> _note(Track t, {int? pct}) async {
    final left = queue.where((x) => x.status == Status.queued).length;
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: pct == null ? 'Wax' : 'Wax · $pct%',
        notificationText: trp('{title}  ·  {n} left', {
          'title': t.title,
          'n': left,
        }),
      );
    } catch (_) {}
  }

  Future<bool> _onWifi() async {
    try {
      final r = await Connectivity().checkConnectivity();
      return r.contains(ConnectivityResult.wifi) ||
          r.contains(ConnectivityResult.ethernet);
    } catch (e, st) {
      AppLog.error('connectivity check', e, st);
      return true; // a failing check must not block downloads
    }
  }

  /// One download lane. Several run side by side when concurrency > 1.
  Future<void> _worker() async {
    while (!_stop) {
      if (wifiOnly && !await _onWifi()) {
        if (!queue.any((x) => x.status == Status.queued)) return;
        waitingForWifi = true;
        notifyListeners();
        for (var i = 0; i < 15 && !_stop; i++) {
          await Future.delayed(
            const Duration(seconds: 1),
          ); // Stop reacts quickly
        }
        continue;
      }
      if (waitingForWifi) {
        waitingForWifi = false;
        notifyListeners();
      }
      final t = queue.where((x) => x.status == Status.queued).firstOrNull;
      if (t == null) return;
      // Claim it before any await so parallel lanes never take the same track.
      t.status = Status.downloading;
      t.msg = '';
      t.cancelled = false;
      notifyListeners();
      await _note(t);
      await _download(t);
    }
  }

  Future<void> run() async {
    if (running) return;
    running = true;
    _stop = false;
    notifyListeners();
    await _startService();
    await Future.wait([for (var i = 0; i < concurrency; i++) _worker()]);
    waitingForWifi = false;
    running = false;
    notifyListeners();
    // Something may have been queued while the last item was finishing.
    if (!_stop && queue.any((t) => t.status == Status.queued)) return run();
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}
    // ...or while the service was shutting down.
    if (!running && !_stop && queue.any((t) => t.status == Status.queued)) {
      unawaited(run());
    }
    if (!running) {
      // Final tail of a run: tell the UI how it went (not after Stop).
      if (!_stop && runSaved + runFailed > 0) {
        runFinished.value = (saved: runSaved, failed: runFailed);
      }
      runSaved = 0;
      runFailed = 0;
    }
  }

  Future<void> _download(Track t) async {
    // (_worker already claimed [t] and reset its flags.)
    Object? failure;
    String? savedPath;
    for (var attempt = 0; attempt < 3; attempt++) {
      t.progress = 0;
      if (attempt > 0) {
        t.msg = trp('Retrying ({n}/2)…', {'n': attempt});
        notifyListeners();
        await Future.delayed(Duration(seconds: 2 * attempt));
        t.msg = '';
      }
      try {
        savedPath = await _dl.fetch(
          t,
          attempt,
          dir: dir,
          tagging: tagging,
          lyrics: lyrics,
          onProgress: (fraction) {
            t.progress = fraction;
            notifyListeners();
            final pct = (fraction * 100).floor();
            if (pct % 10 == 0) unawaited(_note(t, pct: pct));
          },
          onStatus: (message) {
            t.msg = message;
            notifyListeners();
          },
        );
        failure = null;
        break;
      } on Cancelled catch (e) {
        failure = e;
        break;
      } on FileSystemException catch (e, st) {
        failure = e;
        AppLog.error('storage ${t.id}', e, st);
        break; // retrying won't fix a bad folder or a full disk
      } catch (e, st) {
        failure = e;
        AppLog.error('download ${t.id} (attempt ${attempt + 1})', e, st);
        if (Downloader.isBlocked(e)) {
          // This video may be restricted even when other queued songs work.
          break;
        }
      }
    }
    if (failure == null) {
      t.status = Status.done;
      runSaved++;
      t.msg = '';
      downloaded[t.id] = savedPath!;
      _library.add(libraryKey(t.fileName));
      _exists[t.id] = true;
      _saveHistory();
      _addToLibraryTracks(t);
    } else {
      t.status = Status.error;
      if (failure is! Cancelled) runFailed++;
      t.msg = Downloader.friendly(failure);
    }
    _save();
    notifyListeners();
  }
}
