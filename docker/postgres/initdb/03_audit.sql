-- =============================================================================
-- Journal d'audit : qui a créé, modifié ou supprimé une donnée personnelle, et quand.
-- On trace l'opération et l'identifiant de la ligne, pas son contenu
-- (sinon le journal deviendrait lui-même une copie des données personnelles).
-- Le journal est en ajout seul : personne ne peut le modifier ou le supprimer.
-- =============================================================================

CREATE SCHEMA audit;

CREATE TABLE audit.journal (
    id           bigserial PRIMARY KEY,
    horodatage   timestamptz NOT NULL DEFAULT now(),
    utilisateur  text NOT NULL DEFAULT session_user,
    operation    text NOT NULL CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
    table_cible  text NOT NULL,
    cle_ligne    text
);

CREATE INDEX ON audit.journal (horodatage);
CREATE INDEX ON audit.journal (table_cible, cle_ligne);

CREATE FUNCTION audit.tracer() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = audit, pg_temp AS $$
DECLARE
    ligne jsonb := CASE WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
BEGIN
    INSERT INTO audit.journal (operation, table_cible, cle_ligne)
    VALUES (TG_OP, TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
            coalesce(ligne ->> 'id', ligne ->> 'demande_id'));
    RETURN NULL;  -- trigger AFTER : la valeur de retour est ignorée
END;
$$;

-- Tables contenant des données personnelles
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['clients', 'logements', 'consentements', 'artisans', 'demandes',
                             'photos_demande', 'besoins_accessibilite', 'messages', 'factures']
    LOOP
        EXECUTE format('CREATE TRIGGER audit_%1$s AFTER INSERT OR UPDATE OR DELETE ON app.%1$I
                        FOR EACH ROW EXECUTE FUNCTION audit.tracer()', t);
    END LOOP;
END;
$$;

-- Détection d'anomalies : un compte qui modifie ou supprime en masse des données personnelles
-- (hors purges du DPO) peut signaler une compromission ou une erreur grave. Appelée par le
-- pipeline de qualité (bloc 3), qui déclenche une alerte : premier maillon de la procédure
-- de gestion des violations (plan de gouvernance §11.1).
CREATE FUNCTION audit.detecter_anomalies(p_fenetre interval DEFAULT '1 hour', p_seuil integer DEFAULT 500)
RETURNS TABLE (utilisateur text, operation text, table_cible text, nb_lignes bigint)
LANGUAGE sql SECURITY DEFINER SET search_path = audit, pg_temp AS $$
    SELECT j.utilisateur, j.operation, j.table_cible, count(*)
    FROM audit.journal j
    WHERE j.horodatage > now() - p_fenetre
      AND j.operation IN ('UPDATE', 'DELETE')
      AND j.utilisateur <> 'dpo_officer'
    GROUP BY 1, 2, 3
    HAVING count(*) > p_seuil
$$;

-- Ajout seul : même le propriétaire applicatif ne peut pas réécrire l'historique
CREATE FUNCTION audit.interdire_modification() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Le journal d''audit est en ajout seul (opération % refusée)', TG_OP;
END;
$$;

CREATE TRIGGER journal_ajout_seul BEFORE UPDATE OR DELETE ON audit.journal
    FOR EACH ROW EXECUTE FUNCTION audit.interdire_modification();
