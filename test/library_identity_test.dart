import 'dart:io';

import 'package:crate/models/track.dart';
import 'package:crate/state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late AppState app;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('wax_identity_');
    app = AppState()..dir = dir.path;
  });
  tearDown(() async => dir.delete(recursive: true));

  test('library scan keeps different artists with the same title', () async {
    await File('${dir.path}/Artist A - Lucky.m4a').writeAsBytes([0]);
    await File('${dir.path}/Artist B - Lucky.m4a').writeAsBytes([0]);
    await app.scanLocalStorage(force: true);
    expect(app.libraryTracks.length, 2);
  });
  test('download matching respects artist and version', () async {
    await File('${dir.path}/Two Door Cinema Club - Lucky.m4a')
        .writeAsBytes([0]);
    await app.scanLocalStorage(force: true);
    expect(
      app.inLibrary(
        Track('abcdefghijk', 'Lucky', 'Another Artist - Topic', '', null),
      ),
      isFalse,
    );
    expect(
      app.inLibrary(
        Track(
          'abcdefghijl',
          'Lucky (Edit - Official Audio)',
          'Two Door Cinema Club - Topic',
          '',
          null,
        ),
      ),
      isFalse,
    );
    expect(
      app.inLibrary(
        Track(
          'abcdefghijm',
          'Lucky (Official Audio)',
          'Two Door Cinema Club - Topic',
          '',
          null,
        ),
      ),
      isTrue,
    );
  });
  test(
    'title-only files can still be found when no artist is available',
    () async {
      await File('${dir.path}/Lucky.m4a').writeAsBytes([0]);
      await app.scanLocalStorage(force: true);
      expect(
        app.inLibrary(
          Track(
            'abcdefghijk',
            'Lucky',
            'Two Door Cinema Club - Topic',
            '',
            null,
          ),
        ),
        isTrue,
      );
    },
  );
  test(
    'metadata artist is respected when filename contains only title',
    () async {
      final path = '${dir.path}/Lucky.m4a';
      await File(path).writeAsBytes([0]);
      const channel = MethodChannel('crate/media');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'supported' || call.method == 'canRead') return true;
        if (call.method == 'listDetails') {
          return [
            {
              'path': path,
              'displayName': 'Lucky.m4a',
              'title': 'Lucky',
              'artist': 'Artist A',
            },
          ];
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await app.scanLocalStorage(force: true);
      expect(
        app.inLibrary(
          Track('abcdefghijk', 'Lucky', 'Artist B - Topic', '', null),
        ),
        isFalse,
      );
    },
  );
  test(
    'removing an unattributed library entry clears its title match',
    () async {
      await File('${dir.path}/Lucky.m4a').writeAsBytes([0]);
      await app.scanLocalStorage(force: true);
      final local = app.libraryTracks.single;
      app.downloaded.remove(local.id);
      app.dir = '${dir.path}/missing';
      expect(await app.deleteFromLibrary(local), isTrue);
      expect(
        app.inLibrary(
          Track('abcdefghijk', 'Lucky', 'Artist - Topic', '', null),
        ),
        isFalse,
      );
    },
  );
  test(
    'different Cyrillic titles by the same artist remain distinct',
    () async {
      await File('${dir.path}/Artist - Привет.m4a').writeAsBytes([0]);
      await app.scanLocalStorage(force: true);
      expect(
        app.inLibrary(Track('abcdefghijk', 'Пока', 'Artist - Topic', '', null)),
        isFalse,
      );
      expect(
        app.inLibrary(
          Track('abcdefghijl', 'Привет', 'Artist - Topic', '', null),
        ),
        isTrue,
      );
    },
  );
  test('titles without letters do not collapse to just the artist', () async {
    await File('${dir.path}/Artist - 🎵.m4a').writeAsBytes([0]);
    await app.scanLocalStorage(force: true);
    expect(
      app.inLibrary(Track('abcdefghijk', '🎶', 'Artist - Topic', '', null)),
      isFalse,
    );
    expect(
      app.inLibrary(Track('abcdefghijl', 'Artist - 🎶', 'Artist', '', null)),
      isFalse,
    );
  });
}
