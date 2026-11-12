import 'package:flutter/widgets.dart';

import '../models/track.dart';

/// App-level destinations used by track menus on any tab.
class TrackNavigation extends InheritedWidget {
  final void Function(Track track) onArtist;
  final void Function(Track track) onAlbum;

  const TrackNavigation({
    super.key,
    required this.onArtist,
    required this.onAlbum,
    required super.child,
  });

  static TrackNavigation? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TrackNavigation>();

  @override
  bool updateShouldNotify(TrackNavigation oldWidget) =>
      onArtist != oldWidget.onArtist || onAlbum != oldWidget.onAlbum;
}
