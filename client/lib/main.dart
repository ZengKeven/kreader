import 'dart:async';
import 'dart:convert';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'cover.dart';
import 'reader.dart';
import 'reading_statistics.dart';
import 'store.dart';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final profile = args.where((a) => a.startsWith('--profile=')).firstOrNull;
  runApp(BooksApp(await ReaderStore.open(profile?.substring(10))));
}

class BooksApp extends StatelessWidget {
  final ReaderStore store;
  const BooksApp(this.store, {super.key});

  static final _light = _theme(Brightness.light);
  static final _dark = _theme(Brightness.dark);

  static ThemeData _theme(Brightness brightness) {
    final light = brightness == Brightness.light;
    final colors = ColorScheme.fromSeed(
      seedColor: const Color(0xff5a5b87),
      brightness: brightness,
      surface: light ? const Color(0xfffaf9fa) : null,
    );
    return ThemeData(
      colorScheme: colors,
      useMaterial3: true,
      appBarTheme: AppBarTheme(
        backgroundColor: light
            ? const Color(0xfff1eeee)
            : colors.surfaceContainer,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AppThemeMode>(
    valueListenable: store.appTheme,
    builder: (_, mode, _) => MaterialApp(
      title: '个人书房',
      debugShowCheckedModeBanner: false,
      theme: _light,
      darkTheme: _dark,
      themeMode: ThemeMode.values.byName(mode.name),
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: readerSystemBars(Theme.of(context).brightness),
        child: child!,
      ),
      home: Home(store),
    ),
  );
}

enum _HomePage {
  shelf('书架'),
  search('搜书'),
  history('阅读记录'),
  sources('书源管理'),
  connection('连接与同步'),
  stats('阅读统计'),
  account('我的');

  const _HomePage(this.title);
  final String title;
}

class Home extends StatefulWidget {
  final ReaderStore store;
  const Home(this.store, {super.key});
  @override
  State<Home> createState() => _HomeState();
}

enum _ShelfTab {
  books('书架'),
  history('历史'),
  local('本地');

  const _ShelfTab(this.label);
  final String label;
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  ReaderStore get s => widget.store;
  _HomePage page = _HomePage.shelf;
  int searchId = 0, refreshId = 0;
  _ShelfTab shelfTab = _ShelfTab.books;
  bool get shelfGrid => s.state['shelfGrid'] == true;
  String? shelfGroup;
  List<Json> groups = [], memberships = [];
  bool working = false, searching = false, online = false;
  String status = '', filter = '', sourceId = '', searchMessage = '';
  final keyword = TextEditingController(),
      addr = TextEditingController(),
      secret = TextEditingController();
  List<Json> sources = [], hits = [];
  List<String> failures = [];
  Set<String>? sourceSelection;
  Iterable<Json> get searchableSources => sources.where(searchableSource);
  Iterable<Json> get filteredSources =>
      sources.where((v) => ('${v['name']} ${v['groupName']}').contains(filter));
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    addr.text = s.base;
    secret.text = s.token;
    if (s.token.isEmpty) page = _HomePage.connection;
    unawaited(s.flushReadingTime());
    refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    addr.dispose();
    secret.dispose();
    keyword.dispose();
    searchId++;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(s.flushReadingTime());
    if (state == AppLifecycleState.resumed)
      refresh();
    else {
      s.flush();
    }
  }

  void note(String text) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> refresh({bool readingOnly = false}) async {
    if (!mounted || s.token.isEmpty) return;
    final run = readingOnly ? refreshId : ++refreshId;
    try {
      await s.refresh(withActivity: true);
      if (!mounted || run != refreshId) return;
      setState(() {
        online = true;
        status = '';
      });
      if (readingOnly) return;
      final extra = await Future.wait([
        s.get('sources'),
        s.items('group'),
        s.items('membership'),
      ]);
      if (mounted && run == refreshId)
        setState(() {
          sources = rows(extra[0]);
          groups = rows(extra[1]);
          memberships = rows(extra[2]);
          if (!groups.any((g) => g['id'] == shelfGroup)) shelfGroup = null;
          retainVisibleSourceSelection();
          if (sourceId.isNotEmpty &&
              !searchableSources.any((v) => v['id'] == sourceId)) {
            sourceId = '';
          }
        });
    } catch (e) {
      if (mounted && run == refreshId)
        setState(() {
          online = false;
          status = e.toString();
        });
    }
  }

  void refreshAfterReading() {
    if (!mounted) return;
    setState(() {});
    unawaited(refresh(readingOnly: true));
  }

  Future<void> action(Future<void> Function() fn) async {
    if (working) return;
    setState(() => working = true);
    try {
      await fn();
    } catch (e) {
      note(e.toString());
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> read(Json book, [String? chapter]) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ReaderPage(s, book, selected: chapter, resumeSelected: true),
      ),
    );
    refreshAfterReading();
  }

  Future<void> details(Json book) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => BookDetails(s, book)),
    );
    refreshAfterReading();
  }

  Future<void> upload() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: '小说',
          extensions: ['txt', 'epub'],
          mimeTypes: ['text/plain', 'application/epub+zip'],
          uniformTypeIdentifiers: [
            'public.plain-text',
            'org.idpf.epub-container',
          ],
        ),
      ],
    );
    if (file == null || !mounted) return;
    String encoding = 'auto';
    if (file.name.toLowerCase().endsWith('.txt')) {
      String preview = '';
      final bytes = await file
          .openRead(0, (await file.length()).clamp(0, 512))
          .expand((b) => b)
          .toList();
      Future<void> decodePreview(String enc) async {
        try {
          final result = await s.send('POST', 'preview', {
            'bytes': base64Encode(bytes),
            'encoding': enc,
          });
          preview = result['text'];
        } catch (_) {
          preview = utf8.decode(bytes, allowMalformed: true);
        }
      }

      await decodePreview(encoding);
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, update) => AlertDialog(
            title: Text(file.name),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: encoding,
                    decoration: const InputDecoration(labelText: '文本编码'),
                    items:
                        const ['auto', 'utf-8', 'GB18030', 'utf-16', 'utf-16BE']
                            .map(
                              (v) => DropdownMenuItem(
                                value: v,
                                child: Text(v == 'auto' ? '自动识别' : v),
                              ),
                            )
                            .toList(),
                    onChanged: (v) async {
                      encoding = v!;
                      await decodePreview(v);
                      if (ctx.mounted) update(() {});
                    },
                  ),
                  const SizedBox(height: 12),
                  Text(preview, maxLines: 6, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('上传到书架'),
              ),
            ],
          ),
        ),
      );
      if (ok != true) return;
    }
    setState(() => status = '正在上传并解析 ${file.name}…');
    final b = await s.upload(file, encoding);
    await refresh();
    if (mounted)
      setState(() {
        page = _HomePage.shelf;
        shelfTab = _ShelfTab.local;
        shelfGroup = null;
      });
    note('已加入书架 · ${b['title']}');
  }

  Future<void> editSource([Json? source]) async {
    String raw = source == null
        ? ''
        : (await s.get('sources/${source['id']}'))['raw'];
    if (!mounted) return;
    final controller = TextEditingController(text: raw);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(source == null ? '导入书源' : '编辑书源'),
        content: SizedBox(
          width: 530,
          child: TextField(
            controller: controller,
            maxLines: 9,
            decoration: const InputDecoration(
              hintText: '粘贴 Legado JSON 或书源合集 URL',
            ),
          ),
        ),
        actions: [
          if (source == null)
            TextButton(
              onPressed: () async {
                final f = await openFile(
                  acceptedTypeGroups: [
                    const XTypeGroup(
                      label: 'JSON',
                      extensions: ['json'],
                      mimeTypes: ['application/json', 'text/plain'],
                      uniformTypeIdentifiers: ['public.json'],
                    ),
                  ],
                );
                if (f != null) controller.text = await f.readAsString();
              },
              child: const Text('选择文件'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(source == null ? '导入' : '保存'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;
    if (source == null) {
      final report = rows(
        await s.send(
          'POST',
          'sources/import',
          result.startsWith('http') ? {'url': result} : {'json': result},
        ),
      );
      note(
        '已导入 ${report.where((i) => i['imported'] == true).length} 项，${report.where((i) => i['issue'] != '').length} 项有兼容提示',
      );
    } else {
      await s.send('PUT', 'sources/${source['id']}', {'json': result});
    }
    await refresh();
  }

  Future<void> testSource(Json source) async {
    final input = TextEditingController(text: '剑');
    final q = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('测试书源'),
        content: TextField(
          controller: input,
          decoration: const InputDecoration(labelText: '搜索关键词'),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx, input.text.trim()),
            child: const Text('测试搜索、目录和正文'),
          ),
        ],
      ),
    );
    if (q == null || q.isEmpty) return;
    final list = rows(await s.get('search', {'source': source['id'], 'q': q}));
    if (list.isEmpty) {
      note('搜索无结果');
      return;
    }
    final book = list.first;
    final toc = await s.toc(book['id'], force: true);
    final c = await s.chapter(book['id'], toc.first['id']);
    note(
      '实读成功 · ${book['title']} · ${c['title']}（${(c['blocks'] as List).length} 段）',
    );
  }

  void retainVisibleSourceSelection() {
    sourceSelection?.retainAll(filteredSources.map((v) => v['id']));
  }

  Future<void> confirmDeleteSources(Iterable<String> selection) async {
    final ids = selection.toList(growable: false);
    if (working || ids.isEmpty) return;
    if (await confirm('删除选中的 ${ids.length} 个书源？', acceptLabel: '删除') &&
        mounted) {
      await action(() => deleteSources(ids));
    }
  }

  Future<void> deleteSources(List<String> ids) async {
    final removed = <String>{};
    Object? failure;
    bool stopAfterBatch = false;
    const batchSize = 8;
    Future<void> remove(String id) async {
      try {
        await s.send('DELETE', 'sources/$id');
        removed.add(id);
      } catch (e) {
        failure ??= e;
        if (e is! ApiError || e.status == 401 || e.status == 403) {
          stopAfterBatch = true;
        }
      }
    }

    for (
      var start = 0;
      start < ids.length && !stopAfterBatch;
      start += batchSize
    ) {
      await Future.wait(ids.skip(start).take(batchSize).map(remove));
    }
    if (!mounted) return;
    setState(() {
      sources.removeWhere((v) => removed.contains(v['id']));
      sourceSelection?.removeAll(removed);
      if (removed.contains(sourceId)) sourceId = '';
    });
    await refresh();
    if (!mounted) return;
    final remaining = ids.toSet()..removeAll(removed);
    remaining.retainAll(sources.map((v) => v['id']));
    if (sourceSelection?.isEmpty == true)
      setState(() => sourceSelection = null);
    final message = '已删除 ${ids.length - remaining.length} 个书源';
    note(
      remaining.isEmpty
          ? message
          : '$message，剩余 ${remaining.length} 个可重试。$failure',
    );
  }

  Future<void> search() async {
    final q = keyword.text.trim();
    if (q.isEmpty) return;
    final recent = List<String>.from(s.state['recentSearch'] ?? []);
    recent.remove(q);
    recent.insert(0, q);
    s.state['recentSearch'] = recent.take(12).toList();
    s.persist();
    final run = ++searchId;
    final selected = searchableSources
        .where((v) => sourceId.isEmpty || sourceId == v['id'])
        .toList();
    setState(() {
      hits = [];
      failures = [];
      searching = selected.isNotEmpty;
      searchMessage = selected.isEmpty
          ? '请先导入并启用可搜索的书源。'
          : '正在搜索 0 / ${selected.length}';
    });
    int done = 0;
    await s.searchSources(
      q,
      selected,
      active: () => mounted && run == searchId,
      onSource: (src, result, error) => setState(() {
        if (error != null) failures.add("${src['name']} · $error");
        hits.addAll(result.map((b) => {...b, 'sourceName': src['name']}));
        searchMessage = '已搜索 ${++done} / ${selected.length} · ${hits.length} 本';
      }),
    );
    if (mounted && run == searchId) setState(() => searching = false);
  }

  Future<bool> confirm(String message, {String acceptLabel = '确认'}) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(acceptLabel),
            ),
          ],
        ),
      ) ??
      false;
  Widget blank(IconData icon, String message, [Widget? button]) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 46, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 16),
        Text(message),
        if (button != null)
          Padding(padding: const EdgeInsets.only(top: 16), child: button),
      ],
    ),
  );
  Future<String?> ask(String label) async {
    String value = '';
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(label),
        content: TextField(
          autofocus: true,
          onChanged: (x) => value = x,
          onSubmitted: (x) => Navigator.pop(c, x.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, value.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<void> bookMenu(Json b) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(b['title'], style: Theme.of(c).textTheme.titleLarge),
              subtitle: Text(b['author'] ?? ''),
            ),
            for (final op in [
              '详情与目录',
              '设置分组',
              '移出书架',
              if (b['origin'] == 'local') '删除服务器原书',
            ])
              ListTile(title: Text(op), onTap: () => Navigator.pop(c, op)),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == '详情与目录') {
      await details(b);
      return;
    }
    if (choice == '设置分组') {
      if (groups.isEmpty) {
        note('先从书架右上角新建分组');
        return;
      }
      final g = await showDialog<Json>(
        context: context,
        builder: (c) => SimpleDialog(
          title: const Text('选择分组，再次选择可移出'),
          children: [
            for (final g in groups)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(c, g),
                child: Text(g['name']),
              ),
          ],
        ),
      );
      if (g == null) return;
      final copies = s.shelfEditions(b).map((edition) => edition['id']).toSet();
      final existing = memberships
          .where((m) => m['group'] == g['id'] && copies.contains(m['book']))
          .toList();
      if (existing.isNotEmpty) {
        for (final m in existing) {
          await s.send('DELETE', 'items/membership/${m["id"]}');
          memberships.remove(m);
        }
      } else {
        final id = copies.firstOrNull ?? b['id'];
        await s.putItem('membership', {
          'id': '$id-${g["id"]}',
          'book': id,
          'group': g['id'],
        });
      }
    } else if (await confirm('$choice？')) {
      if (choice == '移出书架') {
        await s.setShelved(b, false);
      } else {
        await s.send('DELETE', 'books/${b["id"]}');
      }
    }
    await refresh();
  }

  Future<void> toggleShelfLayout() async {
    setState(() => s.state['shelfGrid'] = !shelfGrid);
    await s.persist();
  }

  Future<void> handleShelfAction(String op) async {
    switch (op) {
      case '导入电子书':
        await upload();
      case '切换书架布局':
        await toggleShelfLayout();
      case '新建分组':
        final name = await ask('分组名称');
        if (name != null && name.isNotEmpty) {
          await s.putItem('group', {'id': ReaderStore.eventId(), 'name': name});
          await refresh();
        }
      case '同步书架':
        await refresh();
    }
  }

  Widget shelfHeader() {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final actionStyle = IconButton.styleFrom(
      backgroundColor: colors.surfaceContainerLow,
      foregroundColor: colors.onSurfaceVariant,
      iconSize: 22,
      tapTargetSize: MaterialTapTargetSize.padded,
    );
    void select(_ShelfTab section, {String? groupId}) => setState(() {
      shelfTab = section;
      shelfGroup = groupId;
    });
    Widget tabChip(_ShelfTab section) {
      final selected = shelfTab == section;
      return ChoiceChip(
        label: Text(section.label),
        selected: selected,
        onSelected: (_) => select(section),
        showCheckmark: false,
        shape: const StadiumBorder(),
        side: BorderSide.none,
        backgroundColor: colors.surface,
        selectedColor: colors.primary,
        labelStyle: theme.textTheme.labelLarge?.copyWith(
          color: selected ? colors.onPrimary : colors.onSurfaceVariant,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        labelPadding: const EdgeInsets.symmetric(horizontal: 10),
        materialTapTargetSize: MaterialTapTargetSize.padded,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppBar(
          automaticallyImplyLeading: false,
          centerTitle: false,
          excludeHeaderSemantics: true,
          backgroundColor: colors.surface,
          scrolledUnderElevation: 0,
          titleSpacing: 12,
          title: SingleChildScrollView(
            key: const PageStorageKey('shelf-tabs'),
            scrollDirection: Axis.horizontal,
            child: Row(
              spacing: 4,
              children: [
                for (final section in _ShelfTab.values) tabChip(section),
              ],
            ),
          ),
          actionsPadding: const EdgeInsetsDirectional.only(end: 12),
          actions: [
            IconButton(
              tooltip: '搜书',
              style: actionStyle,
              onPressed: () => setState(() => page = _HomePage.search),
              icon: const Icon(Icons.search_rounded),
            ),
            PopupMenuButton<String>(
              tooltip: '书架菜单',
              style: actionStyle,
              icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (op) => action(() => handleShelfAction(op)),
              itemBuilder: (_) => [
                for (final op in ['导入电子书', '切换书架布局', '新建分组', '同步书架'])
                  PopupMenuItem(value: op, child: Text(op)),
                if (groups.isNotEmpty) const PopupMenuDivider(),
                for (final g in groups)
                  CheckedPopupMenuItem<String>(
                    checked: shelfGroup == g['id'],
                    onTap: () => select(
                      _ShelfTab.books,
                      groupId: shelfGroup == g['id'] ? null : g['id'],
                    ),
                    child: Text(g['name']),
                  ),
              ],
            ),
          ],
        ),
        Divider(height: 1, thickness: 0, color: colors.outlineVariant),
      ],
    );
  }

  Widget bookTile(
    Json book, {
    required VoidCallback onOpen,
    VoidCallback? onMenu,
    Json? progress,
    String? historyChapter,
  }) {
    final grid = shelfGrid;
    final cover = Stack(
      clipBehavior: Clip.none,
      children: [
        BookCover(s, book, width: grid ? 90 : 56, height: grid ? 120 : 77),
        if ((progress?['total'] ?? 0) > 0)
          Positioned(
            right: -2,
            top: 0,
            child: Badge(
              label: Text(
                '${(progress!["total"] as int) - ((progress["ord"] as int? ?? -1) + 1)}',
              ),
            ),
          ),
      ],
    );
    final title = Text(
      book['title'],
      maxLines: grid ? 2 : 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: grid ? 14 : 17, fontWeight: FontWeight.w600),
    );
    final chapter = historyChapter == null
        ? null
        : Text(
            historyChapter,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          );
    return GestureDetector(
      onSecondaryTap: onMenu,
      child: InkWell(
        onTap: onOpen,
        onLongPress: onMenu,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: grid
              ? Column(
                  children: [
                    cover,
                    const SizedBox(height: 7),
                    title,
                    if (chapter != null) ...[
                      const SizedBox(height: 3),
                      chapter,
                    ],
                  ],
                )
              : Row(
                  children: [
                    cover,
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          title,
                          const SizedBox(height: 3),
                          Text(
                            book['author'] == ''
                                ? '未知作者'
                                : book['author'] ?? '未知作者',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if (chapter != null) chapter,
                          if (progress != null) ...[
                            Text(
                              '进度：${progress["current"] ?? "尚未阅读"}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '最新：${progress["latest"] ?? "待获取目录"}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (onMenu != null)
                      IconButton(
                        tooltip: '书籍操作',
                        onPressed: onMenu,
                        icon: const Icon(Icons.more_vert, size: 18),
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget bookSliver(
    int count,
    IndexedWidgetBuilder itemBuilder, {
    bool withChapter = false,
  }) {
    if (!shelfGrid) {
      return SliverList.separated(
        itemCount: count,
        itemBuilder: itemBuilder,
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 84),
      );
    }
    final scaler = MediaQuery.textScalerOf(context);
    final titleHeight = 2 * 1.5 * scaler.scale(14);
    final chapterHeight = withChapter ? 3 + 1.5 * scaler.scale(12) : 0.0;
    return SliverGrid.builder(
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 156,
        mainAxisExtent: 152 + titleHeight + chapterHeight,
      ),
      itemCount: count,
      itemBuilder: itemBuilder,
    );
  }

  Widget libraryView(_ShelfTab section) {
    final books = s.books;
    final Widget sliver;
    if (section == _ShelfTab.history) {
      final history = books.history;
      if (history.isEmpty) {
        return blank(Icons.menu_book_outlined, '还没有阅读记录');
      }
      sliver = bookSliver(history.length, (_, i) {
        final entry = history[i];
        final id = entry['book'];
        return bookTile(
          books.bookForVisit(entry),
          historyChapter:
              entry['chapter'] ?? (entry['chapterId'] == null ? null : '原章节'),
          onOpen: () => action(() async {
            final book = books.edition(id) ?? await s.get('books/$id');
            if (mounted) await read(book, entry['chapterId']);
          }),
        );
      }, withChapter: true);
    } else {
      final local = section == _ShelfTab.local;
      final list = books.shelfBooks(
        localOnly: local,
        members: local || shelfGroup == null
            ? null
            : {
                for (final m in memberships)
                  if (m['group'] == shelfGroup) m['book'] as String,
              },
      );
      if (list.isEmpty) {
        return blank(
          Icons.menu_book_outlined,
          local
              ? '还没有本地电子书'
              : shelfGroup == null
              ? '书架还是空的'
              : '这一组暂无书籍',
          TextButton(
            onPressed: () => action(upload),
            child: const Text('导入电子书'),
          ),
        );
      }
      sliver = bookSliver(list.length, (_, i) {
        final book = list[i];
        return bookTile(
          book,
          progress: books.progressFor(book),
          onOpen: () => read(book),
          onMenu: () => action(() => bookMenu(book)),
        );
      });
    }
    return CustomScrollView(
      key: PageStorageKey((section, shelfGrid)),
      slivers: [sliver],
    );
  }

  Widget searchView() => Column(
    children: [
      if (hits.isEmpty && !searching)
        Wrap(
          spacing: 6,
          children: [
            for (final q in List<String>.from(s.state['recentSearch'] ?? []))
              ActionChip(
                label: Text(q),
                onPressed: () {
                  keyword.text = q;
                  search();
                },
              ),
          ],
        ),
      TextField(
        controller: keyword,
        onSubmitted: (_) => search(),
        decoration: InputDecoration(
          labelText: '书名或作者',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: IconButton(
            onPressed: search,
            icon: const Icon(Icons.arrow_forward),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: DropdownButton<String>(
              isExpanded: true,
              value: sourceId,
              items: [
                const DropdownMenuItem(value: '', child: Text('全部启用的书源')),
                ...searchableSources.map(
                  (v) => DropdownMenuItem<String>(
                    value: v['id'],
                    child: Text(v['name'], overflow: TextOverflow.ellipsis),
                  ),
                ),
                const DropdownMenuItem<String>(
                  value: 'tomato',
                  enabled: false,
                  child: Text('番茄小说 · 暂不可用'),
                ),
              ],
              onChanged: (v) => setState(() => sourceId = v ?? ''),
            ),
          ),
          if (searching)
            TextButton(
              onPressed: () {
                searchId++;
                setState(() => searching = false);
              },
              child: const Text('停止'),
            ),
          if (failures.isNotEmpty)
            TextButton(
              onPressed: () => showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('书源反馈'),
                  content: SingleChildScrollView(
                    child: Text(failures.join('\n')),
                  ),
                ),
              ),
              child: Text('失败 ${failures.length}'),
            ),
        ],
      ),
      if (searchMessage.isNotEmpty)
        Align(alignment: Alignment.centerLeft, child: Text(searchMessage)),
      if (searching) const LinearProgressIndicator(),
      Expanded(
        child: ListView.builder(
          itemCount: hits.length,
          itemBuilder: (_, i) {
            final b = hits[i];
            return ListTile(
              leading: BookCover(s, b),
              title: Text(b['title']),
              subtitle: Text("${b['author']} · ${b['sourceName']}"),
              onTap: () => details(b),
            );
          },
        ),
      ),
    ],
  );
  Widget sourceView() {
    final list = filteredSources.toList();
    final selection = sourceSelection;
    final allSelected = list.isNotEmpty && selection?.length == list.length;
    return Column(
      children: [
        TextField(
          readOnly: selection != null && working,
          onChanged: (v) => setState(() {
            filter = v;
            retainVisibleSourceSelection();
          }),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.filter_list),
            labelText: '按书源名或分组筛选（${sources.length}）',
          ),
        ),
        if (selection != null)
          CheckboxListTile(
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(filter.isEmpty ? '全选' : '全选筛选结果'),
            tristate: true,
            value: selection.isEmpty
                ? false
                : allSelected
                ? true
                : null,
            onChanged: working || list.isEmpty
                ? null
                : (_) => setState(() {
                    if (allSelected) {
                      selection.clear();
                    } else {
                      selection.addAll(list.map((v) => v['id'] as String));
                    }
                  }),
          ),
        Expanded(
          child: ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, i) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final v = list[i];
              final id = v['id'] as String;
              final title = Text(v['name']);
              final subtitle = Text(
                [v['groupName'], v['issue']].where((s) => s != '').join(' · '),
              );
              if (selection != null) {
                return CheckboxListTile(
                  key: ValueKey(id),
                  controlAffinity: ListTileControlAffinity.leading,
                  title: title,
                  subtitle: subtitle,
                  value: selection.contains(id),
                  onChanged: working
                      ? null
                      : (checked) => setState(() {
                          if (checked == true) {
                            selection.add(id);
                          } else {
                            selection.remove(id);
                          }
                        }),
                );
              }
              return ListTile(
                title: title,
                subtitle: subtitle,
                leading: Switch(
                  value: v['enabled'] == 1,
                  onChanged: (value) => action(() async {
                    await s.send('PUT', 'sources/${v['id']}/enabled', {
                      'enabled': value,
                    });
                    await refresh();
                  }),
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (op) {
                    switch (op) {
                      case 'edit':
                        action(() => editSource(v));
                      case 'test':
                        action(() => testSource(v));
                      case 'delete':
                        confirmDeleteSources([id]);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('编辑 JSON')),
                    PopupMenuItem(value: 'test', child: Text('测试书源')),
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget connection() => ListView(
    children: [
      TextField(
        controller: addr,
        decoration: const InputDecoration(
          labelText: '服务地址',
          hintText: 'http://127.0.0.1:7186',
        ),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: secret,
        obscureText: true,
        decoration: const InputDecoration(
          labelText: '个人令牌',
          helperText: '位于服务端 data/access-token.txt',
        ),
      ),
      const SizedBox(height: 18),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          onPressed: working
              ? null
              : () => action(() async {
                  await s.connect(addr.text, secret.text);
                  await refresh();
                  if (mounted) setState(() => page = _HomePage.shelf);
                  unawaited(s.flushReadingTime());
                  note('已连接个人书房');
                }),
          icon: const Icon(Icons.link),
          label: const Text('连接并同步'),
        ),
      ),
      if (status.isNotEmpty)
        Padding(padding: const EdgeInsets.only(top: 18), child: Text(status)),
    ],
  );

  Future<void> chooseAppTheme() async {
    final choice = await showDialog<AppThemeMode>(
      context: context,
      builder: (dialog) => RadioGroup<AppThemeMode>(
        groupValue: s.appTheme.value,
        onChanged: (value) => Navigator.pop(dialog, value),
        child: SimpleDialog(
          title: const Text('外观主题'),
          children: [
            for (final mode in AppThemeMode.values)
              RadioListTile(value: mode, title: Text(mode.label)),
          ],
        ),
      ),
    );
    if (choice != null && mounted) await action(() => s.setAppTheme(choice));
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final colors = Theme.of(context).colorScheme;
    const sections = [_HomePage.shelf, _HomePage.stats, _HomePage.account];
    final section = switch (page) {
      _HomePage.search => _HomePage.shelf,
      _HomePage.history ||
      _HomePage.sources ||
      _HomePage.connection => _HomePage.account,
      _ => page,
    };
    final dest = sections.indexOf(section);
    final home = page == section;
    final selection = page == _HomePage.sources ? sourceSelection : null;
    void go(_HomePage target) => setState(() {
      if (page == _HomePage.sources && target != _HomePage.sources) {
        sourceSelection = null;
        filter = '';
      }
      page = target;
    });
    void back() {
      if (selection != null) {
        setState(() => sourceSelection = null);
      } else {
        go(section);
      }
    }

    const destinations = [
      NavigationDestination(
        icon: Icon(Icons.auto_stories_outlined),
        selectedIcon: Icon(Icons.auto_stories),
        label: '书架',
      ),
      NavigationDestination(
        icon: Icon(Icons.bar_chart_outlined),
        selectedIcon: Icon(Icons.bar_chart_rounded),
        label: '阅读统计',
      ),
      NavigationDestination(
        icon: Icon(Icons.person_outline),
        selectedIcon: Icon(Icons.person),
        label: '我的',
      ),
    ];
    return PopScope(
      canPop: home,
      onPopInvokedWithResult: (did, _) {
        if (!did && !home) back();
      },
      child: Scaffold(
        bottomNavigationBar: wide || !home
            ? null
            : NavigationBar(
                height: kMinInteractiveDimension,
                labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
                backgroundColor: colors.surfaceContainerLow,
                elevation: 0,
                destinations: destinations,
                selectedIndex: dest,
                onDestinationSelected: (i) => go(sections[i]),
              ),
        body: SafeArea(
          child: Row(
            children: [
              if (wide)
                NavigationRail(
                  selectedIndex: dest,
                  onDestinationSelected: (i) => go(sections[i]),
                  labelType: NavigationRailLabelType.all,
                  destinations: [
                    for (final d in destinations)
                      NavigationRailDestination(
                        icon: d.icon,
                        selectedIcon: d.selectedIcon,
                        label: Text(d.label),
                      ),
                  ],
                ),
              if (wide) const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  children: [
                    if (page == _HomePage.shelf)
                      shelfHeader()
                    else if (page != _HomePage.stats)
                      AppBar(
                        automaticallyImplyLeading: false,
                        leading: selection != null
                            ? IconButton(
                                tooltip: '退出多选',
                                onPressed: back,
                                icon: const Icon(Icons.close),
                              )
                            : home
                            ? null
                            : BackButton(onPressed: back),
                        title: Text(
                          selection == null
                              ? page.title
                              : '已选 ${selection.length} 项',
                        ),
                        actions: [
                          if (selection != null)
                            TextButton.icon(
                              style: TextButton.styleFrom(
                                foregroundColor: colors.error,
                              ),
                              onPressed: selection.isEmpty || working
                                  ? null
                                  : () => confirmDeleteSources(selection),
                              icon: const Icon(Icons.delete_outline),
                              label: const Text('批量删除'),
                            )
                          else if (page == _HomePage.history)
                            IconButton(
                              tooltip: '切换书架布局',
                              onPressed: () => action(toggleShelfLayout),
                              icon: Icon(
                                shelfGrid
                                    ? Icons.view_list_outlined
                                    : Icons.grid_view_outlined,
                              ),
                            )
                          else if (page == _HomePage.sources) ...[
                            TextButton(
                              onPressed: sources.isEmpty || working
                                  ? null
                                  : () => setState(
                                      () => sourceSelection = <String>{},
                                    ),
                              child: const Text('多选'),
                            ),
                            IconButton(
                              tooltip: '导入书源',
                              onPressed: () => action(editSource),
                              icon: const Icon(Icons.add),
                            ),
                          ],
                        ],
                      ),
                    if (working) const LinearProgressIndicator(),
                    if (status.isNotEmpty &&
                        page != _HomePage.connection &&
                        page != _HomePage.stats)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.cloud_off_outlined),
                        title: const Text('当前离线，仍可阅读已缓存的章节'),
                        onTap: () => go(_HomePage.connection),
                      ),
                    Expanded(
                      child: page == _HomePage.shelf
                          ? KeyedSubtree(
                              key: PageStorageKey((shelfTab, shelfGroup)),
                              child: libraryView(shelfTab),
                            )
                          : page == _HomePage.stats
                          ? ReadingStatistics(s)
                          : Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: wide ? 28 : 12,
                              ),
                              child: switch (page) {
                                _HomePage.search => searchView(),
                                _HomePage.history => libraryView(
                                  _ShelfTab.history,
                                ),
                                _HomePage.sources => sourceView(),
                                _HomePage.connection => connection(),
                                _ => ListView(
                                  children: [
                                    for (final link in [
                                      (_HomePage.history, Icons.history),
                                      (
                                        _HomePage.sources,
                                        Icons.library_books_outlined,
                                      ),
                                      (
                                        _HomePage.connection,
                                        Icons.cloud_sync_outlined,
                                      ),
                                    ])
                                      ListTile(
                                        leading: Icon(link.$2),
                                        title: Text(link.$1.title),
                                        trailing: const Icon(
                                          Icons.chevron_right,
                                        ),
                                        onTap: () => go(link.$1),
                                      ),
                                    ListTile(
                                      leading: const Icon(
                                        Icons.contrast_outlined,
                                      ),
                                      title: const Text('外观主题'),
                                      trailing: Text(s.appTheme.value.label),
                                      onTap: chooseAppTheme,
                                    ),
                                    ListTile(
                                      leading: const Icon(
                                        Icons.file_open_outlined,
                                      ),
                                      title: const Text('导入本地电子书'),
                                      onTap: () => action(upload),
                                    ),
                                  ],
                                ),
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class BookDetails extends StatefulWidget {
  final ReaderStore store;
  final Json book;
  const BookDetails(this.store, this.book, {super.key});
  @override
  State<BookDetails> createState() => _BookDetailsState();
}

class _BookDetailsState extends State<BookDetails> {
  late Json book;
  List<Json> toc = [], bookMarks = [];
  bool showMarks = false;
  String chapterQuery = '';
  String error = '';
  bool busy = true, updatingShelf = false;
  bool get shelved =>
      book['shelf'] == 1 || widget.store.shelfEditions(book).isNotEmpty;
  @override
  void initState() {
    super.initState();
    book = {...widget.book};
    load();
  }

  Future<void> load([bool force = false]) async {
    try {
      final mapping = book['origin'] == 'local'
          ? null
          : await widget.store.bookSourceMapping(book['id']);
      final list = await widget.store.readingToc(
        book['id'],
        mapping,
        force: force,
      );
      final ms = await widget.store.items('mark', book['id']);
      Json b = book;
      try {
        b = await widget.store.get('books/${book['id']}');
      } catch (_) {}
      if (mounted)
        setState(() {
          toc = list;
          bookMarks = ms;
          book = b;
          busy = false;
          error = '';
        });
    } catch (e) {
      if (mounted)
        setState(() {
          error = e.toString();
          busy = false;
        });
    }
  }

  Future<void> open([String? chapter, Json? anchor]) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ReaderPage(widget.store, book, selected: chapter, anchor: anchor),
      ),
    );
    if (mounted) await load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('书籍详情')),
    body: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: BookCover(widget.store, book),
            title: Text(book['title']),
            subtitle: Text(book['author']),
          ),
          if ((book['intro'] ?? '') != '')
            Text(book['intro'], maxLines: 4, overflow: TextOverflow.ellipsis),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: toc.isEmpty ? null : () => open(),
                child: const Text('继续阅读'),
              ),
              OutlinedButton(
                onPressed: updatingShelf
                    ? null
                    : () async {
                        final next = !shelved;
                        setState(() => updatingShelf = true);
                        try {
                          await widget.store.setShelved(book, next);
                          if (mounted) book = {...book, 'shelf': next ? 1 : 0};
                        } catch (e) {
                          if (context.mounted)
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(e.toString())),
                            );
                        } finally {
                          if (mounted) setState(() => updatingShelf = false);
                        }
                      },
                child: Text(shelved ? '移出书架' : '加入书架'),
              ),
              IconButton(
                tooltip: '刷新目录',
                onPressed: () => load(true),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const Divider(),
          Row(
            children: [
              TextButton(
                onPressed: () => setState(() => showMarks = false),
                child: Text('目录 · ${toc.length} 章'),
              ),
              TextButton(
                onPressed: () => setState(() => showMarks = true),
                child: Text('书签批注 · ${bookMarks.length}'),
              ),
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: '筛选',
                    border: InputBorder.none,
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (v) => setState(() => chapterQuery = v),
                ),
              ),
            ],
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != '') Text(error),
          Expanded(
            child: showMarks
                ? ListView(
                    children: [
                      for (final m in bookMarks.where(
                        (x) =>
                            '${x["quote"]} ${x["note"]}'.contains(chapterQuery),
                      ))
                        ListTile(
                          title: Text(m['note'] == '' ? m['quote'] : m['note']),
                          subtitle: Text(m['kind']),
                          onTap: () => open(m['chapter'], m),
                        ),
                    ],
                  )
                : ListView.builder(
                    itemCount: toc
                        .where(
                          (x) => (x['title'] as String).contains(chapterQuery),
                        )
                        .length,
                    itemBuilder: (_, i) {
                      final v = toc
                          .where(
                            (x) =>
                                (x['title'] as String).contains(chapterQuery),
                          )
                          .elementAt(i);
                      return ListTile(
                        title: Text(v['title']),
                        onTap: () => open(v['id']),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}
