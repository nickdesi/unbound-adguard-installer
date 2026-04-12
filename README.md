# AdGuard Home & Unbound All-in-One Installer pour Proxmox LXC

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Ce script Bash installe et configure **AdGuard Home** et **Unbound** comme solution DNS complète sur un conteneur **Proxmox LXC** (basé sur Debian/Ubuntu).

Inspiré par le style des [Proxmox VE Helper-Scripts](https://tteck.github.io/Proxmox/), il propose une **interface interactive** (menu Whiptail) et une configuration **ultra-optimisée** basée sur les ressources de votre système.

![Screenshot](https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/images/logo.png)

## 🏗️ Architecture DNS

```mermaid
graph TD
    Client[Clients Reseau] -->|Requete DNS Port 53| AGH["AdGuard Home (Filtrage)"]
    AGH -->|Forward Port 5335| Unbound["Unbound Local (Recursivité)"]
    Unbound -->|DoT / DNSSEC| Upstream["DNS Upstream (Cloudflare, Quad9, etc.)"]
    Upstream -->|Reponse| Unbound
    Unbound -->|Cache DNS| AGH
    AGH -->|Reponse Filtree| Client
```

## ✨ Fonctionnalités

### 🚀 Installation & Mise à jour

- **AdGuard Home** : Téléchargement automatique (GitHub) avec **vérification d'intégrité SHA256**.
- **Unbound** : Installation et configuration récursive haute performance.
- **Récupération Intelligente** : Détecte une installation existante et optimise la configuration sans écraser vos données (filtres, stats).

### ⚙️ Optimisation Dynamique (Multi-Tiers)

Le script analyse vos cœurs CPU et votre RAM pour calibrer Unbound scientifiquement :

- **Threads & Slabs** : Alignés sur le nombre de cœurs (Puissance de 2) pour réduire la contention (Lock Contention).
- **Buffers Réseau** : Augmentation des buffers UDP (Sysctl) pour encaisser les pics de trafic.
- **Profils Mémoire** : De **Micro** (< 512MB) à **Premium** (> 4GB).

### 🛡️ Sécurité & Gestion

- **DNS-over-TLS (DoT)** : Cloudflare ou Quad9 configurés nativement.
- **Nouveau Menu (v3.1.0)** :
  - **Réparer / Optimiser** : Recalcule la config Unbound sans réinstaller.
  - **Désinstaller** : Suppression propre et complète.
  - **Stats** : Vue en temps réel de l'efficacité du cache.
- **Auto-Update (v3.2.0)** : Le script peut se mettre à jour tout seul.

## 🧪 Nouveauté : Production-Ready Utilities & Tests

### Bibliothèques Utilitaires

Le projet inclut maintenant des **bibliothèques bash production-ready** suivant les standards [bash-pro](https://github.com/sickn33/antigravity-awesome-skills) :

- **`lib/common.sh`** - 12+ fonctions utilitaires :
  - ✅ Retry logic réseau avec validation checksum
  - ✅ Validation IP/Port robuste
  - ✅ Backup/Rollback automatique
  - ✅ Gestion services avec health checks
  - ✅ Opérations fichiers atomiques

- **`lib/health_checks.sh`** - Diagnostics DNS complets :
  - ✅ Tests résolution DNS, DNSSEC, DoT
  - ✅ Health checks Unbound & AdGuard (5 vérifications chacun)
  - ✅ Benchmark performance (queries/sec)
  - ✅ Génération rapports détaillés

### Suite de Tests Automatisés

```bash
# Exécuter tous les tests
./tests/test_suite.sh

# Test spécifique
./tests/test_suite.sh --test validate_ipv4

# 25 tests : validation, système, performance
```

### Documentation Contributeurs

- **[CONTRIBUTING.md](CONTRIBUTING.md)** - Standards de code, processus de contribution
- **[USAGE_GUIDE.md](USAGE_GUIDE.md)** - Exemples d'intégration et utilisation avancée
- **[IMPROVEMENTS.md](IMPROVEMENTS.md)** - Détails techniques des améliorations

## 🚀 Installation Rapide

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/nickdesi/unbound-adguard-installer/main/install_unbound_interactive.sh)"
```

Ou clonez le dépôt :

```bash
git clone https://github.com/nickdesi/unbound-adguard-installer.git
cd unbound-adguard-installer
chmod +x install_unbound_interactive.sh
sudo ./install_unbound_interactive.sh
```

## 📋 Options de Ligne de Commande

```text
Usage: ./install_unbound_interactive.sh [OPTION]

Options:
  --install        Installation complète (AdGuard Home + Unbound)
  --unbound-only   Installer/reconfigurer uniquement Unbound
  --update         Mettre à jour ce script depuis GitHub
  --uninstall      Désinstaller AdGuard Home et Unbound
  --help           Afficher l'aide

Sans option, le script affiche un menu interactif.
```

## 🎛️ Menu Interactif (v3.2.0)

1. **Installation Complète (Safe & Idempotent)** : Déploiement total AdGuard Home + Unbound.
2. **Optimiser / Réparer Config Unbound** : Recalibre Unbound sur une installation existante (idéal si vous changez les ressources du LXC).
3. **Mettre à jour OS & Paquets** : Debian/Ubuntu upgrade.
4. **Mettre à jour ce Script** : Récupère la dernière version depuis GitHub.
5. **Stats Unbound** : Consultez l'efficacité de votre cache.
6. **Désinstaller Tout** : Suppression complète.
7. **Quitter**

## ⚙️ Configuration par défaut

- **Unbound** : Port `5335` (localhost)
- **AdGuard Home UI** : Port `3000`
- **Logs** : `/var/log/adguard-unbound-installer.log`

## 🔧 Dépannage & Logs

### Voir les logs du script

```bash
tail -f /var/log/adguard-unbound-installer.log
```

### Vérifier les services

```bash
sudo systemctl status AdGuardHome
sudo systemctl status unbound
sudo unbound-checkconf
```

### Test de résolution directe (Unbound)

```bash
dig @127.0.0.1 -p 5335 google.com
```

### Health Check Automatisé (Nouveau)

```bash
# Sourcer la bibliothèque
source lib/health_checks.sh

# Exécuter le diagnostic complet
run_full_health_check

# Générer un rapport de performance
generate_performance_report

# Benchmark (1000 requêtes)
benchmark_dns_performance 1000
```

## 🔄 Migration LXC Debian → Alpine

Un script dédié permet de migrer votre configuration DNS complète vers un conteneur Alpine Linux.

### Prérequis

1. Conteneur **source** : LXC Debian avec AdGuard Home + Unbound (installés via ce script)
2. Conteneur **cible** : LXC Alpine avec AdGuard Home pré-installé via [community-scripts](https://github.com/community-scripts/ProxmoxVE)

### Utilisation (depuis l'hôte Proxmox)

```bash
# Télécharger et exécuter
curl -fsSL https://raw.githubusercontent.com/nickdesi/unbound-adguard-installer/main/migrate_dns_lxc.sh -o migrate_dns_lxc.sh
chmod +x migrate_dns_lxc.sh
sudo ./migrate_dns_lxc.sh <SOURCE_ID> <TARGET_ID>

# Exemple : migrer du CT 100 vers CT 101
sudo ./migrate_dns_lxc.sh 100 101
```� Développement & Contribution

Contributions bienvenues ! Le projet suit les standards **bash-pro** avec :

- ✅ 25 tests automatisés (`./tests/test_suite.sh`)
- ✅ Linting shellcheck obligatoire
- ✅ Documentation complète
- ✅ Guide de contribution : [CONTRIBUTING.md](CONTRIBUTING.md)

### Structure du Projet

```
├── install_unbound_interactive.sh  # Script principal
├── migrate_dns_lxc.sh              # Migration Debian → Alpine
├── lib/
│   ├── common.sh                   # Fonctions utilitaires
│   └── health_checks.sh            # Tests santé DNS
├── tests/
│   └── test_suite.sh               # Suite de tests automatisés
└── docs/
    ├── CONTRIBUTING.md             # Guide contributeurs
    ├── USAGE_GUIDE.md              # Guide utilisation
    └── IMPROVEMENTS.md             # Détails améliorations
```

## 🙏 Crédits

- Inspiré par [tteck's Proxmox VE Helper-Scripts](https://github.com/community-scripts/ProxmoxVE)
- [AdGuard Home](https://adguard.com/adguard-home/overview.html)
- [NLnet Labs Unbound](https://nlnetlabs.nl/projects/unbound/about/)
- Standards bash : [antigravity-awesome-skills](https://github.com/sickn33/antigravity-awesome-skills)
- Token optimization : [RTK](https://github.com/rtk-ai/rtk
- ✅ Migration des configs AdGuard (YAML + data/stats)
- ✅ Migration de la config Unbound
- ✅ Installation d'Unbound sur Alpine (`apk add`)
- ✅ Gestion des services systemd (Debian) ↔ OpenRC (Alpine)
- ✅ Vérifications de sécurité et permissions
- ✅ Test de résolution DNS post-migration

## 📜 Licence

Ce projet est sous licence MIT. Voir le fichier [LICENSE](LICENSE) pour plus de détails.

## 🙏 Crédits

- Inspiré par [tteck's Proxmox VE Helper-Scripts](https://github.com/community-scripts/ProxmoxVE)
- [AdGuard Home](https://adguard.com/adguard-home/overview.html)
- [NLnet Labs Unbound](https://nlnetlabs.nl/projects/unbound/about/)

## ⚠️ Disclaimer

Ce script modifie la configuration système. Utilisez-le à vos propres risques. Il est recommandé de faire des sauvegardes avant toute modification majeure.
