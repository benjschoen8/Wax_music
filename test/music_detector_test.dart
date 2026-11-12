import 'package:crate/music_detector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shazam_identifier/shazam_identifier.dart';

void main() {
  test(
    'recognition errors are distinguishable from an unmatched recording',
    () {
      expect(
        () => MusicDetector.resultFromStatus(
          RecognitionStatus.error('Microphone permission not granted'),
        ),
        throwsA(isA<MusicDetectionException>()),
      );
      expect(
        MusicDetector.resultFromStatus(RecognitionStatus.noMatch('No match')),
        isNull,
      );
    },
  );
}
