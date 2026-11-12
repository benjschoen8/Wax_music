import 'dart:io';

import 'package:flutter/material.dart';

import '../models/track.dart';

/// Universal track thumbnail image widget that seamlessly displays both
/// online remote URLs (http/https) and local filesystem images (extracted covers,
/// companion images, file://), falling back cleanly to a themed placeholder icon.
class TrackImage extends StatelessWidget {
  final String? thumb;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final BoxShape shape;
  final IconData placeholderIcon;
  final double iconSize;

  const TrackImage({
    super.key,
    required this.thumb,
    this.width = 50,
    this.height = 50,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.shape = BoxShape.rectangle,
    this.placeholderIcon = Icons.music_note_rounded,
    this.iconSize = 24,
  });

  @override
  Widget build(BuildContext context) {
    Widget placeholder() => Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            shape: shape,
            borderRadius: shape == BoxShape.rectangle ? borderRadius : null,
          ),
          child: Center(
            child: Icon(
              placeholderIcon,
              size: iconSize,
              color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        );

    // Remote URLs are restricted to https on YouTube/Google image CDNs.
    final raw = Track.sanitizeThumb(thumb?.trim() ?? '');
    if (raw.isEmpty) {
      return placeholder();
    }

    // Local file path or file:// URI
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
      final cleanPath = raw.startsWith('file://') ? raw.replaceFirst('file://', '') : raw;
      final lower = cleanPath.toLowerCase();
      // If an audio file path was passed, check if a companion image exists next to it
      if (lower.endsWith('.m4a') ||
          lower.endsWith('.mp3') ||
          lower.endsWith('.flac') ||
          lower.endsWith('.opus') ||
          lower.endsWith('.ogg') ||
          lower.endsWith('.wav') ||
          lower.endsWith('.aac') ||
          lower.endsWith('.webm')) {
        final dot = cleanPath.lastIndexOf('.');
        final base = dot > 0 ? cleanPath.substring(0, dot) : cleanPath;
        for (final ext in const ['.jpg', '.png', '.jpeg', '.webp']) {
          final imgFile = File('$base$ext');
          if (imgFile.existsSync() && imgFile.lengthSync() > 0) {
            return _applyShape(Image.file(
              imgFile,
              width: width,
              height: height,
              fit: fit,
              errorBuilder: (_, _, _) => placeholder(),
            ));
          }
        }
        return placeholder();
      }

      try {
        final f = File(cleanPath);
        if (f.existsSync() && f.lengthSync() > 0) {
          final img = Image.file(
            f,
            width: width,
            height: height,
            fit: fit,
            errorBuilder: (_, _, _) => placeholder(),
          );
          return _applyShape(img);
        }
      } catch (_) {
        return placeholder();
      }
      return placeholder();
    }

    // Remote HTTP / HTTPS URL
    final netImg = Image.network(
      raw,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (_, _, _) => placeholder(),
    );
    return _applyShape(netImg);
  }

  Widget _applyShape(Widget child) {
    if (shape == BoxShape.circle) {
      return ClipOval(child: child);
    }
    if (borderRadius != null) {
      return ClipRRect(borderRadius: borderRadius!, child: child);
    }
    return child;
  }
}
