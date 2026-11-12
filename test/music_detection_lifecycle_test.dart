import 'dart:async';

import 'package:crate/music_detector.dart';
import 'package:crate/pages/search_page.dart';
import 'package:crate/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'dismissing recognition does not permit a second recording until the first finishes',
    (tester) async {
      final pending = Completer<DetectedMusic?>();
      var starts = 0;
      Future<DetectedMusic?> detect({void Function(String)? onStateChange}) {
        starts++;
        return pending.future;
      }

      final app = AppState();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchPage(app: app, detectMusic: detect),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Detect music'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tapAt(const Offset(10, 10));
      await tester.pump(const Duration(milliseconds: 500));
      final button = find.byWidgetPredicate(
        (w) => w is IconButton && w.tooltip == 'Detect music',
      );
      final disabled = tester.widget<IconButton>(button);
      expect(disabled.onPressed, isNull);
      expect(starts, 1);
      pending.complete(null);
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(button).onPressed, isNotNull);
    },
  );
}
