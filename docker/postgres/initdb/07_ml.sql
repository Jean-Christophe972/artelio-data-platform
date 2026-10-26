-- =============================================================================
-- Service IA (bloc 4) : compte "ml_service" et schéma "ml"
--   - lit les demandes à qualifier (colonnes utiles uniquement : pas d'identité du client)
--   - écrit les prédictions du modèle (métier, urgence, confiance) dans app.demandes
--   - journalise chaque prédiction (texte masqué) dans ml.predictions : base de la
--     détection de dérive et de l'audit des décisions de l'IA (AI Act, plan de gouvernance §8)
-- Le mot de passe est défini par 01_roles.sh (variable ML_SERVICE_PASSWORD).
-- =============================================================================

GRANT USAGE ON SCHEMA app TO ml_service;
GRANT SELECT (id, description, canal, statut, cree_le, metier_predit, urgence_predite, metier_valide) ON app.demandes TO ml_service;
GRANT UPDATE (metier_predit, urgence_predite, confiance_ia, statut) ON app.demandes TO ml_service;
GRANT SELECT ON app.metiers TO ml_service;

CREATE SCHEMA ml AUTHORIZATION ml_service;
GRANT USAGE ON SCHEMA ml TO dpo_officer, analyst;
