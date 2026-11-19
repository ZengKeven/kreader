import 'dart:io';
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader/reader.dart';
import 'package:novel_reader/store.dart';

class Fixture extends ReaderStore {
  final visited = <String>[], writes = <List<int>>[];
  Fixture()
    : super(Directory.systemTemp, {
        'appearance': {'mode': '无动画', 'fontSize': 20.0},
      });
  @override
  Future<List<Json>> toc(String id, {bool force = false}) async =>
      List.generate(7, (i) => {'id': 'c$i', 'title': '章节 $i'});
  @override
  Future<Json?> position(String id) async => {
    'chapterId': 'c2',
    'paragraph': 0,
    'offset': 0,
  };
  @override
  Future<List<Json>> items(String kind, [String? book]) async => [];
  @override
  Future<Json> chapter(String b, String id) async {
    visited.add(id);
    return {
      'blocks': List.generate(
        24,
        (i) => {'text': '$id 第 $i 段。' + ('月光越过山岭。' * 8), 'kind': 'p'},
      ),
    };
  }

  @override
  Future<void> persist() async {}
  @override
  Future<void> flush() async {}
  @override
  Future<void> remember(
    String book,
    String chapter,
    int p,
    int o,
    String q, {
    Json? visit,
  }) async {
    writes.add([int.parse(chapter.substring(1)), p, o]);
  }
}

class _ShortParagraphs extends Fixture {
  @override
  Future<Json> chapter(String b, String id) async => {
    'blocks': List.generate(24, (i) => {'text': '$id row $i', 'kind': 'p'}),
  };
}

void main() {
  testWidgets('安卓小数页宽下双向跨章，导航栏收起后仍保留原文位置', (t) async {
    t.view.devicePixelRatio = 2.625;
    t.view.physicalSize = const Size(1080, 2400);
    t.view.padding = const FakeViewPadding(top: 63, bottom: 63);
    addTearDown(t.view.reset);
    han = {'简体': {}, '繁体': {}};
    final s = Fixture();
    addTearDown(s.client.close);
    s.map('appearance')['fontSize'] = 28.0;
    await t.pumpWidget(
      MaterialApp(
        home: ReaderPage(s, {'id': 'one', 'title': '山路', 'origin': 'local'}),
      ),
    );
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('章节 2'), findsWidgets);

    Future<void> turn(double delta) async {
      await t.dragFrom(const Offset(200, 400), Offset(delta, 0));
      await t.pumpAndSettle();
      await t.pump(const Duration(milliseconds: 400));
    }

    await turn(300);
    expect(s.writes.last.first, 1);
    await turn(-300);
    expect(s.writes.last, [2, 0, 0]);
    await turn(-300);
    final anchor = s.writes.last.toList();
    expect(anchor[1] + anchor[2], greaterThan(0));
    t.view.padding = FakeViewPadding.zero;
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
    expect(s.writes.last, anchor);
  });

  testWidgets('信息栏使用垂直边距，关闭时正文用满阅读区域', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(400, 800);
    addTearDown(t.view.reset);
    han = {'简体': {}, '繁体': {}};
    final s = Fixture();
    addTearDown(s.client.close);
    final prefs = s.map('appearance')
      ..['marginY'] = 0
      ..['header'] = '无'
      ..['footer'] = '无';
    Future<void> render() async {
      await t.pumpWidget(
        MaterialApp(
          home: ReaderPage(s, {'id': 'one', 'title': '山路', 'origin': 'local'}),
        ),
      );
      await t.pumpAndSettle();
    }

    await render();
    final pager = find.byType(PageView);
    expect(t.getRect(pager).top, 0);
    expect(t.getRect(pager).bottom, 800);
    prefs['footer'] = '阅读进度';
    await render();
    final footer = find.textContaining(' 章   ·');
    expect(t.getRect(pager).top, 0);
    expect(t.getRect(pager).bottom, greaterThan(770));
    expect(
      t.getRect(footer).top,
      greaterThanOrEqualTo(t.getRect(pager).bottom),
    );

    prefs['marginY'] = 40;
    prefs['header'] = '章节';
    await render();
    expect(t.getRect(pager).top, 40);
    expect(t.getRect(pager).bottom, 760);
    prefs['mode'] = '滚动';
    await render();
    expect(t.getRect(find.byType(CustomScrollView)).bottom, 760);
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
  });

  testWidgets('分页和滚动都显示首行缩进，单书可以关闭', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(400, 800);
    addTearDown(t.view.reset);
    han = {'简体': {}, '繁体': {}};
    final store = _ShortParagraphs();
    addTearDown(store.client.close);
    final prefs = store.map('appearance')
      ..['font'] = 'Ahem'
      ..['marginX'] = 0
      ..['hideTitle'] = true;
    Future<void> render() async {
      await t.pumpWidget(
        MaterialApp(
          home: ReaderPage(store, {
            'id': 'one',
            'title': '山路',
            'origin': 'local',
          }),
        ),
      );
      await t.pumpAndSettle();
    }

    final line = find.text('c2 row 0', findRichText: true);
    await render();
    expect(t.getTopLeft(line).dx, 40);
    prefs['mode'] = '滚动';
    await render();
    expect(t.getTopLeft(line).dx, 40);

    store.map('perBook')['one'] = {'indent': 0};
    await render();
    expect(t.getTopLeft(line).dx, 0);
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
  });

  testWidgets('滚动正文在视口边缘隐藏半行，继续滚动可看到完整一行', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    t.view.devicePixelRatio = 1;
    const fontSize = 20.0, leading = 1.5;
    final painter = TextPainter(
      text: const TextSpan(
        text: 'c2 row 0',
        style: TextStyle(
          fontFamily: 'Ahem',
          fontSize: fontSize,
          height: leading,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final lineHeight = painter.computeLineMetrics().single.height;
    painter.dispose();
    t.view.physicalSize = Size(400, 4.5 * lineHeight);
    addTearDown(t.view.reset);
    han = {'简体': {}, '繁体': {}};
    final s = _ShortParagraphs();
    addTearDown(s.client.close);
    s.state['appearance'] = {
      'mode': '滚动',
      'font': 'Ahem',
      'fontSize': fontSize,
      'leading': leading,
      'paraGap': 0,
      'hideTitle': true,
      'header': '无',
      'footer': '无',
      'marginX': 0,
      'marginY': 0,
    };
    await t.pumpWidget(
      MaterialApp(
        home: ReaderPage(s, {'id': 'one', 'title': '山路', 'origin': 'local'}),
      ),
    );
    await t.pumpAndSettle();

    final view = find.byType(CustomScrollView);
    final row = find.text('c2 row 4', findRichText: true);
    final clip = find.ancestor(
      of: view,
      matching: find.byWidgetPredicate(
        (w) => w is ClipRect && w.clipper != null,
      ),
    );
    Rect paintRegion() => t
        .widget<ClipRect>(clip)
        .clipper!
        .getClip(t.getSize(clip))
        .shift(t.getTopLeft(clip));

    expect(t.getRect(row).bottom, greaterThan(t.getRect(view).bottom));
    expect(t.getRect(row).top, lessThan(t.getRect(view).bottom));
    expect(paintRegion().bottom, closeTo(t.getRect(row).top, .1));

    t.widget<CustomScrollView>(view).controller!.jumpTo(lineHeight / 2);
    await t.pumpAndSettle();
    expect(
      paintRegion().bottom,
      greaterThanOrEqualTo(t.getRect(row).bottom - .1),
    );
    expect(paintRegion().top, closeTo(lineHeight / 2, .1));
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
  });

  testWidgets('Android 沉浸阅读在顶部安全区内显示书名和时间并避开开孔', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(400, 800);
    t.view.padding = const FakeViewPadding(top: 36);
    t.view.viewPadding = const FakeViewPadding(top: 36);
    addTearDown(t.view.reset);
    void cutout(Rect bounds) => t.view.displayFeatures = [
      DisplayFeature(
        bounds: bounds,
        type: DisplayFeatureType.cutout,
        state: DisplayFeatureState.unknown,
      ),
    ];

    const middle = Rect.fromLTRB(160, 0, 240, 36);
    cutout(middle);
    han = {'简体': {}, '繁体': {}};
    final s = Fixture();
    addTearDown(s.client.close);
    final prefs = s.map('appearance')..['hideNavigationBar'] = true;
    Future<void> render() async {
      await t.pumpWidget(
        MaterialApp(
          home: ReaderPage(s, {'id': 'one', 'title': '山路', 'origin': 'local'}),
        ),
      );
      await t.pumpAndSettle();
    }

    final title = find.text('山路');
    final time = find.textContaining(RegExp(r'\d{1,2}:\d{2}'));
    final body = find.byType(PageView);
    await render();
    expect(t.getRect(title).right, lessThan(middle.left));
    expect(t.getRect(time).left, greaterThan(middle.right));
    expect(t.getRect(title).center.dy, closeTo(18, 1));
    expect(t.getRect(time).center.dy, closeTo(18, 1));
    expect(t.getTopLeft(body).dy, 36);

    const corner = Rect.fromLTRB(0, 0, 76, 36);
    cutout(corner);
    await t.pumpAndSettle();
    expect(t.getRect(title).left, greaterThan(corner.right));
    expect(t.getRect(title).bottom, lessThan(36));
    expect(t.getTopLeft(body).dy, 36);

    prefs['hideNavigationBar'] = false;
    await render();
    expect(title, findsNothing);
    expect(time, findsNothing);
    expect(t.getTopLeft(body).dy, greaterThan(36));
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
  });

  testWidgets('整屏三区、双向跨章、重排和九种模式', (t) async {
    await t.view.resetFakeSize();
    han = {'简体': {}, '繁体': {}};
    final s = Fixture();
    await t.pumpWidget(
      MaterialApp(
        home: ReaderPage(s, {'id': 'one', 'title': '山路', 'origin': 'local'}),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('章节 2'), findsWidgets);
    expect(s.visited.toSet(), containsAll(['c1', 'c2', 'c3']));
    expect(s.writes.every((e) => e[0] == 2), isTrue);
    final begin = s.writes.last.toList();
    final gesture = await t.startGesture(const Offset(290, 270));
    await gesture.moveBy(const Offset(-36, 0));
    await t.pump();
    await gesture.cancel();
    await t.pumpAndSettle();
    expect(s.writes.last, begin);
    Future<void> tap(double x) async {
      await t.tapAt(Offset(x, 260));
      await t.pumpAndSettle();
      await t.pump(const Duration(milliseconds: 450));
    }

    await tap(12);
    expect(find.text('章节 1'), findsWidgets);
    expect(s.writes.last[1], greaterThan(0));
    await tap(465);
    expect(find.text('章节 2'), findsOneWidget);
    for (int i = 0; i < 20; i++) {
      await tap(465);
    }
    for (int i = 0; i < 20; i++) {
      await tap(12);
    }
    await tap(240);
    expect(find.text('设置'), findsOneWidget);
    final prior = s.writes.last.toList();
    await t.tap(find.text('设置'));
    await t.pumpAndSettle();
    expect(find.text('翻页动画'), findsOneWidget);
    await t.tap(find.text('翻页动画'));
    await t.pumpAndSettle();
    for (final a in animations) {
      expect(find.text(a), findsWidgets);
    }
    await t.tap(find.text('滚动').last);
    await t.pumpAndSettle();
    Navigator.of(t.element(find.text("全局"))).pop();
    await t.pumpAndSettle();
    expect(s.writes.last, prior);
    await tap(240);
    expect(find.byType(CustomScrollView), findsOneWidget);
    final current = s.writes.last[0];
    for (int i = 0; i < 60 && s.writes.last[0] == current; i++) {
      await t.drag(find.byType(CustomScrollView), const Offset(0, -440));
      await t.pumpAndSettle();
      await t.pump(const Duration(milliseconds: 500));
    }
    await t.pumpAndSettle();
    await t.pump(const Duration(milliseconds: 500));
    final sc = t
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    expect(
      s.writes.last[0],
      greaterThan(current),
      reason:
          '${sc.offset} / ${sc.position.maxScrollExtent}, last: ${s.writes.last}, visits: ${s.visited}',
    );
    for (int i = 0; i < 60 && s.writes.last[0] > current; i++) {
      await t.drag(find.byType(CustomScrollView), const Offset(0, 440));
      await t.pumpAndSettle();
      await t.pump(const Duration(milliseconds: 500));
    }
    expect(s.writes.last[0], current);
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
  });
  test('替换、删除和插入后引用原段落的 UTF-16 偏移', () {
    final d = DisplayText('甲乙丙丁');
    d.replace('乙丙', (_) => '很长的新词');
    expect(d.indices.last, 4);
    expect(d.indices.length, d.value.length + 1);
    expect(d.indices[d.value.indexOf('丁')], 3);
    d.replace('甲', (_) => '');
    expect(d.indices.first, 1);
  });

  test('首行使用缩进后的宽度，续行使用正文宽度并保留原文定位', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const original = '😀ABCDEFGH';
    final display = DisplayText(original)..replace('😀', (_) => '');
    final layout = LayoutPages(
      [
        {'kind': 'heading', 'text': 'HEAD'},
        {
          'kind': 'p',
          'text': original,
          'display': display.value,
          'map': display.indices,
        },
        {'kind': 'p', 'text': 'XY\nZABCD'},
      ],
      100,
      40,
      20,
      1.5,
      Colors.black,
      {'font': 'Ahem', 'paraGap': 0, 'titleGap': 0},
    );

    final lines = layout.pages.expand((page) => page).toList();
    expect(lines.map((line) => line.span!.toPlainText()), [
      'HEAD',
      'ABC',
      'DEFGH',
      'XY',
      'ZABCD',
    ]);
    expect(lines.map((line) => line.indent), [0, 40, 0, 40, 0]);
    expect(lines.map((line) => (line.block, line.start, line.end)), [
      (0, 0, 4),
      (1, 2, 5),
      (1, 5, 10),
      (2, 0, 2),
      (2, 3, 8),
    ]);
    expect(layout.pages[layout.pageFor(1, 5)].single, lines[2]);
  });
}

extension FixtureView on TestFlutterView {
  Future<void> resetFakeSize() async {
    physicalSize = const Size(480, 620);
    devicePixelRatio = 1;
  }
}
