/// Curated GGUF downloads. The estimated sizes are the weight files only;
/// runtime memory (including context buffers) is additional.
class LocalModelSpec {
  const LocalModelSpec({
    required this.id,
    required this.name,
    required this.repository,
    required this.remoteFile,
    required this.estimatedBytes,
    this.experimental = true,
    this.pinnedSha256,
  });

  final String id;
  final String name;
  final String repository;
  final String remoteFile;
  final int estimatedBytes;
  final bool experimental;
  /// When available, a checksum pinned in the application source.
  final String? pinnedSha256;

  String get url =>
      'https://huggingface.co/$repository/resolve/main/$remoteFile';
  String get sourceUrl => 'https://huggingface.co/$repository';
  String get fileName => '$id.gguf';

  /// Reject HTML, incomplete uploads and anomalously large downloads.
  int get minimumBytes => (estimatedBytes * 0.80).round();
  int get maximumBytes => (estimatedBytes * 1.25).round();
}

class LocalModelCatalog {
  static const models = <LocalModelSpec>[
    LocalModelSpec(
      id: 'qwen35-2b-q4km',
      name: 'Qwen 3.5 2B — Q4_K_M (~1,3 Go)',
      repository: 'SoAIHQ/Qwen3.5-2B-GGUF',
      remoteFile: 'Qwen3.5-2B-Q4_K_M.gguf',
      estimatedBytes: 1310000000,
    ),
    LocalModelSpec(
      id: 'ministral3-3b-q4km',
      name: 'Ministral 3 3B — Q4_K_M (~2,2 Go)',
      repository: 'bartowski/mistralai_Ministral-3-3B-Instruct-2512-GGUF',
      remoteFile: 'mistralai_Ministral-3-3B-Instruct-2512-Q4_K_M.gguf',
      estimatedBytes: 2150000000,
    ),
    LocalModelSpec(
      id: 'qwen35-4b-q4km',
      name: 'Qwen 3.5 4B — Q4_K_M (~2,8 Go)',
      repository: 'SoAIHQ/Qwen3.5-4B-GGUF',
      remoteFile: 'Qwen3.5-4B-Q4_K_M.gguf',
      estimatedBytes: 2800000000,
    ),
    // Legacy smoke-test model retained to support earlier local prototypes.
    LocalModelSpec(
      id: 'qwen3-0.6b-uncensored-q4km',
      name: 'Qwen 3 0.6B Uncensored — Q4_K_M (~0,4 Go)',
      repository: 'Null-Guard/Qwen3-0.6B-Uncensored-GGUF',
      remoteFile: 'model-Q4_K_M.gguf',
      estimatedBytes: 430000000,
      experimental: true,
      pinnedSha256:
          '9f32e486dd220100dd4fe8762ca798df56f8b030782bcd4ee1f4acf4f0c1838a',
    ),
  ];

  static LocalModelSpec byId(String id) => models.firstWhere(
        (model) => model.id == id,
        orElse: () => throw ArgumentError.value(
            id, 'id', 'Modèle local non répertorié'),
      );
}
