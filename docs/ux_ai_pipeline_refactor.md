# Domolia — Navigation simplifiée et traces IA

## Navigation

La navigation principale privilégie trois destinations : **Accueil**, **Livres**,
**Paramètres**. Une Partie ou un éditeur de Livre masque cette navigation pour
laisser la place au contenu et conserve un bouton Retour.

Les paramètres de l'application sont répartis en trois onglets :
- **IA** : profils, générations d'images, crédits.
- **Application** : mises à jour et informations.
- **Diagnostic** : journal, rétention des traces IA et réinitialisation.

Les paramètres d'une Partie possèdent deux onglets :
- **Partie** : narrateur, illustrations, mémoire, options avancées.
- **Historique et traces** : consommation, exports et diagnostics.

Les capacités et vérifications techniques d'un profil IA sont repliées dans
« Compatibilité et tests avancés », sans être supprimées.

## Passes du pipeline IA

| Étape | Déclencheur | Entrée | Sortie et contrat |
| --- | --- | --- | --- |
| Narrateur | Message du joueur | Lore, état de la Partie, mémoire, derniers tours, style et rythme | Script théâtral avec marqueurs contrôlés `[NARRATION]`, `[PERSONNAGE:...]`, `[SCENE]`, parfois `[IMAGE]` |
| Consultation d'outils (optionnelle) | Besoin du narrateur et modèle compatible | Recherche locale de Lore / historique / mémoire | Données de contexte ; les éventuels tours HTTP supplémentaires sont tracés séparément |
| JSONificateur (ancien pipeline uniquement) | Conversion d'une réponse RAW ancienne | Parties RAW indexées sans modifier le texte | JSON `events` et éventuellement `compact` |
| Mémoire automatique (optionnelle) | Tour narratif confirmé | Message joueur, RAW validé et mémoire existante | JSON `operations` factuelles ; aucune hypothèse confirmée |
| Sélection de scène (locale, **sans appel IA**) | Intention d'illustration | Historique borné, Lore et mémoire confirmée | `VisualScene` avec instant à illustrer et preuves |
| Direction d'image | Préparation d'une illustration | `VisualScene`, style visuel et exclusions | JSON `prompt`, `negativePrompt`, `appearances` facultatif |
| Génération d'image | Validation de l'illustration | Prompt final et configuration du modèle | Image et métadonnées du fournisseur |
| Couverture de Livre | Action explicite de l'utilisateur | Lore du Livre et préférences graphiques | Image de couverture |
| Compaction du Lore (ancienne/optionnelle) | Optimisation explicite | Lore canonique complet | Fiche textuelle bornée, jamais autoritaire face au Livre |

**État actuel de la mise en scène :** l'extraction de scène est locale ; elle
n'est pas encore une passe de modèle IA distincte. Une extraction IA dédiée
nécessitera une évolution séparée du pipeline et de ses tests de fidélité.

## Traces d'appels

- Chaque échange enregistré au niveau des transports IA ajoute un
  **début d'appel** dans le journal local, même hors Partie (couverture, tests de connexion).
- Une fois la passe terminée, le journal reçoit un **résultat** : fournisseur,
  étape, identifiant de l'échange, ID de tour s'il existe, code HTTP, durée,
  tokens disponibles et éventuelle annulation. Ces champs permettent
  d'identifier un appel sans stocker son texte.
- **Aucun prompt, sortie brute, clé API ou jeton n'est placé dans le journal
  général**. L'export de journal reste donc plus prudent à partager.
- Les requêtes HTTP et réponses brutes (expurgées de leurs secrets)
  sont enregistrées séparément dans les diagnostics de la Partie selon la
  politique de rétention choisie. Ils ne sont pas affichés dans le chat.
- Les réponses images sont représentées par des métadonnées expurgées,
  jamais par le contenu binaire.
- Le filtre « Appels IA uniquement » permet d'isoler ces événements
  dans le journal de l'application.

## Vérifications recommandées

1. Naviguer Accueil ↔ Livres ↔ Paramètres, ouvrir une Partie et revenir par
   Retour Android sans perte des modifications du Livre.
2. Parcourir les onglets IA / Application / Diagnostic puis Partie /
   Historique et traces ; confirmer que les exports restent accessibles.
3. Générer un tour avec outils et mémoire, puis préparer et générer une image ;
   contrôler les étapes et les IDs dans le journal ainsi que les diagnostics
   persistés dans la Partie.
4. Faire un test de connexion et créer une couverture ; vérifier que ces
   appels sont visibles dans le journal général, même sans Partie.
5. Exporter les logs : aucune clé, aucun prompt, aucun texte de scène ne doit
   figurer dans le JSONL. Les diagnostics de Partie restent des données
   sensibles que seul l'utilisateur exporte volontairement.

## Périmètre et limites

Cette première passe sépare les usages courants des outils techniques,
clarifie les prompts existants et standardise la journalisation des
échanges instrumentés. Elle ne remplace pas encore chaque écran de
configuration interne et ne crée pas la passe IA supplémentaire
« extraction sémantique de scène ».
