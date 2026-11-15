import '../ai/ai_diagnostics.dart';
import '../ai/ai_provider.dart';
import '../ai/ai_storage.dart';
import '../ai/chatgpt_auth.dart';
import '../ai/chatgpt_responses.dart';
import '../books/book_store.dart';
import '../updates/update_service.dart';
import '../updates/update_io.dart' as android_updates;

BookStore createProductionBookStore() => SqliteBookStore();

AiProfileStore createProductionAiProfileStore() => SecureAiProfileStore();

ChatGptAccountService? createProductionChatGptAccountService() =>
    ChatGptAuthService(store: SecureChatGptSessionStore());

AiChatProvider? createProductionChatGptProvider(
  AiExchangeRecorder diagnostics,
) => ChatGptResponsesProvider(diagnostics: diagnostics);

UpdateController createProductionUpdateController() =>
    android_updates.createProductionUpdateController();
