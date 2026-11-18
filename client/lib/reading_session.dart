import 'dart:math';

class ReadingSession {
  ReadingSession(
    this.onPeriod, {
    int Function()? elapsed,
    DateTime Function()? now,
  }) : _elapsed = elapsed ?? _monotonicClock(),
       _now = now ?? DateTime.now;

  static const idleLimit = Duration(minutes: 5);
  final void Function(int startedAt, int endedAt) onPeriod;
  final int Function() _elapsed;
  final DateTime Function() _now;
  int? _cursor;
  int _lastActivity = 0, _utcOrigin = 0;

  static int Function() _monotonicClock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsedMilliseconds;
  }

  void setVisible(bool visible) {
    if (visible && _cursor == null) {
      _start(_elapsed());
    } else if (!visible && _cursor != null) {
      checkpoint();
      _cursor = null;
    }
  }

  void activity() {
    if (_cursor == null) return;
    final at = _elapsed();
    if (at - _lastActivity >= idleLimit.inMilliseconds) {
      _record(at);
      _start(at);
    } else {
      _lastActivity = at;
    }
  }

  void checkpoint() {
    if (_cursor != null) _record(_elapsed());
  }

  void _start(int at) {
    _cursor = _lastActivity = at;
    _utcOrigin = _now().millisecondsSinceEpoch - at;
  }

  void _record(int at) {
    var start = _cursor!;
    final limit = idleLimit.inMilliseconds;
    final end = min(at, _lastActivity + limit);
    while (start < end) {
      final next = min(end, start + limit);
      _cursor = next;
      onPeriod(_utcOrigin + start, _utcOrigin + next);
      start = next;
    }
  }
}
