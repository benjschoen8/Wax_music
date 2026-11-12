import 'dart:async';

import 'package:crate/share.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('initial playlist waits until the library is ready', () async {
    const channel = MethodChannel('crate/share');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => 'wax://playlist?data=abc',
    );
    final ready = Completer<void>();
    String? received;
    final intake = ShareIntake.init(
      (link) => received = link,
      ready: ready.future,
    );
    await Future<void>.delayed(Duration.zero);
    expect(received, isNull);
    ready.complete();
    await intake;
    expect(received, 'wax://playlist?data=abc');
    messenger.setMockMethodCallHandler(channel, null);
  });
}
