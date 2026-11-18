import 'dart:async';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:html/parser.dart' as html;
import 'package:html/dom.dart' as dom;
import 'package:http/http.dart' as http;
import 'store.dart';
import 'curl.dart';
import 'reading_session.dart';
part 'reader_settings.dart';
part 'reader_tools.dart';
part 'reader_source.dart';

SystemUiOverlayStyle readerSystemBars(Brightness background) {
  final dark = background == Brightness.dark;
  return (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
      .copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: dark
            ? Brightness.light
            : Brightness.dark,
        systemNavigationBarContrastEnforced: false,
      );
}

class LinePiece {
  final int block, start, end;
  final double y, height;
  final InlineSpan? span;
  final String? image;
  LinePiece(
    this.block,
    this.start,
    this.end,
    this.y,
    this.height,
    this.span,
    this.image,
  );
}

class LayoutPages {
  final List<List<LinePiece>> pages = [[]];
  double used = 0;
  LayoutPages(
    List<Json> blocks,
    double width,
    double height,
    double size,
    double leading,
    Color ink, [
    Json prefs = const {},
  ]) {
    void add(
      int b,
      int start,
      int end,
      double h,
      InlineSpan? span,
      String? image,
    ) {
      if (used + h > height && pages.last.isNotEmpty) {
        pages.add([]);
        used = 0;
      }
      pages.last.add(LinePiece(b, start, end, used, h, span, image));
      used += h;
    }

    if (blocks.isNotEmpty &&
        blocks.first['kind'] != 'heading' &&
        prefs['hideTitle'] != true &&
        (prefs['chapterTitle'] ?? '') != '') {
      final span = TextSpan(
        text: prefs['chapterTitle'],
        style: TextStyle(
          fontFamily: prefs['titleFont'] ?? prefs['font'] ?? 'serif',
          fontSize: (prefs['titleSize'] ?? size + 3).toDouble(),
          color: ink,
          fontWeight: FontWeight.w600,
          height: leading,
        ),
      );
      final paint = TextPainter(
        text: span,
        textDirection: TextDirection.ltr,
        maxLines: 2,
      )..layout(maxWidth: width);
      used += (prefs['titleGap'] ?? 6).toDouble();
      add(-1, 0, 0, paint.height, span, null);
      used += (prefs['titleGap'] ?? 6).toDouble();
      paint.dispose();
    }
    for (int b = 0; b < blocks.length; b++) {
      final block = blocks[b];
      if (block['kind'] == 'image') {
        add(b, 0, 1, math.min(height, 260), null, block['bytes']);
        used += 8;
        continue;
      }
      final heading = block['kind'] == 'heading';
      if (heading && prefs['hideTitle'] == true) continue;
      final text = (block['display'] ?? block['text']) as String;
      if (text.isEmpty) continue;
      final style = TextStyle(
        fontFamily:
            (heading ? prefs['titleFont'] : null) ?? prefs['font'] ?? 'serif',
        letterSpacing: (prefs['spacing'] ?? 0).toDouble(),
        fontStyle: prefs['italic'] == true
            ? FontStyle.italic
            : FontStyle.normal,
        fontSize: block['kind'] == 'heading'
            ? (prefs['titleSize'] ?? size + 3).toDouble()
            : size,
        height: leading,
        color: ink,
        fontWeight: block['kind'] == 'heading'
            ? FontWeight.w600
            : prefs['bold'] == true
            ? FontWeight.bold
            : FontWeight.normal,
      );
      final ranges = <({int start, int end, TextStyle style})>[];
      if (block['markup'] != null) {
        int cursor = 0;
        void visit(dom.Node node, TextStyle current) {
          if (node is dom.Text) {
            final t = node.text;
            final p = text.indexOf(t, cursor);
            if (p >= 0) {
              ranges.add((start: p, end: p + t.length, style: current));
              cursor = p + t.length;
            }
            return;
          }
          if (node is dom.Element) {
            if (['b', 'strong'].contains(node.localName))
              current = current.copyWith(fontWeight: FontWeight.bold);
            if (['i', 'em'].contains(node.localName))
              current = current.copyWith(fontStyle: FontStyle.italic);
          }
          for (final child in node.nodes) {
            visit(child, current);
          }
        }

        visit(html.parseFragment(block['markup']), style);
      }
      InlineSpan span(int from, int to) {
        final pieces = <TextSpan>[], bounds = <int>{from, to};
        final annotations = (block['marks'] as List? ?? []).cast<Json>();
        int original(int x) =>
            block['map'] == null ? x : (block['map'] as List)[x];
        for (final r in ranges) {
          if (r.start > from && r.start < to) bounds.add(r.start);
          if (r.end > from && r.end < to) bounds.add(r.end);
        }
        for (final m in annotations) {
          for (final x in [m['offset'], m['end']]) {
            if (x is! int) continue;
            final n = block['map'] == null
                ? x
                : (block['map'] as List).indexWhere((o) => o >= x);
            if (n > from && n < to) bounds.add(n);
          }
        }
        final cuts = bounds.toList()..sort();
        for (int j = 1; j < cuts.length; j++) {
          final l = cuts[j - 1], r = cuts[j];
          var st =
              ranges
                  .where((v) => v.start <= l && v.end > l)
                  .firstOrNull
                  ?.style ??
              style;
          for (final m in annotations) {
            if (original(l) >= (m['offset'] ?? 0) &&
                original(l) < (m['end'] ?? 0)) {
              st = m['kind'] == '下划线'
                  ? st.copyWith(
                      decoration: TextDecoration.underline,
                      decorationColor: Colors.deepOrange,
                    )
                  : st.copyWith(
                      backgroundColor: Colors.amber.withValues(alpha: .36),
                    );
            }
          }
          pieces.add(TextSpan(text: text.substring(l, r), style: st));
        }
        return TextSpan(style: style, children: pieces);
      }

      final painter =
          TextPainter(
            text: span(0, text.length),
            textDirection: TextDirection.ltr,
          )..layout(
            maxWidth: math.max(
              1,
              width - (heading ? 0 : (prefs['indent'] ?? 0) * size),
            ),
          );
      if (heading) used += (prefs['titleGap'] ?? 6).toDouble();
      final metrics = painter.computeLineMetrics();
      for (final line in metrics) {
        final pos = painter.getPositionForOffset(
          Offset(line.left + 0.05, line.baseline - line.ascent / 2),
        );
        final range = painter.getLineBoundary(pos);
        if (range.end > range.start)
          add(
            b,
            block['map'] == null
                ? range.start
                : (block['map'] as List)[range.start],
            block['map'] == null
                ? range.end
                : (block['map'] as List)[range.end],
            line.height,
            span(range.start, range.end),
            null,
          );
      }
      painter.dispose();
      used += heading
          ? (prefs['titleGap'] ?? 6).toDouble()
          : (prefs['paraGap'] ?? size * .58).toDouble();
    }
  }
  int pageFor(int block, int offset) {
    for (int p = 0; p < pages.length; p++) {
      if (pages[p].any((l) => l.block == block && l.end > offset)) return p;
    }
    return math.max(
      0,
      pages.indexWhere((lines) => lines.any((l) => l.block >= block)),
    );
  }
}

class ReaderPage extends StatefulWidget {
  final ReaderStore store;
  final Json book;
  final String? selected;
  final Json? anchor;
  final bool resumeSelected;
  const ReaderPage(
    this.store,
    this.book, {
    super.key,
    this.selected,
    this.anchor,
    this.resumeSelected = false,
  });
  @override
  State<ReaderPage> createState() => _ReaderState();
}

typedef Leaf = ({int ch, int pg});

bool _matchesChapter(Json chapter, Object? id) =>
    id != null &&
    (chapter['id'] == id ||
        chapter['sourceChapter'] == id ||
        chapter['originalChapter'] == id);

class _ReaderState extends State<ReaderPage> with WidgetsBindingObserver {
  // Keep the current page stable when a preceding chapter finishes loading.
  static const pageOrigin = 100000;
  ReaderStore get store => widget.store;
  String get book => widget.book['id'];
  List<Json> toc = [], marks = [], rules = [], corrections = [];
  Json? sourceMapping;
  String get readingBook => sourceMapping?['targetBook'] ?? book;
  final bodies = <int, List<Json>>{},
      layouts = <int, LayoutPages>{},
      failures = <int, String>{},
      fetching = <int>{};
  int chapter = 0,
      paragraph = 0,
      offset = 0,
      page = 0,
      baseCh = 0,
      basePg = 0,
      epoch = 0,
      renderId = 0;
  bool loading = true,
      menus = false,
      modal = false,
      disposed = false,
      leftReader = false,
      hasDisplayedChapter = false,
      unlocated = false;
  static const hardware = MethodChannel('reader/hardware');
  void volume(bool on) {
    if (Platform.isAndroid) hardware.invokeMethod('volume', on);
  }

  bool get hideSystemBars =>
      Platform.isAndroid && pref('hideNavigationBar', false) == true;
  bool systemBarsHidden = false;

  void syncSystemBars() {
    final hidden = !leftReader && hideSystemBars;
    if (systemBarsHidden == hidden) return;
    systemBarsHidden = hidden;
    unawaited(hardware.invokeMethod<void>('setSystemBarsHidden', hidden));
  }

  void updateReader(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
    _syncReadingTime();
  }

  double? seekPreview;
  String? power;
  Timer? clockTimer;
  String? error;
  String geometry = '';
  double height = 1, width = 1;
  Timer? saveTimer, automatic;
  ScrollController? scroll;
  PageController? pager;
  final centerKey = GlobalKey();
  Json get prefs => {
    ...store.map('appearance'),
    if (store.map('perBook').containsKey(book)) ...store.map('perBook')[book],
  };
  dynamic pref(String k, dynamic fallback) =>
      prefs[k] ?? store.state[k] ?? fallback;
  String get mode => pref('mode', store.state['paged'] == true ? '滑动' : '滚动');
  bool get paged => mode != '滚动';
  bool? get nightOverride =>
      (prefs.containsKey('night') ? prefs['night'] : store.state['night'])
          as bool?;
  bool get night =>
      nightOverride ?? Theme.of(context).brightness == Brightness.dark;
  double numv(String k, double d) => (pref(k, d) as num).toDouble();
  Color get paper => Color(
    pref(night ? 'nightPaper' : 'paper', night ? 0xff202321 : 0xfff8f5e9),
  );
  Color get ink =>
      Color(pref(night ? 'nightInk' : 'ink', night ? 0xffc4c7bd : 0xff342f29));
  double get size => numv('fontSize', 21);
  bool get spread =>
      paged && pref('spread', false) && MediaQuery.sizeOf(context).width >= 900;
  void message(Object e) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
  }

  void change(String key, dynamic value) {
    if (key == 'volume') volume(value == true);
    setState(() {
      final m = store.map('perBook');
      if (m.containsKey(book)) {
        m[book][key] = value;
      } else {
        store.map('appearance')[key] = value;
      }
    });
    if (key == 'hideNavigationBar') syncSystemBars();
    store.persist();
  }

  void refreshPageInfo() {
    clockTimer?.cancel();
    if (leftReader) return;
    _readingSession.checkpoint();
    const interval = Duration(seconds: 30);
    final elapsed =
        DateTime.now().millisecondsSinceEpoch % interval.inMilliseconds;
    clockTimer = Timer(
      interval - Duration(milliseconds: elapsed),
      refreshPageInfo,
    );
    if (loading) return;
    final fields = {
      hideSystemBars ? '时间' : pref('header', '章节'),
      pref('footer', '阅读进度'),
    };
    if (fields.contains('时间')) setState(() {});
    if (Platform.isAndroid && fields.contains('电量')) {
      hardware.invokeMethod<int>('battery').then((n) {
        final level = n == null || n < 0 ? null : '$n%';
        if (mounted && !leftReader && level != power)
          setState(() => power = level);
      });
    }
  }

  late final _readingServer = store.namespace;
  late final _readingSession = ReadingSession((start, end) {
    unawaited(
      store
          .rememberReadingTime(widget.book, start, end, server: _readingServer)
          .onError<FileSystemException>((_, _) => debugPrint('无法保存本机阅读时长')),
    );
  });
  bool _routeVisible = false;
  bool _foreground = false;

  void _syncReadingTime() => _readingSession.setVisible(
    _routeVisible &&
        _foreground &&
        !leftReader &&
        hasDisplayedChapter &&
        !loading &&
        error == null &&
        store.token.isNotEmpty &&
        store.namespace == _readingServer,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeVisible = ModalRoute.isCurrentOf(context) ?? true;
    _syncReadingTime();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    refreshPageInfo();
    syncSystemBars();
    if (Platform.isAndroid) {
      hardware.setMethodCallHandler((call) async {
        if (call.method == 'turn' && !modal) {
          _readingSession.activity();
          turn(call.arguments as int);
        }
      });
      volume(pref('volume', false));
    }
    start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncReadingTime();
    if (state != AppLifecycleState.resumed) {
      save();
      stopAuto();
    } else if (!leftReader) {
      refreshPageInfo();
      if (!loading && !modal) guarded(resume);
    }
  }

  Future<void> resume() async {
    final before = (chapter, paragraph, offset);
    if (widget.book['origin'] != 'local') {
      final mapping = await store.bookSourceMapping(book);
      if (!mounted || loading || modal) return;
      if ((mapping?['targetBook'] ?? book) != readingBook) {
        await start();
        return;
      }
    }
    final pos = await store.position(book);
    if (!mounted || loading || modal || before != (chapter, paragraph, offset))
      return;
    if (store.map('conflicts').containsKey(book)) {
      await start();
      return;
    }
    if (pos != null &&
        (chapter >= toc.length ||
            !_matchesChapter(toc[chapter], pos['chapterId']) ||
            pos['paragraph'] != paragraph ||
            pos['offset'] != offset)) {
      final i = toc.indexWhere((e) => _matchesChapter(e, pos['chapterId']));
      if (i >= 0)
        await open(i, spot: pos);
      else {
        store.map('tocs').remove(book);
        store.map('tocs').remove(readingBook);
        await start();
      }
    }
  }

  @override
  void dispose() {
    volume(false);
    if (Platform.isAndroid) hardware.setMethodCallHandler(null);
    clockTimer?.cancel();
    disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    finishReading();
    scroll?.dispose();
    pager?.dispose();
    super.dispose();
  }

  void finishReading() {
    if (leftReader) return;
    leftReader = true;
    _syncReadingTime();
    syncSystemBars();
    epoch++;
    saveTimer?.cancel();
    stopAuto();
    unawaited(save(leaving: true));
  }

  Future<void> start() async {
    final tag = ++epoch;
    saveTimer?.cancel();
    if (!loading) updateReader(() => loading = true);
    try {
      final mapping = widget.book['origin'] == 'local'
          ? null
          : await store.bookSourceMapping(book);
      if (!mounted || tag != epoch) return;
      sourceMapping = mapping;
      await reloadTools();
      if (han.isEmpty)
        han = jsonDecode(
          utf8.decode(
            (await rootBundle.load('assets/han.json')).buffer.asUint8List(),
          ),
        );
      await restoreFonts();
      final chapters = await store.readingToc(book, mapping);
      if (!mounted || tag != epoch) return;
      useCatalog(mapping, chapters);
      if (toc.isEmpty) throw StateError('目录为空');
      var spot = await store.position(book);
      if (!mounted || tag != epoch) return;
      final conflict = store.map('conflicts')[book];
      if (conflict != null) {
        final use = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (c) => AlertDialog(
            title: const Text('选择续读位置'),
            content: Text('本机：${place(spot)}\n服务端：${place(conflict)}'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('使用服务端'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('保留本机'),
              ),
            ],
          ),
        );
        if (use == null) return;
        await store.resolve(book, use);
        spot = await store.position(book);
      }
      if (!mounted || tag != epoch) return;
      final chosen = widget.selected ?? spot?['chapterId'];
      final i = toc.indexWhere((v) => _matchesChapter(v, chosen));
      final missing = chosen != null && i < 0;
      if (missing) {
        message('原章节已变更。翻页或选择章节后会保存新的阅读位置。');
      }
      final resumeSpot =
          i >= 0 &&
          (widget.selected == null ||
              (widget.resumeSelected &&
                  _matchesChapter(toc[i], spot?['chapterId'])));
      await open(
        math.max(0, i),
        spot: widget.anchor ?? (resumeSpot ? spot : null),
        keepPreviousPosition: missing,
      );
    } catch (e) {
      if (mounted && tag == epoch)
        updateReader(() {
          error = '$e';
          loading = false;
        });
    }
  }

  void useCatalog(Json? mapping, List<Json> chapters) {
    sourceMapping = mapping;
    toc = chapters;
    hasDisplayedChapter = false;
    bodies.clear();
    layouts.clear();
    failures.clear();
    fetching.clear();
    geometry = '';
  }

  String place(dynamic p) => p == null
      ? '开头'
      : '${toc.where((e) => _matchesChapter(e, p["chapterId"])).firstOrNull?["title"] ?? "原章节"} · 第 ${(p["paragraph"] ?? 0) + 1} 段';
  (String, String) mappedChapter(int i) =>
      (readingBook, toc[i]['sourceChapter'] ?? toc[i]['id']);

  Future<List<Json>> fetch(int i) async {
    final (id, cid) = mappedChapter(i);
    final item = await store.chapter(id, cid);
    final bs = rows(item['blocks']);
    if (bs.isEmpty) throw StateError('正文为空');

    return bs;
  }

  Future<void> open(
    int i, {
    Json? spot,
    bool keepPreviousPosition = false,
  }) async {
    if (i < 0 || i >= toc.length || !mounted || leftReader) return;
    saveTimer?.cancel();
    if (!loading) await save(localOnly: true);
    if (!mounted || leftReader) return;
    final tag = ++epoch;
    updateReader(() {
      loading = true;
      error = null;
    });
    try {
      final bs = bodies[i] ?? await fetch(i);
      if (!mounted || tag != epoch) return;
      int p = ((spot?['paragraph'] ?? 0) as int).clamp(0, bs.length - 1),
          o = ((spot?['offset'] ?? 0) as int).clamp(
            0,
            (bs[p]['text'] as String).length,
          );
      final q = spot?['quote'] ?? '';
      if (q != '' && !(bs[p]['text'] as String).substring(o).startsWith(q)) {
        final found = [
          for (var n = 0; n < bs.length; n++)
            if ((bs[n]['text'] as String).contains(q)) n,
        ];
        if (found.length == 1) {
          p = found.single;
          o = (bs[p]['text'] as String).indexOf(q);
        } else {
          keepPreviousPosition = true;
          message('原文已更新，未自动覆盖旧位置，请选择新的续读位置。');
        }
      }
      updateReader(() {
        chapter = i;
        hasDisplayedChapter = true;
        paragraph = p;
        offset = o;
        unlocated = keepPreviousPosition;
        bodies[i] = bs;
        loading = false;
        geometry = '';
        failures.remove(i);
      });
      warm();
      if (!unlocated) save();
    } catch (e) {
      if (mounted && tag == epoch)
        updateReader(() {
          error = '$e';
          loading = false;
        });
    }
  }

  void warm() {
    final catalog = toc;
    if ((chapter - baseCh).abs() > 4) {
      geometry = '';
      final keep = chapter;
      bodies.removeWhere((c, _) => (c - keep).abs() > 2);
    }

    for (final i in [chapter - 1, chapter + 1]) {
      if (i >= 0 &&
          i < toc.length &&
          !bodies.containsKey(i) &&
          !failures.containsKey(i) &&
          fetching.add(i)) {
        fetch(i)
            .then(
              (v) {
                if (mounted && identical(catalog, toc))
                  setState(() => bodies[i] = v);
              },
              onError: (e) {
                if (mounted && identical(catalog, toc))
                  setState(() => failures[i] = '$e');
              },
            )
            .whenComplete(() {
              if (identical(catalog, toc)) fetching.remove(i);
            });
      }
    }
  }

  Future<void> save({bool localOnly = false, bool leaving = false}) async {
    if (unlocated || !hasDisplayedChapter || bodies[chapter] == null) return;
    if (!leaving && (leftReader || loading || error != null)) return;
    final text = bodies[chapter]![paragraph]['text'] as String;
    final o = offset.clamp(0, text.length);
    await store.remember(
      book,
      toc[chapter]['id'],
      paragraph,
      o,
      text.substring(o, math.min(text.length, o + 26)),
      visit: leaving
          ? {
              'book': widget.book,
              'current': toc[chapter]['title'],
              'ord': chapter,
              'total': toc.length,
              'latest': toc.last['title'],
            }
          : null,
    );
    if (!localOnly) await store.flush();
  }

  LayoutPages layout(int c) => layouts.putIfAbsent(
    c,
    () => LayoutPages(
      displayBlocks(c),
      width,
      height,
      size,
      numv('leading', 1.65),
      ink,
      {...prefs, 'chapterTitle': toc[c]['title']},
    ),
  );
  List<({int ch, int pg})> before = [], after = [];
  void indexLeaves() {
    before = [];
    after = [];
    for (int c = baseCh; c >= 0 && bodies.containsKey(c); c--) {
      for (
        int p = (c == baseCh ? basePg : layout(c).pages.length) - 1;
        p >= 0;
        p--
      ) {
        before.add((ch: c, pg: p));
      }
    }
    for (int c = baseCh; c < toc.length && bodies.containsKey(c); c++) {
      for (int p = c == baseCh ? basePg : 0; p < layout(c).pages.length; p++) {
        after.add((ch: c, pg: p));
      }
    }
  }

  Leaf? leaf(int n) => n >= 0
      ? (n < after.length ? after[n] : null)
      : (-1 - n < before.length ? before[-1 - n] : null);
  double leafH(Leaf l) {
    final lines = layout(l.ch).pages[l.pg];
    return math.min(
      height,
      math.max(
        1.0,
        (lines.lastOrNull?.y ?? 0) +
            (lines.lastOrNull?.height ?? 0) +
            numv('paraGap', 10),
      ),
    );
  }

  void setup(double w, double h) {
    final key =
        '$w/$h/${jsonEncode(prefs)}/$night/$mode/$spread/$size/${numv("leading", 1.65)}';
    if (key != geometry) {
      final os = scroll, op = pager;
      geometry = key;
      width = w;
      height = h;
      layouts.clear();
      seekPreview = null;
      baseCh = chapter;
      basePg = page = layout(chapter).pageFor(paragraph, offset);
      final lines = layout(chapter).pages[page];
      final ln = lines
          .where((l) => l.block == paragraph && l.end > offset)
          .firstOrNull;
      scroll = ScrollController(initialScrollOffset: ln?.y ?? 0);
      pager = PageController(initialPage: pageOrigin);
      scroll!.addListener(onScroll);
      renderId++;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        os?.dispose();
        op?.dispose();
      });
    }
    indexLeaves();
  }

  (int, double) atY(double y) {
    if (y >= 0) {
      for (var i = 0; i < after.length; i++) {
        final h = leafH(after[i]);
        if (y < h || i == after.length - 1) return (i, math.max(0, y));
        y -= h;
      }
    } else {
      for (var i = 0; i < before.length; i++) {
        y += leafH(before[i]);
        if (y >= 0 || i == before.length - 1) return (-1 - i, math.max(0, y));
      }
    }
    return (0, 0);
  }

  void onScroll() {
    if (disposed || paged || scroll?.hasClients != true || loading) return;
    final loc = atY(scroll!.offset);
    move(loc.$1, loc.$2);
  }

  void move(int n, [double y = 0]) {
    final l = leaf(n);
    if (l == null || disposed || leftReader || !mounted) return;
    final lines = layout(l.ch).pages[l.pg];
    final ln =
        lines.where((x) => x.y + x.height > y).firstOrNull ?? lines.lastOrNull;
    if (ln == null) return;
    final changed = chapter != l.ch || page != l.pg;
    if (chapter != l.ch) seekPreview = null;
    chapter = l.ch;
    page = l.pg;
    paragraph = math.max(0, ln.block);
    offset = ln.start;
    if (changed) setState(() {});
    warm();
    saveTimer?.cancel();
    saveTimer = Timer(const Duration(milliseconds: 380), save);
  }

  int get stride => spread ? 2 : 1;
  void turn(int d) {
    if (loading || error != null) return;
    unlocated = false;
    if (paged && pager?.hasClients == true) {
      final now = (pager!.page ?? pageOrigin).round();
      final to = now + d;
      final n = (to - pageOrigin) * stride;
      if (leaf(n) == null && !(spread && leaf(n + 1) != null)) {
        boundary(d);
        return;
      }
      if (mode == '无动画') {
        pager!.jumpToPage(to);
      } else {
        pager!.animateToPage(
          to,
          duration: Duration(milliseconds: (pref('speed', 260) as num).round()),
          curve: Curves.easeOutCubic,
        );
      }
    } else if (scroll?.hasClients == true) {
      final pos = scroll!.position;
      final to = (pos.pixels + d * height * .92).clamp(
        pos.minScrollExtent,
        pos.maxScrollExtent,
      );
      if ((to - pos.pixels).abs() < 1) {
        boundary(d);
        return;
      }
      scroll!.animateTo(
        to,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  void boundary(int d) {
    final i = chapter + d;
    if (i < 0 || i >= toc.length) {
      stopAuto();
      message(d < 0 ? '已到全书开头' : '已到全书末尾');
    } else if (failures[i] != null) {
      message(failures[i]!);
      setState(() => failures.remove(i));
      warm();
    } else {
      warm();
    }
  }

  void stopAuto() {
    automatic?.cancel();
    automatic = null;
  }

  void auto() {
    if (automatic != null) {
      setState(stopAuto);
      return;
    }
    setState(() => menus = false);
    automatic = Timer.periodic(
      Duration(seconds: (pref('autoSeconds', 8) as num).round()),
      (_) {
        if (!modal && !menus) turn(1);
      },
    );
  }

  void tapAction(String a) {
    switch (a) {
      case '上一页':
        turn(-1);
        break;
      case '下一页':
        turn(1);
        break;
      case '菜单':
        setState(() {
          menus = !menus;
          stopAuto();
        });
        break;
      case '目录':
        contents();
        break;
      case '设置':
        settings();
        break;
      case '书签':
        mark('书签');
        break;
      case '夜间':
        change('night', !night);
    }
  }

  Widget pageBody(Leaf l, bool vertical) {
    final lines = layout(l.ch).pages[l.pg];
    final b = bodies[l.ch]!;
    final h = vertical ? leafH(l) : height;
    return SizedBox(
      height: h,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          for (final ln in lines)
            Positioned(
              top:
                  ln.y +
                  (!vertical && pref('bottom', false) && lines.isNotEmpty
                      ? (height - lines.last.y - lines.last.height).clamp(
                          0,
                          height,
                        )
                      : 0),
              left: 0,
              right: 0,
              height: ln.height,
              child: Builder(
                builder: (c) {
                  final block = ln.block < 0
                          ? <String, dynamic>{'kind': 'heading', 'text': ''}
                          : b[ln.block],
                      heading = block['kind'] == 'heading';
                  final align = heading
                      ? pref('titleAlign', '居左')
                      : pref('align', '居左');
                  final text = ln.span != null
                      ? Container(
                          padding: EdgeInsets.only(
                            left: !heading && ln.start == 0
                                ? numv('indent', 0) * size
                                : 0,
                          ),
                          alignment: align == '居中'
                              ? Alignment.center
                              : align == '居右'
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: RichText(
                            text: ln.span!,
                            softWrap: false,
                            overflow: TextOverflow.clip,
                          ),
                        )
                      : ln.image == null
                      ? const Icon(Icons.broken_image_outlined)
                      : GestureDetector(
                          onTap: () => showDialog(
                            context: context,
                            builder: (ctx) => Dialog(
                              child: InteractiveViewer(
                                maxScale: 8,
                                child: Image.memory(base64Decode(ln.image!)),
                              ),
                            ),
                          ),
                          child: Image.memory(
                            base64Decode(ln.image!),
                            fit: BoxFit.contain,
                          ),
                        );
                  return GestureDetector(
                    onSecondaryTap: ln.block < 0
                        ? null
                        : () => selection(l.ch, ln),
                    onLongPress: ln.block < 0
                        ? null
                        : () => selection(l.ch, ln),
                    child:
                        pref('bubbles', true) &&
                            block['commentCount'] != null &&
                            ln.end >= (block['text'] as String).length
                        ? Row(
                            children: [
                              Expanded(child: text),
                              ActionChip(
                                visualDensity: VisualDensity.compact,
                                label: Text('评 ${block["commentCount"]}'),
                                onPressed: () =>
                                    comments(l.ch, ln.block, block),
                              ),
                            ],
                          )
                        : text,
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget animation(int i, Widget child) {
    return AnimatedBuilder(
      animation: pager!,
      child: child,
      builder: (_, c) {
        double t = pager!.hasClients && pager!.position.hasContentDimensions
            ? (pager!.page ?? pageOrigin.toDouble()) - i
            : 0;
        t = t.clamp(-1, 1);
        final w = width * stride;
        if (mode == '淡入淡出')
          return Transform.translate(
            offset: Offset(t * w, 0),
            child: Opacity(opacity: (1 - t.abs()).clamp(0, 1), child: c),
          );
        if (mode == '覆盖' && t > 0)
          return Transform.translate(offset: Offset(t * w, 0), child: c);
        if (mode == '视差')
          return Transform.translate(offset: Offset(t * w * .36, 0), child: c);
        if (['仿真', 'iOS 卷页', 'Google 卷页'].contains(mode)) {
          return CurlPage(
            progress: t,
            variant: mode == '仿真'
                ? 0
                : mode == 'iOS 卷页'
                ? 1
                : 2,
            child: RepaintBoundary(child: c),
          );
        }
        return c!;
      },
    );
  }

  Widget readingView(BoxConstraints box) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null)
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(error!),
            TextButton(onPressed: start, child: const Text('重试')),
            if (widget.book['origin'] != 'local')
              TextButton(
                onPressed: () => guarded(changeSource),
                child: const Text('换源'),
              ),
            TextButton(
              onPressed: () => Navigator.maybePop(context),
              child: const Text('返回'),
            ),
          ],
        ),
      );
    final mx = numv('marginX', 26).clamp(0.0, box.maxWidth / 4);
    final my = numv('marginY', 14).clamp(0.0, box.maxHeight / 5);
    final header = hideSystemBars ? '书名' : pref('header', '章节') as String;
    final footer = pref('footer', '阅读进度') as String;
    final infoStyle = TextStyle(
      color: ink.withValues(alpha: .65),
      fontSize: numv('infoSize', 12),
      fontFamily: pref('infoFont', 'sans-serif'),
      height: 1.25,
    );
    final infoLine =
        MediaQuery.textScalerOf(context).scale(infoStyle.fontSize!) *
        infoStyle.height!;
    // The running header and footer share the page margins with the text.
    double inset(String field) =>
        field == '无' ? my : math.max(my, infoLine.ceilToDouble() + 8);
    final topInset = inset(header), bottomInset = inset(footer);
    final w = math.max<double>(
      28.0,
      math.min(box.maxWidth - mx * 2, spread ? 1520.0 : 820.0),
    );
    final h = box.maxHeight - topInset - bottomInset;
    if (h <= 0) return const SizedBox.shrink();
    setup(spread ? (w - 24) / 2 : w, h);
    Widget spreadPage(int i) {
      final n = (i - pageOrigin) * stride;
      final l = leaf(n), r = spread ? leaf(n + 1) : null;
      return animation(
        i,
        ColoredBox(
          color: pref('backgroundFile', '') == '' ? paper : Colors.transparent,
          child: Row(
            children: [
              Expanded(
                child: l == null ? const SizedBox() : pageBody(l, false),
              ),
              if (spread) ...[
                const SizedBox(width: 24),
                Expanded(
                  child: r == null ? const SizedBox() : pageBody(r, false),
                ),
              ],
            ],
          ),
        ),
      );
    }

    Widget v;
    if (paged) {
      final min = pageOrigin - (before.length / stride).ceil(),
          max = pageOrigin + ((after.length - 1) / stride).floor();
      v = PageView.custom(
        key: ValueKey('p$renderId'),
        controller: pager,
        physics: ReaderBounds(min, max),
        onPageChanged: (i) {
          final n = (i - pageOrigin) * stride;
          move(leaf(n) == null ? n + 1 : n);
        },
        childrenDelegate: _ReaderPageDelegate(
          (_, i) => i < min ? const SizedBox() : spreadPage(i),
          childCount: max + 1,
          viewportWidth: math.min(w, box.maxWidth),
        ),
      );
    } else {
      v = CustomScrollView(
        key: ValueKey('s$renderId'),
        controller: scroll,
        center: centerKey,
        slivers: [
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, i) => pageBody(before[i], true),
              childCount: before.length,
            ),
          ),
          SliverList(
            key: centerKey,
            delegate: SliverChildBuilderDelegate(
              (_, i) => pageBody(after[i], true),
              childCount: after.length,
            ),
          ),
        ],
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) {
        final x = (3 * d.localPosition.dx / box.maxWidth).floor().clamp(0, 2),
            y = (3 * d.localPosition.dy / box.maxHeight).floor().clamp(0, 2);
        tapAction((pref('zones', defaultZones) as List)[y * 3 + x]);
      },
      child: Column(
        children: [
          SizedBox(
            height: topInset,
            child: header == '无' ? null : info(true, header, infoStyle),
          ),
          SizedBox(
            height: h,
            width: w,
            child: NotificationListener<UserScrollNotification>(
              onNotification: (n) {
                if (n.direction != ScrollDirection.idle) unlocated = false;
                return false;
              },
              child: v,
            ),
          ),
          SizedBox(
            height: bottomInset,
            child: footer == '无' ? null : info(false, footer, infoStyle),
          ),
        ],
      ),
    );
  }

  Widget info(bool top, String format, TextStyle style) {
    final bookAndTime = top && hideSystemBars;
    final c = toc[chapter];
    final text = switch (format) {
      '书名' => widget.book['title'],
      '章节' => c['title'],
      '页码' => '${page + 1} / ${layouts[chapter]?.pages.length ?? 1}',
      '时间' => TimeOfDay.now().format(context),
      '电量' => power ?? '电量不可用',
      '阅读进度' =>
        '${chapter + 1} / ${toc.length} 章   ·   ${(((chapter + page / (layouts[chapter]?.pages.length ?? 1)) / toc.length) * 100).toStringAsFixed(1)}%',
      _ => '',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 26),
      child: DefaultTextStyle.merge(
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
        child: bookAndTime
            ? Row(
                children: [
                  Expanded(child: Text(text)),
                  const SizedBox(width: 8),
                  Text(TimeOfDay.now().format(context)),
                ],
              )
            : Align(
                alignment: top ? Alignment.centerLeft : Alignment.centerRight,
                child: Text(text),
              ),
      ),
    );
  }

  Widget pageSlider() {
    final pages = error == null ? layouts[chapter]?.pages : null;
    final lastPage = (pages?.length ?? 1) - 1;
    final value = (seekPreview ?? page.toDouble()).clamp(
      0.0,
      lastPage.toDouble(),
    );
    return Slider(
      value: value,
      max: lastPage.toDouble(),
      divisions: lastPage > 0 ? lastPage : null,
      label: '第 ${value.round() + 1} 页',
      onChanged: lastPage == 0 ? null : (v) => setState(() => seekPreview = v),
      onChangeEnd: lastPage == 0
          ? null
          : (v) {
              if (loading || pages != layouts[chapter]?.pages) return;
              final ln = pages![v.round()].firstOrNull;
              if (ln == null) return;
              setState(() {
                paragraph = math.max(0, ln.block);
                offset = ln.start;
                unlocated = false;
                seekPreview = null;
                geometry = '';
              });
              save();
            },
    );
  }

  @override
  Widget build(BuildContext context) {
    final reader = Theme(
      data: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff626484),
          brightness: night ? Brightness.dark : Brightness.light,
        ),
        useMaterial3: true,
      ),
      child: Scaffold(
        backgroundColor: paper,
        body: Listener(
          onPointerDown: (_) => _readingSession.activity(),
          onPointerMove: (_) => _readingSession.activity(),
          onPointerSignal: (_) => _readingSession.activity(),
          onPointerPanZoomUpdate: (_) => _readingSession.activity(),
          child: SafeArea(
            child: Focus(
              autofocus: true,
              onKeyEvent: (_, e) {
                if (e is! KeyDownEvent || modal) return KeyEventResult.ignored;
                _readingSession.activity();
                final k = e.logicalKey;
                if ([
                      LogicalKeyboardKey.arrowRight,
                      LogicalKeyboardKey.pageDown,
                      LogicalKeyboardKey.space,
                    ].contains(k) ||
                    k.keyId == pref('nextKey', -1)) {
                  turn(1);
                  return KeyEventResult.handled;
                }
                if ([
                      LogicalKeyboardKey.arrowLeft,
                      LogicalKeyboardKey.pageUp,
                    ].contains(k) ||
                    k.keyId == pref('prevKey', -1)) {
                  turn(-1);
                  return KeyEventResult.handled;
                }
                if (k == LogicalKeyboardKey.escape && menus) {
                  setState(() => menus = false);
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: LayoutBuilder(builder: buildViewport),
            ),
          ),
        ),
      ),
    );
    return PopScope<void>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) finishReading();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: readerSystemBars(ThemeData.estimateBrightnessForColor(paper)),
        child: reader,
      ),
    );
  }

  Widget buildViewport(BuildContext context, BoxConstraints box) {
    final bg = pref('backgroundFile', '');
    // Paginate the text before building the controls that use its page range.
    final content = readingView(box);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (bg != '')
          Image.file(
            File(bg),
            fit: BoxFit.cover,
            errorBuilder: (_, e, s) => const SizedBox(),
          ),
        content,
        if (numv('shade', 0) > 0)
          IgnorePointer(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: numv('shade', 0)),
            ),
          ),
        if (pref('eye', false))
          IgnorePointer(
            child: ColoredBox(color: Colors.amber.withValues(alpha: .10)),
          ),
        if (failures.containsKey(chapter + 1) ||
            failures.containsKey(chapter - 1))
          Align(
            alignment: Alignment.bottomCenter,
            child: TextButton.icon(
              onPressed: () {
                setState(() => failures.clear());
                warm();
              },
              icon: const Icon(Icons.refresh),
              label: const Text('邻章加载失败 · 重试'),
            ),
          ),
        if (menus && !loading) ...[
          Align(
            alignment: Alignment.topCenter,
            child: Material(
              elevation: 3,
              child: SafeArea(
                bottom: false,
                child: ListTile(
                  leading: BackButton(
                    onPressed: () => Navigator.maybePop(context),
                  ),
                  title: Text(
                    widget.book['title'],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.book['origin'] != 'local')
                        IconButton(
                          tooltip: '换源',
                          onPressed: () => guarded(changeSource),
                          icon: const Icon(Icons.swap_horiz_rounded),
                        ),
                      downloadButton(),
                      IconButton(
                        tooltip: '章节工具',
                        onPressed: toolsMenu,
                        icon: const Icon(Icons.more_vert),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Material(
              elevation: 8,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(22),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 32,
                        height: 4,
                        margin: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.grey,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      if (toc.isNotEmpty)
                        Row(
                          children: [
                            IconButton(
                              tooltip: '上一章',
                              onPressed: chapter > 0
                                  ? () => open(chapter - 1)
                                  : null,
                              icon: const Icon(Icons.skip_previous_outlined),
                            ),
                            Expanded(child: pageSlider()),
                            IconButton(
                              tooltip: '下一章',
                              onPressed: chapter + 1 < toc.length
                                  ? () => open(chapter + 1)
                                  : null,
                              icon: const Icon(Icons.skip_next_outlined),
                            ),
                          ],
                        ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          for (final a
                              in [
                                (Icons.format_list_bulleted, '目录', contents),
                                (
                                  night
                                      ? Icons.light_mode_outlined
                                      : Icons.dark_mode_outlined,
                                  night ? '日间' : '夜间',
                                  () => change('night', !night),
                                ),
                                (Icons.timer_outlined, '自动', auto),
                                (Icons.tune, '设置', settings),
                              ].where(
                                (a) =>
                                    (pref('toolbar', ['目录', '日夜', '自动', '设置'])
                                            as List)
                                        .contains(
                                          ['夜间', '日间'].contains(a.$2)
                                              ? '日夜'
                                              : a.$2,
                                        ),
                              ))
                            InkWell(
                              onTap: a.$3,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 9,
                                  vertical: 3,
                                ),
                                child: Column(
                                  children: [Icon(a.$1), Text(a.$2)],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

const defaultZones = [
  '上一页',
  '菜单',
  '下一页',
  '上一页',
  '菜单',
  '下一页',
  '上一页',
  '菜单',
  '下一页',
];

class _ReaderPageDelegate extends SliverChildBuilderDelegate {
  _ReaderPageDelegate(
    super.builder, {
    required int childCount,
    required this.viewportWidth,
  }) : super(childCount: childCount);

  final double viewportWidth;

  // Every child fills the viewport. Extrapolating its width from the
  // difference of two distant scroll offsets loses precision on fractional widths.
  @override
  double estimateMaxScrollOffset(
    int firstIndex,
    int lastIndex,
    double leadingScrollOffset,
    double trailingScrollOffset,
  ) => childCount! * viewportWidth;
}

class ReaderBounds extends PageScrollPhysics {
  final int minPage, maxPage;
  const ReaderBounds(this.minPage, this.maxPage, {super.parent});
  @override
  ReaderBounds applyTo(ScrollPhysics? ancestor) =>
      ReaderBounds(minPage, maxPage, parent: buildParent(ancestor));
  @override
  double applyBoundaryConditions(ScrollMetrics p, double value) {
    final lo = minPage * p.viewportDimension;
    if (value < lo && value < p.pixels) return value - math.min(p.pixels, lo);
    return super.applyBoundaryConditions(p, value);
  }
}
