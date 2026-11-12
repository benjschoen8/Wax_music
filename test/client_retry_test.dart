import 'dart:async';

import 'package:crate/client_retry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('continues to the next client after timeout', () async {
    final tried = <int>[];
    final result = await runClientAttempts<int>(
      start: 0,
      count: 3,
      isBlocked: (_) => false,
      attempt: (i) async {
        tried.add(i);
        if (i == 0) throw TimeoutException('first');
        return i;
      },
    );
    expect(result, 1);
    expect(tried, [0, 1]);
  });
  test('mixed failures do not masquerade as connection blocking', () async {
    final blocked = StateError('blocked');
    final timeout = TimeoutException('timed out');
    await expectLater(
      runClientAttempts<int>(
        start: 0,
        count: 2,
        isBlocked: (e) => identical(e, blocked),
        attempt: (i) async {
          if (i == 0) throw blocked;
          throw timeout;
        },
      ),
      throwsA(same(timeout)),
    );
  });
}
