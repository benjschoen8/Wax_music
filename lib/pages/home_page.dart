import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants.dart';
import '../models/music_category.dart';
import '../models/track.dart';
import '../state.dart';
import '../strings.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/track_actions_sheet.dart';
import '../widgets/track_image.dart';

class HomePage extends StatefulWidget {
  final AppState app;
  final Function(String query) onSearchQuery;

  const HomePage({
    super.key,
    required this.app,
    required this.onSearchQuery,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // Curated popular featured tracks for quick discovery & instant playback (official YTM audio tracks)
  static final List<Track> _featuredHits = [
    Track(
      '5qZQEq_C3vc',
      'Numb',
      'Linkin Park - Topic',
      'https://i.ytimg.com/vi/5qZQEq_C3vc/hqdefault.jpg',
      const Duration(minutes: 3, seconds: 8),
      album: 'Meteora',
    ),
    Track(
      'BSTsnWoslP4',
      'Bohemian Rhapsody',
      'Queen - Topic',
      'https://i.ytimg.com/vi/BSTsnWoslP4/hqdefault.jpg',
      const Duration(minutes: 5, seconds: 55),
      album: 'A Night At The Opera',
    ),
    Track(
      'xTvyyoF_LZY',
      'Shape of You',
      'Ed Sheeran - Topic',
      'https://i.ytimg.com/vi/xTvyyoF_LZY/hqdefault.jpg',
      const Duration(minutes: 3, seconds: 54),
      album: 'Shape of You',
    ),
    Track(
      'wSOc5jmvF-k',
      'Sugar',
      'Maroon 5 - Topic',
      'https://i.ytimg.com/vi/wSOc5jmvF-k/hqdefault.jpg',
      const Duration(minutes: 3, seconds: 56),
      album: 'V',
    ),
    Track(
      'ORrFJ63nlcA',
      'Perfect',
      'Ed Sheeran - Topic',
      'https://i.ytimg.com/vi/ORrFJ63nlcA/hqdefault.jpg',
      const Duration(minutes: 4, seconds: 24),
      album: '÷ (Divide)',
    ),
    Track(
      'sWMk8dwljFU',
      'Shake It Off',
      'Taylor Swift - Topic',
      'https://i.ytimg.com/vi/sWMk8dwljFU/hqdefault.jpg',
      const Duration(minutes: 3, seconds: 40),
      album: '1989',
    ),
  ];

  Widget _buildCategoryCard(MusicCategory cat) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          HapticFeedback.lightImpact();
          widget.onSearchQuery(cat.query);
        },
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              colors: [
                cat.color.withValues(alpha: 0.85),
                cat.color.withValues(alpha: 0.55),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: cat.color.withValues(alpha: 0.25),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(cat.icon, color: Colors.white, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  tr(cat.title),
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
    );
  }

  Widget _buildTrendingTrackItem(Track t) {
    return ListenableBuilder(
      listenable: widget.app.preview,
      builder: (context, _) {
        final isPlaying = widget.app.preview.playingId == t.id && widget.app.preview.isPlaying;
        final isLoading = widget.app.preview.loadingId == t.id;
        final isSaved = widget.app.isSaved(t);
        final isQueued = widget.app.has(t.id);

        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          elevation: 0,
          color: Theme.of(context).colorScheme.surfaceContainerHigh.withValues(alpha: 0.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            leading: Stack(
              alignment: Alignment.center,
              children: [
                TrackImage(
                  thumb: widget.app.getCoverArt(t),
                  width: 48,
                  height: 48,
                  borderRadius: BorderRadius.circular(8),
                ),
                Semantics(
                  label: isPlaying ? tr('Pause') : tr('Play'),
                  button: true,
                  child: Material(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => widget.app.preview.toggle(t, contextTracks: _featuredHits),
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: isLoading
                            ? const Center(
                                child: SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                ),
                              )
                            : Icon(
                                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 28,
                              ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            title: Text(
              t.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: isPlaying ? FontWeight.bold : FontWeight.w600,
                color: isPlaying ? accent(context) : null,
              ),
            ),
            subtitle: Text(
              t.author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: isSaved
                      ? tr('Downloaded')
                      : (isQueued ? tr('Queued') : tr('Download')),
                  icon: Semantics(
                    label: isSaved
                        ? tr('Downloaded')
                        : (isQueued ? tr('Queued') : tr('Download')),
                    child: Icon(
                      isSaved
                          ? Icons.check_circle_rounded
                          : (isQueued ? Icons.hourglass_top_rounded : Icons.download_rounded),
                      color: isSaved
                          ? okColor(context)
                          : (isQueued ? accent(context) : null),
                      size: 22,
                    ),
                  ),
                  onPressed: isSaved
                      ? null
                      : () {
                          HapticFeedback.lightImpact();
                          widget.app.add([t]);
                          widget.app.run(); // Start download immediately!
                          showAppSnackBar(
                            context,
                            trp('Added "{title}" to download queue', {'title': t.title}),
                          );
                        },
                ),
                IconButton(
                  tooltip: tr('More'),
                  icon: const Icon(Icons.more_vert_rounded, size: 20),
                  onPressed: () {
                    TrackActionsSheet.show(context, track: t, app: widget.app);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // App Header
          SliverAppBar(
            floating: true,
            pinned: false,
            elevation: 0,
            scrolledUnderElevation: 1,
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: accent(context).withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.album_rounded, color: accent(context), size: 24),
                ),
                const SizedBox(width: 10),
                const Text(
                  'Wax',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22, letterSpacing: -0.5),
                ),
              ],
            ),
          ),

          // Search shortcut card
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(28),
                child: InkWell(
                  borderRadius: BorderRadius.circular(28),
                  onTap: () => widget.onSearchQuery(''),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        Icon(
                          Icons.search_rounded,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          size: 22,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          tr('Search songs, artists, albums, or paste link…'),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Popular Picks section
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.local_fire_department_rounded, color: Colors.orangeAccent, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    tr('Popular Picks'),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => widget.onSearchQuery('Popular Songs Hits'),
                    child: Text(tr('See all')),
                  ),
                ],
              ),
            ),
          ),

          // Trending tracks list
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _buildTrendingTrackItem(_featuredHits[index]),
              childCount: _featuredHits.length,
            ),
          ),

          // Categories & Genres Header
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
              child: Row(
                children: [
                  Icon(Icons.category_rounded, color: accent(context), size: 20),
                  const SizedBox(width: 8),
                  Text(
                    tr('Explore Categories & Genres'),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ],
              ),
            ),
          ),

          // Unified Categories Grid
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 2.2,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) => _buildCategoryCard(musicCategories[index]),
                childCount: musicCategories.length,
              ),
            ),
          ),

          const SliverToBoxAdapter(
            child: SizedBox(height: 32),
          ),
        ],
      ),
    );
  }
}
