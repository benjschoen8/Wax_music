import 'package:crate/music_detector.dart';
import 'package:crate/state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'detected music selects song results even after another search mode',
    () {
      final app = AppState()
        ..artistMode = true
        ..albumMode = true
        ..plMode = true;
      app.selectSongSearch();
      expect([
        app.artistMode,
        app.albumMode,
        app.plMode,
      ], everyElement(isFalse));
      const detected = DetectedMusic(
        title: 'Song',
        artist: 'Artist',
        videoId: 'abcdefghijk',
      );
      expect(detected.searchQuery, 'Artist - Song');
    },
  );
}
