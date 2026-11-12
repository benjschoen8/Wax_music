import 'package:flutter/material.dart';

class MusicCategory {
  final String title;
  final String query;
  final IconData icon;
  final Color color;

  const MusicCategory({
    required this.title,
    required this.query,
    required this.icon,
    required this.color,
  });
}

/// Unified single source of truth for categories and genres across Wax.
/// Used on both the Home page and Search page Explore grids.
const List<MusicCategory> musicCategories = [
  MusicCategory(
    title: 'Top 50 Global',
    query: 'Top 50 Global Songs',
    icon: Icons.public_rounded,
    color: Color(0xFFE91E63),
  ),
  MusicCategory(
    title: 'Pop Hits',
    query: 'Pop Music Hits',
    icon: Icons.music_note_rounded,
    color: Color(0xFF2196F3),
  ),
  MusicCategory(
    title: 'Hip-Hop & Rap',
    query: 'Hip Hop and Rap Music',
    icon: Icons.mic_rounded,
    color: Color(0xFFFF9800),
  ),
  MusicCategory(
    title: 'Rock & Metal',
    query: 'Rock and Heavy Metal Music',
    icon: Icons.electric_bolt_rounded,
    color: Color(0xFFF44336),
  ),
  MusicCategory(
    title: 'Lo-Fi & Chill',
    query: 'Lofi Chill Beats',
    icon: Icons.coffee_rounded,
    color: Color(0xFF4CAF50),
  ),
  MusicCategory(
    title: 'R&B / Soul',
    query: 'R&B and Soul Music',
    icon: Icons.nightlife_rounded,
    color: Color(0xFF9C27B0),
  ),
  MusicCategory(
    title: 'Soundtracks & OST',
    query: 'Soundtracks and Movie OST',
    icon: Icons.movie_filter_rounded,
    color: Color(0xFF009688),
  ),
  MusicCategory(
    title: 'Anime & Gaming',
    query: 'Anime and Video Game Music',
    icon: Icons.sports_esports_rounded,
    color: Color(0xFF3F51B5),
  ),
  MusicCategory(
    title: 'K-Pop & Asian Pop',
    query: 'K-Pop and Asian Pop Hits',
    icon: Icons.stars_rounded,
    color: Color(0xFFE040FB),
  ),
  MusicCategory(
    title: 'Workout & Energy',
    query: 'Workout and Gym Motivation Music',
    icon: Icons.fitness_center_rounded,
    color: Color(0xFFFF5722),
  ),
  MusicCategory(
    title: 'Sleep & Ambient',
    query: 'Ambient Sleep Music',
    icon: Icons.bedtime_rounded,
    color: Color(0xFF607D8B),
  ),
  MusicCategory(
    title: 'Focus & Study',
    query: 'Study and Focus Music',
    icon: Icons.auto_stories_rounded,
    color: Color(0xFF795548),
  ),
  MusicCategory(
    title: 'Jazz & Blues',
    query: 'Classic Jazz and Blues',
    icon: Icons.album_rounded,
    color: Color(0xFF673AB7),
  ),
  MusicCategory(
    title: 'Acoustic & Folk',
    query: 'Acoustic Guitar and Folk Music',
    icon: Icons.nature_people_rounded,
    color: Color(0xFF8BC34A),
  ),
  MusicCategory(
    title: 'Kids & Family',
    query: 'Kids and Family Songs',
    icon: Icons.toys_rounded,
    color: Color(0xFF00BCD4),
  ),
  MusicCategory(
    title: 'Classics & Oldies',
    query: 'Classic Golden Oldies',
    icon: Icons.radio_rounded,
    color: Color(0xFFFFB300),
  ),
];
