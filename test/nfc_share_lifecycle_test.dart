import 'dart:async';

import 'package:crate/models/user_playlist.dart';
import 'package:crate/playlist_sharing.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('closing share sheet during NFC startup stops the broadcast', (
    tester,
  ) async {
    const channel = MethodChannel('crate/nfc');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final started = Completer<bool>();
    var stopped = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isAvailable') return true;
      if (call.method == 'startShare') return started.future;
      if (call.method == 'stopShare') {
        stopped = true;
        return true;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final playlist = UserPlaylist(
      id: 'x',
      title: 'Mix',
      createdAt: DateTime.now(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SharePlaylistSheet(playlist: playlist)),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    started.complete(true);
    await tester.pump();
    await tester.pump();
    expect(stopped, isTrue);
  });
  testWidgets('older startup does not stop a newer share', (tester) async {
    const channel = MethodChannel('crate/nfc');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final first = Completer<bool>();
    var starts = 0, stops = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isAvailable') return true;
      if (call.method == 'startShare') {
        starts++;
        return starts == 1 ? first.future : true;
      }
      if (call.method == 'stopShare') {
        stops++;
        return true;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final a = UserPlaylist(id: 'a', title: 'A', createdAt: DateTime.now());
    final b = UserPlaylist(id: 'b', title: 'B', createdAt: DateTime.now());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SharePlaylistSheet(key: const ValueKey('a'), playlist: a),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SharePlaylistSheet(key: const ValueKey('b'), playlist: b),
        ),
      ),
    );
    await tester.pump();
    first.complete(true);
    await tester.pump();
    await tester.pump();
    expect(starts, 2);
    expect(stops, 0);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    expect(stops, 1);
  });
  testWidgets('a stale availability response cannot start an old share', (
    tester,
  ) async {
    const channel = MethodChannel('crate/nfc');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final firstAvailability = Completer<bool>();
    var checks = 0, starts = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isAvailable') {
        checks++;
        return checks == 1 ? firstAvailability.future : true;
      }
      if (call.method == 'startShare') {
        starts++;
        return true;
      }
      if (call.method == 'stopShare') return true;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final a = UserPlaylist(id: 'a', title: 'A', createdAt: DateTime.now());
    final b = UserPlaylist(id: 'b', title: 'B', createdAt: DateTime.now());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SharePlaylistSheet(key: const ValueKey('a'), playlist: a),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SharePlaylistSheet(key: const ValueKey('b'), playlist: b),
        ),
      ),
    );
    await tester.pump();
    firstAvailability.complete(true);
    await tester.pump();
    await tester.pump();
    expect(checks, 2);
    expect(starts, 1);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
  });
  testWidgets('an old share is stopped if the newer share cannot start', (tester) async {
    const channel = MethodChannel('crate/nfc');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final first = Completer<bool>();
    var checks = 0, stops = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isAvailable') return ++checks == 1;
      if (call.method == 'status') return 'unavailable';
      if (call.method == 'startShare') return first.future;
      if (call.method == 'stopShare') { stops++; return true; }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final a = UserPlaylist(id: 'a', title: 'A', createdAt: DateTime.now());
    final b = UserPlaylist(id: 'b', title: 'B', createdAt: DateTime.now());
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SharePlaylistSheet(key: const ValueKey('a'), playlist: a))));
    await tester.pump();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SharePlaylistSheet(key: const ValueKey('b'), playlist: b))));
    await tester.pump();
    first.complete(true);
    await tester.pump();
    await tester.pump();
    expect(checks, 2);
    expect(stops, 1);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
  });
}
