import 'dart:math';

import 'package:flutter/foundation.dart';

import '../ai/ai_controller.dart';
import '../ai/ai_provider.dart';
import '../ai/ai_usage.dart';
import '../books/book_lore.dart';
import '../chat/chat_protocol.dart';
import '../memory/live_memory.dart';
import 'illustration_records.dart';
import 'image_preferences.dart';
import 'image_providers.dart';
import 'visual_pipeline.dart';

typedef ImageProviderFactory = ImageGenerationProvider Function(String id);

/// One session, one timeline. No image request is started by its constructor,
/// initialization, narration, or an incoming [IMAGE] marker.
class IllustrationController extends ChangeNotifier {
  IllustrationController({
    required this.sessionId,
    required this.ai,
    required this.preferences,
    required this.records,
    required this.timeline,
    required this.lore,
    required this.memory,
    required this.awaitNarrativeWrites,
    required this.files,
    this.usage,
    this.providerFactory,
    this.onOpenUncensoredCharge,
  });

  final String sessionId;
  final AiConnectionController ai;
  final ImagePreferences preferences;
  final IllustrationRecordStore records;
  final List<ChatTimelineEvent> Function() timeline;
  final BookLore Function() lore;
  final Iterable<LiveMemoryFact> Function() memory;
  final Future<void> Function() awaitNarrativeWrites;
  final LocalIllustrationFiles files;
  final AiUsageStore? usage;
  final ImageProviderFactory? providerFactory;
  final VoidCallback? onOpenUncensoredCharge;

  final Map<int, StoredIllustration> _latest = {};
  final Set<int> _inFlight = {};
  bool _closed = false;
  bool initialized = false;
  String? error;

  StoredIllustration? forIntent(int id) => _latest[id];
  bool isBusy(int id) => _inFlight.contains(id);

  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> initialize() async {
    final old = await records.listIllustrations(sessionId);
    final current = timeline().whereType<ChatIllustrationIntent>()
        .map((e) => e.id).toSet();
    for (final entry in old) {
      if (!current.contains(entry.intentId)) continue;
      // Unfinished jobs might have been billed before a process exit.
      _latest[entry.intentId] = entry.state == IllustrationJobState.preparing ||
              entry.state == IllustrationJobState.generating
          ? entry.copyWith(state: IllustrationJobState.failed,
              error: 'Opération interrompue ; vérifier vos crédits avant de réessayer.')
          : entry;
    }
    await files.pruneOrphans(await records.retainedIllustrationFiles());
    initialized = true;
    _notify();
  }

  int? get lastUnillustratedIntent {
    for (final event in timeline().reversed) {
      if (event is ChatIllustrationIntent &&
          event.state != IllustrationIntentState.cancelled &&
          event.state != IllustrationIntentState.ignored &&
          forIntent(event.id)?.state != IllustrationJobState.available) {
        return event.id;
      }
    }
    return null;
  }

  int? get lastAiMessageWithoutIntent {
    final events = timeline();
    for (var index = events.length - 1; index >= 0; index--) {
      final event = events[index];
      if (event is ChatEntry && event.speaker != ChatSpeaker.player &&
          event.text.trim().isNotEmpty &&
          (index + 1 == events.length ||
           events[index + 1] is! ChatIllustrationIntent)) return event.id;
    }
    return null;
  }

  ImageGenerationProvider _provider(String id) =>
      providerFactory?.call(id) ?? (id == 'openai'
          ? OpenAiImageGenerationProvider()
          : OpenUncensoredImageGenerationProvider());

  String _providerId(AiProfile profile) {
    if (profile.kind != AiProviderKind.customAi ||
        profile.apiKey.trim().isEmpty) {
      throw const ImageGenerationFailure(ImageFailureKind.authentication,
          'La génération d’image requiert une clé API personnelle, '
          'pas un jeton de connexion ChatGPT.');
    }
    final base = Uri.tryParse(profile.baseUrl);
    if (base == null || base.scheme != 'https') {
      throw const ImageGenerationFailure(ImageFailureKind.unsupported,
          'URL du fournisseur graphique non sécurisée.');
    }
    if (base.host == 'api.openai.com') return 'openai';
    if (base.host == 'api.openuncensored.com' ||
        base.host == 'openuncensored.com') return 'openuncensored';
    throw const ImageGenerationFailure(ImageFailureKind.unsupported,
        'Utilisez un profil API OpenAI ou OpenUncensored.');
  }

  Future<void> generate(int intentId) async {
    if (_closed || !_inFlight.add(intentId)) return;
    error = null;
    _notify();
    StoredIllustration? current;
    final savedFiles = <String>[];
    var providerInvoked = false;
    final start = DateTime.now();
    try {
      await awaitNarrativeWrites();
      final intents = timeline().whereType<ChatIllustrationIntent>()
          .where((e) => e.id == intentId).toList();
      if (intents.length != 1 ||
          intents.first.state == IllustrationIntentState.ignored ||
          intents.first.state == IllustrationIntentState.cancelled) {
        throw StateError('Cette intention n’existe plus.');
      }
      final scene = const VisualSceneSelector().select(
        intent: intents.first, timeline: timeline(),
        lore: lore(), memory: memory(),
      );
      final options = await preferences.forSession(sessionId);
      options.validate();
      final profiles = ai.profiles.where((e) => e.id == options.profileId);
      if (profiles.isEmpty || options.model.isEmpty) {
        throw StateError('Configurez un profil et un modèle graphique.');
      }
      final profile = profiles.first;
      final providerId = _providerId(profile);
      final directorId = options.directorProfileId;
      if (directorId.isEmpty) {
        throw StateError('Choisissez un profil IA pour la mise en scène.');
      }
      final directorConnection = await ai.connectionForProfile(directorId);
      final imageProvider = _provider(providerId);
      // Price estimates are deliberately null until an actual, reliable
      // maximum cost is provided by the selected backend.
      if (options.maximumCostUsd != null) {
        throw StateError('Plafond strict impossible : coût maximal inconnu. '
            'Désactivez le plafond ou choisissez un modèle à prix garanti.');
      }
      final unique = 'request-' +
          DateTime.now().microsecondsSinceEpoch.toString() + '-' +
          Random.secure().nextInt(0x7fffffff).toString();
      current = StoredIllustration(
        requestId: unique, sessionId: sessionId, intentId: intentId,
        sourceHash: scene.sourceHash, state: IllustrationJobState.preparing,
        provider: providerId, model: options.model,
        createdAtUtc: DateTime.now().toUtc(),
      );
      if (!await records.saveIllustrationIfCurrent(current)) {
        throw StateError('Cette scène a été modifiée ou supprimée.');
      }
      _latest[intentId] = current;
      _notify();

      final direction = await const VisualDirector().direct(
        scene: scene, provider: directorConnection.provider,
        connection: directorConnection.configuration,
      );
      final prompt = validatedImagePrompt(scene, direction, style: options.style);
      current = current.copyWith(
          state: IllustrationJobState.generating, prompt: prompt);
      if (!await records.saveIllustrationIfCurrent(current)) {
        throw StateError('Scène invalidée avant la génération.');
      }
      _latest[intentId] = current;
      _notify();

      providerInvoked = true;
      final result = await imageProvider.generate(
        ImageGenerationRequest(
          model: options.model, prompt: prompt, size: options.size,
          quality: options.quality, count: options.count,
        ),
        apiKey: profile.apiKey,
      );
      for (var index = 0; index < result.images.length; index++) {
        final image = result.images[index];
        savedFiles.add(await files.save(unique + '-' + index.toString(),
            image.bytes, image.mimeType));
      }
      final completed = current.copyWith(
        state: IllustrationJobState.available,
        fileNames: List.unmodifiable(savedFiles),
        mimeType: result.images.first.mimeType,
        costUsd: result.costUsd,
      );
      if (!await records.saveIllustrationIfCurrent(completed)) {
        // In-flight HTTP results cannot attach to a rewritten history.
        for (final file in savedFiles) { await files.delete(file); }
        savedFiles.clear();
        _latest.remove(intentId);
        throw StateError('La scène a changé pendant la génération.');
      }
      current = completed;
      _latest[intentId] = completed;
      if (providerId == 'openuncensored') onOpenUncensoredCharge?.call();
      await _usage(completed, failed: false, start: start);
    } catch (failure) {
      final message = failure is ImageGenerationFailure
          ? failure.message : failure is FormatException
          ? 'Mise en scène invalide ou insuffisamment attestée.'
          : failure is StateError ? failure.message
          : 'Erreur de génération. Vérifiez le fournisseur et les crédits.';
      error = message;
      for (final file in savedFiles) { await files.delete(file); }
      if (current != null) {
        final failed = current.copyWith(
          state: IllustrationJobState.failed, error: message);
        if (await records.saveIllustrationIfCurrent(failed)) {
          _latest[intentId] = failed;
        } else {
          _latest.remove(intentId);
        }
        // A timeout does not prove that the image API was not billed.
        if (providerInvoked) await _usage(failed, failed: true, start: start);
      }
    } finally {
      _inFlight.remove(intentId);
      _notify();
    }
  }

  Future<void> _usage(StoredIllustration record,
      {required bool failed, required DateTime start}) async {
    try {
      await usage?.putUsage(AiUsageRecord(
        id: 'image-' + record.requestId, sessionId: sessionId,
        stage: 'image_generation', createdAtUtc: start.toUtc(),
        providerCostUsd: record.costUsd,
        failed: failed, usageSource: 'unknown',
        durationMs: DateTime.now().difference(start).inMilliseconds,
        playerEventId: record.intentId,
      ));
    } catch (_) {
      // Usage storage may fail; never submit another charge to compensate.
    }
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}
