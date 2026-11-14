import 'dart:async';
import 'dart:convert';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'cover.dart';
import 'reader.dart';
import 'store.dart';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final profile = args.where((a) => a.startsWith('--profile=')).firstOrNull;
  runApp(BooksApp(await ReaderStore.open(profile?.substring(10))));
}

class BooksApp extends StatelessWidget {
  final ReaderStore store;
  const BooksApp(this.store, {super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '个人书房',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff5a5b87),
        surface: const Color(0xfffaf9fa),
      ),
      useMaterial3: true,
      appBarTheme: const AppBarTheme(backgroundColor: Color(0xfff1eeee)),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    home: Home(store),
  );
}

const names = ['书架', '搜书', '历史', '书源', '连接'];
const icons = [
  Icons.auto_stories_outlined,
  Icons.search,
  Icons.history,
  Icons.hub_outlined,
  Icons.settings_outlined,
];

class Home extends StatefulWidget {
  final ReaderStore store;
  const Home(this.store, {super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  ReaderStore get s => widget.store;
  int tab = 0, searchId = 0;
  String shelfTab = '全部';
  List<Json> groups = [], memberships = [], activity = [];
  bool working = false, searching = false, online = false;
  String status = '', filter = '', sourceId = '', searchMessage = '';
  final keyword = TextEditingController(),
      addr = TextEditingController(),
      secret = TextEditingController();
  List<Json> sources = [], hits = [];
  List<String> failures = [];
  Json get library => s.state['library'] ?? {};
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    addr.text = s.base;
    secret.text = s.token;
    if (s.token.isEmpty) tab = 4;
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

  Future<void> refresh() async {
    if (s.token.isEmpty) return;
    try {
      await s.refresh();
      await s.flush();
      final list = rows(await s.get('sources'));
      final extra = await Future.wait([
        s.items('group'),
        s.items('membership'),
        s.get('activity'),
      ]);
      if (mounted)
        setState(() {
          groups = rows(extra[0]);
          memberships = rows(extra[1]);
          activity = rows(extra[2]);
          sources = list;
          online = true;
          status = '';
        });
    } catch (e) {
      if (mounted)
        setState(() {
          online = false;
          status = e.toString();
        });
    }
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
      MaterialPageRoute(builder: (_) => ReaderPage(s, book, selected: chapter)),
    );
    await refresh();
  }

  Future<void> details(Json book) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => BookDetails(s, book)),
    );
    await refresh();
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
    if (mounted) setState(() => tab = 0);
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

  Future<void> search() async {
    final q = keyword.text.trim();
    if (q.isEmpty) return;
    final recent = List<String>.from(s.state['recentSearch'] ?? []);
    recent.remove(q);
    recent.insert(0, q);
    s.state['recentSearch'] = recent.take(12).toList();
    s.persist();
    final run = ++searchId;
    final selected = sources
        .where(
          (v) =>
              v['enabled'] == 1 &&
              v['issue'] == '' &&
              (sourceId == '' || sourceId == v['id']),
        )
        .toList();
    setState(() {
      hits = [];
      failures = [];
      searching = selected.isNotEmpty;
      searchMessage = selected.isEmpty
          ? '请先导入并启用可搜索的书源。'
          : '正在搜索 0 / ${selected.length}';
    });
    int next = 0, done = 0;
    Future<void> worker() async {
      while (next < selected.length && run == searchId) {
        final src = selected[next++];
        try {
          final result = rows(
            await s.get('search', {'source': src['id'], 'q': q}),
          );
          if (!mounted || run != searchId) return;
          setState(
            () => hits.addAll(
              result.map((b) => {...b, 'sourceName': src['name']}),
            ),
          );
        } catch (e) {
          if (mounted && run == searchId) failures.add("${src['name']} · $e");
        }
        if (mounted && run == searchId)
          setState(
            () => searchMessage =
                '已搜索 ${++done} / ${selected.length} · ${hits.length} 本',
          );
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
    if (mounted && run == searchId) setState(() => searching = false);
  }

  Future<bool> confirm(String message) async =>
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
              child: const Text('确认'),
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
      final id = '${b["id"]}-${g["id"]}';
      if (memberships.any((x) => x['id'] == id)) {
        await s.send('DELETE', 'items/membership/$id');
      } else {
        await s.putItem('membership', {
          'id': id,
          'book': b['id'],
          'group': g['id'],
        });
      }
    } else if (await confirm('$choice？')) {
      if (choice == '移出书架') {
        await s.send('PUT', 'books/${b["id"]}/shelf', {'shelf': false});
      } else {
        await s.send('DELETE', 'books/${b["id"]}');
      }
    }
    await refresh();
  }

  Widget libraryView(bool hist) {
    if (hist && activity.isNotEmpty) {
      return ListView(
        children: [
          for (final day in activity.map((e) => e['day']).toSet()) ...[
            ListTile(
              title: Text(
                '$day',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              subtitle: Text(
                '${activity.where((e) => e["day"] == day).map((e) => e["book"]).toSet().length} 本 · ${activity.where((e) => e["day"] == day).length} 章',
              ),
            ),
            for (final e in activity.where((e) => e['day'] == day))
              ListTile(
                leading: const Icon(Icons.history),
                title: Text(e['title']),
                subtitle: Text(e['chapter'] ?? '原章节'),
                onTap: () => action(() async {
                  await read(await s.get('books/${e["book"]}'), e['chapterId']);
                }),
              ),
          ],
        ],
      );
    }
    final indicators = {
      for (final v in rows(library['indicators'])) v['id']: v,
    };
    final list = rows(library[hist ? 'history' : 'shelf']).where((b) {
      final d = indicators[b['id']];
      final seen = d?['stamp'] != null;
      final done = seen && (d?['ord'] ?? -1) + 1 == (d?['total'] ?? 0);
      return hist ||
          switch (shelfTab) {
            '全部' => true,
            '在读' => seen && !done,
            '未读' => !seen,
            '已读' => done,
            '本地' => b['origin'] == 'local',
            _ => memberships.any(
              (x) => x['book'] == b['id'] && x['group'] == shelfTab,
            ),
          };
    }).toList();
    final grid = !hist && s.state['shelfGrid'] == true;
    Widget tile(Json b) {
      final d = indicators[b['id']];
      final cover = Stack(
        clipBehavior: Clip.none,
        children: [
          SizedBox(
            width: grid ? 90 : 56,
            height: grid ? 120 : 77,
            child: BookCover(
              s,
              b,
              width: grid ? 90 : 56,
              height: grid ? 120 : 77,
            ),
          ),
          if ((d?['total'] ?? 0) > 0)
            Positioned(
              right: -2,
              top: 0,
              child: Badge(
                label: Text(
                  '${(d!["total"] as int) - (d["ord"] == null ? 0 : (d["ord"] as int) + 1)}',
                ),
              ),
            ),
        ],
      );
      final title = Text(
        b['title'],
        maxLines: grid ? 2 : 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: grid ? 14 : 17, fontWeight: FontWeight.w600),
      );
      return GestureDetector(
        onSecondaryTap: () => action(() => bookMenu(b)),
        child: InkWell(
          onTap: () => read(b),
          onLongPress: () => action(() => bookMenu(b)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: grid
                ? Column(children: [cover, const SizedBox(height: 7), title])
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
                              b['author'] == ''
                                  ? '未知作者'
                                  : b['author'] ?? '未知作者',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            Text(
                              '进度：${d?["current"] ?? "尚未阅读"}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '最新：${d?["latest"] ?? "待获取目录"}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '书籍操作',
                        onPressed: () => action(() => bookMenu(b)),
                        icon: const Icon(Icons.more_vert, size: 18),
                      ),
                    ],
                  ),
          ),
        ),
      );
    }

    return Column(
      children: [
        if (!hist)
          SizedBox(
            height: 46,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final g in [
                  for (final n in ['全部', '在读', '未读', '已读', '本地'])
                    {'id': n, 'name': n},
                  ...groups,
                ])
                  InkWell(
                    onTap: () => setState(() => shelfTab = g['id']),
                    child: Container(
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: shelfTab == g['id']
                                ? Theme.of(context).colorScheme.primary
                                : Colors.transparent,
                            width: 3,
                          ),
                        ),
                      ),
                      child: Text(g['name']),
                    ),
                  ),
              ],
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: list.isEmpty
              ? blank(
                  Icons.menu_book_outlined,
                  hist
                      ? '还没有阅读记录'
                      : shelfTab == '全部'
                      ? '书架还是空的'
                      : '这一组暂无书籍',
                  hist
                      ? null
                      : TextButton(
                          onPressed: () => action(upload),
                          child: const Text('导入电子书'),
                        ),
                )
              : grid
              ? GridView.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 156,
                    mainAxisExtent: 194,
                  ),
                  itemCount: list.length,
                  itemBuilder: (_, i) => tile(list[i]),
                )
              : ListView.separated(
                  itemCount: list.length,
                  itemBuilder: (_, i) => tile(list[i]),
                  separatorBuilder: (_, i) =>
                      const Divider(height: 1, indent: 84),
                ),
        ),
      ],
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
              value: sources.any((v) => v['id'] == sourceId) ? sourceId : '',
              items: [
                const DropdownMenuItem(value: '', child: Text('全部启用的书源')),
                ...sources
                    .where((v) => v['enabled'] == 1 && v['issue'] == '')
                    .map(
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
    final list = sources
        .where((v) => ('${v['name']} ${v['groupName']}').contains(filter))
        .toList();
    return Column(
      children: [
        TextField(
          onChanged: (v) => setState(() => filter = v),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.filter_list),
            labelText: '按书源名或分组筛选（${sources.length}）',
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, i) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final v = list[i];
              return ListTile(
                title: Text(v['name']),
                subtitle: Text(
                  [
                    v['groupName'],
                    v['issue'],
                  ].where((s) => s != '').join(' · '),
                ),
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
                  onSelected: (op) => action(() async {
                    if (op == 'edit') {
                      await editSource(v);
                    } else if (op == 'test') {
                      await testSource(v);
                    } else if (await confirm('删除这个书源？')) {
                      await s.send('DELETE', 'sources/${v['id']}');
                      await refresh();
                    }
                  }),
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
                  if (mounted) setState(() => tab = 0);
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
  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final mine = tab >= 2;
    final dest = mine ? 1 : 0;
    void go(int i) => setState(() => tab = i);
    const destinations = [
      NavigationDestination(
        icon: Icon(Icons.auto_stories_outlined),
        selectedIcon: Icon(Icons.auto_stories),
        label: '书架',
      ),
      NavigationDestination(
        icon: Icon(Icons.person_outline),
        selectedIcon: Icon(Icons.person),
        label: '我的',
      ),
    ];
    final home = tab == 0 || tab == 5;
    final title = ['书架', '搜书', '阅读记录', '书源管理', '连接与同步', '我的'][tab];
    return PopScope(
      canPop: home,
      onPopInvokedWithResult: (did, _) {
        if (!did && !home) go(mine ? 5 : 0);
      },
      child: Scaffold(
        bottomNavigationBar: wide || !home
            ? null
            : NavigationBar(
                destinations: destinations,
                selectedIndex: dest,
                onDestinationSelected: (i) => go(i == 0 ? 0 : 5),
              ),
        body: SafeArea(
          child: Row(
            children: [
              if (wide)
                NavigationRail(
                  selectedIndex: dest,
                  onDestinationSelected: (i) => go(i == 0 ? 0 : 5),
                  labelType: NavigationRailLabelType.all,
                  destinations: [
                    for (final d in destinations)
                      NavigationRailDestination(
                        icon: d.icon,
                        label: Text(d.label),
                      ),
                  ],
                ),
              if (wide) const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  children: [
                    AppBar(
                      automaticallyImplyLeading: false,
                      leading: home
                          ? null
                          : BackButton(onPressed: () => go(mine ? 5 : 0)),
                      title: Text(title),
                      actions: [
                        if (tab == 0)
                          IconButton(
                            tooltip: '搜书',
                            onPressed: () => go(1),
                            icon: const Icon(Icons.search),
                          ),
                        if (tab == 3)
                          IconButton(
                            tooltip: '导入书源',
                            onPressed: () => action(editSource),
                            icon: const Icon(Icons.add),
                          ),
                        if (tab == 0)
                          PopupMenuButton<String>(
                            tooltip: '书架菜单',
                            onSelected: (op) => action(() async {
                              switch (op) {
                                case '导入电子书':
                                  await upload();
                                  break;
                                case '切换书架布局':
                                  setState(
                                    () => s.state['shelfGrid'] =
                                        s.state['shelfGrid'] != true,
                                  );
                                  await s.persist();
                                  break;
                                case '新建分组':
                                  final n = await ask('分组名称');
                                  if (n != null && n.isNotEmpty) {
                                    await s.putItem('group', {
                                      'id': ReaderStore.eventId(),
                                      'name': n,
                                    });
                                    await refresh();
                                  }
                                  break;
                                case '同步书架':
                                  await refresh();
                              }
                            }),
                            itemBuilder: (_) => [
                              for (final op in [
                                '导入电子书',
                                '切换书架布局',
                                '新建分组',
                                '同步书架',
                              ])
                                PopupMenuItem(value: op, child: Text(op)),
                            ],
                          ),
                      ],
                    ),
                    if (working) const LinearProgressIndicator(),
                    if (status.isNotEmpty && tab != 4)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.cloud_off_outlined),
                        title: const Text('当前离线，仍可阅读已缓存的章节'),
                        onTap: () => go(4),
                      ),
                    Expanded(
                      child: tab == 0
                          ? libraryView(false)
                          : Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: wide ? 28 : 12,
                              ),
                              child: switch (tab) {
                                1 => searchView(),
                                2 => libraryView(true),
                                3 => sourceView(),
                                4 => connection(),
                                _ => ListView(
                                  children: [
                                    for (final link in [
                                      (2, Icons.history, '阅读记录'),
                                      (3, Icons.library_books_outlined, '书源管理'),
                                      (4, Icons.cloud_sync_outlined, '连接与同步'),
                                    ])
                                      ListTile(
                                        leading: Icon(link.$2),
                                        title: Text(link.$3),
                                        trailing: const Icon(
                                          Icons.chevron_right,
                                        ),
                                        onTap: () => go(link.$1),
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
  bool busy = true;
  @override
  void initState() {
    super.initState();
    book = {...widget.book};
    load();
  }

  Future<void> load([bool force = false]) async {
    try {
      final list = await widget.store.toc(book['id'], force: force);
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

  void open([String? chapter]) => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => ReaderPage(widget.store, book, selected: chapter),
    ),
  );
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
                onPressed: () async {
                  try {
                    final next = book['shelf'] != 1;
                    await widget.store.send(
                      'PUT',
                      'books/${book['id']}/shelf',
                      {'shelf': next},
                    );
                    if (mounted) setState(() => book['shelf'] = next ? 1 : 0);
                  } catch (e) {
                    if (context.mounted)
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text(e.toString())));
                  }
                },
                child: Text(book['shelf'] == 1 ? '移出书架' : '加入书架'),
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
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ReaderPage(
                                widget.store,
                                book,
                                selected: m['chapter'],
                                anchor: m,
                              ),
                            ),
                          ),
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
