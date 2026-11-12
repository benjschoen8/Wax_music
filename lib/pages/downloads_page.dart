import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants.dart';
import '../log.dart';
import '../models/track.dart';
import '../state.dart';
import '../strings.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/track_actions_sheet.dart';
import '../widgets/track_image.dart';

class DownloadsPage extends StatelessWidget {
  final AppState app;
  final VoidCallback? onOpenSearch;

  const DownloadsPage({
    super.key,
    required this.app,
    this.onOpenSearch,
  });

  void _remove(BuildContext context, Track t) {
    app.remove(t);
    showAppSnackBar(
      context,
      tr('Removed'),
      duration: const Duration(seconds: 3),
      action: SnackBarAction(label: tr('Undo'), onPressed: app.undoRemove),
    );
  }

  void _showError(BuildContext context, Track t) => showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      content: SelectableText(t.msg.isEmpty ? '—' : t.msg),
      actions: [
        TextButton(
          onPressed: AppLog.length == 0
              ? null
              : () async {
                  await Clipboard.setData(ClipboardData(text: AppLog.text));
                  if (c.mounted) Navigator.pop(c);
                },
          child: Text(tr('Copy log')),
        ),
        FilledButton(onPressed: () => Navigator.pop(c), child: Text(tr('Close'))),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final pending = app.queue.where(
          (t) => t.status == Status.queued || t.status == Status.downloading,
        ).toList();
        final finished = app.queue.where((t) => t.status == Status.done).toList();
        final failed = app.queue.where((t) => t.status == Status.error).toList();

        final hasPending = pending.isNotEmpty;

        return Column(
          children: [
            // Directory Problem Alert
            if (app.dirProblem != null)
              Container(
                width: double.infinity,
                color: errColor(context).withValues(alpha: 0.12),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: errColor(context), size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        app.dirProblem!,
                        style: TextStyle(color: errColor(context), fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),

            // Downloads Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tr('Downloads'),
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          hasPending
                              ? trp('{n} downloading · {k} finished', {
                                  'n': pending.length,
                                  'k': finished.length,
                                })
                              : finished.isNotEmpty
                              ? trp('{k} downloads finished', {'k': finished.length})
                              : tr('No active downloads'),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (finished.isNotEmpty || failed.isNotEmpty)
                    TextButton(
                      onPressed: app.clearFinished,
                      child: Text(tr('Clear finished')),
                    ),
                  if (app.running)
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.stop, size: 18),
                      label: Text(tr('Stop')),
                      onPressed: app.stopAll,
                    )
                  else if (hasPending)
                    FilledButton.icon(
                      icon: const Icon(Icons.download, size: 18),
                      label: Text(tr('Download all')),
                      onPressed: app.startAll,
                    ),
                ],
              ),
            ),

            if (failed.isNotEmpty)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: errColor(context).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, color: errColor(context), size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        trp('{n} downloads failed', {'n': failed.length}),
                        style: TextStyle(color: errColor(context), fontSize: 13, fontWeight: FontWeight.w500),
                      ),
                    ),
                    TextButton(
                      onPressed: app.startAll,
                      child: Text(tr('Retry')),
                    ),
                  ],
                ),
              ),

            if (app.waitingForWifi)
              Container(
                width: double.infinity,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Icon(Icons.wifi_off, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        tr('Waiting for Wi-Fi to start downloading…'),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),

            if (app.queue.isNotEmpty && hasPending)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    minHeight: 4,
                    value: finished.length / app.queue.length,
                  ),
                ),
              ),

            const Divider(height: 1),

            // Downloads Queue List
            Expanded(
              child: app.queue.isEmpty
                  ? Center(
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
                              child: Icon(
                                Icons.download_done_rounded,
                                size: 36,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              tr('No active downloads'),
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              tr('Tracks you download will appear here while downloading and finishing.'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                                fontSize: 13,
                              ),
                            ),
                            if (onOpenSearch != null) ...[
                              const SizedBox(height: 20),
                              FilledButton.icon(
                                icon: const Icon(Icons.search),
                                label: Text(tr('Search Songs')),
                                onPressed: onOpenSearch,
                              ),
                            ],
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: app.queue.length,
                      padding: const EdgeInsets.only(bottom: 24),
                      itemBuilder: (context, i) {
                        final t = app.queue[i];
                        final isPlayingThis = app.preview.playingId == t.id && app.preview.isPlaying;
                        final isLoadingThis = app.preview.loadingId == t.id;

                        final label = switch (t.status) {
                          Status.queued => tr('Waiting in download queue…'),
                          Status.downloading => t.msg.isNotEmpty
                              ? t.msg
                              : trp('Downloading {p}%', {
                                  'p': (t.progress * 100).floor(),
                                }),
                          Status.done => tr('Downloaded successfully'),
                          Status.error => tr('Download failed, tap to retry'),
                        };

                        return Dismissible(
                          key: ValueKey('dl_${t.id}'),
                          direction: DismissDirection.endToStart,
                          confirmDismiss: (_) async => t.status != Status.downloading,
                          onDismissed: (_) => _remove(context, t),
                          background: Container(
                            color: errColor(context),
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 20),
                            child: const Icon(Icons.delete_outline, color: Colors.white, size: 28),
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            onTap: () {
                              if (t.status == Status.error) {
                                HapticFeedback.lightImpact();
                                app.retry(t);
                              } else if (t.status == Status.done) {
                                HapticFeedback.lightImpact();
                                app.preview.toggle(t);
                              } else if (t.status == Status.queued) {
                                app.startAll();
                              }
                            },
                            onLongPress: () => TrackActionsSheet.show(
                              context,
                              track: t,
                              app: app,
                            ),
                            leading: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  TrackImage(
                                    thumb: app.getCoverArt(t),
                                    width: 50,
                                    height: 50,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  Container(
                                    width: 50,
                                    height: 50,
                                    color: isPlayingThis
                                        ? Colors.black54
                                        : (t.status == Status.done ? Colors.black26 : Colors.black45),
                                  ),
                                  if (isLoadingThis)
                                    const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                    )
                                  else if (isPlayingThis)
                                    Icon(Icons.pause_rounded, color: accent(context), size: 26)
                                  else if (t.status == Status.done)
                                    const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 26)
                                  else if (t.status == Status.downloading)
                                    const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                                    )
                                  else if (t.status == Status.error)
                                    Icon(Icons.error_outline, color: errColor(context), size: 24)
                                  else
                                    const Icon(Icons.hourglass_top, color: Colors.white70, size: 20),
                                ],
                              ),
                            ),
                            title: Text(
                              t.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14.5,
                                color: isPlayingThis ? accent(context) : null,
                              ),
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 2),
                                Row(
                                  children: [
                                    if (t.status == Status.done) ...[
                                      Icon(Icons.check_circle, size: 14, color: okColor(context)),
                                      const SizedBox(width: 4),
                                    ],
                                    Expanded(
                                      child: Text(
                                        label,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: switch (t.status) {
                                            Status.done => okColor(context),
                                            Status.error => errColor(context),
                                            Status.downloading => accent(context),
                                            _ => Theme.of(context).colorScheme.onSurfaceVariant,
                                          },
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                if (t.status == Status.downloading)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(2),
                                      child: LinearProgressIndicator(
                                        minHeight: 3,
                                        value: t.msg.isNotEmpty ? null : t.progress,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            trailing: t.status == Status.error
                                ? Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (t.msg.isNotEmpty)
                                        IconButton(
                                          tooltip: tr('Error details'),
                                          icon: const Icon(Icons.info_outline_rounded, size: 22),
                                          onPressed: () => _showError(context, t),
                                        ),
                                      IconButton(
                                        tooltip: tr('Retry'),
                                        icon: const Icon(Icons.refresh, size: 22),
                                        onPressed: () => app.retry(t),
                                      ),
                                    ],
                                  )
                                : t.status == Status.downloading
                                ? IconButton(
                                    tooltip: tr('Cancel'),
                                    icon: const Icon(Icons.stop_circle_outlined, size: 22),
                                    onPressed: () => app.cancel(t),
                                  )
                                : Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        icon: const Icon(Icons.more_vert, size: 20),
                                        tooltip: tr('More'),
                                        onPressed: () => TrackActionsSheet.show(
                                          context,
                                          track: t,
                                          app: app,
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
      },
    );
  }
}
