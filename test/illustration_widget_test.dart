import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:domolia/ai/ai_controller.dart';
import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/books/book_lore.dart';
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
      'shot':'medium','angle':'eye_level','focusIds':[],
      'composition':'rule_of_thirds','lighting':'soft',
      'palette':'muted','mood':'calm',
      'visualSubject':'Un personnage dans le décor',
      'visualAction':'Le personnage observe les lieux',
      'visualSetting':'Un intérieur calme',
    });
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
      'shot':'medium', 'angle':'eye_level',
      'focusIds':['party:boulangere'],
      'composition':'centered', 'lighting':'soft',
      'palette':'warm', 'mood':'calm',
      'visualSubject':'La boulangère au comptoir',
      'visualAction':'Elle ajuste son tablier',
      'visualSetting':'Une boulangerie',
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
    expect(request.model,'test-image');
    expect(request.prompt,contains('Sujet visible :'));
    expect(request.prompt,isNot(contains('Texte établi :')));
    expect(request.prompt,isNot(contains('Mémoire confirmée :')));
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
    await tester.ensureVisible(find.byKey(const ValueKey('chatGeneratedImage')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chatGeneratedImage')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('imagePromptExport')),findsOneWidget);
    expect(find.byTooltip('Exporter le prompt (JSON)'),findsOneWidget);
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
          'shot':'medium','angle':'eye_level','focusIds':[],
          'composition':'rule_of_thirds','lighting':'soft',
          'palette':'muted','mood':'calm',
      'visualSubject':'Un personnage dans le décor',
      'visualAction':'Le personnage observe les lieux',
      'visualSetting':'Un intérieur calme',
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
      'shot':'medium','angle':'eye_level','focusIds':[],
      'composition':'rule_of_thirds','lighting':'soft',
      'palette':'muted','mood':'calm',
      'visualSubject':'Un personnage dans le décor',
      'visualAction':'Le personnage observe les lieux',
      'visualSetting':'Un intérieur calme',
    }));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('imageApprovePrompt')),findsOneWidget);
    expect(image.calls,0);
    await tester.tap(find.byKey(const ValueKey('imageApprovePrompt')));
    await tester.pump(const Duration(milliseconds: 200));
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
    expect(draft?.prompt, contains('Boulangère'));
    expect(text.calls, 1);
    expect(image.calls, 0);

    await controller.editPrompt(3, '${draft!.prompt}\nPlan plus rapproché.');
    expect(controller.forIntent(3)?.state, IllustrationJobState.ready);
    await controller.approvePrompt(3);
    expect(controller.forIntent(3)?.state, IllustrationJobState.approved);
    expect(visualFacts, hasLength(2));
    expect(visualFacts.where((f) => f.field == 'visual_identity')
        .single.text, 'Cheveux bruns et yeux verts');
    expect(visualFacts.where((f) => f.field == 'visual_current')
        .single.text, 'Tablier beige');
    expect(image.calls, 0);

    await controller.generate(3);
    expect(image.calls, 1);
    expect(text.calls, 1);
    expect(controller.forIntent(3)?.state, IllustrationJobState.available);
    expect(controller.forIntent(3)?.prompt, contains('Plan plus rapproché.'));
  });

}
