/// On-device GGUF models supported by Domolia.
///
/// Each entry defines the exact upstream artifact and the required chat
/// template. Models are deliberately allowlisted; arbitrary download URLs
/// cannot be provided by book content or untrusted prompts.
enum LocalPromptFormat { chatMl, mistralInst }

class LocalModelVariant {
  const LocalModelVariant({
    required this.id,
    required this.name,
    required this.filename,
    required this.bytes,
    required this.repository,
    required this.modelId,
    required this.format,
    required this.storageFolder,
    this.sha256,
    this.contextTokens = 2048,
  });

  final String id;
  final String name;
  final String filename;
  final int bytes;
  final String repository;
  final String modelId;
  final LocalPromptFormat format;
  final String storageFolder;
  /// Official upstream digest, when published and verified.
  final String? sha256;
  /// Validated native context baseline; no increase without device testing.
  final int contextTokens;

  String get downloadUrl =>
      'https://huggingface.co/$repository/resolve/main/$filename';
}

const localModelVariants = <LocalModelVariant>[
  LocalModelVariant(
    id: 'qwen2.5-1.5b-instruct-q4-k-m',
    name: 'Qwen2.5 1.5B Instruct — Q4_K_M (conseillé, 1,12 Go)',
    filename: 'qwen2.5-1.5b-instruct-q4_k_m.gguf',
    bytes: 1117320736,
    repository: 'Qwen/Qwen2.5-1.5B-Instruct-GGUF',
    modelId: 'qwen2.5-1.5b-instruct',
    format: LocalPromptFormat.chatMl,
    storageFolder: 'qwen2.5',
    sha256: '6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e',
  ),
  // IDs and storage folder intentionally unchanged: existing installations
  // are detected without redownloading large Ministral files.
  LocalModelVariant(
    id: 'ministral-3-3b-q4',
    name: 'Ministral 3 3B — Q4_K_M (2,15 Go)',
    filename: 'Ministral-3-3B-Instruct-2512-Q4_K_M.gguf',
    bytes: 2147023008,
    repository: 'mistralai/Ministral-3-3B-Instruct-2512-GGUF',
    modelId: 'ministral-3-3b-instruct-2512',
    format: LocalPromptFormat.mistralInst,
    storageFolder: 'ministral',
  ),
  LocalModelVariant(
    id: 'ministral-3-3b-q5',
    name: 'Ministral 3 3B — Q5_K_M (2,47 Go)',
    filename: 'Ministral-3-3B-Instruct-2512-Q5_K_M.gguf',
    bytes: 2474178720,
    repository: 'mistralai/Ministral-3-3B-Instruct-2512-GGUF',
    modelId: 'ministral-3-3b-instruct-2512',
    format: LocalPromptFormat.mistralInst,
    storageFolder: 'ministral',
  ),
];
