"""Charge un jeu de données synthétiques cohérent dans la base Artelio.

    python scripts/seed_data.py --clients 3000 --artisans 350 --demandes 8000

Les insertions sont faites avec le compte applicatif "app_api" (moindre privilège) :
elles passent donc par les mêmes contrôles et le même journal d'audit que l'application.
Le script est déterministe (graine fixe) : deux exécutions produisent les mêmes données.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import random
import sys
import uuid
from decimal import Decimal

from faker import Faker

from platform_common import get_logger, pg_connect, retry, s3_client
from synthetic import COMMUNES, GABARITS, POIDS_DEPARTEMENTS, generer_description, poids_metiers, siret_valide

log = get_logger("seed")
UTC = dt.UTC
NOW = dt.datetime(2026, 10, 14, 12, 0, tzinfo=UTC)
DEBUT = dt.datetime(2025, 1, 1, tzinfo=UTC)
METIERS = list(GABARITS)
STATUTS_DEMANDE = {"terminee": 55, "acceptee": 8, "devis_envoyes": 12, "qualifiee": 8, "nouvelle": 5, "annulee": 12}
TVA = [Decimal("0.100"), Decimal("0.100"), Decimal("0.200"), Decimal("0.055")]


def pick(rng: random.Random, weights: dict[str, int]) -> str:
    return rng.choices(list(weights), weights=list(weights.values()))[0]


def date_aleatoire(rng: random.Random, debut: dt.datetime, fin: dt.datetime) -> dt.datetime:
    return debut + dt.timedelta(seconds=rng.randint(0, int((fin - debut).total_seconds())))


class Generateur:
    def __init__(self, seed: int):
        self.rng = random.Random(seed)
        self.fake = Faker("fr_FR")
        self.fake.seed_instance(seed)
        self.rows: dict[str, list[tuple]] = {}

    def add(self, table: str, row: tuple) -> None:
        self.rows.setdefault(table, []).append(row)

    # ------------------------------------------------------------------ Clients et logements
    def clients(self, n: int) -> list[dict]:
        clients = []
        for i in range(n):
            cid = uuid.UUID(int=self.rng.getrandbits(128), version=4)
            cree = date_aleatoire(self.rng, DEBUT - dt.timedelta(days=365), NOW - dt.timedelta(days=30))
            # Quelques comptes "historiques" inactifs depuis plus de 3 ans : la purge RGPD doit les effacer
            activite = dt.datetime(2022, 6, 1, tzinfo=UTC) if i < 5 else date_aleatoire(self.rng, cree, NOW)
            prenom, nom = self.fake.first_name(), self.fake.last_name()
            email = f"{prenom}.{nom}.{i}@example.org".lower().replace(" ", "")
            self.add("clients", (cid, email, prenom, nom, self.fake.phone_number(), cree, activite))

            dep = pick(self.rng, POIDS_DEPARTEMENTS)
            cp, commune, lat, lon = self.rng.choice(COMMUNES[dep])
            lid = uuid.UUID(int=self.rng.getrandbits(128), version=4)
            fiche = self.rng.random() < 0.4
            self.add(
                "logements",
                (
                    lid,
                    cid,
                    self.fake.street_address(),
                    cp,
                    commune,
                    dep,
                    round(lat + self.rng.uniform(-0.02, 0.02), 5),
                    round(lon + self.rng.uniform(-0.02, 0.02), 5),
                    self.rng.choice(["appartement"] * 3 + ["maison"]),
                    self.rng.randint(1880, 2022),
                    fiche,
                    cree,
                ),
            )
            if fiche:
                self.add("consentements", (cid, "fiche_habitation", True, "app", cree))
            if self.rng.random() < 0.3:
                self.add("consentements", (cid, "prospection", True, "web", cree))
            if self.rng.random() < 0.03:
                self.add("consentements", (cid, "entrainement_ia", False, "app", cree))
            clients.append({"id": cid, "logement": lid, "dep": dep, "cree": cree})
        return clients

    # ------------------------------------------------------------------ Artisans
    def artisans(self, n: int) -> list[dict]:
        artisans = []
        departements = list(POIDS_DEPARTEMENTS)
        for i in range(n):
            aid = uuid.UUID(int=self.rng.getrandbits(128), version=4)
            metiers = self.rng.sample(METIERS, k=self.rng.choice([1, 1, 2]))
            deps = self.rng.sample(departements, k=self.rng.choice([1, 2, 3]))
            statut = pick(self.rng, {"actif": 90, "en_verification": 5, "suspendu": 5})
            note = round(self.rng.uniform(3.4, 5.0), 1) if statut == "actif" else None
            prenom, nom = self.fake.first_name(), self.fake.last_name()
            self.add(
                "artisans",
                (
                    aid,
                    siret_valide(self.rng),
                    f"{nom} {self.rng.choice(['Services', 'Rénovation', 'Dépannage', 'Bâtiment'])}",
                    prenom,
                    nom,
                    f"contact.{i}@artisan.example.org",
                    self.fake.phone_number(),
                    "{" + ",".join(deps) + "}",
                    (NOW + dt.timedelta(days=self.rng.randint(-20, 700))).date(),
                    note,
                    self.rng.randint(0, 120) if note else 0,
                    statut,
                    date_aleatoire(self.rng, DEBUT - dt.timedelta(days=700), NOW - dt.timedelta(days=10)),
                ),
            )
            for m in metiers:
                self.add("artisan_metiers", (aid, m))
            if statut == "actif" and self.rng.random() < 0.3:
                # Positions GPS récentes (trajets de mission) : certaines ont plus de 24 h → purgées
                for _ in range(self.rng.randint(1, 4)):
                    self.add(
                        "positions_artisans",
                        (
                            aid,
                            48.85 + self.rng.uniform(-0.2, 0.2),
                            2.35 + self.rng.uniform(-0.3, 0.3),
                            NOW - dt.timedelta(hours=self.rng.randint(1, 60)),
                        ),
                    )
            artisans.append({"id": aid, "metiers": metiers, "deps": deps, "actif": statut == "actif"})
        return artisans

    # ------------------------------------------------------------------ Demandes et tout le cycle de vie
    def demandes(self, n: int, clients: list[dict], artisans: list[dict]) -> list[dict]:
        demandes = []
        par_metier_dep: dict[tuple[str, str], list[dict]] = {}
        for a in artisans:
            if a["actif"]:
                for m in a["metiers"]:
                    for d in a["deps"]:
                        par_metier_dep.setdefault((m, d), []).append(a)

        for _ in range(n):
            client = self.rng.choice(clients)
            cree = date_aleatoire(self.rng, max(client["cree"], DEBUT), NOW - dt.timedelta(hours=2))
            metier = pick(self.rng, poids_metiers(cree.month))
            description, urgence = generer_description(metier, self.rng)
            did = uuid.UUID(int=self.rng.getrandbits(128), version=4)
            statut = pick(self.rng, STATUTS_DEMANDE)
            if NOW - cree < dt.timedelta(days=2) and statut == "terminee":
                statut = "acceptee"

            # L'IA (bloc 4) se trompe ~12 % du temps sur le métier ; le support corrige ensuite
            predit = metier if self.rng.random() < 0.88 else self.rng.choice([m for m in METIERS if m != metier])
            confiance = round(self.rng.uniform(0.75, 0.99) if predit == metier else self.rng.uniform(0.35, 0.7), 3)
            valide = metier if (predit != metier and statut not in ("nouvelle",)) else None
            canal = pick(self.rng, {"app": 55, "web": 30, "vocal": 8, "telephone": 7})
            self.add(
                "demandes",
                (
                    did,
                    client["id"],
                    client["logement"],
                    description,
                    canal,
                    None if statut == "nouvelle" else predit,
                    None if statut == "nouvelle" else urgence,
                    None if statut == "nouvelle" else confiance,
                    valide,
                    statut,
                    cree,
                ),
            )
            demandes.append({"id": did, "cree": cree, "metier": metier, "urgence": urgence, "statut": statut})

            self._messages(did, client["id"], cree, canal)
            if self.rng.random() < 0.03:
                self.rows.setdefault("_besoins", []).append(
                    (
                        did,
                        self.rng.choice(
                            [
                                "Occupant en fauteuil roulant, prévoir l'accès par l'ascenseur.",
                                "Personne malentendante : merci de privilégier les SMS.",
                                "Personne âgée à mobilité réduite.",
                            ]
                        ),
                        cree,
                    )
                )
            if statut in ("devis_envoyes", "acceptee", "terminee"):
                candidats = par_metier_dep.get((metier, client["dep"])) or [a for a in artisans if a["actif"]]
                self._devis(did, cree, statut, candidats, urgence)
        return demandes

    def _messages(self, did: uuid.UUID, cid: uuid.UUID, cree: dt.datetime, canal: str) -> None:
        for k in range(self.rng.randint(1, 4)):
            auteur = "client" if k % 2 == 0 else self.rng.choice(["artisan", "support"])
            meta = {
                "canal": canal,
                "lu": self.rng.random() < 0.9,
                "langue": "fr",
                "pieces_jointes": self.rng.randint(0, 2) if auteur == "client" else 0,
            }
            contenu = self.fake.sentence(nb_words=self.rng.randint(6, 18))
            self.add(
                "messages",
                (
                    did,
                    auteur,
                    cid if auteur == "client" else None,
                    contenu,
                    json.dumps(meta),
                    cree + dt.timedelta(minutes=10 * (k + 1) + self.rng.randint(0, 600)),
                ),
            )

    def _devis(self, did, cree, statut, candidats, urgence) -> None:
        choisis = self.rng.sample(candidats, k=min(len(candidats), self.rng.randint(1, 3)))
        delai_h = {"critique": 1, "haute": 4, "normale": 24, "faible": 72}[urgence]
        for idx, artisan in enumerate(choisis):
            accepte = idx == 0 and statut in ("acceptee", "terminee")
            vid = uuid.UUID(int=self.rng.getrandbits(128), version=4)
            ht = Decimal(self.rng.randint(80, 2500))
            tva = self.rng.choice(TVA)
            lignes = [
                {"libelle": "Déplacement", "montant_ht": 39.0},
                {"libelle": "Main d'œuvre et fournitures", "montant_ht": float(ht - 39)},
            ]
            envoye = cree + dt.timedelta(hours=self.rng.uniform(0.2, delai_h * 1.5))
            self.add(
                "devis",
                (
                    vid,
                    did,
                    artisan["id"],
                    json.dumps(lignes),
                    ht,
                    tva,
                    "accepte" if accepte else ("refuse" if statut in ("acceptee", "terminee") else "envoye"),
                    envoye,
                    envoye + dt.timedelta(hours=self.rng.uniform(1, 30)) if statut != "devis_envoyes" else None,
                ),
            )
            if accepte:
                self._intervention(vid, artisan["id"], envoye, statut, ht, tva, urgence)

    def _intervention(self, vid, aid, envoye, statut, ht, tva, urgence) -> None:
        iid = uuid.UUID(int=self.rng.getrandbits(128), version=4)
        debut = envoye + dt.timedelta(
            hours=self.rng.uniform(1, {"critique": 4, "haute": 24, "normale": 72, "faible": 240}[urgence])
        )
        termine = statut == "terminee" and debut < NOW
        fin = debut + dt.timedelta(hours=self.rng.uniform(0.5, 6)) if termine else None
        self.add("interventions", (iid, vid, aid, debut, debut if termine else None, fin, "terminee" if termine else "planifiee"))
        if termine:
            ttc = (ht * (1 + tva)).quantize(Decimal("0.01"))
            numero = f"F-{fin:%Y%m}-{self.rng.getrandbits(32):08X}"
            self.rows.setdefault("_factures", []).append(
                (iid, numero, ttc, (ttc * Decimal("0.12")).quantize(Decimal("0.01")), fin.date(), vid)
            )
            if self.rng.random() < 0.7:
                note = self.rng.choices([5, 4, 3, 2, 1], weights=[50, 30, 10, 6, 4])[0]
                self.add(
                    "avis",
                    (iid, note, self.fake.sentence(nb_words=10) if self.rng.random() < 0.6 else None, fin + dt.timedelta(days=1)),
                )


COLONNES = {
    "clients": "id, email, prenom, nom, telephone, cree_le, derniere_activite",
    "logements": (
        "id, client_id, adresse, code_postal, commune, departement, latitude, longitude, "
        "type_logement, annee_construction, fiche_habitation_active, cree_le"
    ),
    "consentements": "client_id, finalite, accorde, source, horodatage",
    "artisans": (
        "id, siret, raison_sociale, prenom_contact, nom_contact, email, telephone, departements, "
        "assurance_decennale_expire_le, note_moyenne, nb_avis, statut, cree_le"
    ),
    "artisan_metiers": "artisan_id, metier_code",
    "positions_artisans": "artisan_id, latitude, longitude, enregistree_le",
    "demandes": (
        "id, client_id, logement_id, description, canal, metier_predit, urgence_predite, "
        "confiance_ia, metier_valide, statut, cree_le"
    ),
    "messages": "demande_id, auteur_type, auteur_id, contenu, metadonnees, envoye_le",
    "devis": "id, demande_id, artisan_id, lignes, montant_ht, taux_tva, statut, cree_le, repondu_le",
    "interventions": "id, devis_id, artisan_id, debut_prevu, debut_reel, fin_reelle, statut",
    "avis": "intervention_id, note, commentaire, publie_le",
}


def charger(gen: Generateur, photos: int) -> None:
    with retry(lambda: pg_connect("app_api", "PG_APP_PASSWORD"), "PostgreSQL") as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT count(*) FROM app.clients")
            if cur.fetchone()[0] > 0:
                log.warning("La base contient déjà des clients : chargement ignoré (base déjà initialisée)")
                return
            for table, cols in COLONNES.items():
                rows = gen.rows.get(table, [])
                with cur.copy(f"COPY app.{table} ({cols}) FROM STDIN") as copy:
                    for row in rows:
                        copy.write_row(row)
                log.info("%-20s %6d lignes", table, len(rows))

            # Factures : l'identité de facturation est copiée depuis le client (conservation légale)
            cur.executemany(
                """INSERT INTO app.factures (intervention_id, numero, montant_ttc, commission_artelio, emise_le,
                                             nom_facturation, adresse_facturation)
                   SELECT %s, %s, %s, %s, %s, c.prenom || ' ' || c.nom, l.adresse || ', ' || l.code_postal || ' ' || l.commune
                   FROM app.devis v JOIN app.demandes d ON d.id = v.demande_id
                   JOIN app.clients c ON c.id = d.client_id JOIN app.logements l ON l.id = d.logement_id
                   WHERE v.id = %s""",
                gen.rows.get("_factures", []),
            )
            log.info("%-20s %6d lignes", "factures", len(gen.rows.get("_factures", [])))

            # Donnée de santé : chiffrée par PostgreSQL avec la clé attachée au rôle app_api
            cur.executemany(
                """INSERT INTO app.besoins_accessibilite (demande_id, description_chiffree, consentement_explicite_le, expire_le)
                   VALUES (%s, pgp_sym_encrypt(%s, current_setting('artelio.cle_chiffrement')), %s, %s + interval '30 days')""",
                [(did, texte, cree, cree) for did, texte, cree in gen.rows.get("_besoins", [])],
            )
            log.info("%-20s %6d lignes (chiffrées)", "besoins_accessib.", len(gen.rows.get("_besoins", [])))
        conn.commit()

    if photos:
        televerser_photos(gen, photos)


def televerser_photos(gen: Generateur, n: int) -> None:
    """Envoie des photos synthétiques dans S3 et enregistre leurs références en base."""
    s3 = s3_client("S3_APP_ACCESS_KEY", "S3_APP_SECRET_KEY")
    demandes = sorted(gen.rows["demandes"], key=lambda r: r[10], reverse=True)[:n]
    refs = []
    for row in demandes:
        did, cree = row[0], row[10]
        contenu = f"photo synthétique de la demande {did}".encode() * 40  # pas de vraie image : aucune donnée réelle
        cle = f"demandes/{cree:%Y/%m}/{did}/{uuid.uuid4()}.jpg"
        s3.put_object(Bucket="photos", Key=cle, Body=contenu, ContentType="image/jpeg")
        refs.append((did, cle, "image/jpeg", len(contenu), hashlib.sha256(contenu).hexdigest(), cree))
    with pg_connect("app_api", "PG_APP_PASSWORD") as conn, conn.cursor() as cur:
        cur.executemany(
            """INSERT INTO app.photos_demande (demande_id, cle_objet, type_mime, taille_octets, empreinte_sha256, televersee_le)
                           VALUES (%s, %s, %s, %s, %s, %s)""",
            refs,
        )
    log.info("%-20s %6d objets dans le bucket 'photos'", "photos_demande", len(refs))


def rafraichir_entrepot() -> None:
    with pg_connect("pipeline_etl", "PG_ETL_PASSWORD") as conn, conn.cursor() as cur:
        cur.execute("CALL dwh.rafraichir_entrepot()")
        cur.execute("SELECT (SELECT count(*) FROM dwh.fait_demande), (SELECT count(*) FROM dwh.fait_intervention)")
        demandes, interventions = cur.fetchone()
    log.info("Entrepôt rafraîchi : %d faits 'demande', %d faits 'intervention'", demandes, interventions)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--clients", type=int, default=3000)
    parser.add_argument("--artisans", type=int, default=350)
    parser.add_argument("--demandes", type=int, default=8000)
    parser.add_argument("--photos", type=int, default=300, help="nombre de demandes récentes avec une photo")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    try:
        gen = Generateur(args.seed)
        clients = gen.clients(args.clients)
        artisans = gen.artisans(args.artisans)
        gen.demandes(args.demandes, clients, artisans)
        charger(gen, args.photos)
        rafraichir_entrepot()
    except Exception:  # noqa: BLE001
        log.exception("Échec du chargement des données de démonstration")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
