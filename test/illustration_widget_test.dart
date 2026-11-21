import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:domolia/ai/ai_controller.dart';
import 'package:domolia/ai/ai_diagnostics.dart';
import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/books/book_lore.dart';
import 'package:domolia/books/book_definition.dart';
import 'package:domolia/chat/chat_controller.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/chat/group_chat_page.dart';
import 'package:domolia/illustration/illustration_controller.dart';
import 'package:domolia/illustration/illustration_records.dart';
import 'package:domolia/memory/live_memory.dart';
import 'package:domolia/illustration/image_preferences.dart';
import 'package:domolia/illustration/image_providers.dart';
import 'package:domolia/theme/domolia_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Store implements AiProfileStore {
  @override
  Future<AiProfilesState?> read() async => const AiProfilesState(
    profiles: [
      AiProfile(id:'image',name:'Images OU',
        baseUrl:'https://api.openuncensored.com/v1',
        model:'text',apiKey:'ou-key'),
      AiProfile(id:'director',name:'Directeur photo',
        baseUrl:'https://api.openuncensored.com/v1',
        model:'text',apiKey:'text-key'),
    ],
    selectedId:'director',
  );
  @override
  Future<void> write(AiProfilesState state) async {}
}

class _NoKeyStore implements AiProfileStore {
  @override
  Future<AiProfilesState?> read() async => const AiProfilesState(
    profiles: [
      AiProfile(id:'image', name:'Images OU',
        baseUrl:'https://api.openuncensored.com/v1',
        model:'text', apiKey:''),
      AiProfile(id:'director', name:'Directeur photo',
        baseUrl:'https://api.openuncensored.com/v1',
        model:'text', apiKey:''),
    ],
    selectedId:'director',
  );
  @override
  Future<void> write(AiProfilesState state) async {}
}

class _Text implements AiChatProvider {
  Completer<String>? gate;
  @override
  Future<List<AiModel>> listModels(AiConfiguration configuration) async => [];
  @override
  Future<String> complete(AiConfiguration configuration, {
    required List<AiMessage> messages, int maxTokens = 300,
  }) async {
    if (gate != null) return gate!.future;
    return jsonEncode({
      'prompt':'Un personnage adulte se tient immobile au milieu d’une '
          'pièce calme. Il regarde autour de lui, les bras le long du corps. '
          'Plan moyen, angle à hauteur des yeux, lumière douce et diffuse.',
    });
  }
}

class _FailOnceDirector extends _Text {
  Object? nextFailure;
  String? nextText;

  @override
  Future<String> complete(AiConfiguration configuration, {
    required List<AiMessage> messages, int maxTokens = 300,
  }) async {
    final failure = nextFailure;
    nextFailure = null;
    if (failure != null) throw failure;
    final replacement = nextText;
    nextText = null;
    if (replacement != null) return replacement;
    return super.complete(
      configuration, messages: messages, maxTokens: maxTokens,
    );
  }
}

class _VisualText extends _Text {
  int calls = 0;

  @override
  Future<String> complete(AiConfiguration configuration, {
    required List<AiMessage> messages, int maxTokens = 300,
  }) async {
    calls++;
    return jsonEncode({
      'prompt':'La boulangère, femme adulte aux cheveux bruns coupés '
          'aux épaules et aux yeux verts, ajuste son tablier beige. '
          'Elle se tient debout derrière le comptoir de sa boulangerie, '
          'le buste légèrement incliné, les mains sur la taille du tablier. '
          'Lumière chaude et douce, plan moyen de face.',
      'appearances':[{
        'id':'party:boulangere',
        'identity':'Cheveux bruns et yeux verts',
        'current':'Tablier beige',
      }],
    });
  }
}

class _Image implements ImageGenerationProvider {
  int calls=0;
  ImageGenerationRequest? lastRequest;
  Completer<ImageGenerationResult>? gate;
  @override
  String get id=>'openuncensored';
  @override
  Future<List<ImageModelCapability>> listModels(String apiKey) async => [
    const ImageModelCapability(id:'test-image',
      sizes:['1024x1024']),
  ];
  @override
  Future<ImageGenerationResult> generate(ImageGenerationRequest request,
      {required String apiKey}) async {
    calls++;
    lastRequest=request;
    expect(request.model,'test-image');
    expect(request.prompt.length, greaterThan(50));
    expect(request.prompt, isNot(contains('Sujet :')));
    expect(request.prompt, isNot(contains('focusIds')));
    expect(request.prompt,isNot(contains('Texte établi :')));
    expect(request.prompt,isNot(contains('Mémoire confirmée :')));
    expect(request.prompt,isNot(contains('ACTION PRIORITAIRE')));
    expect(request.prompt,isNot(contains('Personnage party:')));
    if (gate != null) return gate!.future;
    return _result();
  }
}

ImageGenerationResult _result() {
  final bytes=base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
    'AAAAC0lEQVR42mP8/x8AAwMCAO+jJ5kAAAAASUVORK5CYII=');
  return ImageGenerationResult(
    images:[GeneratedImage(Uint8List.fromList(bytes),'image/png')],
    provider:'openuncensored',model:'test-image',costUsd:0.01,
  );
}

class _MemoryFiles extends LocalIllustrationFiles {
  _MemoryFiles() : super(root: () async => Directory('unused'));
  final Map<String, Uint8List> storage = {};

  @override
  Future<String> save(String requestId, Uint8List bytes, String mimeType) async {
    final name = 'img-$requestId.png';
    storage[name] = bytes;
    return name;
  }

  @override
  Future<Uint8List?> read(String name) async => storage[name];

  @override
  Future<void> delete(String name) async { storage.remove(name); }

  @override
  Future<void> pruneOrphans(Set<String> retained) async {
    storage.removeWhere((name, _) => !retained.contains(name));
  }
}

class _ImageRecords implements IllustrationRecordStore {
  final Map<String,StoredIllustration> jobs={};
  List<ChatTimelineEvent> Function()? timeline;
  @override
  Future<List<StoredIllustration>> listIllustrations(String sessionId) async =>
    jobs.values.toList();
  @override
  Future<bool> saveIllustrationIfCurrent(StoredIllustration record) async {
    if (!(timeline?.call().whereType<ChatIllustrationIntent>()
      .any((e)=>e.id==record.intentId) ?? false)) {
      return false;
    }
    jobs[record.requestId]=record;
    return true;
  }
  @override
  Future<Set<String>> retainedIllustrationFiles() async => {
    for(final r in jobs.values)...r.fileNames,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(()=>SharedPreferences.setMockInitialValues({}));

  testWidgets('Placeholder generates only after confirmation and brush exists',
      (tester) async {
    tester.view.physicalSize=const Size(430,1100);
    tester.view.devicePixelRatio=1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final memoryFiles = _MemoryFiles();
    final text=_Text();
    final ai=AiConnectionController(store:_Store(),provider:text);
    addTearDown(ai.dispose);
    await ai.initialize();
    final prefs=ImagePreferences();
    addTearDown(prefs.dispose);
    await prefs.initialize();
    await prefs.saveApplication(const ImageGenerationOptions(
      profileId:'image',directorProfileId:'director',
      model:'test-image'));
    final chat=NarrativeChatController(
      provider:text,
      configuration:()=>const AiConfiguration(
        baseUrl:'https://api.openuncensored.com/v1',
        model:'text',apiKey:'test'),
    );
    addTearDown(chat.dispose);
    chat.restoreTimeline(const [
      ChatEntry(id:1,speaker:ChatSpeaker.narrator,
        name:'Narrateur',text:'Soren referme lentement le tiroir.'),
      ChatIllustrationIntent(id:2,playerEventId:1,
        description:'Soren referme le tiroir.'),
    ]);
    final records=_ImageRecords()..timeline=()=>chat.timeline;
    final image=_Image();
    final images=IllustrationController(
      sessionId:'session',ai:ai,preferences:prefs,records:records,
      timeline:()=>chat.timeline,lore:()=>const BookLore(),
      memory:()=>const [],awaitNarrativeWrites:() async {},
      files:memoryFiles,
      providerFactory:(_)=>image,
    );
    addTearDown(images.dispose);
    await images.initialize();
    await tester.pumpWidget(MaterialApp(
      theme:DomoliaTheme.dark,
      home:Scaffold(body:GroupChatPage(
        controller:chat,onOpenSettings:(){},illustrations:images,
      )),
    ));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('chatIllustrateLastScene')),
      findsOneWidget);
    expect(find.byKey(const ValueKey('imagePreparePrompt')),findsOneWidget);
    expect(find.byKey(const ValueKey('imagePromptText')),findsOneWidget);
    expect(image.calls,0);
    await tester.tap(find.byKey(const ValueKey('imagePreparePrompt')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('imageApprovePrompt')),findsOneWidget);
    expect(image.calls,0);
    await tester.ensureVisible(
      find.byKey(const ValueKey('imageApprovePrompt')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('imageApprovePrompt')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('imageGenerate')),findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('imageGenerate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('imageGenerate')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('imageConfirmGenerate')),
      findsOneWidget);
    expect(image.calls,0);
    await tester.tap(find.text('Annuler').last);
    await tester.pump(const Duration(milliseconds: 500));
    expect(image.calls,0);
    await tester.ensureVisible(find.byKey(const ValueKey('imageGenerate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('imageGenerate')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const ValueKey('imageConfirmGenerate')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(image.calls,1);
    expect(find.byKey(const ValueKey('chatGeneratedImage')),findsOneWidget);
    // Once the image is available, the chat shows the image alone.
    expect(find.byKey(const ValueKey('imagePromptText')),findsNothing);
    expect(find.byKey(const ValueKey('imageRegenerate')),findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('chatGeneratedImage')));
    await tester.pumpAndSettle();
    // Actions remain accessible by long-pressing the completed image.
    await tester.longPress(find.byKey(const ValueKey('chatGeneratedImage')));
    await tester.pumpAndSettle();
    expect(find.text('Régénérer l’image'),findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('imageActionCopyPrompt')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chatGeneratedImage')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('imagePromptExport')),findsOneWidget);
    expect(find.byTooltip('Exporter le prompt (JSON)'),findsOneWidget);
    expect(find.byKey(const ValueKey('imageRegenerate')),findsOneWidget);
    await tester.tap(find.text('Prompt et modèle'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Prompt final :'),findsOneWidget);
  });

  test('No image configuration required with an OpenUncensored API key',
      () async {
    final ai=AiConnectionController(store:_Store(),provider:_Text());
    addTearDown(ai.dispose);
    await ai.initialize();
    final prefs=ImagePreferences();
    addTearDown(prefs.dispose);
    await prefs.initialize();
    final events=<ChatTimelineEvent>[
      const ChatEntry(id:1,speaker:ChatSpeaker.narrator,
        name:'Narrateur',text:'La lumière entre dans la pièce.'),
      const ChatIllustrationIntent(id:2,playerEventId:1,
        description:'La lumière dessine un rayon sur le plancher.'),
    ];
    final records=_ImageRecords()..timeline=()=>events;
    final provider=_Image();
    final controller=IllustrationController(
      sessionId:'automatic',ai:ai,preferences:prefs,
      records:records,timeline:()=>events,
      lore:()=>const BookLore(),memory:()=>const [],
      visualSettings:()=>const BookIllustrationSettings(quality:'high'),
      awaitNarrativeWrites:() async {},
      files:_MemoryFiles(),providerFactory:(_)=>provider,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.generate(2);
    expect(provider.calls,1);
    expect(provider.lastRequest!.quality,isNull);
    expect(provider.lastRequest!.model,'test-image');
    expect(provider.lastRequest!.negativePrompt,
        contains('bulles de dialogue'));
    expect(provider.lastRequest!.prompt,
        isNot(contains('À exclure :')));
    expect(controller.forIntent(2)?.state,IllustrationJobState.available);
  });

  test('Duplicate requests while provider is pending spend only once',
      () async {
    final dir=await Directory.systemTemp.createTemp('domolia-image-race-');
    addTearDown(()=>dir.delete(recursive:true));
    final ai=AiConnectionController(store:_Store(),provider:_Text());
    addTearDown(ai.dispose);
    await ai.initialize();
    final preferences=ImagePreferences();
    addTearDown(preferences.dispose);
    await preferences.initialize();
    await preferences.saveApplication(const ImageGenerationOptions(
      profileId:'image',directorProfileId:'director',
      model:'test-image'));
    final events=<ChatTimelineEvent>[
      const ChatEntry(id:1,speaker:ChatSpeaker.narrator,
        name:'Narrateur',text:'Soren referme le tiroir.'),
      const ChatIllustrationIntent(id:2,playerEventId:1,
        description:'Soren referme le tiroir.'),
    ];
    final records=_ImageRecords()..timeline=()=>events;
    final image=_Image()..gate=Completer<ImageGenerationResult>();
    final controller=IllustrationController(
      sessionId:'s',ai:ai,preferences:preferences,records:records,
      timeline:()=>events,lore:()=>const BookLore(),memory:()=>const [],
      awaitNarrativeWrites:() async {},files:LocalIllustrationFiles(
        root:() async=>dir),providerFactory:(_)=>image,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    final first=controller.generate(2);
    final second=controller.generate(2);
    await second;
    await Future<void>.delayed(const Duration(milliseconds:20));
    expect(image.calls,1);
    image.gate!.complete(_result());
    await first;
    expect(controller.forIntent(2)?.state,IllustrationJobState.available);
  });

  testWidgets('Image error is visible even before an API job is persisted',
      (tester) async {
    tester.view.physicalSize=const Size(430,1100);
    tester.view.devicePixelRatio=1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final ai=AiConnectionController(store:_NoKeyStore(),provider:_Text());
    addTearDown(ai.dispose);
    await ai.initialize();
    final prefs=ImagePreferences();
    addTearDown(prefs.dispose);
    await prefs.initialize();
    final chat=NarrativeChatController(provider:_Text(),
      configuration:()=>const AiConfiguration(
        baseUrl:'https://api.openuncensored.com/v1',
        model:'text',apiKey:'test'));
    addTearDown(chat.dispose);
    chat.restoreTimeline(const [
      ChatEntry(id:1,speaker:ChatSpeaker.narrator,
        name:'Narrateur',text:'Une scène au quai.'),
      ChatIllustrationIntent(id:2,playerEventId:1,
        description:'Le quai sous le brouillard.'),
    ]);
    final records=_ImageRecords()..timeline=()=>chat.timeline;
    final provider=_Image();
    final images=IllustrationController(
      sessionId:'unconfigured',ai:ai,preferences:prefs,records:records,
      timeline:()=>chat.timeline,lore:()=>const BookLore(),
      memory:()=>const [],awaitNarrativeWrites:() async {},
      files:_MemoryFiles(),providerFactory:(_)=>provider,
    );
    addTearDown(images.dispose);
    await images.initialize();
    var settingsOpened=false;
    await tester.pumpWidget(MaterialApp(theme:DomoliaTheme.dark,
      home:Scaffold(body:GroupChatPage(
        controller:chat,onOpenSettings:(){},illustrations:images,
        onOpenImageSettings:()=>settingsOpened=true,
      ))));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const ValueKey('imagePreparePrompt')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(provider.calls,0);
    expect(find.byKey(const ValueKey('chatIllustrationErrorBanner')),
      findsOneWidget);
    expect(find.textContaining('Choisissez un metteur'),findsWidgets);
    await tester.tap(find.byKey(
      const ValueKey('chatIllustrationOpenSettings')));
    expect(settingsOpened,isTrue);
    await tester.tap(find.byKey(
      const ValueKey('chatIllustrationDismissError')));
    await tester.pump();
    expect(find.byKey(const ValueKey('chatIllustrationErrorBanner')),
      findsNothing);
  });

  testWidgets('Illustrator status follows actual director and image phases',
      (tester) async {
    tester.view.physicalSize=const Size(430,1100);
    tester.view.devicePixelRatio=1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final text=_Text()..gate=Completer<String>();
    final image=_Image()..gate=Completer<ImageGenerationResult>();
    addTearDown(() {
      if (!text.gate!.isCompleted) {
        text.gate!.complete(jsonEncode({
          'prompt':'Un personnage adulte se trouve dans une pièce calme, '
              'debout au centre, regard vers la fenêtre. '
              'Plan moyen, lumière naturelle et douce.',
        }));
      }
      if (!image.gate!.isCompleted) image.gate!.complete(_result());
    });
    final ai=AiConnectionController(store:_Store(),provider:text);
    addTearDown(ai.dispose);
    await ai.initialize();
    final prefs=ImagePreferences();
    addTearDown(prefs.dispose);
    await prefs.initialize();
    await prefs.saveApplication(const ImageGenerationOptions(
      profileId:'image',directorProfileId:'director',model:'test-image'));
    final chat=NarrativeChatController(provider:_Text(),
      configuration:()=>const AiConfiguration(
        baseUrl:'https://api.openuncensored.com/v1',
        model:'text',apiKey:'test'));
    addTearDown(chat.dispose);
    chat.restoreTimeline(const [
      ChatEntry(id:1,speaker:ChatSpeaker.narrator,
        name:'Narrateur',text:'Une scène au quai.'),
      ChatIllustrationIntent(id:2,playerEventId:1,
        description:'Le quai sous le brouillard.'),
    ]);
    final records=_ImageRecords()..timeline=()=>chat.timeline;
    final images=IllustrationController(
      sessionId:'phases',ai:ai,preferences:prefs,records:records,
      timeline:()=>chat.timeline,lore:()=>const BookLore(),
      memory:()=>const [],awaitNarrativeWrites:() async {},
      files:_MemoryFiles(),providerFactory:(_)=>image,
    );
    addTearDown(images.dispose);
    await images.initialize();
    await tester.pumpWidget(MaterialApp(theme:DomoliaTheme.dark,
      home:Scaffold(body:GroupChatPage(
        controller:chat,onOpenSettings:(){},illustrations:images,
      ))));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const ValueKey('imagePreparePrompt')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('chatIllustratorIndicator')),
      findsOneWidget);
    expect(find.text('Illustrateur prépare la mise en scène…'),
      findsOneWidget);
    expect(image.calls,0);
    text.gate!.complete(jsonEncode({
      'prompt':'Un personnage adulte se trouve dans une pièce calme, '
          'debout au centre, regard vers la fenêtre. '
          'Plan moyen, lumière naturelle et douce.',
    }));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('imageApprovePrompt')),findsOneWidget);
    expect(image.calls,0);
    // Director prompts can be longer than a phone viewport. Scroll to the
    // actual confirmation rather than tapping an off-screen control.
    await tester.ensureVisible(find.byKey(const ValueKey('imageApprovePrompt')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('imageApprovePrompt')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.ensureVisible(find.byKey(const ValueKey('imageGenerate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('imageGenerate')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const ValueKey('imageConfirmGenerate')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Illustrateur dessine…'),findsOneWidget);
    expect(image.calls,1);
    image.gate!.complete(_result());
    await tester.pump();
    await tester.pumpAndSettle();
    expect(images.forIntent(2)?.state, IllustrationJobState.available);
    expect(find.byKey(const ValueKey('chatIllustratorIndicator')),
      findsNothing);
    expect(find.byKey(const ValueKey('chatGeneratedImage')),findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test('Prompt is prepared and approved before the image API is used',
      () async {
    final text = _VisualText();
    final ai = AiConnectionController(store:_Store(), provider:text);
    addTearDown(ai.dispose);
    await ai.initialize();
    final preferences = ImagePreferences();
    addTearDown(preferences.dispose);
    await preferences.initialize();
    await preferences.saveApplication(const ImageGenerationOptions(
      profileId:'image', directorProfileId:'director', model:'test-image',
    ));
    final events = <ChatTimelineEvent>[
      const ChatEntry(id:1, speaker:ChatSpeaker.character,
          name:'Boulangère', text:'Bonjour.'),
      const ChatEntry(id:2, speaker:ChatSpeaker.narrator,
          name:'Narrateur', text:'Elle ajuste son tablier.'),
      const ChatIllustrationIntent(id:3, playerEventId:1,
          description:'La boulangère au comptoir.'),
    ];
    final records = _ImageRecords()..timeline = () => events;
    final image = _Image();
    final visualFacts = <LiveMemoryFact>[];
    final controller = IllustrationController(
      sessionId:'prepared', ai:ai, preferences:preferences,
      records:records, timeline:() => events,
      lore:() => const BookLore(), memory:() => visualFacts,
      awaitNarrativeWrites:() async {}, files:_MemoryFiles(),
      providerFactory:(_) => image,
      onAcceptVisualFacts:(facts) async => visualFacts.addAll(facts),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.prepare(3);
    final draft = controller.forIntent(3);
    expect(draft?.state, IllustrationJobState.ready);
    expect(draft?.prompt.toLowerCase(), contains('boulangère'));
    expect(text.calls, 1);
    expect(image.calls, 0);

    // First approval confirms proposed appearance facts in Party memory.
    await controller.approvePrompt(3);
    expect(controller.forIntent(3)?.state, IllustrationJobState.approved);
    expect(visualFacts, hasLength(2));
    expect(visualFacts.where((f) => f.field == 'visual_identity')
        .single.text, 'Cheveux bruns et yeux verts');
    expect(visualFacts.where((f) => f.field == 'visual_current')
        .single.text, 'Tablier beige');
    await controller.editPrompt(3, '${draft!.prompt}\nPlan plus rapproché.');
    expect(controller.forIntent(3)?.state, IllustrationJobState.ready);
    expect(controller.forIntent(3)?.appearanceProposals, isEmpty);
    await controller.approvePrompt(3);
    expect(visualFacts, hasLength(2));
    expect(image.calls, 0);

    await controller.generate(3);
    expect(image.calls, 1);
    expect(text.calls, 1);
    expect(controller.forIntent(3)?.state, IllustrationJobState.available);
    expect(controller.forIntent(3)?.prompt, contains('Plan plus rapproché.'));
  });

  test('Director failures explain the issue and allow preparation retry',
      () async {
    final director = _FailOnceDirector()
      ..nextFailure = const AiProviderException(
        'Aucune réponse du fournisseur sous 25 s.',
        kind: AiProviderErrorKind.timeout,
      );
    final ai = AiConnectionController(store:_Store(), provider:director);
    addTearDown(ai.dispose);
    await ai.initialize();
    final prefs = ImagePreferences();
    addTearDown(prefs.dispose);
    await prefs.initialize();
    await prefs.saveApplication(const ImageGenerationOptions(
      profileId:'image', directorProfileId:'director', model:'test-image',
    ));
    final events = <ChatTimelineEvent>[
      const ChatEntry(id:1, speaker:ChatSpeaker.narrator,
        name:'Narrateur', text:'Un rayon de soleil éclaire la cuisine.'),
      const ChatIllustrationIntent(id:2, playerEventId:1,
        description:'La lumière sur la table.'),
    ];
    final records = _ImageRecords()..timeline = () => events;
    final image = _Image();
    final controller = IllustrationController(
      sessionId:'director-retry', ai:ai, preferences:prefs, records:records,
      timeline:() => events, lore:() => const BookLore(),
      memory:() => const [], awaitNarrativeWrites:() async {},
      files:_MemoryFiles(), providerFactory:(_) => image,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await controller.prepare(2);
    expect(controller.error, contains('Metteur en scène IA'));
    expect(controller.error, contains('25 s'));
    expect(controller.error, isNot(contains('Vérifiez le profil IA')));
    expect(controller.errorIntentId, 2);
    expect(controller.forIntent(2), isNull);
    expect(image.calls, 0);

    await controller.prepare(2);
    expect(controller.error, isNull);
    expect(controller.errorIntentId, isNull);
    expect(controller.forIntent(2)?.state, IllustrationJobState.ready);
    expect(image.calls, 0);
  });

  test('Invalid director JSON and provider errors remain distinguishable',
      () async {
    final director = _FailOnceDirector()..nextText = 'not-json';
    final ai = AiConnectionController(store:_Store(), provider:director);
    addTearDown(ai.dispose);
    await ai.initialize();
    final prefs = ImagePreferences();
    addTearDown(prefs.dispose);
    await prefs.initialize();
    final events = <ChatTimelineEvent>[
      const ChatEntry(id:1, speaker:ChatSpeaker.narrator,
        name:'Narrateur', text:'Une lampe éclaire le salon.'),
      const ChatIllustrationIntent(id:2, playerEventId:1,
        description:'La lampe dans le salon.'),
    ];
    final records = _ImageRecords()..timeline = () => events;
    final image = _Image();
    final controller = IllustrationController(
      sessionId:'director-bad-json', ai:ai, preferences:prefs,
      records:records, timeline:() => events, lore:() => const BookLore(),
      memory:() => const [], awaitNarrativeWrites:() async {},
      files:_MemoryFiles(), providerFactory:(_) => image,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await controller.prepare(2);
    expect(controller.error, contains('Description du metteur en scène invalide'));
    expect(controller.forIntent(2), isNull);
    expect(image.calls, 0);

    director.nextFailure = const AiProviderException(
      'Accès refusé (HTTP 403).',
      kind: AiProviderErrorKind.access,
    );
    await controller.generate(2);
    expect(controller.error, contains('Metteur en scène IA : Accès refusé'));
    expect(controller.error, contains('HTTP 403'));
    expect(image.calls, 0);
  });


  test('Director HTTP exchanges are scoped to illustration and exported',
      () async {
    final recorder = AiExchangeRecorder();
    final narratorExchange = recorder.begin(
      provider:'test',method:'POST',url:'https://example.invalid/chat',
      requestBody:'{"model":"narrator"}',secret:'narrator-secret',
      accept:'application/json',
    );
    final captured = <AiExchange>[];
    final provider = OpenAiCompatibleChatProvider(
      diagnostics:recorder,
      client:MockClient((request) async {
        expect(request.url.path, '/v1/chat/completions');
        expect(request.headers['Authorization'], 'Bearer text-key');
        final requestBody = jsonDecode(request.body) as Map<String,dynamic>;
        expect(requestBody['model'], 'text');
        return http.Response(jsonEncode({'choices':[{'message':{
          'role':'assistant',
          'content':jsonEncode({
            'prompt':'La voisine est debout dans un salon éclairé, '
                'une main appuyée sur la poignée de la porte '
                'qu’elle vient de fermer. Plan moyen de trois quarts.',
          }),
        }}]}), 200, headers: {
          'content-type': 'application/json; charset=utf-8',
        });
      }),
    );
    final ai = AiConnectionController(store:_Store(), provider:provider);
    addTearDown(ai.dispose);
    await ai.initialize();
    final prefs = ImagePreferences();
    addTearDown(prefs.dispose);
    await prefs.initialize();
    await prefs.saveApplication(const ImageGenerationOptions(
      profileId:'image', directorProfileId:'director',
    ));
    final events = <ChatTimelineEvent>[
      const ChatEntry(id:1, speaker:ChatSpeaker.player,
        name:'Vous', text:'Je regarde ma voisine.'),
      const ChatIllustrationIntent(id:2, playerEventId:1,
        description:'Ma voisine ferme la porte du salon.'),
    ];
    final records = _ImageRecords()..timeline = () => events;
    final controller = IllustrationController(
      sessionId:'director-capture',ai:ai,preferences:prefs,
      records:records,timeline:()=>events,
      lore:()=>const BookLore(),memory:()=>const [],
      awaitNarrativeWrites:() async {},files:_MemoryFiles(),
      diagnostics:recorder,onExchangeCaptured:captured.add,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.prepare(2);

    expect(controller.error, isNull);
    expect(controller.forIntent(2)?.state, IllustrationJobState.ready);
    expect(captured, hasLength(1));
    expect(captured.single.stage, 'image_direction');
    expect(captured.single.playerEventId, 1);
    expect(captured.single.statusCode, 200);
    expect(captured.single.completedAtUtc, isNotNull);
    expect(captured.single.toJson()['request']['body']['model'], 'text');
    expect(captured.single.toJson()['response']['rawBody'],
      contains('prompt'));
    expect(recorder.last, same(narratorExchange));
    expect(captured.single.exportJson(), isNot(contains('text-key')));
  });

  test('Director HTTP failure is captured with original status', () async {
    final recorder = AiExchangeRecorder();
    final captured = <AiExchange>[];
    final provider = OpenAiCompatibleChatProvider(
      diagnostics:recorder,
      client:MockClient((_) async => http.Response(
        '{"error":{"message":"text-key"}}', 504)),
    );
    final ai = AiConnectionController(store:_Store(), provider:provider);
    addTearDown(ai.dispose);
    await ai.initialize();
    final prefs = ImagePreferences();
    addTearDown(prefs.dispose);
    await prefs.initialize();
    await prefs.saveApplication(const ImageGenerationOptions(
      profileId:'image', directorProfileId:'director',
    ));
    final events = <ChatTimelineEvent>[
      const ChatEntry(id:1,speaker:ChatSpeaker.player,
        name:'Vous',text:'Je regarde.'),
      const ChatIllustrationIntent(id:2,playerEventId:1,
        description:'La fenêtre derrière ma voisine.'),
    ];
    final records = _ImageRecords()..timeline = () => events;
    final controller = IllustrationController(
      sessionId:'director-error',ai:ai,preferences:prefs,
      records:records,timeline:()=>events,lore:()=>const BookLore(),
      memory:()=>const [],awaitNarrativeWrites:() async {},
      files:_MemoryFiles(),diagnostics:recorder,
      onExchangeCaptured:captured.add,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.prepare(2);
    expect(controller.error, contains('délai dépassé'));
    expect(captured, hasLength(1));
    expect(captured.single.stage, 'image_direction');
    expect(captured.single.statusCode, 504);
    expect(captured.single.toJson()['interpretation']['error'],
      contains('délai dépassé'));
    expect(captured.single.exportJson(), isNot(contains('text-key')));
  });

}
