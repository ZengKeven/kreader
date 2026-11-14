part of 'reader.dart';

const animations = [
  '覆盖',
  '滑动',
  '仿真',
  'iOS 卷页',
  'Google 卷页',
  '视差',
  '滚动',
  '淡入淡出',
  '无动画',
];
final loadedFonts = <String>{};

extension ReaderSettings on _ReaderState {
  Future<void> restoreFonts() async {
    for (final e in store.map('fonts').entries) {
      if (!loadedFonts.contains(e.key)) {
        final f = File(e.value);
        if (await f.exists()) {
          final loader = FontLoader(e.key)
            ..addFont(f.readAsBytes().then((b) => ByteData.sublistView(b)));
          await loader.load();
          loadedFonts.add(e.key);
        }
      }
    }
  }

  Future<String?> field(String title, [String initial = '']) async {
    var v = initial;
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: TextFormField(
          initialValue: initial,
          autofocus: true,
          minLines: 1,
          maxLines: 5,
          onChanged: (s) => v = s,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, v),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Future<String?> choose(String title, List<String> options) =>
      showDialog<String>(
        context: context,
        builder: (c) => SimpleDialog(
          title: Text(title),
          children: [
            for (final v in options)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(c, v),
                child: Text(v),
              ),
          ],
        ),
      );
  Future<void> keyFor(String k, String title) async {
    final id = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Focus(
          autofocus: true,
          onKeyEvent: (_, e) {
            if (e is KeyDownEvent) Navigator.pop(c, e.logicalKey.keyId);
            return KeyEventResult.handled;
          },
          child: const Text('请按希望使用的按键'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (id != null) change(k, id);
  }

  Future<void> settings() async {
    if (modal) return;
    modal = true;
    stopAuto();
    try {
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        useSafeArea: true,
        builder: (ctx) => FractionallySizedBox(
          heightFactor: .78,
          child: DefaultTabController(
            length: 4,
            child: StatefulBuilder(
              builder: (ctx, update) {
                void put(String k, dynamic v) {
                  change(k, v);
                  update(() {});
                }

                Future<void> doIt(Future<void> Function() f) async {
                  try {
                    await f();
                    if (ctx.mounted) update(() {});
                  } catch (e) {
                    message(e);
                  }
                }

                Widget step(
                  String title,
                  String k,
                  double fallback,
                  double min,
                  double max,
                  double by,
                ) {
                  final v = numv(k, fallback).clamp(min, max).toDouble();
                  return ListTile(
                    title: Text(title),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: v <= min
                              ? null
                              : () => put(k, (v - by).clamp(min, max)),
                          icon: const Icon(Icons.remove),
                        ),
                        SizedBox(
                          width: 48,
                          child: Text(
                            v.toStringAsFixed(by < 1 ? 2 : 0),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        IconButton(
                          onPressed: v >= max
                              ? null
                              : () => put(k, (v + by).clamp(min, max)),
                          icon: const Icon(Icons.add),
                        ),
                      ],
                    ),
                  );
                }

                Widget sw(String label, String k, [bool def = false]) =>
                    SwitchListTile(
                      title: Text(label),
                      value: pref(k, def),
                      onChanged: (v) => put(k, v),
                    );
                Widget select(
                  String label,
                  String k,
                  String def,
                  List<String> vals,
                ) => ListTile(
                  title: Text(label),
                  trailing: Text(pref(k, def)),
                  onTap: () async {
                    final v = await choose(label, vals);
                    if (v != null) put(k, v);
                  },
                );
                Widget color(String title, String k, Color cur) => ListTile(
                  title: Text(title),
                  trailing: CircleAvatar(radius: 13, backgroundColor: cur),
                  onTap: () async {
                    final s = await field(
                      '$title · 六位十六进制',
                      cur.toARGB32().toRadixString(16).substring(2),
                    );
                    if (s == null) return;
                    final t = s.trim().replaceFirst('#', '');
                    final n = int.tryParse(t, radix: 16);
                    if (t.length != 6 || n == null) {
                      message('请输入六位色值，例如 302F29');
                      return;
                    }
                    put(k, 0xff000000 | n);
                  },
                );
                Widget group(String label, List<Widget> children) => Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 3, 0, 6),
                        child: Text(
                          label,
                          style: TextStyle(
                            color: Theme.of(ctx).colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Material(
                        color: Theme.of(ctx).colorScheme.surfaceContainer,
                        borderRadius: BorderRadius.circular(18),
                        clipBehavior: Clip.antiAlias,
                        child: Column(children: children),
                      ),
                    ],
                  ),
                );
                final fonts = [
                  'serif',
                  'sans-serif',
                  'monospace',
                  ...store.map('fonts').keys,
                ];
                Future<void> font() async {
                  final f = await openFile(
                    acceptedTypeGroups: [
                      const XTypeGroup(label: '字体', extensions: ['ttf', 'otf']),
                    ],
                  );
                  if (f == null) return;
                  final dir = Directory('${store.dir.path}/fonts');
                  await dir.create(recursive: true);
                  final path = '${dir.path}/${ReaderStore.eventId()}';
                  await f.saveTo(path);
                  final name = f.name.replaceFirst(
                    RegExp(r'\.(ttf|otf)$', caseSensitive: false),
                    '',
                  );
                  store.map('fonts')[name] = path;
                  await restoreFonts();
                  put('font', name);
                }

                Future<void> applyTheme(Json v) async {
                  final allowed = themeKeys;
                  final shared = pref('sharedLayout', false);
                  for (final k in v.keys.where(allowed.contains)) {
                    final x = v[k];
                    if (x is String || x is bool || x is num) {
                      if (!validSetting(k, x) ||
                          (shared &&
                              ![
                                'ink',
                                'paper',
                                'nightInk',
                                'nightPaper',
                                'eye',
                                'shade',
                              ].contains(k)))
                        continue;
                      change(k, x);
                    }
                  }
                }

                final tabs = [
                  [
                    group('阅读方式', [
                      SwitchListTile(
                        title: const Text('仅为本书设置'),
                        value: store.map('perBook').containsKey(book),
                        onChanged: (v) {
                          updateReader(() {
                            if (v) {
                              store.map('perBook')[book] = {...prefs};
                            } else {
                              store.map('perBook').remove(book);
                            }
                          });
                          store.persist();
                          update(() {});
                        },
                      ),
                      select('翻页动画', 'mode', mode, animations),
                      step('动画时长（毫秒）', 'speed', 260, 80, 650, 10),
                      sw('宽窗双页', 'spread'),
                      step('自动翻页间隔（秒）', 'autoSeconds', 8, 2, 120, 1),
                    ]),
                    group('正文排版', [
                      step('字号', 'fontSize', size, 12, 48, 1),
                      step('字距', 'spacing', 0, -1, 8, .25),
                      step('行距', 'leading', 1.65, 1.0, 3, .1),
                      step('段距', 'paraGap', 12, 0, 56, 1),
                      step('首行缩进（字）', 'indent', 0, 0, 4, 1),
                      select('字体', 'font', 'serif', fonts),
                      ListTile(
                        title: const Text('导入 TTF / OTF 字体'),
                        onTap: () => doIt(font),
                      ),
                      sw('粗体', 'bold'),
                      sw('斜体', 'italic'),
                      select('正文对齐', 'align', '居左', ['居左', '居中', '居右']),
                      sw('页底对齐', 'bottom'),
                    ]),
                    group('章节标题', [
                      sw('隐藏标题', 'hideTitle'),
                      step('标题字号', 'titleSize', size + 3, 12, 54, 1),
                      step('标题留白', 'titleGap', 6, 0, 60, 1),
                      select('标题字体', 'titleFont', 'serif', fonts),
                      select('标题对齐', 'titleAlign', '居左', ['居左', '居中', '居右']),
                    ]),
                    group('纸张与颜色', [
                      sw('夜间阅读', 'night'),
                      color('字体颜色', night ? 'nightInk' : 'ink', ink),
                      color('背景颜色', night ? 'nightPaper' : 'paper', paper),
                      sw('护眼色', 'eye'),
                      step('屏幕遮光', 'shade', 0, 0, .75, .05),
                      step('水平边距', 'marginX', 26, 0, 120, 2),
                      step('垂直边距', 'marginY', 14, 0, 80, 2),
                      ListTile(
                        title: const Text('选择背景图片'),
                        onTap: () => doIt(() async {
                          final f = await openFile(
                            acceptedTypeGroups: [
                              const XTypeGroup(
                                label: '图片',
                                extensions: ['jpg', 'jpeg', 'png', 'webp'],
                              ),
                            ],
                          );
                          if (f != null) {
                            final path =
                                '${store.dir.path}/paper-${ReaderStore.eventId()}';
                            await f.saveTo(path);
                            put('backgroundFile', path);
                          }
                        }),
                      ),
                      ListTile(
                        title: const Text('使用纯色背景'),
                        onTap: () => put('backgroundFile', ''),
                      ),
                    ]),
                  ],
                  [
                    group('点击区域 · 点击格子更换动作', [
                      GridView.count(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        crossAxisCount: 3,
                        childAspectRatio: 2.2,
                        children: [
                          for (var i = 0; i < 9; i++)
                            OutlinedButton(
                              onPressed: () async {
                                final a = await choose('选择点击动作', [
                                  '上一页',
                                  '下一页',
                                  '菜单',
                                  '目录',
                                  '设置',
                                  '书签',
                                  '夜间',
                                  '无',
                                ]);
                                if (a != null) {
                                  final z = List<String>.from(
                                    pref('zones', defaultZones),
                                  );
                                  z[i] = a;
                                  if (!z.contains('菜单')) {
                                    message('至少保留一个菜单区域');
                                    return;
                                  }
                                  put('zones', z);
                                }
                              },
                              child: Text(pref('zones', defaultZones)[i]),
                            ),
                        ],
                      ),
                      ListTile(
                        title: const Text('恢复左翻、中间菜单、右翻'),
                        onTap: () => put('zones', defaultZones),
                      ),
                    ]),
                    group('底栏布局', [
                      for (final action in ['目录', '日夜', '自动', '设置'])
                        CheckboxListTile(
                          title: Text(action),
                          value:
                              (pref('toolbar', ['目录', '日夜', '自动', '设置'])
                                      as List)
                                  .contains(action),
                          onChanged: action == '设置'
                              ? null
                              : (v) {
                                  final values = List<String>.from(
                                    pref('toolbar', ['目录', '日夜', '自动', '设置']),
                                  );
                                  if (v == true) {
                                    values.add(action);
                                  } else {
                                    values.remove(action);
                                  }
                                  put('toolbar', values);
                                },
                        ),
                    ]),
                    group('按键', [
                      if (Platform.isAndroid) sw('音量键翻页', 'volume'),
                      ListTile(
                        title: const Text('自定义上一页按键'),
                        onTap: () => keyFor('prevKey', '上一页按键'),
                      ),
                      ListTile(
                        title: const Text('自定义下一页按键'),
                        onTap: () => keyFor('nextKey', '下一页按键'),
                      ),
                    ]),
                  ],
                  [
                    group('页面信息', [
                      select('顶栏', 'header', '章节', [
                        '无',
                        '书名',
                        '章节',
                        '页码',
                        '阅读进度',
                        '时间',
                        if (Platform.isAndroid) '电量',
                      ]),
                      select('底栏', 'footer', '阅读进度', [
                        '无',
                        '书名',
                        '章节',
                        '页码',
                        '阅读进度',
                        '时间',
                        if (Platform.isAndroid) '电量',
                      ]),
                      select('信息栏字体', 'infoFont', 'sans-serif', fonts),
                      step('信息字号', 'infoSize', 12, 9, 18, 1),
                    ]),
                  ],
                  [
                    group('阅读主题', [
                      sw('不同主题共用排版', 'sharedLayout'),
                      ListTile(
                        title: const Text('保存当前主题'),
                        onTap: () => doIt(() async {
                          final n = await field('主题名称');
                          if (n == null || n.trim().isEmpty) return;
                          store.map('themes')[n] = {
                            for (final k in themeKeys)
                              if (pref(k, null) != null) k: pref(k, null),
                          };
                          await store.persist();
                        }),
                      ),
                      for (final n in store.map('themes').keys)
                        ListTile(
                          leading: const Icon(Icons.palette_outlined),
                          title: Text(n),
                          onTap: () =>
                              doIt(() => applyTheme(store.map('themes')[n])),
                        ),
                      ListTile(
                        title: const Text('导出当前主题 JSON'),
                        onTap: () => doIt(() async {
                          final data = jsonEncode({
                            for (final k in themeKeys)
                              if (pref(k, null) != null) k: pref(k, null),
                          });
                          final loc = await getSaveLocation(
                            suggestedName: '阅读主题.json',
                          );
                          if (loc != null)
                            await XFile.fromData(
                              Uint8List.fromList(utf8.encode(data)),
                              mimeType: 'application/json',
                              name: '阅读主题.json',
                            ).saveTo(loc.path);
                        }),
                      ),
                      ListTile(
                        title: const Text('导入主题 JSON'),
                        onTap: () => doIt(() async {
                          final f = await openFile(
                            acceptedTypeGroups: [
                              const XTypeGroup(
                                label: '阅读主题',
                                extensions: ['json'],
                              ),
                            ],
                          );
                          if (f != null)
                            await applyTheme(
                              jsonDecode(await f.readAsString()),
                            );
                        }),
                      ),
                    ]),
                    group('阅读工具', [
                      select('中文转换', 'script', '原文', ['原文', '简体', '繁体']),
                      sw('长段分行', 'resegment'),
                      sw('显示段评气泡', 'bubbles', true),
                    ]),
                  ],
                ];
                return Column(
                  children: [
                    const TabBar(
                      tabs: [
                        Tab(text: '全局'),
                        Tab(text: '菜单'),
                        Tab(text: '信息'),
                        Tab(text: '更多'),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          for (final content in tabs)
                            ListView(
                              padding: const EdgeInsets.only(bottom: 24),
                              children: content,
                            ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
    } finally {
      modal = false;
    }
  }
}

const themeKeys = {
  'fontSize',
  'spacing',
  'leading',
  'paraGap',
  'indent',
  'font',
  'bold',
  'italic',
  'align',
  'bottom',
  'titleSize',
  'titleFont',
  'titleAlign',
  'titleGap',
  'hideTitle',
  'ink',
  'paper',
  'nightInk',
  'nightPaper',
  'eye',
  'shade',
  'marginX',
  'marginY',
  'infoSize',
  'infoFont',
  'header',
  'footer',
  'mode',
};
bool validSetting(String k, dynamic x) {
  const ranges = {
    'fontSize': (12, 48),
    'spacing': (-1, 8),
    'leading': (1, 3),
    'paraGap': (0, 56),
    'indent': (0, 4),
    'titleSize': (12, 54),
    'titleGap': (0, 60),
    'shade': (0, .75),
    'marginX': (0, 120),
    'marginY': (0, 80),
    'infoSize': (9, 18),
    'ink': (0, 0xffffffff),
    'paper': (0, 0xffffffff),
    'nightInk': (0, 0xffffffff),
    'nightPaper': (0, 0xffffffff),
  };
  if (ranges.containsKey(k)) {
    final r = ranges[k]!;
    return x is num &&
        x.isFinite &&
        x >= r.$1 &&
        x <= r.$2 &&
        (!['ink', 'paper', 'nightInk', 'nightPaper'].contains(k) || x is int);
  }
  if (['eye', 'bold', 'italic', 'bottom', 'hideTitle'].contains(k))
    return x is bool;
  return x is String && (k != 'mode' || animations.contains(x));
}
