import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../browser_auth.dart';
import '../constants.dart';
import '../log.dart';
import '../state.dart';
import '../strings.dart';
import '../widgets/app_snackbar.dart';

class SettingsPage extends StatefulWidget {
  final AppState app;
  const SettingsPage({super.key, required this.app});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _showAdvanced = false;

  Future<void> _setDir(String? path) async {
    if (path == null) return;
    final err = await widget.app.testDir(path);
    if (!mounted) return;
    if (err != null) {
      showAppSnackBar(context, err);
    } else {
      await widget.app.setDir(path);
      if (!mounted) return;
      showAppSnackBar(context, tr('Save folder updated'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final cardColor = cardBgColor(context);

    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            Text(
              tr('Settings'),
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 16),

            // Card 1: Storage & Folder
            Card(
              elevation: 0,
              color: cardColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.folder_rounded, color: accent(context), size: 22),
                        const SizedBox(width: 8),
                        Text(
                          tr('Music Storage'),
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      tr('Current save location:'),
                      style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.audio_file, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              app.dir,
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (app.dirProblem != null) ...[
                      const SizedBox(height: 8),
                      Text(app.dirProblem!, style: TextStyle(color: errColor(context), fontSize: 12)),
                    ],
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          icon: const Icon(Icons.home_rounded, size: 18),
                          label: Text(tr('Default (Music)')),
                          onPressed: () => _setDir(musicDir),
                        ),
                        FilledButton.tonalIcon(
                          icon: const Icon(Icons.folder_open_rounded, size: 18),
                          label: Text(tr('Change Folder…')),
                          onPressed: () async {
                            final picked = await FilePicker.platform.getDirectoryPath();
                            if (mounted && picked != null) _setDir(picked);
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            // Card 2: Google Account (Optional) - Faster throttle-free playback
            Card(
              elevation: 0,
              color: cardColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ValueListenableBuilder<bool>(
                  valueListenable: BrowserAuth.authState,
                  builder: (context, signedIn, _) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: (signedIn ? okColor(context) : accent(context)).withValues(alpha: 0.15),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                signedIn ? Icons.verified_user_rounded : Icons.account_circle_outlined,
                                color: signedIn ? okColor(context) : accent(context),
                                size: 22,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    tr('Google Account (Optional)'),
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                  ),
                                  Text(
                                    signedIn
                                        ? tr('Signed in and active')
                                        : tr('Enhance playback speed and reliability'),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: signedIn ? okColor(context) : Theme.of(context).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (signedIn)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: okColor(context).withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  tr('Signed in'),
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: okColor(context)),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                signedIn
                                    ? tr('Session active for faster playback and downloads.')
                                    : tr('Optional sign-in for improved stream speed and availability.'),
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.info_outline_rounded, size: 20),
                              tooltip: tr('Details'),
                              onPressed: () {
                                showDialog(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: Text(tr('Google Account (Optional)')),
                                    content: Text(
                                      signedIn
                                          ? tr('Your Google Account session is active. YouTube rate-limiting and stream throttling are bypassed, unlocking maximum speed and instant playback.')
                                          : tr('Sign in to your Google / YouTube account to remove speed throttling, bypass rate-limits, unlock age-restricted tracks, and achieve instant playback. You can also continue using Wax anonymously without signing in.'),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.of(ctx).pop(),
                                        child: Text(tr('OK')),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        if (signedIn)
                          OutlinedButton.icon(
                            icon: const Icon(Icons.logout_rounded, size: 18),
                            label: Text(tr('Sign out')),
                            onPressed: () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: Text(tr('Sign out')),
                                  content: Text(tr('Sign out of your Google Account? Streaming will revert to anonymous mode.')),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(ctx, false),
                                      child: Text(tr('Cancel')),
                                    ),
                                    FilledButton(
                                      onPressed: () => Navigator.pop(ctx, true),
                                      child: Text(tr('Sign out')),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm == true) {
                                await BrowserAuth.signOut();
                                if (context.mounted) {
                                  showAppSnackBar(
                                    context,
                                    tr('Signed out of Google Account'),
                                  );
                                }
                              }
                            },
                          )
                        else
                          FilledButton.tonalIcon(
                            icon: const Icon(Icons.login_rounded, size: 18),
                            label: Text(tr('Sign in with Google')),
                            onPressed: () async {
                              await BrowserAuth.showSignInSheet(context);
                              if (context.mounted && BrowserAuth.isSignedIn) {
                                showAppSnackBar(
                                  context,
                                  tr('Signed in to Google Account'),
                                );
                              }
                            },
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),

            const SizedBox(height: 12),

            // Card: Music Bar & Background Controls
            Card(
              elevation: 0,
              color: cardColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FutureBuilder<NotificationPermission>(
                  future: FlutterForegroundTask.checkNotificationPermission(),
                  builder: (context, snap) {
                    final granted = snap.data == NotificationPermission.granted;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.notifications_active_rounded,
                              color: granted ? okColor(context) : accent(context),
                              size: 22,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                tr('Music Bar & Background Controls'),
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: (granted ? okColor(context) : errColor(context)).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                granted ? tr('Enabled') : tr('Disabled'),
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: granted ? okColor(context) : errColor(context),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          tr('Shows playback controls (play, pause, skip) and track artwork in your notification bar and lock screen, and allows continuous background playback when the screen is locked or another app is open.'),
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.4,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (!granted) ...[
                          const SizedBox(height: 14),
                          FilledButton.tonalIcon(
                            icon: const Icon(Icons.check_circle_outline, size: 18),
                            label: Text(tr('Enable Notification Controls')),
                            onPressed: () async {
                              await FlutterForegroundTask.requestNotificationPermission();
                              setState(() {});
                            },
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ),

            const SizedBox(height: 12),

            // Card 3: Playback & Download Preferences
            Card(
              elevation: 0,
              color: cardColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  children: [
                    SwitchListTile(
                      secondary: const Icon(Icons.wifi_rounded),
                      title: Text(tr('Download on Wi-Fi only')),
                      subtitle: Text(
                        tr('Downloads wait until Wi-Fi or Ethernet is connected.'),
                        style: const TextStyle(fontSize: 12),
                      ),
                      value: app.wifiOnly,
                      onChanged: app.setWifiOnly,
                    ),
                    const Divider(height: 1, indent: 56),
                    SwitchListTile(
                      secondary: const Icon(Icons.image_rounded),
                      title: Text(tr('Embed album art & tags')),
                      subtitle: Text(
                        tr('Embed square cover art, artist name, and album into files.'),
                        style: const TextStyle(fontSize: 12),
                      ),
                      value: app.tagging,
                      onChanged: app.setTagging,
                    ),
                    const Divider(height: 1, indent: 56),
                    SwitchListTile(
                      secondary: const Icon(Icons.lyrics_rounded),
                      title: Text(tr('Download synchronized lyrics')),
                      subtitle: Text(
                        tr('Save synced karaoke lyrics (.lrc) for offline sing-along.'),
                        style: const TextStyle(fontSize: 12),
                      ),
                      value: app.lyrics,
                      onChanged: app.setLyrics,
                    ),
                    const Divider(height: 1, indent: 56),
                    SwitchListTile(
                      secondary: const Icon(Icons.notifications_active_outlined),
                      title: Text(tr('Download completed alerts')),
                      subtitle: Text(
                        tr('Show a brief notification when songs finish downloading.'),
                        style: const TextStyle(fontSize: 12),
                      ),
                      value: app.downloadAlerts,
                      onChanged: app.setDownloadAlerts,
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            // Card 3: Advanced Options (Collapsible for cleaner UX)
            Card(
              elevation: 0,
              color: cardColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: ExpansionTile(
                initiallyExpanded: _showAdvanced,
                onExpansionChanged: (v) => setState(() => _showAdvanced = v),
                leading: const Icon(Icons.tune_rounded),
                title: Text(tr('Advanced Settings')),
                subtitle: Text(
                  tr('Parallel downloads, history & diagnostics'),
                  style: const TextStyle(fontSize: 12),
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Divider(height: 1),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(tr('Parallel downloads'), style: const TextStyle(fontWeight: FontWeight.w600)),
                                  Text(
                                    tr('1 is recommended for reliability.'),
                                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                                  ),
                                ],
                              ),
                            ),
                            SegmentedButton<int>(
                              segments: const [
                                ButtonSegment(value: 1, label: Text('1')),
                                ButtonSegment(value: 2, label: Text('2')),
                                ButtonSegment(value: 3, label: Text('3')),
                              ],
                              selected: {app.concurrency},
                              onSelectionChanged: (v) => app.setConcurrency(v.first),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.history_rounded, size: 18),
                          onPressed: app.downloaded.isEmpty
                              ? null
                              : () {
                                  final old = app.forgetHistory();
                                  showAppSnackBar(
                                    context,
                                    tr('History cleared'),
                                    duration: const Duration(seconds: 5),
                                    action: SnackBarAction(
                                      label: tr('Undo'),
                                      onPressed: () => app.restoreHistory(old),
                                    ),
                                  );
                                },
                          label: Text(
                            trp('Clear download history ({n})', {'n': app.downloaded.length}),
                          ),
                        ),
                        const SizedBox(height: 14),
                        ListenableBuilder(
                          listenable: AppLog.changes,
                          builder: (context, _) => Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  icon: const Icon(Icons.copy_rounded, size: 18),
                                  label: Text(trp('Copy diagnostic log ({n})', {'n': AppLog.length})),
                                  onPressed: AppLog.length == 0
                                      ? null
                                      : () async {
                                          await Clipboard.setData(ClipboardData(text: AppLog.text));
                                          if (!context.mounted) return;
                                          showAppSnackBar(
                                            context,
                                            tr('Log copied to clipboard'),
                                          );
                                        },
                                ),
                              ),
                              if (AppLog.length > 0) ...[
                                const SizedBox(width: 8),
                                IconButton(
                                  tooltip: tr('Clear'),
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: AppLog.clear,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // About Wax note
            Center(
              child: Text(
                'Wax · ${tr('Lossless & AAC YouTube Music Player')}',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
