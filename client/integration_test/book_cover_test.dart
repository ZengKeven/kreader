import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:novel_reader/cover.dart';
import 'package:novel_reader/main.dart';
import 'package:novel_reader/store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('既有远程书、EPUB 和 TXT 封面在真实书架、详情与离线重开时显示', (tester) async {
    final run = jsonDecode(Platform.environment['COVER_QA']!) as Json;
    final folder = run['folder'] as String;
    final store = await ReaderStore.open('$folder/reader');
    await store.connect(
      'http://127.0.0.1:17955',
      (await File('$folder/server/access-token.txt').readAsString()).trim(),
    );
    final online = await store.get('books/' + run['online']) as Json;
    final epub = await store.get('books/' + run['epub']) as Json;
    final txt = await store.get('books/' + run['txt']) as Json;
    tester.view.physicalSize = const Size(560, 710);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const boundary = ValueKey('cover-capture');
    Future<void> check(Json book, bool original) async {
      final widget = find.byWidgetPredicate(
        (w) => w is BookCover && w.book['id'] == book['id'],
      );
      final image = find.descendant(
        of: widget,
        matching: find.byWidgetPredicate(
          (w) =>
              w is Image &&
              (original ? w.image is ResizeImage : w.image is AssetImage),
        ),
      );
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 80));
        if (image.evaluate().isNotEmpty &&
            find
                .descendant(
                  of: image,
                  matching: find.byWidgetPredicate(
                    (w) => w is RawImage && w.image != null,
                  ),
                )
                .evaluate()
                .isNotEmpty)
          return;
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
      fail('没有显示期望的封面 ' + book['title']);
    }

    await tester.pumpWidget(
      RepaintBoundary(key: boundary, child: BooksApp(store)),
    );
    await check(online, true);
    await check(epub, true);
    await check(txt, false);
    await tester.tap(find.byTooltip('书架菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('切换书架布局'));
    await tester.pumpAndSettle();
    await check(online, true);
    await check(epub, true);
    await check(txt, false);
    final screen = await tester
        .renderObject<RenderRepaintBoundary>(find.byKey(boundary))
        .toImage();
    final bytes = await screen.toByteData(format: ui.ImageByteFormat.png);
    screen.dispose();
    await File(
      Platform.environment['COVER_SCREENSHOT']!,
    ).writeAsBytes(bytes!.buffer.asUint8List());
    await tester.pumpWidget(MaterialApp(home: BookDetails(store, online)));
    await check(online, true);
    final offline = ReaderStore(store.dir, {
      ...store.state,
    }, client: MockClient((_) async => throw http.ClientException('offline')));
    await tester.pumpWidget(MaterialApp(home: BookDetails(offline, online)));
    await check(online, true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
