-- =============================================================================
-- Schéma "dwh" : entrepôt analytique en étoile (star schema)
--   - 2 tables de faits : fait_demande (grain : une demande), fait_intervention (grain : une intervention)
--   - 5 dimensions : date, métier, zone, artisan (historisée SCD 2), client
-- Aucune donnée directement identifiante : les identifiants sont remplacés par un HMAC-SHA256
-- (pseudonymisation, plan de gouvernance §7). Les analystes n'ont accès qu'à ce schéma.
-- L'alimentation incrémentale et orchestrée est l'objet du bloc 3 ; dwh.rafraichir_entrepot()
-- fournit ici un chargement complet de référence.
-- =============================================================================

CREATE SCHEMA dwh;
SET search_path = dwh;

-- ---------------------------------------------------------------- Dimensions
CREATE TABLE dim_date (
    date_key      integer PRIMARY KEY,          -- AAAAMMJJ
    jour          date NOT NULL UNIQUE,
    annee         smallint NOT NULL,
    trimestre     smallint NOT NULL,
    mois          smallint NOT NULL,
    libelle_mois  text NOT NULL,
    semaine_iso   smallint NOT NULL,
    jour_semaine  smallint NOT NULL,            -- 1 = lundi
    est_week_end  boolean NOT NULL,
    saison        text NOT NULL                 -- utile pour la saisonnalité (pannes de chauffage en hiver)
);

INSERT INTO dim_date
SELECT to_char(d, 'YYYYMMDD')::integer,
       d::date,
       extract(year FROM d),
       extract(quarter FROM d),
       extract(month FROM d),
       (ARRAY['janvier','février','mars','avril','mai','juin','juillet','août','septembre','octobre','novembre','décembre'])[extract(month FROM d)],
       extract(week FROM d),
       extract(isodow FROM d),
       extract(isodow FROM d) IN (6, 7),
       CASE WHEN extract(month FROM d) IN (12, 1, 2) THEN 'hiver'
            WHEN extract(month FROM d) IN (3, 4, 5) THEN 'printemps'
            WHEN extract(month FROM d) IN (6, 7, 8) THEN 'été'
            ELSE 'automne' END
FROM generate_series('2024-01-01'::date, '2030-12-31'::date, interval '1 day') AS d;

CREATE TABLE dim_metier (
    metier_key   smallserial PRIMARY KEY,
    metier_code  text NOT NULL UNIQUE,
    libelle      text NOT NULL
);

CREATE TABLE dim_zone (
    zone_key     smallserial PRIMARY KEY,
    departement  char(2) NOT NULL UNIQUE,
    libelle      text NOT NULL,
    couronne     text NOT NULL CHECK (couronne IN ('Paris', 'Petite couronne', 'Grande couronne'))
);

INSERT INTO dim_zone (departement, libelle, couronne) VALUES
    ('75', 'Paris', 'Paris'),
    ('92', 'Hauts-de-Seine', 'Petite couronne'),
    ('93', 'Seine-Saint-Denis', 'Petite couronne'),
    ('94', 'Val-de-Marne', 'Petite couronne'),
    ('77', 'Seine-et-Marne', 'Grande couronne'),
    ('78', 'Yvelines', 'Grande couronne'),
    ('91', 'Essonne', 'Grande couronne'),
    ('95', 'Val-d''Oise', 'Grande couronne');

-- SCD type 2 : on garde l'historique des attributs (une nouvelle ligne quand la note ou la zone change)
CREATE TABLE dim_artisan (
    artisan_key        bigserial PRIMARY KEY,
    artisan_pseudo     char(64) NOT NULL,
    metier_principal   text NOT NULL,
    departement_principal char(2) NOT NULL,
    tranche_anciennete text NOT NULL,
    tranche_note       text NOT NULL,
    valide_du          timestamptz NOT NULL,
    valide_au          timestamptz,
    est_courant        boolean NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX dim_artisan_courant ON dim_artisan (artisan_pseudo) WHERE est_courant;

CREATE TABLE dim_client (
    client_key         bigserial PRIMARY KEY,
    client_pseudo      char(64) NOT NULL UNIQUE,
    departement        char(2),
    segment            text NOT NULL CHECK (segment IN ('nouveau', 'recurrent')),
    premiere_demande   date
);

-- ---------------------------------------------------------------- Faits
CREATE TABLE fait_demande (
    demande_pseudo        char(64) PRIMARY KEY,
    date_key              integer NOT NULL REFERENCES dim_date,
    metier_key            smallint REFERENCES dim_metier,
    zone_key              smallint REFERENCES dim_zone,
    client_key            bigint NOT NULL REFERENCES dim_client,
    urgence               text,
    canal                 text NOT NULL,
    confiance_ia          numeric(4,3),
    correction_humaine    boolean NOT NULL,   -- l'IA a-t-elle été corrigée ? (qualité du modèle)
    nb_devis              smallint NOT NULL,
    convertie             boolean NOT NULL,
    delai_premier_devis_h numeric(8,2)
);

CREATE TABLE fait_intervention (
    intervention_pseudo   char(64) PRIMARY KEY,
    date_key              integer NOT NULL REFERENCES dim_date,
    metier_key            smallint REFERENCES dim_metier,
    zone_key              smallint REFERENCES dim_zone,
    artisan_key           bigint NOT NULL REFERENCES dim_artisan,
    client_key            bigint NOT NULL REFERENCES dim_client,
    montant_ttc           numeric(10,2),
    commission_artelio    numeric(10,2),
    delai_intervention_h  numeric(8,2),       -- de la demande au début de l'intervention
    duree_h               numeric(8,2),
    note_avis             smallint
);

CREATE INDEX ON fait_demande (date_key);
CREATE INDEX ON fait_demande (metier_key, zone_key);
CREATE INDEX ON fait_intervention (date_key);
CREATE INDEX ON fait_intervention (artisan_key);
CREATE INDEX ON fait_intervention (metier_key, zone_key);

-- ---------------------------------------------------------------- Pseudonymisation
CREATE FUNCTION dwh.pseudo(p_id uuid) RETURNS char(64)
LANGUAGE sql STABLE AS $$
    SELECT encode(public.hmac(p_id::text, current_setting('artelio.cle_pseudonymisation'), 'sha256'), 'hex')
$$;

-- ---------------------------------------------------------------- Chargement complet de référence
CREATE PROCEDURE dwh.rafraichir_entrepot()
SET search_path = dwh, public
LANGUAGE plpgsql AS $$
BEGIN
    TRUNCATE fait_demande, fait_intervention;
    DELETE FROM dim_client;
    DELETE FROM dim_artisan;

    INSERT INTO dim_metier (metier_code, libelle)
    SELECT code, libelle FROM app.metiers
    ON CONFLICT (metier_code) DO UPDATE SET libelle = EXCLUDED.libelle;

    INSERT INTO dim_client (client_pseudo, departement, segment, premiere_demande)
    SELECT dwh.pseudo(c.id),
           (SELECT l.departement FROM app.logements l WHERE l.client_id = c.id ORDER BY l.cree_le LIMIT 1),
           CASE WHEN count(d.id) > 1 THEN 'recurrent' ELSE 'nouveau' END,
           min(d.cree_le)::date
    FROM app.clients c LEFT JOIN app.demandes d ON d.client_id = c.id
    GROUP BY c.id;

    INSERT INTO dim_artisan (artisan_pseudo, metier_principal, departement_principal,
                             tranche_anciennete, tranche_note, valide_du)
    SELECT dwh.pseudo(a.id),
           (SELECT min(m.metier_code) FROM app.artisan_metiers m WHERE m.artisan_id = a.id),
           a.departements[1],
           CASE WHEN a.cree_le > now() - interval '6 months' THEN 'moins de 6 mois'
                WHEN a.cree_le > now() - interval '2 years' THEN '6 mois à 2 ans'
                ELSE 'plus de 2 ans' END,
           CASE WHEN a.note_moyenne IS NULL THEN 'sans note'
                WHEN a.note_moyenne >= 4.5 THEN '4,5 à 5'
                WHEN a.note_moyenne >= 4 THEN '4 à 4,5'
                ELSE 'moins de 4' END,
           now()
    FROM app.artisans a;

    INSERT INTO fait_demande
    SELECT dwh.pseudo(d.id),
           to_char(d.cree_le, 'YYYYMMDD')::integer,
           dm.metier_key, dz.zone_key, dc.client_key,
           d.urgence_predite, d.canal, d.confiance_ia,
           d.metier_valide IS NOT NULL AND d.metier_valide IS DISTINCT FROM d.metier_predit,
           (SELECT count(*) FROM app.devis v WHERE v.demande_id = d.id),
           EXISTS (SELECT 1 FROM app.devis v WHERE v.demande_id = d.id AND v.statut = 'accepte'),
           (SELECT round(extract(epoch FROM min(v.cree_le) - d.cree_le) / 3600, 2) FROM app.devis v WHERE v.demande_id = d.id)
    FROM app.demandes d
    JOIN dim_client dc ON dc.client_pseudo = dwh.pseudo(d.client_id)
    LEFT JOIN app.logements l ON l.id = d.logement_id
    LEFT JOIN dim_zone dz ON dz.departement = l.departement
    LEFT JOIN dim_metier dm ON dm.metier_code = coalesce(d.metier_valide, d.metier_predit);

    INSERT INTO fait_intervention
    SELECT dwh.pseudo(i.id),
           to_char(coalesce(i.fin_reelle, i.debut_prevu), 'YYYYMMDD')::integer,
           dm.metier_key, dz.zone_key, da.artisan_key, dc.client_key,
           f.montant_ttc, f.commission_artelio,
           round(extract(epoch FROM coalesce(i.debut_reel, i.debut_prevu) - d.cree_le) / 3600, 2),
           round(extract(epoch FROM i.fin_reelle - i.debut_reel) / 3600, 2),
           av.note
    FROM app.interventions i
    JOIN app.devis v ON v.id = i.devis_id
    JOIN app.demandes d ON d.id = v.demande_id
    JOIN dim_client dc ON dc.client_pseudo = dwh.pseudo(d.client_id)
    JOIN dim_artisan da ON da.artisan_pseudo = dwh.pseudo(i.artisan_id) AND da.est_courant
    LEFT JOIN app.logements l ON l.id = d.logement_id
    LEFT JOIN dim_zone dz ON dz.departement = l.departement
    LEFT JOIN dim_metier dm ON dm.metier_code = coalesce(d.metier_valide, d.metier_predit)
    LEFT JOIN app.factures f ON f.intervention_id = i.id
    LEFT JOIN app.avis av ON av.intervention_id = i.id;
END;
$$;
