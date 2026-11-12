import 'package:crate/models/track.dart';
import 'package:crate/ytm_search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fallback picks only the same artist and recording', () {
    final original = Track(
      'abcdefghijk',
      'Lucky',
      'Two Door Cinema Club',
      '',
      const Duration(seconds: 200),
    );
    final edit = Track(
      '12345678901',
      'Lucky (Edit)',
      'Two Door Cinema Club - Topic',
      '',
      const Duration(seconds: 200),
    );
    final wrongArtist = Track(
      '12345678902',
      'Lucky',
      'Another Artist - Topic',
      '',
      const Duration(seconds: 200),
    );
    final match = Track(
      '12345678903',
      'Lucky',
      'Two Door Cinema Club - Topic',
      '',
      const Duration(seconds: 200),
    );
    expect(
      YtmSearchService.findAudioCandidate(original, [edit, wrongArtist]),
      isNull,
    );
    expect(
      YtmSearchService.findAudioCandidate(original, [
        edit,
        wrongArtist,
        match,
      ])?.id,
      match.id,
    );
  });
}
