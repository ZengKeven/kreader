import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:novel_reader/main.dart';
import 'package:novel_reader/reader.dart';

import '../test/shelf_return_test.dart' show ShelfStore;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android 阅读和打开设置时隐藏状态栏与导航栏，退出恢复，重开沿用设置', (t) async {
    final store = ShelfStore(paragraphCount: 160)..firstWrite.complete();
    addTearDown(store.client.close);
    store.map('appearance')['header'] = '页码';
    await t.pumpWidget(BooksApp(store));
    await t.pumpAndSettle();
    final bottom = t.view.viewPadding.bottom;
    final top = t.view.viewPadding.top;
    expect(top, greaterThan(0), reason: '在竖屏模拟器上先显示系统状态栏');
    expect(bottom, greaterThan(0), reason: '竖屏设备上应先显示系统导航栏');

    Future<void> checkInsets(bool hidden) async {
      final expectedTop = hidden ? 0.0 : top;
      final expectedBottom = hidden ? 0.0 : bottom;
      for (
        var i = 0;
        i < 40 &&
            (t.view.viewPadding.top != expectedTop ||
                t.view.viewPadding.bottom != expectedBottom);
        i++
      ) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(t.view.viewPadding.bottom, expectedBottom);
      expect(t.view.viewPadding.top, expectedTop);
    }

    Future<void> openReader() async {
      await t.tap(find.text('山路').last);
      await t.pumpAndSettle();
    }

    Future<void> toggleSystemBars(bool hidden) async {
      final center = t.getCenter(find.byType(ReaderPage));
      await t.tapAt(center);
      await t.pumpAndSettle();
      await t.tap(find.text('设置'));
      await t.pumpAndSettle();
      await t.tap(find.text('信息'));
      await t.pumpAndSettle();
      await t.tap(find.text('隐藏状态栏和导航栏'));
      await t.pumpAndSettle();
      await checkInsets(hidden);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      await t.tapAt(center);
      await t.pumpAndSettle();
    }

    void checkHeader() {
      final title = t.getRect(find.text('山路'));
      final time = t.getRect(find.textContaining(RegExp(r'\d{1,2}:\d{2}')));
      expect(title.right, lessThan(time.left));
      expect(title.center.dy, closeTo(time.center.dy, 1));
    }

    await openReader();
    final pageNumber = find.textContaining(RegExp(r'^1 / \d+$'));
    expect(pageNumber, findsOneWidget);
    expect(find.text('1 / 1'), findsNothing);
    await toggleSystemBars(true);
    await checkInsets(true);
    checkHeader();
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    await checkInsets(false);

    await openReader();
    await checkInsets(true);
    checkHeader();
    await toggleSystemBars(false);
    await checkInsets(false);
    expect(pageNumber, findsOneWidget);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
  }, skip: !Platform.isAndroid);
}
