import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:file_selector/file_selector.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

typedef Json = Map<String, dynamic>;
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

class ReaderStore {
  final Directory dir;
  final http.Client client;
  Json state;
  Future<void> _writes = Future.value();
  Future<void>? _sending;
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
      state.remove('positions');
      state.remove('tocs');
      state.remove('cacheOrder');
      state.remove('conflicts');
    }
    state['base'] = normalized;
    state['token'] = secret.trim();
    state['library'] = data;
    await persist();
  }

  Future<Json> refresh() async {
    final value = await get('library') as Json;
    state['library'] = value;
    await persist();
    return value;
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

  final _loads = <String, Future<Json>>{};
  Future<void> _cacheWrite = Future.value();
  Future<Json> chapter(String book, String id) => _loads.putIfAbsent(
    '$book/$id',
    () => _chapter(book, id).whenComplete(() {
      _loads.remove('$book/$id');
    }),
  );
  Future<void> touch(String id) =>
      _cacheWrite = _cacheWrite.catchError((_) {}).then((_) async {
        final order = List<String>.from(state['cacheOrder'] ?? []);
        order.remove(id);
        order.add(id);
        while (order.length > 30) {
          final f = File('${cache.path}/${order.removeAt(0)}.json');
          if (await f.exists()) await f.delete();
        }
        state['cacheOrder'] = order;
        await persist();
      });
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

  Future<void> forgetChapter(String id) async {
    final f = File('${cache.path}/$id.json');
    if (await f.exists()) await f.delete();
  }

  Future<Json> _chapter(String book, String id) async {
    await cache.create(recursive: true);
    final file = File('${cache.path}/$id.json');
    if (await file.exists()) {
      final item = jsonDecode(await file.readAsString()) as Json;
      await touch(id);
      return item;
    }
    final item = await get('books/$book/chapters/$id') as Json;
    for (final block in item['blocks']) {
      if (block['image'] == null) continue;
      final response = await client
          .get(uri('books/$book/assets/${block['image']}'), headers: headers)
          .timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) throw StateError('插图加载失败，请重试');
      block['bytes'] = base64Encode(response.bodyBytes);
    }
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(item), flush: true);
    await temp.rename(file.path);
    await touch(id);
    return item;
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
    try {
      final remote = await get('books/$book/progress');
      if (remote is Map) {
        map('positions')[book] = remote;
        await persist();
      }
    } on SocketException {
    } on http.ClientException {
    } on TimeoutException {}
    return map('positions')[book];
  }

  Future<void> remember(
    String book,
    String chapter,
    int paragraph,
    int offset,
    String quote,
  ) async {
    final previous = map('pending')[book] ?? map('positions')[book];
    if (previous != null &&
        previous['chapterId'] == chapter &&
        previous['paragraph'] == paragraph &&
        previous['offset'] == offset)
      return;
    map('pending')[book] = {
      'chapterId': chapter,
      'paragraph': paragraph,
      'offset': offset,
      'quote': quote,
      'version': previous?['version'] ?? 0,
      'eventId': eventId(),
    };
    await persist();
  }

  Future<void> flush() => _sending ??= _flush().whenComplete(() {
    _sending = null;
  });
  Future<void> _flush() async {
    for (final book in map('pending').keys.toList()) {
      if (map('conflicts').containsKey(book)) continue;
      final item = Map<String, dynamic>.from(map('pending')[book]);
      try {
        final ack = await send('PUT', 'books/$book/progress', item);
        map('positions')[book] = {...item, 'version': ack['version']};
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
        } else if (e.status == 404) {
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
