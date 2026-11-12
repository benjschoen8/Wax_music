import 'package:flutter_foreground_task/flutter_foreground_task.dart';

// The service only keeps the process alive (notification + wake/wifi lock);
// the download work itself runs in the main isolate.
@pragma('vm:entry-point')
void startCallback() => FlutterForegroundTask.setTaskHandler(KeepAlive());

class KeepAlive extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}
