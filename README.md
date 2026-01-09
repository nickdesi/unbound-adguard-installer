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
  --install        Installation complete (AdGuard Home + Unbound)
  --update         Mise a jour complete
  --unbound-only   Installer uniquement Unbound
  --help           Afficher l'aide

Sans option, le script affiche un menu interactif.
```

## 🎛️ Menu Interactif (v3.1.0)

1. **Installation Complete** : Déploiement total AdGuard Home + Unbound.
2. **Optimiser / Réparer Config** : Recalibre Unbound sur une installation existante (idéal si vous changez les ressources du LXC).
3. **Mettre à jour** : Apps + OS.
4. **Stats Unbound** : Consultez l'efficacité de votre cache.
5. **Désinstaller Tout** : Suppression complète.
6. **Quitter**

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

## 📜 Licence

Ce projet est sous licence MIT. Voir le fichier [LICENSE](LICENSE) pour plus de détails.

## 🙏 Crédits

- Inspiré par [tteck's Proxmox VE Helper-Scripts](https://github.com/community-scripts/ProxmoxVE)
- [AdGuard Home](https://adguard.com/adguard-home/overview.html)
- [NLnet Labs Unbound](https://nlnetlabs.nl/projects/unbound/about/)

## ⚠️ Disclaimer

Ce script modifie la configuration système. Utilisez-le à vos propres risques. Il est recommandé de faire des sauvegardes avant toute modification majeure.
