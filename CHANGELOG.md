# Changelog

Toutes les modifications notables de ce projet sont documentées dans ce fichier.

Le format est basé sur [Keep a Changelog](https://keepachangelog.com/fr/1.0.0/),
et ce projet adhère au [Semantic Versioning](https://semver.org/lang/fr/).

## [4.0.0] - 2026-08-25

### Ajouté
- **Migration complète vers Alpine Linux** (OpenRC + apk) : consommation RAM divisée par 3 (< 60 Mo en production), empreinte disque < 50 Mo.
- **Bootstrap POSIX `/bin/sh`** (`setup.sh`) avec auto-installation des dépendances initiales (`bash`, `curl`, `tar`, `jq`, `coreutils`) sur conteneur Alpine minimal.
- **Gestionnaire de services OpenRC** : support natif de `rc-service` et `rc-update` pour Unbound et AdGuard Home.
- **Tuning OpenRC & limites ressources** : configuration automatique de `/etc/conf.d/unbound` (`rc_ulimit`, `rc_nice`) et `/etc/security/limits.d/99-unbound.conf`.
- **Persistance du cache Unbound via cron périodique** : intégration dans `/etc/periodic/hourly/unbound-cache-persist`.

### Modifié
- Version du script : 3.5.0 → 4.0.0
- Remplacement d'`apt-get`/`dpkg` par `apk` (`apk add --no-cache`, `apk info -e`).
- Mapping des paquets pour Alpine (`bind-tools`, `newt`, `py3-yaml`, `iproute2`, `apache2-utils`).
- Suppression de la gestion de `systemd-resolved` (inutile sur Alpine Linux).
- Mise à jour de la documentation et de la suite de tests pour Alpine.

## [3.4.2] - 2026-05-16

### Ajouté
- **Cache pre-warming** : résout 25 domaines courants au boot (hit rate 0%→30%+)
- **Upstream failover** : 2ème fournisseur en fallback automatique
- **AGH disable_ipv6** : -30% de requêtes AAAA inutiles

### Modifié
- Version du script : 3.4.1 → 3.4.2
- **Cache Unbound doublé** pour tier ≤512MB : 128m rrset + 64m msg
- **so-reuseport: no** sur 1 cœur (économie syscall)
- **BBR fallback** : détection auto, fallback cubic si indisponible

### Corrigé
- **Arithmetic increment** : `(( var++ ))` → `$(( var + 1 ))` (crash avec set -e quand var=0)

## [3.4.1] - 2026-05-16

### Ajouté
- **Option reset mot de passe** AdGuard Home dans le menu interactif
- **Détection limites cgroup LXC** (CPU/RAM) pour auto-config précise
- **Préfetch parallèle** AdGuard Home pendant l'installation Unbound

### Modifié
- Version du script : 3.2.5 → 3.4.1
- **Cache Unbound doublé** pour tier ≤512MB : 128m rrset + 64m msg (was 64m/32m)
  - Cache hit rate cible : ~50% (was 20.8%)
- **Verbosité Unbound à 0** (économie CPU sur 1 cœur)
- **use-caps-for-id: no** (élimine requêtes sortantes dupliquées, DoT+DNSSEC suffisent)
- **serve-expired-reply-ttl: 60** (clients cachent 2× plus longtemps)
- **AGH cache_size: 0** (Unbound gère seul le cache, pas de duplication)
- **AGH bootstrap_dns** réduit à `1.1.1.1` (was 2 serveurs)
- **Menu interactif modernisé** avec labels dynamiques selon état d'installation
- **Flux d'installation simplifié** et durci

### Corrigé
- **Whiptail** : suppression du piège ERR dans les subshells (évite erreurs sur Cancel)
- **Whiptail** : nettoyage accents dans les chaînes (prévient troncation et wrapping awk)
- **Unbound** : suppression directive invalide `val-cache-size`
- **DNSSEC** : réparation trust anchor pendant les diagnostics
- **DNSSEC** : désactivation automatique des directives dupliquées
- **DNSSEC** : scope de réparation limité (ne touche pas les configs externes)
- **Root hints** : remplacement `timeout` externe par boucle bash native
- **bash -c** : échec gracieux avec message de bootstrap recommandé
- **Radiolist upstream** : adaptation aux petits terminaux
- **gitignore** : ajout `data/` (artefacts runtime agentmemory)

### Technique
- Configuration MCP agentmemory avec chemin absolu npx (compatibilité OpenCode)
- Tous les changements validés par shellcheck (0 warning/error)
- Suite de tests : 42/42 passants

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
