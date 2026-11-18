part of 'store.dart';

extension ReadingTimeStore on ReaderStore {
  Json? _readingQueue(String server) =>
      state['readingTimePending']?[server] as Json?;
  int get pendingReadingPeriods => _readingQueue(namespace)?.length ?? 0;
  Json? get cachedReadingStats => state['readingStats']?[namespace] as Json?;

  Future<void> rememberReadingTime(
    Json book,
    int startedAt,
    int endedAt, {
    required String server,
  }) async {
    final queue =
        map('readingTimePending').putIfAbsent(server, () => <String, dynamic>{})
            as Json;
    final id = ReaderStore.eventId();
    queue[id] = {
      'id': id,
      'bookId': book['id'],
      'title': book['title'],
      'author': book['author'] ?? '',
      'startedAt': startedAt,
      'endedAt': endedAt,
    };
    await persist();
    if (server == namespace) await flushReadingTime();
  }

  Future<void> flushReadingTime() async {
    final server = namespace;
    final queue = _readingQueue(server);
    if (queue == null || queue.isEmpty || token.isEmpty) return;
    await _readingUploads.putIfAbsent(
      server,
      () => _uploadReadingTime(server, queue).whenComplete(() {
        _readingUploads.remove(server);
      }),
    );
  }

  Future<void> _uploadReadingTime(String server, Json queue) async {
    try {
      while (server == namespace && token.isNotEmpty && queue.isNotEmpty) {
        final ids = queue.keys.take(200).toList();
        await _writes;
        if (server != namespace || token.isEmpty) return;
        await send('POST', 'reading-time', {
          'periods': ids.map((id) => queue[id]).toList(),
        }).timeout(const Duration(seconds: 8));
        for (final id in ids) {
          queue.remove(id);
        }
        await persist();
      }
    } on SocketException {
    } on http.ClientException {
    } on TimeoutException {
    } on ApiError {
      // Keep the unsent periods if the server is unavailable or needs an upgrade.
    } on FileSystemException {
      // The saved event IDs can be safely retried if persisting the queue fails.
    }
  }

  Future<Json> loadReadingStats() async {
    final server = namespace;
    await flushReadingTime();
    if (namespace != server) throw StateError('服务连接已切换');
    final data =
        await get('reading-time').timeout(const Duration(seconds: 8)) as Json;
    if (namespace != server) throw StateError('服务连接已切换');
    map('readingStats')[server] = data;
    await persist();
    return data;
  }
}
