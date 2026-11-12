import 'package:flutter_test/flutter_test.dart';
import 'package:crate/files.dart';

void main() {
  test('keeps meaningful version labels distinct', () {
    expect(
      normalizeLibraryKey('Two Door Cinema Club - Lucky (Edit)'),
      isNot(normalizeLibraryKey('Two Door Cinema Club - Lucky')),
    );
    expect(
      normalizeLibraryKey('Lucky [Live]'),
      isNot(normalizeLibraryKey('Lucky')),
    );
  });

  test('ignores descriptive video and audio labels', () {
    expect(
      normalizeLibraryKey('Artist - Song (Official Audio)'),
      normalizeLibraryKey('Artist - Song'),
    );
    expect(
      normalizeLibraryKey('Artist - Song [Lyrics]'),
      normalizeLibraryKey('Artist - Song'),
    );
  });
}
