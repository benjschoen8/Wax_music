import 'package:crate/models/track.dart';
import 'package:crate/ytm_search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'album metadata uses the same recording instead of the first result',
    () {
      final track = Track(
        'abcdefghijk',
        'Lucky',
        'Artist - Topic',
        '',
        const Duration(seconds: 200),
      );
      final wrong = Track(
        'abcdefghijl',
        'Lucky',
        'Another - Topic',
        '',
        const Duration(seconds: 200),
        album: 'Wrong',
      );
      final same = Track(
        'abcdefghijk',
        'Lucky',
        'Artist - Topic',
        '',
        const Duration(seconds: 200),
        album: 'Right',
        albumBrowseId: 'MPREb_right',
      );
      expect(YtmSearchService.findAlbumTrack(track, [wrong]), isNull);
      expect(
        YtmSearchService.findAlbumTrack(track, [wrong, same])?.album,
        'Right',
      );
    },
  );
}
