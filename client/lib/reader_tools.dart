part of 'reader.dart';

Json han = {};

class DisplayText {
  String value;
  List<int> indices;
  DisplayText(this.value) : indices = List.generate(value.length + 1, (i) => i);
  void replace(Pattern pattern, String Function(Match) replacement) {
    final buf = StringBuffer(), idx = <int>[];
    int from = 0;
    for (final m in pattern.allMatches(value)) {
      if (m.end == m.start) continue;
      buf.write(value.substring(from, m.start));
      idx.addAll(indices.getRange(from, m.start));
      final t = replacement(m);
      buf.write(t);
      for (int j = 0; j < t.length; j++) {
        idx.add(indices[m.start + ((m.end - m.start) * j ~/ t.length)]);
      }
      from = m.end;
    }
    buf.write(value.substring(from));
    idx.addAll(indices.getRange(from, indices.length));
    value = buf.toString();
    indices = idx;
  }
}

extension ReaderTools on _ReaderState {
  List<Json> displayBlocks(int ch) {
    return [
      for (var i = 0; i < bodies[ch]!.length; i++)
        () {
          final raw = bodies[ch]![i];
          final b = {
            ...raw,
            'marks': marks
                .where(
                  (m) =>
                      _matchesChapter(toc[ch], m['chapter']) &&
                      m['paragraph'] == i &&
                      m['kind'] != '书签' &&
                      (m['original'] == null || m['original'] == raw['text']),
                )
                .toList(),
          };
          final text = b['text'] as String;
          final d = DisplayText(text);
          final fix = corrections
              .where(
                (x) =>
                    _matchesChapter(toc[ch], x['chapter']) &&
                    x['paragraph'] == i &&
                    x['original'] == text,
              )
              .firstOrNull;
          if (fix != null && text.isNotEmpty)
            d.replace(text, (_) => fix['value']);
          for (final r in rules) {
            if (r['enabled'] != false &&
                (r['book'] == null || r['book'] == book) &&
                (r['from'] ?? '') != '') {
              d.replace(r['from'] as String, (_) => r['to'] ?? '');
            }
          }
          final table = han[pref('script', '原文')];
          if (table is Map) {
            d.replace(RegExp('[㐀-鿿]'), (m) => table[m[0]] ?? m[0]!);
          }
          if (pref('resegment', false) && d.value.length > 140) {
            d.replace(RegExp('[。！？]'), (m) => '${m[0]}\n');
          }
          return d.value == text
              ? b
              : {...b, 'display': d.value, 'map': d.indices, 'markup': null};
        }(),
    ];
  }

  Future<void> guarded(Future<void> Function() fn) async {
    try {
      await fn();
    } catch (e) {
      message(e);
    }
  }

  Future<void> reloadTools() async {
    final all = await Future.wait([
      store.items('mark', book),
      store.items('rule'),
      store.items('correction', book),
    ]);
    if (mounted)
      updateReader(() {
        marks = all[0];
        rules = all[1];
        corrections = all[2];
        geometry = '';
      });
  }

  Future<void> mark(
    String kind, {
    int? c,
    int? p,
    int? start,
    int? end,
    String? note,
  }) async {
    await guarded(() async {
      final ch = c ?? chapter, idx = p ?? paragraph;
      final text = bodies[ch]![idx]['text'] as String;
      final o = (start ?? offset).clamp(0, text.length),
          e = (end ?? math.min(text.length, o + 32)).clamp(o, text.length);
      await store.putItem('mark', {
        'id': ReaderStore.eventId(),
        'book': book,
        'chapter': toc[ch]['id'],
        'paragraph': idx,
        'offset': o,
        'end': e,
        'original': text,
        'quote': text.substring(o, e),
        'note': note ?? '',
        'kind': kind,
        'time': DateTime.now().millisecondsSinceEpoch,
      });
      await reloadTools();
      message('已保存$kind');
    });
  }

  Future<void> selection(int c, LinePiece ln) async {
    stopAuto();
    final text = bodies[c]![ln.block]['text'] as String;
    if (text.isEmpty) return;
    var sel = TextSelection(
      baseOffset: ln.start.clamp(0, text.length),
      extentOffset: ln.end.clamp(0, text.length),
    );
    final ctl = TextEditingController(text: text)..selection = sel;
    final op = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选中文本'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: TextField(
            controller: ctl,
            readOnly: true,
            autofocus: true,
            maxLines: 8,
            minLines: 2,
            selectionControls: materialTextSelectionControls,
          ),
        ),
        actions: [
          Wrap(
            children: [
              for (final a in ['复制', '高亮', '下划线', '批注', '书签', '查词', '修正文段'])
                TextButton(
                  onPressed: () {
                    sel = ctl.selection;
                    Navigator.pop(ctx, a);
                  },
                  child: Text(a),
                ),
            ],
          ),
        ],
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ctl.dispose();
    });
    if (op == null || !mounted) return;
    final start = sel.isValid && !sel.isCollapsed ? sel.start : ln.start,
        end = sel.isValid && !sel.isCollapsed ? sel.end : ln.end;
    final q = text.substring(
      start.clamp(0, text.length),
      end.clamp(start, text.length),
    );
    await guarded(() async {
      switch (op) {
        case '复制':
          await Clipboard.setData(ClipboardData(text: q));
          message('已复制');
          break;
        case '修正文段':
          final v = await field('修正本段原文', text);
          if (v != null) {
            await store.putItem('correction', {
              'id': '$book-${toc[c]["id"]}-${ln.block}',
              'book': book,
              'chapter': toc[c]['id'],
              'paragraph': ln.block,
              'original': text,
              'value': v,
            });
            await reloadTools();
          }
          break;
        case '查词':
          await dictionary(q);
          break;
        default:
          String? note;
          if (op == '批注') {
            note = await field('写批注');
            if (note == null) return;
          }
          await mark(op, c: c, p: ln.block, start: start, end: end, note: note);
      }
    });
  }

  Future<void> jump(Json m) async {
    final i = toc.indexWhere(
      (x) => _matchesChapter(x, m['chapter'] ?? m['chapterId']),
    );
    if (i < 0) {
      message('原章节已变更，请重新定位');
      return;
    }
    await open(i, spot: m);
    if (mounted) updateReader(() => menus = false);
  }

  Future<void> contents() async {
    if (toc.isEmpty) return;
    stopAuto();
    String q = '';
    int tab = 0;
    bool rev = false;
    final dest = await showModalBottomSheet<Json>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => FractionallySizedBox(
        heightFactor: .78,
        child: StatefulBuilder(
          builder: (ctx, up) {
            final chapters = (rev ? toc.reversed : toc)
                .where((x) => (x['title'] as String).contains(q))
                .toList();
            final notes = marks
                .where((m) => ('${m["note"]} ${m["quote"]}').contains(q))
                .toList();
            return Column(
              children: [
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('目录')),
                    ButtonSegment(value: 1, label: Text('书签与批注')),
                  ],
                  selected: {tab},
                  onSelectionChanged: (v) => up(() => tab = v.first),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    onChanged: (v) => up(() => q = v),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: tab == 0 ? '筛选章节' : '筛选摘录或笔记',
                      suffixIcon: IconButton(
                        onPressed: () => up(() => rev = !rev),
                        icon: const Icon(Icons.swap_vert),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: tab == 0 ? chapters.length : notes.length,
                    itemBuilder: (_, i) {
                      if (tab == 0) {
                        final ch = chapters[i];
                        return ListTile(
                          selected: ch['id'] == toc[chapter]['id'],
                          title: Text(ch['title']),
                          onTap: () =>
                              Navigator.pop(ctx, {'chapter': ch['id']}),
                        );
                      }
                      final m = notes[i];
                      return ListTile(
                        title: Text(
                          '${m["kind"]} · ${m["note"] == "" ? m["quote"] : m["note"]}',
                        ),
                        subtitle: Text(
                          place({...m, 'chapterId': m['chapter']}),
                        ),
                        onTap: () => Navigator.pop(ctx, m),
                        trailing: IconButton(
                          tooltip: '删除',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => guarded(() async {
                            await store.send('DELETE', 'items/mark/${m["id"]}');
                            await reloadTools();
                            if (ctx.mounted) up(() {});
                          }),
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
    if (dest != null) await jump(dest);
  }

  Future<Json?> pickRow(
    String title,
    List<Json> data,
    String Function(Json) label,
  ) async {
    if (!mounted) return null;
    String q = '';
    return showModalBottomSheet<Json>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => FractionallySizedBox(
        heightFactor: .7,
        child: StatefulBuilder(
          builder: (ctx, up) {
            final filtered = data.where((v) => label(v).contains(q)).toList();
            return Column(
              children: [
                Text(title, style: Theme.of(ctx).textTheme.titleLarge),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: '筛选结果',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (v) => up(() => q = v),
                  ),
                ),
                Expanded(
                  child: filtered.isEmpty
                      ? const Center(child: Text('没有匹配结果'))
                      : ListView.builder(
                          itemCount: filtered.length,
                          itemBuilder: (_, i) => ListTile(
                            title: Text(
                              label(filtered[i]),
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => Navigator.pop(ctx, filtered[i]),
                          ),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> findInBook() async {
    final q = await field('搜索正文');
    if (q == null || q.trim().isEmpty) return;
    List<Json> result = [];
    bool cached = widget.book['origin'] != 'local';
    if (!cached) {
      try {
        result = rows(await store.get('books/$book/find', {'q': q}));
      } on SocketException {
        cached = true;
      } on TimeoutException {
        cached = true;
      } on http.ClientException {
        cached = true;
      }
    }
    if (cached) {
      final catalog = toc;
      final edition = readingBook;
      for (final ch in catalog) {
        final body = await store.cachedChapter(
          edition,
          ch['sourceChapter'] ?? ch['id'],
        );
        if (!mounted || leftReader || !identical(toc, catalog)) return;
        if (body == null) continue;
        final bs = rows(body['blocks']);
        for (int i = 0; i < bs.length; i++) {
          final t = bs[i]['text'] as String;
          final o = t.indexOf(q);
          if (o >= 0)
            result.add({
              'chapterId': ch['id'],
              'paragraph': i,
              'offset': o,
              'title': ch['title'],
              'text': t,
            });
        }
      }
    }
    if (!mounted || leftReader) return;
    final m = await pickRow(
      cached ? '本机缓存的章节 · ${result.length} 段' : '全书 · ${result.length} 段',
      result,
      (v) => '${v["title"]}\n${v["text"]}',
    );
    if (m != null) await jump({...m, 'quote': q});
  }

  Future<void> comments(int ch, int p, Json b) async {
    String text = b['commentText'] ?? '';
    final url = b['commentUrl'] ?? '';
    if (text.isEmpty && url != '') {
      try {
        final (bid, cid) = mappedChapter(ch);
        final data = await store.get('books/$bid/chapters/$cid/comments', {
          'paragraph': '$p',
        });
        text = data['text'];
      } catch (e) {
        text = '段评暂时无法读取：$e';
      }
    }
    if (text.isEmpty) text = '书源只提供了段评数量。';
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('书源段评'),
        content: SingleChildScrollView(child: SelectableText(text)),
        actions: [
          if (url != '')
            TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: url)),
              child: const Text('复制原文地址'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> dictionaryRules() async {
    final dict = await store.items('dict');
    final r = await pickRow('词典规则', [
      {'add': true},
      ...dict.where((x) => x['url'] != null),
    ], (x) => x['add'] == true ? '＋ 新增在线词典' : x['name']);
    if (r == null) return;
    if (r['add'] != true) {
      final op = await choose(r['name'], ['删除规则', '取消']);
      if (op == '删除规则') await store.send('DELETE', 'items/dict/${r["id"]}');
      return;
    }
    final n = await field('词典名称');
    if (n == null || n.trim().isEmpty) return;
    final url = await field('查询 URL（用 {word} 表示选词）');
    if (url == null || !url.contains('{word}')) return;
    final selector = await field('释义规则（CSS 或 JSONPath）');
    if (selector == null || selector.trim().isEmpty) return;
    await store.putItem('dict', {
      'id': ReaderStore.eventId(),
      'name': n,
      'url': url,
      'selector': selector,
    });
  }

  Future<void> dictionary(String q) async {
    final list = await store.items('dict');
    final match = list.where((v) => v['word'] == q).firstOrNull;
    if (!mounted) return;
    if (match != null) {
      await showDialog(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(q),
          content: SelectableText(match['definition']),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      return;
    }
    final services = list.where((v) => v['url'] != null).toList();
    if (services.isNotEmpty) {
      final service = await pickRow('查词方式', [
        {'name': '编写个人释义'},
        ...services,
      ], (r) => r['name']);
      if (service == null) return;
      if (service['url'] != null) {
        final result = await store.get('dictionary/lookup', {
          'q': q,
          'rule': service['id'],
        });
        if (!mounted) return;
        await showDialog(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(q),
            content: SingleChildScrollView(
              child: SelectableText(result['text']),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
        return;
      }
    }
    final v = await field('个人词典 · $q');
    if (v != null && v.trim().isNotEmpty) {
      await store.putItem('dict', {
        'id': ReaderStore.eventId(),
        'word': q,
        'definition': v,
      });
      message('词条已同步');
    }
  }

  Future<void> replacements() async {
    final r = await pickRow(
      '正文替换规则',
      [
        {'new': true},
        ...rules,
      ],
      (x) => x['new'] == true
          ? '＋ 新增文字替换'
          : '${x["enabled"] == false ? "停用" : "启用"} · ${x["from"]} → ${x["to"]}',
    );
    if (r == null) return;
    if (r['new'] == true) {
      final from = await field('要替换的原文');
      if (from == null || from.isEmpty) return;
      final to = await field('替换为（可留空）');
      if (to == null) return;
      final scope = await choose('生效范围', ['本书', '所有书籍']);
      if (scope == null) return;
      await store.putItem('rule', {
        'id': ReaderStore.eventId(),
        'from': from,
        'to': to,
        if (scope == '本书') 'book': book,
        'enabled': true,
      });
    } else {
      final op = await choose('管理规则', ['切换启停', '删除']);
      if (op == null) return;
      if (op == '删除') {
        await store.send('DELETE', 'items/rule/${r["id"]}');
      } else {
        await store.putItem('rule', {...r, 'enabled': r['enabled'] == false});
      }
    }
    await reloadTools();
  }

  Future<void> reloadChapter() async {
    if (toc.isEmpty) return;
    final old = chapter;
    final catalog = toc;
    final (edition, chapterId) = mappedChapter(old);
    await store.refreshChapter(edition, chapterId);
    if (!mounted ||
        leftReader ||
        chapter != old ||
        !identical(toc, catalog) ||
        loading) {
      return;
    }
    final text = bodies[old]?[paragraph]['text'] as String? ?? '';
    final o = offset.clamp(0, text.length);
    final spot = {
      'paragraph': paragraph,
      'offset': o,
      'quote': text.substring(o, math.min(text.length, o + 26)),
    };
    bodies.clear();
    layouts.clear();
    failures.clear();
    await open(old, spot: spot, keepPreviousPosition: unlocated);
  }

  Widget downloadButton() => ValueListenableBuilder<BookDownload?>(
    valueListenable: store.activeDownload,
    builder: (buttonContext, job, _) => IconButton(
      tooltip: job == null ? '下载全书' : '下载进度',
      icon: Icon(
        job == null ? Icons.download_outlined : Icons.downloading_outlined,
      ),
      onPressed: toc.isEmpty && job == null
          ? null
          : () => guarded(() => downloadCurrentBook(buttonContext)),
    ),
  );

  String downloadStatus(BookDownload job) {
    if (!job.running && job.saved == job.total) {
      return '全书已下载 · ${job.total} 章';
    }
    final failures = job.failed == 0 ? '' : ' · 失败 ${job.failed} 章';
    return '已下载 ${job.saved}/${job.total} 章$failures';
  }

  Future<void> downloadCurrentBook(BuildContext buttonContext) async {
    if (modal || loading) return;
    final active = store.activeDownload.value;
    if (active != null) {
      modal = true;
      stopAuto();
      try {
        await showDialog<void>(
          context: buttonContext,
          builder: (c) => ListenableBuilder(
            listenable: active,
            builder: (_, _) => AlertDialog(
              title: Text(
                '下载《${active.title}》',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(value: active.saved / active.total),
                  const SizedBox(height: 12),
                  Text(downloadStatus(active)),
                  if (active.stopping && active.saved < active.total)
                    Text(active.running ? '正在停止下载…' : '已停止下载'),
                  if (active.error != null)
                    Text(
                      active.error!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
              actions: [
                if (active.running && !active.stopping)
                  TextButton(onPressed: active.stop, child: const Text('停止下载')),
                TextButton(
                  onPressed: () => Navigator.pop(c),
                  child: const Text('关闭'),
                ),
              ],
            ),
          ),
        );
      } finally {
        modal = false;
      }
      return;
    }
    if (toc.isEmpty) return;
    final edition = readingBook;
    final server = store.namespace;
    final result = await store.downloadBook(
      edition,
      widget.book['title'],
      toc.map<String>((ch) => ch['sourceChapter'] ?? ch['id']),
    );
    if (!mounted ||
        leftReader ||
        ModalRoute.of(context)?.isCurrent == false ||
        readingBook != edition ||
        store.namespace != server) {
      return;
    }
    final status = downloadStatus(result);
    if (result.saved == result.total) {
      message(status);
    } else if (result.error != null) {
      message('$status\n${result.error}。再次点击下载可重试。');
    } else {
      message('已停止下载 · $status');
    }
  }

  Future<void> reparse() async {
    final enc = await choose('以此编码重新分章', [
      'auto',
      'UTF-8',
      'GB18030',
      'UTF-16',
    ]);
    if (enc == null) return;
    final regex = await field('章节标题正则（留空使用默认）');
    if (regex == null) return;
    await save();
    await store.send('POST', 'books/$book/reparse', {
      'encoding': enc,
      'pattern': regex,
    });
    store.map('tocs').remove(book);
    bodies.clear();
    layouts.clear();
    await start();
  }

  Future<void> toolsMenu() async {
    stopAuto();
    final op = await choose('阅读工具', [
      '添加书签',
      '搜索正文',
      '文字替换',
      '个人词典',
      '词典规则',
      '刷新本章',
      if (widget.book['origin'] != 'local') '原文地址',
      if (widget.book['url'] == '.txt') 'TXT 重新分章',
    ]);
    if (op == null) return;
    await guarded(() async {
      switch (op) {
        case '添加书签':
          await mark('书签');
          break;
        case '搜索正文':
          await findInBook();
          break;
        case '文字替换':
          await replacements();
          break;
        case '词典规则':
          await dictionaryRules();
          break;
        case '个人词典':
          final q = await field('查询或添加词条');
          if (q != null && q.isNotEmpty) await dictionary(q);
          break;
        case '刷新本章':
          await reloadChapter();
          break;
        case '原文地址':
          final (bid, cid) = mappedChapter(chapter);
          final result = await store.get('books/$bid/chapters/$cid/url');
          final url =
              result['url'] ??
              sourceMapping?['targetUrl'] ??
              widget.book['url'];
          await Clipboard.setData(ClipboardData(text: url));
          message('已复制原文地址：$url');
          break;
        case 'TXT 重新分章':
          await reparse();
      }
    });
  }
}
