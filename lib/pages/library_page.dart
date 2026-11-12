import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants.dart';
import '../models/track.dart';
import '../models/user_playlist.dart';
import '../playlist_sharing.dart';
import '../state.dart';
import '../strings.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/edit_metadata_dialog.dart';
import '../widgets/track_actions_sheet.dart';
import '../widgets/track_image.dart';

enum LibraryView { allSongs, artists, albums, playlists }

class LibraryPage extends StatefulWidget {
  final AppState app;
  final VoidCallback? onOpenSearch;

  const LibraryPage({
    super.key,
    required this.app,
    this.onOpenSearch,
  });

  @override
  State<LibraryPage> createState() => LibraryPageState();
}

class LibraryPageState extends State<LibraryPage> {
  LibraryView _view = LibraryView.allSongs;
  String? _selectedArtist;
  String? _selectedAlbum;
  UserPlaylist? _selectedPlaylist;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  String _subSearchQuery = '';
  final TextEditingController _subSearchController = TextEditingController();

  // Multi-select (songs, or whole artists / albums) for bulk edit and delete.
  bool _selecting = false;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    // Check local storage for songs on opening Library
    widget.app.scanLocalStorage();
  }

  /// Public back navigation handler for system Back button.
  /// Returns true if internal navigation was popped, false if already at root.
  bool goBack() {
    if (_selecting) {
      _exitSelection();
      return true;
    }
    if (_subSearchQuery.isNotEmpty) {
      setState(() {
        _subSearchQuery = '';
        _subSearchController.clear();
      });
      return true;
    }
    if (_selectedArtist != null) {
      setState(() {
        _selectedArtist = null;
        _subSearchQuery = '';
        _subSearchController.clear();
      });
      return true;
    }
    if (_selectedAlbum != null) {
      setState(() {
        _selectedAlbum = null;
        _subSearchQuery = '';
        _subSearchController.clear();
      });
      return true;
    }
    if (_selectedPlaylist != null) {
      setState(() {
        _selectedPlaylist = null;
        _subSearchQuery = '';
        _subSearchController.clear();
      });
      return true;
    }
    if (_searchQuery.isNotEmpty) {
      setState(() {
        _searchQuery = '';
        _searchController.clear();
      });
      return true;
    }
    if (_view != LibraryView.allSongs) {
      setState(() => _view = LibraryView.allSongs);
      return true;
    }
    return false;
  }

  bool get canGoBack =>
      _selecting ||
      _subSearchQuery.isNotEmpty ||
      _selectedArtist != null ||
      _selectedAlbum != null ||
      _selectedPlaylist != null ||
      _searchQuery.isNotEmpty ||
      _view != LibraryView.allSongs;

  List<Track> _getSavedTracks() {
    final map = <String, Track>{};
    for (final t in widget.app.libraryTracks) {
      map[t.id] = t;
    }
    for (final t in widget.app.queue) {
      // Only while the file still exists (a song deleted from the phone is gone).
      if (t.status == Status.done && widget.app.isDownloaded(t.id)) {
        map[t.id] = t;
      }
    }
    return map.values.toList();
  }

  /// Extracts all individual artist names for a track.
  /// For multi-author songs (e.g. "Artist A & Artist B", "Artist A feat. Artist B"),
  /// returns each artist so the song appears in both/all artist categories instead
  /// of a single combined "X & Y" category.
  static List<String> extractArtists(Track t) {
    final rawArtist = t.tagArtist.trim().isNotEmpty
        ? t.tagArtist.trim()
        : t.author.replaceAll(RegExp(r'\s*-\s*Topic$', caseSensitive: false), '').trim();

    final result = <String>{};

    void addCandidate(String s) {
      var clean = s.trim();
      // Remove enclosing quotes or brackets
      clean = clean
          .replaceAll(RegExp(r'^[\(\[\{"\x27]+'), '')
          .replaceAll(RegExp(r'[\)\]\}"\x27]+$'), '')
          .replaceAll(RegExp(r'\s*-\s*Topic$', caseSensitive: false), '')
          .trim();
      if (clean.isNotEmpty) {
        result.add(clean);
      }
    }

    void splitAndAdd(String str) {
      if (str.trim().isEmpty) return;
      // Split on common collaboration delimiters:
      // - " feat. ", " ft. ", " featuring ", " with "
      // - " & "
      // - " x ", " X "
      // - " / " (spaced only, to preserve names like AC/DC)
      // - ", ", "; ", "、"
      // - " 与 ", " 與 ", " 和 "
      final parts = str.split(
        RegExp(
          r'(?:\s+(?:feat\.?|ft\.?|featuring|with|and|&|x|X|/|與|与|和)\s+|\s*[,;、]\s*)',
          caseSensitive: false,
        ),
      );
      for (final p in parts) {
        addCandidate(p);
      }
    }

    if (rawArtist.isNotEmpty) {
      splitAndAdd(rawArtist);
    }

    // Also extract featured artists from the title: e.g. "(feat. Artist)", "[ft. Artist]"
    final fullTitle = '${t.title} ${t.tagTitle}';
    final featMatches = RegExp(
      r'[\(\[]\s*(?:feat\.?|ft\.?|featuring|with)\s+([^\)\]]+)[\)\]]',
      caseSensitive: false,
    ).allMatches(fullTitle);

    for (final m in featMatches) {
      final inside = m.group(1);
      if (inside != null && inside.trim().isNotEmpty) {
        splitAndAdd(inside.trim());
      }
    }

    if (result.isEmpty) {
      return ['Unknown Artist'];
    }
    return result.toList();
  }

  /// Groups tracks by individual artist and orders artists by:
  /// 1. Number of songs descending (most songs first)
  /// 2. Alphabetical ascending (case-insensitive) for ties
  static Map<String, List<Track>> groupByArtist(List<Track> tracks) {
    final groups = <String, List<Track>>{};
    for (final t in tracks) {
      final artists = extractArtists(t);
      for (final a in artists) {
        final list = groups.putIfAbsent(a, () => []);
        if (!list.any((existing) => existing.id == t.id)) {
          list.add(t);
        }
      }
    }
    final sortedKeys = groups.keys.toList()
      ..sort((a, b) {
        final countA = groups[a]?.length ?? 0;
        final countB = groups[b]?.length ?? 0;
        if (countA != countB) {
          return countB.compareTo(countA); // Most songs first
        }
        return a.toLowerCase().compareTo(b.toLowerCase()); // Alphabetical
      });
    return {for (final k in sortedKeys) k: groups[k]!};
  }

  Map<String, List<Track>> _groupByArtist(List<Track> tracks) => groupByArtist(tracks);

  Map<String, List<Track>> _groupByAlbum(List<Track> tracks) {
    final groups = <String, List<Track>>{};
    for (final t in tracks) {
      final alb = (t.album != null && t.album!.trim().isNotEmpty)
          ? t.album!.trim()
          : t.tagAlbum;
      groups.putIfAbsent(alb, () => []).add(t);
    }
    return groups;
  }

  void _createNewPlaylist() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('New playlist')),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: tr('Playlist name'),
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (val) => Navigator.pop(ctx, val.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(tr('Create')),
          ),
        ],
      ),
    );

    if (name != null && name.isNotEmpty && mounted) {
      final pl = widget.app.createPlaylist(name);
      HapticFeedback.lightImpact();
      setState(() => _selectedPlaylist = pl);
    }
  }

  void openPlaylist(UserPlaylist pl) {
    setState(() {
      _view = LibraryView.playlists;
      _selectedArtist = null;
      _selectedAlbum = null;
      _selectedPlaylist = pl;
    });
  }

  void _importPlaylistDialog() async {
    final controller = TextEditingController();
    final link = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Import playlist')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('Paste a shared playlist link (wax://playlist?data=...)'),
              style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.nfc_rounded),
              label: Text(tr('Receive via NFC')),
              onPressed: () => Navigator.pop(ctx, _nfcReceiveToken),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'wax://playlist?data=...',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.paste_rounded),
                  tooltip: tr('Paste link'),
                  onPressed: () async {
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
                    if (data?.text != null) controller.text = data!.text!.trim();
                  },
                ),
              ),
              onSubmitted: (val) => Navigator.pop(ctx, val.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(tr('Import')),
          ),
        ],
      ),
    );

    if (link == _nfcReceiveToken && mounted) {
      await _receiveViaNfc();
      return;
    }
    if (link != null && link.isNotEmpty && mounted) _finishImport(link);
  }

  static const _nfcReceiveToken = '\u0000nfc';

  void _finishImport(String link) {
    final pl = PlaylistSharingService.decodePlaylist(link);
    if (pl == null) {
      showAppSnackBar(context, tr('Invalid playlist link or data'));
      return;
    }
    final imported = widget.app.importPlaylist(pl);
    HapticFeedback.lightImpact();
    setState(() {
      _view = LibraryView.playlists;
      _selectedPlaylist = imported;
    });
    showAppSnackBar(
      context,
      trp('Imported "{title}" ({n} songs)', {'title': imported.title, 'n': imported.tracks.length}),
    );
  }

  /// Waits for the other phone (open "Share playlist" there) and imports it.
  Future<void> _receiveViaNfc() async {
    String? got;
    var dialogOpen = false;
    final nav = Navigator.of(context, rootNavigator: true);
    final started = await PlaylistSharingService.startNfcReceive(
      onLink: (l) {
        got = l;
        if (dialogOpen) nav.pop();
      },
      onProblem: (_) {
        if (mounted) showAppSnackBar(context, tr('That NFC tag does not contain a Wax playlist'));
      },
    );
    if (!started) {
      if (mounted) showAppSnackBar(context, tr('NFC is off or unavailable on this device'));
      return;
    }
    if (!mounted) {
      await PlaylistSharingService.stopNfcReceive();
      return;
    }
    if (got != null) {
      await PlaylistSharingService.stopNfcReceive();
      if (mounted) _finishImport(got!);
      return;
    }
    dialogOpen = true;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.nfc_rounded, size: 36, color: accent(context)),
        title: Text(tr('Receive via NFC')),
        content: Text(
          tr('On the other phone open "Share playlist", then hold the backs of the phones together.'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Cancel'))),
        ],
      ),
    );
    dialogOpen = false;
    await PlaylistSharingService.stopNfcReceive();
    if (got != null && mounted) _finishImport(got!);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _subSearchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_selecting) return _buildInner(context);
    return Column(
      children: [
        _buildSelectionBar(),
        Expanded(child: _buildInner(context)),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Selection mode
  // ---------------------------------------------------------------------

  void _startSelection(List<Track> tracks) {
    HapticFeedback.mediumImpact();
    setState(() {
      _selecting = true;
      _selectedIds
        ..clear()
        ..addAll(tracks.map((t) => t.id));
    });
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selectedIds.clear();
    });
  }

  void _toggleTrack(Track t) {
    HapticFeedback.selectionClick();
    setState(() {
      if (!_selectedIds.remove(t.id)) _selectedIds.add(t.id);
      if (_selectedIds.isEmpty) _selecting = false;
    });
  }

  /// true = every song of the group selected, null = some, false = none.
  bool? _groupState(List<Track> tracks) {
    if (tracks.isEmpty) return false;
    final n = tracks.where((t) => _selectedIds.contains(t.id)).length;
    if (n == 0) return false;
    return n == tracks.length ? true : null;
  }

  void _toggleGroup(List<Track> tracks) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_groupState(tracks) == true) {
        _selectedIds.removeAll(tracks.map((t) => t.id));
      } else {
        _selectedIds.addAll(tracks.map((t) => t.id));
      }
      if (_selectedIds.isEmpty) _selecting = false;
    });
  }

  /// The songs "select all" applies to: the open artist/album, else everything.
  List<Track> _scopeTracks(List<Track> all) {
    if (_selectedArtist != null) return _groupByArtist(all)[_selectedArtist] ?? const [];
    if (_selectedAlbum != null) return _groupByAlbum(all)[_selectedAlbum] ?? const [];
    return all;
  }

  List<Track> _selectedTracks() =>
      _getSavedTracks().where((t) => _selectedIds.contains(t.id)).toList();

  /// After edits/deletes an open artist or album may no longer exist.
  void _fixSubpage() {
    final all = _getSavedTracks();
    setState(() {
      if (_selectedArtist != null && !_groupByArtist(all).containsKey(_selectedArtist)) {
        _selectedArtist = null;
      }
      if (_selectedAlbum != null && !_groupByAlbum(all).containsKey(_selectedAlbum)) {
        _selectedAlbum = null;
      }
    });
  }

  Widget _buildSelectionBar() {
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        final scope = _scopeTracks(_getSavedTracks());
        final allSelected = scope.isNotEmpty && scope.every((t) => _selectedIds.contains(t.id));
        return Material(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
            child: Row(
              children: [
                IconButton(
                  tooltip: tr('Cancel'),
                  icon: const Icon(Icons.close_rounded),
                  onPressed: _exitSelection,
                ),
                Expanded(
                  child: Text(
                    trp('{n} selected', {'n': _selectedIds.length}),
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: tr('Select all'),
                  icon: Icon(allSelected ? Icons.deselect_rounded : Icons.select_all_rounded),
                  onPressed: scope.isEmpty
                      ? null
                      : () => setState(() {
                            if (allSelected) {
                              _selectedIds.removeAll(scope.map((t) => t.id));
                            } else {
                              _selectedIds.addAll(scope.map((t) => t.id));
                            }
                            if (_selectedIds.isEmpty) _selecting = false;
                          }),
                ),
                IconButton(
                  tooltip: tr('Edit'),
                  icon: const Icon(Icons.edit_rounded),
                  onPressed: _selectedIds.isEmpty ? null : _editSelected,
                ),
                IconButton(
                  tooltip: tr('Delete'),
                  icon: Icon(Icons.delete_outline_rounded, color: errColor(context)),
                  onPressed: _selectedIds.isEmpty ? null : _deleteSelected,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _editSelected() async {
    final tracks = _selectedTracks();
    if (tracks.isEmpty) return;
    if (tracks.length == 1) {
      await showEditMetadataDialog(context, track: tracks.first, app: widget.app);
      if (!mounted) return;
      _exitSelection();
      _fixSubpage();
      return;
    }
    final r = await showDialog<({int ok, int retagFailed})>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _BulkEditDialog(app: widget.app, tracks: tracks),
    );
    if (!mounted) return;
    _exitSelection();
    _fixSubpage();
    if (r != null && r.ok > 0) {
      showAppSnackBar(
        context,
        r.retagFailed > 0
            ? trp("Saved in the app, but {n} files' tags couldn't be updated", {'n': r.retagFailed})
            : trp('Updated {n} songs', {'n': r.ok}),
      );
    }
  }

  Future<void> _deleteSelected() async {
    final tracks = _selectedTracks();
    if (tracks.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.delete_outline_rounded, size: 36, color: errColor(ctx)),
        title: Text(tracks.length == 1 ? tr('Delete song?') : tr('Delete songs?')),
        content: Text(
          tracks.length == 1
              ? trp('Delete "{title}" from offline storage?', {'title': tracks.first.title})
              : trp('Delete {n} songs from offline storage?', {'n': tracks.length}),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: errColor(ctx)),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Delete')),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    var failed = 0;
    for (final t in tracks) {
      if (!await widget.app.deleteFromLibrary(t)) failed++;
    }
    if (!mounted) return;
    _exitSelection();
    _fixSubpage();
    showAppSnackBar(
      context,
      failed == 0
          ? (tracks.length == 1 ? tr('Song deleted') : trp('Deleted {n} songs', {'n': tracks.length}))
          : trp("Couldn't delete {n} songs. Check storage permission.", {'n': failed}),
      duration: Duration(seconds: failed == 0 ? 2 : 4),
    );
  }

  Widget _buildInner(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        final allTracks = _getSavedTracks();
        final artistGroups = _groupByArtist(allTracks);
        final albumGroups = _groupByAlbum(allTracks);
        final playlists = widget.app.userPlaylists;

        if (_selectedArtist != null) {
          final artistTracks = artistGroups[_selectedArtist] ?? [];
          return _buildSubpageView(
            title: _selectedArtist!,
            subtitle: trp('{n} songs', {'n': artistTracks.length}),
            icon: Icons.person_rounded,
            tracks: artistTracks,
            onBack: () => setState(() => _selectedArtist = null),
          );
        }

        if (_selectedAlbum != null) {
          final albumTracks = albumGroups[_selectedAlbum] ?? [];
          final artist = albumTracks.isNotEmpty ? albumTracks.first.author : '';
          return _buildSubpageView(
            title: _selectedAlbum!,
            subtitle: artist.isNotEmpty
                ? '$artist · ${trp('{n} songs', {'n': albumTracks.length})}'
                : trp('{n} songs', {'n': albumTracks.length}),
            icon: Icons.album_rounded,
            tracks: albumTracks,
            onBack: () => setState(() => _selectedAlbum = null),
          );
        }

        if (_selectedPlaylist != null) {
          return _buildPlaylistDetailView(_selectedPlaylist!);
        }

        return Column(
          children: [
            // Library Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Text(
                    tr('Library'),
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: tr('Scan local storage'),
                    icon: widget.app.scanningLocalStorage
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded, size: 22),
                    onPressed: widget.app.scanningLocalStorage
                        ? null
                        : () async {
                            HapticFeedback.lightImpact();
                            final count = await widget.app.scanLocalStorage(force: true);
                            if (!mounted) return;
                            showAppSnackBar(
                              this.context,
                              count > 0
                                  ? trp('Found {k} new songs in local storage', {'k': '$count'})
                                  : tr('Local storage is up to date'),
                            );
                          },
                  ),
                  if (_view == LibraryView.playlists) ...[
                    const SizedBox(width: 4),
                    IconButton.outlined(
                      tooltip: tr('Import playlist'),
                      icon: const Icon(Icons.file_download_outlined, size: 20),
                      onPressed: _importPlaylistDialog,
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: Text(tr('New playlist')),
                      onPressed: _createNewPlaylist,
                    ),
                  ],
                ],
              ),
            ),

            // Spotify UX 2x2 Grid:
            // [ All Songs ]  |  [ Artists ]
            // [ Albums ]     |  [ Playlists ]
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Builder(
                builder: (context) {
                  final q = _searchQuery.toLowerCase().trim();
                  final songsCount = q.isEmpty
                      ? allTracks.length
                      : allTracks.where((t) =>
                          t.title.toLowerCase().contains(q) ||
                          t.author.toLowerCase().contains(q) ||
                          (t.album?.toLowerCase().contains(q) ?? false) ||
                          t.tagTitle.toLowerCase().contains(q) ||
                          t.tagArtist.toLowerCase().contains(q) ||
                          t.tagAlbum.toLowerCase().contains(q)).length;

                  final artistsCount = q.isEmpty
                      ? artistGroups.length
                      : artistGroups.keys.where((artist) {
                          if (artist.toLowerCase().contains(q)) return true;
                          final tracks = artistGroups[artist] ?? [];
                          return tracks.any((t) =>
                              t.title.toLowerCase().contains(q) ||
                              t.tagTitle.toLowerCase().contains(q) ||
                              (t.album?.toLowerCase().contains(q) ?? false));
                        }).length;

                  final albumsCount = q.isEmpty
                      ? albumGroups.length
                      : albumGroups.keys.where((album) {
                          if (album.toLowerCase().contains(q)) return true;
                          final tracks = albumGroups[album] ?? [];
                          final artist = tracks.isNotEmpty ? tracks.first.author : '';
                          if (artist.toLowerCase().contains(q)) return true;
                          return tracks.any((t) =>
                              t.title.toLowerCase().contains(q) ||
                              t.tagTitle.toLowerCase().contains(q));
                        }).length;

                  final playlistsCount = q.isEmpty
                      ? playlists.length
                      : playlists.where((pl) {
                          if (pl.title.toLowerCase().contains(q)) return true;
                          return pl.tracks.any((t) =>
                              t.title.toLowerCase().contains(q) ||
                              t.author.toLowerCase().contains(q) ||
                              (t.album?.toLowerCase().contains(q) ?? false));
                        }).length;

                  return Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _buildGridButton(
                              title: tr('All songs'),
                              count: trp('{n} songs', {'n': songsCount}),
                              icon: Icons.music_note_rounded,
                              selected: _view == LibraryView.allSongs,
                              onTap: () => setState(() => _view = LibraryView.allSongs),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _buildGridButton(
                              title: tr('Artists'),
                              count: trp('{n} artists', {'n': artistsCount}),
                              icon: Icons.person_rounded,
                              selected: _view == LibraryView.artists,
                              onTap: () => setState(() => _view = LibraryView.artists),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: _buildGridButton(
                              title: tr('Albums'),
                              count: trp('{n} albums', {'n': albumsCount}),
                              icon: Icons.album_rounded,
                              selected: _view == LibraryView.albums,
                              onTap: () => setState(() => _view = LibraryView.albums),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _buildGridButton(
                              title: tr('Playlists'),
                              count: trp('{n} playlists', {'n': playlistsCount}),
                              icon: Icons.queue_music_rounded,
                              selected: _view == LibraryView.playlists,
                              onTap: () => setState(() => _view = LibraryView.playlists),
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 6),
            const Divider(height: 1),

            // Section Content
            Expanded(
              child: switch (_view) {
                LibraryView.allSongs => _buildAllSongsView(allTracks),
                LibraryView.artists => _buildArtistsView(artistGroups),
                LibraryView.albums => _buildAlbumsView(albumGroups),
                LibraryView.playlists => _buildPlaylistsView(playlists),
              },
            ),
          ],
        );
      },
    );
  }

  Widget _buildGridButton({
    required String title,
    required String count,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return Material(
      color: selected
          ? primary.withValues(alpha: 0.15)
          : theme.colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? primary : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: selected ? primary : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontWeight: selected ? FontWeight.bold : FontWeight.w600,
                    fontSize: 14,
                    color: selected ? primary : null,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                count,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBar({
    required String hintText,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              onChanged: (val) => setState(() => _searchQuery = val),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                hintText: hintText,
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 16),
                        tooltip: tr('Clear'),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                filled: true,
                fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing,
          ],
        ],
      ),
    );
  }

  Widget _buildAllSongsView(List<Track> allTracks) {
    if (allTracks.isEmpty) {
      return _buildEmptyState(
        icon: Icons.music_note_rounded,
        title: tr('No saved songs yet'),
        subtitle: tr('Songs downloaded or found on your device will appear here.'),
        action: FilledButton.icon(
          icon: widget.app.scanningLocalStorage
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.folder_open_rounded),
          label: Text(tr('Scan local storage')),
          onPressed: widget.app.scanningLocalStorage
              ? null
              : () async {
                  HapticFeedback.lightImpact();
                  final count = await widget.app.scanLocalStorage(force: true);
                  if (!mounted) return;
                  showAppSnackBar(
                    context,
                    count > 0
                        ? trp('Found {k} new songs in local storage', {'k': '$count'})
                        : tr('No audio files found in local storage'),
                  );
                },
        ),
      );
    }

    final query = _searchQuery.toLowerCase().trim();
    final filtered = query.isEmpty
        ? allTracks
        : allTracks.where((t) {
            return t.title.toLowerCase().contains(query) ||
                t.author.toLowerCase().contains(query) ||
                (t.album?.toLowerCase().contains(query) ?? false) ||
                t.tagTitle.toLowerCase().contains(query) ||
                t.tagArtist.toLowerCase().contains(query) ||
                t.tagAlbum.toLowerCase().contains(query);
          }).toList();

    return Column(
      children: [
        _buildSearchBar(
          hintText: tr('Search in library…'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton.filledTonal(
                tooltip: tr('Play all'),
                icon: const Icon(Icons.play_arrow_rounded, size: 22),
                onPressed: filtered.isEmpty
                    ? null
                    : () {
                        HapticFeedback.lightImpact();
                        widget.app.preview.playList(filtered);
                      },
              ),
              const SizedBox(width: 8),
              IconButton.outlined(
                tooltip: tr('Shuffle'),
                icon: const Icon(Icons.shuffle_rounded, size: 20),
                onPressed: filtered.isEmpty
                    ? null
                    : () {
                        HapticFeedback.lightImpact();
                        widget.app.preview.playList(filtered, startShuffled: true);
                      },
              ),
            ],
          ),
        ),

        // Songs List with Pull-to-refresh
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    tr('No matching songs found'),
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () => widget.app.scanLocalStorage(force: true),
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: filtered.length,
                    itemBuilder: (context, i) {
                      final t = filtered[i];
                      return _buildSongTile(t, filtered);
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildArtistsView(Map<String, List<Track>> artistGroups) {
    if (artistGroups.isEmpty) {
      return _buildEmptyState(
        icon: Icons.person_rounded,
        title: tr('No artists yet'),
        subtitle: tr('Artists will appear here when you save their songs offline.'),
      );
    }

    final query = _searchQuery.toLowerCase().trim();
    final allArtists = artistGroups.keys.toList()
      ..sort((a, b) {
        final countA = artistGroups[a]?.length ?? 0;
        final countB = artistGroups[b]?.length ?? 0;
        if (countA != countB) {
          return countB.compareTo(countA); // Number of songs descending
        }
        return a.toLowerCase().compareTo(b.toLowerCase()); // Then alphabetically
      });

    final artists = query.isEmpty
        ? allArtists
        : allArtists.where((artist) {
            if (artist.toLowerCase().contains(query)) return true;
            final tracks = artistGroups[artist] ?? [];
            return tracks.any((t) =>
                t.title.toLowerCase().contains(query) ||
                t.tagTitle.toLowerCase().contains(query) ||
                (t.album?.toLowerCase().contains(query) ?? false));
          }).toList();

    return Column(
      children: [
        _buildSearchBar(
          hintText: tr('Search artists…'),
        ),
        Expanded(
          child: artists.isEmpty
              ? Center(
                  child: Text(
                    tr('No matching artists found'),
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  itemCount: artists.length,
                  itemBuilder: (context, i) {
                    final artist = artists[i];
                    final tracks = artistGroups[artist] ?? [];
                    final thumb = tracks.isNotEmpty
                        ? widget.app.getCoverArt(tracks.first)
                        : null;

                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(vertical: 4),
                      leading: TrackImage(
                        thumb: thumb,
                        width: 52,
                        height: 52,
                        shape: BoxShape.circle,
                        placeholderIcon: Icons.person,
                        iconSize: 26,
                      ),
                      title: Text(
                        artist,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        trp('{n} songs', {'n': tracks.length}),
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      selected: _selecting && _groupState(tracks) != false,
                      selectedTileColor: accent(context).withValues(alpha: 0.12),
                      trailing: _selecting
                          ? Checkbox(
                              tristate: true,
                              value: _groupState(tracks),
                              onChanged: (_) => _toggleGroup(tracks),
                            )
                          : const Icon(Icons.chevron_right_rounded),
                      onLongPress: _selecting ? () => _toggleGroup(tracks) : () => _startSelection(tracks),
                      onTap: _selecting
                          ? () => _toggleGroup(tracks)
                          : () {
                              HapticFeedback.selectionClick();
                              setState(() => _selectedArtist = artist);
                            },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildAlbumsView(Map<String, List<Track>> albumGroups) {
    if (albumGroups.isEmpty) {
      return _buildEmptyState(
        icon: Icons.album_rounded,
        title: tr('No albums yet'),
        subtitle: tr('Albums will appear here when you download music.'),
      );
    }

    final query = _searchQuery.toLowerCase().trim();
    final allAlbums = albumGroups.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    final albums = query.isEmpty
        ? allAlbums
        : allAlbums.where((album) {
            if (album.toLowerCase().contains(query)) return true;
            final tracks = albumGroups[album] ?? [];
            final artist = tracks.isNotEmpty ? tracks.first.author : '';
            if (artist.toLowerCase().contains(query)) return true;
            return tracks.any((t) =>
                t.title.toLowerCase().contains(query) ||
                t.tagTitle.toLowerCase().contains(query));
          }).toList();

    return Column(
      children: [
        _buildSearchBar(
          hintText: tr('Search albums…'),
        ),
        Expanded(
          child: albums.isEmpty
              ? Center(
                  child: Text(
                    tr('No matching albums found'),
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 14,
                    mainAxisSpacing: 14,
                    childAspectRatio: 0.76,
                  ),
                  itemCount: albums.length,
                  itemBuilder: (context, i) {
                    final album = albums[i];
                    final tracks = albumGroups[album] ?? [];
                    final thumb = tracks.isNotEmpty
                        ? widget.app.getCoverArt(tracks.first)
                        : null;
                    final artist = tracks.isNotEmpty ? tracks.first.author : '';

                    return Material(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(12),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onLongPress: _selecting ? () => _toggleGroup(tracks) : () => _startSelection(tracks),
                        onTap: _selecting
                            ? () => _toggleGroup(tracks)
                            : () {
                                HapticFeedback.selectionClick();
                                setState(() => _selectedAlbum = album);
                              },
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: SizedBox(
                                width: double.infinity,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    TrackImage(
                                      thumb: thumb,
                                      width: double.infinity,
                                      fit: BoxFit.cover,
                                      placeholderIcon: Icons.album_rounded,
                                      iconSize: 40,
                                    ),
                                    if (_selecting && _groupState(tracks) != false)
                                      Container(color: accent(context).withValues(alpha: 0.35)),
                                    if (_selecting)
                                      Positioned(
                                        top: 6,
                                        right: 6,
                                        child: Icon(
                                          _groupState(tracks) == true
                                              ? Icons.check_circle_rounded
                                              : (_groupState(tracks) == null
                                                  ? Icons.remove_circle_rounded
                                                  : Icons.radio_button_unchecked_rounded),
                                          color: Colors.white,
                                          size: 26,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    album,
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    artist.replaceAll(RegExp(r'\s*-\s*Topic$', caseSensitive: false), ''),
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    trp('{n} songs', {'n': tracks.length}),
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Theme.of(context).colorScheme.primary,
                                    ),
                                  ),
                                ],
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
    );
  }

  Widget _buildPlaylistsView(List<UserPlaylist> playlists) {
    if (playlists.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildEmptyState(
              icon: Icons.queue_music_rounded,
              title: tr('No playlists created'),
              subtitle: tr('Tap "New playlist" above to create or import a playlist!'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.file_download_outlined, size: 18),
              label: Text(tr('Import playlist')),
              onPressed: _importPlaylistDialog,
            ),
          ],
        ),
      );
    }

    final query = _searchQuery.toLowerCase().trim();
    final filtered = query.isEmpty
        ? playlists
        : playlists.where((pl) {
            if (pl.title.toLowerCase().contains(query)) return true;
            return pl.tracks.any((t) =>
                t.title.toLowerCase().contains(query) ||
                t.author.toLowerCase().contains(query) ||
                (t.album?.toLowerCase().contains(query) ?? false));
          }).toList();

    return Column(
      children: [
        _buildSearchBar(
          hintText: tr('Search playlists…'),
        ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    tr('No matching playlists found'),
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  itemCount: filtered.length,
                  itemBuilder: (context, i) {
                    final pl = filtered[i];
                    final firstTrack = pl.tracks.isNotEmpty ? pl.tracks.first : null;
                    final thumb = firstTrack != null
                        ? widget.app.getCoverArt(firstTrack)
                        : null;

                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(vertical: 4),
                      leading: TrackImage(
                        thumb: thumb,
                        width: 52,
                        height: 52,
                        borderRadius: BorderRadius.circular(8),
                        placeholderIcon: pl.id == 'favorites' ? Icons.favorite_rounded : Icons.queue_music_rounded,
                      ),
                      title: Text(
                        pl.title,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        trp('{n} songs', {'n': pl.tracks.length}),
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.more_vert, size: 20),
                            tooltip: tr('More'),
                            onPressed: () => _showPlaylistMenu(pl),
                          ),
                          const Icon(Icons.chevron_right_rounded),
                        ],
                      ),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _selectedPlaylist = pl);
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _showPlaylistMenu(UserPlaylist pl) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.qr_code_2_rounded),
              title: Text(tr('Share playlist')),
              subtitle: Text(tr('Share via QR code or NFC tap')),
              onTap: () {
                Navigator.pop(ctx);
                SharePlaylistSheet.show(context, pl);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: Text(tr('Rename playlist')),
              onTap: () async {
                Navigator.pop(ctx);
                final controller = TextEditingController(text: pl.title);
                final newName = await showDialog<String>(
                  context: context,
                  builder: (dCtx) => AlertDialog(
                    title: Text(tr('Rename playlist')),
                    content: TextField(
                      controller: controller,
                      autofocus: true,
                      decoration: const InputDecoration(border: OutlineInputBorder()),
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(dCtx), child: Text(tr('Cancel'))),
                      FilledButton(
                        onPressed: () => Navigator.pop(dCtx, controller.text.trim()),
                        child: Text(tr('Save')),
                      ),
                    ],
                  ),
                );
                if (newName != null && newName.isNotEmpty) {
                  widget.app.renamePlaylist(pl.id, newName);
                  setState(() {});
                }
              },
            ),
            if (pl.id != 'favorites')
              ListTile(
                leading: Icon(Icons.delete_outline, color: errColor(context)),
                title: Text(tr('Delete playlist'), style: TextStyle(color: errColor(context))),
                onTap: () async {
                  Navigator.pop(ctx);
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (dialogCtx) => AlertDialog(
                      icon: Icon(Icons.delete_outline_rounded, size: 36, color: errColor(context)),
                      title: Text(tr('Delete playlist?')),
                      content: Text(trp('Delete "{title}"? This cannot be undone.', {'title': pl.title})),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogCtx, false),
                          child: Text(tr('Cancel')),
                        ),
                        FilledButton(
                          style: FilledButton.styleFrom(backgroundColor: errColor(context)),
                          onPressed: () => Navigator.pop(dialogCtx, true),
                          child: Text(tr('Delete')),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true) {
                    widget.app.deletePlaylist(pl.id);
                    setState(() {
                      if (_selectedPlaylist?.id == pl.id) _selectedPlaylist = null;
                    });
                    if (mounted) {
                      showAppSnackBar(context, tr('Playlist deleted'));
                    }
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubpageView({
    required String title,
    required String subtitle,
    required IconData icon,
    required List<Track> tracks,
    required VoidCallback onBack,
  }) {
    final query = _subSearchQuery.toLowerCase().trim();
    final filtered = query.isEmpty
        ? tracks
        : tracks.where((t) {
            return t.title.toLowerCase().contains(query) ||
                t.author.toLowerCase().contains(query) ||
                (t.album?.toLowerCase().contains(query) ?? false) ||
                t.tagTitle.toLowerCase().contains(query) ||
                t.tagArtist.toLowerCase().contains(query);
          }).toList();

    return Column(
      children: [
        // Subpage Header
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 16, 4),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                tooltip: tr('Back'),
                onPressed: () {
                  _subSearchQuery = '';
                  _subSearchController.clear();
                  onBack();
                },
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton.filledTonal(
                tooltip: tr('Play all'),
                icon: const Icon(Icons.play_arrow_rounded, size: 22),
                onPressed: filtered.isEmpty
                    ? null
                    : () {
                        HapticFeedback.lightImpact();
                        widget.app.preview.playList(filtered);
                      },
              ),
              const SizedBox(width: 6),
              IconButton.outlined(
                tooltip: tr('Shuffle'),
                icon: const Icon(Icons.shuffle_rounded, size: 20),
                onPressed: filtered.isEmpty
                    ? null
                    : () {
                        HapticFeedback.lightImpact();
                        widget.app.preview.playList(filtered, startShuffled: true);
                      },
              ),
            ],
          ),
        ),
        if (tracks.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _subSearchController,
              onChanged: (val) => setState(() => _subSearchQuery = val),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                hintText: tr('Search in this list…'),
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _subSearchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 16),
                        tooltip: tr('Clear'),
                        onPressed: () {
                          _subSearchController.clear();
                          setState(() => _subSearchQuery = '');
                        },
                      )
                    : null,
                filled: true,
                fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: tracks.isEmpty
              ? _buildEmptyState(
                  icon: icon,
                  title: tr('No songs found'),
                  subtitle: '',
                )
              : filtered.isEmpty
                  ? Center(
                      child: Text(
                        tr('No matching songs found'),
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: filtered.length,
                      itemBuilder: (context, i) => _buildSongTile(filtered[i], filtered),
                    ),
        ),
      ],
    );
  }

  Widget _buildPlaylistDetailView(UserPlaylist pl) {
    final query = _subSearchQuery.toLowerCase().trim();
    final filtered = query.isEmpty
        ? pl.tracks
        : pl.tracks.where((t) {
            return t.title.toLowerCase().contains(query) ||
                t.author.toLowerCase().contains(query) ||
                (t.album?.toLowerCase().contains(query) ?? false) ||
                t.tagTitle.toLowerCase().contains(query) ||
                t.tagArtist.toLowerCase().contains(query);
          }).toList();

    return Column(
      children: [
        // Playlist detail header
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 16, 4),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                tooltip: tr('Back'),
                onPressed: () {
                  setState(() {
                    _selectedPlaylist = null;
                    _subSearchQuery = '';
                    _subSearchController.clear();
                  });
                },
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pl.title,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      trp('{n} songs', {'n': pl.tracks.length}),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton.filledTonal(
                tooltip: tr('Play all'),
                icon: const Icon(Icons.play_arrow_rounded, size: 22),
                onPressed: filtered.isEmpty
                    ? null
                    : () {
                        HapticFeedback.lightImpact();
                        widget.app.preview.playList(filtered);
                      },
              ),
              const SizedBox(width: 6),
              IconButton.outlined(
                tooltip: tr('Share playlist'),
                icon: const Icon(Icons.qr_code_2_rounded, size: 20),
                onPressed: () => SharePlaylistSheet.show(context, pl),
              ),
              const SizedBox(width: 6),
              IconButton.outlined(
                tooltip: tr('Shuffle'),
                icon: const Icon(Icons.shuffle_rounded, size: 20),
                onPressed: filtered.isEmpty
                    ? null
                    : () {
                        HapticFeedback.lightImpact();
                        widget.app.preview.playList(filtered, startShuffled: true);
                      },
              ),
            ],
          ),
        ),
        if (pl.tracks.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _subSearchController,
              onChanged: (val) => setState(() => _subSearchQuery = val),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                hintText: tr('Search in playlist…'),
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _subSearchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 16),
                        tooltip: tr('Clear'),
                        onPressed: () {
                          _subSearchController.clear();
                          setState(() => _subSearchQuery = '');
                        },
                      )
                    : null,
                filled: true,
                fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        const Divider(height: 1),

        Expanded(
          child: pl.tracks.isEmpty
              ? _buildEmptyState(
                  icon: Icons.queue_music_rounded,
                  title: tr('This playlist is empty'),
                  subtitle: tr('Add songs by tapping "Save to playlist" on any track!'),
                )
              : filtered.isEmpty
                  ? Center(
                      child: Text(
                        tr('No matching songs in playlist'),
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    )
                  : query.isNotEmpty
                      ? ListView.builder(
                          padding: const EdgeInsets.only(bottom: 24),
                          itemCount: filtered.length,
                          itemBuilder: (context, i) {
                            final t = filtered[i];
                            final isPlaying = widget.app.preview.playingId == t.id && widget.app.preview.isPlaying;

                            return ListTile(
                              key: ValueKey('pl_${pl.id}_${t.id}_$i'),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                              leading: TrackImage(
                                thumb: widget.app.getCoverArt(t),
                                width: 44,
                                height: 44,
                                borderRadius: BorderRadius.circular(6),
                                placeholderIcon: Icons.music_note,
                                iconSize: 22,
                              ),
                              title: Text(
                                t.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: isPlaying ? FontWeight.bold : FontWeight.w600,
                                  fontSize: 14,
                                  color: isPlaying ? accent(context) : null,
                                ),
                              ),
                              subtitle: Text(
                                t.author.replaceAll(RegExp(r'\s*-\s*Topic$', caseSensitive: false), ''),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.remove_circle_outline, size: 20),
                                    tooltip: tr('Remove from playlist'),
                                    onPressed: () {
                                      widget.app.removeTrackFromPlaylist(pl.id, t.id);
                                      setState(() {});
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.more_vert, size: 20),
                                    tooltip: tr('More'),
                                    onPressed: () => TrackActionsSheet.show(context, track: t, app: widget.app),
                                  ),
                                ],
                              ),
                              onLongPress: () => TrackActionsSheet.show(context, track: t, app: widget.app),
                              onTap: () {
                                widget.app.preview.playTrack(t, contextTracks: filtered);
                              },
                            );
                          },
                        )
                      : ReorderableListView.builder(
                          padding: const EdgeInsets.only(bottom: 24),
                          itemCount: pl.tracks.length,
                          // ignore: deprecated_member_use
                          onReorder: (oldIdx, newIdx) {
                            HapticFeedback.lightImpact();
                            widget.app.reorderTrackInPlaylist(pl.id, oldIdx, newIdx);
                            setState(() {});
                          },
                          itemBuilder: (context, i) {
                            final t = pl.tracks[i];
                            final isPlaying = widget.app.preview.playingId == t.id && widget.app.preview.isPlaying;

                            return ListTile(
                              key: ValueKey('pl_${pl.id}_${t.id}_$i'),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                              leading: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ReorderableDragStartListener(
                                    index: i,
                                    child: Icon(
                                      Icons.drag_handle_rounded,
                                      size: 20,
                                      color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  TrackImage(
                                    thumb: widget.app.getCoverArt(t),
                                    width: 44,
                                    height: 44,
                                    borderRadius: BorderRadius.circular(6),
                                    placeholderIcon: Icons.music_note,
                                    iconSize: 22,
                                  ),
                                ],
                              ),
                              title: Text(
                                t.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: isPlaying ? FontWeight.bold : FontWeight.w600,
                                  fontSize: 14,
                                  color: isPlaying ? accent(context) : null,
                                ),
                              ),
                              subtitle: Text(
                                t.author.replaceAll(RegExp(r'\s*-\s*Topic$', caseSensitive: false), ''),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.remove_circle_outline, size: 20),
                                    tooltip: tr('Remove from playlist'),
                                    onPressed: () {
                                      widget.app.removeTrackFromPlaylist(pl.id, t.id);
                                      setState(() {});
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.more_vert, size: 20),
                                    tooltip: tr('More'),
                                    onPressed: () => TrackActionsSheet.show(context, track: t, app: widget.app),
                                  ),
                                ],
                              ),
                              onLongPress: () => TrackActionsSheet.show(context, track: t, app: widget.app),
                              onTap: () {
                                widget.app.preview.playTrack(t, contextTracks: pl.tracks);
                              },
                            );
                          },
                        ),
        ),
      ],
    );
  }

  Widget _buildSongTile(Track t, List<Track> contextTracks) {
    final isPlaying = widget.app.preview.playingId == t.id && widget.app.preview.isPlaying;
    final isLoading = widget.app.preview.loadingId == t.id;

    final picked = _selectedIds.contains(t.id);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      selected: _selecting && picked,
      selectedTileColor: accent(context).withValues(alpha: 0.12),
      onTap: _selecting
          ? () => _toggleTrack(t)
          : () {
              HapticFeedback.lightImpact();
              widget.app.preview.toggle(t, contextTracks: contextTracks);
            },
      onLongPress: _selecting ? () => _toggleTrack(t) : () => _startSelection([t]),
      leading: Semantics(
        button: true,
        label: isPlaying ? '${tr('Pause')} ${t.title}' : '${tr('Play')} ${t.title}',
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            alignment: Alignment.center,
            children: [
              TrackImage(
                thumb: widget.app.getCoverArt(t),
                width: 50,
                height: 50,
                borderRadius: BorderRadius.circular(8),
              ),
              Container(
                width: 50,
                height: 50,
                color: isPlaying ? Colors.black54 : Colors.transparent,
              ),
              if (isLoading)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              else if (isPlaying)
                Icon(Icons.pause_rounded, color: accent(context), size: 28),
            ],
          ),
        ),
      ),
      title: Text(
        t.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: isPlaying ? FontWeight.bold : FontWeight.w600,
          fontSize: 14.5,
          color: isPlaying ? accent(context) : null,
        ),
      ),
      subtitle: Text(
        '${t.author.replaceAll(RegExp(r'\s*-\s*Topic$', caseSensitive: false), '')} · ${t.durText}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: _selecting
          ? Checkbox(value: picked, onChanged: (_) => _toggleTrack(t))
          : IconButton(
              tooltip: tr('More'),
              icon: const Icon(Icons.more_vert, size: 20),
              onPressed: () => TrackActionsSheet.show(context, track: t, app: widget.app),
            ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
    Widget? action,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
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
              child: Icon(icon, size: 36, color: Theme.of(context).colorScheme.primary),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: 20),
              action,
            ] else if (widget.onOpenSearch != null) ...[
              const SizedBox(height: 20),
              FilledButton.icon(
                icon: const Icon(Icons.search),
                label: Text(tr('Explore Music')),
                onPressed: widget.onOpenSearch,
              ),
            ],
          ],
        ),
      ),
    );
  }
}


/// Edit artist and/or album of several songs at once. A blank field keeps each
/// song's current value.
class _BulkEditDialog extends StatefulWidget {
  final AppState app;
  final List<Track> tracks;
  const _BulkEditDialog({required this.app, required this.tracks});

  @override
  State<_BulkEditDialog> createState() => _BulkEditDialogState();
}

class _BulkEditDialogState extends State<_BulkEditDialog> {
  final _artistCtrl = TextEditingController();
  final _albumCtrl = TextEditingController();
  bool _saving = false;
  int _done = 0;

  @override
  void dispose() {
    _artistCtrl.dispose();
    _albumCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final artist = _artistCtrl.text.trim();
    final album = _albumCtrl.text.trim();
    if (artist.isEmpty && album.isEmpty) {
      Navigator.pop(context);
      return;
    }
    setState(() => _saving = true);
    var ok = 0, retagFailed = 0;
    for (final t in widget.tracks) {
      try {
        final r = await widget.app.updateTrackMetadata(
          t,
          newTitle: t.tagTitle.isNotEmpty ? t.tagTitle : t.title,
          newArtist: artist.isNotEmpty ? artist : (t.tagArtist.isNotEmpty ? t.tagArtist : t.author),
          newAlbum: album.isNotEmpty
              ? album
              : (t.album ?? (t.tagAlbum != t.tagTitle ? t.tagAlbum : null)),
        );
        ok++;
        if (r.retagFailed) retagFailed++;
      } catch (_) {}
      if (mounted) setState(() => _done++);
    }
    if (mounted) Navigator.pop(context, (ok: ok, retagFailed: retagFailed));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: Icon(Icons.edit_note_rounded, size: 36, color: accent(context)),
      title: Text(trp('Edit {n} songs', {'n': widget.tracks.length})),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tr("Leave a field empty to keep each song's current value."),
              style: TextStyle(
                fontSize: 12.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _artistCtrl,
              enabled: !_saving,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: tr('Artist'),
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.person_rounded),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _albumCtrl,
              enabled: !_saving,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: tr('Album'),
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.album_rounded),
              ),
            ),
            if (_saving) ...[
              const SizedBox(height: 14),
              LinearProgressIndicator(value: _done / widget.tracks.length),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(tr('Cancel')),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(tr('Save')),
        ),
      ],
    );
  }
}
