import 'dart:convert';
import 'dart:ui' as ui;

import 'package:domolia/books/book_definition.dart';
import 'package:flutter_test/flutter_test.dart';

// These fixtures are actual decodable image files, rather than just valid
// magic bytes. They are the same PNG/JPEG samples as the database roundtrip
// test, plus the original valid WebP 1x1 fixture.
const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR4nGNM6VnFwMDAxMDAwMDAAAATHAGeH6ekLgAAAABJRU5ErkJggg==';
const _jpeg = '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAACAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXFh8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwB9FFFeoeWf/9k=';
const _webp = 'UklGRh4AAABXRUJQVlA4TBEAAAAvAAAAAAdQrXrUqP+BiOh/AAA=';

void main() {
  testWidgets('actual PNG/JPEG/WebP covers remain decodable after JSON roundtrip',
      (tester) async {
    final originals = [
      const BookDefinition(
        id: 'cover-png', title: 'PNG',
        coverMime: 'image/png', coverBase64: _png,
      ),
      const BookDefinition(
        id: 'cover-jpeg', title: 'JPEG',
        coverMime: 'image/jpeg', coverBase64: _jpeg,
      ),
      const BookDefinition(
        id: 'cover-webp', title: 'WebP',
        coverMime: 'image/webp', coverBase64: _webp,
      ),
    ];
    for (final book in originals) {
      final restored = BookDefinition.importJson(book.exportJson());
      expect(restored.coverBase64, book.coverBase64);
      final size = await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(
          base64Decode(restored.coverBase64!),
        );
        try {
          final frame = await codec.getNextFrame();
          try {
            return (width: frame.image.width, height: frame.image.height);
          } finally {
            frame.image.dispose();
          }
        } finally {
          codec.dispose();
        }
      });
      expect(size, isNotNull);
      expect(size!.width, greaterThan(0));
      expect(size.height, greaterThan(0));
    }
  });
}
