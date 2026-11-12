import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'audio_handler.dart';
import 'browser_auth.dart';
import 'constants.dart';
import 'pages/downloads_page.dart';
import 'pages/home_page.dart';
import 'pages/library_page.dart';
import 'pages/search_page.dart';
import 'pages/settings_page.dart';
import 'playlist_sharing.dart';
import 'share.dart';
import 'state.dart';
import 'models/track.dart';
import 'strings.dart';
import 'log.dart';
import 'widgets/app_snackbar.dart';
import 'widgets/mini_player.dart';
import 'widgets/track_navigation.dart';

late final WaxAudioHandler waxAudioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Route uncaught errors through AppLog, which redacts cookies / tokens / URL
  // queries, instead of letting raw exception text (signed stream URLs, headers)
  // go straight to the device log.
  FlutterError.onError = (details) =>
      AppLog.error('flutter', details.exception, details.stack);
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    AppLog.error('uncaught', error, stack);
    return true;
  };
  waxAudioHandler = await AudioService.init(
    builder: () => WaxAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'dev.crate.wax.channel.audio',
      androidNotificationChannelName: 'Wax Audio Playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      androidNotificationIcon: 'drawable/ic_stat_music',
      notificationColor: Color(0xFFFFB300),
    ),
  );
  FlutterForegroundTask.initCommunicationPort();
  runApp(const CrateApp());
}

ThemeData _theme(Brightness b) {
  final isDark = b == Brightness.dark;
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: amber,
      brightness: b,
      surface: isDark ? const Color(0xFF0F1015) : null,
      surfaceContainerHigh: isDark ? const Color(0xFF1B1D25) : null,
      surfaceContainerHighest: isDark ? const Color(0xFF252733) : null,
    ),
    scaffoldBackgroundColor: isDark ? const Color(0xFF0F1015) : null,
    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      backgroundColor: isDark ? const Color(0xFF13141C) : null,
      indicatorColor: amber.withValues(alpha: isDark ? 0.22 : 0.35),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      elevation: 4,
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 14),
    ),
  );
}

class CrateApp extends StatelessWidget {
  const CrateApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Wax',
    debugShowCheckedModeBanner: false,
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    themeMode: ThemeMode.system,
    home: const Home(),
  );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  final app = AppState();
  final searchKey = GlobalKey<SearchPageState>();
  final libraryKey = GlobalKey<LibraryPageState>();
  int tab = 0;
  DateTime? _lastBackPressTime;
  bool _showingVerification = false;

  void _switchTab(int newTab) {
    if (tab == newTab) return;
    setState(() => tab = newTab);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    app.runFinished.removeListener(_onRunFinished);
    BrowserAuth.verificationRequired.removeListener(_onVerificationRequired);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed || state == AppLifecycleState.paused) {
      waxAudioHandler.sync();
    }
  }

  void _onVerificationRequired() {
    if (!BrowserAuth.verificationRequired.value) {
      if (_showingVerification && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _showingVerification = false;
        BrowserAuth.isWebViewInModal.value = false;
      }
      return;
    }
    if (_showingVerification || !mounted) return;
    _showingVerification = true;
    BrowserAuth.isWebViewInModal.value = true;
    showModalBottomSheet(
      context: context,
      isDismissible: true,
      enableDrag: false,
      isScrollControlled: true,
      backgroundColor: sheetBgColor(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => PopScope(
        onPopInvokedWithResult: (_, _) {
          _showingVerification = false;
          BrowserAuth.isWebViewInModal.value = false;
        },
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.8,
          child: Column(
            children: [
              AppBar(
                title: Text(tr('Security check')),
                automaticallyImplyLeading: false,
                actions: [
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: tr('Close'),
                    onPressed: () {
                      _showingVerification = false;
                      BrowserAuth.isWebViewInModal.value = false;
                      Navigator.pop(ctx);
                    },
                  ),
                ],
              ),
              Expanded(
                child: WebViewWidget(controller: BrowserAuth.controller),
              ),
            ],
          ),
        ),
      ),
    ).then((_) {
      _showingVerification = false;
      BrowserAuth.isWebViewInModal.value = false;
    });
  }

  /// Compact, subtle pill notification when downloads complete.
  void _onRunFinished() {
    final stats = app.runFinished.value;
    if (stats == null || !mounted) return;
    app.runFinished.value = null;

    // Skip if user disabled download alerts in settings
    if (!app.downloadAlerts) return;

    // Skip if the user is already on the Downloads tab (they see the list directly)
    if (tab == 3) return;

    final hasErrors = stats.failed > 0;
    final String label;
    if (hasErrors) {
      label = trp('Done: {s} saved, {f} failed', {
        's': stats.saved,
        'f': stats.failed,
      });
    } else if (stats.saved == 1) {
      label = tr('Saved to Downloads');
    } else {
      label = trp('{n} songs saved to Downloads', {'n': stats.saved});
    }

    showAppSnackBar(
      context,
      label,
      duration: const Duration(milliseconds: 1800),
      icon: Icon(
        hasErrors ? Icons.warning_amber_rounded : Icons.check_circle_rounded,
        size: 18,
        color: hasErrors ? Colors.orangeAccent : const Color(0xFF66BB6A),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    waxAudioHandler.attachPreview(app.preview);
    app.runFinished.addListener(_onRunFinished);
    BrowserAuth.verificationRequired.addListener(_onVerificationRequired);
    // Links shared from other apps (YouTube -> Share -> Wax) or NFC playlist beam.
    final appReady = app.init();
    final intakeReady = ShareIntake.init((url) async {
      if (url.startsWith('wax://playlist')) {
        await _handleSharedPlaylist(url);
      } else {
        app.sharedUrl.value = url;
        if (mounted) _switchTab(1);
      }
    }, ready: appReady);
    intakeReady.then((_) {
      if (mounted) _askNotifications();
    });
  }

  Future<void> _handleSharedPlaylist(String raw) async {
    final pl = PlaylistSharingService.decodePlaylist(raw);
    if (pl == null || !mounted) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.queue_music_rounded, size: 36, color: accent(context)),
        title: Text(tr('Import playlist')),
        content: Text(
          trp('Import "{title}" ({n} songs) into your library?', {
            'title': pl.title,
            'n': pl.tracks.length,
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Import')),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      final imported = app.importPlaylist(pl);
      _switchTab(2);
      libraryKey.currentState?.openPlaylist(imported);
      showAppSnackBar(
        context,
        trp('Imported "{title}"', {'title': imported.title}),
        icon: const Icon(Icons.playlist_add_check_rounded, size: 18),
      );
    }
  }

  /// Request notification permission so Android shows the music bar / playback controls
  /// in the notification shade and on the lockscreen.
  Future<void> _askNotifications() async {
    try {
      final status = await FlutterForegroundTask.checkNotificationPermission();
      if (status == NotificationPermission.granted) return;

      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          icon: Icon(Icons.music_note_rounded, size: 36, color: accent(context)),
          title: Text(tr('Enable Music Bar & Controls')),
          content: Text(
            tr(
              'Allow notifications so Wax can display the music player in your notification bar and lock screen with play/pause and skip controls, and keep playback running in the background.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(tr('Not now')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(tr('Allow')),
            ),
          ],
        ),
      );
      if (ok == true) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
    } catch (_) {}
  }

  late final pages = [
    HomePage(
      app: app,
      onSearchQuery: (q) {
        _switchTab(1);
        searchKey.currentState?.searchFor(q);
      },
    ),
    SearchPage(
      key: searchKey,
      app: app,
      onOpenQueue: () => _switchTab(3),
    ),
    LibraryPage(
      key: libraryKey,
      app: app,
      onOpenSearch: () => _switchTab(1),
    ),
    DownloadsPage(
      app: app,
      onOpenSearch: () => _switchTab(1),
    ),
    SettingsPage(app: app),
  ];

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;

        // 1. If currently on Search tab, let Search handle its internal back stack first
        // (suggestions -> album/artist details -> search results -> explore root)
        if (tab == 1 && searchKey.currentState?.canGoBack == true) {
          searchKey.currentState?.goBack();
          return;
        }

        // 2. If currently on Library tab, let Library handle its internal back stack first
        // (playlist detail -> list / artist detail -> list / album detail -> list / search -> root)
        if (tab == 2 && libraryKey.currentState?.canGoBack == true) {
          libraryKey.currentState?.goBack();
          return;
        }

        // 3. If on any tab other than Home, return to Home (tab 0)
        if (tab != 0) {
          setState(() => tab = 0);
          return;
        }

        // 4. At Home: double-back-to-exit prevention
        final now = DateTime.now();
        if (_lastBackPressTime == null || now.difference(_lastBackPressTime!) > const Duration(seconds: 2)) {
          _lastBackPressTime = now;
          showAppSnackBar(
            context,
            tr('Press back again to exit'),
            duration: const Duration(seconds: 2),
            icon: const Icon(Icons.exit_to_app_rounded, size: 18),
          );
          return;
        }

        // Confirmed second back press: cleanly minimize or exit
        if (app.running) {
          FlutterForegroundTask.minimizeApp();
        } else {
          SystemNavigator.pop();
        }
      },
      child: TrackNavigation(
        onArtist: (track) {
          _switchTab(1);
          searchKey.currentState?.openArtistDirect(track.artistBrowseId ?? '', track.tagArtist);
        },
        onAlbum: (track) {
          _switchTab(1);
          searchKey.currentState?.openAlbumForTrack(track);
        },
        child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              IndexedStack(index: tab, children: pages),
              ListenableBuilder(
                listenable: BrowserAuth.isWebViewInModal,
                builder: (_, _) {
                  if (!BrowserAuth.isSupported ||
                      BrowserAuth.isWebViewInModal.value ||
                      _showingVerification) {
                    return const SizedBox.shrink();
                  }
                  return IgnorePointer(
                    child: Opacity(
                      opacity: 0.001,
                      child: SizedBox(
                        width: 320,
                        height: 320,
                        child: WebViewWidget(controller: BrowserAuth.controller),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MiniPlayer(
              app: app,
              onOpenArtist: (browseId, name) {
                _switchTab(1);
                searchKey.currentState?.openArtistDirect(browseId, name);
              },
              onOpenAlbum: (browseId, title) {
                _switchTab(1);
                final track = app.preview.currentTrack;
                if (track != null) {
                  searchKey.currentState?.openAlbumForTrack(
                    track.copyWith(album: title, albumBrowseId: browseId),
                  );
                } else {
                  searchKey.currentState?.openAlbumDirect(browseId, title);
                }
              },
            ),
            ListenableBuilder(
              listenable: app,
              builder: (_, _) {
                final pending = app.queue
                    .where(
                      (t) =>
                          t.status == Status.queued ||
                          t.status == Status.downloading,
                    )
                    .length;
                return NavigationBar(
                  selectedIndex: tab,
                  onDestinationSelected: (i) {
                    HapticFeedback.selectionClick();
                    _switchTab(i);
                  },
                  destinations: [
                    NavigationDestination(
                      icon: const Icon(Icons.home_outlined),
                      selectedIcon: const Icon(Icons.home_rounded),
                      label: tr('Home'),
                    ),
                    NavigationDestination(
                      icon: const Icon(Icons.search_outlined),
                      selectedIcon: const Icon(Icons.search_rounded),
                      label: tr('Search'),
                    ),
                    NavigationDestination(
                      icon: const Icon(Icons.library_music_outlined),
                      selectedIcon: const Icon(Icons.library_music_rounded),
                      label: tr('Library'),
                    ),
                    NavigationDestination(
                      icon: Badge(
                        isLabelVisible: pending > 0,
                        label: Text('$pending'),
                        child: const Icon(Icons.download_rounded),
                      ),
                      selectedIcon: Badge(
                        isLabelVisible: pending > 0,
                        label: Text('$pending'),
                        child: const Icon(Icons.download_done_rounded),
                      ),
                      label: tr('Downloads'),
                    ),
                    NavigationDestination(
                      icon: const Icon(Icons.settings_outlined),
                      selectedIcon: const Icon(Icons.settings_rounded),
                      label: tr('Settings'),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
      ),
    );
}
