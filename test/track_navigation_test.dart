import 'package:crate/models/track.dart';
import 'package:crate/state.dart';
import 'package:crate/widgets/track_actions_sheet.dart';
import 'package:crate/widgets/track_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('track menus use app navigation when opened from the library', (
    tester,
  ) async {
    final track = Track(
      'abcdefghijk',
      'Song',
      'Artist',
      '',
      null,
      album: 'Album',
    );
    final app = AppState();
    Track? artist;
    Track? album;
    await tester.pumpWidget(
      MaterialApp(
        home: TrackNavigation(
          onArtist: (t) => artist = t,
          onAlbum: (t) => album = t,
          child: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    TrackActionsSheet.show(context, track: track, app: app),
                child: const Text('Open menu'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Go to artist: Artist'));
    await tester.pumpAndSettle();
    expect(artist?.id, track.id);
    expect(artist?.tagArtist, 'Artist');
    await tester.tap(find.text('Open menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Go to album: Album'));
    await tester.pumpAndSettle();
    expect(album?.album, 'Album');
  });
}
