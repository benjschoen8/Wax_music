import 'package:crate/playlist_search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only opens an album with matching title and artist', () {
    const wrongTitle = PlaylistHit(
      id: 'a',
      title: 'Other',
      author: 'Artist',
      isVerified: true,
      videoCount: 0,
      thumbnail: '',
      isAlbum: true,
    );
    const wrongArtist = PlaylistHit(
      id: 'b',
      title: 'Album',
      author: 'Another Artist',
      isVerified: true,
      videoCount: 0,
      thumbnail: '',
      isAlbum: true,
    );
    const right = PlaylistHit(
      id: 'c',
      title: 'Album',
      author: 'Artist',
      isVerified: true,
      videoCount: 0,
      thumbnail: '',
      isAlbum: true,
    );
    expect(
      PlaylistSearchService.matchAlbum(
        [wrongTitle, wrongArtist],
        'Album',
        'Artist',
      ),
      isNull,
    );
    expect(
      PlaylistSearchService.matchAlbum(
        [wrongTitle, wrongArtist, right],
        'Album',
        'Artist',
      )?.id,
      'c',
    );
  });
}
