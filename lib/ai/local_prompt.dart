import 'ai_provider.dart';
import 'local_model_catalog.dart';

/// Serialize text turns using the installed GGUF's own chat markers.
class LocalPrompt {
  static String format(LocalModelVariant model, List<AiMessage> messages) =>
      switch (model.format) {
        LocalPromptFormat.chatMl => _chatMl(messages),
        LocalPromptFormat.mistralInst => _mistral(messages),
      };

  static String _chatMl(List<AiMessage> messages) {
    if (!messages.any((message) => message.role == 'user')) {
      throw const FormatException('Aucun message utilisateur.');
    }
    final buffer = StringBuffer();
    for (final message in messages) {
      if (!const {'system', 'user', 'assistant'}.contains(message.role)) continue;
      buffer.write('<|im_start|>${message.role}\n');
      buffer.write(message.content);
      buffer.write('<|im_end|>\n');
    }
    buffer.write('<|im_start|>assistant\n');
    return buffer.toString();
  }

  static String _mistral(List<AiMessage> messages) {
    final system = messages.where((m) => m.role == 'system')
        .map((m) => m.content).join('\n\n');
    final buffer = StringBuffer('<s>');
    if (system.isNotEmpty) {
      buffer.write('[SYSTEM_PROMPT]');
      buffer.write(system);
      buffer.write('[/SYSTEM_PROMPT]');
    }
    var hasUser = false;
    for (final message in messages) {
      if (message.role == 'system') continue;
      if (message.role == 'user') {
        buffer.write('[INST]');
        buffer.write(message.content);
        buffer.write('[/INST]');
        hasUser = true;
      } else if (message.role == 'assistant') {
        buffer.write(message.content);
        buffer.write('</s>');
      }
    }
    if (!hasUser) throw const FormatException('Aucun message utilisateur.');
    return buffer.toString();
  }
}
