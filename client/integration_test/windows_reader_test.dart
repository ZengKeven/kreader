import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:file_selector/file_selector.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart'
    show FileSelectorPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:novel_reader/main.dart';
import 'package:novel_reader/reader.dart';
import 'package:novel_reader/store.dart';

class SamplePicker extends FileSelectorPlatform {
  final String path;
  SamplePicker(this.path);
  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => XFile(path);
}

Future<void> capture(WidgetTester tester, String name) async {
  final folder = Platform.environment['NOVEL_SCREENSHOTS'];
  if (folder == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(ValueKey('capture')),
  );
  final im = await boundary.toImage(pixelRatio: 1);
  final bytes = await im.toByteData(format: ui.ImageByteFormat.png);
  im.dispose();
  await File('$folder/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
}

Widget captured(Widget body) =>
    RepaintBoundary(key: ValueKey('capture'), child: body);
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('两份独立配置通过真实服务端上传、阅读、离线与冲突续读', (tester) async {
    final work = Platform.environment['NOVEL_TEST_WORK']!;
    final base = Platform.environment['NOVEL_TEST_URL']!;
    final key = (await File(
      '$work/server/access-token.txt',
    ).readAsString()).trim();
    final testRoot = await Directory(
      '$work/native-${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final a = await ReaderStore.open('${testRoot.path}/A');
    final b = await ReaderStore.open('${testRoot.path}/B');
    await a.connect(base, key);
    await b.connect(base, key);
    FileSelectorPlatform.instance = SamplePicker('$work/灯塔.epub');
    await tester.pumpWidget(captured(BooksApp(a)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('书架菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入电子书').last);
    for (int i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 80));
      if (find.textContaining('已加入书架 · 灯塔手记').evaluate().isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    expect(find.textContaining('已加入书架 · 灯塔手记'), findsOneWidget);
    final book = rows(
      (await a.refresh())['shelf'],
    ).firstWhere((v) => v['title'] == '灯塔手记');
    await tester.pumpWidget(const SizedBox.shrink());
    final novel = await a.upload(XFile('$work/山路.txt'), 'GB18030');
    final library = await b.refresh();
    expect(rows(library['shelf']).any((v) => v['id'] == book['id']), isTrue);
    final id = book['id'] as String;
    final chapters = await a.toc(id);
    expect(chapters.length, greaterThanOrEqualTo(3));
    for (final ch in [
      ...chapters.take(3),
      ...chapters.take(3).toList().reversed,
    ]) {
      expect(rows((await b.chapter(id, ch['id']))['blocks']), isNotEmpty);
    }
    final chapter = chapters.first['id'] as String;
    final anchor = await a.chapter(id, chapter);
    expect(
      rows(anchor['blocks']).firstWhere((v) => v['kind'] == 'image')['bytes'],
      isNotEmpty,
    );
    // Start at a known version, including reruns against the same QA service.
    await a.position(id);
    await a.remember(id, chapter, 10, 4, '');
    await a.flush();
    b.state['fontSize'] = 27;
    b.state['paged'] = true;
    expect((await b.position(id))?['paragraph'], 10);
    tester.view.physicalSize = const Size(520, 760);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(captured(BooksApp(b)));
    Future<void> until(Finder f) async {
      for (int i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 80));
        if (f.evaluate().isNotEmpty) return;
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      fail('未找到 $f');
    }

    await until(find.text('灯塔手记'));
    await tester.pumpAndSettle();
    await capture(tester, 'shelf-narrow');
    tester.view.physicalSize = const Size(1150, 760);
    await tester.pumpAndSettle();
    await capture(tester, 'shelf-wide');
    tester.view.physicalSize = const Size(520, 760);
    await tester.pumpAndSettle();
    await tester.tap(find.text('灯塔手记').first);
    await until(find.byType(PageView));
    expect(find.byType(ReaderPage), findsOneWidget);
    await tester.pumpAndSettle();
    await capture(tester, 'reader');
    await tester.tapAt(tester.getCenter(find.byType(ReaderPage)));
    await tester.pumpAndSettle();
    await capture(tester, 'overlay');
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await capture(tester, 'settings');
    Navigator.of(tester.element(find.text("全局"))).pop();
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getCenter(find.byType(ReaderPage)));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(PageView), const Offset(-550, 0));
    await tester.pumpAndSettle();
    await Future<void>.delayed(const Duration(milliseconds: 750));
    await tester.pump();
    await b.flush();
    final moved = await a.position(id);
    expect(moved?['paragraph'], greaterThanOrEqualTo(10));
    if (find.byType(BackButton).evaluate().isEmpty) {
      await tester.tapAt(tester.getCenter(find.byType(ReaderPage)));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final loaded = await b.toc(id);
    await b.chapter(id, loaded.first['id']);
    await b.persist();
    final reopened = await ReaderStore.open(b.dir.path);
    final disconnected = ReaderStore(
      reopened.dir,
      reopened.state,
      client: MockClient((_) async => throw http.ClientException('断网测试')),
    );
    expect((await disconnected.chapter(id, chapter))['blocks'], isNotEmpty);
    await disconnected.remember(id, chapter, 8, 1, '');
    await disconnected.flush();
    await a.remember(id, chapter, 16, 2, '');
    await a.flush();
    final back = await ReaderStore.open(b.dir.path);
    await back.flush();
    expect(back.map('conflicts')[id], isNotNull);
    await back.resolve(id, false);
    expect((await back.position(id))?['paragraph'], 16);
    await back.remember(id, chapter, 2, 0, '');
    await back.flush();
    expect((await a.position(id))?['paragraph'], 2);
    final txt = await a.toc(novel['id']);
    for (final c in txt) {
      await a.chapter(novel['id'], c['id']);
    }
    expect((a.state['cacheOrder'] as List).length, 30);
    expect(
      await File('${a.cache.path}/${txt.first['id']}.json').exists(),
      isFalse,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
  final fixturePath = Platform.environment['NOVEL_TEST_SOURCES'];
  if (fixturePath == null) return;
  testWidgets('实际书源从搜书到加入书架并阅读', (tester) async {
    final work = Platform.environment['NOVEL_TEST_WORK']!;
    final store = await ReaderStore.open('$work/online-ui');
    final secret = (await File(
      '$work/server/access-token.txt',
    ).readAsString()).trim();
    await store.connect(Platform.environment['NOVEL_TEST_URL']!, secret);
    final fixture = await File(fixturePath).readAsString();
    final imported = rows(
      await store.send('POST', 'sources/import', {'json': fixture}),
    );
    expect(
      imported.where((s) => s['imported'] == true && s['issue'] == ''),
      hasLength(2),
    );
    await tester.pumpWidget(BooksApp(store));
    Future<void> waitFor(Finder f) async {
      for (int i = 0; i < 260; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (f.evaluate().isNotEmpty) return;
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      final visible = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .take(22)
          .join(' / ');
      fail('未找到 $f；页面显示 $visible');
    }

    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('搜书'));
    await tester.pumpAndSettle();
    await waitFor(find.text('全部启用的书源'));
    await tester.tap(find.text('全部启用的书源'));
    await tester.pumpAndSettle();
    await waitFor(find.text('疯读小说（优+）').last);
    await tester.tap(find.text('疯读小说（优+）').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '绝世剑神');
    await tester.tap(find.byIcon(Icons.arrow_forward));
    final result = find.widgetWithText(ListTile, '绝世剑神');
    await waitFor(result);
    await tester.tap(result.first);
    await waitFor(find.text('第一章神秘小鼎'));
    final add = find.text('加入书架');
    if (add.evaluate().isNotEmpty) {
      await tester.tap(add);
      await waitFor(find.text('移出书架'));
    }
    await tester.tap(find.text('继续阅读'));
    await waitFor(find.byType(ReaderPage));
    await waitFor(find.byType(CustomScrollView));
    await tester.tapAt(tester.getCenter(find.byType(ReaderPage)));
    await tester.pumpAndSettle();
    await waitFor(find.byTooltip('下一章'));
    expect(find.byType(ReaderPage), findsOneWidget);
    await tester.tap(find.byTooltip('下一章'));
    await waitFor(find.text('第二章挑衅'));
    await tester.tap(find.byTooltip('下一章'));
    await tester.pump(const Duration(milliseconds: 80));
    final candidate = rows(
      (await store.refresh())['shelf'],
    ).firstWhere((v) => v['title'] == '绝世剑神');
    final onlineCh = await store.toc(candidate['id']);
    await waitFor(find.text(onlineCh[2]['title']));
    await tester.tap(find.byTooltip('上一章'));
    await waitFor(find.text('第二章挑衅'));
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    final lib = await store.refresh();
    expect(rows(lib['history']).any((b) => b['title'] == '绝世剑神'), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
