import 'dart:io';
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
    String q,
  ) async {
    writes.add([int.parse(chapter.substring(1)), p, o]);
  }
}

void main() {
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
}

extension FixtureView on TestFlutterView {
  Future<void> resetFakeSize() async {
    physicalSize = const Size(480, 620);
    devicePixelRatio = 1;
  }
}
