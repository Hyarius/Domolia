# JSONificateur — dialogues nettoyés et statuts de personnages

Cette évolution s'applique au pipeline Narrateur RAW → JSONificateur de PR08,
sur la branche de Lore statique PR #12.

## Contrat

- Le narrateur reste totalement libre d'écrire de la prose littéraire.
- Domolia découpe le RAW en **parties immuables**, en isolant les citations
  françaises `« … »` au sein d'un même paragraphe. Chaque caractère du RAW
  appartient à une et une seule partie.
- Le JSONificateur ne renvoie que des étiquettes d'index : `narration`,
  `dialogue`, `aside`, avec le nom du personnage et éventuellement `status`
  pour le dialogue. Il ne renvoie jamais le texte des bulles ni des offsets.
- Domolia retire les guillemets de la citation et n'affiche que ses paroles.
  Les courtes incises attributives peuvent être masquées. Une attitude
  intéressante peut être traduite en statut, sans inventer de fait.
- Les faits et actions indépendants doivent rester de la narration, et ne
  doivent pas être supprimés à prétexte de faire un statut.
- Le statut est facultatif, conservé dans la Partie et exporté avec elle, mais
  n'est **pas** un élément permanent du Lore. Un état n'est pas propagé
  automatiquement aux répliques suivantes.

Exemple RAW :

```text
Liv, étonnée : « Quoi ?! » murmure-t-elle. « Mais pourquoi ? »
```

Représentation visible :

- **Liv - étonnée :** Quoi ?!
- **Liv - murmurant :** Mais pourquoi ?

La vraie source RAW reste stockée indépendamment et renvoyée intacte au
narrateur à son prochain tour, conformément à PR08.


## Mémoire narrative compacte pour les tours suivants

Le même appel de JSONification peut produire un champ facultatif
`compact` au niveau de l'enveloppe JSON (à côté de `events`). Il résume
les faits narratifs du **tour RAW courant**, pour éviter de renvoyer toute
la prose aux futurs appels du narrateur. Ce résumé n'est jamais utilisé pour
produire les bulles de la conversation.

- Les faits du lieu, les protagonistes, les actions réalisées, l'état des
  personnages, les révélations et les questions encore ouvertes doivent
  être présents si utiles au prochain tour.
- Le JSONificateur ne doit pas inventer de propos ou d'actions du joueur,
  ni transformer une possibilité future en événement réalisé.
- La validation accepte seulement un résumé non vide de 25 à 1200 caractères,
  économisant au moins 20 % du texte RAW ; en dessous de 180 caractères RAW,
  on ne condense pas. Le résumé non valable est ignoré, **sans invalider la
  JSONification ni perdre le RAW**.
- Dans `NarrativeChatController.buildNarratorContext`, chaque tour terminé
  utilise son `compactText` validé lorsque disponible ; sinon le RAW original
  est transmis. Les interventions du joueur restent inchangées.
- La table SQLite `raw_generations` dispose d'une colonne nullable
  `compact_text` depuis la version 7. Les anciennes Parties sont migrées
  sans compression et gardent leur comportement antérieur.
- Les exports de diagnostics IA conservent côte à côte le RAW d'origine
  et son résumé, pour permettre l'inspection des éventuels oublis.

La compression réduit généralement le volume du contexte transmis mais ne
prouve pas la fidélité sémantique du résumé. Le texte original reste la source
de vérité, et la mémoire compacte est une optimisation de contexte, pas une
modification du canon du Livre ou un nouveau mécanisme de Live Lore.

## Rejets et compatibilité

Les indices de parties absents, réordonnés ou répétés sont rejetés.
Les noms non présents dans le RAW ou les personnages précédemment connus
sont rejetés, ainsi que les paroles explicites attribuées au joueur.
Une incise doit toucher une réplique, pas remplacer un paragraphe narratif
isolé. Un statut ne peut contenir ni saut de ligne ni balises et est borné
à 65 caractères.

Les anciens protocoles à blocs et à offsets continuent d'être décodés pour
les clients/tests historiques. Les anciennes Parties sans statut continuent
de se charger ; l'affichage retire aussi les guillemets français de leurs
bulles quand il le peut. La reclassification de dialogues déjà enregistrés
n'est pas automatique.

## Limites

Le modèle reste responsable de l'interprétation sémantique des incises.
Aucune validation purement syntaxique ne peut prouver qu'un passage masqué
est littérairement secondaire ou qu'une émotion est correcte. Le RAW reste
consultable pour diagnostic. Les fragments dépassant le seuil de
fragmentation sont regroupés par paragraphes pour contenir la requête :
la séparation très fine des répliques n'est alors pas garantie.
