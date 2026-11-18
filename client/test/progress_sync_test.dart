import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novel_reader/store.dart';

http.Response jsonResponse(Object? data, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(data)), status);

void main() {
  test('旧章节返回 404 后本机仍能续读，新章节进度可同步', () async {
    final dir = await Directory.systemTemp.createTemp('kreader-progress-');
    addTearDown(() => dir.delete(recursive: true));
    Json? synced;
    final client = MockClient((request) async {
      if (request.url.path == '/api/books/b') return jsonResponse({'id': 'b'});
      expect(request.url.path, '/api/books/b/progress');
      if (request.method == 'GET') return jsonResponse(synced);
      final spot = jsonDecode(request.body) as Json;
      if (spot['chapterId'] == 'old')
        return jsonResponse({'error': '章节不存在'}, 404);
      expect(spot['version'], 0);
      synced = {...spot, 'version': 1};
      return jsonResponse(synced);
    });
    addTearDown(client.close);
    final first = ReaderStore(dir, {}, client: client);
    await first.remember('b', 'old', 7, 34, '接着读');
    final event = first.map('pending')['b']['eventId'];
    await first.flush();
    final disk = await ReaderStore.open(dir.path);
    addTearDown(disk.client.close);
    final reopened = ReaderStore(dir, disk.state, client: client);
    final saved = await reopened.position('b');
    expect(saved?['eventId'], event);
    expect(saved?['offset'], 34);
    await reopened.remember('b', 'current', 8, 34, '接着读');
    await reopened.flush();
    expect(reopened.map('pending'), isEmpty);
    expect((await reopened.position('b'))?['chapterId'], 'current');
    expect(synced?['paragraph'], 8);
  });

  test('读进度的旧响应晚到时保留此间已保存的新位置', () async {
    final dir = await Directory.systemTemp.createTemp('kreader-progress-');
    addTearDown(() => dir.delete(recursive: true));
    final started = Completer<void>(), response = Completer<http.Response>();
    final client = MockClient((request) async {
      if (request.method == 'PUT') return jsonResponse({'version': 2});
      started.complete();
      return response.future;
    });
    addTearDown(client.close);
    final older = {
      'chapterId': 'old',
      'paragraph': 1,
      'offset': 2,
      'version': 1,
    };
    final store = ReaderStore(dir, {}, client: client);
    store.map('positions')['b'] = older;
    final read = store.position('b');
    await started.future;
    await store.remember('b', 'new', 3, 7, '新位置');
    await store.flush();
    response.complete(jsonResponse(older));
    expect((await read)?['chapterId'], 'new');
    expect(store.map('positions')['b']['version'], 2);
  });
}
