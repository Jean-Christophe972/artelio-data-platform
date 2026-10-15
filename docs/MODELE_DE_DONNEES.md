# Modèle de données

Deux modèles complémentaires dans la même base PostgreSQL :

- **`app`** — modèle **relationnel normalisé** (OLTP) : optimisé pour écrire vite et sans incohérence.
- **`dwh`** — modèle **en étoile** (OLAP) : optimisé pour analyser vite, sans données identifiantes.

## 1. Modèle transactionnel (schéma `app`)

```mermaid
erDiagram
    CLIENTS ||--o{ LOGEMENTS : possede
    CLIENTS ||--o{ CONSENTEMENTS : donne
    CLIENTS ||--o{ DEMANDES : cree
    LOGEMENTS ||--o{ DEMANDES : concerne
    DEMANDES ||--o{ PHOTOS_DEMANDE : contient
    DEMANDES ||--o| BESOINS_ACCESSIBILITE : "precise (chiffre)"
    DEMANDES ||--o{ MESSAGES : echange
    DEMANDES ||--o{ DEVIS : recoit
    METIERS ||--o{ DEMANDES : "predit / valide"
    ARTISANS ||--o{ ARTISAN_METIERS : exerce
    METIERS ||--o{ ARTISAN_METIERS : ""
    ARTISANS ||--o{ DEVIS : propose
    ARTISANS ||--o{ POSITIONS_ARTISANS : "geolocalise (24 h)"
    DEVIS ||--o| INTERVENTIONS : declenche
    INTERVENTIONS ||--o| FACTURES : "donne lieu a (10 ans)"
    INTERVENTIONS ||--o| AVIS : "est notee"

    CLIENTS {
        uuid id PK
        text email UK
        text prenom
        text nom
        text telephone
        text statut "actif / efface"
        timestamptz derniere_activite
    }
    LOGEMENTS {
        uuid id PK
        uuid client_id FK
        text adresse
        char departement "IDF uniquement"
        bool fiche_habitation_active "consentement"
    }
    DEMANDES {
        uuid id PK
        uuid client_id FK
        text description "texte libre analyse par l'IA"
        text metier_predit FK "IA"
        text urgence_predite "IA"
        numeric confiance_ia
        text metier_valide FK "correction humaine"
        text statut
    }
    MESSAGES {
        uuid id PK
        uuid demande_id FK
        text contenu
        jsonb metadonnees "semi-structure"
    }
    PHOTOS_DEMANDE {
        uuid id PK
        text cle_objet UK "reference S3"
        char empreinte_sha256
    }
    DEVIS {
        uuid id PK
        jsonb lignes "semi-structure"
        numeric montant_ht
        numeric montant_ttc "calcule"
    }
    FACTURES {
        uuid id PK
        text numero UK
        text nom_facturation "copie legale"
        numeric commission_artelio
    }
    ARTISANS {
        uuid id PK
        char siret UK
        char_array departements
        date assurance_decennale_expire_le
        text statut
    }
```

### Règles d'intégrité portées par la base (et pas seulement par l'application)

| Règle | Mise en œuvre |
|---|---|
| Uniquement l'Île-de-France | `CHECK (departement IN ('75','77','78','91','92','93','94','95'))` |
| SIRET valide | `CHECK (siret ~ '^[0-9]{14}$')` + unicité |
| TVA légale du bâtiment | `CHECK (taux_tva IN (0.055, 0.100, 0.200))` |
| Montant TTC jamais faux | Colonne **calculée** : `montant_ht × (1 + taux_tva)` |
| Photo ≤ 15 Mo, format image | `CHECK` sur la taille et le type MIME |
| Une facture ne disparaît pas | `ON DELETE RESTRICT` + aucun droit `DELETE` pour l'application |
| Emails normalisés | `CHECK (email = lower(email))` |

## 2. Entrepôt en étoile (schéma `dwh`)

```mermaid
erDiagram
    DIM_DATE ||--o{ FAIT_DEMANDE : ""
    DIM_METIER ||--o{ FAIT_DEMANDE : ""
    DIM_ZONE ||--o{ FAIT_DEMANDE : ""
    DIM_CLIENT ||--o{ FAIT_DEMANDE : ""
    DIM_DATE ||--o{ FAIT_INTERVENTION : ""
    DIM_METIER ||--o{ FAIT_INTERVENTION : ""
    DIM_ZONE ||--o{ FAIT_INTERVENTION : ""
    DIM_CLIENT ||--o{ FAIT_INTERVENTION : ""
    DIM_ARTISAN ||--o{ FAIT_INTERVENTION : ""

    FAIT_DEMANDE {
        char demande_pseudo PK "HMAC"
        int date_key FK
        int metier_key FK
        int zone_key FK
        bigint client_key FK
        text urgence
        bool correction_humaine "qualite IA"
        int nb_devis
        bool convertie
        numeric delai_premier_devis_h
    }
    FAIT_INTERVENTION {
        char intervention_pseudo PK "HMAC"
        int date_key FK
        bigint artisan_key FK
        numeric montant_ttc
        numeric commission_artelio
        numeric delai_intervention_h
        smallint note_avis
    }
    DIM_DATE {
        int date_key PK "AAAAMMJJ"
        text saison "saisonnalite"
        bool est_week_end
    }
    DIM_ARTISAN {
        bigint artisan_key PK
        char artisan_pseudo "HMAC"
        text tranche_note
        timestamptz valide_du "SCD 2"
        timestamptz valide_au "SCD 2"
        bool est_courant
    }
    DIM_ZONE {
        int zone_key PK
        char departement
        text couronne
    }
```

### Choix de modélisation

| Choix | Raison |
|---|---|
| **Deux tables de faits** au grain différent (demande, intervention) | Toutes les demandes ne deviennent pas des interventions : les mélanger fausserait les taux de conversion. |
| **Dimension date** pré-calculée (2024 → 2030) avec la **saison** | Les analyses de saisonnalité (chauffage en hiver) n'ont pas à recalculer les dates. |
| **Dimension artisan historisée (SCD type 2)** | Si un artisan change de zone ou de note, les interventions passées restent rattachées à ses caractéristiques de l'époque. |
| **Tranches** plutôt que valeurs exactes (note, ancienneté) | Minimisation : l'analyse n'a pas besoin de la valeur exacte, et une tranche identifie moins. |
| **Identifiants pseudonymisés** (HMAC-SHA256 avec clé secrète) | Un analyste ne peut pas remonter à la personne ; un simple hachage sans clé serait réversible par force brute sur les UUID connus. |
| `correction_humaine` dans les faits | Mesure en continu de la qualité du modèle IA (supervision humaine exigée par le plan de gouvernance). |

## 3. Où va chaque type de donnée

| Type | Exemple | Stockage | Accès |
|---|---|---|---|
| Structuré | Clients, devis, factures | PostgreSQL `app` (tables) | SQL, TLS |
| Semi-structuré | Métadonnées des messages, lignes de devis | PostgreSQL `app` (JSONB indexé GIN) | SQL + opérateurs JSON |
| Non structuré | Photos, factures PDF | Stockage objet S3 (la base garde la clé et l'empreinte SHA-256) | API S3 |
| Flux d'événements | Demande créée, message envoyé | Kafka (7 jours) | Producteurs / consommateurs |
| Analytique | Indicateurs | PostgreSQL `dwh` (étoile) | SQL, compte `analyst`, sur le réplica |
