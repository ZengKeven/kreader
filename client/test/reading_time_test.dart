import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novel_reader/reading_session.dart';
import 'package:novel_reader/store.dart';

void main() {
  test('只累计可见且活跃的时间，续读后重新计时', () {
    const origin = 1700000000000;
    var elapsed = 0;
    final periods = <(int, int)>[];
    final session = ReadingSession(
      (start, end) => periods.add((start - origin, end - origin)),
      elapsed: () => elapsed,
      now: () => DateTime.fromMillisecondsSinceEpoch(origin + elapsed),
    );

    session.setVisible(true);
    elapsed = 30000;
    session.checkpoint();
    elapsed = 45000;
    session.setVisible(false);
    elapsed = 180000;
    session.checkpoint();
    session.setVisible(true);
    elapsed = 540000;
    session.checkpoint();
    elapsed = 780000;
    session.activity();
    elapsed = 792000;
    session.setVisible(false);
    session.setVisible(false);

    expect(periods, [
      (0, 30000),
      (30000, 45000),
      (180000, 480000),
      (780000, 792000),
    ]);
  });

  test('离线时长重开后以原 ID 重试，统计读取前先上传', () async {
    final dir = await Directory.systemTemp.createTemp('kreader-reading-time-');
    addTearDown(() => dir.delete(recursive: true));
    var online = false;
    final calls = <String>[];
    final writes = <Json>[];
    final client = MockClient((request) async {
      expect(request.url.path, '/api/reading-time');
      calls.add(request.method);
      if (request.method == 'POST') {
        writes.add(rows(jsonDecode(request.body)['periods']).single);
        if (!online) throw const SocketException('测试断网');
        return http.Response('', 204);
      }
      return http.Response('{"todayMs":9000}', 200);
    });
    addTearDown(client.close);
    final first = ReaderStore(dir, {'token': 'test'}, client: client);
    await first.setAppTheme(AppThemeMode.dark);
    await first.rememberReadingTime(
      {'id': 'book', 'title': '山路'},
      1700000000000,
      1700000009000,
      server: first.namespace,
    );
    expect(first.pendingReadingPeriods, 1);
    final disk = await ReaderStore.open(dir.path);
    addTearDown(disk.client.close);
    final reopened = ReaderStore(dir, disk.state, client: client);
    expect(reopened.pendingReadingPeriods, 1);
    expect(reopened.appTheme.value, AppThemeMode.dark);
    online = true;
    expect((await reopened.loadReadingStats())['todayMs'], 9000);
    expect(calls, ['POST', 'POST', 'GET']);
    expect(writes.first, writes.last);
    expect(reopened.pendingReadingPeriods, 0);
    final saved = await ReaderStore.open(dir.path);
    addTearDown(saved.client.close);
    expect(saved.cachedReadingStats?['todayMs'], 9000);
    expect(saved.pendingReadingPeriods, 0);
  });
}
