import 'package:crate/models/track.dart';
import 'package:crate/widgets/track_credits.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('artist and album can be opened without browse IDs', (
    tester,
  ) async {
    String? artistId;
    String? albumId;
    final track = Track(
      'abcdefghijk',
      'Song',
      'Artist - Topic',
      '',
      null,
      album: 'Album',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TrackCredits(
            track: track,
            onOpenArtist: (id, name) {
              artistId = id;
            },
            onOpenAlbum: (id, title) {
              albumId = id;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Artist'));
    await tester.tap(find.text('Album'));
    expect(artistId, '');
    expect(albumId, '');
  });
}
