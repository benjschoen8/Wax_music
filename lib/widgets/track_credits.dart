import 'package:flutter/material.dart';

import '../constants.dart';
import '../models/track.dart';

class TrackCredits extends StatelessWidget {
  final Track track;
  final void Function(String, String?)? onOpenArtist;
  final void Function(String, String?)? onOpenAlbum;

  const TrackCredits({
    super.key,
    required this.track,
    this.onOpenArtist,
    this.onOpenAlbum,
  });

  @override
  Widget build(BuildContext context) {
    final artist = track.tagArtist;
    final album = track.album?.trim();
    return Column(
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onOpenArtist == null
              ? null
              : () => onOpenArtist!(track.artistBrowseId ?? '', artist),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(
              artist,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: accent(context),
              ),
            ),
          ),
        ),
        if (album != null && album.isNotEmpty)
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onOpenAlbum == null
                ? null
                : () => onOpenAlbum!(track.albumBrowseId ?? '', album),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                album,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: accent(context)),
              ),
            ),
          ),
      ],
    );
  }
}
