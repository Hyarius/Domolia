import 'chat_protocol.dart';

/// Incremental theatre script parser. A plain prose reply becomes one narrator
/// block. Historical NDJSON is accepted for compatibility without changing
/// the durable ChatTimelineEvent model.
class TheatricalScriptDecoder {
  final ChatLineDecoder _legacyJson = ChatLineDecoder();
  final _TheatricalLines _script = _TheatricalLines();
  String _initial = '';
  bool? _jsonMode;

  List<ChatOutputEvent> add(String fragment) {
    if (_jsonMode == null) {
      _initial += fragment;
      if (_initial.length > 131072) {
        throw const FormatException('Réponse narrative trop volumineuse.');
      }
      final start = _initial.trimLeft();
      if (start.isEmpty) return const [];
      _jsonMode = start.startsWith('{');
      final initial = _initial;
      _initial = '';
      return _jsonMode! ? _legacyJson.add(initial) : _script.add(initial);
    }
    return _jsonMode! ? _legacyJson.add(fragment) : _script.add(fragment);
  }

  ChatLine? get preview => _jsonMode == null
      ? null : _jsonMode! ? _legacyJson.preview : _script.preview;

  List<ChatOutputEvent> finish() {
    if (_jsonMode == null) return const [];
    return _jsonMode! ? _legacyJson.finish() : _script.finish();
  }
}

class _TheatricalLines {
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
    if (text.isNotEmpty) {
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
    // Never silently reinterpret malformed JSON as stage directions.
    if (trimmed.startsWith('{"type"')) {
      throw const FormatException('Formats narratifs mélangés.');
    }
    final narration = _narration.firstMatch(trimmed);
    if (narration != null) {
      _flush(output);
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
      _speaker = ChatSpeaker.narrator;
      _name = 'Narrateur';
      _status = null;
      if (scene.group(1)!.isNotEmpty) _append(scene.group(1)!);
      return;
    }
    // A bare text reply, including dashes, stays narration: attributing
    // characters without a speaker marker is unreliable.
    _append(line);
  }

  ChatLine? get preview {
    final candidate = _pendingLine.trimLeft();
    // A split marker must not flash as raw syntax in the UI.
    final withheld = candidate.startsWith('[') ||
        candidate.startsWith(String.fromCharCodes([96, 96, 96])) ||
        candidate.startsWith('{"type"');
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
