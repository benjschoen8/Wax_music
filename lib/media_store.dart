import 'dart:io';

import 'package:flutter/services.dart';

import 'files.dart';
import 'log.dart';

/// Saving into Music/ through Android's MediaStore, via the native bridge in
/// MainActivity.kt (no plugin: the old media_store_plus failed to build).
class MediaStoreBridge {
  static const _ch = MethodChannel('crate/media');

  /// True on Android 10+ when the bridge is installed.
  static Future<bool> supported() async {
    try {
      return await _ch.invokeMethod<bool>('supported') ?? false;
    } catch (_) {
      return false; // MissingPluginException etc.: fall back to file I/O
    }
  }

  /// Is there already an audio file [name] in Music/[rel]?
  static Future<bool> exists(String name, String rel) async =>
      await _ch.invokeMethod<bool>('exists', {'name': name, 'rel': rel}) ??
      false;

  /// May Crate see audio files it did not create itself?
  static Future<bool> canRead() async {
    try {
      return await _ch.invokeMethod<bool>('canRead') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Shows the system permission prompt; true if granted.
  static Future<bool> askRead() async {
    try {
      return await _ch.invokeMethod<bool>('askRead') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// File names of all audio in Music/[rel] (sub-folders included).
  static Future<List<String>> list(String rel) async {
    try {
      final r = await _ch.invokeMethod<List<Object?>>('list', {'rel': rel});
      return r?.cast<String>() ?? const [];
    } catch (_) {
      return const [];
    }
  }

  /// Detailed list of all audio files in local storage (or under [rel]).
  /// Returns maps with keys: id, displayName, title, artist, album, durationMs, path.
  static Future<List<Map<String, dynamic>>> listDetails({String? rel}) async {
    try {
      final r = await _ch.invokeMethod<List<dynamic>>('listDetails', {'rel': rel});
      if (r == null) return const [];
      return r
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Copies the file at [path] into Music/[rel] as [name]; returns its URI.
  static Future<String> save(String path, String name, String rel) async =>
      (await _ch.invokeMethod<String>('save', {
        'path': path,
        'name': name,
        'rel': rel,
      }))!;

  /// Deletes the audio file at [path] together with its MediaStore row.
  ///
  /// Tries the native `delete` first (needed on Android 10+ scoped storage),
  /// then falls back to plain file I/O. Returns true only when the file is
  /// really gone afterwards, so callers can report failure honestly.
  static Future<bool> delete(String path) async {
    if (!isSafeAudioPath(path)) {
      AppLog.info('refused to delete non-audio / unsafe path');
      return false;
    }
    try {
      await _ch.invokeMethod<bool>('delete', {'path': path});
    } catch (_) {
      // MissingPluginException etc.: fall back to file I/O below
    }
    final f = File(path);
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
    return !await f.exists();
  }

  /// Asks MediaStore to re-read the tags of [path] after it was rewritten.
  /// Best effort: silently does nothing when the native bridge lacks `scan`.
  static Future<void> rescan(String path) async {
    if (!isSafeAudioPath(path)) return;
    try {
      await _ch.invokeMethod<bool>('scan', {'path': path});
    } catch (_) {}
  }
}
