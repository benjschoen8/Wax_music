import 'track.dart';

/// Represents a user-created local playlist.
class UserPlaylist {
  final String id;
  String title;
  final DateTime createdAt;
  final List<Track> tracks;

  UserPlaylist({
    required this.id,
    required this.title,
    required this.createdAt,
    List<Track>? tracks,
  }) : tracks = tracks ?? [];

  bool containsTrack(String trackId) => tracks.any((t) => t.id == trackId);

  void addTrack(Track track) {
    if (!containsTrack(track.id)) {
      tracks.add(track);
    }
  }

  void removeTrack(String trackId) {
    tracks.removeWhere((t) => t.id == trackId);
  }

  void reorderTrack(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= tracks.length) return;
    if (newIndex < 0 || newIndex > tracks.length) return;
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final item = tracks.removeAt(oldIndex);
    tracks.insert(newIndex, item);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'tracks': tracks.map((t) => t.toJson()).toList(),
  };

  factory UserPlaylist.fromJson(Map<String, dynamic> json) => UserPlaylist(
    id: (json['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString()).replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), ''),
    title: (json['title']?.toString() ?? 'Untitled Playlist').replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim(),
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    tracks: (json['tracks'] as List<dynamic>?)
            ?.map((e) => Track.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [],
  );
}
