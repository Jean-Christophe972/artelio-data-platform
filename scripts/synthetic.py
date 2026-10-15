"""Génération de données synthétiques réalistes pour Artelio.

Aucune personne réelle : noms, adresses et SIRET sont inventés (Faker, locale fr_FR).
Les descriptions de demandes sont construites à partir de gabarits par métier et par
niveau d'urgence, avec du "bruit" (fautes, style oral, abréviations) pour que le modèle
d'IA du bloc 4 apprenne sur des textes proches de la réalité.
"""

from __future__ import annotations

import random
import unicodedata

# (description du problème, urgence) par métier
GABARITS: dict[str, list[tuple[str, str]]] = {
    "plomberie": [
        ("fuite d'eau importante sous l'évier, l'eau coule partout", "critique"),
        ("dégât des eaux, l'eau passe chez le voisin du dessous", "critique"),
        ("canalisation bouchée, l'eau ne s'évacue plus dans la douche", "haute"),
        ("les toilettes sont bouchées et débordent", "haute"),
        ("le robinet de la cuisine goutte en permanence", "normale"),
        ("chasse d'eau qui coule en continu", "normale"),
        ("je voudrais remplacer mon mitigeur de salle de bain", "faible"),
        ("installation d'un lave-vaisselle à raccorder", "faible"),
        ("odeur d'égout dans la salle de bain", "normale"),
        ("pression d'eau très faible à tous les robinets", "normale"),
    ],
    "electricite": [
        ("plus de courant dans tout l'appartement, le disjoncteur saute", "critique"),
        ("odeur de brûlé qui sort d'une prise électrique", "critique"),
        ("une prise a fait des étincelles", "haute"),
        ("le tableau électrique disjoncte dès que j'allume le four", "haute"),
        ("plusieurs prises ne fonctionnent plus dans la chambre", "normale"),
        ("installer des luminaires au plafond du salon", "faible"),
        ("ajouter des prises dans la cuisine", "faible"),
        ("mise aux normes du tableau électrique avant location", "faible"),
        ("l'interphone ne marche plus", "normale"),
        ("lumière qui clignote dans le couloir", "normale"),
    ],
    "serrurerie": [
        ("porte claquée, je suis bloqué dehors avec les clés à l'intérieur", "critique"),
        ("cambriolage cette nuit, la serrure est forcée", "critique"),
        ("clé cassée dans la serrure de la porte d'entrée", "haute"),
        ("la serrure tourne dans le vide, impossible de fermer", "haute"),
        ("changer le cylindre après la perte de mes clés", "normale"),
        ("installer une serrure trois points", "faible"),
        ("poser un verrou supplémentaire", "faible"),
        ("la porte frotte et ferme mal", "normale"),
    ],
    "chauffage": [
        ("plus de chauffage ni d'eau chaude, la chaudière est en panne", "critique"),
        ("chaudière en sécurité avec un code erreur, plus de chauffage", "haute"),
        ("radiateurs froids dans toutes les pièces", "haute"),
        ("le ballon d'eau chaude ne chauffe plus", "haute"),
        ("entretien annuel de la chaudière gaz", "faible"),
        ("un radiateur fait du bruit et chauffe mal, il faut le purger", "normale"),
        ("installation d'une pompe à chaleur", "faible"),
        ("thermostat qui ne répond plus", "normale"),
        ("climatisation qui ne refroidit plus", "normale"),
    ],
    "peinture": [
        ("repeindre le salon et le couloir, environ 30 m2", "faible"),
        ("rafraîchir les peintures avant un état des lieux de sortie", "normale"),
        ("traces d'humidité et moisissures au plafond de la salle de bain", "normale"),
        ("poser du papier peint dans une chambre", "faible"),
        ("reprendre les fissures et repeindre la façade", "faible"),
        ("peinture qui s'écaille dans la cuisine", "faible"),
    ],
    "menuiserie": [
        ("vitre cassée, la fenêtre ne ferme plus", "haute"),
        ("porte-fenêtre bloquée, impossible de l'ouvrir", "normale"),
        ("volet roulant coincé en position fermée", "normale"),
        ("poser des étagères sur mesure", "faible"),
        ("remplacer une porte intérieure", "faible"),
        ("parquet qui se soulève dans le salon", "normale"),
    ],
    "petits_travaux": [
        ("monter des meubles et fixer une télé au mur", "faible"),
        ("fixer des tringles à rideaux et des cadres", "faible"),
        ("refaire les joints de la baignoire", "faible"),
        ("poser une barre d'appui dans la salle de bain", "normale"),
        ("installer une étagère et un miroir", "faible"),
        ("petites réparations avant l'arrivée d'un locataire", "normale"),
    ],
}

PIECES = ["", "", " dans la cuisine", " dans la salle de bain", " au salon", " dans la chambre", " dans l'entrée"]
DEBUTS = ["", "", "Bonjour, ", "Bonjour, ", "Bonsoir, ", "Salut, ", "Bjr ", "Bonjour madame, monsieur, "]
FINS = [
    "",
    "",
    "",
    " Merci d'avance.",
    " Merci de me rappeler rapidement.",
    " Je suis disponible demain matin.",
    " C'est assez urgent svp.",
    " Combien ça coûterait ?",
    " Je suis locataire, le propriétaire est d'accord.",
]
ABREVIATIONS = {"rendez-vous": "rdv", "s'il vous plaît": "svp", "appartement": "appart", "aujourd'hui": "auj"}

# Saisonnalité : poids relatif de chaque métier selon le mois (le chauffage explose en hiver)
POIDS_METIERS_HIVER = {
    "plomberie": 25,
    "electricite": 18,
    "serrurerie": 12,
    "chauffage": 30,
    "peinture": 5,
    "menuiserie": 5,
    "petits_travaux": 5,
}
POIDS_METIERS_ETE = {
    "plomberie": 28,
    "electricite": 20,
    "serrurerie": 14,
    "chauffage": 6,
    "peinture": 14,
    "menuiserie": 8,
    "petits_travaux": 10,
}


def poids_metiers(mois: int) -> dict[str, int]:
    return POIDS_METIERS_HIVER if mois in (11, 12, 1, 2, 3) else POIDS_METIERS_ETE


def _sans_accents(texte: str) -> str:
    return "".join(c for c in unicodedata.normalize("NFD", texte) if unicodedata.category(c) != "Mn")


def _ajouter_fautes(texte: str, rng: random.Random) -> str:
    """Simule un message tapé vite : pas d'accents, minuscules, lettres inversées."""
    if rng.random() < 0.35:
        texte = _sans_accents(texte)
    if rng.random() < 0.30:
        texte = texte.lower()
    if rng.random() < 0.20 and len(texte) > 20:
        i = rng.randrange(5, len(texte) - 2)
        texte = texte[:i] + texte[i + 1] + texte[i] + texte[i + 2 :]
    for long, court in ABREVIATIONS.items():
        if long in texte and rng.random() < 0.5:
            texte = texte.replace(long, court)
    return texte


def generer_description(metier: str, rng: random.Random) -> tuple[str, str]:
    """Renvoie (description, urgence) pour un métier donné."""
    probleme, urgence = rng.choice(GABARITS[metier])
    texte = rng.choice(DEBUTS) + probleme + rng.choice(PIECES) + "." + rng.choice(FINS)
    texte = texte[0].upper() + texte[1:] if texte else texte
    return _ajouter_fautes(texte, rng), urgence


def siret_valide(rng: random.Random) -> str:
    """SIRET fictif à 14 chiffres respectant la clé de Luhn (comme un vrai SIRET)."""
    base = [rng.randint(0, 9) for _ in range(13)]
    for check in range(10):
        digits = base + [check]
        total = 0
        for i, d in enumerate(reversed(digits)):
            d = d * 2 if i % 2 else d
            total += d - 9 if d > 9 else d
        if total % 10 == 0:
            return "".join(map(str, digits))
    raise AssertionError("inatteignable")


# Communes représentatives par département d'Île-de-France : (code postal, commune, lat, lon)
COMMUNES = {
    "75": [
        ("75011", "Paris 11e", 48.859, 2.380),
        ("75015", "Paris 15e", 48.841, 2.300),
        ("75018", "Paris 18e", 48.892, 2.348),
        ("75020", "Paris 20e", 48.864, 2.398),
    ],
    "92": [
        ("92100", "Boulogne-Billancourt", 48.835, 2.241),
        ("92000", "Nanterre", 48.892, 2.207),
        ("92130", "Issy-les-Moulineaux", 48.823, 2.263),
    ],
    "93": [("93200", "Saint-Denis", 48.936, 2.357), ("93100", "Montreuil", 48.862, 2.443), ("93000", "Bobigny", 48.908, 2.439)],
    "94": [
        ("94000", "Créteil", 48.790, 2.455),
        ("94300", "Vincennes", 48.847, 2.439),
        ("94200", "Ivry-sur-Seine", 48.813, 2.384),
    ],
    "77": [("77100", "Meaux", 48.960, 2.879), ("77000", "Melun", 48.540, 2.660)],
    "78": [("78000", "Versailles", 48.805, 2.120), ("78100", "Saint-Germain-en-Laye", 48.898, 2.093)],
    "91": [("91000", "Évry-Courcouronnes", 48.629, 2.441), ("91300", "Massy", 48.731, 2.271)],
    "95": [("95000", "Cergy", 49.036, 2.076), ("95100", "Argenteuil", 48.947, 2.248)],
}
# Répartition de la population cliente (Paris et petite couronne plus denses)
POIDS_DEPARTEMENTS = {"75": 30, "92": 15, "93": 13, "94": 12, "77": 7, "78": 8, "91": 7, "95": 8}
