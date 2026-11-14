import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader/reader.dart';

void main() {
  test('文字锚点在不同页面宽度和字号下都能定位', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final blocks = [
      {'text': '春风吹过山岗。' * 300, 'kind': 'p'},
    ];
    for (final width in [300.0, 700.0]) {
      final layout = LayoutPages(
        blocks,
        width,
        360,
        width == 300 ? 24 : 18,
        1.6,
        Colors.black,
      );
      final page = layout.pageFor(0, 500);
      expect(
        layout.pages[page].any((l) => l.start <= 500 && l.end > 500),
        isTrue,
      );
    }
  });
}
