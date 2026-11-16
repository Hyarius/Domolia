import 'package:material_ui/material_ui.dart';

import '../theme/domolia_theme.dart';
import 'live_memory.dart';
import 'live_memory_coordinator.dart';

/// A Party-only reader/editor. It does not expose Book canon authoring.
class LiveMemoryPage extends StatefulWidget {
  const LiveMemoryPage({
    super.key, required this.memory, required this.onBack,
  });

  final LiveMemoryCoordinator memory;
  final VoidCallback onBack;

  @override
  State<LiveMemoryPage> createState() => _LiveMemoryPageState();
}

class _LiveMemoryPageState extends State<LiveMemoryPage> {
  bool _loading = true;
  bool _working = false;
  String? _error;
  String _query = '';
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    widget.memory.addListener(_changed);
    _load();
  }

  @override
  void didUpdateWidget(covariant LiveMemoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.memory != widget.memory) {
      oldWidget.memory.removeListener(_changed);
      widget.memory.addListener(_changed);
      _load();
    }
  }

  void _changed() {
    if (mounted) { setState(() {}); }
  }

  Future<void> _load() async {
    try {
      await widget.memory.refresh();
      if (mounted) { setState(() { _loading = false; _error = null; }); }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Impossible de charger la mémoire.';
        });
      }
    }
  }

  @override
  void dispose() {
    widget.memory.removeListener(_changed);
    super.dispose();
  }

  void _notice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(text)));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await action();
    } catch (_) {
      _notice('Modification de mémoire impossible.');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _edit(LiveMemoryFact fact) async {
    final input = TextEditingController(text: fact.text);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Corriger : ${fact.label}'),
        content: TextField(
          key: const ValueKey('memoryCorrectionText'),
          controller: input,
          maxLength: 800,
          maxLines: 5,
          decoration: const InputDecoration(
            labelText: 'Fait corrigé',
            helperText: 'La correction sera conservée lors des retours arrière.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
              child: const Text('Annuler')),
          FilledButton(onPressed: () =>
              Navigator.pop(context, input.text.trim()),
              child: const Text('Enregistrer')),
        ],
      ),
    );
    input.dispose();
    if (value != null && value.isNotEmpty) {
      await _run(() => widget.memory.overrideFact(fact, text: value));
    }
  }

  Future<void> _remove(LiveMemoryFact fact) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer ce souvenir ?'),
        content: const Text('Une suppression manuelle restera effective '
            'même si la mémoire est reconstruite.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Supprimer')),
        ],
      ),
    );
    if (yes == true) await _run(() => widget.memory.deleteFact(fact));
  }

  Future<void> _rebuild() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Réanalyser la Partie ?'),
        content: const Text('Cette opération relit les tours RAW validés '
            'et entraîne de nouveaux appels IA payants. Les corrections, '
            'protections et suppressions manuelles seront conservées.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Réanalyser')),
        ],
      ),
    );
    if (yes == true) await _run(widget.memory.rebuild);
  }

  Widget _factTile(LiveMemoryFact fact) => Card(
    child: ExpansionTile(
      key: ValueKey('memoryFact-${fact.id}'),
      title: Text(fact.label),
      subtitle: Text(fact.text, maxLines: 2,
          overflow: TextOverflow.ellipsis),
      leading: Icon(fact.pinned ? Icons.push_pin : Icons.bookmark_outline,
          color: DomoliaColors.gold),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(fact.text),
              const SizedBox(height: 8),
              Text('Statut : ${fact.certainty} · ${fact.kind} · '
                  '${fact.visibility}',
                  style: const TextStyle(color: DomoliaColors.muted)),
              Text('Source : tour ${fact.sourceTurnId} '
                  '(${fact.sourceSide})',
                  style: const TextStyle(color: DomoliaColors.muted)),
              Text('« ${fact.sourceQuote} »',
                  style: const TextStyle(color: DomoliaColors.muted)),
              if (fact.loreId != null)
                Text('Référence canonique : ${fact.loreId}',
                    style: const TextStyle(color: DomoliaColors.muted)),
              Wrap(spacing: 8, runSpacing: 6, children: [
                TextButton.icon(
                  onPressed: _working ? null :
                      () => _run(() => widget.memory.overrideFact(fact,
                        pinned: !fact.pinned)),
                  icon: Icon(fact.pinned
                      ? Icons.lock_open : Icons.lock_outline),
                  label: Text(fact.pinned ? 'Déprotéger' : 'Protéger'),
                ),
                TextButton.icon(
                  key: ValueKey('memoryEdit-${fact.id}'),
                  onPressed: _working ? null : () => _edit(fact),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Corriger'),
                ),
                TextButton.icon(
                  onPressed: _working ? null : () => _remove(fact),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Supprimer'),
                ),
              ]),
            ],
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    const categories = <String, String>{
      'state': 'État courant',
      'character': 'Personnages',
      'place': 'Lieux',
      'object': 'Objets',
      'event': 'Événements',
      'relationship': 'Relations',
      'commitment': 'Promesses et objectifs',
    };
    final facts = widget.memory.facts.where((fact) {
      if (_filter != 'all' && fact.certainty != _filter) return false;
      final needle = _query.toLowerCase();
      return '${fact.label} ${fact.text} ${fact.category} '
          '${fact.entityId}'.toLowerCase().contains(needle);
    }).toList();
    return SafeArea(
      child: ListView(
        key: const ValueKey('liveMemoryPage'),
        padding: const EdgeInsets.all(20),
        children: [
          Row(children: [
            IconButton(onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back)),
            const Expanded(child: Text('Mémoire de la Partie',
                style: TextStyle(fontSize: 21,
                    color: DomoliaColors.goldLight))),
          ]),
          const SizedBox(height: 8),
          const Text('Souvenirs de cette aventure uniquement. '
              'Le Lore du Livre demeure canonique.',
              style: TextStyle(color: DomoliaColors.muted)),
          const SizedBox(height: 16),
          Text(widget.memory.processing ? 'Extraction en cours…' :
              widget.memory.pendingCount == 0
                ? 'Mémoire à jour'
                : '${widget.memory.pendingCount} tour(s) à analyser',
              key: const ValueKey('memoryStatus')),
          if (widget.memory.error != null)
            Text(widget.memory.error!,
                style: const TextStyle(color: DomoliaColors.goldLight)),
          if (_error != null) Text(_error!),
          if (_loading) const LinearProgressIndicator(),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              key: const ValueKey('memoryRetry'),
              onPressed: _working ? null :
                () => _run(widget.memory.analyzePending),
              icon: const Icon(Icons.sync),
              label: const Text('Analyser les tours en attente'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('memoryRebuild'),
              onPressed: _working ? null : _rebuild,
              icon: const Icon(Icons.restart_alt),
              label: const Text('Reconstruire'),
            ),
          ]),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('memorySearch'),
            onChanged: (value) => setState(() => _query = value),
            decoration: const InputDecoration(
              labelText: 'Rechercher un souvenir',
              prefixIcon: Icon(Icons.search),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: const ValueKey('memoryCertaintyFilter'),
            initialValue: _filter,
            decoration: const InputDecoration(labelText: 'Fiabilité'),
            items: const [
              DropdownMenuItem(value: 'all', child: Text('Toutes')),
              DropdownMenuItem(value: 'confirmed', child: Text('Confirmées')),
              DropdownMenuItem(value: 'reported', child: Text('Rapportées')),
              DropdownMenuItem(value: 'uncertain', child: Text('Incertaines')),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _filter = value);
            },
          ),
          const SizedBox(height: 16),
          if (!_loading && facts.isEmpty)
            const Text('Aucun souvenir correspondant.',
                key: ValueKey('memoryEmpty')),
          for (final category in categories.entries)
            if (facts.any((f) => f.category == category.key))
              ExpansionTile(
                key: ValueKey('memoryCategory-${category.key}'),
                initiallyExpanded: category.key == 'state',
                title: Text(category.value),
                subtitle: Text('${facts.where((f) =>
                    f.category == category.key).length} souvenirs'),
                children: [
                  for (final fact in facts.where((f) =>
                      f.category == category.key))
                    _factTile(fact),
                ],
              ),
        ],
      ),
    );
  }
}
