import 'package:flutter_test/flutter_test.dart';
import 'package:crate/files.dart';
import 'package:crate/models/track.dart';
import 'package:crate/log.dart';
import 'package:crate/playlist_sharing.dart';
import 'package:crate/models/user_playlist.dart';
import 'package:crate/strings.dart';
import 'dart:convert';
import 'dart:io';

void main() {
  group('isSafeAudioPath', () {
    test('accepts audio under shared storage', () {
      expect(isSafeAudioPath('/storage/emulated/0/Music/a - b.m4a'), isTrue);
      expect(isSafeAudioPath('/sdcard/Music/x.MP3'), isTrue);
    });
    test('rejects traversal, non-audio and other roots', () {
      expect(isSafeAudioPath('/storage/emulated/0/Music/../../x.m4a'), isFalse);
      expect(isSafeAudioPath('/storage/emulated/0/Music/notes.txt'), isFalse);
      expect(isSafeAudioPath('/data/data/app/shared_prefs/x.m4a'), isFalse);
      expect(isSafeAudioPath('/storage/emulated/0/Music/noext'), isFalse);
      expect(isSafeAudioPath('/storage/emulated/0/Music/.m4a'), isFalse);
      expect(isSafeAudioPath('relative/x.m4a'), isFalse);
    });
  });

  group('Track.sanitizeThumb', () {
    test('keeps trusted https image hosts and upgrades http', () {
      expect(Track.sanitizeThumb('https://i.ytimg.com/vi/abc/hqdefault.jpg'),
          'https://i.ytimg.com/vi/abc/hqdefault.jpg');
      expect(Track.sanitizeThumb('http://i.ytimg.com/vi/abc/hqdefault.jpg'),
          startsWith('https://'));
    });
    test('drops untrusted hosts and look-alikes', () {
      expect(Track.sanitizeThumb('https://evil.example/x.jpg'), '');
      expect(Track.sanitizeThumb('https://i.ytimg.com.evil.example/x.jpg'), '');
      expect(Track.sanitizeThumb('https://user@i.ytimg.com/x.jpg'), '');
    });
    test('leaves local paths alone', () {
      expect(Track.sanitizeThumb('/storage/emulated/0/Music/a.jpg'),
          '/storage/emulated/0/Music/a.jpg');
    });
  });

  group('AppLog', () {
    test('redactUrl drops query and fragment', () {
      expect(AppLog.redactUrl('https://accounts.google.com/x/y?TL=secret#f'),
          'https://accounts.google.com/x/y');
    });
    test('cookies are redacted', () {
      AppLog.clear();
      AppLog.info('cookie: SAPISID=abc123; __Secure-3PSID=zzz');
      expect(AppLog.text, isNot(contains('abc123')));
      expect(AppLog.text, isNot(contains('zzz')));
    });
  });

  group('isAllowedSaveDir', () {
    test('only shared storage', () {
      expect(isAllowedSaveDir('/storage/emulated/0/Music'), isTrue);
      expect(isAllowedSaveDir('/sdcard/Download'), isTrue);
      expect(isAllowedSaveDir('/data/user/0/x'), isFalse);
      expect(isAllowedSaveDir('/storage/emulated/0/../../data'), isFalse);
      expect(isAllowedSaveDir('/'), isFalse);
    });
  });

  group('playlist import', () {
    test('round-trips a normal playlist', () {
      final pl = UserPlaylist(
        id: 'x',
        title: 'Mix',
        createdAt: DateTime.now(),
        tracks: [Track('abcdefghijk', 'Song', 'Artist', '', null)],
      );
      final back = PlaylistSharingService.decodePlaylist(
          PlaylistSharingService.encodePlaylist(pl));
      expect(back?.tracks.length, 1);
    });
    test('decompression bomb is rejected', () {
      final bomb = zlib.encode(utf8.encode('{"title":"${'A' * (8 * 1024 * 1024)}"}'));
      final raw = 'wax://playlist?data=${base64Url.encode(bomb)}';
      expect(raw.length < 65536, isTrue);
      expect(PlaylistSharingService.decodePlaylist(raw), isNull);
    });
  });

  test('trp does not re-expand placeholders inside values', () {
    expect(trp('{a} and {b}', {'a': '{b}', 'b': 'X'}), '{b} and X');
  });
}
