import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novel_reader/store.dart';

http.Response jsonResponse(Object? data, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(data)), status);

http.Response chapterResponse(String id, {String? image, String? text}) =>
    jsonResponse({
      'id': id,
      'blocks': [
        {'kind': 'p', 'text': text ?? '正文 $id'},
        if (image != null) {'kind': 'image', 'text': '', 'image': image},
      ],
    });

Future<ReaderStore> makeStore(http.Client client) async {
  final dir = await Directory.systemTemp.createTemp('kreader-download-');
  addTearDown(() => dir.delete(recursive: true));
  addTearDown(client.close);
  return ReaderStore(dir, {}, client: client);
}

void main() {
  test('下载超过 30 章后重开可离线读首尾及插图，刷新失败保留下载', () async {
    final ids = List.generate(36, (i) => 'c$i');
    const image = 'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
    final requests = <String>[];
    var imageRequests = 0;
    var refreshed = false;
    final store = await makeStore(
      MockClient((request) async {
        final parts = request.url.pathSegments;
        if (parts.last == 'toc') {
          return jsonResponse([
            for (final id in ids) {'id': id, 'title': '章节 $id'},
          ]);
        }
        if (parts[3] == 'assets') {
          imageRequests++;
          return http.Response.bytes(base64Decode(image), 200);
        }
        final id = parts.last;
        requests.add(id);
        return chapterResponse(
          id,
          image: id == ids.first ? 'picture' : null,
          text: refreshed && id == ids.last ? '更新后的末章' : null,
        );
      }),
    );

    final toc = await store.toc('epub');
    await store.chapter('epub', 'c7');
    final job = await store.downloadBook(
      'epub',
      '山路',
      toc.map((ch) => ch['id'] as String),
    );
    expect(job.saved, 36);
    expect(job.failed, 0);
    expect(requests, unorderedEquals(ids));
    expect(imageRequests, 1);
    expect(store.state['pending'], isNull);
    expect(store.state['positions'], isNull);

    for (var i = 0; i < 31; i++) {
      await store.chapter('other', 'other$i');
    }
    expect(store.state['cacheOrder'], hasLength(30));
    expect(await File('${store.cache.path}/c7.json').exists(), isFalse);
    refreshed = true;
    await store.refreshChapter('epub', ids.last);

    final disk = await ReaderStore.open(store.dir.path);
    addTearDown(disk.client.close);
    var offlineRequests = 0;
    final client = MockClient((_) async {
      offlineRequests++;
      throw const SocketException('测试断网');
    });
    addTearDown(client.close);
    final offline = ReaderStore(disk.dir, disk.state, client: client);
    final first = rows((await offline.chapter('epub', ids.first))['blocks']);
    expect(first.first['text'], '正文 c0');
    expect(first.last['bytes'], image);
    expect((await offline.toc('epub')).last['id'], ids.last);
    expect(await offline.cachedChapter('epub', '未下载'), isNull);
    expect(
      rows(
        (await offline.cachedChapter('epub', ids.last))?['blocks'],
      ).single['text'],
      '更新后的末章',
    );
    expect((await offline.downloadBook('epub', '山路', ids)).saved, 36);
    expect(offlineRequests, 0);
    await expectLater(
      offline.refreshChapter('epub', ids.last),
      throwsA(isA<SocketException>()),
    );
    expect(
      rows((await offline.chapter('epub', ids.last))['blocks']).single['text'],
      '更新后的末章',
    );
    expect(offlineRequests, 1);
  });

  test('停止后保留在途章节，重试只请求缺失和失败章节', () async {
    final ids = List.generate(6, (i) => 'c$i');
    final firstPair = Completer<void>(), release = Completer<void>();
    final requests = <String>[];
    String? fail;
    final store = await makeStore(
      MockClient((request) async {
        final id = request.url.pathSegments.last;
        requests.add(id);
        if (!release.isCompleted) {
          if (requests.length == 2) firstPair.complete();
          await release.future;
        }
        if (id == fail) return jsonResponse({'error': '正文取不到'}, 404);
        return chapterResponse(id);
      }),
    );
    final initial = store.downloadBook('b', '山路', ids);
    await firstPair.future.timeout(const Duration(seconds: 5));
    await expectLater(
      store.downloadBook('other', '另一本', ids),
      throwsStateError,
    );
    final reading = store.chapter('b', ids.first);
    store.activeDownload.value!.stop();
    release.complete();
    final stopped = await initial;
    expect((await reading)['id'], ids.first);
    expect(stopped.saved, 2);
    expect(stopped.stopping, isTrue);
    expect(requests, unorderedEquals(ids.take(2)));
    expect(store.activeDownload.value, isNull);

    requests.clear();
    fail = 'c3';
    final retried = await store.downloadBook('b', '山路', ids);
    expect(retried.saved, 5);
    expect(retried.failed, 1);
    expect(requests, unorderedEquals(ids.skip(2)));

    requests.clear();
    fail = null;
    final completed = await store.downloadBook('b', '山路', ids);
    expect(completed.saved, 6);
    expect(completed.error, isNull);
    expect(requests, ['c3']);
  });

  test('切换服务停止派发，迟到的旧连接正文与新连接隔离', () async {
    final firstPair = Completer<void>(), release = Completer<void>();
    final oldRequests = <String>[];
    final store = await makeStore(
      MockClient((request) async {
        final id = request.url.pathSegments.last;
        if (id == 'library') return jsonResponse({});
        if (request.url.host == 'new.example') {
          return chapterResponse(id, text: '新服务的正文');
        }
        oldRequests.add(id);
        if (oldRequests.length == 2) firstPair.complete();
        await release.future;
        return chapterResponse(id);
      }),
    );
    final oldBase = store.base;
    final downloading = store.downloadBook('b', '山路', ['c1', 'c2', 'c3']);
    await firstPair.future.timeout(const Duration(seconds: 5));
    await store.connect('http://new.example', 'test-secret');
    release.complete();
    final stopped = await downloading;
    expect(stopped.stopping, isTrue);
    expect(oldRequests, unorderedEquals(['c1', 'c2']));
    expect(await store.cachedChapter('b', 'c1'), isNull);
    final newer = rows((await store.chapter('b', 'c1'))['blocks']);
    expect(newer.single['text'], '新服务的正文');
    await store.connect(oldBase, 'test-secret');
    final older = rows((await store.chapter('b', 'c1'))['blocks']);
    expect(older.single['text'], '正文 c1');
    expect(oldRequests, hasLength(2));
  });
}
