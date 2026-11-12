import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants.dart';
import '../models/track.dart';
import '../state.dart';
import '../strings.dart';
import 'add_to_playlist_sheet.dart';
import 'app_snackbar.dart';
import 'edit_metadata_dialog.dart';
import 'now_playing_sheet.dart';
import 'track_image.dart';
import 'track_navigation.dart';

class TrackActionsSheet extends StatelessWidget {
  final Track track;
  final AppState app;
  final void Function(String browseId, String? name)? onOpenArtist;
  final void Function(String browseId, String? title)? onOpenAlbum;

  const TrackActionsSheet({
    super.key,
    required this.track,
    required this.app,
    this.onOpenArtist,
    this.onOpenAlbum,
  });

  static Future<void> show(
    BuildContext context, {
    required Track track,
    required AppState app,
    void Function(String browseId, String? name)? onOpenArtist,
    void Function(String browseId, String? title)? onOpenAlbum,
  }) {
    final navigation = TrackNavigation.maybeOf(context);
    onOpenArtist ??= navigation == null ? null : (id, name) => navigation.onArtist(
      track.copyWith(artistBrowseId: id, author: name),
    );
    onOpenAlbum ??= navigation == null ? null : (id, title) => navigation.onAlbum(
      track.copyWith(albumBrowseId: id, album: title),
    );
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => TrackActionsSheet(
        track: track,
        app: app,
        onOpenArtist: onOpenArtist,
        onOpenAlbum: onOpenAlbum,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = track;
    final saved = app.isSaved(t);
    final queued = app.has(t.id);
    final addable = !saved && !queued;
    final isLibraryTrack = app.libraryTracks.any((x) => x.id == t.id);
    final canManageOffline = saved || isLibraryTrack;
    final bgColor = sheetBgColor(context);

    return Material(
      color: bgColor,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag Handle
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 12, bottom: 12),
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Track Header Card
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  TrackImage(
                    thumb: app.getCoverArt(t),
                    width: 56,
                    height: 56,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.title,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${t.author.replaceAll(RegExp(r'\s*-\s*Topic$', caseSensitive: false), '')} · ${t.durText}',
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (t.album != null && t.album!.isNotEmpty)
                          Text(
                            t.album!,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // Manage the saved file: visible buttons, right under the header.
            if (canManageOffline)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.edit_note_rounded, size: 20),
                        label: Text(tr('Edit metadata')),
                        onPressed: () {
                          Navigator.pop(context);
                          showEditMetadataDialog(context, track: t, app: app);
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: errColor(context),
                          side: BorderSide(
                            color: errColor(context).withValues(alpha: 0.5),
                          ),
                        ),
                        icon: const Icon(Icons.delete_outline_rounded, size: 20),
                        label: Text(tr('Delete song')),
                        onPressed: () => _confirmDelete(context),
                      ),
                    ),
                  ],
                ),
              ),

            // 1. Play / Pause
            ListTile(
              leading: Icon(
                app.preview.playingId == t.id ? Icons.pause_circle : Icons.play_circle_outline,
                color: accent(context),
              ),
              title: Text(app.preview.playingId == t.id ? tr('Pause') : tr('Play')),
              onTap: () {
                Navigator.pop(context);
                app.preview.toggle(t);
              },
            ),

            // 2. Play Next
            ListTile(
              leading: const Icon(Icons.playlist_play_rounded),
              title: Text(tr('Play next')),
              onTap: () {
                Navigator.pop(context);
                app.preview.playNext(t);
                HapticFeedback.lightImpact();
                showAppSnackBar(context, tr('Playing next'));
              },
            ),

            // 3. Add to Playback Queue
            ListTile(
              leading: const Icon(Icons.queue_music_rounded),
              title: Text(tr('Add to queue')),
              onTap: () {
                Navigator.pop(context);
                app.preview.addToQueue(t);
                HapticFeedback.lightImpact();
                showAppSnackBar(context, tr('Added to playback queue'));
              },
            ),

            // 4. Save to Playlist (YouTube-style)
            ListTile(
              leading: const Icon(Icons.playlist_add_rounded),
              title: Text(tr('Save to playlist')),
              onTap: () {
                Navigator.pop(context);
                AddToPlaylistSheet.show(context, track: t, app: app);
              },
            ),

            // 5. Download / Queue action
            ListTile(
              leading: Icon(
                saved
                    ? Icons.check_circle
                    : queued
                    ? Icons.hourglass_top
                    : Icons.arrow_downward_rounded,
                color: saved ? okColor(context) : null,
              ),
              title: Text(
                saved
                    ? tr('Already downloaded')
                    : queued
                    ? tr('In queue')
                    : tr('Download song'),
              ),
              onTap: addable
                  ? () {
                      Navigator.pop(context);
                      HapticFeedback.lightImpact();
                      app.add([t]);
                      app.run();
                      showAppSnackBar(context, tr('Added to queue'));
                    }
                  : null,
            ),

            // 3. View Lyrics
            ListTile(
              leading: const Icon(Icons.lyrics_outlined),
              title: Text(tr('View synchronized lyrics')),
              onTap: () {
                Navigator.pop(context);
                NowPlayingSheet.show(
                  context,
                  track: t,
                  app: app,
                  onOpenArtist: onOpenArtist,
                  onOpenAlbum: onOpenAlbum,
                  startOnLyrics: true,
                );
              },
            ),

            // 4. View Album (if available)
            if (t.album != null && t.album!.isNotEmpty && onOpenAlbum != null)
              ListTile(
                leading: const Icon(Icons.album_outlined),
                title: Text('${tr('Go to album')}: ${t.album}'),
                onTap: () {
                  Navigator.pop(context);
                  onOpenAlbum!(t.albumBrowseId ?? '', t.album);
                },
              ),

            // 5. View Artist (if available)
            if (onOpenArtist != null)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text('${tr('Go to artist')}: ${t.author.replaceAll(RegExp(r'\s*-\s*Topic$', caseSensitive: false), '')}'),
                onTap: () {
                  Navigator.pop(context);
                  onOpenArtist!(t.artistBrowseId ?? '', t.author);
                },
              ),

            // 6. Copy Link
            ListTile(
              leading: const Icon(Icons.link),
              title: Text(tr('Copy link')),
              onTap: () {
                Navigator.pop(context);
                final url = 'https://youtu.be/${t.id}';
                Clipboard.setData(ClipboardData(text: url));
                showAppSnackBar(context, tr('Link copied to clipboard'));
              },
            ),

            const SizedBox(height: 12),
          ],
        ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final t = track;
    // The sheet's own context dies as soon as it closes, so keep the
    // navigator's context for the dialog and the result message.
    final host = Navigator.of(context).context;
    Navigator.pop(context);
    final confirm = await showDialog<bool>(
      context: host,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.delete_outline_rounded, size: 36, color: errColor(ctx)),
        title: Text(tr('Delete song?')),
        content: Text(
          trp('Delete "{title}" from offline storage?', {'title': t.title}),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: errColor(ctx)),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Delete')),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final ok = await app.deleteFromLibrary(t);
    if (host.mounted) {
      showAppSnackBar(
        host,
        ok
            ? tr('Song deleted')
            : tr("Couldn't delete the file. Check storage permission."),
        duration: Duration(seconds: ok ? 2 : 4),
      );
    }
  }
}
