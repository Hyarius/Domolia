import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../logging/app_logger.dart';
import 'book_definition.dart';

class BookCoverData {
  const BookCoverData(this.mime, this.base64);
  final String mime;
  final String base64;
}

/// FilePicker may give bytes or an Android cache path, depending on the
/// document provider. Never persist a provider URI or an external file path.
class BookCoverLoader {
  static Future<BookCoverData> load(PlatformFile file) async {
    AppLogger.debug('Couverture sélectionnée', component: 'cover',
      details: {'reportedBytes': file.size, 'hasBytes': file.bytes != null,
          'hasCachePath': file.path != null});
    if (file.size > BookDefinition.maxCoverBytes) {
      AppLogger.warning('Couverture trop volumineuse', component: 'cover',
          details: {'bytes': file.size});
      throw const FormatException('Couverture supérieure à 1 Mo.');
    }

    Uint8List? bytes = file.bytes;
    if (bytes == null && file.path != null) {
      AppLogger.debug('Lecture du fichier temporaire Android', component: 'cover');
      try {
        final cached = File(file.path!);
        if (await cached.length() > BookDefinition.maxCoverBytes) {
          throw const FormatException('Couverture supérieure à 1 Mo.');
        }
        bytes = await cached.readAsBytes();
      } on FormatException {
        rethrow;
      } on FileSystemException catch (error, stackTrace) {
        AppLogger.error('Fichier de couverture inaccessible', component: 'cover',
            error: error, stackTrace: stackTrace);
        throw const FormatException('Fichier de couverture inaccessible.');
      }
    }
    if (bytes == null || bytes.isEmpty) {
      AppLogger.warning('Sélecteur sans données de couverture', component: 'cover');
      throw const FormatException('Fichier de couverture inaccessible.');
    }
    if (bytes.length > BookDefinition.maxCoverBytes) {
      throw const FormatException('Couverture supérieure à 1 Mo.');
    }

    // MIME is determined by the actual bytes rather than unreliable picker
    // extensions; BookDefinition.validate checks the signature again.
    String mime;
    if (bytes.length >= 8 &&
        bytes[0] == 137 && bytes[1] == 80 && bytes[2] == 78 &&
        bytes[3] == 71 && bytes[4] == 13 && bytes[5] == 10 &&
        bytes[6] == 26 && bytes[7] == 10) {
      mime = 'image/png';
    } else if (bytes.length >= 3 && bytes[0] == 255 &&
        bytes[1] == 216 && bytes[2] == 255) {
      mime = 'image/jpeg';
    } else if (bytes.length >= 12 &&
        ascii.decode(bytes.sublist(0, 4)) == 'RIFF' &&
        ascii.decode(bytes.sublist(8, 12)) == 'WEBP') {
      mime = 'image/webp';
    } else {
      AppLogger.warning('Signature de couverture inconnue', component: 'cover',
          details: {'bytes': bytes.length});
      throw const FormatException('Image PNG, JPEG ou WebP attendue.');
    }
    AppLogger.info('Couverture décodée', component: 'cover',
        details: {'bytes': bytes.length, 'mime': mime});
    return BookCoverData(mime, base64Encode(bytes));
  }
}
