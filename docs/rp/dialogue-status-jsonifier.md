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
