import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader/cover.dart';
import 'package:novel_reader/main.dart';
import 'package:novel_reader/reader.dart';
import 'package:novel_reader/store.dart';
import 'shelf_return_test.dart' show ShelfStore, book, other, mountShelf, tap;

class _HistoryStore extends ShelfStore {
  final editions = <Json>[
    {
      ...book,
      'id': 'earlier',
      'title': '《 山 路 》',
      'author': '作者：林舟',
      'origin': 'second',
    },
    book,
    {...book, 'id': 'homonym', 'author': '苏溪', 'origin': 'third'},
  ];
  final removed = <String>{};

  @override
  Future<dynamic> get(String route, [Map<String, String>? query]) async {
    if (route == 'library') {
      return {
        'shelf': [
          for (final b in editions)
            if (!removed.contains(b['id'])) b,
        ],
        'history': [
          ...editions,
          {...other, 'shelf': 0, 'cover': 'old-cover.jpg'},
        ],
      };
    }
    if (route == 'items/membership') {
      return [
        {'id': 'earlier-favorites', 'book': 'earlier', 'group': 'favorites'},
      ];
    }
    if (route == 'activity') {
      return [
        {
          'book': 'earlier',
          'title': '《 山 路 》',
          'chapter': '过 桥',
          'chapterId': 'other-b',
          'day': '今天',
          'last': 30,
        },
        {
          'book': 'book',
          'title': '山路',
          'chapter': '过桥',
          'chapterId': 'b',
          'day': '今天',
          'last': 40,
        },
        {
          'book': 'homonym',
          'title': '山路',
          'chapter': '初雪',
          'chapterId': 'snow',
          'day': '今天',
          'last': 25,
        },
        {
          'book': 'book',
          'title': '山路',
          'chapter': '进山',
          'chapterId': 'a',
          'day': '今天',
          'last': 20,
        },
        {
          'book': 'other',
          'title': '旧书',
          'chapter': '重逢',
          'chapterId': 'old',
          'day': '昨天',
          'last': 10,
        },
        {
          'book': 'earlier',
          'title': '《 山 路 》',
          'chapter': '另一章',
          'chapterId': 'oldest',
          'day': '前天',
          'last': 1,
        },
      ];
    }
    return super.get(route, query);
  }

  @override
  Future<dynamic> send(String method, String route, [Json? data]) async {
    if (route.endsWith('/shelf')) {
      expect(method, 'PUT');
      expect(data, {'shelf': false});
      removed.add(route.split('/')[1]);
      return 1;
    }
    return super.send(method, route, data);
  }
}

void main() {
  testWidgets('书架三个标签与搜索菜单共用顶栏，切换底栏后保留选择', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(402, 910);
    const insets = FakeViewPadding(top: 24, bottom: 24);
    tester.view.viewPadding = insets;
    tester.view.padding = insets;
    addTearDown(tester.view.reset);
    final store = ReaderStore(Directory.systemTemp, {});
    addTearDown(store.client.close);
    await tester.pumpWidget(BooksApp(store));
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('书架'));
    await tester.pumpAndSettle();

    final bar = find.byType(NavigationBar);
    expect(
      tester.widget<NavigationBar>(bar).labelBehavior,
      NavigationDestinationLabelBehavior.alwaysHide,
    );
    expect(tester.getSize(bar).height, 48 + insets.bottom);
    final chips = tester.widgetList<ChoiceChip>(find.byType(ChoiceChip));
    expect(chips.map((c) => (c.label as Text).data), ['书架', '历史', '本地']);
    expect(chips.first.selected, isTrue);
    final header = find.byType(AppBar);
    expect(
      find.descendant(of: header, matching: find.text('书架')),
      findsOneWidget,
    );
    final search = tester.getCenter(find.byTooltip('搜书'));
    for (final label in ['书架', '历史', '本地']) {
      final chip = find.widgetWithText(ChoiceChip, label);
      expect(tester.getCenter(chip).dy, closeTo(search.dy, 1));
      expect(tester.getTopRight(chip).dx, lessThan(search.dx));
    }
    expect(tester.getCenter(find.byTooltip('书架菜单')).dy, closeTo(search.dy, 1));
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    expect(find.text('还没有阅读记录'), findsOneWidget);
    tester.view.physicalSize = const Size(280, 910);
    await tester.pumpAndSettle();
    final narrowSearch = tester.getCenter(find.byTooltip('搜书'));
    await tester.drag(
      find.byKey(const PageStorageKey('shelf-tabs')),
      const Offset(-120, 0),
    );
    await tester.pumpAndSettle();
    expect(tester.getCenter(find.byTooltip('搜书')), narrowSearch);
    await tester.tap(find.text('本地'));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(402, 910);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('我的'));
    await tester.pumpAndSettle();
    expect(find.text('连接与同步'), findsOneWidget);
    await tester.tap(find.byTooltip('书架'));
    await tester.pumpAndSettle();
    final local = find.widgetWithText(ChoiceChip, '本地');
    expect(tester.widget<ChoiceChip>(local).selected, isTrue);
    expect(find.text('还没有本地电子书'), findsOneWidget);
    expect(find.text('导入电子书'), findsOneWidget);
  });

  testWidgets('书架列出所有书，本地只列出导入书，分组从书架菜单进入', (t) async {
    final store = ShelfStore()..firstWrite.complete();
    await mountShelf(t, store);
    expect(find.byType(ChoiceChip), findsNWidgets(3));
    expect(find.text('收藏夹'), findsNothing);
    expect(find.text('山路'), findsWidgets);
    expect(find.text('旧书'), findsWidgets);

    await tap(t, find.text('本地'));
    expect(find.text('山路'), findsWidgets);
    expect(find.text('旧书'), findsNothing);
    await tap(t, find.byTooltip('书架菜单'));
    await tap(t, find.widgetWithText(CheckedPopupMenuItem<String>, '收藏夹'));
    final shelf = find.widgetWithText(ChoiceChip, '书架');
    expect(t.widget<ChoiceChip>(shelf).selected, isTrue);
    expect(find.text('书架 · 收藏夹'), findsNothing);
    expect(find.text('旧书'), findsWidgets);
    expect(find.text('山路'), findsNothing);

    await tap(t, find.byTooltip('书架菜单'));
    final group = find.widgetWithText(CheckedPopupMenuItem<String>, '收藏夹');
    expect(t.widget<CheckedPopupMenuItem<String>>(group).checked, isTrue);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    await tap(t, shelf);
    expect(find.text('山路'), findsWidgets);
    expect(find.text('旧书'), findsWidgets);
  });

  testWidgets('书架和历史合并跨源同书，两个入口共用布局并续读最近章节', (t) async {
    final store = _HistoryStore()..firstWrite.complete();
    store.remote = {
      'chapterId': 'a',
      'paragraph': 0,
      'offset': 0,
      'version': 1,
    };
    await mountShelf(t, store);
    final covers = find.byWidgetPredicate(
      (w) => w is BookCover && w.book['id'] == 'book',
    );
    final listWidth = t.getSize(covers).width;
    expect(find.byType(BookCover), findsNWidgets(2));
    await tap(t, find.text('历史'));
    expect(covers, findsOneWidget);
    expect(t.getSize(covers).width, listWidth);
    expect(find.text('今天'), findsNothing);
    expect(find.text('昨天'), findsNothing);
    expect(find.textContaining('本 ·'), findsNothing);
    expect(find.text('进山'), findsNothing);
    expect(find.text('前天'), findsNothing);
    expect(
      t.getTopLeft(find.text('过桥')).dy,
      lessThan(t.getTopLeft(find.text('初雪')).dy),
    );
    final oldCover = find.byWidgetPredicate(
      (w) => w is BookCover && w.book['id'] == 'other',
    );
    expect(t.widget<BookCover>(oldCover).book['cover'], 'old-cover.jpg');
    expect(
      t.getTopLeft(oldCover).dy,
      greaterThan(t.getTopLeft(find.text('初雪')).dy),
    );

    await tap(t, find.byTooltip('书架菜单'));
    await tap(t, find.text('切换书架布局'));
    expect(store.state['shelfGrid'], isTrue);
    final gridWidth = t.getSize(covers.first).width;
    expect(gridWidth, greaterThan(listWidth));
    final recent = t.getCenter(find.text('过桥'));
    final earlier = t.getCenter(find.text('初雪'));
    expect(recent.dy, closeTo(earlier.dy, 1));
    expect(recent.dx, lessThan(earlier.dx));
    expect(t.getTopLeft(oldCover).dy, closeTo(t.getTopLeft(covers).dy, 1));
    expect(t.getCenter(oldCover).dx, greaterThan(earlier.dx));

    await tap(t, find.text('过桥'));
    expect(find.byType(ReaderPage), findsOneWidget);
    expect(t.widget<ReaderPage>(find.byType(ReaderPage)).book['id'], 'book');
    expect(store.writes.last, 'b');
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    await tap(t, find.widgetWithText(ChoiceChip, '书架'));
    expect(t.getSize(covers).width, gridWidth);
    await tap(t, find.byTooltip('我的'));
    await tap(t, find.text('阅读记录'));
    expect(t.getSize(covers.first).width, gridWidth);
    expect(find.text('昨天'), findsNothing);
    expect(find.textContaining('本 ·'), findsNothing);
    await tap(t, find.byTooltip('切换书架布局'));
    expect(store.state['shelfGrid'], isFalse);
    expect(t.getSize(covers.first).width, listWidth);
  });

  testWidgets('分组中的旧书源展示当前版本，移出书架同时移出所有同书版本', (t) async {
    final store = _HistoryStore()..firstWrite.complete();
    await mountShelf(t, store);
    await tap(t, find.byTooltip('书架菜单'));
    await tap(t, find.widgetWithText(CheckedPopupMenuItem<String>, '收藏夹'));
    final covers = find.byType(BookCover);
    expect(t.widget<BookCover>(covers).book['id'], 'book');
    await t.tap(find.byTooltip('书籍操作'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 350));
    await t.tap(find.text('移出书架'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 350));
    await tap(t, find.text('确认'));
    expect(store.removed, {'book', 'earlier'});
    expect(find.text('这一组暂无书籍'), findsOneWidget);
    await tap(t, find.widgetWithText(ChoiceChip, '书架'));
    expect(t.widget<BookCover>(covers).book['id'], 'homonym');
    await tap(t, find.text('历史'));
    expect(find.text('过桥'), findsOneWidget);
  });

  test('旧书库与离线书架按作品续读，本地标签仍打开本地文件', () {
    final online = {
      ...book,
      'id': 'online',
      'origin': 'source',
      'shelf': 0,
      'updated': 90,
    };
    final local = {...book, 'id': 'local', 'author': '', 'updated': 10};
    final sequel = {...book, 'id': 'sequel', 'title': '山路：归乡', 'updated': 50};
    final library = BookLibrary({
      'shelf': [sequel, local],
      'history': [local, sequel, online],
    });
    expect(library.history.map((v) => v['book']), ['online', 'sequel']);
    expect(library.shelfBooks().map((b) => b['id']), ['online', 'sequel']);
    expect(library.shelfBooks(members: {'local'}).single['id'], 'online');
    expect(library.shelfBooks(localOnly: true).map((b) => b['id']), [
      'sequel',
      'local',
    ]);

    final ambiguous = BookLibrary({
      'shelf': [
        local,
        online,
        {...book, 'id': 'homonym', 'author': '其他作者'},
      ],
    });
    expect(ambiguous.shelfBooks(), hasLength(3));
  });

  test('书源进度比缓存的章节记录更新时，书架和历史都采用新进度', () {
    final online = {...book, 'id': 'online', 'origin': 'web', 'shelf': 0};
    final library = BookLibrary({
      'shelf': [book],
      'history': [online],
      'activity': [
        {
          'book': 'online',
          'title': '山路',
          'chapter': '旧章',
          'day': '昨天',
          'last': 10,
        },
      ],
      'indicators': [
        {'id': 'online', 'chapterId': 'next', 'current': '回乡', 'stamp': 20},
      ],
    });
    expect(library.history.single['chapterId'], 'next');
    final current = library.shelfBooks().single;
    expect(current['id'], 'online');
    expect(library.progressFor(current)['current'], '回乡');
  });

  test('文字锚点在不同页面宽度和字号下都能定位', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final blocks = [
      {'text': '春风吹过山岗。' * 300, 'kind': 'p'},
    ];
    for (final width in [300.0, 700.0]) {
      final layout = LayoutPages(
        blocks,
        width,
        360,
        width == 300 ? 24 : 18,
        1.6,
        Colors.black,
      );
      final page = layout.pageFor(0, 500);
      expect(
        layout.pages[page].any((l) => l.start <= 500 && l.end > 500),
        isTrue,
      );
    }
  });
}
