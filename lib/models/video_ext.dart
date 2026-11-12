import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'track.dart';

extension VideoToTrack on Video {
  Track toTrack({String? album}) => Track(
        id.value,
        title,
        author,
        thumbnails.highResUrl.isNotEmpty
            ? thumbnails.highResUrl
            : (thumbnails.mediumResUrl.isNotEmpty
                ? thumbnails.mediumResUrl
                : thumbnails.lowResUrl),
        duration,
        uploadDate: uploadDate?.toIso8601String() ?? uploadDateRaw,
        album: album,
      );
}
