# Changelog

Toutes les modifications notables de ce projet sont documentées dans ce fichier.

Le format est basé sur [Keep a Changelog](https://keepachangelog.com/fr/1.0.0/),
et ce projet adhère au [Semantic Versioning](https://semver.org/lang/fr/).

## [Non publié]

### En cours
- Amélioration continue de la suite de tests
- Documentation exemples d'utilisation avancée

## [3.2.5] - 2026-04-12

### Ajouté
- **Intégration bibliothèques utilitaires** dans `install_unbound_interactive.sh`
  - Chargement automatique de `lib/common.sh` et `lib/health_checks.sh`
  - Retry logic pour téléchargement AdGuard Home (3 tentatives)
  - Retry logic pour API GitHub (récupération version)
  - Backup automatique avant modification configuration AdGuard
  - Redémarrage sécurisé des services avec health check
  - Health check post-installation automatique

### Modifié
- Version du script : 3.2.4 → 3.2.5
- Fonction `install_adguard_home()` : utilise `download_with_retry()`
- Fonction `install_adguard_home()` : utilise `fetch_json_api()` pour version
- Fonction `configure_adguard_upstream()` : utilise `create_backup()`
- Fonction `install_unbound()` : utilise `restart_service_safely()`
- Menu principal : affiche résultat health check complet après installation

### Technique
- Compatibilité descendante : fallback vers méthodes originales si libs non disponibles
- Toutes les nouvelles fonctions utilisent `type cmd &>/dev/null` pour vérifier disponibilité
- Syntaxe bash validée avec `bash -n`
- Tests d'intégration passent (7/7 fonctions critiques disponibles)

## [3.2.4] - 2026-04-12

### Ajouté
- Bibliothèque `lib/common.sh` avec 12+ fonctions utilitaires
- Bibliothèque `lib/health_checks.sh` avec diagnostics DNS complets
- Suite de tests `tests/test_suite.sh` avec 25 tests automatisés
- Documentation `CONTRIBUTING.md` pour contributeurs
- Documentation `USAGE_GUIDE.md` avec exemples d'utilisation
- Documentation `IMPROVEMENTS.md` détaillant les améliorations

### Technique
- Standards bash-pro appliqués (retry logic, validation, backup)
- Tests unitaires pour toutes les fonctions critiques
- Framework de test avec compteurs pass/fail
- Health checks Unbound & AdGuard (5 vérifications chacun)
- Benchmark performance DNS

## [3.2.0] - Précédent

### Ajouté
- Auto-update du script depuis GitHub
- Menu interactif avec Whiptail
- Support multi-architecture (amd64, arm64, armv7)

### Modifié
- Optimisation configuration Unbound basée sur ressources système
- Calcul automatique threads & slabs (puissance de 2)
- Profils mémoire adaptatifs (Micro à Premium)

## [3.1.0] - Précédent

### Ajouté
- Menu "Réparer / Optimiser"
- Menu "Stats Unbound"
- Menu "Désinstaller"

### Modifié
- Interface utilisateur améliorée
- Gestion erreurs renforcée

## [3.0.0] - Précédent

### Ajouté
- Installation AdGuard Home
- Configuration Unbound optimisée
- DNS-over-TLS (Cloudflare, Quad9)
- Optimisations sysctl

---

## Convention de Versioning

- **MAJOR** : Changements incompatibles avec versions précédentes
- **MINOR** : Ajout de fonctionnalités rétrocompatibles
- **PATCH** : Corrections de bugs rétrocompatibles

## Types de Changements

- **Ajouté** : Nouvelles fonctionnalités
- **Modifié** : Changements de fonctionnalités existantes
- **Déprécié** : Fonctionnalités bientôt supprimées
- **Supprimé** : Fonctionnalités retirées
- **Corrigé** : Corrections de bugs
- **Sécurité** : Corrections de vulnérabilités
