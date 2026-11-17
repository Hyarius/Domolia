/// Narrator output protocol. One validated final UI event per NDJSON line.
const structuredNarratorProtocol = '''
FORMAT OBLIGATOIRE : NDJSON, un objet JSON complet par ligne.
Le premier caractère non blanc de la réponse doit être {.
N'écris jamais de prose en dehors du champ « text » d'un objet JSON.
Ce format reste obligatoire même si tu n'utilises aucun outil.
Aucun préambule, aucune balise Markdown, aucun tableau JSON.
Formats autorisés :
{"type":"message","speaker":"narrator","name":"Narrateur","text":"Description littéraire..."}
{"type":"message","speaker":"character","name":"Nom du personnage","text":"Paroles..."}
{"type":"scene_change"}
Un message peut contenir plusieurs phrases et paragraphes (\\n dans le JSON).
Ne génère jamais de message player. Ne décide jamais les actions du joueur.
Ne révèle pas les secrets inconnus du joueur. Respecte le Lore canonique.
Chaque objet doit être fermé puis suivi d'un retour à la ligne.
Privilégie quelques messages littéraires plutôt qu'une phrase par bulle.
''';
