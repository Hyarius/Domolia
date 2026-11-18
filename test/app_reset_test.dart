import 'dart:io';

import 'package:domolia/books/book_definition.dart';
import 'package:domolia/books/book_session.dart';
import 'package:domolia/books/book_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/ai/openuncensored_api.dart';
import 'package:domolia/ai/openuncensored_vault.dart';
import 'package:domolia/illustration/image_preferences.dart';
import 'package:domolia/settings/app_reset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Profiles implements AiProfileStore {
  _Profiles(this.state, this.events, {this.failWrite = false});
  AiProfilesState? state;
  final List<String> events;
  final bool failWrite;

  @override
  Future<AiProfilesState?> read() async => state;

  @override
  Future<void> write(AiProfilesState next) async {
    events.add('profiles');
    if (failWrite) throw StateError('Storage unavailable');
    state = next;
  }
}

class _Vault implements OuVaultStore {
  _Vault(this.state, this.events);
  OuVaultState state;
  final List<String> events;

  @override
  Future<OuVaultState> read() async => state;

  @override
  Future<void> write(OuVaultState next) async {
    events.add('vault');
    state = next;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'domolia.narrator.settings.v1': 'old narrator',
      'domolia.image.settings.v1': 'old image connection',
      'domolia.image.party.partie-1': 'old image override',
      'aiTaskNarratorProfileId': 'external',
      'aiTaskGeneration-narrator': 'old budget',
      'aiTaskMemoryProfileId': '#disabled',
      'aiDiagnosticsRetentionPerSession': 50,
      'updateChannel': 'dev-latest',
      'automaticUpdates': false,
      // Unknown future preferences and persistent user data are never erased.
      'unrelatedPersistentData': 'keep this',
      'libraryBookDraft': 'keep this too',
    });
  });

  test('Reset touches only settings and preserves keys, balances and history',
      () async {
    final events = <String>[];
    const ouKey = 'ou-cus_KEEP_THIS_KEY_123456';
    const otherKey = 'sk-another-api-key';
    final id = ouKeyId(ouKey);
    final vault = _Vault(OuVaultState(
      keys: [
        StoredOuKey(
          id: id, secret: ouKey,
          addedAt: DateTime.utc(2026, 11, 1), name: 'Ma clé',
          lastBalance: const OuBalance(
            remainingUsd: 9, balanceUsd: 9, pendingUsd: 0),
        ),
      ],
      activeKeyId: id,
      mode: 'advanced',
      models: const {'narrator': 'old-model'},
      toolChecks: const {'abc': 'supported'},
    ), events);
    final profiles = _Profiles(const AiProfilesState(
      profiles: [
        AiProfile(
          id: 'default', name: 'Ancien réglage',
          baseUrl: defaultAiBaseUrl,
          model: 'old-model', apiKey: ouKey,
        ),
        AiProfile(
          id: 'external', name: 'Autre fournisseur',
          baseUrl: 'https://api.example.org/v1',
          model: 'custom-model', apiKey: otherKey,
        ),
        AiProfile(
          id: 'chatgpt', name: 'ChatGPT',
          baseUrl: 'https://api.openai.com/v1',
          model: 'gpt', apiKey: '',
          kind: AiProviderKind.chatGpt,
        ),
      ],
      selectedId: 'external',
    ), events);

    await AppResetService(profiles: profiles, vault: vault).reset();

    expect(events, ['profiles', 'vault']);
    expect(vault.state.keys.single.secret, ouKey);
    expect(vault.state.keys.single.name, 'Ma clé');
    expect(vault.state.keys.single.lastBalance!.balanceUsd, 9);
    expect(vault.state.activeKeyId, id);
    expect(vault.state.pending, isNull);
    expect(vault.state.mode, 'balanced');
    expect(vault.state.models, isEmpty);
    expect(vault.state.toolChecks, isEmpty);

    expect(profiles.state!.selectedId, 'default');
    final saved = profiles.state!.profiles;
    expect(saved.first.apiKey, ouKey);
    expect(saved.first.model, defaultAiModel);
    expect(saved.map((p) => p.id), ['default', 'external', 'chatgpt']);
    expect(saved[1].apiKey, otherKey);
    final auto = const ImageGenerationOptions()
        .resolveProfiles(saved);
    expect(auto.profileId, 'default');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('domolia.narrator.settings.v1'), isNull);
    expect(prefs.getString('domolia.image.settings.v1'), isNull);
    expect(prefs.getString('domolia.image.party.partie-1'), isNull);
    expect(prefs.getString('aiTaskNarratorProfileId'), isNull);
    expect(prefs.getString('aiTaskGeneration-narrator'), isNull);
    expect(prefs.getString('aiTaskMemoryProfileId'), isNull);
    expect(prefs.getInt('aiDiagnosticsRetentionPerSession'), isNull);
    expect(prefs.getString('updateChannel'), isNull);
    expect(prefs.getBool('automaticUpdates'), isNull);
    expect(prefs.getString('unrelatedPersistentData'), 'keep this');
    expect(prefs.getString('libraryBookDraft'), 'keep this too');
  });

  test('A different key in the default profile survives a profile collision',
      () async {
    final events = <String>[];
    const ouKey = 'ou-cus_ACTIVE_KEY_123456';
    const externalKey = 'sk-special-default-key';
    final vault = _Vault(OuVaultState(keys: [
      StoredOuKey(
        id: ouKeyId(ouKey), secret: ouKey,
        addedAt: DateTime.utc(2026, 11, 1),
      ),
    ], activeKeyId: ouKeyId(ouKey)), events);
    final profiles = _Profiles(const AiProfilesState(
      selectedId: 'default',
      profiles: [
        AiProfile(
          id: 'default', name: 'Autre fournisseur',
          baseUrl: 'https://api.example.org/v1',
          model: 'custom', apiKey: externalKey,
        ),
        AiProfile(
          id: 'retained-default-0', name: 'Profil déjà présent',
          baseUrl: defaultAiBaseUrl,
          model: 'another', apiKey: ouKey,
        ),
      ],
    ), events);
    final reset = AppResetService(profiles: profiles, vault: vault);
    await reset.reset();
    expect(profiles.state!.selectedId, 'default');
    expect(profiles.state!.profiles.first.apiKey, ouKey);
    expect(profiles.state!.profiles.map((p) => p.apiKey),
        contains(externalKey));
    expect(profiles.state!.profiles.map((p) => p.id).toSet().length,
        profiles.state!.profiles.length);
    await reset.reset();
    expect(profiles.state!.profiles.where(
        (profile) => profile.apiKey == externalKey), hasLength(1));
  });

  test('Pending OpenUncensored checkout blocks all writes', () async {
    final events = <String>[];
    final vault = _Vault(OuVaultState(
      pending: PendingOuCheckout(
        sessionId: 'checkout', claimToken: 'claim',
        paymentUrl: Uri.parse('https://example.org/checkout'),
        cents: 1000, startedAt: DateTime.utc(2026, 11, 18),
      ),
    ), events);
    final profiles = _Profiles(null, events);
    await expectLater(
      AppResetService(vault: vault, profiles: profiles).reset(),
      throwsA(isA<StateError>()),
    );
    expect(events, isEmpty);
    expect((await SharedPreferences.getInstance())
        .getString('domolia.image.settings.v1'), 'old image connection');
  });

  test('Secure profile write failure cannot erase local settings', () async {
    final events = <String>[];
    final profiles = _Profiles(null, events, failWrite: true);
    await expectLater(
      AppResetService(
        vault: _Vault(const OuVaultState(), events),
        profiles: profiles,
      ).reset(),
      throwsA(isA<StateError>()),
    );
    expect(events, ['profiles']);
    expect((await SharedPreferences.getInstance())
        .getString('domolia.narrator.settings.v1'), 'old narrator');
  });

  test('A real SQLite Book, Party and local image survive the reset',
      () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp
        .createTemp('domolia-settings-reset-');
    final dbPath = '${directory.path}/domolia.sqlite';
    final image = File('${directory.path}/existing-illustration.png');
    await image.writeAsBytes([137, 80, 78, 71]);
    final original = SqliteBookStore(
      factory: databaseFactoryFfi, databasePath: dbPath,
    );
    addTearDown(() async {
      await original.close();
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    const book = BookDefinition(id: 'book-keep', title: 'Mon Livre');
    const session = BookSession(
      id: 'party-keep', bookId: 'book-keep', title: 'Ma Partie',
    );
    await original.putBook(book);
    await original.putSession(session);

    final order = <String>[];
    await AppResetService(
      profiles: _Profiles(null, order),
      vault: _Vault(const OuVaultState(), order),
    ).reset();

    expect((await original.findBook(book.id))?.title, 'Mon Livre');
    expect((await original.findSession(session.id))?.title, 'Ma Partie');
    expect(await image.exists(), isTrue);
    await original.close();
    final reopened = SqliteBookStore(
      factory: databaseFactoryFfi, databasePath: dbPath,
    );
    try {
      expect((await reopened.findBook(book.id))?.title, 'Mon Livre');
      expect((await reopened.findSession(session.id))?.bookId, book.id);
      expect(await image.readAsBytes(), [137, 80, 78, 71]);
    } finally {
      await reopened.close();
    }
  });

  test('Without credentials, reset produces the standard OpenUncensored setup',
      () async {
    final events = <String>[];
    final profiles = _Profiles(null, events);
    await AppResetService(
      vault: _Vault(const OuVaultState(), events),
      profiles: profiles,
    ).reset();
    expect(profiles.state!.selectedId, 'default');
    expect(profiles.state!.profiles.single.baseUrl, defaultAiBaseUrl);
    expect(profiles.state!.profiles.single.apiKey, isEmpty);
    expect(profiles.state!.profiles.single.model, defaultAiModel);
  });
}
