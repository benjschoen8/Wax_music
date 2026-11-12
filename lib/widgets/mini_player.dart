import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants.dart';
import '../state.dart';
import '../strings.dart';
import 'app_snackbar.dart';
import 'now_playing_sheet.dart';
import 'track_image.dart';

class MiniPlayer extends StatelessWidget {
  final AppState app;
  final void Function(String browseId, String? name)? onOpenArtist;
  final void Function(String browseId, String? title)? onOpenAlbum;

  const MiniPlayer({
    super.key,
    required this.app,
    this.onOpenArtist,
    this.onOpenAlbum,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app.preview,
      builder: (context, _) {
        final track = app.preview.currentTrack;
        final loading = app.preview.loadingId != null;
        final playing = app.preview.playingId != null && app.preview.isPlaying;
        // On narrow phones drop the quick-download shortcut so the 44 dp
        // controls fit and the title keeps room (download stays in the menu).
        final narrow = MediaQuery.sizeOf(context).width < 380;

        if (track == null && !loading && !playing) {
          return const SizedBox.shrink();
        }

        final t = track!;
        final saved = app.isSaved(t);
        final queued = app.has(t.id);
        final addable = !saved && !queued;

        final cardColor = cardBgColor(context);

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Material(
            elevation: 8,
            shadowColor: Colors.black45,
            borderRadius: BorderRadius.circular(14),
            color: cardColor,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () {
                NowPlayingSheet.show(
                  context,
                  track: t,
                  app: app,
                  onOpenArtist: onOpenArtist,
                  onOpenAlbum: onOpenAlbum,
                );
              },
              child: Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 4, 10),
                    child: Row(
                      children: [
                        // Cover Thumbnail
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              TrackImage(
                                thumb: app.getCoverArt(t),
                                width: 44,
                                height: 44,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              if (loading)
                                Container(
                                  width: 44,
                                  height: 44,
                                  color: Colors.black54,
                                  child: const Center(
                                    child: SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),

                        // Title & Artist
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                t.title,
                                style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                t.author.replaceAll(RegExp(r'\s*-\s*Topic$', caseSensitive: false), ''),
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),

                        // Quick Download Button
                        if (!narrow)
                        Semantics(
                          button: addable,
                          label: saved
                              ? tr('Already downloaded')
                              : queued
                              ? tr('In queue')
                              : tr('Download song'),
                          child: IconButton(
                            padding: const EdgeInsets.all(6),
                            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
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
                              size: 20,
                              color: saved
                                  ? okColor(context)
                                  : queued
                                  ? accent(context)
                                  : null,
                            ),
                            onPressed: addable
                                ? () {
                                    HapticFeedback.lightImpact();
                                    app.add([t]);
                                    app.run();
                                    showAppSnackBar(
                                      context,
                                      tr('Added to queue'),
                                    );
                                  }
                                : null,
                          ),
                        ),

                        // Play / Pause Toggle
                        Semantics(
                          button: true,
                          label: playing ? tr('Pause') : tr('Play'),
                          child: IconButton(
                            padding: const EdgeInsets.all(6),
                            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                            tooltip: playing ? tr('Pause') : tr('Play'),
                            icon: Icon(
                              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                              size: 26,
                            ),
                            onPressed: () => app.preview.toggle(t),
                          ),
                        ),

                        // Next Track Button
                        Semantics(
                          button: true,
                          label: tr('Next'),
                          child: IconButton(
                            padding: const EdgeInsets.all(6),
                            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                            tooltip: tr('Next'),
                            icon: const Icon(
                              Icons.skip_next_rounded,
                              size: 24,
                            ),
                            onPressed: () => app.preview.next(),
                          ),
                        ),

                        // Dismiss / Close
                        Semantics(
                          button: true,
                          label: tr('Close'),
                          child: IconButton(
                            padding: const EdgeInsets.all(6),
                            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                            tooltip: tr('Close'),
                            icon: const Icon(Icons.close_rounded, size: 20),
                            onPressed: () => app.preview.stop(),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Linear Audio Progress Bar at bottom edge
                  StreamBuilder<Duration>(
                    stream: app.preview.positionStream,
                    builder: (context, snapshot) {
                      final pos = snapshot.data ?? Duration.zero;
                      final total = app.preview.duration ?? t.duration ?? const Duration(minutes: 3);
                      final progress = total.inMilliseconds > 0
                          ? (pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
                          : 0.0;

                      return Semantics(
                        label: tr('Playback progress'),
                        value: '${(progress * 100).toInt()}%',
                        child: ClipRRect(
                          borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 2.5,
                            backgroundColor: Colors.transparent,
                            valueColor: AlwaysStoppedAnimation<Color>(accent(context)),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
