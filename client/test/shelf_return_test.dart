import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader/main.dart';
import 'package:novel_reader/reader.dart';
import 'package:novel_reader/store.dart';

const book = {
  'id': 'book',
  'title': '山路',
  'author': '林舟',
  'origin': 'local',
  'url': '.txt',
  'shelf': 1,
};
const other = {
  'id': 'other',
  'title': '旧书',
  'author': '作者',
  'origin': 'source',
  'url': '/other',
  'shelf': 1,
};
const chapters = [
  {'id': 'a', 'title': '进山'},
  {'id': 'b', 'title': '过桥'},
];

class ShelfStore extends ReaderStore {
  ShelfStore({this.paragraphCount = 1})
    : super(Directory.systemTemp, {
        'token': 'test',
        'appearance': <String, dynamic>{'mode': '无动画'},
      });
  final int paragraphCount;
  final firstWrite = Completer<void>();
  final writes = <String>[];
  final libraryReads = <String?>[];
  Json? remote;
  bool offline = false;
  @override
  Future<void> persist() async {}
  @override
  Future<List<Json>> toc(String id, {bool force = false}) async => chapters;
  @override
  Future<Json> chapter(String book, String id) async => {
    'blocks': List.generate(
      paragraphCount,
      (_) => {'kind': 'p', 'text': '第 $id 章的正文。'},
    ),
  };
  @override
  Future<dynamic> get(String route, [Map<String, String>? query]) async {
    if (offline) throw const SocketException('离线');
    final current = remote;
    final chapter = current == null
        ? null
        : chapters.firstWhere((c) => c['id'] == current['chapterId']);
    switch (route) {
      case 'library':
        libraryReads.add(current?['chapterId']);
        return <String, dynamic>{
          'shelf': (current?['updated'] ?? 0) < 2
              ? [
                  {...other, 'updated': 2},
                  {...book, 'updated': current?['updated'] ?? 0},
                ]
              : [book, other],
          'history': [if (current != null) book, other],
          'indicators': [
            if (chapter != null)
              {
                'id': 'book',
                'current': chapter['title'],
                'ord': chapters.indexOf(chapter),
                'total': 2,
                'latest': '过桥',
                'stamp': 1,
              },
          ],
        };
      case 'activity':
        return [
          if (chapter != null)
            {
              'book': 'book',
              'title': '山路',
              'chapter': chapter['title'],
              'chapterId': chapter['id'],
              'day': '今天',
              'last': 1,
            },
        ];
      case 'books/book':
        return book;
      case 'books/book/progress':
        return current;
      case 'items/group':
        return [
          {'id': 'favorites', 'name': '收藏夹'},
        ];
      case 'items/membership':
        return [
          {'id': 'other-favorites', 'book': 'other', 'group': 'favorites'},
        ];
      default:
        return [];
    }
  }

  @override
  Future<dynamic> send(String method, String route, [Json? data]) async {
    if (route == 'reading-time') {
      if (offline) throw const SocketException('离线');
      return null;
    }
    expectSync(route, 'books/book/progress');
    if (offline) throw const SocketException('离线');
    final item = data!;
    expectSync(item.containsKey('visit'), isFalse);
    writes.add(item['chapterId']);
    await firstWrite.future;
    expectSync(item['version'], remote?['version'] ?? 0);
    remote = {
      ...item,
      'version': (item['version'] as int) + 1,
      'updated': DateTime.now().millisecondsSinceEpoch,
    };
    return remote;
  }
}

Future<void> mountShelf(WidgetTester t, ShelfStore s) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = const Size(400, 850);
  addTearDown(t.view.reset);
  addTearDown(s.client.close);
  han = {'简体': {}, '繁体': {}};
  await t.pumpWidget(BooksApp(s));
  await t.pumpAndSettle();
}

Future<void> tap(WidgetTester t, Finder finder) async {
  await t.tap(finder);
  await t.pumpAndSettle();
}

void expectLatest(WidgetTester t) {
  expect(find.text('进度：过桥'), findsOneWidget);
  expect(
    t.getTopLeft(find.text('山路').last).dy,
    lessThan(t.getTopLeft(find.text('旧书').last).dy),
  );
}

void main() {
  testWidgets('跨章立即系统返回，旧进度上传期间书架先显示最新一章，随后同步', (t) async {
    final s = ShelfStore();
    await mountShelf(t, s);
    await tap(t, find.text('山路').last);
    expect(s.writes, ['a']);
    await t.tapAt(const Offset(380, 400));
    await t.pump();
    expect(find.text('过桥'), findsWidgets);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expectLatest(t);
    expect(s.libraryReads, [null]);
    s.firstWrite.complete();
    await t.pumpAndSettle();
    expect(s.writes, ['a', 'b']);
    expect(s.map('pending'), isEmpty);
    expect(s.libraryReads.last, 'b');
    expectLatest(t);
    await tap(t, find.byTooltip('我的'));
    await tap(t, find.text('阅读记录'));
    expect(find.text('过桥'), findsOneWidget);
  });

  testWidgets('重读已记录的同一页后，这本书也会排在最前', (t) async {
    final s = ShelfStore()..firstWrite.complete();
    s.remote = {
      'chapterId': 'b',
      'paragraph': 0,
      'offset': 0,
      'quote': '第 b 章的正文。',
      'version': 1,
      'updated': 1,
    };
    await mountShelf(t, s);
    expect(
      t.getTopLeft(find.text('旧书').last).dy,
      lessThan(t.getTopLeft(find.text('山路').last).dy),
    );
    await tap(t, find.text('山路').last);
    expect(s.writes, isEmpty);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expectLatest(t);
    expect(s.writes, ['b']);
  });

  testWidgets('从详情阅读后离线返回，书架排序、进度和阅读记录立即更新', (t) async {
    final s = ShelfStore()..firstWrite.complete();
    await mountShelf(t, s);
    await t.longPress(find.text('山路').last);
    await t.pump();
    await t.pump(const Duration(milliseconds: 350));
    await tap(t, find.text('详情与目录'));
    await tap(t, find.text('过桥'));
    await t.tapAt(const Offset(200, 400));
    await t.pumpAndSettle();
    s.offline = true;
    await tap(t, find.byTooltip('Back'));
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expectLatest(t);
    await tap(t, find.text('历史'));
    expect(find.text('过桥'), findsOneWidget);
    await tap(t, find.text('过桥'));
    expect(find.byType(ReaderPage), findsOneWidget);
    expect(find.text('过桥'), findsWidgets);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.text('过桥'), findsOneWidget);
  });
}
