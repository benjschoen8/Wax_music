import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import '../constants.dart';
import '../lyrics.dart';
import '../models/track.dart';
import '../state.dart';
import '../strings.dart';
import '../ytm_search.dart';
import 'add_to_playlist_sheet.dart';
import 'app_snackbar.dart';
import 'track_actions_sheet.dart';
import 'track_image.dart';
import 'track_credits.dart';

class NowPlayingSheet extends StatefulWidget {
  final Track track;
  final AppState app;
  final void Function(String browseId, String? name)? onOpenArtist;
  final void Function(String browseId, String? title)? onOpenAlbum;
  final int initialViewMode; // 0 = Track, 1 = Lyrics, 2 = Queue

  const NowPlayingSheet({
    super.key,
    required this.track,
    required this.app,
    this.onOpenArtist,
    this.onOpenAlbum,
    this.initialViewMode = 0,
  });

  static Future<void> show(
    BuildContext context, {
    required Track track,
    required AppState app,
    void Function(String browseId, String? name)? onOpenArtist,
    void Function(String browseId, String? title)? onOpenAlbum,
    bool startOnLyrics = false,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => NowPlayingSheet(
        track: track,
        app: app,
        onOpenArtist: onOpenArtist,
        onOpenAlbum: onOpenAlbum,
        initialViewMode: startOnLyrics ? 1 : 0,
      ),
    );
  }

  @override
  State<NowPlayingSheet> createState() => _NowPlayingSheetState();
}

class _ParsedLyricLine {
  final Duration time;
  final String text;
  const _ParsedLyricLine(this.time, this.text);
}

class _NowPlayingSheetState extends State<NowPlayingSheet> {
  late Track _currentTrack;
  late int _viewMode;
  bool _loadingLyrics = false;
  LyricsResult? _lyricsResult;
  List<_ParsedLyricLine> _parsedLines = [];
  final ScrollController _lyricsScroll = ScrollController();
  StreamSubscription<Duration>? _posSub;
  Duration _currentPos = Duration.zero;
  int _activeLineIndex = -1;
  bool _userScrolling = false;
  Timer? _userScrollDebounce;
  Timer? _deferredLyricsTimer;

  @override
  void initState() {
    super.initState();
    _currentTrack = widget.app.preview.currentTrack ?? widget.track;
    _viewMode = widget.initialViewMode;
    _loadAlbum(_currentTrack);
    if (_viewMode == 1) {
      _fetchLyrics();
    } else {
      _scheduleDeferredLyrics();
    }
    _posSub = widget.app.preview.positionStream.listen((pos) {
      if (!mounted) return;
      setState(() => _currentPos = pos);
      _updateActiveLine(pos);
    });
    widget.app.preview.addListener(_onPreviewChanged);
  }

  @override
  void dispose() {
    _deferredLyricsTimer?.cancel();
    widget.app.preview.removeListener(_onPreviewChanged);
    _posSub?.cancel();
    _userScrollDebounce?.cancel();
    _lyricsScroll.dispose();
    super.dispose();
  }

  void _scheduleDeferredLyrics() {
    _deferredLyricsTimer?.cancel();
    // Allow ExoPlayer 3.5s of dedicated network bandwidth to connect and
    // begin playing immediately without socket contention from 4 concurrent lyrics lookups.
    _deferredLyricsTimer = Timer(const Duration(milliseconds: 3500), () {
      if (!mounted) return;
      if (_lyricsResult == null && !_loadingLyrics) {
        _fetchLyrics();
      }
    });
  }

  void _onPreviewChanged() {
    final active = widget.app.preview.currentTrack;
    if (active != null && active.id != _currentTrack.id) {
      _deferredLyricsTimer?.cancel();
      setState(() {
        _currentTrack = active;
        _activeLineIndex = -1;
        _currentPos = Duration.zero;
        _lyricsResult = null;
        _parsedLines = [];
        _loadingLyrics = (_viewMode == 1);
      });
      _loadAlbum(active);
      if (_viewMode == 1) {
        _fetchLyrics();
      } else {
        _scheduleDeferredLyrics();
      }
    } else {
      if (mounted) setState(() {});
    }
  }

  Future<void> _loadAlbum(Track track) async {
    if (track.album?.trim().isNotEmpty == true || track.id.startsWith('local_')) return;
    final details = await YtmSearchService.fetchDetails(track.id);
    var album = details.album?.trim();
    String? browseId;
    if (album == null || album.isEmpty) {
      final candidates = await YtmSearchService.search('${track.tagTitle} ${track.tagArtist}', limit: 20);
      final match = YtmSearchService.findAlbumTrack(track, candidates);
      album = match?.album?.trim();
      browseId = match?.albumBrowseId;
    }
    if (!mounted || _currentTrack.id != track.id || album == null || album.isEmpty) return;
    setState(() => _currentTrack = _currentTrack.copyWith(album: album, albumBrowseId: browseId));
  }

  void _updateActiveLine(Duration pos) {
    if (_parsedLines.isEmpty || _userScrolling) return;
    int idx = -1;
    for (int i = 0; i < _parsedLines.length; i++) {
      if (_parsedLines[i].time <= pos) {
        idx = i;
      } else {
        break;
      }
    }
    if (idx != _activeLineIndex && idx >= 0) {
      _activeLineIndex = idx;
      if (_lyricsScroll.hasClients) {
        final targetOffset = (idx * 52.0) - 120.0;
        _lyricsScroll.animateTo(
          targetOffset.clamp(0.0, _lyricsScroll.position.maxScrollExtent),
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  Future<void> _fetchLyrics() async {
    _deferredLyricsTimer?.cancel();
    final targetId = _currentTrack.id;
    setState(() => _loadingLyrics = true);
    try {
      final localPath = widget.app.getLocalTrackPath(_currentTrack.id);
      final res = await LyricsService.fetch(
        _currentTrack,
        yt: widget.app.yt,
        localPath: localPath,
      );
      if (!mounted || _currentTrack.id != targetId) return;
      if (res != null) {
        _lyricsResult = res;
        if (res.isSynced) {
          _parsedLines = _parseLrc(res.lyrics);
        } else {
          _parsedLines = [];
        }
      } else {
        _lyricsResult = null;
        _parsedLines = [];
      }
    } catch (_) {}
    if (mounted && _currentTrack.id == targetId) {
      setState(() => _loadingLyrics = false);
    }
  }

  List<_ParsedLyricLine> _parseLrc(String lrc) {
    final lines = <_ParsedLyricLine>[];
    final regex = RegExp(r'\[(\d+):(\d+(?:\.\d+)?)\](.*)');
    for (final line in lrc.split('\n')) {
      final m = regex.firstMatch(line.trim());
      if (m != null) {
        final min = int.tryParse(m.group(1)!) ?? 0;
        final sec = double.tryParse(m.group(2)!) ?? 0.0;
        final text = m.group(3)?.trim() ?? '';
        final totalMs = ((min * 60 + sec) * 1000).round();
        if (text.isNotEmpty) {
          lines.add(_ParsedLyricLine(Duration(milliseconds: totalMs), text));
        }
      }
    }
    lines.sort((a, b) => a.time.compareTo(b.time));
    return lines;
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final t = _currentTrack;
    final app = widget.app;
    final bgColor = sheetBgColor(context);
    final totalDuration = app.preview.duration ?? t.duration ?? const Duration(minutes: 3);

    return Container(
      height: MediaQuery.of(context).size.height * 0.90,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 20, spreadRadius: 5),
        ],
      ),
      child: Column(
        children: [
          // Drag handle
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

          // Top Header Bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                if (_viewMode == 0)
                  IconButton(
                    tooltip: tr('Close'),
                    icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 28),
                    onPressed: () => Navigator.pop(context),
                  )
                else
                  IconButton(
                    tooltip: tr('Back to player'),
                    icon: const Icon(Icons.arrow_back_rounded, size: 24),
                    onPressed: () => setState(() => _viewMode = 0),
                  ),
                const Spacer(),
                Text(
                  _viewMode == 1
                      ? tr('Lyrics')
                      : _viewMode == 2
                      ? tr('Queue')
                      : tr('Now Playing'),
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                if (_viewMode == 0) ...[
                  ListenableBuilder(
                    listenable: widget.app.preview,
                    builder: (context, _) {
                      final active = widget.app.preview.isSleepTimerActive;
                      final mins = widget.app.preview.sleepTimerMinutesRemaining;
                      return PopupMenuButton<int>(
                        tooltip: active
                            ? '${tr('Sleep timer')}: $mins ${tr('min left')}'
                            : tr('Sleep timer'),
                        icon: Stack(
                          alignment: Alignment.topRight,
                          children: [
                            Icon(
                              active ? Icons.bedtime : Icons.bedtime_outlined,
                              size: 22,
                              color: active ? accent(context) : null,
                            ),
                            if (active && mins != null)
                              Container(
                                padding: const EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                  color: accent(context),
                                  shape: BoxShape.circle,
                                ),
                                constraints: const BoxConstraints(minWidth: 8, minHeight: 8),
                              ),
                          ],
                        ),
                        onSelected: (val) {
                          if (val == 0) {
                            widget.app.preview.cancelSleepTimer();
                            showAppSnackBar(
                              context,
                              tr('Sleep timer turned off'),
                            );
                          } else {
                            widget.app.preview.setSleepTimer(val);
                            showAppSnackBar(
                              context,
                              '${tr('Sleep timer set for')} $val ${tr('minutes')}',
                            );
                          }
                        },
                        itemBuilder: (ctx) => [
                          PopupMenuItem(
                            value: 15,
                            child: Text('15 ${tr('minutes')}'),
                          ),
                          PopupMenuItem(
                            value: 30,
                            child: Text('30 ${tr('minutes')}'),
                          ),
                          PopupMenuItem(
                            value: 45,
                            child: Text('45 ${tr('minutes')}'),
                          ),
                          PopupMenuItem(
                            value: 60,
                            child: Text('60 ${tr('minutes')}'),
                          ),
                          if (active)
                            PopupMenuItem(
                              value: 0,
                              child: Text(
                                tr('Turn off timer'),
                                style: TextStyle(color: errColor(context)),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  IconButton(
                    tooltip: tr('More'),
                    icon: const Icon(Icons.more_vert, size: 22),
                    onPressed: () => TrackActionsSheet.show(
                      context,
                      track: t,
                      app: app,
                      onOpenArtist: widget.onOpenArtist,
                      onOpenAlbum: widget.onOpenAlbum,
                    ),
                  ),
                ] else ...[
                  IconButton(
                    tooltip: tr('Close'),
                    icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 28),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ],
            ),
          ),

          Expanded(
            child: _viewMode == 1
                ? _buildLyricsView()
                : _viewMode == 2
                ? _buildQueueView()
                : _buildTrackView(totalDuration),
          ),
        ],
      ),
    );
  }

  Widget _buildTrackView(Duration totalDuration) {
    final t = _currentTrack;
    final app = widget.app;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 32),
      child: Column(
        children: [
          const SizedBox(height: 8),
          // Large High-Res Artwork
          Center(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: TrackImage(
                thumb: widget.app.getCoverArt(t),
                width: 260,
                height: 260,
                borderRadius: BorderRadius.circular(16),
                placeholderIcon: Icons.music_note,
                iconSize: 80,
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Title
          Text(
            t.title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.5,
                ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),

          TrackCredits(
            track: t,
            onOpenArtist: widget.onOpenArtist == null ? null : (id, name) {
              Navigator.pop(context);
              widget.onOpenArtist!(id, name);
            },
            onOpenAlbum: widget.onOpenAlbum == null ? null : (id, title) {
              Navigator.pop(context);
              widget.onOpenAlbum!(id, title);
            },
          ),

          // Streamlined Action Row: Download icon + Save to Playlist icon
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ListenableBuilder(
                listenable: app,
                builder: (context, _) {
                  final isDone = app.isSaved(t);
                  final isQ = app.has(t.id);
                  return Semantics(
                    button: (!isDone && !isQ),
                    label: isDone
                        ? tr('Downloaded')
                        : isQ
                        ? tr('In queue')
                        : tr('Download song'),
                    child: IconButton(
                      tooltip: isDone
                          ? tr('Downloaded')
                          : isQ
                          ? tr('In queue')
                          : tr('Download song'),
                      icon: Icon(
                        isDone
                            ? Icons.check_circle_rounded
                            : isQ
                            ? Icons.hourglass_top_rounded
                            : Icons.download_rounded,
                        color: isDone
                            ? okColor(context)
                            : isQ
                            ? accent(context)
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                        size: 26,
                      ),
                      onPressed: (!isDone && !isQ)
                          ? () {
                              HapticFeedback.lightImpact();
                              app.add([t]);
                              app.run();
                              showAppSnackBar(
                                context,
                                tr('Added to queue'),
                              );
                              setState(() {});
                            }
                          : null,
                    ),
                  );
                },
              ),
              const SizedBox(width: 14),
              Semantics(
                button: true,
                label: tr('Save to playlist'),
                child: IconButton(
                  tooltip: tr('Save to playlist'),
                  icon: const Icon(Icons.playlist_add_rounded, size: 26),
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    AddToPlaylistSheet.show(context, track: t, app: app);
                  },
                ),
              ),
            ],
          ),

          const SizedBox(height: 14),

          // Audio Scrubber Slider
          Semantics(
            label: tr('Playback progress'),
            value: '${_formatDuration(_currentPos)} / ${_formatDuration(totalDuration)}',
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: accent(context),
                thumbColor: accent(context),
              ),
              child: Slider(
                value: _currentPos.inMilliseconds
                    .clamp(0, totalDuration.inMilliseconds)
                    .toDouble(),
                min: 0,
                max: totalDuration.inMilliseconds.toDouble(),
                onChanged: (val) {
                  widget.app.preview.seek(Duration(milliseconds: val.round()));
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatDuration(_currentPos),
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  _formatDuration(totalDuration),
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Playback Controls (Spotify style: Shuffle | Previous | Play/Pause | Next | Repeat)
          ListenableBuilder(
            listenable: widget.app.preview,
            builder: (_, _) {
              final loading = widget.app.preview.loadingId == t.id;
              final playing = widget.app.preview.playingId == t.id && widget.app.preview.isPlaying;
              final shuffleActive = widget.app.preview.shuffle;
              final loopMode = widget.app.preview.loopMode;
              final hasPrev = widget.app.preview.hasPrevious;
              final hasNxt = widget.app.preview.hasNext;

              return Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // Shuffle
                      Semantics(
                        button: true,
                        label: shuffleActive ? tr('Shuffle on') : tr('Shuffle off'),
                        child: IconButton(
                          tooltip: shuffleActive ? tr('Shuffle on') : tr('Shuffle off'),
                          icon: Icon(
                            Icons.shuffle_rounded,
                            size: 24,
                            color: shuffleActive
                                ? accent(context)
                                : Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                          ),
                          onPressed: () => widget.app.preview.toggleShuffle(),
                        ),
                      ),

                      // Previous
                      Semantics(
                        button: true,
                        label: tr('Previous'),
                        child: IconButton(
                          tooltip: tr('Previous'),
                          iconSize: 38,
                          icon: Icon(
                            Icons.skip_previous_rounded,
                            color: hasPrev || widget.app.preview.position.inSeconds > 3
                                ? Theme.of(context).colorScheme.onSurface
                                : Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                          ),
                          onPressed: () => widget.app.preview.previous(),
                        ),
                      ),

                      // Play / Pause FAB
                      Semantics(
                        button: true,
                        label: playing ? tr('Pause') : tr('Play'),
                        child: Container(
                          width: 66,
                          height: 66,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: accent(context),
                            boxShadow: [
                              BoxShadow(
                                color: accent(context).withValues(alpha: 0.4),
                                blurRadius: 16,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: IconButton(
                            tooltip: playing ? tr('Pause') : tr('Play'),
                            icon: loading
                                ? const SizedBox(
                                    width: 26,
                                    height: 26,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: Colors.black,
                                    ),
                                  )
                                : Icon(
                                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                    size: 38,
                                    color: Colors.black,
                                  ),
                            onPressed: () => widget.app.preview.toggle(t),
                          ),
                        ),
                      ),

                      // Next
                      Semantics(
                        button: true,
                        label: tr('Next'),
                        child: IconButton(
                          tooltip: tr('Next'),
                          iconSize: 38,
                          icon: Icon(
                            Icons.skip_next_rounded,
                            color: hasNxt
                                ? Theme.of(context).colorScheme.onSurface
                                : Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                          ),
                          onPressed: () => widget.app.preview.next(),
                        ),
                      ),

                      // Repeat
                      Semantics(
                        button: true,
                        label: loopMode == LoopMode.one
                            ? tr('Repeat one')
                            : loopMode == LoopMode.all
                            ? tr('Repeat all')
                            : tr('Repeat off'),
                        child: IconButton(
                          tooltip: loopMode == LoopMode.one
                              ? tr('Repeat one')
                              : loopMode == LoopMode.all
                              ? tr('Repeat all')
                              : tr('Repeat off'),
                          icon: Icon(
                            loopMode == LoopMode.one
                                ? Icons.repeat_one_rounded
                                : Icons.repeat_rounded,
                            size: 24,
                            color: loopMode != LoopMode.off
                                ? accent(context)
                                : Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                          ),
                          onPressed: () => widget.app.preview.cycleLoopMode(),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),

                  // Bottom Navigation: Clean Lyrics & Queue pills
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        ),
                        icon: const Icon(Icons.lyrics_outlined, size: 18),
                        label: Text(
                          _lyricsResult?.isSynced == true ? tr('Lyrics (Synced)') : tr('Lyrics'),
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                        onPressed: () {
                          HapticFeedback.lightImpact();
                          setState(() => _viewMode = 1);
                          if (_lyricsResult == null && !_loadingLyrics) {
                            _fetchLyrics();
                          }
                        },
                      ),
                      const SizedBox(width: 14),
                      FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        ),
                        icon: const Icon(Icons.queue_music_rounded, size: 18),
                        label: Text(
                          widget.app.preview.queue.isNotEmpty
                              ? '${tr('Queue')} (${widget.app.preview.queue.length})'
                              : tr('Queue'),
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                        onPressed: () {
                          HapticFeedback.lightImpact();
                          setState(() => _viewMode = 2);
                        },
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildLyricsView() {
    if (_loadingLyrics) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              tr('Finding synchronized lyrics...'),
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    if (_lyricsResult == null || _lyricsResult!.lyrics.trim().isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lyrics, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(
                tr('No lyrics found for this track.'),
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(tr('Retry')),
                onPressed: _fetchLyrics,
              ),
            ],
          ),
        ),
      );
    }

    // Synchronized Karaoke Lyrics View
    if (_lyricsResult!.isSynced && _parsedLines.isNotEmpty) {
      return NotificationListener<ScrollNotification>(
        onNotification: (notif) {
          if (notif is UserScrollNotification) {
            _userScrolling = true;
            _userScrollDebounce?.cancel();
            _userScrollDebounce = Timer(const Duration(seconds: 3), () {
              if (mounted) _userScrolling = false;
            });
          }
          return false;
        },
        child: ListView.builder(
          controller: _lyricsScroll,
          padding: const EdgeInsets.fromLTRB(28, 20, 28, 48),
          itemCount: _parsedLines.length,
          itemBuilder: (ctx, i) {
            final line = _parsedLines[i];
            final isActive = i == _activeLineIndex;
            final isPast = i < _activeLineIndex;

            return InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                widget.app.preview.seek(line.time);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                child: Text(
                  line.text,
                  style: TextStyle(
                    fontSize: isActive ? 22 : 17,
                    fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
                    color: isActive
                        ? accent(context)
                        : isPast
                        ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.8)
                        : Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                    height: 1.35,
                  ),
                ),
              ),
            );
          },
        ),
      );
    }

    // Plain text lyrics view
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 20, 32, 48),
      child: SelectableText(
        _lyricsResult!.lyrics,
        style: const TextStyle(fontSize: 16, height: 1.6),
      ),
    );
  }

  Widget _buildQueueView() {
    return ListenableBuilder(
      listenable: widget.app.preview,
      builder: (context, _) {
        final queue = widget.app.preview.queue;
        if (queue.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.queue_music, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(height: 12),
                  Text(
                    tr('Playback queue is empty.'),
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        }

        final currentIdx = widget.app.preview.currentIndex;

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
              child: Row(
                children: [
                  Text(
                    trp('{n} songs in queue', {'n': queue.length}),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  if (queue.length > 1)
                    TextButton.icon(
                      icon: const Icon(Icons.clear_all, size: 18),
                      label: Text(tr('Clear upcoming')),
                      onPressed: () {
                        widget.app.preview.clearUpcoming();
                        HapticFeedback.lightImpact();
                      },
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ReorderableListView.builder(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 32),
                itemCount: queue.length,
                // ignore: deprecated_member_use
                onReorder: (oldIdx, newIdx) {
                  HapticFeedback.lightImpact();
                  widget.app.preview.reorderQueue(oldIdx, newIdx);
                },
                itemBuilder: (context, i) {
                  final item = queue[i];
                  final isCurrent = i == currentIdx;
                  final saved = widget.app.isSaved(item);

                  return ListTile(
                    key: ValueKey('queue_reorder_${item.id}_$i'),
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              TrackImage(
                                thumb: widget.app.getCoverArt(item),
                                width: 40,
                                height: 40,
                                borderRadius: BorderRadius.circular(6),
                                placeholderIcon: Icons.music_note,
                                iconSize: 20,
                              ),
                              if (isCurrent)
                                Container(
                                  width: 40,
                                  height: 40,
                                  color: Colors.black45,
                                  child: Icon(Icons.graphic_eq, color: accent(context), size: 22),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    title: Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                        color: isCurrent ? accent(context) : null,
                      ),
                    ),
                    subtitle: Text(
                      item.author.replaceAll(RegExp(r'\s*-\s*Topic$', caseSensitive: false), ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (saved)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(Icons.check_circle, size: 16, color: okColor(context)),
                          ),
                        IconButton(
                          tooltip: tr('Remove from queue'),
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            widget.app.preview.removeFromQueue(i);
                          },
                        ),
                      ],
                    ),
                    onTap: () {
                      widget.app.preview.playTrack(item);
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
