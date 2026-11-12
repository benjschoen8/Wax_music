/// Tries each client, preferring a non-blocking error if failures differ.
Future<T> runClientAttempts<T>({
  required int start,
  required int count,
  required Future<T> Function(int index) attempt,
  required bool Function(Object error) isBlocked,
  void Function(int index, Object error)? onFailure,
}) async {
  Object? lastError;
  StackTrace? lastStack;
  Object? otherError;
  StackTrace? otherStack;
  for (var i = start; i < count; i++) {
    try {
      return await attempt(i);
    } catch (error, stack) {
      onFailure?.call(i, error);
      lastError = error;
      lastStack = stack;
      if (!isBlocked(error)) {
        otherError = error;
        otherStack = stack;
      }
    }
  }
  if (otherError != null) Error.throwWithStackTrace(otherError, otherStack!);
  if (lastError != null) Error.throwWithStackTrace(lastError, lastStack!);
  throw StateError('No download clients available');
}
