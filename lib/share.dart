import 'dart:async';

import 'package:flutter/services.dart';

import 'files.dart';
import 'log.dart';

/// Receives text shared into the app (e.g. YouTube's Share -> Crate) from the
/// small native bridge in android_manifest/MainActivity.kt.
class ShareIntake {
  static const _channel = MethodChannel('crate/share');

  static Future<void> init(
    FutureOr<void> Function(String url) onShared, {
    Future<void>? ready,
  }) async {
    Future<void> deliver(String url) async {
      await ready;
      await onShared(url);
    }

    // App already running: native side pushes new shares.
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'shared') {
        final url = extractUrl(call.arguments as String?);
        if (url != null) await deliver(url);
      }
    });
    // Cold start: ask for whatever launched us.
    try {
      final initial = await _channel.invokeMethod<String>('getInitial');
      final url = extractUrl(initial);
      if (url != null) await deliver(url);
    } on MissingPluginException {
      // Native bridge not installed (e.g. MainActivity wasn't replaced).
    } catch (e, s) {
      AppLog.error('share intake', e, s);
    }
    await ready;
  }
}
