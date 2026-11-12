import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../constants.dart';
import '../downloader.dart';
import '../log.dart';
import '../models/track.dart';
import '../models/video_ext.dart';
import '../music_detector.dart';
import '../state.dart';
import '../strings.dart';
import '../models/music_category.dart';
import '../playlist_search.dart';
import '../ytm_search.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/track_actions_sheet.dart';
import '../widgets/track_image.dart';

class SearchPage extends StatefulWidget {
  final AppState app;
  final VoidCallback? onOpenQueue;
  final Future<DetectedMusic?> Function({void Function(String)? onStateChange})? detectMusic;
  const SearchPage({super.key, required this.app, this.onOpenQueue, this.detectMusic});
  @override
  State<SearchPage> createState() => SearchPageState();
}

class _NavSnapshot {
  final List<Track> results;
  final List<PlaylistHit> plHits;
  final String? playlist;
  final ArtistDetails? artist;

  _NavSnapshot({
    required this.results,
    required this.plHits,
    this.playlist,
    this.artist,
  });
}

class SearchPageState extends State<SearchPage> {
  final ctrl = TextEditingController();
  List<Track> results = [];
  List<PlaylistHit> plHits = []; // playlist or artist search results
  ArtistDetails? artist;
  final List<_NavSnapshot> _navStack = [];
  String? playlist, error;
  bool loading = false, searched = false;
  int _searchId = 0; // ignore results of superseded searches
  final Set<String> _sel = {}; // ticked tracks while a playlist is shown
  List<String> _suggestions = [];
  Timer? _debounceTimer;

  AppState get app => widget.app;

  void openArtistDirect(String browseId, [String? name]) {
    _openArtistPage(browseId, name);
  }

  void openAlbumForTrack(Track track) => _openAlbumForTrack(track);

  void openAlbumDirect(String browseId, [String? title]) {
    _openAlbumForTrack(Track(
      '',
      title ?? '',
      '',
      '',
      null,
      album: title,
      albumBrowseId: browseId,
    ));
  }

  void searchFor(String query) {
    _navStack.clear();
    artist = null;
    playlist = null;
    ctrl.text = query;
    if (query.trim().isNotEmpty) {
      _search();
    } else {
      setState(() {
        results = [];
        plHits = [];
        searched = false;
        error = null;
      });
    }
  }

  bool get canGoBack =>
      _suggestions.isNotEmpty ||
      _navStack.isNotEmpty ||
      artist != null ||
      playlist != null ||
      searched ||
      results.isNotEmpty ||
      plHits.isNotEmpty ||
      ctrl.text.isNotEmpty;

  bool goBack() {
    if (_suggestions.isNotEmpty) {
      setState(() => _suggestions = []);
      return true;
    }
    if (_navStack.isNotEmpty) {
      final prev = _navStack.removeLast();
      setState(() {
        results = prev.results;
        plHits = prev.plHits;
        playlist = prev.playlist;
        artist = prev.artist;
        _sel.clear();
        if (prev.playlist != null) {
          _sel.addAll(prev.results.where(_addable).map((t) => t.id));
        }
      });
      return true;
    }
    if (artist != null || playlist != null) {
      setState(() {
        artist = null;
        playlist = null;
        _sel.clear();
      });
      return true;
    }
    if (searched || results.isNotEmpty || plHits.isNotEmpty || ctrl.text.isNotEmpty) {
      setState(() {
        results = [];
        plHits = [];
        searched = false;
        error = null;
        ctrl.clear();
        _sel.clear();
      });
      return true;
    }
    return false;
  }

  void _pushNav() {
    _navStack.add(_NavSnapshot(
      results: List<Track>.from(results),
      plHits: List<PlaylistHit>.from(plHits),
      playlist: playlist,
      artist: artist,
    ));
  }

  void _goBack() {
    if (_navStack.isNotEmpty) {
      final prev = _navStack.removeLast();
      setState(() {
        results = prev.results;
        plHits = prev.plHits;
        playlist = prev.playlist;
        artist = prev.artist;
        _sel.clear();
        if (prev.playlist != null) {
          _sel.addAll(prev.results.where(_addable).map((t) => t.id));
        }
      });
    } else {
      setState(() {
        playlist = null;
        artist = null;
        results = [];
        _sel.clear();
      });
    }
  }

  // Filters live in AppState so they persist between launches.
  int get durFilter => app.durFilter; // 0 any, 1 <5m, 2 5-20m, 3 >20m
  set durFilter(int v) {
    app.durFilter = v;
    app.saveFilters();
  }

  int get limit => app.limit;
  set limit(int v) {
    app.limit = v;
    app.saveFilters();
  }

  bool get topicOnly => app.topicOnly; // YouTube Music "- Topic" uploads
  set topicOnly(bool v) {
    app.topicOnly = v;
    app.saveFilters();
  }

  bool get plMode => app.plMode; // search for playlists instead of songs
  set plMode(bool v) {
    app.plMode = v;
    app.saveFilters();
  }

  bool get albumMode => app.albumMode; // search for official albums
  set albumMode(bool v) {
    app.albumMode = v;
    app.saveFilters();
  }

  bool get artistMode => app.artistMode; // search for artists
  set artistMode(bool v) {
    app.artistMode = v;
    app.saveFilters();
  }

  bool get verifiedOnly => app.verifiedOnly; // only verified channels / artists
  set verifiedOnly(bool v) {
    app.verifiedOnly = v;
    app.saveFilters();
  }

  @override
  void initState() {
    super.initState();
    app.membership.addListener(_refresh);
    app.preview.addListener(_onPreview);
    app.sharedUrl.addListener(_onShared);
    ctrl.addListener(_onQueryChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onShared());
  }

  @override
  void dispose() {
    app.membership.removeListener(_refresh);
    app.preview.removeListener(_onPreview);
    app.sharedUrl.removeListener(_onShared);
    _debounceTimer?.cancel();
    ctrl.removeListener(_onQueryChanged);
    ctrl.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    final q = ctrl.text.trim();
    _debounceTimer?.cancel();
    if (q.isEmpty || q.startsWith('http')) {
      if (_suggestions.isNotEmpty && mounted) {
        setState(() => _suggestions = []);
      }
      return;
    }
    _debounceTimer = Timer(const Duration(milliseconds: 250), () async {
      if (!mounted) return;
      final cur = ctrl.text.trim();
      if (cur.isEmpty || cur.startsWith('http')) return;
      final list = await PlaylistSearchService.getSuggestions(cur);
      if (!mounted || ctrl.text.trim() != cur) return;
      setState(() => _suggestions = list);
    });
  }

  /// A link arrived from the share sheet: search it right away.
  void _onShared() {
    final url = app.sharedUrl.value;
    if (url == null || !mounted) return;
    app.sharedUrl.value = null;
    ctrl.text = url;
    _search();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _onPreview() {
    final e = app.preview.error;
    if (e == null || !mounted) return;
    app.preview.error = null;
    showAppSnackBar(context, e);
  }

  Widget _previewThumb(Track t, {double size = 52, List<Track>? contextTracks}) => ListenableBuilder(
    listenable: app.preview,
    builder: (_, _) {
      final loading = app.preview.loadingId == t.id;
      final playing = app.preview.playingId == t.id && app.preview.isPlaying;
      return Semantics(
        button: true,
        label: playing ? '${tr('Pause')} ${t.title}' : '${tr('Play')} ${t.title}',
        child: Tooltip(
          message: playing ? tr('Pause') : tr('Play'),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => app.preview.toggle(t, contextTracks: contextTracks),
            child: Stack(
              alignment: Alignment.center,
              children: [
                TrackImage(
                  thumb: app.getCoverArt(t),
                  width: size,
                  height: size,
                  borderRadius: BorderRadius.circular(8),
                ),
                Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    color: playing ? Colors.black54 : (loading ? Colors.black45 : Colors.black26),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                if (loading)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                else
                  Icon(
                    playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: playing ? accent(context) : Colors.white,
                    size: size > 40 ? 28 : 22,
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _genreCard(String title, String query, IconData icon, Color color) {
    return Semantics(
      button: true,
      label: title,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            HapticFeedback.lightImpact();
            ctrl.text = query;
            _search();
          },
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: LinearGradient(
                colors: [
                  color.withValues(alpha: 0.85),
                  color.withValues(alpha: 0.55),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.25),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(icon, color: Colors.white, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      letterSpacing: -0.2,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _emptyState() {
    final hint = playlist != null
        ? tr('This playlist is empty or its tracks are unavailable.')
        : searched
        ? (artistMode
              ? tr('No artists found.')
              : albumMode
              ? (verifiedOnly
                  ? tr('No verified albums found.')
                  : tr('No albums found.'))
              : plMode
              ? (verifiedOnly
                  ? tr('No verified playlists found. Try turning off the Verified only filter.')
                  : tr('No playlists found.'))
              : verifiedOnly
              ? tr('No verified results found. Try turning off the Verified only filter.')
              : tr('No results.'))
        : tr('Search for a track or paste a video / playlist link');
    return ListenableBuilder(
      listenable: app,
      builder: (_, _) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (searched)
            Padding(
              padding: const EdgeInsets.only(top: 48, bottom: 24),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        artistMode
                            ? Icons.person_off_rounded
                            : albumMode
                                ? Icons.album_rounded
                                : plMode
                                    ? Icons.queue_music_rounded
                                    : Icons.music_off_rounded,
                        size: 36,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      tr('No results found'),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        hint,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    if (verifiedOnly) ...[
                      const SizedBox(height: 16),
                      FilledButton.tonalIcon(
                        icon: const Icon(Icons.tune_rounded, size: 18),
                        label: Text(tr('Turn off Verified filter')),
                        onPressed: () {
                          setState(() {
                            verifiedOnly = false;
                            topicOnly = false;
                          });
                          _search();
                        },
                      ),
                    ],
                  ],
                ),
              ),
            )
          else ...[
            Text(
              tr('Explore Music'),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 12),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 2.2,
              children: musicCategories
                  .map((cat) => _genreCard(tr(cat.title), cat.query, cat.icon, cat.color))
                  .toList(),
            ),
          ],
          if (!searched && app.recents.isNotEmpty) ...[
            const SizedBox(height: 24),
            Row(
              children: [
                Text(
                  tr('Recent searches'),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const Spacer(),
                TextButton(
                  onPressed: app.clearRecents,
                  child: Text(tr('Clear')),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final q in app.recents)
                  ActionChip(
                    label: Text(q, overflow: TextOverflow.ellipsis),
                    onPressed: () {
                      ctrl.text = q;
                      _search();
                    },
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  bool _durOk(Track t) {
    final s = t.duration?.inSeconds ?? 0;
    return switch (durFilter) {
      1 => s > 0 && s < 300,
      2 => s >= 300 && s <= 1200,
      3 => s > 1200,
      _ => true,
    };
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final text = d?.text?.trim();
    if (!mounted || text == null || text.isEmpty) return;
    ctrl.text = text;
    _search();
  }

  bool _detecting = false;

  Future<void> _detectMusic() async {
    if (_detecting) return;
    setState(() => _detecting = true);

    String statusText = tr('Listening for music...');
    StateSetter? modalSetState;
    var sheetOpen = true;

    showModalBottomSheet<void>(
      context: context,
      isDismissible: true,
      enableDrag: true,
      backgroundColor: sheetBgColor(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModal) {
            modalSetState = setModal;
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Theme.of(context).colorScheme.primaryContainer,
                      ),
                      child: Icon(
                        Icons.graphic_eq,
                        size: 44,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      statusText,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      tr('Keep the phone close to the music source'),
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      sheetOpen = false;
    });

    DetectedMusic? detected;
    MusicDetectionException? failure;
    try {
      detected = await (widget.detectMusic ?? MusicDetector.detect)(
        onStateChange: (state) {
          if (!mounted || !sheetOpen) return;
          if (state == 'identifying') {
            modalSetState?.call(() {
              statusText = tr('Identifying music...');
            });
          }
        },
      );
    } on MusicDetectionException catch (e) {
      failure = e;
    }

    if (!mounted) return;
    if (!sheetOpen) {
      setState(() => _detecting = false);
      return;
    }
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    setState(() => _detecting = false);

    if (detected != null) {
      // The recognition provider's optional video enrichment may return an
      // unrelated first result. Search the recognized artist and title instead.
      app.selectSongSearch();
      ctrl.text = detected.searchQuery;
      _search();
      showAppSnackBar(
        context,
        '${tr('Detected')}: ${detected.artist} - ${detected.title}',
        duration: const Duration(seconds: 3),
        icon: const Icon(Icons.music_note_rounded, size: 18),
      );
    } else if (failure != null) {
      showAppSnackBar(
        context,
        tr(failure.message == 'permission'
            ? 'Microphone permission is needed to identify music.'
            : 'Music identification failed. Check the app log and try again.'),
        duration: const Duration(seconds: 4),
        icon: const Icon(Icons.error_outline_rounded, size: 18),
      );
    } else {
      showAppSnackBar(
        context,
        tr('No music detected. Please try again.'),
        duration: const Duration(seconds: 3),
        icon: const Icon(Icons.info_outline_rounded, size: 18),
      );
    }
  }

  void _toast(String msg, {IconData? icon}) {
    if (!mounted) return;
    showAppSnackBar(
      context,
      msg,
      duration: const Duration(milliseconds: 1500),
      icon: icon != null ? Icon(icon, size: 18, color: accent(context)) : null,
    );
  }

  Future<void> _search() async {
    final q = ctrl.text.trim();
    if (q.isEmpty) return;
    _debounceTimer?.cancel();
    _navStack.clear();
    final id = ++_searchId;
    FocusScope.of(context).unfocus();
    setState(() {
      _suggestions = [];
      loading = true;
      error = null;
      playlist = null;
      artist = null;
    });
    try {
      var r = <Track>[];
      String? plTitle;
      var hits = <PlaylistHit>[];
      if (q.startsWith('http')) {
        final mpreMatch = RegExp(r'\b(MPREb_[A-Za-z0-9_-]+)\b').firstMatch(q);
        if (mpreMatch != null) {
          (r, plTitle) = await _loadPlaylist(mpreMatch.group(1)!);
        } else {
          final pl = PlaylistId.parsePlaylistId(q);
          // A "Mix" (RD...) is endless and auto-generated: treat a watch URL
          // carrying one as the single video.
          final isMix =
              pl != null &&
              pl.startsWith('RD'); // parsePlaylistId returns a String?
          if (pl != null && !(isMix && VideoId.parseVideoId(q) != null)) {
            (r, plTitle) = await _loadPlaylist(pl);
          } else {
            final vid = VideoId.parseVideoId(q);
            if (vid == null) throw Exception(tr('Not a YouTube link'));
            r = [(await app.yt.videos.get(vid)).toTrack()];
          }
        }
      } else if (artistMode) {
        // Artists search on YouTube Music
        hits = await PlaylistSearchService.searchArtists(q, limit: limit);
        r = [];
      } else if (albumMode) {
        // Official albums search on YouTube Music
        hits = await PlaylistSearchService.search(
          q,
          verifiedOnly: verifiedOnly,
          albumsOnly: true,
          limit: limit,
        );
        r = [];
      } else if (plMode) {
        // Playlist search: show matching playlists & albums, tap one to open it.
        hits = await PlaylistSearchService.search(
          q,
          verifiedOnly: verifiedOnly,
          albumsOnly: false,
          limit: limit,
        );
        r = [];
      } else {
        if (verifiedOnly) {
          // Verified only is checked: search official YouTube Music tracks
          r = (await YtmSearchService.search(
            q,
            limit: limit,
            verifiedOnly: true,
          ))
              .where(_durOk)
              .toList();

          // Fallback to standard YouTube filtered by topic if YTM had no matches
          if (r.isEmpty) {
            final queryForTopic =
                q.toLowerCase().contains('topic') ? q : '$q topic';
            var page = await app.yt.search.search(queryForTopic);
            for (var i = 0; i < 4; i++) {
              r.addAll(
                page
                    .map((v) => v.toTrack())
                    .where(
                      (t) {
                        if (!_durOk(t)) return false;
                        final aLower = t.author.toLowerCase();
                        final tLower = t.title.toLowerCase();
                        if (aLower.endsWith('vevo') || aLower.contains('vevo')) {
                          return false;
                        }
                        if (tLower.contains('official video') ||
                            tLower.contains('official music video') ||
                            tLower.contains('music video') ||
                            tLower.contains('[mv]') ||
                            tLower.contains('(mv)')) {
                          return false;
                        }
                        return t.author.endsWith('- Topic') ||
                            aLower.contains('topic');
                      },
                    ),
              );
              if (r.length >= limit) break;
              final next = await page.nextPage();
              if (next == null) break;
              page = next;
            }
            r = r.take(limit).toList();
          }
        } else {
          // Standard search (Verified filter OFF):
          // Queries standard YouTube directly, natively searching song titles, lyrics,
          // user uploads, OSTs, and non-topic releases (such as "不凡 - 王铮亮").
          var page = await app.yt.search.search(q);
          for (var i = 0; i < 4; i++) {
            r.addAll(
              page
                  .map((v) => v.toTrack())
                  .where(_durOk),
            );
            if (r.length >= limit) break;
            final next = await page.nextPage();
            if (next == null) break;
            page = next;
          }
          r = r.take(limit).toList();
        }
      }
      if (!mounted || id != _searchId) return;
      if (app.isLibraryStale) {
        unawaited(app.refreshLibrary().then((_) {
          if (mounted) setState(() {});
        }));
      }
      if (!mounted || id != _searchId) return;
      if (!q.startsWith('http') && (r.isNotEmpty || hits.isNotEmpty)) {
        app.addRecent(q);
      }
      setState(() {
        results = r;
        plHits = hits;
        playlist = plTitle;
        // A playlist starts with every addable track ticked.
        _sel
          ..clear()
          ..addAll(
            plTitle == null
                ? const <String>[]
                : r.where(_addable).map((t) => t.id),
          );
        searched = true;
      });
    } catch (e, st) {
      AppLog.error('search', e, st);
      if (!mounted || id != _searchId) return;
      setState(() => error = Downloader.friendly(e));
    } finally {
      if (mounted && id == _searchId) setState(() => loading = false);
    }
  }

  bool _addable(Track t) => !app.has(t.id) && !app.isSaved(t);

  Future<(List<Track>, String)> _loadPlaylist(String id, [String? fallbackTitle]) async {
    // If this is an official YouTube Music album (MPREb... or OLAK5... or VLOLAK5...)
    if (id.startsWith('MPREb') || id.startsWith('OLAK5') || id.startsWith('VLOLAK5')) {
      final album = await PlaylistSearchService.loadAlbum(id);
      if (album != null && album.tracks.isNotEmpty) {
        return (album.tracks, album.title);
      }
    }

    String title = fallbackTitle ?? '';
    try {
      final meta = await app.yt.playlists.get(id);
      if (meta.title.isNotEmpty) title = meta.title;
    } catch (_) {}

    final cleanTitle = PlaylistSearchService.cleanAlbumTitle(title);
    // Fetch up to 100 tracks for responsive loading.
    final vids = await app.yt.playlists.getVideos(id).take(100).toList();
    final tracks = vids
        .map((v) => v.toTrack(album: cleanTitle.isNotEmpty ? cleanTitle : null))
        .toList();
    return (tracks, title);
  }

  /// Opens a playlist or artist from the search results.
  Future<void> _openPlaylist(PlaylistHit pl) async {
    if (pl.isArtist) {
      return _openArtistPage(pl.id, pl.title);
    }
    _pushNav();
    final id = ++_searchId;
    AppLog.info('opening playlist: ${pl.id} ("${pl.title}")');
    setState(() {
      loading = true;
      error = null;
      artist = null;
    });
    try {
      final (tracks, title) = await _loadPlaylist(pl.id, pl.title);
      AppLog.info('playlist ${pl.id} loaded ${tracks.length} tracks');
      if (app.isLibraryStale) {
        unawaited(app.refreshLibrary().then((_) {
          if (mounted) setState(() {});
        }));
      }
      if (!mounted || id != _searchId) return;
      setState(() {
        results = tracks;
        playlist = title.isEmpty ? (pl.title.isEmpty ? tr('Playlist') : pl.title) : title;
        _sel
          ..clear()
          ..addAll(tracks.where(_addable).map((t) => t.id));
      });
    } catch (e, st) {
      AppLog.error('open playlist', e, st);
      if (!mounted || id != _searchId) return;
      setState(() => error = Downloader.friendly(e));
    } finally {
      if (mounted && id == _searchId) setState(() => loading = false);
    }
  }

  /// Opens an official album directly from a track in search results.
  Future<void> _openAlbumForTrack(Track t) async {
    final id = ++_searchId;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      String? browseId = t.albumBrowseId;
      if (browseId == null || browseId.isEmpty) {
        final artistName = t.tagArtist;
        final hits = await PlaylistSearchService.search(
          '$artistName ${t.album}',
          albumsOnly: true,
          limit: 20,
        );
        browseId = PlaylistSearchService.matchAlbum(
          hits, t.album ?? '', artistName,
        )?.id;
      }
      if (browseId == null || browseId.isEmpty) {
        throw Exception(tr('Album details not found'));
      }
      _pushNav();
      final (tracks, title) = await _loadPlaylist(browseId, t.album);
      if (app.isLibraryStale) {
        unawaited(app.refreshLibrary().then((_) {
          if (mounted) setState(() {});
        }));
      }
      if (!mounted || id != _searchId) return;
      setState(() {
        results = tracks;
        artist = null;
        playlist = title.isEmpty ? (t.album ?? tr('Album')) : title;
        _sel
          ..clear()
          ..addAll(tracks.where(_addable).map((x) => x.id));
      });
    } catch (e, st) {
      AppLog.error('open album for track', e, st);
      if (!mounted || id != _searchId) return;
      setState(() => error = Downloader.friendly(e));
    } finally {
      if (mounted && id == _searchId) setState(() => loading = false);
    }
  }

  /// Opens an artist page directly from a track in search results.
  Future<void> _openArtistForTrack(Track t) async {
    final id = ++_searchId;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      String? browseId = t.artistBrowseId;
      if (browseId == null || browseId.isEmpty) {
        final clean = t.author.replaceAll(RegExp(r'\s*-\s*Topic$', caseSensitive: false), '').trim();
        browseId = await PlaylistSearchService.findArtistBrowseId(clean);
      }
      if (browseId == null || browseId.isEmpty) {
        throw Exception(tr('Artist details not found'));
      }
      await _openArtistPage(browseId, t.author);
    } catch (e, st) {
      AppLog.error('open artist for track', e, st);
      if (!mounted || id != _searchId) return;
      setState(() => error = Downloader.friendly(e));
    } finally {
      if (mounted && id == _searchId) setState(() => loading = false);
    }
  }

  /// Opens an artist page by browseId.
  Future<void> _openArtistPage(String browseId, [String? fallbackName]) async {
    if (browseId.isEmpty && fallbackName != null && fallbackName.trim().isNotEmpty) {
      return _openArtistForTrack(Track('', '', fallbackName, '', null));
    }

    _pushNav();
    final id = ++_searchId;
    setState(() {
      loading = true;
      error = null;
      playlist = null;
    });
    try {
      final data = await PlaylistSearchService.loadArtist(browseId);
      if (!mounted || id != _searchId) return;
      if (data == null) throw Exception(tr('Failed to load artist page'));
      if (app.isLibraryStale) {
        unawaited(app.refreshLibrary().then((_) {
          if (mounted) setState(() {});
        }));
      }
      if (!mounted || id != _searchId) return;
      setState(() {
        artist = data;
        results = [];
        playlist = null;
      });
    } catch (e, st) {
      AppLog.error('open artist $browseId', e, st);
      if (!mounted || id != _searchId) return;
      setState(() => error = Downloader.friendly(e));
    } finally {
      if (mounted && id == _searchId) setState(() => loading = false);
    }
  }

  Widget _buildArtistPage(ArtistDetails art) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        // Artist Profile Header
        Center(
          child: Column(
            children: [
              if (art.bannerThumb != null)
                TrackImage(
                  thumb: art.bannerThumb,
                  width: 110,
                  height: 110,
                  shape: BoxShape.circle,
                  placeholderIcon: Icons.person,
                  iconSize: 55,
                )
              else
                CircleAvatar(
                  radius: 55,
                  backgroundColor: accent(context).withValues(alpha: 0.2),
                  child: Icon(Icons.person, size: 55, color: accent(context)),
                ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      art.name,
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(Icons.verified, color: accent(context), size: 20),
                ],
              ),
              if (art.subscriberCount != null) ...[
                const SizedBox(height: 4),
                Text(
                  art.subscriberCount!,
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 24),

        // Top Songs Section
        if (art.topSongs.isNotEmpty) ...[
          Row(
            children: [
              Text(
                tr('Top Songs'),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const Spacer(),
              IconButton(
                tooltip: tr('Play all'),
                icon: const Icon(Icons.play_circle_fill, size: 26),
                color: accent(context),
                onPressed: art.topSongs.isEmpty
                    ? null
                    : () => app.preview.playList(art.topSongs),
              ),
              IconButton(
                tooltip: tr('Shuffle'),
                icon: const Icon(Icons.shuffle, size: 20),
                onPressed: art.topSongs.isEmpty
                    ? null
                    : () => app.preview.playList(art.topSongs, startShuffled: true),
              ),
              TextButton.icon(
                icon: const Icon(Icons.playlist_add, size: 18),
                label: Text(tr('Add all')),
                onPressed: () {
                  final n = app.add(art.topSongs);
                  _toast(
                    n == 0
                        ? tr('Already in the queue')
                        : trp('Added {n} songs', {'n': n}),
                  );
                  app.run();
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final (idx, t) in art.topSongs.indexed)
            ListenableBuilder(
              listenable: app.membership,
              builder: (_, _) {
                final saved = app.isSaved(t);
                final queued = app.has(t.id);
                final addable = !saved && !queued;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  onTap: () => app.preview.toggle(t, contextTracks: art.topSongs),
                  onLongPress: () => TrackActionsSheet.show(
                    context,
                    track: t,
                    app: app,
                    onOpenArtist: _openArtistPage,
                    onOpenAlbum: (bId, title) => _openAlbumForTrack(t.copyWith(album: title, albumBrowseId: bId)),
                  ),
                  leading: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 22,
                        child: Text(
                          '${idx + 1}',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _previewThumb(t, size: 46, contextTracks: art.topSongs),
                    ],
                  ),
                  title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    t.album != null && t.album!.isNotEmpty
                        ? '${t.album!} · ${t.durText}'
                        : (t.durText.isNotEmpty ? t.durText : t.author),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Semantics(
                        label: saved
                            ? tr('Already downloaded')
                            : queued
                            ? tr('In queue')
                            : tr('Download song'),
                        button: addable,
                        child: IconButton(
                          tooltip: saved
                              ? tr('Already downloaded')
                              : queued
                              ? tr('In queue')
                              : tr('Download song'),
                          icon: Icon(
                            saved
                                ? Icons.check_circle
                                : queued
                                ? Icons.hourglass_top
                                : Icons.arrow_downward_rounded,
                            size: 22,
                          ),
                          color: saved ? okColor(context) : (queued ? accent(context) : null),
                          onPressed: addable
                              ? () {
                                  HapticFeedback.lightImpact();
                                  app.add([t]);
                                  app.run();
                                  _toast(tr('Added to queue'));
                                }
                              : null,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.more_vert, size: 20),
                        tooltip: tr('More'),
                        onPressed: () => TrackActionsSheet.show(
                          context,
                          track: t,
                          app: app,
                          onOpenArtist: _openArtistPage,
                          onOpenAlbum: (bId, title) => _openAlbumForTrack(t.copyWith(album: title, albumBrowseId: bId)),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          const SizedBox(height: 20),
        ],

        // Albums Section
        if (art.albums.isNotEmpty) ...[
          Text(
            tr('Albums'),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 195,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: art.albums.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (_, i) {
                final alb = art.albums[i];
                return InkWell(
                  onTap: () => _openPlaylist(alb),
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 135,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TrackImage(
                          thumb: alb.thumbnail,
                          width: 135,
                          height: 135,
                          borderRadius: BorderRadius.circular(8),
                          placeholderIcon: Icons.album,
                          iconSize: 48,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          alb.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                        if (alb.year != null)
                          Text(
                            alb.year!,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 20),
        ],

        // Singles & EPs Section
        if (art.singles.isNotEmpty) ...[
          Text(
            tr('Singles & EPs'),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 195,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: art.singles.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (_, i) {
                final s = art.singles[i];
                return InkWell(
                  onTap: () => _openPlaylist(s),
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 135,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TrackImage(
                          thumb: s.thumbnail,
                          width: 135,
                          height: 135,
                          borderRadius: BorderRadius.circular(8),
                          placeholderIcon: Icons.album,
                          iconSize: 48,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          s.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                        if (s.year != null)
                          Text(
                            s.year!,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _playlistTile(PlaylistHit pl) {
    if (pl.isArtist) {
      return ListTile(
        leading: CircleAvatar(
          radius: 25,
          backgroundImage: Track.sanitizeThumb(pl.thumbnail).isNotEmpty
              ? NetworkImage(Track.sanitizeThumb(pl.thumbnail))
              : null,
          child: pl.thumbnail.isEmpty ? const Icon(Icons.person) : null,
        ),
        title: Text(pl.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: accent(context).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'ARTIST',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: accent(context),
                ),
              ),
            ),
            Flexible(
              child: Text(
                pl.author,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.verified, size: 14, color: accent(context)),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _openArtistPage(pl.id, pl.title),
      );
    }

    final isAlbum = pl.isAlbum;
    final thumbW = isAlbum ? 50.0 : 80.0;
    final thumbH = isAlbum ? 50.0 : 45.0;
    return ListTile(
      leading: TrackImage(
        thumb: pl.thumbnail,
        width: thumbW,
        height: thumbH,
        borderRadius: BorderRadius.circular(6),
        placeholderIcon: isAlbum ? Icons.album : Icons.queue_music,
      ),
      title: Text(pl.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
            margin: const EdgeInsets.only(right: 6),
            decoration: BoxDecoration(
              color: isAlbum
                  ? accent(context).withValues(alpha: 0.15)
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isAlbum ? Icons.album : Icons.queue_music,
                  size: 11,
                  color: isAlbum ? accent(context) : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 3),
                Text(
                  isAlbum
                      ? (pl.year != null ? 'ALBUM · ${pl.year}' : 'ALBUM')
                      : 'PLAYLIST',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: isAlbum ? accent(context) : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: Text(
              isAlbum ? pl.author : 'by ${pl.author}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          if (pl.isVerified) ...[
            const SizedBox(width: 4),
            Icon(Icons.verified, size: 14, color: accent(context)),
          ],
          if (pl.videoCount > 0) ...[
            Text(
              ' · ${trp('{n} tracks', {'n': pl.videoCount})}',
              style: const TextStyle(fontSize: 12.5),
            ),
          ],
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _openPlaylist(pl),
    );
  }

  void _toggle(String id) =>
      setState(() => _sel.contains(id) ? _sel.remove(id) : _sel.add(id));

  void _toggleAll() => setState(() {
    final all = results.where(_addable).map((t) => t.id).toSet();
    if (_sel.containsAll(all)) {
      _sel.clear();
    } else {
      _sel
        ..clear()
        ..addAll(all);
    }
  });

  void _addSelected() {
    final picks = results.where((t) => _sel.contains(t.id)).toList();
    final n = app.add(picks);
    setState(() => _sel.removeAll(picks.map((t) => t.id)));
    _toast(
      n == 0
          ? tr('Already in the queue')
          : trp('Added {n}, skipped {m} duplicates', {
              'n': n,
              'm': picks.length - n,
            }),
    );
    app.run();
  }

  void _openFiltersSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final bgColor = sheetBgColor(context);
            final hasActiveFilters = topicOnly || verifiedOnly || durFilter > 0 || limit != 20;

            return Container(
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Handle
                      Center(
                        child: Container(
                          width: 38,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            tr('Search Filters'),
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          if (hasActiveFilters)
                            TextButton(
                              onPressed: () {
                                setModalState(() {
                                  topicOnly = false;
                                  verifiedOnly = false;
                                  durFilter = 0;
                                  limit = 20;
                                });
                                setState(() {});
                                if (ctrl.text.trim().isNotEmpty) _search();
                              },
                              child: Text(tr('Reset')),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        tr('Duration'),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final (i, label) in [
                            tr('Any length'),
                            tr('< 5 min'),
                            tr('5–20 min'),
                            tr('> 20 min'),
                          ].indexed)
                            ChoiceChip(
                              label: Text(label),
                              selected: durFilter == i,
                              onSelected: (_) {
                                setModalState(() => durFilter = i);
                                setState(() => durFilter = i);
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        tr('Source & Quality'),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 6),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(tr('Verified & Official only')),
                        subtitle: Text(
                          tr('Prioritize official YouTube Music releases and verified artists'),
                          style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                        ),
                        value: verifiedOnly,
                        onChanged: (v) {
                          setModalState(() {
                            verifiedOnly = v;
                            topicOnly = v;
                          });
                          setState(() {
                            verifiedOnly = v;
                            topicOnly = v;
                          });
                        },
                      ),
                      const SizedBox(height: 8),
                      Text(
                        tr('Results limit'),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(value: 10, label: Text('10')),
                          ButtonSegment(value: 20, label: Text('20')),
                          ButtonSegment(value: 30, label: Text('30')),
                        ],
                        selected: {limit},
                        onSelectionChanged: (s) {
                          setModalState(() => limit = s.first);
                          setState(() => limit = s.first);
                        },
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: () {
                            Navigator.pop(ctx);
                            if (ctrl.text.trim().isNotEmpty) _search();
                          },
                          child: Text(tr('Apply')),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            controller: ctrl,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: artistMode
                  ? tr('Search artists')
                  : albumMode
                  ? tr('Search official albums, or paste an album link')
                  : plMode
                  ? tr('Search playlists, or paste a link')
                  : tr('Search songs, artists, albums, or paste link'),
              filled: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(28),
                borderSide: BorderSide.none,
              ),
              prefixIcon: const Icon(Icons.search),
              suffixIcon: ValueListenableBuilder<TextEditingValue>(
                valueListenable: ctrl,
                builder: (_, v, _) => v.text.isEmpty
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: tr('Detect music'),
                            icon: _detecting
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.graphic_eq),
                            onPressed: _detecting ? null : _detectMusic,
                          ),
                          IconButton(
                            tooltip: tr('Paste link'),
                            icon: const Icon(Icons.content_paste),
                            onPressed: _paste,
                          ),
                        ],
                      )
                    : IconButton(
                        tooltip: tr('Clear'),
                        icon: const Icon(Icons.close),
                        onPressed: ctrl.clear,
                      ),
              ),
            ),
          ),
        ),
        if (_suggestions.isNotEmpty)
          Container(
            height: 38,
            margin: const EdgeInsets.only(bottom: 6),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _suggestions.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final s = _suggestions[i];
                return ActionChip(
                  avatar: const Icon(Icons.search, size: 14),
                  label: Text(s),
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    ctrl.text = s;
                    setState(() => _suggestions = []);
                    _search();
                  },
                );
              },
            ),
          ),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  avatar: const Icon(Icons.music_note, size: 16),
                  label: Text(tr('All')),
                  selected: !artistMode && !albumMode && !plMode,
                  onSelected: (v) {
                    if (v) {
                      setState(() {
                        artistMode = false;
                        albumMode = false;
                        plMode = false;
                      });
                      if (ctrl.text.trim().isNotEmpty) _search();
                    }
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  avatar: const Icon(Icons.person, size: 16),
                  label: Text(tr('Artists')),
                  selected: artistMode,
                  onSelected: (v) {
                    setState(() {
                      artistMode = v;
                      if (v) {
                        albumMode = false;
                        plMode = false;
                      }
                    });
                    if (ctrl.text.trim().isNotEmpty) _search();
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  avatar: const Icon(Icons.album, size: 16),
                  label: Text(tr('Albums')),
                  selected: albumMode,
                  onSelected: (v) {
                    setState(() {
                      albumMode = v;
                      if (v) {
                        plMode = false;
                        artistMode = false;
                      }
                    });
                    if (ctrl.text.trim().isNotEmpty) _search();
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  avatar: const Icon(Icons.queue_music, size: 16),
                  label: Text(tr('Playlists')),
                  selected: plMode,
                  onSelected: (v) {
                    setState(() {
                      plMode = v;
                      if (v) {
                        albumMode = false;
                        artistMode = false;
                      }
                    });
                    if (ctrl.text.trim().isNotEmpty) _search();
                  },
                ),
              ),
              FilterChip(
                avatar: Icon(
                  Icons.tune_rounded,
                  size: 16,
                  color: (topicOnly || verifiedOnly || durFilter > 0 || limit != 20)
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                label: Text(
                  (topicOnly || verifiedOnly || durFilter > 0 || limit != 20)
                      ? tr('Filters (Active)')
                      : tr('Filters'),
                ),
                selected: (topicOnly || verifiedOnly || durFilter > 0 || limit != 20),
                onSelected: (_) => _openFiltersSheet(),
              ),
            ],
          ),
        ),
        if (artist != null)
          Container(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            padding: const EdgeInsets.fromLTRB(4, 6, 12, 6),
            child: Row(
              children: [
                IconButton(
                  tooltip: tr('Back'),
                  icon: const Icon(Icons.arrow_back),
                  onPressed: _goBack,
                ),
                Expanded(
                  child: Text(
                    artist!.name,
                    style: Theme.of(context).textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          )
        else if (playlist != null)
          Container(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            padding: const EdgeInsets.fromLTRB(4, 8, 8, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: tr('Back'),
                      icon: const Icon(Icons.arrow_back),
                      onPressed: _goBack,
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            playlist!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          Text(
                            results.any(app.isSaved)
                                ? trp('{n} of {m} selected · {k} already saved', {
                                    'n': _sel.length,
                                    'm': results.length,
                                    'k': results.where(app.isSaved).length,
                                  })
                                : trp('{n} of {m} selected', {
                                    'n': _sel.length,
                                    'm': results.length,
                                  }),
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: _toggleAll,
                      child: Text(
                        results.where(_addable).every((t) => _sel.contains(t.id))
                            ? tr('None')
                            : tr('All'),
                      ),
                    ),
                    FilledButton(
                      onPressed: _sel.isEmpty ? null : _addSelected,
                      child: Text(tr('Add selected')),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
                  child: Row(
                    children: [
                      FilledButton.icon(
                        icon: const Icon(Icons.play_arrow, size: 20),
                        label: Text(tr('Play')),
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                        ),
                        onPressed: results.isEmpty
                            ? null
                            : () => app.preview.playList(results),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.shuffle, size: 18),
                        label: Text(tr('Shuffle')),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                        ),
                        onPressed: results.isEmpty
                            ? null
                            : () => app.preview.playList(results, startShuffled: true),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          trp('Search failed: {e}', {'e': error}),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: _search,
                          child: Text(tr('Retry')),
                        ),
                      ],
                    ),
                  ),
                )
              : artist != null
              ? _buildArtistPage(artist!)
              : plHits.isNotEmpty && playlist == null
              ? ListView.builder(
                  itemCount: plHits.length,
                  itemBuilder: (_, i) => _playlistTile(plHits[i]),
                )
              : results.isEmpty
              ? _emptyState()
              : ListenableBuilder(
                  listenable: app.membership,
                  builder: (_, _) => ListView.builder(
                    itemCount: results.length,
                    itemBuilder: (_, i) {
                      final t = results[i];
                      final saved = app.isSaved(t);
                      final queued = app.has(t.id);
                      final addable = !saved && !queued;
                      final inPlaylist = playlist != null;
                      return ListTile(
                        leading: inPlaylist
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: 20,
                                    child: Text(
                                      '${i + 1}',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                                        fontSize: 12,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  _previewThumb(t, size: 46, contextTracks: results),
                                ],
                              )
                            : _previewThumb(t, size: 50, contextTracks: results),
                        onTap: inPlaylist
                            ? (addable ? () => _toggle(t.id) : () => app.preview.toggle(t, contextTracks: results))
                            : () => app.preview.toggle(t, contextTracks: results),
                        onLongPress: () => TrackActionsSheet.show(
                          context,
                          track: t,
                          app: app,
                          onOpenArtist: _openArtistPage,
                          onOpenAlbum: (bId, title) => _openAlbumForTrack(t.copyWith(album: title, albumBrowseId: bId)),
                        ),
                        title: Text(
                          t.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: InkWell(
                                    onTap: () => _openArtistForTrack(t),
                                    borderRadius: BorderRadius.circular(3),
                                    child: Text(
                                      t.author,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: accent(context),
                                      ),
                                    ),
                                  ),
                                ),
                                Text(
                                  ' · ${t.durText}',
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                            if (!inPlaylist && t.album != null && t.album!.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              InkWell(
                                onTap: () => _openAlbumForTrack(t),
                                borderRadius: BorderRadius.circular(4),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 2),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.album_outlined,
                                        size: 14,
                                        color: accent(context),
                                      ),
                                      const SizedBox(width: 4),
                                      Flexible(
                                        child: Text(
                                          t.album!,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w500,
                                            color: accent(context),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 2),
                                      Icon(
                                        Icons.chevron_right,
                                        size: 14,
                                        color: accent(context),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        trailing: inPlaylist
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (addable)
                                    Checkbox(
                                      value: _sel.contains(t.id),
                                      onChanged: (_) => _toggle(t.id),
                                    )
                                  else
                                    Semantics(
                                      label: saved ? tr('Downloaded') : tr('In queue'),
                                      child: Icon(
                                        saved ? Icons.check_circle : Icons.hourglass_top,
                                        color: saved ? okColor(context) : accent(context),
                                        size: 22,
                                      ),
                                    ),
                                  IconButton(
                                    icon: const Icon(Icons.more_vert, size: 20),
                                    tooltip: tr('More'),
                                    onPressed: () => TrackActionsSheet.show(
                                      context,
                                      track: t,
                                      app: app,
                                      onOpenArtist: _openArtistPage,
                                      onOpenAlbum: (bId, title) => _openAlbumForTrack(t.copyWith(album: title, albumBrowseId: bId)),
                                    ),
                                  ),
                                ],
                              )
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Semantics(
                                    label: saved
                                        ? tr('Already downloaded')
                                        : queued
                                        ? tr('In queue')
                                        : tr('Download song'),
                                    button: addable,
                                    child: IconButton(
                                      tooltip: saved
                                          ? tr('Already downloaded')
                                          : queued
                                          ? tr('In queue')
                                          : tr('Download song'),
                                      icon: Icon(
                                        saved
                                            ? Icons.check_circle
                                            : queued
                                            ? Icons.hourglass_top
                                            : Icons.arrow_downward_rounded,
                                        size: 22,
                                      ),
                                      color: saved ? okColor(context) : (queued ? accent(context) : null),
                                      onPressed: addable
                                          ? () {
                                              HapticFeedback.lightImpact();
                                              app.add([t]);
                                              app.run();
                                              _toast(tr('Added to queue'));
                                            }
                                          : null,
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.more_vert, size: 20),
                                    tooltip: tr('More'),
                                    onPressed: () => TrackActionsSheet.show(
                                      context,
                                      track: t,
                                      app: app,
                                      onOpenArtist: _openArtistPage,
                                      onOpenAlbum: (bId, title) => _openAlbumForTrack(t.copyWith(album: title, albumBrowseId: bId)),
                                    ),
                                  ),
                                ],
                              ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}
