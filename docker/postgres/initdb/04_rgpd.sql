-- =============================================================================
-- Mécanismes RGPD intégrés à la base (plan de gouvernance, §5.2 et §5.3)
--   rgpd.exporter_client()          → droit d'accès et de portabilité (art. 15 et 20)
--   rgpd.effacer_client()           → droit à l'effacement (art. 17), en respectant
--                                     l'obligation légale de conserver les factures 10 ans
--   rgpd.purger_donnees_expirees()  → application automatique des durées de conservation
-- Les fonctions sont SECURITY DEFINER : le DPO peut les exécuter sans avoir d'accès
-- direct aux tables. Chaque appel est tracé dans rgpd.registre_demandes.
-- =============================================================================

CREATE SCHEMA rgpd;

CREATE TABLE rgpd.registre_demandes (
    id            bigserial PRIMARY KEY,
    client_id     uuid NOT NULL,
    type_demande  text NOT NULL CHECK (type_demande IN ('acces', 'portabilite', 'effacement', 'rectification', 'opposition', 'purge_automatique')),
    recue_le      timestamptz NOT NULL DEFAULT now(),
    traitee_le    timestamptz,
    traitee_par   text NOT NULL DEFAULT session_user,
    resultat      jsonb
);

-- ---------------------------------------------------------------- Accès / portabilité
CREATE FUNCTION rgpd.exporter_client(p_client_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = app, public, pg_temp AS $$
DECLARE
    export jsonb;
    cle    text := current_setting('artelio.cle_chiffrement', true);
BEGIN
    IF NOT EXISTS (SELECT 1 FROM clients WHERE id = p_client_id) THEN
        RAISE EXCEPTION 'Client % inconnu', p_client_id USING ERRCODE = 'no_data_found';
    END IF;

    SELECT jsonb_build_object(
        'format', 'artelio-export-rgpd-v1',
        'genere_le', now(),
        'client', (SELECT to_jsonb(c) FROM clients c WHERE c.id = p_client_id),
        'logements', (SELECT coalesce(jsonb_agg(to_jsonb(l)), '[]') FROM logements l WHERE l.client_id = p_client_id),
        'consentements', (SELECT coalesce(jsonb_agg(to_jsonb(k) ORDER BY k.horodatage), '[]') FROM consentements k WHERE k.client_id = p_client_id),
        'demandes', (
            SELECT coalesce(jsonb_agg(
                to_jsonb(d) || jsonb_build_object(
                    'messages', (SELECT coalesce(jsonb_agg(to_jsonb(m) ORDER BY m.envoye_le), '[]') FROM messages m WHERE m.demande_id = d.id),
                    'photos',   (SELECT coalesce(jsonb_agg(jsonb_build_object('cle_objet', p.cle_objet, 'televersee_le', p.televersee_le)), '[]')
                                 FROM photos_demande p WHERE p.demande_id = d.id),
                    'besoins_accessibilite', (
                        SELECT CASE WHEN cle IS NULL THEN '"[chiffré — clé non disponible]"'::jsonb
                                    ELSE to_jsonb(pgp_sym_decrypt(b.description_chiffree, cle)) END
                        FROM besoins_accessibilite b WHERE b.demande_id = d.id),
                    'devis', (SELECT coalesce(jsonb_agg(to_jsonb(v)), '[]') FROM devis v WHERE v.demande_id = d.id)
                ) ORDER BY d.cree_le), '[]')
            FROM demandes d WHERE d.client_id = p_client_id),
        'factures', (
            SELECT coalesce(jsonb_agg(to_jsonb(f)), '[]')
            FROM factures f
            JOIN interventions i ON i.id = f.intervention_id
            JOIN devis v ON v.id = i.devis_id
            JOIN demandes d ON d.id = v.demande_id
            WHERE d.client_id = p_client_id)
    ) INTO export;

    INSERT INTO rgpd.registre_demandes (client_id, type_demande, traitee_le, resultat)
    VALUES (p_client_id, 'acces', now(), jsonb_build_object('taille_export_octets', length(export::text)));

    RETURN export;
END;
$$;

-- ---------------------------------------------------------------- Effacement
-- Renvoie un résumé, dont la liste des photos à supprimer dans le stockage objet
-- (la suppression des fichiers est faite par scripts/rgpd_demo.py, puisque la base n'a pas accès au S3).
CREATE FUNCTION rgpd.effacer_client(p_client_id uuid, p_type text DEFAULT 'effacement') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = app, public, pg_temp AS $$
DECLARE
    photos       text[];
    n_messages   integer;
    n_demandes   integer;
    n_logements  integer;
    n_factures   integer;
    resultat     jsonb;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM clients WHERE id = p_client_id AND statut = 'actif') THEN
        RAISE EXCEPTION 'Client % inconnu ou déjà effacé', p_client_id USING ERRCODE = 'no_data_found';
    END IF;

    SELECT coalesce(array_agg(p.cle_objet), '{}') INTO photos
    FROM photos_demande p JOIN demandes d ON d.id = p.demande_id
    WHERE d.client_id = p_client_id;

    -- Contenus libres et pièces jointes : supprimés
    DELETE FROM messages m USING demandes d WHERE m.demande_id = d.id AND d.client_id = p_client_id;
    GET DIAGNOSTICS n_messages = ROW_COUNT;
    DELETE FROM photos_demande p USING demandes d WHERE p.demande_id = d.id AND d.client_id = p_client_id;
    DELETE FROM besoins_accessibilite b USING demandes d WHERE b.demande_id = d.id AND d.client_id = p_client_id;
    UPDATE avis a SET commentaire = NULL
    FROM interventions i JOIN devis v ON v.id = i.devis_id JOIN demandes d ON d.id = v.demande_id
    WHERE a.intervention_id = i.id AND d.client_id = p_client_id;

    -- Demandes sans facture : supprimées. Demandes facturées : conservées mais vidées de leur texte,
    -- car la facture (obligation légale de 10 ans) doit rester rattachée à son intervention.
    DELETE FROM demandes d
    WHERE d.client_id = p_client_id
      AND NOT EXISTS (SELECT 1 FROM devis v JOIN interventions i ON i.devis_id = v.id
                      JOIN factures f ON f.intervention_id = i.id WHERE v.demande_id = d.id);
    GET DIAGNOSTICS n_demandes = ROW_COUNT;
    UPDATE demandes SET description = '[effacé à la demande du client]' WHERE client_id = p_client_id;

    DELETE FROM logements WHERE client_id = p_client_id;
    GET DIAGNOSTICS n_logements = ROW_COUNT;
    DELETE FROM consentements WHERE client_id = p_client_id;

    SELECT count(*) INTO n_factures
    FROM factures f JOIN interventions i ON i.id = f.intervention_id
    JOIN devis v ON v.id = i.devis_id JOIN demandes d ON d.id = v.demande_id
    WHERE d.client_id = p_client_id;

    -- Le compte est conservé sous forme anonyme pour ne pas casser les références des factures
    UPDATE clients
    SET email = 'efface+' || id || '@artelio.invalid', prenom = NULL, nom = NULL, telephone = NULL,
        statut = 'efface', efface_le = now()
    WHERE id = p_client_id;

    resultat := jsonb_build_object(
        'client_id', p_client_id,
        'messages_supprimes', n_messages,
        'demandes_supprimees', n_demandes,
        'logements_supprimes', n_logements,
        'factures_conservees_obligation_legale', n_factures,
        'photos_a_supprimer', to_jsonb(photos));

    INSERT INTO rgpd.registre_demandes (client_id, type_demande, traitee_le, resultat)
    VALUES (p_client_id, p_type, now(), resultat);

    RETURN resultat;
END;
$$;

-- ---------------------------------------------------------------- Durées de conservation
-- Appelée chaque nuit par l'orchestrateur (bloc 3). Renvoie les compteurs et les photos à supprimer.
CREATE FUNCTION rgpd.purger_donnees_expirees() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = app, public, pg_temp AS $$
DECLARE
    n_positions  integer;
    n_besoins    integer;
    photos       text[];
    clients_inactifs uuid[];
    c            uuid;
    photos_clients text[] := '{}';
    r            jsonb;
BEGIN
    -- Géolocalisation des artisans : 24 h
    DELETE FROM positions_artisans WHERE enregistree_le < now() - interval '24 hours';
    GET DIAGNOSTICS n_positions = ROW_COUNT;

    -- Besoins d'accessibilité (donnée de santé) : date d'expiration fixée à la collecte
    DELETE FROM besoins_accessibilite WHERE expire_le < now();
    GET DIAGNOSTICS n_besoins = ROW_COUNT;

    -- Photos : 12 mois après la fin de l'intervention, sauf si le client les a gardées dans sa fiche habitation
    WITH expirees AS (
        DELETE FROM photos_demande p
        USING demandes d
        LEFT JOIN logements l ON l.id = d.logement_id
        WHERE p.demande_id = d.id
          AND coalesce(l.fiche_habitation_active, false) = false
          AND EXISTS (SELECT 1 FROM devis v JOIN interventions i ON i.devis_id = v.id
                      WHERE v.demande_id = d.id AND i.fin_reelle < now() - interval '12 months')
        RETURNING p.cle_objet)
    SELECT coalesce(array_agg(cle_objet), '{}') INTO photos FROM expirees;

    -- Comptes clients inactifs depuis 3 ans : effacés
    SELECT coalesce(array_agg(id), '{}') INTO clients_inactifs
    FROM clients WHERE statut = 'actif' AND derniere_activite < now() - interval '3 years';
    FOREACH c IN ARRAY clients_inactifs LOOP
        r := rgpd.effacer_client(c, 'purge_automatique');
        photos_clients := photos_clients || ARRAY(SELECT jsonb_array_elements_text(r -> 'photos_a_supprimer'));
    END LOOP;

    RETURN jsonb_build_object(
        'execute_le', now(),
        'positions_supprimees', n_positions,
        'besoins_accessibilite_supprimes', n_besoins,
        'clients_inactifs_effaces', cardinality(clients_inactifs),
        'photos_a_supprimer', to_jsonb(photos || photos_clients));
END;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA rgpd FROM PUBLIC;
