import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader/main.dart';
import 'package:novel_reader/reader.dart';
import 'package:novel_reader/store.dart';

const novel = {'id': 'original', 'title': '山路', 'author': '林舟', 'origin': 'a'};

class EditionStore extends ReaderStore {
  final queries = <String>[];
  final reads = <(String, String)>[];
  final paragraphs = <String, List<String>>{};
  final catalogs = <String, List<Json>>{
    'original': [
      {'id': 'o1', 'title': '初见'},
      {'id': 'o2', 'title': '归来'},
    ],
    'alternative': [
      {'id': 't0', 'title': '序'},
      {'id': 't2', 'title': '归来'},
      {'id': 't3', 'title': '新书源独有章节'},
    ],
  };
  final maps = <Json>[
    {
      'id': 'old-chapter',
      'chapter': 'o2',
      'targetBook': 'obsolete',
      'targetChapter': 'unused',
    },
  ];
  Json positionData = {
    'chapterId': 'o2',
    'paragraph': 0,
    'offset': 2,
    'quote': '春山',
  };
  final lateResult = Completer<List<Json>>();
  List<String> sources = [
    'a',
    'b',
    'other',
    'offline',
    'disabled',
    'invalid',
    'slow',
  ];
  bool chapterFails = false;
  bool hasMatch = true;
  EditionStore([Directory? dir])
    : super(dir ?? Directory.systemTemp, {
        'appearance': <String, dynamic>{'mode': '无动画'},
      });

  @override
  Future<void> persist() async {}
  @override
  Future<void> flush() async {}
  @override
  Future<Json?> position(String id) async => positionData;
  @override
  Future<void> remember(
    String book,
    String chapter,
    int p,
    int o,
    String quote, {
    Json? visit,
  }) async {
    expect(book, 'original');
    positionData = {
      'chapterId': chapter,
      'paragraph': p,
      'offset': o,
      'quote': quote,
    };
  }

  @override
  Future<List<Json>> items(String kind, [String? book]) async =>
      kind == 'mapping' ? maps : [];
  @override
  Future<void> putItem(String kind, Json item) async {
    expect(kind, 'mapping');
    maps.removeWhere((m) => m['id'] == item['id']);
    maps.insert(0, item);
  }

  @override
  Future<dynamic> get(String route, [Map<String, String>? query]) async {
    if (route == 'library') return <String, dynamic>{};
    if (route == 'activity')
      return [
        {
          'book': 'original',
          'title': '山路',
          'day': '今天',
          'chapter': '归来',
          'chapterId': 'o2',
        },
      ];
    if (route == 'sources')
      return [
        for (final id in sources)
          {
            'id': id,
            'name': '书源 $id',
            'enabled': id == 'disabled' ? 0 : 1,
            'issue': id == 'invalid' ? '规则不可用' : '',
          },
      ];
    if (route == 'books/alternative') return {'origin': 'b'};
    if (route == 'books/original') return novel;
    if (route != 'search') return [];
    expect(query!['q'], '山路');
    final id = query['source']!;
    queries.add(id);
    if (id == 'offline') throw StateError('书源暂不可用');
    if (id.startsWith('slow')) return lateResult.future;
    if (id == 'a') return [novel];
    return [
      {'id': 'sequel', 'title': '山路续集', 'author': '林舟'},
      {'id': 'unrelated', 'title': '山路', 'author': '另一作者'},
      if (hasMatch && id == 'b') ...[
        {'id': 'alternative', 'title': '《山路》', 'author': ' 林舟 '},
        {'id': 'alternative', 'title': '山路', 'author': '林舟'},
      ],
    ];
  }

  @override
  Future<List<Json>> toc(String id, {bool force = false}) async =>
      catalogs[id] ?? (throw StateError('不应读取旧的单章映射'));
  @override
  Future<Json> chapter(String book, String id) async {
    reads.add((book, id));
    if (chapterFails && book == 'alternative') throw StateError('新源正文读取失败');
    return {
      'blocks': [
        for (final text in paragraphs[id] ?? ['走过春山，又见归人。' * 6 + id])
          {'kind': 'p', 'text': text},
      ],
    };
  }
}

class DownloadEditionStore extends EditionStore {
  DownloadEditionStore(super.dir);

  final downloads = <String>[];
  final started = Completer<void>(), release = Completer<void>();

  @override
  Future<dynamic> get(String route, [Map<String, String>? query]) async {
    if (!route.contains('/chapters/')) return super.get(route, query);
    downloads.add(route);
    if (downloads.length == 2) started.complete();
    await release.future;
    return {
      'blocks': [
        {'kind': 'p', 'text': '下载正文 $route'},
      ],
    };
  }
}

Future<void> tap(WidgetTester t, Finder what) async {
  await t.tap(what);
  await t.pumpAndSettle();
}

Future<void> mountReader(
  WidgetTester t,
  EditionStore store, {
  double width = 402,
}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = Size(width, 840);
  addTearDown(t.view.reset);
  addTearDown(store.client.close);
  han = {'简体': {}, '繁体': {}};
  await t.pumpWidget(BooksApp(store));
  final nav = t.state<NavigatorState>(find.byType(Navigator));
  nav.push(
    PageRouteBuilder<void>(
      pageBuilder: (_, __, ___) => BookDetails(store, novel),
    ),
  );
  await t.pumpAndSettle();
  await tap(t, find.text('继续阅读'));
  await t.tapAt(const Offset(200, 400));
  await t.pumpAndSettle();
}

Future<void> openPicker(WidgetTester t) async {
  await tap(t, find.byTooltip('换源'));
  expect(find.text('换源范围'), findsNothing);
}

void main() {
  testWidgets('窄屏夜间使用顶栏下载当前书源，退出后仍可查看进度并停止', (t) async {
    final s = (await t.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('kreader-download-ui-');
      return DownloadEditionStore(dir)
        ..map('appearance')['night'] = true
        ..maps.add({
          'id': 'original-*',
          'chapter': '*',
          'targetBook': 'alternative',
          'targetSource': 'b',
        });
    }))!;
    addTearDown(() => s.dir.delete(recursive: true));
    await mountReader(t, s, width: 320);
    final source = find.byTooltip('换源');
    final download = find.byTooltip('下载全书');
    final tools = find.byTooltip('章节工具');
    expect(t.getCenter(source).dx, lessThan(t.getCenter(download).dx));
    expect(t.getCenter(download).dx, lessThan(t.getCenter(tools).dx));
    await tap(t, tools);
    expect(find.text('阅读工具'), findsOneWidget);
    expect(find.text('原文地址'), findsOneWidget);
    expect(find.text('换源'), findsNothing);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();

    await t.runAsync(() async {
      await t.tap(download);
      await s.started.future.timeout(const Duration(seconds: 5));
    });
    await t.pumpAndSettle();
    final job = s.activeDownload.value!;
    expect(job.total, 3);
    expect(find.byTooltip('下载进度'), findsOneWidget);
    expect(find.text('下载《山路》'), findsNothing);

    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(s.activeDownload.value, same(job));
    await tap(t, find.text('继续阅读'));
    await t.tapAt(const Offset(160, 400));
    await t.pumpAndSettle();
    await tap(t, find.byTooltip('下载进度'));
    expect(find.text('已下载 0/3 章'), findsOneWidget);
    await tap(t, find.text('停止下载'));
    expect(find.text('正在停止下载…'), findsOneWidget);

    final finished = Completer<void>.sync();
    void onFinish() {
      if (!job.running) finished.complete();
    }

    job.addListener(onFinish);
    await t.runAsync(() async {
      s.release.complete();
      await finished.future.timeout(const Duration(seconds: 5));
    });
    job.removeListener(onFinish);
    await t.pumpAndSettle();
    expect(find.text('已下载 2/3 章'), findsOneWidget);
    expect(find.text('已停止下载'), findsOneWidget);
    expect(
      s.downloads,
      unorderedEquals([
        'books/alternative/chapters/t0',
        'books/alternative/chapters/t2',
      ]),
    );
  });

  test('章号格式等价时保留旧 ID，标题冲突或重复时不建立别名', () async {
    final s = EditionStore();
    addTearDown(s.client.close);
    s.catalogs['original'] = [
      {'id': 'o1', 'title': '第１０２章：回程'},
      {'id': 'o2', 'title': '第10章'},
      {'id': 'o3', 'title': '第2章 序'},
    ];
    s.catalogs['alternative'] = [
      {'id': 't1', 'title': '第一百零二章 回程'},
      {'id': 't2', 'title': '第十章'},
      {'id': 't3', 'title': '第二章 序'},
      {'id': 't4', 'title': '第２章 序'},
      {'id': 't5', 'title': '第一章 序'},
    ];
    final toc = await s.readingToc('original', {'targetBook': 'alternative'});
    expect(toc.map((ch) => ch['originalChapter']), [
      'o1',
      'o2',
      null,
      null,
      null,
    ]);
    expect(toc.first['id'], 't1');
  });

  testWidgets('旧书源的数字章号能在新目录续读，移动过的原文位置在退出后保留', (t) async {
    final s = EditionStore();
    s.catalogs['original']![0]['title'] = '第1章 压缩四千万';
    s.catalogs['alternative']![0]['title'] = '第一章　压缩四千万';
    s.maps.add({
      'id': 'original-*',
      'chapter': '*',
      'targetBook': 'alternative',
    });
    const quote = '就在这里接着读。';
    s.positionData = {
      'chapterId': 'o1',
      'paragraph': 7,
      'offset': 34,
      'quote': quote,
    };
    s.paragraphs['t0'] = [
      for (var i = 0; i < 8; i++) '新排版的第 $i 段。',
      '山' * 34 + quote,
    ];
    await mountReader(t, s);
    expect(find.textContaining('原章节已变更'), findsNothing);
    expect(s.positionData['paragraph'], 8);
    expect(s.positionData['offset'], 34);
    expect(s.positionData['quote'], quote);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    await tap(t, find.text('继续阅读'));
    expect(find.textContaining('原章节已变更'), findsNothing);
    expect(s.positionData['paragraph'], 8);
    expect(s.positionData['offset'], 34);
  });

  testWidgets('旧章节确实移除时，手动切到下一章后恢复保存并能再次续读', (t) async {
    final s = EditionStore()..positionData['chapterId'] = 'removed';
    await mountReader(t, s);
    expect(s.positionData['chapterId'], 'removed');
    expect(find.textContaining('原章节已变更'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));
    await t.pumpAndSettle();
    await tap(t, find.byTooltip('下一章'));
    expect(s.positionData['chapterId'], 'o2');
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    await tap(t, find.text('继续阅读'));
    expect(find.text('归来'), findsWidgets);
    expect(find.textContaining('原章节已变更'), findsNothing);
  });

  testWidgets('从阅读记录打开最近一章时，继续保留段内位置', (t) async {
    final s = EditionStore()..state['token'] = 'fixture';
    addTearDown(s.client.close);
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(402, 840);
    addTearDown(t.view.reset);
    han = {'简体': {}, '繁体': {}};
    await t.pumpWidget(BooksApp(s));
    await t.pumpAndSettle();
    await tap(t, find.byTooltip('我的'));
    await tap(t, find.text('阅读记录'));
    await tap(t, find.text('归来'));
    expect(find.byType(ReaderPage), findsOneWidget);
    expect(s.positionData['chapterId'], 'o2');
    expect(s.positionData['offset'], 2);
  });

  testWidgets('从多页章节换到单页书源，滑块按新分页显示并能切回原位置', (t) async {
    const passage = '翻过了最后一道山梁，终于望见了回家的路。';
    final s = EditionStore();
    s.map('appearance')['footer'] = '页码';
    s.paragraphs['o2'] = [for (var i = 0; i < 60; i++) '经过第 $i 道山梁。', passage];
    s.paragraphs['t2'] = [passage];
    s.positionData = {
      'chapterId': 'o2',
      'paragraph': 60,
      'offset': 2,
      'quote': passage.substring(2),
    };
    s.lateResult.complete([]);
    await mountReader(t, s);
    final pageNumber = find.textContaining(RegExp(r'^\d+ / \d+$'));
    final originalPages = t.widget<Text>(pageNumber).data!;
    final originalPage = int.parse(originalPages.split(' / ').first);
    expect(originalPage, greaterThan(2));

    await openPicker(t);
    await tap(t, find.text('书源 b'));
    expect(t.takeException(), isNull);
    expect(find.text('1 / 1'), findsOneWidget);
    expect(
      t.getSemantics(find.bySemanticsLabel('第 1 页')),
      isSemantics(isSlider: true, isEnabled: false),
    );
    expect(s.positionData['paragraph'], 0);
    expect(s.positionData['offset'], 2);

    await openPicker(t);
    await tap(t, find.text('书源 a'));
    expect(t.takeException(), isNull);
    expect(find.text(originalPages), findsOneWidget);
    expect(s.positionData['paragraph'], 60);
    expect(s.positionData['offset'], 2);
    await tap(t, find.bySemanticsLabel('第 $originalPage 页'));
    expect(s.positionData['paragraph'], inExclusiveRange(0, 60));
  });

  testWidgets('只显示其他源的同书同作者命中，整本目录与进度随换源持久化', (t) async {
    final s = EditionStore();
    await mountReader(t, s);
    expect(s.reads, contains(('original', 'o2')));
    await openPicker(t);
    expect(s.queries.toSet(), {'b', 'other', 'offline', 'slow'});
    expect(find.text('书源 b'), findsOneWidget);
    expect(find.text('书源 other'), findsNothing);
    expect(find.text('书源 a'), findsNothing);
    await tap(t, find.text('书源 b'));
    s.lateResult.complete([]);
    await t.pumpAndSettle();
    expect(s.maps.first['chapter'], '*');
    expect(s.maps.first['targetBook'], 'alternative');
    expect(s.positionData['chapterId'], 'o2');
    expect(s.positionData['offset'], 2);
    expect(s.reads, contains(('alternative', 't2')));
    await tap(t, find.byTooltip('下一章'));
    expect(s.positionData['chapterId'], 't3');
    s.queries.clear();
    await openPicker(t);
    expect(s.queries, isNot(contains('b')));
    expect(find.text('书源 a'), findsOneWidget);
    await tap(t, find.byTooltip('关闭'));
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.text('目录 · 3 章'), findsOneWidget);
    expect(find.text('新书源独有章节'), findsOneWidget);
    await tap(t, find.text('继续阅读'));
    expect(s.positionData['chapterId'], 't3');
    expect(find.text('新书源独有章节'), findsWidgets);
  });

  testWidgets('切换失败仍可读原书，无匹配与关闭均不会写入换源', (t) async {
    final s = EditionStore()..chapterFails = true;
    s.lateResult.complete([]);
    await mountReader(t, s);
    await openPicker(t);
    await tap(t, find.text('书源 b'));
    expect(find.textContaining('新源正文读取失败'), findsOneWidget);
    expect(s.maps.single['id'], 'old-chapter');
    expect(s.positionData['chapterId'], 'o2');
    s.hasMatch = false;
    await openPicker(t);
    expect(find.text('没有找到匹配的小说'), findsOneWidget);
    await tap(t, find.byTooltip('关闭'));
    expect(s.maps.length, 1);
  });

  testWidgets('旧整书映射识别实际书源，可以从同书命中切回原版', (t) async {
    final s = EditionStore();
    s.maps.add({
      'id': 'original-*',
      'chapter': '*',
      'targetBook': 'alternative',
    });
    s.lateResult.complete([]);
    await mountReader(t, s);
    await openPicker(t);
    expect(s.queries, isNot(contains('b')));
    await tap(t, find.text('书源 a'));
    expect(s.maps.first['targetBook'], 'original');
    expect(s.reads, contains(('original', 'o2')));
    expect(s.positionData['chapterId'], 'o2');
  });

  testWidgets('关闭换源列表后不再派发排队中的查询', (t) async {
    final s = EditionStore()..sources = List.generate(35, (i) => 'slow$i');
    await mountReader(t, s);
    await openPicker(t);
    expect(s.queries.length, 12);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    s.lateResult.complete([]);
    await t.pumpAndSettle();
    expect(s.queries.length, 12);
    expect(s.maps.single['id'], 'old-chapter');
  });
}
