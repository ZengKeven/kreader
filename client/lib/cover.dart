import 'dart:io';
import 'package:flutter/material.dart';
import 'store.dart';

class BookCover extends StatefulWidget {
  final ReaderStore store;
  final Json book;
  final double width, height;
  const BookCover(
    this.store,
    this.book, {
    super.key,
    this.width = 40,
    this.height = 54,
  });

  @override
  State<BookCover> createState() => _BookCoverState();
}

class _BookCoverState extends State<BookCover> {
  late Future<File?> image;
  late (String, String, String, String) identity;
  void load() {
    identity = (
      widget.store.namespace,
      widget.book['id'],
      widget.book['cover'] ?? '',
      widget.book['url'] ?? '',
    );
    image = widget.store.coverFile(widget.book);
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(BookCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store ||
        identity !=
            (
              widget.store.namespace,
              widget.book['id'],
              widget.book['cover'] ?? '',
              widget.book['url'] ?? '',
            ))
      load();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.book['title'] as String;
    final fallback = Stack(
      fit: StackFit.expand,
      children: [
        Image.asset('assets/cover-landscape.jpg', fit: BoxFit.cover),
        Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              widget.width * .09,
              widget.height * .08,
              widget.width * .08,
              0,
            ),
            child: SizedBox(
              height: widget.height * .32,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 96,
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: Color(0xff243538),
                      fontFamily: 'serif',
                      fontWeight: FontWeight.bold,
                      fontSize: 22,
                      height: 1.15,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
    return Semantics(
      image: true,
      label: '$title 封面',
      excludeSemantics: true,
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: FutureBuilder<File?>(
            key: ValueKey(identity),
            future: image,
            builder: (context, result) {
              if (result.data == null) return fallback;
              return Image.file(
                result.data!,
                fit: BoxFit.cover,
                cacheWidth:
                    (widget.width *
                            MediaQuery.devicePixelRatioOf(context) *
                            1.5)
                        .ceil(),
                errorBuilder: (_, error, stack) => fallback,
              );
            },
          ),
        ),
      ),
    );
  }
}
