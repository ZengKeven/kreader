part of 'reader.dart';

extension ReaderSource on _ReaderState {
  Future<void> changeSource() async {
    if (modal || loading) return;
    modal = true;
    stopAuto();
    try {
      final selected = await showModalBottomSheet<Json>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => _BookSourcePicker(
          store: store,
          book: widget.book,
          mapping: sourceMapping,
        ),
      );
      if (selected == null || !mounted) return;
      await switchBookSource(selected);
    } finally {
      modal = false;
    }
  }

  Future<void> switchBookSource(Json selected) async {
    final mapping = {
      'id': '$book-*',
      'book': book,
      'chapter': '*',
      'targetBook': selected['id'],
      'targetSource': selected['origin'],
      'targetUrl': selected['url'],
    };
    final oldChapter = chapter < toc.length ? toc[chapter] : null;
    final oldBody = bodies[chapter];
    Json? anchor;
    if (oldBody != null) {
      final text = oldBody[paragraph]['text'] as String;
      final start = offset.clamp(0, text.length);
      anchor = {
        'paragraph': paragraph,
        'offset': start,
        'quote': text.substring(start, math.min(text.length, start + 26)),
      };
    }
    saveTimer?.cancel();
    final saved = save();
    updateReader(() => loading = true);
    try {
      await saved;
      anchor ??= await store.position(book);
      var oldId = oldChapter?['id'];
      if (oldBody == null)
        oldId = widget.selected ?? anchor?['chapterId'] ?? oldId;
      final chapters = await store.readingToc(book, mapping);
      if (chapters.isEmpty) throw StateError('这个书源的目录为空');
      final previous = toc.where((c) => _matchesChapter(c, oldId)).firstOrNull;
      var index = chapters.indexWhere(
        (c) =>
            _matchesChapter(c, oldId) ||
            _matchesChapter(c, previous?['originalChapter']),
      );
      if (index < 0 && previous != null) {
        final title = chapterTitleKey(previous['title']);
        bool sameTitle(Json ch) => chapterTitleKey(ch['title']) == title;
        if (toc.where(sameTitle).length == 1 &&
            chapters.where(sameTitle).length == 1) {
          index = chapters.indexWhere(sameTitle);
        }
      }
      final sameChapter = index >= 0;
      if (!sameChapter) index = chapter.clamp(0, chapters.length - 1);
      final ch = chapters[index];
      final item = await store.chapter(
        selected['id'],
        ch['sourceChapter'] ?? ch['id'],
      );
      final blocks = rows(item['blocks']);
      if (blocks.isEmpty) throw StateError('这个书源的章节没有正文');
      if (!mounted) return;
      await store.setBookSource(mapping);
      if (!mounted) return;
      useCatalog(mapping, chapters);
      bodies[index] = blocks;
      await open(
        index,
        spot: sameChapter ? anchor : null,
        keepPreviousPosition: !sameChapter && oldId != null,
      );
      if (!sameChapter && oldId != null) {
        message('新目录未找到唯一同名章节，已定位到第 ${index + 1} 章。可从目录调整续读位置。');
      }
    } finally {
      if (mounted && loading) updateReader(() => loading = false);
    }
  }
}

class _BookSourcePicker extends StatefulWidget {
  final ReaderStore store;
  final Json book;
  final Json? mapping;
  const _BookSourcePicker({
    required this.store,
    required this.book,
    required this.mapping,
  });

  @override
  State<_BookSourcePicker> createState() => _BookSourcePickerState();
}

class _BookSourcePickerState extends State<_BookSourcePicker> {
  final matches = <Json>[];
  final seenBooks = <String>{};
  int done = 0, failed = 0;
  int? total;
  String? error;
  bool closed = false;
  bool get active => mounted && !closed;
  bool get searching => error == null && (total == null || done < total!);
  String get emptyMessage {
    if (error != null) return error!;
    if (searching) return '正在查找同一本小说…';
    if (total == 0) return '没有其他可搜索的书源';
    if (failed == total) return '其他书源均搜索失败，请重试';
    return '没有找到匹配的小说';
  }

  @override
  void initState() {
    super.initState();
    search();
  }

  Future<void> search() async {
    setState(() {
      matches.clear();
      seenBooks.clear();
      done = failed = 0;
      total = null;
      error = null;
    });
    try {
      final book = widget.book, store = widget.store;
      final query = bareBookTitle(book['title']);
      if (query.isEmpty) throw StateError('缺少书名，无法查找其他书源');
      final currentBook = widget.mapping?['targetBook'] ?? book['id'];
      final currentSource =
          widget.mapping?['targetSource'] ??
          (currentBook == book['id']
              ? book['origin']
              : (await store.get('books/$currentBook'))['origin']);
      final sources = rows(
        await store.get('sources'),
      ).where((s) => searchableSource(s) && s['id'] != currentSource).toList();
      if (!active) return;
      setState(() => total = sources.length);
      final title = bookTitleKey(book['title']);
      final author = bookAuthorKey(book['author']);
      await store.searchSources(
        query,
        sources,
        active: () => active,
        onSource: (src, books, failure) => setState(() {
          done++;
          if (failure != null) failed++;
          for (final match in books) {
            final id = match['id'];
            if (id is String &&
                id.isNotEmpty &&
                id != currentBook &&
                bookTitleKey(match['title']) == title &&
                (author.isEmpty || bookAuthorKey(match['author']) == author) &&
                seenBooks.add(id)) {
              matches.add({
                ...match,
                'origin': src['id'],
                'sourceName': src['name'],
              });
            }
          }
        }),
      );
    } catch (e) {
      if (active) setState(() => error = '$e');
    }
  }

  void close([Json? book]) {
    closed = true;
    Navigator.of(context).pop(book);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Json>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) closed = true;
      },
      child: SafeArea(
        child: FractionallySizedBox(
          heightFactor: .7,
          child: Column(
            children: [
              ListTile(
                title: Text('为《${bareBookTitle(widget.book['title'])}》换源'),
                subtitle: error != null
                    ? null
                    : Text(
                        total == null
                            ? '正在获取可用书源'
                            : '已搜索 $done / $total 个书源${failed == 0 ? '' : ' · $failed 个失败'}',
                      ),
                trailing: IconButton(
                  tooltip: '关闭',
                  icon: const Icon(Icons.close),
                  onPressed: close,
                ),
              ),
              if (searching)
                LinearProgressIndicator(
                  value: total == null ? null : done / total!,
                ),
              Expanded(
                child: matches.isNotEmpty
                    ? ListView.builder(
                        itemCount: matches.length,
                        itemBuilder: (_, i) {
                          final match = matches[i];
                          return ListTile(
                            title: Text(match['sourceName']),
                            subtitle: Text(
                              [match['title'], match['author']]
                                  .whereType<String>()
                                  .where((v) => v.isNotEmpty)
                                  .join(' · '),
                            ),
                            onTap: () => close(match),
                          );
                        },
                      )
                    : Center(child: Text(emptyMessage)),
              ),
              if (!searching && matches.isEmpty)
                TextButton(onPressed: search, child: const Text('重新搜索')),
            ],
          ),
        ),
      ),
    );
  }
}
