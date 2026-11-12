import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants.dart';
import '../models/track.dart';
import '../state.dart';
import '../strings.dart';
import 'app_snackbar.dart';

/// YouTube-style "Save to playlist" sheet.
class AddToPlaylistSheet extends StatefulWidget {
  final Track track;
  final AppState app;

  const AddToPlaylistSheet({
    super.key,
    required this.track,
    required this.app,
  });

  static Future<void> show(
    BuildContext context, {
    required Track track,
    required AppState app,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddToPlaylistSheet(track: track, app: app),
    );
  }

  @override
  State<AddToPlaylistSheet> createState() => _AddToPlaylistSheetState();
}

class _AddToPlaylistSheetState extends State<AddToPlaylistSheet> {
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
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(tr('Create')),
          ),
        ],
      ),
    );

    if (name != null && name.isNotEmpty && mounted) {
      final pl = widget.app.createPlaylist(name);
      widget.app.addTrackToPlaylist(pl.id, widget.track);
      HapticFeedback.lightImpact();
      showAppSnackBar(
        context,
        trp('Added to {name}', {'name': pl.title}),
      );
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = sheetBgColor(context);
    final playlists = widget.app.userPlaylists;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.75,
      ),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.playlist_add_rounded, size: 24),
                  const SizedBox(width: 10),
                  Text(
                    tr('Save to playlist'),
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: tr('Close'),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // "+ New Playlist" action tile
            ListTile(
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: accent(context).withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.add_rounded, color: accent(context)),
              ),
              title: Text(
                tr('New playlist'),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: accent(context),
                ),
              ),
              onTap: _createNewPlaylist,
            ),
            const Divider(height: 1),

            // Playlists list with checkboxes
            Expanded(
              child: playlists.isEmpty
                  ? Center(
                      child: Text(
                        tr('No playlists yet. Create one above!'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: playlists.length,
                      itemBuilder: (context, i) {
                        final pl = playlists[i];
                        final inPl = widget.app.isInPlaylist(pl.id, widget.track.id);

                        return CheckboxListTile(
                          value: inPl,
                          activeColor: accent(context),
                          secondary: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(
                              pl.id == 'favorites'
                                  ? Icons.favorite_rounded
                                  : Icons.queue_music_rounded,
                              color: pl.id == 'favorites' ? errColor(context) : null,
                              size: 20,
                            ),
                          ),
                          title: Text(
                            pl.title,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            trp('{n} songs', {'n': pl.tracks.length}),
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          onChanged: (checked) {
                            HapticFeedback.selectionClick();
                            if (checked == true) {
                              widget.app.addTrackToPlaylist(pl.id, widget.track);
                              showAppSnackBar(
                                context,
                                trp('Added to {name}', {'name': pl.title}),
                              );
                            } else {
                              widget.app.removeTrackFromPlaylist(pl.id, widget.track.id);
                              showAppSnackBar(
                                context,
                                trp('Removed from {name}', {'name': pl.title}),
                              );
                            }
                            setState(() {});
                          },
                        );
                      },
                    ),
            ),

            // Bottom Done button
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(tr('Done')),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
