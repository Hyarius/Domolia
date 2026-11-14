import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../ai/ai_provider.dart';
import 'chat_protocol.dart';

const groupChatSystemPrompt = '''
Tu es l'orchestrateur d'une conversation de jeu de rôle en français.
Tu contrôles le narrateur, les personnages et le décor, mais jamais les
paroles, pensées, choix ou actions du personnage joueur.
Le joueur est le participant "Vous" et seul l'utilisateur le fait parler.
Pour chaque prise de parole, retourne EXCLUSIVEMENT une ligne JSON valide,
sans tableau, sans Markdown et sans texte autour :
{"speaker":"narrator","name":"Narrateur","text":"Description de la scène."}
{"speaker":"character","name":"Lina","text":"Dialogue de Lina."}
Le narrateur est un participant ordinaire, au même titre que les personnages.
Tu peux produire plusieurs lignes JSON pour un même tour, avec plusieurs
personnages et le narrateur, dans l'ordre des événements.
Le champ speaker vaut uniquement narrator ou character.
Le champ name doit être constant pour une même personne dans la scène.
N'invente aucune intervention du joueur. Chaque ligne est un objet JSON
indépendant, avec des chaînes correctement échappées.
Conserve des réponses suffisamment courtes pour un chat sur téléphone.
''';

class NarrativeAiEndpoint {
  const NarrativeAiEndpoint({required this.provider, required this.configuration});
  final AiChatProvider provider;
  final AiConfiguration configuration;
}

class NarrativeChatController extends ChangeNotifier {
  NarrativeChatController({
    required this.provider,
    required this.configuration,
    this.resolveConnection,
  });

  final AiChatProvider provider;
  final AiConfiguration? Function() configuration;
  final Future<NarrativeAiEndpoint> Function()? resolveConnection;

  final List<ChatEntry> _messages = [];
  List<ChatEntry> get messages => List.unmodifiable(_messages);
  ChatEntry? preview;
  bool busy = false;
  String? error;
  int? promptTokens;
  int? completionTokens;
  String? modelUsed;
  bool _closed = false;
  int _nextId = 0;
  int? _lastPlayerIndex;
  int _currentTurnCount = 0;
  bool _cancelled = false;
  StreamSubscription<AiStreamChunk>? _subscription;
  Completer<void>? _done;

  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> send(String text) async {
    final action = text.trim();
    if (_closed || busy || action.isEmpty) return;
    if (action.length > 4000) {
      error = 'Le message est trop long (maximum 4 000 caractères).';
      _notify();
      return;
    }
    _lastPlayerIndex = _messages.length;
    _messages.add(ChatEntry(
      id: _nextId++,
      speaker: ChatSpeaker.player,
      name: 'Vous',
      text: action,
    ));
    await _generate();
  }

  Future<void> regenerate() async {
    if (_closed || busy || _lastPlayerIndex == null) return;
    // Keep the original player message. Never add it a second time.
    _messages.removeRange(_lastPlayerIndex! + 1, _messages.length);
    await _generate();
  }

  Future<void> retry() => regenerate();

  List<AiMessage> _buildContext() {
    final recent = _messages.length > 35
        ? _messages.sublist(_messages.length - 35)
        : _messages;
    return [
      const AiMessage(role: 'system', content: groupChatSystemPrompt),
      for (final message in recent)
        AiMessage(
          role: message.speaker == ChatSpeaker.player ? 'user' : 'assistant',
          content: message.speaker == ChatSpeaker.player
              ? message.text
              : jsonEncode({
                  'speaker': message.speaker == ChatSpeaker.narrator
                      ? 'narrator'
                      : 'character',
                  'name': message.name,
                  'text': message.text,
                }),
        ),
    ];
  }

  void _addLines(Iterable<ChatLine> lines) {
    for (final line in lines) {
      _currentTurnCount++;
      _messages.add(ChatEntry(
        id: _nextId++,
        speaker: line.speaker,
        name: line.name,
        text: line.text,
      ));
    }
  }

  Future<void> _generate() async {
    error = null;
    busy = true;
    _cancelled = false;
    _currentTurnCount = 0;
    promptTokens = null;
    completionTokens = null;
    preview = ChatEntry(
      id: -1, speaker: ChatSpeaker.narrator, name: 'Narrateur',
      text: 'Rédaction en cours…', inProgress: true,
    );
    _notify();

    NarrativeAiEndpoint? endpoint;
    try {
      if (resolveConnection != null) {
        endpoint = await resolveConnection!();
      } else {
        final config = configuration();
        if (config != null) {
          endpoint = NarrativeAiEndpoint(
            provider: provider,
            configuration: config,
          );
        }
      }
    } on AiProviderException catch (failure) {
      error = failure.userMessage;
    } catch (_) {
      error = 'Impossible de préparer la connexion IA.';
    }
    if (_closed || _cancelled) return;
    if (endpoint == null || endpoint.configuration.apiKey.isEmpty) {
      error ??= 'Configurez une connexion IA valide dans les paramètres.';
      preview = null;
      busy = false;
      _notify();
      return;
    }
    final selectedProvider = endpoint.provider;
    final config = endpoint.configuration;
    modelUsed = config.model;

    final decoder = ChatLineDecoder();
    final context = _buildContext();
    try {
      if (selectedProvider is AiStreamingChatProvider) {
        final complete = Completer<void>();
        _done = complete;
        _subscription = (selectedProvider as AiStreamingChatProvider)
            .streamChat(config, messages: context, maxTokens: 1200)
            .listen(
          (chunk) {
            if (_cancelled || _closed) return;
            try {
              if (chunk.promptTokens != null) promptTokens = chunk.promptTokens;
              if (chunk.completionTokens != null) {
                completionTokens = chunk.completionTokens;
              }
              if (chunk.text.isNotEmpty) {
                _addLines(decoder.add(chunk.text));
                final current = decoder.preview;
                preview = current == null
                    ? ChatEntry(
                        id: -1,
                        speaker: ChatSpeaker.narrator,
                        name: 'Narrateur',
                        text: 'Rédaction en cours…',
                        inProgress: true,
                      )
                    : ChatEntry(
                        id: -1,
                        speaker: current.speaker,
                        name: current.name,
                        text: current.text.isEmpty ? '…' : current.text,
                        inProgress: true,
                      );
              }
              _notify();
            } catch (failure) {
              error = failure is FormatException
                  ? failure.message
                  : 'Le format de la réponse IA est invalide.';
              _subscription?.cancel();
              if (!complete.isCompleted) complete.complete();
            }
          },
          onError: (Object failure, StackTrace trace) {
            if (!_cancelled) {
              error = failure is AiProviderException
                  ? failure.userMessage
                  : 'La connexion a été interrompue. Réessayez.';
            }
            if (!complete.isCompleted) complete.complete();
          },
          onDone: () {
            if (!_cancelled && error == null) {
              try {
                _addLines(decoder.finish());
              } on FormatException catch (failure) {
                error = failure.message;
              }
            }
            if (!complete.isCompleted) complete.complete();
          },
          cancelOnError: true,
        );
        await complete.future;
      } else {
        // A provider can implement only AiChatProvider.complete(). In that
        // case the same strict format is decoded after its single response.
        final text = await selectedProvider.complete(
          config, messages: context, maxTokens: 1200,
        );
        if (!_cancelled) {
          _addLines(decoder.add(text));
          _addLines(decoder.finish());
        }
      }
      if (!_cancelled && error == null && _currentTurnCount == 0) {
        error = 'Le modèle n’a retourné aucun message exploitable.';
      }
    } on AiProviderException catch (failure) {
      if (!_cancelled) error = failure.userMessage;
    } on FormatException catch (failure) {
      if (!_cancelled) error = failure.message;
    } catch (_) {
      if (!_cancelled) error = 'Impossible de générer la réponse. Réessayez.';
    } finally {
      _subscription = null;
      _done = null;
      preview = null;
      busy = false;
      _notify();
    }
  }

  void stop() {
    if (!busy || _closed) return;
    _cancelled = true;
    error = 'Génération interrompue.';
    preview = null;
    busy = false;
    unawaited(_subscription?.cancel() ?? Future<void>.value());
    if (_done != null && !_done!.isCompleted) _done!.complete();
    _notify();
  }

  @override
  void dispose() {
    _closed = true;
    _cancelled = true;
    unawaited(_subscription?.cancel() ?? Future<void>.value());
    if (_done != null && !_done!.isCompleted) _done!.complete();
    super.dispose();
  }
}
