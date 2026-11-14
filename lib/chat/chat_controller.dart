import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../ai/ai_provider.dart';
import '../ai/ai_diagnostics.dart';
import 'chat_protocol.dart';
import 'narrator.dart';

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
    this.narrator = const Narrator(),
    this.narratorProvider,
    this.onTimelineChanged,
    this.diagnostics,
    int Function(int count)? selectOpeningIndex,
  }) : _selectOpeningIndex = selectOpeningIndex ?? Random.secure().nextInt;

  final AiChatProvider provider;
  final AiConfiguration? Function() configuration;
  final Future<NarrativeAiEndpoint> Function()? resolveConnection;
  final Narrator narrator;
  final AiExchangeRecorder? diagnostics;
  AiExchange? lastExchange;

  /// Reads the latest saved narrator settings for each new model request.
  final Narrator Function()? narratorProvider;
  final int Function(int count) _selectOpeningIndex;

  /// Store only committed events, never streaming previews.
  final void Function(List<ChatTimelineEvent> events)? onTimelineChanged;

  void _timelineChanged() =>
      onTimelineChanged?.call(List<ChatTimelineEvent>.unmodifiable(_timeline));

  /// Restore a saved session before beginConversation without triggering AI.
  void restoreTimeline(List<ChatTimelineEvent> events) {
    if (_closed || busy || _timeline.isNotEmpty) {
      throw StateError('La conversation est déjà ouverte.');
    }
    _timeline.addAll(events);
    _started = events.isNotEmpty;
    if (events.isNotEmpty) {
      _nextId = events.last.id + 1;
      final last = _timeline.lastIndexWhere(
        (item) => item is ChatEntry && item.speaker == ChatSpeaker.player,
      );
      _lastPlayerIndex = last < 0 ? null : last;
    }
    _notify();
  }
  bool _started = false;

  /// Adds one local narrator bubble at the beginning of the conversation.
  /// Calling this after navigating away and back is always a no-op.
  void beginConversation() {
    if (_closed || _started || _timeline.isNotEmpty) return;
    _started = true;
    final candidates = (narratorProvider?.call() ?? narrator).openingMessages
        .where((message) => message.trim().isNotEmpty)
        .toList(growable: false);
    if (candidates.isEmpty) return;
    final index = _selectOpeningIndex(candidates.length);
    if (index < 0 || index >= candidates.length) {
      throw RangeError.range(index, 0, candidates.length - 1, 'openingIndex');
    }
    _timeline.add(ChatEntry(
      id: _nextId++,
      speaker: ChatSpeaker.narrator,
      name: 'Narrateur',
      text: candidates[index].trim(),
    ));
    _timelineChanged();
    _notify();
  }

  final List<ChatTimelineEvent> _timeline = [];
  List<ChatTimelineEvent> get timeline => List.unmodifiable(_timeline);

  /// Only dialogue bubbles. Old callers need not know about scene dividers.
  List<ChatEntry> get messages =>
      List.unmodifiable(_timeline.whereType<ChatEntry>());

  /// A future image prompt builder can read just the current scene's dialogue.
  List<ChatEntry> get currentSceneMessages {
    final boundary = _timeline.lastIndexWhere(
      (event) => event is ChatSceneChange,
    );
    return List.unmodifiable(
      _timeline.skip(boundary + 1).whereType<ChatEntry>(),
    );
  }
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
    _lastPlayerIndex = _timeline.length;
    _timeline.add(ChatEntry(
      id: _nextId++,
      speaker: ChatSpeaker.player,
      name: 'Vous',
      text: action,
    ));
    _timelineChanged();
    await _generate();
  }

  Future<void> regenerate() async {
    if (_closed || busy || _lastPlayerIndex == null) return;
    // Keep the original player message. Never add it a second time.
    _timeline.removeRange(_lastPlayerIndex! + 1, _timeline.length);
    _timelineChanged();
    await _generate();
  }

  Future<void> retry() => regenerate();

  List<AiMessage> _buildContext() {
    final recent = _timeline.length > 35
        ? _timeline.sublist(_timeline.length - 35)
        : _timeline;
    return [
      AiMessage(
        role: 'system',
        content: (narratorProvider?.call() ?? narrator).systemPrompt,
      ),
      for (final event in recent)
        if (event is ChatSceneChange)
          const AiMessage(
            role: 'assistant',
            content: '{"type":"scene_change"}',
          )
        else if (event is ChatEntry)
          AiMessage(
            role: event.speaker == ChatSpeaker.player ? 'user' : 'assistant',
            content: event.speaker == ChatSpeaker.player
                ? event.text
                : jsonEncode({
                    'type': 'message',
                    'speaker': event.speaker == ChatSpeaker.narrator
                        ? 'narrator'
                        : 'character',
                    'name': event.name,
                    'text': event.text,
                  }),
          ),
    ];
  }

  void _addLines(Iterable<ChatOutputEvent> events) {
    var changed = false;
    for (final event in events) {
      changed = true;
      if (event is ChatSceneChangeOutput) {
        if (_timeline.isEmpty || _timeline.last is ChatSceneChange) {
          throw const FormatException('Changement de scène consécutif ou isolé.');
        }
        _timeline.add(ChatSceneChange(id: _nextId++));
      } else if (event is ChatLine) {
        _currentTurnCount++;
        _timeline.add(ChatEntry(
          id: _nextId++,
          speaker: event.speaker,
          name: event.name,
          text: event.text,
        ));
      }
    }
    if (changed) _timelineChanged();
  }

  Future<void> _generate() async {
    lastExchange = null;
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
    final priorExchange = diagnostics?.last;
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
                preview = decoder.isPendingSceneChange
                    ? null
                    : current == null
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
      if (diagnostics?.last != priorExchange) {
        lastExchange = diagnostics?.last;
      }
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
