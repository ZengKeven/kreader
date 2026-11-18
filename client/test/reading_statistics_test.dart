import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader/store.dart';

import 'shelf_return_test.dart' show ShelfStore, mountShelf, tap;

class StatisticsStore extends ShelfStore {
  @override
  Future<dynamic> get(String route, [Map<String, String>? query]) async {
    if (route != 'reading-time') return super.get(route, query);
    final first = DateTime.utc(2026, 8, 19);
    return <String, dynamic>{
      'todayMs': 3720000,
      'monthMs': 7200000,
      'totalMs': 10800000,
      'activeDays': 2,
      'days': [
        for (var day = 0; day < 92; day++)
          {
            'date': first
                .add(Duration(days: day))
                .toIso8601String()
                .substring(0, 10),
            'milliseconds': day == 91 ? 3720000 : 0,
          },
      ],
      'books': [
        for (var i = 1; i <= 11; i++)
          {'title': '作品 $i', 'author': '作者', 'milliseconds': (12 - i) * 60000},
      ],
    };
  }
}

void main() {
  testWidgets('底栏中间打开阅读统计，窄屏可查看热力图和前十名', (t) async {
    final store = StatisticsStore();
    await mountShelf(t, store);
    t.view.physicalSize = const Size(320, 850);
    final light = t.binding.platformDispatcher;
    addTearDown(light.clearPlatformBrightnessTestValue);
    light.platformBrightnessTestValue = Brightness.dark;
    await t.pumpAndSettle();
    final stats = find.byTooltip('阅读统计');
    final bar = find.byType(NavigationBar);
    expect(t.getCenter(stats).dx, closeTo(t.getCenter(bar).dx, 1));
    await tap(t, stats);
    expect(t.widget<NavigationBar>(bar).selectedIndex, 1);
    for (final label in ['今日', '本月', '累计', '本月活跃天数', '1 小时 2 分钟', '2 天']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('近三个月阅读热力图'), findsOneWidget);
    expect(find.byTooltip('2026年11月18日 · 1 小时 2 分钟'), findsOneWidget);
    expect(find.text('阅读时长排行'), findsOneWidget);
    expect(find.text('作品 10'), findsOneWidget);
    expect(find.text('作品 11'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('应用主题可立即切换亮暗，也能跟随系统变化', (t) async {
    final platform = t.binding.platformDispatcher;
    addTearDown(platform.clearPlatformBrightnessTestValue);
    platform.platformBrightnessTestValue = Brightness.dark;
    final store = ShelfStore();
    await mountShelf(t, store);
    await tap(t, find.byTooltip('我的'));
    Brightness brightness() =>
        Theme.of(t.element(find.byType(NavigationBar))).brightness;
    expect(brightness(), Brightness.dark);

    Future<void> select(String label) async {
      await tap(t, find.text('外观主题'));
      await tap(t, find.widgetWithText(RadioListTile<AppThemeMode>, label));
    }

    await select('亮色');
    expect(brightness(), Brightness.light);
    expect(store.state['appTheme'], 'light');
    platform.platformBrightnessTestValue = Brightness.light;
    await t.pumpAndSettle();
    await select('暗色');
    expect(brightness(), Brightness.dark);
    await select('跟随系统');
    expect(brightness(), Brightness.light);
    platform.platformBrightnessTestValue = Brightness.dark;
    await t.pumpAndSettle();
    expect(brightness(), Brightness.dark);
  });
}
