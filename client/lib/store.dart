import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart'
    show ChangeNotifier, ValueListenable, ValueNotifier, mergeSort;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

part 'book_library.dart';
part 'reading_time_store.dart';

typedef Json = Map<String, dynamic>;
bool searchableSource(Json source) =>
    source['enabled'] == 1 && source['issue'] == '';

String _chapterName(Json chapter) => (chapter['title'] as String).trim();

final _chapterPrefix = RegExp(
  r'^第([0-9零〇一二两兩三四五六七八九十百千万萬]+)([章回节節卷])[:：、.．-]*',
);
final _titleSpace = RegExp(r'\s+');
final _wideDigits = RegExp(r'[０-９]');

String chapterTitleKey(String title) {
  final compact = title
      .toLowerCase()
      .replaceAll(_titleSpace, '')
      .replaceAllMapped(
        _wideDigits,
        (m) => String.fromCharCode(m[0]!.codeUnitAt(0) - 0xff10 + 0x30),
      );
  return compact.replaceFirstMapped(_chapterPrefix, (match) {
    final ordinal = match[1]!
        .replaceAll('〇', '零')
        .replaceAll('两', '二')
        .replaceAll('兩', '二');
    const units = {'十': 10, '百': 100, '千': 1000};
    var total = 0, group = 0, digits = 0;
    for (final char in ordinal.split('')) {
      if (char == '万' || char == '萬') {
        total += (group + digits) * 10000;
        group = digits = 0;
      } else if (units.containsKey(char)) {
        group += (digits == 0 ? 1 : digits) * units[char]!;
        digits = 0;
      } else {
        digits =
            digits * 10 + (int.tryParse(char) ?? '零一二三四五六七八九'.indexOf(char));
      }
    }
    return '第${total + group + digits}${match[2] == '節' ? '节' : match[2]}';
  });
}

Map<String, String?> _uniqueOriginalIds(
  List<Json> original,
  List<Json> chapters,
  String Function(Json) key,
) {
  final ids = <String, String?>{};
  for (final ch in original) {
    ids.update(key(ch), (_) => null, ifAbsent: () => ch['id'] as String);
  }
  final seen = <String>{};
  for (final ch in chapters) {
    final name = key(ch);
    if (!seen.add(name)) ids.remove(name);
  }
  return ids;
}

List<Json> rows(dynamic data) => (data as List? ?? [])
    .map((v) => Map<String, dynamic>.from(v as Map))
    .toList();

class ApiError implements Exception {
  final int status;
  final String message;
  final dynamic data;
  ApiError(this.status, this.message, this.data);
  @override
  String toString() => message;
}

enum AppThemeMode {
  system('跟随系统'),
  light('亮色'),
  dark('暗色');

  const AppThemeMode(this.label);
  final String label;
}

class BookDownload extends ChangeNotifier {
  BookDownload._(this.title, this.total);

  final String title;
  final int total;
  int _saved = 0, _failed = 0;
  bool _running = true, _stopping = false;
  String? _error;

  int get saved => _saved;
  int get failed => _failed;
  bool get running => _running;
  bool get stopping => _stopping;
  String? get error => _error;

  void stop() {
    if (!running || stopping) return;
    _stopping = true;
    notifyListeners();
  }

  void _update({int saved = 0, Object? error, String? interruption}) {
    _saved += saved;
    if (error != null) _failed++;
    _error = interruption ?? _error ?? error?.toString();
    if (interruption != null) _stopping = true;
    notifyListeners();
  }

  void _finish() {
    _running = false;
    notifyListeners();
  }
}

typedef _ChapterKey = ({String server, String book, String id});

class ReaderStore {
  final Directory dir;
  final http.Client client;
  Json state;
  Future<void> _writes = Future.value();
  Future<void>? _sending;
  final _readingUploads = <String, Future<void>>{};
  late final _appTheme = ValueNotifier(
    AppThemeMode.values
            .where((mode) => mode.name == state['appTheme'])
            .firstOrNull ??
        AppThemeMode.system,
  );
  ValueListenable<AppThemeMode> get appTheme => _appTheme;

  Future<void> setAppTheme(AppThemeMode mode) async {
    state['appTheme'] = mode.name;
    _appTheme.value = mode;
    await persist();
  }

  int _libraryRevision = 0;
  BookLibrary? _books;
  BookLibrary get books {
    final data = state['library'] as Json? ?? const <String, dynamic>{};
    if (!identical(_books?._data, data)) _books = BookLibrary(data);
    return _books!;
  }

  ReaderStore(this.dir, this.state, {http.Client? client})
    : client = client ?? http.Client();
  static Future<ReaderStore> open([String? override]) async {
    final root = Directory(
      override ??
          Platform.environment['NOVEL_PROFILE'] ??
          (await getApplicationSupportDirectory()).path,
    );
    await root.create(recursive: true);
    final file = File('${root.path}/profile.json');
    Json state = {};
    for (final f in [file, File('${file.path}.old')]) {
      if (await f.exists()) {
        try {
          state = jsonDecode(await f.readAsString()) as Json;
          break;
        } on FormatException {
          continue;
        }
      }
    }
    final store = ReaderStore(root, state);
    if (store.token.isEmpty && Platform.isWindows) {
      final key = File(
        '${File(Platform.resolvedExecutable).parent.parent.path}/server/data/access-token.txt',
      );
      if (await key.exists()) {
        state['token'] = (await key.readAsString()).trim();
        await store.persist();
      }
    }
    return store;
  }

  String get base => state['base'] ?? 'http://127.0.0.1:7186';
  String get token => state['token'] ?? '';
  Json map(String key) =>
      state.putIfAbsent(key, () => <String, dynamic>{}) as Json;
  String get namespace =>
      base64Url.encode(utf8.encode(base)).replaceAll('=', '');
  Directory get cache => Directory('${dir.path}/chapters/$namespace');
  final _coverRequests = <String, Future<File?>>{};
  final _missingCovers = <String, DateTime>{};

  Future<File?> coverFile(Json book) {
    if (book['origin'] == 'local' && book['url'] != '.epub') {
      return Future.value(null);
    }
    final id = book['id'] as String;
    final key = '$namespace/$id';
    return _coverRequests.putIfAbsent(
      key,
      () => _loadCover(id, key, book['cover'] ?? '').whenComplete(() {
        _coverRequests.remove(key);
      }),
    );
  }

  Future<File?> _loadCover(String id, String key, String source) async {
    if (!RegExp(r'^[a-f0-9]{32,64}$').hasMatch(id)) return null;
    final folder = Directory('${dir.path}/covers/$namespace');
    final file = File('${folder.path}/$id.img');
    final origin = File('${folder.path}/$id.source');
    final exists = await file.exists();
    if (exists &&
        (source.isEmpty ||
            await origin.exists() && await origin.readAsString() == source))
      return file;
    final retryKey = '$key/$source';
    if ((_missingCovers[retryKey]?.isAfter(DateTime.now()) ?? false))
      return exists ? file : null;
    try {
      final response = await client
          .get(uri('books/$id/cover'), headers: headers)
          .timeout(const Duration(seconds: 42));
      if (response.statusCode == 200 &&
          response.bodyBytes.isNotEmpty &&
          (response.headers['content-type'] ?? '').startsWith('image/')) {
        await folder.create(recursive: true);
        final temp = File('${file.path}.${eventId()}.tmp');
        try {
          await temp.writeAsBytes(response.bodyBytes, flush: true);
          await temp.rename(file.path);
        } finally {
          if (await temp.exists()) await temp.delete();
        }
        await origin.writeAsString(source);
        return file;
      }
    } on IOException {
      // A previously downloaded cover is also available offline.
    } on TimeoutException {
    } on http.ClientException {}
    _missingCovers[retryKey] = DateTime.now().add(const Duration(minutes: 2));
    return exists ? file : null;
  }

  Future<void> persist() {
    final snapshot = jsonEncode(state);
    return _writes = _writes.catchError((_) {}).then((_) async {
      final file = File('${dir.path}/profile.json'),
          temp = File('${file.path}.tmp'),
          backup = File('${file.path}.old');
      await temp.writeAsString(snapshot, flush: true);
      if (await file.exists()) {
        if (await backup.exists()) await backup.delete();
        await file.rename(backup.path);
      }
      await temp.rename(file.path);
    });
  }

  Map<String, String> get headers => {'Authorization': 'Bearer $token'};
  Uri uri(String route, [Map<String, String>? query]) =>
      Uri.parse('$base/api/$route').replace(queryParameters: query);
  dynamic decode(http.Response response) {
    final raw = utf8.decode(response.bodyBytes);
    dynamic result;
    if (raw.isNotEmpty) {
      try {
        result = jsonDecode(raw);
      } catch (_) {
        result = raw;
      }
    }
    if (response.statusCode >= 400)
      throw ApiError(
        response.statusCode,
        result is Map
            ? result['error'] ?? '阅读位置已在另一台设备更新'
            : '请求失败 ${response.statusCode}',
        result,
      );
    return result;
  }

  Future<dynamic> get(String route, [Map<String, String>? query]) async =>
      decode(
        await client
            .get(uri(route, query), headers: headers)
            .timeout(
              Duration(
                seconds:
                    route.endsWith('/progress') ||
                        route == 'library' ||
                        route.startsWith('items/')
                    ? 4
                    : 100,
              ),
            ),
      );
  Future<dynamic> send(String method, String route, [Json? data]) async {
    final request = http.Request(method, uri(route))
      ..headers.addAll({
        ...headers,
        'Content-Type': 'application/json; charset=utf-8',
      })
      ..body = jsonEncode(data ?? {});
    return decode(
      await http.Response.fromStream(
        await client
            .send(request)
            .timeout(Duration(seconds: route.endsWith('/progress') ? 4 : 100)),
      ),
    );
  }

  Future<void> searchSources(
    String query,
    List<Json> sources, {
    required bool Function() active,
    required void Function(Json source, List<Json> books, Object? error)
    onSource,
  }) async {
    var next = 0;
    Future<void> worker() async {
      while (active() && next < sources.length) {
        final source = sources[next++];
        List<Json> books = [];
        Object? error;
        try {
          books = rows(
            await get('search', {'source': source['id'], 'q': query}),
          );
        } catch (e) {
          error = e;
        }
        if (active()) onSource(source, books, error);
      }
    }

    const maxConcurrentSources = 12;
    await Future.wait(
      List.generate(
        sources.length.clamp(0, maxConcurrentSources),
        (_) => worker(),
      ),
    );
  }

  Future<void> connect(String address, String secret) async {
    final normalized = address.trim().replaceFirst(RegExp(r'/+$'), '');
    final u = Uri.tryParse(normalized);
    if (u == null || !u.hasAuthority || !['http', 'https'].contains(u.scheme))
      throw const FormatException('请输入完整的 HTTP 或 HTTPS 地址');
    final response = await client
        .get(
          Uri.parse('$normalized/api/library'),
          headers: {'Authorization': 'Bearer ${secret.trim()}'},
        )
        .timeout(const Duration(seconds: 8));
    final data = decode(response);
    if (normalized != base) {
      if (map('pending').isNotEmpty)
        throw StateError('有尚未同步的阅读位置，请先完成同步后切换服务。');
      _activeDownload.value?.stop();
      state.remove('positions');
      state.remove('tocs');
      state.remove('cacheOrder');
      state.remove('conflicts');
    }
    state['base'] = normalized;
    state['token'] = secret.trim();
    _libraryRevision++;
    state['library'] = data;
    await persist();
  }

  Future<Json> refresh({bool withActivity = false}) async {
    final revision = ++_libraryRevision;
    await flush();
    final data = await Future.wait([
      get('library'),
      if (withActivity) get('activity'),
    ], eagerError: true);
    if (revision != _libraryRevision) return state['library'] ?? data.first;
    final library = Map<String, dynamic>.from(data.first as Map);
    library['activity'] = withActivity
        ? data[1]
        : state['library']?['activity'] ?? [];
    for (final item in map('pending').values) {
      if (item['visit'] != null) _applyVisit(library, item);
    }
    state['library'] = library;
    await persist();
    return library;
  }

  Iterable<Json> shelfEditions(Json book) {
    final library = books;
    final cached = library.edition(book['id']);
    if (cached != null &&
        cached['title'] == book['title'] &&
        cached['author'] == book['author']) {
      return library.shelfEditions(book);
    }
    return BookLibrary(library._data, candidate: book).shelfEditions(book);
  }

  Future<void> setShelved(Json book, bool value) async {
    final ids = <String>{
      if (!value) ...shelfEditions(book).map((b) => b['id'] as String),
      if (value || book['shelf'] == 1) book['id'],
    };
    final changed = <String>{};
    try {
      for (final id in ids) {
        await send('PUT', 'books/$id/shelf', {'shelf': value});
        changed.add(id);
      }
    } finally {
      if (changed.isNotEmpty) {
        _libraryRevision++;
        final library = Map<String, dynamic>.of(state['library'] ?? {});
        library['shelf'] = [
          if (value) {...book, 'shelf': 1},
          ...rows(library['shelf']).where((b) => !changed.contains(b['id'])),
        ];
        library['history'] = [
          for (final b in rows(library['history']))
            if (changed.contains(b['id']))
              {...b, 'shelf': value ? 1 : 0}
            else
              b,
        ];
        state['library'] = library;
        await persist();
      }
    }
  }

  void _applyVisit(Json library, Json item) {
    final visit = item['visit'] as Json, book = visit['book'] as Json;
    final id = book['id'], chapter = item['chapterId'];
    final stamp = visit['stamp'] as int;
    final day = DateTime.fromMillisecondsSinceEpoch(
      stamp,
    ).toIso8601String().split('T').first;

    List<Json> insertByTime(Iterable<Json> others, Json entry, String timeKey) {
      final list = others.toList();
      final index = list.indexWhere((row) => (row[timeKey] ?? 0) <= stamp);
      list.insert(index < 0 ? list.length : index, entry);
      return list;
    }

    final shelf = rows(library['shelf']);
    final index = shelf.indexWhere((b) => b['id'] == id);
    if (index >= 0) {
      final shelfBook = shelf.removeAt(index);
      library['shelf'] = insertByTime(shelf, {
        ...shelfBook,
        'updated': stamp,
      }, 'updated');
    }
    library['history'] = insertByTime(
      rows(library['history']).where((b) => b['id'] != id),
      {...book, 'updated': stamp},
      'updated',
    );
    library['indicators'] = [
      {
        'id': id,
        'stamp': stamp,
        'chapterId': chapter,
        'current': visit['current'],
        'ord': visit['ord'],
        'total': visit['total'],
        'latest': visit['latest'],
      },
      ...rows(library['indicators']).where((row) => row['id'] != id),
    ];
    library['activity'] = insertByTime(
      rows(library['activity']).where(
        (row) =>
            row['book'] != id ||
            row['chapterId'] != chapter ||
            row['day'] != day,
      ),
      {
        'book': id,
        'title': book['title'],
        'chapter': visit['current'],
        'chapterId': chapter,
        'day': day,
        'last': stamp,
      },
      'last',
    ).take(2000).toList();
  }

  Future<Json> upload(XFile file, String encoding) async {
    final request = http.MultipartRequest('POST', uri('upload'))
      ..headers.addAll(headers)
      ..fields['encoding'] = encoding;
    request.files.add(
      http.MultipartFile(
        'file',
        file.openRead(),
        await file.length(),
        filename: file.name,
      ),
    );
    return decode(
          await http.Response.fromStream(
            await client.send(request).timeout(const Duration(minutes: 4)),
          ),
        )
        as Json;
  }

  Future<List<Json>> toc(String book, {bool force = false}) async {
    final cached = map('tocs')[book];
    if (cached != null && !force) return rows(cached);
    final list = await get(
      'books/$book/toc',
      force ? {'refresh': 'true'} : null,
    );
    map('tocs')[book] = list;
    await persist();
    return rows(list);
  }

  Future<Json?> bookSourceMapping(String book) async =>
      (await items('mapping', book))
          .where(
            (item) => item['chapter'] == '*' && item['targetBook'] is String,
          )
          .firstOrNull;

  Future<void> setBookSource(Json mapping) async {
    await putItem('mapping', mapping);
    final key = '$namespace/mapping/${mapping['book']}';
    final cached = rows(map('items')[key]);
    map('items')[key] = [
      mapping,
      ...cached.where((item) => item['chapter'] != '*'),
    ];
    await persist();
  }

  Future<List<Json>> readingToc(
    String book,
    Json? mapping, {
    bool force = false,
  }) async {
    final target = mapping?['targetBook'] as String?;
    if (target == null || target == book) return toc(book, force: force);
    final chapters = await toc(target, force: force);
    List<Json> original;
    try {
      original = await toc(book);
    } catch (_) {
      // The selected source can still be read if the original catalog is unavailable.
      original = [];
    }
    final exact = _uniqueOriginalIds(original, chapters, _chapterName);
    final equivalent = _uniqueOriginalIds(
      original,
      chapters,
      (ch) => chapterTitleKey(ch['title']),
    );
    return chapters.map((ch) {
      final id = exact[_chapterName(ch)];
      final alias = id == null
          ? equivalent[chapterTitleKey(ch['title'])]
          : null;
      // Keep both editions' existing IDs addressable when their headings differ.
      return {
        ...ch,
        'sourceChapter': ch['id'],
        'id': id ?? ch['id'],
        if (alias != null) 'originalChapter': alias,
      };
    }).toList();
  }

  Future<List<Json>> items(String kind, [String? book]) async {
    final k = '$namespace/$kind/${book ?? ""}';
    try {
      final data = await get(
        'items/$kind',
        book == null ? null : {'book': book},
      );
      map('items')[k] = data;
      await persist();
      return rows(data);
    } on SocketException {
      return rows(map('items')[k]);
    } on TimeoutException {
      return rows(map('items')[k]);
    } on http.ClientException {
      return rows(map('items')[k]);
    }
  }

  Future<void> putItem(String kind, Json item) async {
    await send('PUT', 'items/$kind/${item["id"]}', item);
  }

  final _loads = <_ChapterKey, Future<Json>>{};
  Future<void> _cacheWrite = Future.value();
  final _activeDownload = ValueNotifier<BookDownload?>(null);
  ValueListenable<BookDownload?> get activeDownload => _activeDownload;

  _ChapterKey _chapterKey(String book, String id) =>
      (server: namespace, book: book, id: id);

  File _recentChapter(String server, String id) =>
      File('${dir.path}/chapters/$server/$id.json');

  File _downloadedChapter(_ChapterKey key) {
    final book = Uri.encodeComponent(key.book);
    final id = Uri.encodeComponent(key.id);
    return File('${dir.path}/downloads/${key.server}/book-$book/$id.json');
  }

  Future<Json?> _readChapterFile(File file) async {
    try {
      final item = jsonDecode(await file.readAsString());
      if (item is Json && item['blocks'] is List && item['blocks'].isNotEmpty) {
        return item;
      }
    } on PathNotFoundException {
      return null;
    } on FormatException {
      return null;
    }
    return null;
  }

  Future<void> _writeChapterFile(File file, Json item) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    try {
      await temp.writeAsString(jsonEncode(item), flush: true);
      await temp.rename(file.path);
    } on FileSystemException {
      try {
        await temp.delete();
      } on FileSystemException {
        // A later attempt can reuse the temporary path.
      }
      rethrow;
    }
  }

  Future<void> _saveRecent(_ChapterKey key, Json item, {required bool write}) =>
      _cacheWrite = _cacheWrite.catchError((_) {}).then((_) async {
        if (namespace != key.server) return;
        final file = _recentChapter(key.server, key.id);
        if (write || !await file.exists()) await _writeChapterFile(file, item);
        if (namespace != key.server) return;
        final order = List<String>.from(state['cacheOrder'] ?? [])
          ..remove(key.id)
          ..add(key.id);
        while (order.length > 30) {
          final old = _recentChapter(key.server, order.removeAt(0));
          if (await old.exists()) await old.delete();
        }
        if (namespace != key.server) return;
        state['cacheOrder'] = order;
        await persist();
      });

  Future<Json?> cachedChapter(String book, String id) async {
    final key = _chapterKey(book, id);
    return await _readChapterFile(_downloadedChapter(key)) ??
        await _readChapterFile(_recentChapter(key.server, id));
  }

  Future<Json> chapter(String book, String id) =>
      _loadChapter(_chapterKey(book, id));

  Future<Json> refreshChapter(String book, String id) =>
      _loadChapter(_chapterKey(book, id), refresh: true);

  Future<Json> _loadChapter(
    _ChapterKey key, {
    bool download = false,
    bool refresh = false,
  }) {
    final previous = _loads[key];
    if (!download && !refresh && previous != null) return previous;

    Future<Json> load() async {
      Json? shared;
      if (previous != null) {
        if (refresh) {
          try {
            await previous;
          } catch (_) {
            // Refresh still makes a new request if the earlier load failed.
          }
        } else {
          shared = await previous;
        }
      }
      final downloaded = _downloadedChapter(key);
      Json? cached;
      if (!refresh) {
        if (shared == null) {
          final saved = await _readChapterFile(downloaded);
          if (saved != null) return saved;
        }
        cached =
            shared ??
            await _readChapterFile(_recentChapter(key.server, key.id));
      }
      final item = cached ?? await _fetchChapter(key);
      if (download || (refresh && await downloaded.exists())) {
        await _writeChapterFile(downloaded, item);
      } else {
        await _saveRecent(key, item, write: cached == null);
      }
      return item;
    }

    // A download can save an in-flight read. Refresh runs after either so an
    // earlier body cannot overwrite a freshly fetched chapter.
    late final Future<Json> pending;
    pending = load().whenComplete(() {
      if (identical(_loads[key], pending)) _loads.remove(key);
    });
    return _loads[key] = pending;
  }

  Future<Json> _fetchChapter(_ChapterKey key) async {
    void checkServer() {
      if (key.server != namespace) throw StateError('服务连接已切换');
    }

    checkServer();
    final item = await get('books/${key.book}/chapters/${key.id}') as Json;
    final blocks = item['blocks'];
    if (blocks is! List || blocks.isEmpty) throw StateError('正文为空');
    for (final block in blocks) {
      if (block['image'] == null) continue;
      checkServer();
      final response = await client
          .get(
            uri('books/${key.book}/assets/${block['image']}'),
            headers: headers,
          )
          .timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) throw StateError('插图加载失败，请重试');
      block['bytes'] = base64Encode(response.bodyBytes);
    }
    return item;
  }

  String? _downloadInterruption(Object error) => switch (error) {
    SocketException() || http.ClientException() => '无法连接服务，请检查网络',
    TimeoutException() => '请求超时',
    FileSystemException() => '无法读写本机下载文件，请检查存储空间',
    ApiError(status: 401 || 403) => '服务验证失败，请检查连接设置',
    _ => null,
  };

  Future<BookDownload> downloadBook(
    String book,
    String title,
    Iterable<String> chapterIds,
  ) async {
    if (_activeDownload.value != null) throw StateError('已有下载任务');
    final ids = chapterIds.toSet();
    if (ids.isEmpty) throw StateError('目录为空');
    final server = namespace;
    final job = BookDownload._(title, ids.length);
    _activeDownload.value = job;
    try {
      final missing = <_ChapterKey>[];
      for (final id in ids) {
        final key = (server: server, book: book, id: id);
        if (!await _downloadedChapter(key).exists()) missing.add(key);
      }
      job._update(saved: ids.length - missing.length);
      var next = 0;
      Future<void> worker() async {
        while (!job.stopping && next < missing.length) {
          final key = missing[next++];
          try {
            await _loadChapter(key, download: true);
            job._update(saved: 1);
          } catch (e) {
            job._update(error: e, interruption: _downloadInterruption(e));
          }
        }
      }

      const maxConcurrentChapters = 2;
      await Future.wait(
        List.generate(
          min(maxConcurrentChapters, missing.length),
          (_) => worker(),
        ),
      );
    } on FileSystemException catch (e) {
      job._update(interruption: _downloadInterruption(e));
    } finally {
      job._finish();
      _activeDownload.value = null;
    }
    return job;
  }

  static String eventId() {
    final r = Random.secure();
    String hex(int count) =>
        List.generate(count, (_) => r.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-a${hex(3)}-${hex(12)}';
  }

  Future<Json?> position(String book) async {
    if (map('pending').containsKey(book)) await flush();
    if (map('pending').containsKey(book)) return map('pending')[book];
    final previous = map('positions')[book];
    try {
      final remote = await get('books/$book/progress');
      final current = map('positions')[book];
      if (remote is Map &&
          !map('pending').containsKey(book) &&
          (identical(previous, current) ||
              (remote['version'] ?? 0) > (current?['version'] ?? 0))) {
        map('positions')[book] = remote;
        await persist();
      }
    } on SocketException {
    } on http.ClientException {
    } on TimeoutException {}
    return map('pending')[book] ?? map('positions')[book];
  }

  Future<void> remember(
    String book,
    String chapter,
    int paragraph,
    int offset,
    String quote, {
    Json? visit,
  }) async {
    final pending = map('pending')[book];
    final previous = pending ?? map('positions')[book];
    final same =
        previous != null &&
        previous['chapterId'] == chapter &&
        previous['paragraph'] == paragraph &&
        previous['offset'] == offset;
    if (same && visit == null) return;
    final item = same && pending != null
        ? Map<String, dynamic>.from(pending)
        : <String, dynamic>{
            'chapterId': chapter,
            'paragraph': paragraph,
            'offset': offset,
            'quote': quote,
            'version': previous?['version'] ?? 0,
            'eventId': eventId(),
          };
    if (visit != null) {
      item['visit'] = {
        ...visit,
        'stamp': DateTime.now().millisecondsSinceEpoch,
      };
      _libraryRevision++;
      final library = Map<String, dynamic>.of(state['library'] ?? {});
      _applyVisit(library, item);
      state['library'] = library;
    }
    map('pending')[book] = item;
    await persist();
  }

  Future<void> flush() => _sending ??= _flush().whenComplete(() {
    _sending = null;
  });

  Future<Json?> _sendPosition(String book, Json item) async {
    try {
      return await send(
        'PUT',
        'books/$book/progress',
        {...item}..remove('visit'),
      );
    } on ApiError catch (e) {
      if (e.status != 404) rethrow;
      // A removed chapter can still be matched locally after a source change.
      // Only a 404 for the book itself should discard its pending progress.
      await get('books/$book').timeout(const Duration(seconds: 4));
      return null;
    }
  }

  Future<void> _flush() async {
    // A reader can queue its final position while an earlier PUT is in flight.
    final attempted = <String?>{};
    while (true) {
      final batch = map('pending').entries
          .where(
            (entry) =>
                !map('conflicts').containsKey(entry.key) &&
                !attempted.contains(entry.value['eventId']),
          )
          .toList();
      if (batch.isEmpty) return;
      for (final entry in batch) {
        final book = entry.key;
        final item = Map<String, dynamic>.from(entry.value);
        if (map('pending')[book]?['eventId'] != item['eventId']) continue;
        attempted.add(item['eventId']);
        try {
          await _writes;
          final ack = await _sendPosition(book, item);
          if (ack == null) continue;
          map('positions')[book] = {...item, 'version': ack['version']}
            ..remove('visit');
          final newer = map('pending')[book];
          if (newer?['eventId'] == item['eventId']) {
            map('pending').remove(book);
          } else if (newer != null) {
            newer['version'] = ack['version'];
          }
          await persist();
        } on ApiError catch (e) {
          if (e.status == 409) {
            map('conflicts')[book] = e.data;
            await persist();
          } else if (e.status == 404 &&
              map('pending')[book]?['eventId'] == item['eventId']) {
            map('pending').remove(book);
            await persist();
          }
        } on SocketException {
          return;
        } on http.ClientException {
          return;
        } on TimeoutException {
          return;
        }
      }
    }
  }

  Future<void> resolve(String book, bool useLocal) async {
    final remote = map('conflicts').remove(book);
    if (remote == null) return;
    map('positions')[book] = remote;
    if (useLocal) {
      final pending = map('pending')[book];
      pending['version'] = remote['version'];
      pending['eventId'] = eventId();
    } else {
      map('pending').remove(book);
    }
    await persist();
    if (useLocal) await flush();
  }
}
