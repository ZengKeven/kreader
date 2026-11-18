import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader/main.dart';
import 'package:novel_reader/store.dart';

class SourceStore extends ReaderStore {
  final Map<String, Json> catalog;
  final deletes = <String>[];
  final searches = <String>[];
  String? failingId;

  SourceStore(int count)
    : catalog = {
        for (var i = 0; i < count; i++)
          's$i': {
            'id': 's$i',
            'name': '书源 $i',
            'groupName': i.isEven ? '科幻' : '历史',
            'enabled': i % 3 == 0 ? 0 : 1,
            'issue': i % 5 == 0 ? '规则不兼容' : '',
          },
      },
      super(Directory.systemTemp, {'token': 'test'});

  @override
  Future<void> persist() async {}

  @override
  Future<dynamic> get(String route, [Map<String, String>? query]) async {
    switch (route) {
      case 'library':
        return <String, dynamic>{};
      case 'sources':
        return catalog.values.toList();
      case 'search':
        searches.add(query!['source']!);
    }
    return [];
  }

  @override
  Future<dynamic> send(String method, String route, [Json? data]) async {
    expect(method, 'DELETE');
    expect(route, startsWith('sources/'));
    final id = route.substring('sources/'.length);
    deletes.add(id);
    if (id == failingId) throw ApiError(500, '删除失败', null);
    return catalog.remove(id) == null ? 0 : 1;
  }
}

Future<void> tap(WidgetTester tester, Finder target) async {
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> start(WidgetTester tester, SourceStore store) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(402, 910);
  addTearDown(tester.view.reset);
  addTearDown(store.client.close);
  await tester.pumpWidget(BooksApp(store));
  await tester.pumpAndSettle();
}

Future<void> openSources(WidgetTester tester) async {
  await tap(tester, find.byTooltip('我的'));
  await tap(tester, find.text('书源管理'));
  await tap(tester, find.text('多选'));
}

void main() {
  testWidgets('全选包含屏幕外的书源，筛选和取消勾选限定实际删除范围', (t) async {
    final store = SourceStore(352);
    await start(t, store);
    await openSources(t);
    await tap(t, find.text('书源 0'));
    expect(find.text('已选 1 项'), findsOneWidget);
    await tap(t, find.text('全选'));
    expect(find.text('已选 352 项'), findsOneWidget);
    await t.enterText(find.byType(EditableText), '科幻');
    await t.pumpAndSettle();
    expect(find.text('已选 176 项'), findsOneWidget);
    await tap(t, find.text('全选筛选结果'));
    expect(find.text('已选 0 项'), findsOneWidget);
    await tap(t, find.text('批量删除'));
    expect(find.text('取消'), findsNothing);
    await tap(t, find.text('全选筛选结果'));
    await tap(t, find.text('书源 0'));
    await tap(t, find.text('批量删除'));
    expect(find.text('删除选中的 175 个书源？'), findsOneWidget);
    await tap(t, find.text('取消'));
    expect(store.deletes, isEmpty);
    expect(find.text('已选 175 项'), findsOneWidget);
    await tap(t, find.text('批量删除'));
    await tap(t, find.text('删除'));
    expect(
      store.deletes,
      unorderedEquals([for (var i = 2; i < 352; i += 2) 's$i']),
    );
    expect(store.catalog.length, 177);
    expect(find.text('书源 0'), findsOneWidget);
    expect(find.text('已删除 175 个书源'), findsOneWidget);
  });

  testWidgets('单个书源失败后继续删除其他批次，重试只提交剩余项', (t) async {
    final store = SourceStore(21)..failingId = 's1';
    await start(t, store);
    await openSources(t);
    await tap(t, find.text('全选'));
    await tap(t, find.text('批量删除'));
    await tap(t, find.text('删除'));
    expect(store.catalog.keys, ['s1']);
    expect(find.text('已选 1 项'), findsOneWidget);
    store.failingId = null;
    await tap(t, find.text('批量删除'));
    expect(find.text('删除选中的 1 个书源？'), findsOneWidget);
    await tap(t, find.text('删除'));
    expect(store.catalog, isEmpty);
    expect(store.deletes.length, 22);
    expect(store.deletes.last, 's1');
    expect(find.text('多选'), findsOneWidget);
  });

  testWidgets('删除搜书页指定的书源后回到全部可用书源', (t) async {
    final store = SourceStore(3);
    await start(t, store);
    await tap(t, find.byTooltip('搜书'));
    await tap(t, find.text('全部启用的书源'));
    await tap(t, find.text('书源 1').last);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    await openSources(t);
    await tap(t, find.text('书源 1'));
    await tap(t, find.text('批量删除'));
    await tap(t, find.text('删除'));
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    await tap(t, find.byTooltip('书架'));
    await tap(t, find.byTooltip('搜书'));
    await t.enterText(find.byType(EditableText), '山路');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pumpAndSettle();
    expect(store.searches, ['s2']);
  });
}
