# Cahier des charges d'architecture — Plateforme data Artelio

> Version 1.0 — octobre 2026 — Auteur : Jean-Christophe Dorn (Architecte IA / Head of Data)
> Artelio est une organisation fictive créée pour la certification « Architecte en Intelligence Artificielle ».

## 1. Contexte

Artelio est une marketplace qui met en relation des particuliers et des artisans du bâtiment en Île-de-France
(plomberie, électricité, serrurerie, chauffage, peinture…). Un client décrit son problème (texte et photos),
une IA qualifie la demande (métier et urgence), propose des artisans, qui envoient des devis. L'intervention
donne lieu à une facture et alimente la « fiche habitation » du logement.

La plateforme data doit stocker et faire circuler ces données, alimenter les tableaux de bord et l'IA,
tout en respectant le plan de gouvernance des données (bloc 1).

## 2. Besoins fonctionnels

| # | Besoin | Exemple |
|---|---|---|
| F1 | Stocker les données transactionnelles de la marketplace | Comptes, demandes, devis, interventions, factures |
| F2 | Stocker des données semi-structurées | Messages avec métadonnées variables, lignes de devis |
| F3 | Stocker des fichiers volumineux | Photos des demandes, factures PDF, sauvegardes |
| F4 | Transporter des événements en temps réel | Nouvelle demande, message, disponibilité d'artisan |
| F5 | Fournir des indicateurs analytiques | Demandes par métier et par mois, délais, chiffre d'affaires |
| F6 | Fournir des données d'entraînement à l'IA | Textes de demandes pseudonymisés et étiquetés |
| F7 | Répondre aux demandes RGPD | Export (accès, portabilité), effacement, purge selon les durées de conservation |

## 3. Volumétrie et exigences non fonctionnelles

### 3.1 Les « 3 V » des données

| Dimension | Aujourd'hui | Dans 2 ans (×3, ouverture Lyon et Lille) | Conséquence d'architecture |
|---|---|---|---|
| **Volume** — base transactionnelle | ~10 000 demandes et 250 000 messages / mois → ~5 Go / an | ~15 Go / an | PostgreSQL suffit largement, avec de la marge |
| **Volume** — fichiers | 60 000 photos / mois × 2 Mo = **~120 Go / mois** | ~360 Go / mois | Stockage objet séparé, extensible en ajoutant des volumes |
| **Vélocité** | ~5 M événements / mois, pics à **~200 événements/s** (soirées d'hiver) | ~600 événements/s | Bus d'événements (Kafka) qui absorbe les pics |
| **Variété** | Structuré (SQL), semi-structuré (JSON), non structuré (images) | + audio (demandes vocales) | Trois modes de stockage adaptés |

### 3.2 Exigences de qualité de service

| # | Exigence | Cible | Justification |
|---|---|---|---|
| NF1 | Disponibilité de la base transactionnelle | 99,5 % (≈ 3 h 40 d'arrêt par mois au maximum) | Les urgences (fuite, porte claquée) n'attendent pas |
| NF2 | Perte de données maximale (RPO) | 1 h (sauvegardes), quasi nulle (réplica) | Plan de gouvernance §11.2 |
| NF3 | Temps de reprise après sinistre (RTO) | 8 h maximum | Plan de gouvernance §11.2 |
| NF4 | Latence du flux temps réel | Événement disponible pour les pipelines en moins de 5 s | Qualification IA rapide des urgences |
| NF5 | Évolutivité | ×3 sans changer d'architecture | Plan de croissance |
| NF6 | Observabilité | Supervision de chaque composant, alerte en moins de 2 min | Détecter avant les clients |
| NF7 | Reproductibilité | Environnement complet recréé en une commande | Infrastructure as Code |

### 3.3 Exigences de sécurité et de conformité

| # | Exigence | Référence |
|---|---|---|
| S1 | Chiffrement des données en transit (TLS) et au repos | RGPD art. 32, ISO 27001 A.8.24 |
| S2 | Moindre privilège : un compte par usage, droits minimaux | ISO 27001 A.5.15, ANSSI (guide d'hygiène, gestion des droits) |
| S3 | Traçabilité des opérations sur les données personnelles | RGPD art. 5.2 (redevabilité), ISO 27001 A.8.15 |
| S4 | Pseudonymisation des données analytiques et d'entraînement | RGPD art. 25 et 32 |
| S5 | Droits des personnes : accès, portabilité, effacement | RGPD art. 15, 17, 20 |
| S6 | Durées de conservation appliquées automatiquement | RGPD art. 5.1.e, plan de gouvernance §5.2 |
| S7 | Conservation des factures 10 ans malgré une demande d'effacement | Code de commerce L123-22 |
| S8 | Données de santé (besoins d'accessibilité) isolées et chiffrées | RGPD art. 9 |
| S9 | Aucune donnée hors de l'Union européenne | RGPD chapitre V |
| S10 | Segmentation réseau, exposition minimale | ANSSI (cloisonnement) |
| S11 | Aucun secret dans le code source | ANSSI, bonnes pratiques DevSecOps |

## 4. Contraintes

- **Budget** : start-up de 35 personnes, pas d'hyperscaler imposé. Préférence pour des logiciels **open source**,
  sans dépendance forte à un fournisseur (réversibilité).
- **Équipe** : 4 personnes en data → des composants standards, bien documentés, faciles à exploiter.
- **Souveraineté** : hébergement en UE ; l'environnement de référence est conteneurisé et peut tourner
  sur site, chez un hébergeur français ou sur Railway (région UE).
- **Données de test** : aucune donnée réelle hors production → jeu de données synthétiques.

## 5. Traçabilité exigences → solution

| Exigences | Réponse | Où dans le code |
|---|---|---|
| F1, F2 | PostgreSQL 16, schéma `app` (tables relationnelles + colonnes JSONB) | `docker/postgres/initdb/02_schema_app.sql` |
| F3 | Stockage objet S3 SeaweedFS (buckets `photos`, `factures`, `backups`) | `terraform/object_storage.tf` |
| F4, NF4 | Apache Kafka (KRaft), 5 topics partitionnés | `terraform/kafka.tf` |
| F5, F6, S4 | Entrepôt en étoile `dwh`, identifiants pseudonymisés (HMAC-SHA256) | `docker/postgres/initdb/05_dwh.sql` |
| F7, S5, S6, S7 | Fonctions `rgpd.*` et registre des demandes | `docker/postgres/initdb/04_rgpd.sql` |
| NF1, NF2 | Réplica en flux + sauvegardes horaires chiffrées | `terraform/postgres.tf`, `terraform/backup.tf` |
| NF3 | Restauration testée, infrastructure recréable en une commande | `scripts/restore_test.sh`, `scripts/deploy.sh` |
| NF6 | Prometheus, Alertmanager, Grafana, 8 règles d'alerte | `terraform/monitoring.tf`, `docker/monitoring/` |
| NF7, S11 | Terraform, secrets générés et jamais versionnés | `terraform/secrets.tf`, `.gitignore` |
| S1 | TLS 1.2+ obligatoire sur PostgreSQL (PKI interne générée par Terraform), chiffrement des volumes S3 | `docker/postgres/scripts/pg_hba.conf` |
| S2 | 7 rôles PostgreSQL, 3 identités S3 limitées à leurs buckets | `01_roles.sh`, `06_grants.sql` |
| S3 | Journal d'audit en ajout seul | `03_audit.sql` |
| S8 | Table séparée, colonne chiffrée (pgcrypto), inaccessible au pipeline | `02_schema_app.sql`, `06_grants.sql` |
| S10 | Réseau `backend` interne sans accès Internet, ports publiés sur 127.0.0.1 uniquement | `terraform/main.tf` |
