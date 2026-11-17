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

class _Text implements AiChatProvider {
  @override
  Future<List<AiModel>> listModels(AiConfiguration configuration) async => [];
  @override
  Future<String> complete(AiConfiguration configuration, {
    required List<AiMessage> messages, int maxTokens = 300,
  }) async => jsonEncode({
    'shot':'medium','angle':'eye_level','focusIds':[],
    'composition':'rule_of_thirds','lighting':'soft',
    'palette':'muted','mood':'calm',
  });
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

class _ImageRecords implements IllustrationRecordStore {
  final Map<String,StoredIllustration> jobs={};
  List<ChatTimelineEvent> Function()? timeline;
  @override
  Future<List<StoredIllustration>> listIllustrations(String sessionId) async =>
    jobs.values.toList();
  @override
  Future<bool> saveIllustrationIfCurrent(StoredIllustration record) async {
    if (!(timeline?.call().whereType<ChatIllustrationIntent>()
      .any((e)=>e.id==record.intentId) ?? false)) return false;
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
    final dir=await Directory.systemTemp.createTemp('domolia-slot-widget-');
    addTearDown(()=>dir.delete(recursive:true));
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
      files:LocalIllustrationFiles(root:() async=>dir),
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
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatIllustrateLastScene')),
      findsOneWidget);
    expect(find.byKey(const ValueKey('imageGenerate')),findsOneWidget);
    expect(image.calls,0);
    await tester.tap(find.byKey(const ValueKey('imageGenerate')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('imageConfirmGenerate')),
      findsOneWidget);
    expect(image.calls,0);
    await tester.tap(find.text('Annuler').last);
    await tester.pumpAndSettle();
    expect(image.calls,0);
    await tester.tap(find.byKey(const ValueKey('imageGenerate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('imageConfirmGenerate')));
    await tester.pumpAndSettle();
    expect(image.calls,1);
    expect(find.byKey(const ValueKey('chatGeneratedImage')),findsOneWidget);
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
}
