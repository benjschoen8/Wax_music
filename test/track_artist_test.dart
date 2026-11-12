import 'package:crate/models/track.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a dash qualifier in a song title does not replace its artist', () {
    final t = Track(
      'abcdefghijk',
      'Lucky - Live',
      'Two Door Cinema Club',
      '',
      null,
    );
    expect(t.tagArtist, 'Two Door Cinema Club');
    expect(t.tagTitle, 'Lucky - Live');
  });
  test('artist-prefixed titles still split when the author matches', () {
    final t = Track(
      'abcdefghijk',
      'Two Door Cinema Club - Lucky',
      'Two Door Cinema Club',
      '',
      null,
    );
    expect(t.tagArtist, 'Two Door Cinema Club');
    expect(t.tagTitle, 'Lucky');
  });
}
