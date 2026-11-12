import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ndef_record/ndef_record.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'constants.dart';
import 'log.dart';
import 'models/track.dart';
import 'models/user_playlist.dart';
import 'strings.dart';
import 'widgets/app_snackbar.dart';

/// Collects decompressed bytes but aborts as soon as [limit] is exceeded.
class _LimitedSink implements Sink<List<int>> {
  _LimitedSink(this._buffer, this._limit);
  final BytesBuilder _buffer;
  final int _limit;
  int _total = 0;

  @override
  void add(List<int> chunk) {
    _total += chunk.length;
    if (_total > _limit) {
      throw const FormatException(
        'Decompressed payload exceeds maximum security limit (512 KB)',
      );
    }
    _buffer.add(chunk);
  }

  @override
  void close() {}
}

class PlaylistSharingService {
  static bool _isNfcActive = false;
  static Object? _nfcOwner;
  static Object? _nfcLastStart;

  /// Maximum allowed encoded string length (64 KB) to avoid memory DOS
  static const int maxEncodedLength = 65536;

  /// Maximum allowed decompressed payload size (512 KB) to prevent zip bomb attacks
  static const int maxDecompressedBytes = 524288;

  /// Maximum tracks parsed from a single shared playlist
  static const int maxTracksPerPlaylist = 1000;

  /// Strict pattern for YouTube video IDs: 10 to 16 alphanumeric characters, dashes, and underscores
  static final _validVideoIdPattern = RegExp(r'^[a-zA-Z0-9_-]{10,16}$');

  /// Validates that an image thumbnail URL strictly belongs to authentic YouTube CDN domains
  /// to prevent SSRF, IP leakage, and local network scanning.
  static bool isTrustedThumbUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || !uri.hasAuthority) return false;
    final host = uri.host.toLowerCase();
    return host == 'i.ytimg.com' ||
        host == 'ytimg.com' ||
        host.endsWith('.ytimg.com') ||
        host == 'lh3.googleusercontent.com' ||
        host.endsWith('.googleusercontent.com') ||
        host.endsWith('.ggpht.com');
  }

  /// Encodes a [UserPlaylist] into a compact, compressed URI suitable for QR codes and NFC.
  static String encodePlaylist(UserPlaylist pl, {bool withThumbs = true}) {
    final trackList = pl.tracks.take(maxTracksPerPlaylist).map((t) => {
      'i': t.id,
      't': t.title.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ' ').trim(),
      'a': t.author.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ' ').trim(),
      if (withThumbs && t.thumb.isNotEmpty && isTrustedThumbUrl(t.thumb)) 'm': t.thumb,
      if (t.duration != null && t.duration!.inSeconds > 0 && t.duration!.inSeconds <= 86400)
        'd': t.duration!.inSeconds,
    }).toList();

    final cleanTitle = pl.title.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ' ').trim();
    final map = {
      'v': 1,
      'title': cleanTitle.length > 100 ? cleanTitle.substring(0, 100) : cleanTitle,
      'tracks': trackList,
    };

    final jsonStr = jsonEncode(map);
    final compressed = zlib.encode(utf8.encode(jsonStr));
    final b64 = base64Url.encode(compressed);
    return 'wax://playlist?data=$b64';
  }

  /// Decodes and validates a shared URI or data string into a [UserPlaylist].
  /// Employs strict bounds, zip-bomb protection, SSRF prevention, and character sanitization.
  static UserPlaylist? decodePlaylist(String raw) {
    try {
      String dataStr = raw.trim();
      if (dataStr.isEmpty || dataStr.length > maxEncodedLength) return null;

      if (dataStr.contains('data=')) {
        final uri = Uri.tryParse(dataStr);
        final param = uri?.queryParameters['data'];
        if (param != null && param.isNotEmpty) {
          dataStr = param;
        } else {
          final idx = dataStr.indexOf('data=');
          dataStr = dataStr.substring(idx + 5).split('&').first;
        }
      }

      if (dataStr.isEmpty || dataStr.length > maxEncodedLength) return null;

      // Decode Base64 with length validation
      final compressed = base64Url.decode(base64.normalize(dataStr));
      if (compressed.isEmpty || compressed.length > maxEncodedLength) return null;

      // Safe chunked decompression to guard against decompression bombs (zip bombs)
      // The limit is checked on every chunk as it is produced. (A
      // ChunkedConversionSink.withCallback only fires once at close(), i.e.
      // after the whole bomb has already been inflated into memory.)
      final buffer = BytesBuilder(copy: false);
      final sink = _LimitedSink(buffer, maxDecompressedBytes);
      final zlibSink = zlib.decoder.startChunkedConversion(sink);
      zlibSink.add(compressed);
      zlibSink.close();

      final jsonStr = utf8.decode(buffer.takeBytes());
      final map = jsonDecode(jsonStr);

      if (map is! Map) return null;

      // Validate and sanitize playlist title
      final rawTitle = map['title']
              ?.toString()
              .replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ' ')
              .trim() ??
          'Shared Playlist';
      var title = rawTitle.isNotEmpty ? rawTitle : 'Shared Playlist';
      if (title.length > 100) title = title.substring(0, 100);

      // Validate tracks list with strict bounded capacity
      final rawTracks = map['tracks'];
      final tracks = <Track>[];

      if (rawTracks is List) {
        for (final item in rawTracks.take(maxTracksPerPlaylist)) {
          if (item is Map) {
            final rawId = item['i']?.toString().trim() ?? '';
            // Strict video ID format validation
            if (!_validVideoIdPattern.hasMatch(rawId)) continue;
            final id = rawId;

            final rawTTitle = item['t']
                    ?.toString()
                    .replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ' ')
                    .trim() ??
                '';
            final tTitle = rawTTitle.length > 200 ? rawTTitle.substring(0, 200) : rawTTitle;

            final rawAuthor = item['a']
                    ?.toString()
                    .replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ' ')
                    .trim() ??
                '';
            final author = rawAuthor.length > 100 ? rawAuthor.substring(0, 100) : rawAuthor;

            // SSRF prevention: Verify thumbnail domain strictly
            final rawThumb = item['m']?.toString().trim() ?? '';
            final thumb = (rawThumb.isNotEmpty && isTrustedThumbUrl(rawThumb))
                ? rawThumb
                : 'https://i.ytimg.com/vi/$id/hqdefault.jpg';

            final rawDur = item['d'] is int
                ? item['d'] as int
                : int.tryParse(item['d']?.toString() ?? '');
            final durSec = (rawDur != null && rawDur > 0 && rawDur <= 86400) ? rawDur : null;

            if (tTitle.isNotEmpty) {
              tracks.add(Track(
                id,
                tTitle,
                author,
                thumb,
                durSec != null ? Duration(seconds: durSec) : null,
              ));
            }
          }
        }
      }

      final id = 'shared_${DateTime.now().millisecondsSinceEpoch}';
      return UserPlaylist(
        id: id,
        title: title,
        tracks: tracks,
        createdAt: DateTime.now(),
      );
    } catch (e, st) {
      AppLog.error('decodePlaylist', e, st);
      return null;
    }
  }

  // ---------------------------------------------------------------------
  // NFC phone-to-phone sharing
  //
  // A phone cannot "write" to another phone the way it writes to a sticker, and
  // Android Beam no longer exists. So the SENDER emulates an NFC Forum Type 4
  // tag (Host Card Emulation, native service WaxNdefService) that serves one
  // NDEF URI record holding the playlist link, and the RECEIVER simply reads it
  // like any tag. The native half lives in android_patch/nfc_hce/.
  // ---------------------------------------------------------------------
  static const _nfcChannel = MethodChannel('crate/nfc');

  /// One NDEF message containing a single well-known URI record for [uri].
  /// Uses the long-record form (no SR flag) because playlists exceed 255 bytes.
  static Uint8List buildNdefUriMessage(String uri) {
    final uriBytes = utf8.encode(uri);
    final payloadLen = 1 + uriBytes.length; // prefix byte 0x00 = no abbreviation
    final out = BytesBuilder(copy: false)
      ..addByte(0xC1) // MB | ME | TNF=well-known (SR cleared: 4-byte length)
      ..addByte(0x01) // type length
      ..addByte((payloadLen >> 24) & 0xFF)
      ..addByte((payloadLen >> 16) & 0xFF)
      ..addByte((payloadLen >> 8) & 0xFF)
      ..addByte(payloadLen & 0xFF)
      ..addByte(0x55) // type 'U'
      ..addByte(0x00)
      ..add(uriBytes);
    return out.toBytes();
  }

  /// Why the last [startNfcBroadcast] did not start (null if it did). One of:
  /// no_bridge, no_nfc, off, no_hce, unavailable, too_large, error.
  static String? nfcFailure;

  /// Makes this phone present [pl] as an NFC tag until [stopNfc] is called.
  /// Returns false if it could not start; [nfcFailure] then says why.
  /// [onSharedSuccess] fires once the other phone has read the whole message.
  static Future<bool> startNfcBroadcast(
    UserPlaylist pl, {
    VoidCallback? onSharedSuccess,
    Object? owner,
  }) async {
    final session = owner ?? Object();
    _nfcOwner = session;
    nfcFailure = null;
    try {
      // No thumbnail URLs over NFC: a shorter message means a shorter tap, and a
      // long one fails if the phones drift apart mid-transfer.
      final message = buildNdefUriMessage(encodePlaylist(pl, withThumbs: false));
      AppLog.info('NFC share: ${message.length} bytes for ${pl.tracks.length} tracks');
      // The Type 4 tag length field is 16 bits.
      if (message.length > 65000) {
        AppLog.info('NFC share: playlist too large (${message.length} bytes)');
        nfcFailure = 'too_large';
        return false;
      }
      _nfcChannel.setMethodCallHandler((call) async {
        if (call.method == 'delivered' && identical(_nfcOwner, session)) {
          HapticFeedback.heavyImpact();
          AppLog.info('NFC playlist share delivered');
          onSharedSuccess?.call();
        }
      });
      final ok = await _nfcChannel.invokeMethod<bool>('isAvailable') ?? false;
      if (!identical(_nfcOwner, session)) return false;
      if (!ok) {
        // Newer native code can say why; older code only answers true/false.
        String why = 'unavailable';
        try {
          why = await _nfcChannel.invokeMethod<String>('status') ?? 'unavailable';
        } on MissingPluginException {
          // old bridge without 'status'
        }
        if (!identical(_nfcOwner, session)) return false;
        AppLog.info('NFC share: not available ($why)');
        nfcFailure = why;
        return false;
      }
      final previousStart = _nfcLastStart;
      _nfcLastStart = session;
      final started = await _nfcChannel.invokeMethod<bool>('startShare', {'ndef': message}) ?? false;
      if (!identical(_nfcOwner, session)) {
        // A stale start may still be the last native start, even if a newer
        // sheet is open but could not start sharing.
        if (started && identical(_nfcLastStart, session)) {
          _nfcLastStart = null;
          _isNfcActive = false;
          await _stopNativeNfc();
        }
        return false;
      }
      _isNfcActive = started;
      if (!started) {
        if (identical(_nfcLastStart, session)) _nfcLastStart = null;
        if (previousStart != null) await _stopNativeNfc();
        nfcFailure = 'error';
      }
      return started;
    } on MissingPluginException {
      AppLog.info('NFC share: native WaxNdefService bridge not installed (see android_patch/nfc_hce)');
      if (identical(_nfcOwner, session)) nfcFailure = 'no_bridge';
      return false;
    } catch (e, st) {
      AppLog.error('startNfcBroadcast', e, st);
      if (identical(_nfcOwner, session)) nfcFailure = 'error';
      return false;
    }
  }

  /// Short user-facing explanation for [nfcFailure].
  static String nfcFailureText() {
    switch (nfcFailure) {
      case 'no_bridge':
        return tr('NFC sharing is not installed in this build. Scan the QR code');
      case 'no_nfc':
        return tr('This phone has no NFC. Scan the QR code');
      case 'off':
        return tr('NFC is off. Turn it on in Settings, or scan the QR code');
      case 'no_hce':
        return tr("This phone can't act as an NFC tag. Scan the QR code");
      case 'too_large':
        return tr('Playlist too large for NFC. Scan the QR code');
      default:
        return tr('NFC could not start. Scan the QR code');
    }
  }

  /// Stops presenting the playlist over NFC.
  static Future<void> stopNfc({Object? owner}) async {
    if (owner != null && !identical(_nfcOwner, owner)) return;
    _nfcOwner = null;
    if (!_isNfcActive) return;
    _isNfcActive = false;
    _nfcLastStart = null;
    await _stopNativeNfc();
  }

  static Future<void> _stopNativeNfc() async {
    try {
      await _nfcChannel.invokeMethod<bool>('stopShare');
    } catch (_) {}
  }

  /// Receiver side: reads a shared playlist link from the other phone (or
  /// from an NFC tag). [onLink] gets the raw `wax://playlist?...` string.
  /// Returns false if NFC is unavailable.
  static Future<bool> startNfcReceive({
    required void Function(String link) onLink,
    void Function(String message)? onProblem,
  }) async {
    try {
      final availability = await NfcManager.instance.checkAvailability();
      if (availability != NfcAvailability.enabled) {
        AppLog.info('NFC receive: not enabled: $availability');
        return false;
      }
      await NfcManager.instance.startSession(
        pollingOptions: {NfcPollingOption.iso14443},
        onDiscovered: (NfcTag tag) async {
          try {
            final ndef = NdefAndroid.from(tag);
            AppLog.info('NFC receive: tag detected, ndef=${ndef != null}, cached=${ndef?.cachedNdefMessage != null}');
            // The cached copy can be empty (e.g. the emulating phone answered after
            // Android's first NDEF check), so read the tag actively as a fallback.
            final msg = ndef == null ? null : (ndef.cachedNdefMessage ?? await ndef.getNdefMessage());
            AppLog.info('NFC receive: ${msg?.records.length ?? 0} record(s)');
            if (msg == null) {
              onProblem?.call('no-ndef');
              return;
            }
            for (final r in msg.records) {
              if (r.typeNameFormat == TypeNameFormat.wellKnown &&
                  r.type.length == 1 &&
                  r.type[0] == 0x55 &&
                  r.payload.length > 1 &&
                  r.payload[0] == 0x00) {
                final link = utf8.decode(r.payload.sublist(1), allowMalformed: true);
                if (link.startsWith('wax://playlist')) {
                  HapticFeedback.heavyImpact();
                  onLink(link);
                  return;
                }
              }
            }
            onProblem?.call('not-wax');
          } catch (e, st) {
            AppLog.error('nfc read error', e, st);
            onProblem?.call('read-error');
          }
        },
      );
      return true;
    } catch (e, st) {
      AppLog.error('startNfcReceive', e, st);
      return false;
    }
  }

  static Future<void> stopNfcReceive() async {
    try {
      await NfcManager.instance.stopSession();
    } catch (_) {}
  }
}

/// Modal bottom sheet displaying the playlist's QR code and active NFC broadcast.
class SharePlaylistSheet extends StatefulWidget {
  final UserPlaylist playlist;

  const SharePlaylistSheet({super.key, required this.playlist});

  static Future<void> show(BuildContext context, UserPlaylist playlist) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SharePlaylistSheet(playlist: playlist),
    );
  }

  @override
  State<SharePlaylistSheet> createState() => _SharePlaylistSheetState();
}

class _SharePlaylistSheetState extends State<SharePlaylistSheet> {
  late final String _shareData;
  final Object _nfcOwner = Object();
  bool _nfcSupported = false;
  bool _nfcTransferred = false;

  @override
  void initState() {
    super.initState();
    _shareData = PlaylistSharingService.encodePlaylist(widget.playlist);
    _initNfc();
  }

  void _initNfc() async {
    final ok = await PlaylistSharingService.startNfcBroadcast(
      widget.playlist,
      owner: _nfcOwner,
      onSharedSuccess: () {
        if (mounted) {
          setState(() => _nfcTransferred = true);
          showAppSnackBar(
            context,
            tr('Playlist shared via NFC tap!'),
            duration: const Duration(seconds: 3),
            icon: const Icon(Icons.nfc_rounded, size: 18),
          );
        }
      },
    );
    if (!mounted) return;
    setState(() => _nfcSupported = ok);
  }

  @override
  void dispose() {
    PlaylistSharingService.stopNfc(owner: _nfcOwner);
    super.dispose();
  }

  void _copyToClipboard() {
    Clipboard.setData(ClipboardData(text: _shareData));
    HapticFeedback.lightImpact();
    showAppSnackBar(
      context,
      tr('Playlist link copied to clipboard'),
      duration: const Duration(seconds: 2),
      icon: const Icon(Icons.link_rounded, size: 18),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = sheetBgColor(context);

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.88,
      ),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Title & Info
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: accent(context).withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.qr_code_2_rounded, color: accent(context), size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tr('Share Playlist'),
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                        ),
                        Text(
                          '${widget.playlist.title} · ${trp('{n} songs', {'n': widget.playlist.tracks.length})}',
                          style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    tooltip: tr('Close'),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // QR Code Card (High Contrast White Container)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: QrImageView(
                  data: _shareData,
                  version: QrVersions.auto,
                  size: 210,
                  backgroundColor: Colors.white,
                  eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: Colors.black87,
                  ),
                  dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: Colors.black87,
                  ),
                ),
              ),
              const SizedBox(height: 18),

              // NFC Status Pill
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: _nfcTransferred
                      ? okColor(context).withValues(alpha: 0.15)
                      : (_nfcSupported
                          ? accent(context).withValues(alpha: 0.15)
                          : Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5)),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _nfcTransferred
                        ? okColor(context)
                        : (_nfcSupported ? accent(context) : Colors.transparent),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _nfcTransferred
                          ? Icons.check_circle_rounded
                          : (_nfcSupported ? Icons.nfc_rounded : Icons.nfc_outlined),
                      size: 18,
                      color: _nfcTransferred
                          ? okColor(context)
                          : (_nfcSupported ? accent(context) : Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _nfcTransferred
                            ? tr('Transferred via NFC!')
                            : (_nfcSupported
                                ? tr('NFC Active: Tap another phone to share')
                                : (PlaylistSharingService.nfcFailure != null
                                    ? PlaylistSharingService.nfcFailureText()
                                    : tr('Scan QR code with another phone'))),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _nfcTransferred
                              ? okColor(context)
                              : (_nfcSupported ? accent(context) : Theme.of(context).colorScheme.onSurfaceVariant),
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),

              // Action Buttons
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: Text(tr('Copy Link')),
                      onPressed: _copyToClipboard,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: Text(tr('Done')),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
