part of 'store.dart';

String bareBookTitle(String? text) {
  final title = (text ?? '').trim();
  return title.startsWith('《') && title.endsWith('》')
      ? title.substring(1, title.length - 1).trim()
      : title;
}

String bookTitleKey(String? text) =>
    bareBookTitle(text).replaceAll(_titleSpace, '').toLowerCase();

String bookAuthorKey(String? text) => (text ?? '')
    .replaceAll(_titleSpace, '')
    .toLowerCase()
    .replaceFirst(RegExp(r'^作者[：:]'), '');

typedef _NovelKey = (String, String);

class BookLibrary {
  final Json _data;
  final List<Json> shelf;
  final List<Json> _past;
  final Map<String, Json> _books = {};
  final Map<String, Set<String>> _authors = {};
  final Map<String, Json> indicators;
  late final _recent = _recentVisits();
  late final List<Json> history = List.unmodifiable(_recent.values);

  BookLibrary(this._data, {Json? candidate})
    : shelf = rows(_data['shelf']),
      _past = rows(_data['history']),
      indicators = {for (final v in rows(_data['indicators'])) v['id']: v} {
    for (final book in [...shelf, ..._past, ?candidate]) {
      _books[book['id']] = book;
    }
    for (final book in _books.values) {
      final author = _knownAuthor(book);
      if (author.isNotEmpty) {
        (_authors[bookTitleKey(book['title'])] ??= {}).add(author);
      }
    }
  }

  String _knownAuthor(Json book) {
    final author = bookAuthorKey(book['author']);
    return const {'未知', '未知作者', '作者不详', '佚名'}.contains(author) ? '' : author;
  }

  _NovelKey _key(Json edition) {
    final book = _books[edition['id']] ?? edition;
    final title = bookTitleKey(book['title']);
    final author = _knownAuthor(book);
    if (title.isNotEmpty) {
      if (author.isNotEmpty) return (title, author);
      final authors = _authors[title];
      if (authors == null) return (title, '');
      if (authors.length == 1) return (title, authors.single);
    }
    return ('', book['id'] as String);
  }

  Json? edition(String id) => _books[id];
  Json bookForVisit(Json entry) =>
      _books[entry['book']] ?? {'id': entry['book'], 'title': entry['title']};

  Iterable<Json> shelfEditions(Json book) {
    final key = _key(book);
    return shelf.where((edition) => _key(edition) == key);
  }

  Map<_NovelKey, Json> _recentVisits() {
    int stamp(Json row) => row['last'] ?? 0;
    final visits = rows(_data['activity']);
    final recorded = <String, int>{};
    for (final row in visits) {
      final id = row['book'] as String;
      recorded[id] = max(recorded[id] ?? 0, stamp(row));
    }
    for (final b in _past) {
      final id = b['id'] as String;
      final progress = indicators[id];
      final saved = progress?['stamp'] as int?;
      final last = recorded[id];
      if (last != null && (saved == null || saved <= last)) continue;
      visits.add({
        'book': id,
        'title': b['title'],
        'last': saved ?? b['updated'] ?? 0,
        'chapterId': progress?['chapterId'],
        'chapter': progress?['current'],
      });
    }
    mergeSort(visits, compare: (a, b) => stamp(b).compareTo(stamp(a)));
    final recent = <_NovelKey, Json>{};
    for (final visit in visits) {
      final key = _key(bookForVisit(visit));
      recent.putIfAbsent(key, () => visit);
    }
    return recent;
  }

  List<Json> shelfBooks({bool localOnly = false, Set<String>? members}) {
    final first = <_NovelKey, Json>{};
    final included = <_NovelKey>{};
    final eligibleIds = <String>{};
    for (final b in shelf) {
      if (localOnly && b['origin'] != 'local') continue;
      eligibleIds.add(b['id']);
      final key = _key(b);
      first.putIfAbsent(key, () => b);
      if (members == null || members.contains(b['id'])) included.add(key);
    }
    final ranked = <({Json book, int stamp})>[];
    for (final key in first.keys.where(included.contains)) {
      final b = first[key]!;
      final visit = _recent[key];
      final latest = visit == null ? null : edition(visit['book']);
      final useLatest =
          latest != null && (!localOnly || eligibleIds.contains(latest['id']));
      final stamp = b['updated'] as int? ?? 0;
      final visitStamp = visit?['last'] as int? ?? 0;
      ranked.add((
        book: useLatest ? latest : b,
        stamp: useLatest ? max(stamp, visitStamp) : stamp,
      ));
    }
    mergeSort(ranked, compare: (a, b) => b.stamp.compareTo(a.stamp));
    return [for (final row in ranked) row.book];
  }

  Json progressFor(Json book) {
    final visit = _recent[_key(book)];
    return {
      ...?indicators[book['id']],
      if (visit?['book'] == book['id'] && visit?['chapter'] != null)
        'current': visit!['chapter'],
    };
  }
}
