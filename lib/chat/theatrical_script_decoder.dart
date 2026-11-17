import 'chat_protocol.dart';

/// Single-format incremental theatre-script decoder. Ordinary literary prose
/// is accepted as narration; JSON output is explicitly rejected.
class TheatricalScriptDecoder {
  TheatricalScriptDecoder({bool allowImages = true})
      : _script = _TheatricalLines(allowImages: allowImages);

  final _TheatricalLines _script;

  List<ChatOutputEvent> add(String fragment) => _script.add(fragment);
  ChatLine? get preview => _script.preview;
  List<ChatOutputEvent> finish() => _script.finish();
}

class _TheatricalLines {
  _TheatricalLines({required this.allowImages});
  final bool allowImages;

  static final _image = RegExp(
    r'^\[\s*IMAGE\s*\]\s*(.*)$',
    caseSensitive: false,
  );
  static final _narration = RegExp(
    r'^\[\s*(?:NARRATION|NARRATEUR)\s*\]\s*(.*)$',
    caseSensitive: false,
  );
  static final _character = RegExp(
    r'^\[\s*(?:PERSONNAGE|CHARACTER)\s*:\s*([^\]|]+?)\s*(?:\|\s*([^\]]+))?\]\s*(.*)$',
    caseSensitive: false,
  );
  static final _scene = RegExp(
    r'^\[\s*(?:SCENE|SCÈNE|SCENE_CHANGE|CHANGEMENT_DE_SCENE)\s*\]\s*(.*)$',
    caseSensitive: false,
  );
  static final _player = RegExp(
    r'^\[\s*(?:JOUEUR|PLAYER|PERSONNAGE\s*:\s*(?:VOUS|JOUEUR|PLAYER))\s*\]',
    caseSensitive: false,
  );
  static final _fence = RegExp(r'^\x60{3}[a-zA-Z]*$');

  bool _imageBlock = false;
  int _imageCount = 0;
  String _pendingLine = '';
  String _currentText = '';
  ChatSpeaker _speaker = ChatSpeaker.narrator;
  String _name = 'Narrateur';
  String? _status;
  int _emitted = 0;
  int _total = 0;

  List<ChatOutputEvent> add(String fragment) {
    _total += fragment.length;
    if (_total > 131072) {
      throw const FormatException('Réponse narrative trop volumineuse.');
    }
    _pendingLine += fragment;
    final output = <ChatOutputEvent>[];
    while (true) {
      final newline = _pendingLine.indexOf('\n');
      if (newline < 0) break;
      final line = _pendingLine.substring(0, newline).replaceFirst(
          RegExp(r'\r$'), '');
      _pendingLine = _pendingLine.substring(newline + 1);
      _consumeLine(line, output);
    }
    if (_pendingLine.length > 8192 || _currentText.length > 6000) {
      throw const FormatException('Bloc narratif trop volumineux.');
    }
    return output;
  }

  void _emit(List<ChatOutputEvent> output, ChatOutputEvent event) {
    if (_emitted >= 20) {
      throw const FormatException('Trop de messages dans la réponse IA.');
    }
    _emitted++;
    output.add(event);
  }

  void _flush(List<ChatOutputEvent> output) {
    final text = _currentText.trim();
    if (_imageBlock) {
      if (text.length > 500) {
        throw const FormatException('Description d’image trop longue.');
      }
      // Empty and repeated suggestions never invalidate valid prose.
      if (allowImages && text.isNotEmpty && _imageCount == 0) {
        _emit(output, ChatIllustrationOutput(text));
        _imageCount++;
      }
    } else if (text.isNotEmpty) {
      if (text.length > 6000) {
        throw const FormatException('Message narratif trop volumineux.');
      }
      _emit(output, ChatLine(
        speaker: _speaker, name: _name, text: text, status: _status));
    }
    _currentText = '';
  }

  void _append(String text) {
    _currentText += _currentText.isEmpty ? text : '\n$text';
    if (_currentText.length > 6000) {
      throw const FormatException('Message narratif trop volumineux.');
    }
  }

  void _consumeLine(String line, List<ChatOutputEvent> output) {
    final trimmed = line.trim();
    if (_fence.hasMatch(trimmed)) return;
    if (_player.hasMatch(trimmed)) {
      throw const FormatException(
          'Le narrateur ne peut pas écrire les répliques du joueur.');
    }
    final illustration = _image.firstMatch(trimmed);
    if (illustration != null) {
      _flush(output);
      _imageBlock = true;
      if (illustration.group(1)!.isNotEmpty) _append(illustration.group(1)!);
      return;
    }
    final narration = _narration.firstMatch(trimmed);
    if (narration != null) {
      _flush(output);
      _imageBlock = false;
      _speaker = ChatSpeaker.narrator;
      _name = 'Narrateur';
      _status = null;
      if (narration.group(1)!.isNotEmpty) _append(narration.group(1)!);
      return;
    }
    final character = _character.firstMatch(trimmed);
    if (character != null) {
      final name = character.group(1)!.trim();
      final status = character.group(2)?.trim();
      if (name.isEmpty || name.length > 50 ||
          {'vous', 'joueur', 'player', 'narrateur', 'narrator'}
              .contains(name.toLowerCase()) ||
          (status != null && (status.isEmpty || status.length > 50))) {
        throw const FormatException('Personnage narratif invalide.');
      }
      _flush(output);
      _imageBlock = false;
      _speaker = ChatSpeaker.character;
      _name = name;
      _status = status;
      if (character.group(3)!.isNotEmpty) _append(character.group(3)!);
      return;
    }
    final scene = _scene.firstMatch(trimmed);
    if (scene != null) {
      _flush(output);
      _emit(output, const ChatSceneChangeOutput());
      _imageBlock = false;
      _speaker = ChatSpeaker.narrator;
      _name = 'Narrateur';
      _status = null;
      if (scene.group(1)!.isNotEmpty) _append(scene.group(1)!);
      return;
    }
    // JSON, unknown markers, and truncated headers cannot become prose.
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      throw const FormatException('Format narratif invalide : utilise le script théâtral.');
    }
    // A bare literary response remains narration; never guess speakers.
    _append(line);
  }

  ChatLine? get preview {
    if (_imageBlock) return null;
    final candidate = _pendingLine.trimLeft();
    // A split marker must not flash as raw syntax in the UI.
    final withheld = candidate.startsWith('[') ||
        candidate.startsWith(String.fromCharCodes([96, 96, 96])) ||
        candidate.startsWith('{');
    final text = [
      if (_currentText.trim().isNotEmpty) _currentText,
      if (!withheld && candidate.isNotEmpty) _pendingLine,
    ].join(_currentText.isNotEmpty && !withheld ? '\n' : '').trim();
    if (text.isEmpty) return null;
    if (text.length > 6000) {
      throw const FormatException('Message narratif trop volumineux.');
    }
    return ChatLine(speaker: _speaker, name: _name,
        text: text, status: _status);
  }

  List<ChatOutputEvent> finish() {
    final output = <ChatOutputEvent>[];
    if (_pendingLine.isNotEmpty) {
      _consumeLine(_pendingLine.replaceFirst(RegExp(r'\r$'), ''), output);
      _pendingLine = '';
    }
    _flush(output);
    return output;
  }
}
