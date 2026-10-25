-- =============================================================================
-- Schéma "app" : base transactionnelle (OLTP) de la marketplace Artelio
--   - données structurées : clients, artisans, devis, factures...
--   - données semi-structurées : messages et lignes de devis en JSONB
--   - données non structurées : photos → stockées dans le stockage objet S3,
--     la base ne garde que la référence (clé d'objet, taille, empreinte)
-- Modèle conceptuel : docs/MODELE_DE_DONNEES.md
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;            -- chiffrement de colonnes, HMAC
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;  -- statistiques de requêtes (monitoring)

CREATE SCHEMA app;
SET search_path = app;

-- ---------------------------------------------------------------- Référentiel
CREATE TABLE metiers (
    code     text PRIMARY KEY,
    libelle  text NOT NULL
);

INSERT INTO metiers (code, libelle) VALUES
    ('plomberie',    'Plomberie'),
    ('electricite',  'Électricité'),
    ('serrurerie',   'Serrurerie'),
    ('chauffage',    'Chauffage et climatisation'),
    ('peinture',     'Peinture et revêtements'),
    ('menuiserie',   'Menuiserie et vitrerie'),
    ('petits_travaux', 'Petits travaux et bricolage');

-- ---------------------------------------------------------------- Clients
CREATE TABLE clients (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email              text NOT NULL UNIQUE CHECK (email = lower(email) AND email LIKE '%@%'),
    prenom             text,
    nom                text,
    telephone          text,
    statut             text NOT NULL DEFAULT 'actif' CHECK (statut IN ('actif', 'efface')),
    cree_le            timestamptz NOT NULL DEFAULT now(),
    derniere_activite  timestamptz NOT NULL DEFAULT now(),
    efface_le          timestamptz
);

-- Un logement = la "fiche habitation" (historique des travaux), activée sur consentement
CREATE TABLE logements (
    id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id                 uuid NOT NULL REFERENCES clients (id) ON DELETE CASCADE,
    adresse                   text NOT NULL,
    code_postal               char(5) NOT NULL CHECK (code_postal ~ '^[0-9]{5}$'),
    commune                   text NOT NULL,
    departement               char(2) NOT NULL CHECK (departement IN ('75','77','78','91','92','93','94','95')),
    latitude                  numeric(8,5),
    longitude                 numeric(8,5),
    type_logement             text CHECK (type_logement IN ('appartement', 'maison')),
    annee_construction        smallint CHECK (annee_construction BETWEEN 1600 AND 2100),
    fiche_habitation_active   boolean NOT NULL DEFAULT false,
    cree_le                   timestamptz NOT NULL DEFAULT now()
);

-- Historique des consentements : on ajoute des lignes, on n'en modifie jamais (preuve)
CREATE TABLE consentements (
    id          bigserial PRIMARY KEY,
    client_id   uuid NOT NULL REFERENCES clients (id) ON DELETE CASCADE,
    finalite    text NOT NULL CHECK (finalite IN ('fiche_habitation', 'prospection', 'mesure_audience', 'donnees_accessibilite', 'entrainement_ia')),
    accorde     boolean NOT NULL,
    source      text NOT NULL CHECK (source IN ('app', 'web', 'telephone')),
    horodatage  timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- Artisans
CREATE TABLE artisans (
    id                           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    siret                        char(14) NOT NULL UNIQUE CHECK (siret ~ '^[0-9]{14}$'),
    raison_sociale               text NOT NULL,
    prenom_contact               text NOT NULL,
    nom_contact                  text NOT NULL,
    email                        text NOT NULL UNIQUE CHECK (email = lower(email)),
    telephone                    text NOT NULL,
    departements                 char(2)[] NOT NULL,
    assurance_decennale_expire_le date NOT NULL,
    note_moyenne                 numeric(2,1) CHECK (note_moyenne BETWEEN 1 AND 5),
    nb_avis                      integer NOT NULL DEFAULT 0,
    statut                       text NOT NULL DEFAULT 'en_verification'
                                 CHECK (statut IN ('en_verification', 'actif', 'suspendu', 'sorti')),
    cree_le                      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE artisan_metiers (
    artisan_id   uuid NOT NULL REFERENCES artisans (id) ON DELETE CASCADE,
    metier_code  text NOT NULL REFERENCES metiers (code),
    PRIMARY KEY (artisan_id, metier_code)
);

-- Géolocalisation pendant le trajet de mission uniquement, purgée après 24 h
CREATE TABLE positions_artisans (
    id              bigserial PRIMARY KEY,
    artisan_id      uuid NOT NULL REFERENCES artisans (id) ON DELETE CASCADE,
    latitude        numeric(8,5) NOT NULL,
    longitude       numeric(8,5) NOT NULL,
    enregistree_le  timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- Demandes
CREATE TABLE demandes (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id        uuid NOT NULL REFERENCES clients (id) ON DELETE CASCADE,
    logement_id      uuid REFERENCES logements (id) ON DELETE SET NULL,
    description      text NOT NULL,
    canal            text NOT NULL CHECK (canal IN ('app', 'web', 'vocal', 'telephone')),
    -- Prédictions de l'IA (bloc 4) et éventuelle correction humaine
    metier_predit    text REFERENCES metiers (code),
    urgence_predite  text CHECK (urgence_predite IN ('faible', 'normale', 'haute', 'critique')),
    confiance_ia     numeric(4,3) CHECK (confiance_ia BETWEEN 0 AND 1),
    metier_valide    text REFERENCES metiers (code),
    statut           text NOT NULL DEFAULT 'nouvelle'
                     CHECK (statut IN ('nouvelle', 'qualifiee', 'devis_envoyes', 'acceptee', 'terminee', 'annulee')),
    cree_le          timestamptz NOT NULL DEFAULT now()
);

-- Photos : le fichier est dans le stockage objet, la base garde la référence
CREATE TABLE photos_demande (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    demande_id       uuid NOT NULL REFERENCES demandes (id) ON DELETE CASCADE,
    cle_objet        text NOT NULL UNIQUE,
    type_mime        text NOT NULL CHECK (type_mime IN ('image/jpeg', 'image/png', 'image/heic')),
    taille_octets    integer NOT NULL CHECK (taille_octets > 0 AND taille_octets <= 15 * 1024 * 1024),
    empreinte_sha256 char(64) NOT NULL,
    exif_supprime    boolean NOT NULL DEFAULT true,
    televersee_le    timestamptz NOT NULL DEFAULT now()
);

-- Donnée de santé (art. 9 RGPD) : table séparée, colonne chiffrée, durée de vie limitée
CREATE TABLE besoins_accessibilite (
    demande_id               uuid PRIMARY KEY REFERENCES demandes (id) ON DELETE CASCADE,
    description_chiffree     bytea NOT NULL,
    consentement_explicite_le timestamptz NOT NULL,
    expire_le                timestamptz NOT NULL
);

-- Messages : contenu libre + métadonnées semi-structurées (pièces jointes, lecture, canal...)
CREATE TABLE messages (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    demande_id   uuid NOT NULL REFERENCES demandes (id) ON DELETE CASCADE,
    auteur_type  text NOT NULL CHECK (auteur_type IN ('client', 'artisan', 'support', 'systeme')),
    auteur_id    uuid,
    contenu      text NOT NULL,
    metadonnees  jsonb NOT NULL DEFAULT '{}'::jsonb,
    envoye_le    timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- Devis, interventions, factures
CREATE TABLE devis (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    demande_id    uuid NOT NULL REFERENCES demandes (id) ON DELETE CASCADE,
    artisan_id    uuid NOT NULL REFERENCES artisans (id),
    lignes        jsonb NOT NULL CHECK (jsonb_typeof(lignes) = 'array'),
    montant_ht    numeric(10,2) NOT NULL CHECK (montant_ht > 0),
    taux_tva      numeric(4,3) NOT NULL CHECK (taux_tva IN (0.055, 0.100, 0.200)),
    montant_ttc   numeric(10,2) GENERATED ALWAYS AS (round(montant_ht * (1 + taux_tva), 2)) STORED,
    statut        text NOT NULL DEFAULT 'envoye' CHECK (statut IN ('envoye', 'accepte', 'refuse', 'expire')),
    cree_le       timestamptz NOT NULL DEFAULT now(),
    repondu_le    timestamptz
);

CREATE TABLE interventions (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    devis_id     uuid NOT NULL UNIQUE REFERENCES devis (id) ON DELETE CASCADE,
    artisan_id   uuid NOT NULL REFERENCES artisans (id),
    debut_prevu  timestamptz NOT NULL,
    debut_reel   timestamptz,
    fin_reelle   timestamptz,
    statut       text NOT NULL DEFAULT 'planifiee' CHECK (statut IN ('planifiee', 'en_cours', 'terminee', 'annulee')),
    CHECK (fin_reelle IS NULL OR fin_reelle >= debut_reel)
);

-- Les factures sont conservées 10 ans (Code de commerce L123-22), même après effacement du client :
-- l'identité de facturation est donc copiée ici au moment de l'émission.
CREATE TABLE factures (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    intervention_id      uuid NOT NULL UNIQUE REFERENCES interventions (id) ON DELETE RESTRICT,
    numero               text NOT NULL UNIQUE,
    montant_ttc          numeric(10,2) NOT NULL CHECK (montant_ttc > 0),
    commission_artelio   numeric(10,2) NOT NULL CHECK (commission_artelio >= 0),
    nom_facturation      text NOT NULL,
    adresse_facturation  text NOT NULL,
    cle_objet_pdf        text,
    emise_le             date NOT NULL DEFAULT current_date
);

CREATE TABLE avis (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    intervention_id  uuid NOT NULL UNIQUE REFERENCES interventions (id) ON DELETE CASCADE,
    note             smallint NOT NULL CHECK (note BETWEEN 1 AND 5),
    commentaire      text,
    publie_le        timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- Index
CREATE INDEX ON logements (client_id);
CREATE INDEX ON consentements (client_id, finalite, horodatage DESC);
CREATE INDEX ON artisans USING gin (departements);
CREATE INDEX ON artisans (statut);
CREATE INDEX ON positions_artisans (enregistree_le);
CREATE INDEX ON demandes (client_id);
CREATE INDEX ON demandes (statut, cree_le);
CREATE INDEX ON photos_demande (demande_id);
CREATE INDEX ON messages (demande_id, envoye_le);
CREATE INDEX ON messages USING gin (metadonnees jsonb_path_ops);
CREATE INDEX ON devis (demande_id);
CREATE INDEX ON devis (artisan_id);
CREATE INDEX ON interventions (artisan_id, statut);
CREATE INDEX ON clients (derniere_activite) WHERE statut = 'actif';
