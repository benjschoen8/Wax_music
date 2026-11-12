import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'log.dart';
import 'cache.dart';
import 'strings.dart';

/// Manages YouTube session cookies, PO tokens, bot-verification and Google account sign-in
/// using an offstage system WebView.
class BrowserAuth {
  static const _cookiePref = 'yt_browser_cookies';
  static const _visitorPref = 'yt_browser_visitor_data';
  static const _uaPref = 'yt_browser_user_agent';

  /// Session cookies are account credentials, so they live in the Android
  /// Keystore-backed encrypted store, never in plain SharedPreferences
  /// (which is readable from backups and on rooted devices).
  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static Future<String> _readSecureCookies() async {
    try {
      return await _secure.read(key: _cookiePref) ?? '';
    } catch (e, st) {
      AppLog.error('secure read cookies', e, st);
      return '';
    }
  }

  static Future<void> _writeSecureCookies(String value) async {
    try {
      if (value.isEmpty) {
        await _secure.delete(key: _cookiePref);
      } else {
        await _secure.write(key: _cookiePref, value: value);
      }
    } catch (e, st) {
      // Never fall back to plaintext: the session stays in memory only.
      AppLog.error('secure write cookies', e, st);
    }
  }

  /// Limits for data arriving from the WebView JavaScript bridge. The bridge is
  /// reachable by every frame loaded in the WebView, so its input is untrusted.
  static final _videoIdPattern = RegExp(r'^[a-zA-Z0-9_-]{1,16}$');
  static final _poTokenPattern = RegExp(r'^[A-Za-z0-9_\-=+/]{16,4096}$');
  static const _maxPlayerResponseChars = 2 * 1024 * 1024;

  static const defaultUserAgent =
      'Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  static String cookies = '';
  static String visitorData = '';
  static String userAgent = defaultUserAgent;

  static bool get isSignedIn =>
      cookies.contains('SAPISID') ||
      cookies.contains('LOGIN_INFO') ||
      cookies.contains('SSID') ||
      cookies.contains('__Secure-3PSID');

  static final ValueNotifier<bool> authState = ValueNotifier(false);
  static final ValueNotifier<bool> verificationRequired = ValueNotifier(false);
  static final ValueNotifier<bool> isWebViewInModal = ValueNotifier(false);
  static final ValueNotifier<int> loadProgress = ValueNotifier(100);
  static WebViewController? _controller;

  static final Map<String, String> _poTokenCache = {};
  static final Map<String, Completer<void>> _loadCompleters = {};
  static final Map<String, Completer<String?>> _mintCompleters = {};
  static final Map<String, String> _playerResponses = {};

  static bool get isSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static WebViewController get controller {
    if (!isSupported) {
      throw UnsupportedError('WebView is not supported on this platform');
    }
    return _controller ??= _initController();
  }

  static Completer<bool>? _refreshCompleter;

  static Future<void> init(SharedPreferences prefs) async {
    cookies = await _readSecureCookies();
    // One-time migration: older versions stored cookies in plain prefs.
    final legacy = prefs.getString(_cookiePref);
    if (legacy != null) {
      if (cookies.isEmpty && legacy.isNotEmpty) {
        cookies = legacy;
        await _writeSecureCookies(cookies);
      }
      await prefs.remove(_cookiePref);
    }
    visitorData = prefs.getString(_visitorPref) ?? '';
    userAgent = prefs.getString(_uaPref) ?? defaultUserAgent;
    authState.value = isSignedIn;
    AppLog.info(
      'browser auth init: cookies=${cookies.isNotEmpty ? "loaded (${cookies.length} chars)" : "none"} (signedIn: $isSignedIn)',
    );
    if (isSupported) {
      unawaited(refreshCookies());
    }
  }

  static Future<void> save(SharedPreferences prefs) async {
    await _writeSecureCookies(cookies);
    await prefs.remove(_cookiePref); // never keep a plaintext copy
    if (visitorData.isNotEmpty) {
      await prefs.setString(_visitorPref, visitorData);
    } else {
      await prefs.remove(_visitorPref);
    }
    if (userAgent.isNotEmpty && userAgent != defaultUserAgent) {
      await prefs.setString(_uaPref, userAgent);
    } else {
      await prefs.remove(_uaPref);
    }
  }

  static WebViewController _initController() {
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(userAgent)
      ..addJavaScriptChannel(
        'CrateBridge',
        onMessageReceived: (JavaScriptMessage msg) {
          _onBridgeMessage(msg.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) => loadProgress.value = p,
          onNavigationRequest: (NavigationRequest request) {
            final uri = Uri.tryParse(request.url);
            if (uri == null) return NavigationDecision.prevent;

            // 1. Strict Protocol Enforcement: only https is permitted
            if (uri.scheme != 'https') {
              AppLog.info('browser auth: blocked insecure scheme: ${uri.scheme}');
              return NavigationDecision.prevent;
            }

            final host = uri.host.toLowerCase();
            if (host.isEmpty) return NavigationDecision.navigate;

            // 2. HARD VETO: Block all non-YouTube Google services to prevent "jumper" attacks.
            // Under no circumstances should Gmail, Google Drive, Account Management,
            // Contacts, Payments, or Passwords be accessible from within this WebView.
            if (isRestrictedGoogleService(host)) {
              AppLog.info('browser auth: BLOCKED attempt to navigate to restricted service: $host');
              return NavigationDecision.prevent;
            }

            // 3. Strict Domain Allowlist: Only Google Authentication and YouTube domains
            if (isAllowedDomain(host)) {
              return NavigationDecision.navigate;
            }

            AppLog.info('browser auth: blocked navigation to untrusted domain: $host');
            return NavigationDecision.prevent;
          },
          onPageStarted: (url) {
            loadProgress.value = 15;
            AppLog.info('browser auth page started: ${AppLog.redactUrl(url)}');
            _checkUrl(url);
          },
          onPageFinished: (url) async {
            loadProgress.value = 100;
            AppLog.info('browser auth page finished: ${AppLog.redactUrl(url)}');
            await _onPageLoaded(url);
          },
          onWebResourceError: (error) {
            loadProgress.value = 100;
            AppLog.info('browser auth web error: ${error.description}');
          },
        ),
      );
    return c;
  }

  /// Explicitly block any Google service that holds personal/sensitive data (e.g. Gmail, Drive, Pay).
  /// This prevents the WebView from being used as a jumper/pivot to access or exploit personal Google services.
  static bool isRestrictedGoogleService(String host) {
    const blockedHosts = {
      'mail.google.com',
      'gmail.com',
      'inbox.google.com',
      'drive.google.com',
      'docs.google.com',
      'sheets.google.com',
      'slides.google.com',
      'contacts.google.com',
      'photos.google.com',
      'payments.google.com',
      'pay.google.com',
      'myaccount.google.com',
      'passwords.google.com',
      'admin.google.com',
      'play.google.com',
      'calendar.google.com',
      'messages.google.com',
      'voice.google.com',
      'keep.google.com',
    };
    if (blockedHosts.contains(host)) return true;
    for (final bh in blockedHosts) {
      if (host.endsWith('.$bh')) return true;
    }
    return false;
  }

  /// Strictly allow ONLY legitimate YouTube, Google OAuth login endpoints, and static CDNs.
  /// Prevents domain substring spoofing (e.g. google.attacker.com).
  static bool isAllowedDomain(String host) {
    // 1. YouTube official domains
    if (host == 'youtube.com' ||
        host.endsWith('.youtube.com') ||
        host == 'youtu.be' ||
        host == 'googlevideo.com' ||
        host.endsWith('.googlevideo.com') ||
        host == 'ytimg.com' ||
        host.endsWith('.ytimg.com')) {
      return true;
    }

    // 2. Google Authentication & Identity Endpoints (e.g. accounts.google.com, accounts.google.co.uk)
    if (RegExp(r'^accounts\.google\.(com|org|[a-z]{2}|co\.[a-z]{2}|com\.[a-z]{2})$').hasMatch(host)) {
      return true;
    }

    // 3. Static assets & the Google OAuth helper needed for the sign-in handshake.
    // Deliberately NOT allowed as page destinations: URL shorteners / redirectors
    // (goo.gl, g.co) and user-content hosts (*.googleusercontent.com,
    // storage.googleapis.com), which can serve attacker-controlled pages.
    if (host == 'apis.google.com' ||
        host == 'gstatic.com' ||
        host.endsWith('.gstatic.com')) {
      return true;
    }

    return false;
  }

  static void _onBridgeMessage(String raw) {
    try {
      final data = jsonDecode(raw);
      if (data is Map) {
        final type = data['type'];
        final videoId = data['videoId']?.toString() ?? '';
        // Only accept answers to a mint WE started, for a well-formed id.
        if (!_videoIdPattern.hasMatch(videoId) ||
            !_mintCompleters.containsKey(videoId)) {
          AppLog.info('browser auth: ignored unsolicited bridge message');
          return;
        }
        if (type == 'poToken') {
          final token = data['token']?.toString();
          final c = _mintCompleters.remove(videoId);
          if (token != null && _poTokenPattern.hasMatch(token)) {
            putBounded(_poTokenCache, videoId, token, max: 200);
            AppLog.info(
              'browser auth: minted poToken for $videoId (${token.length} chars)',
            );
            if (c != null && !c.isCompleted) c.complete(token);
          } else {
            if (c != null && !c.isCompleted) c.complete(null);
          }
        } else if (type == 'playerResponse') {
          final resp = data['response']?.toString();
          if (resp != null &&
              resp.isNotEmpty &&
              resp.length <= _maxPlayerResponseChars) {
            putBounded(_playerResponses, videoId, resp, max: 5);
            AppLog.info(
              'browser auth: captured playerResponse for $videoId (${resp.length} bytes)',
            );
          }
        }
      }
    } catch (e, st) {
      AppLog.error('bridge message', e, st);
    }
  }

  static void _checkUrl(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('/sorry/') ||
        lower.contains('recaptcha') ||
        lower.contains('not_a_bot')) {
      verificationRequired.value = true;
    }
  }

  static Future<void> _onPageLoaded(String url) async {
    for (final entry in _loadCompleters.entries) {
      if (url.contains(entry.key) && !entry.value.isCompleted) {
        entry.value.complete();
      }
    }

    final lower = url.toLowerCase();
    if (lower.contains('/sorry/') ||
        lower.contains('recaptcha') ||
        lower.contains('not_a_bot')) {
      verificationRequired.value = true;
      return;
    }

    try {
      final cm = WebViewCookieManager();
      final list1 = await cm.getCookies(domain: Uri.parse('https://www.youtube.com'));
      final list2 = await cm.getCookies(domain: Uri.parse('https://m.youtube.com'));
      
      // Strict allowlist of YouTube authentication cookies only (Principle of Least Privilege).
      const allowedCookieNames = {
        'LOGIN_INFO',
        'SAPISID',
        'APISID',
        'SSID',
        'HSID',
        'SID',
        '__Secure-1PSID',
        '__Secure-3PSID',
        '__Secure-1PAPISID',
        '__Secure-3PAPISID',
        'VISITOR_INFO1_LIVE',
        'PREF',
        'YSC',
        'GPS',
      };

      final map = <String, String>{};
      for (final c in [...list1, ...list2]) {
        if (allowedCookieNames.contains(c.name) || c.name.startsWith('__Secure-')) {
          map[c.name] = c.value;
        }
      }
      if (map.isNotEmpty) {
        cookies = map.entries.map((e) => '${e.key}=${e.value}').join('; ');
        AppLog.info('browser auth: harvested ${map.length} sanitized cookies');
      }

      // Only execute visitorData extraction if on a verified YouTube domain
      final uri = Uri.tryParse(url);
      if (uri != null && (uri.host == 'm.youtube.com' || uri.host == 'www.youtube.com' || uri.host == 'youtube.com')) {
        try {
          final vd = await controller.runJavaScriptReturningResult(
            "window.ytcfg ? (window.ytcfg.get('VISITOR_DATA') || '') : ''",
          );
          final vdStr = vd.toString().replaceAll('"', '').trim();
          if (vdStr.isNotEmpty && vdStr != 'null') {
            visitorData = vdStr;
          }
        } catch (_) {}
      }

      final p = await SharedPreferences.getInstance();
      await save(p);

      authState.value = isSignedIn;
      verificationRequired.value = false;
      if (_refreshCompleter != null && !_refreshCompleter!.isCompleted) {
        _refreshCompleter!.complete(true);
      }
    } catch (e, st) {
      AppLog.error('harvest cookies', e, st);
      if (_refreshCompleter != null && !_refreshCompleter!.isCompleted) {
        _refreshCompleter!.complete(false);
      }
    }
  }

  static String? poTokenFor(String videoId) => _poTokenCache[videoId];
  static String? playerResponseFor(String videoId) => _playerResponses[videoId];

  /// Mint or retrieve a cached PO token for [videoId].
  static Future<String?> getOrFetchPoToken(String videoId) async {
    if (!isSupported) return null;
    final safeId = videoId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    if (safeId.isEmpty) return null;
    if (_poTokenCache.containsKey(safeId)) {
      return _poTokenCache[safeId];
    }

    // 1. Try minting from current page if WebPoClient is already ready
    var token = await _tryMintToken(safeId);
    if (token != null && token.isNotEmpty) {
      putBounded(_poTokenCache, safeId, token, max: 200);
      return token;
    }

    // 2. If not ready, load the embed player page for this video
    try {
      final completer = Completer<void>();
      _loadCompleters[safeId] = completer;
      controller.loadRequest(
        Uri.parse('https://www.youtube.com/embed/$safeId?autoplay=0'),
      );
      await completer.future.timeout(
        const Duration(seconds: 8),
        onTimeout: () => null,
      );
      _loadCompleters.remove(safeId);

      // Try minting again once the embed player script is loaded
      token = await _tryMintToken(safeId);
      if (token != null && token.isNotEmpty) {
        putBounded(_poTokenCache, safeId, token, max: 200);
        return token;
      }
    } catch (e, st) {
      AppLog.error('getOrFetchPoToken load $safeId', e, st);
    }
    return null;
  }

  static Future<void> refreshPoToken(String videoId) async {
    final safeId = videoId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    _poTokenCache.remove(safeId);
    await getOrFetchPoToken(safeId);
  }

  static Future<String?> _tryMintToken(String videoId) async {
    final safeId = videoId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    if (safeId.isEmpty) return null;
    final completer = Completer<String?>();
    _mintCompleters[safeId] = completer;

    final js = '''
      (async function() {
        try {
          for (let i = 0; i < 20; i++) {
            for (const target of [window, window.top || window]) {
              try {
                for (const k of Object.getOwnPropertyNames(target)) {
                  try {
                    const wpc = target[k]?.bevasrs?.wpc;
                    if (typeof wpc === 'function') {
                      const client = await wpc();
                      const token = await client.mws({ c: "$safeId", mc: false, me: false });
                      if (token && token !== 'backoff') {
                        CrateBridge.postMessage(JSON.stringify({ type: 'poToken', videoId: "$safeId", token: String(token) }));
                        return;
                      }
                    }
                  } catch(_) {}
                }
              } catch(_) {}
            }
            try {
              const mp = document.getElementById('movie_player') || document.querySelector('#movie_player');
              if (mp && typeof mp.getPlayerResponse === 'function') {
                const pr = mp.getPlayerResponse();
                if (pr && pr.streamingData) {
                  CrateBridge.postMessage(JSON.stringify({ type: 'playerResponse', videoId: "$safeId", response: JSON.stringify(pr) }));
                }
              }
            } catch(_) {}
            await new Promise(r => setTimeout(r, 250));
          }
        } catch(e) {}
        CrateBridge.postMessage(JSON.stringify({ type: 'poToken', videoId: "$safeId", token: null }));
      })()
    ''';

    try {
      await controller.runJavaScript(js);
    } catch (e, st) {
      AppLog.error('runJavaScript mint $safeId', e, st);
      _mintCompleters.remove(safeId);
      return null;
    }

    return await completer.future.timeout(
      const Duration(seconds: 6),
      onTimeout: () {
        _mintCompleters.remove(safeId);
        return null;
      },
    );
  }

  /// Triggers a background refresh of YouTube session cookies using the WebView.
  static Future<bool> refreshCookies() async {
    if (!isSupported) return false;
    if (_refreshCompleter != null && !_refreshCompleter!.isCompleted) {
      return _refreshCompleter!.future;
    }
    _refreshCompleter = Completer<bool>();
    try {
      controller.loadRequest(Uri.parse('https://www.youtube.com/?themeRefresh=1'));
      return await _refreshCompleter!.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => false,
      );
    } catch (e, st) {
      AppLog.error('refreshCookies', e, st);
      return false;
    }
  }

  /// Opens the official Google Account sign-in page in an in-app bottom sheet.
  static Future<void> showSignInSheet(BuildContext context) async {
    if (!isSupported) return;
    isWebViewInModal.value = true;
    // Allow a tick for the offstage WebView to unmount cleanly
    await Future<void>.delayed(const Duration(milliseconds: 60));
    if (!context.mounted) return;

    controller.loadRequest(
      Uri.parse(
        'https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fm.youtube.com%2F',
      ),
    );

    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        enableDrag: false,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (ctx) => _SignInModal(controller: controller),
      );
    } finally {
      isWebViewInModal.value = false;
      await refreshCookies();
      authState.value = isSignedIn;
    }
  }

  /// Signs out by completely wiping cookies, web storage, cache, and session tokens.
  static Future<void> signOut() async {
    if (isSupported) {
      try {
        final cm = WebViewCookieManager();
        await cm.clearCookies();
      } catch (_) {}
      try {
        await controller.clearLocalStorage();
      } catch (_) {}
      try {
        await controller.clearCache();
      } catch (_) {}
      try {
        await controller.loadRequest(Uri.parse('about:blank'));
      } catch (_) {}
    }
    cookies = '';
    visitorData = '';
    _poTokenCache.clear();
    _playerResponses.clear();
    authState.value = false;
    final p = await SharedPreferences.getInstance();
    await _writeSecureCookies('');
    await p.remove(_cookiePref);
    await p.remove(_visitorPref);
    await p.remove(_uaPref);
    AppLog.info('browser auth: user signed out, all session state wiped');
  }
}

class _SignInModal extends StatefulWidget {
  final WebViewController controller;
  const _SignInModal({required this.controller});

  @override
  State<_SignInModal> createState() => _SignInModalState();
}

class _SignInModalState extends State<_SignInModal> {
  @override
  void initState() {
    super.initState();
    BrowserAuth.authState.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    BrowserAuth.authState.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (BrowserAuth.isSignedIn && mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.88,
        child: Column(
          children: [
            AppBar(
              title: Text(tr('Google Account')),
              leading: IconButton(
                tooltip: tr('Close'),
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
              actions: [
                IconButton(
                  tooltip: tr('Refresh'),
                  icon: const Icon(Icons.refresh),
                  onPressed: () => widget.controller.reload(),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  tooltip: tr('More options'),
                  onSelected: (val) {
                    if (val == 'yt') {
                      widget.controller.loadRequest(
                        Uri.parse('https://m.youtube.com/signin'),
                      );
                    } else if (val == 'google') {
                      widget.controller.loadRequest(
                        Uri.parse(
                          'https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fm.youtube.com%2F',
                        ),
                      );
                    }
                  },
                  itemBuilder: (ctx) => [
                    PopupMenuItem(
                      value: 'google',
                      child: Text(tr('Sign in with Google')),
                    ),
                    PopupMenuItem(
                      value: 'yt',
                      child: Text(tr('Sign in via YouTube Mobile')),
                    ),
                  ],
                ),
              ],
            ),
            ValueListenableBuilder<int>(
              valueListenable: BrowserAuth.loadProgress,
              builder: (_, p, _) => p < 100
                  ? LinearProgressIndicator(value: p / 100, minHeight: 3)
                  : const SizedBox(height: 3),
            ),
            Expanded(
              child: WebViewWidget(controller: widget.controller),
            ),
          ],
        ),
      ),
    );
  }
}

/// A [YoutubeHttpClient] that injects harvested browser cookies, visitorData and poTokens.
class AuthenticatedYoutubeHttpClient extends YoutubeHttpClient {
  @override
  Map<String, String> get headers {
    final base = Map<String, String>.from(super.headers);
    if (BrowserAuth.cookies.isNotEmpty) {
      base['cookie'] = BrowserAuth.cookies;
    }
    return base;
  }

  @override
  String? get visitorData =>
      BrowserAuth.visitorData.isNotEmpty ? BrowserAuth.visitorData : null;

  @override
  String? getPoToken(String videoId) => BrowserAuth.poTokenFor(videoId);
}
