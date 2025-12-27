# AdGuard Home & Unbound All-in-One Installer pour Proxmox LXC

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Ce script Bash installe et configure **AdGuard Home** et **Unbound** comme solution DNS complète sur un conteneur **Proxmox LXC** (basé sur Debian/Ubuntu).

Inspiré par le style des [Proxmox VE Helper-Scripts](https://tteck.github.io/Proxmox/), il propose une **interface interactive** (menu Whiptail) et une configuration **ultra-optimisée** basée sur les ressources de votre système.

![Screenshot](https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/images/logo.png)

## ✨ Fonctionnalités

### Installation

- **AdGuard Home** : Téléchargement automatique de la dernière version depuis GitHub
- **Unbound** : Configuration optimisée selon les ressources CPU/RAM détectées
- **Intégration automatique** : Configuration d'Unbound comme DNS amont dans AdGuard Home

### Mise à jour

- **AdGuard Home** : Vérification et mise à jour du binaire depuis GitHub
- **Unbound** : Mise à jour via APT + rafraîchissement des Root Hints DNS

### Optimisation

- Calcul automatique des paramètres Unbound (threads, caches, buffers)
- Sécurité renforcée (DNSSEC, DoT, hardening)
- Gestion de systemd-resolved et des conflits de ports

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
  --update         Mise à jour complète
  --unbound-only   Installer uniquement Unbound
  --help           Afficher l'aide

Sans option, le script affiche un menu interactif.
```

## 🎛️ Menu Interactif

Lancez le script sans arguments pour accéder au menu :

1. **Installation Complète** - AdGuard Home + Unbound + configuration automatique
2. **Mise à jour Complète** - Met à jour les deux composants
3. **Installer uniquement Unbound** - Pour les utilisateurs ayant déjà AdGuard Home
4. **Afficher les Statistiques** - Statistiques du cache Unbound
5. **Quitter**

## ⚙️ Configuration Générée

### Unbound

- **Port** : `5335` (localhost uniquement)
- **Threads** : Automatiquement ajusté selon vos cœurs CPU
- **Cache** : Optimisé selon votre RAM disponible
- **Sécurité** : DNS-over-TLS vers Cloudflare, DNSSEC activé

### AdGuard Home

- **Interface Web** : `http://<IP>:3000`
- **DNS Upstream** : `127.0.0.1:5335` (Unbound local)

## 🔧 Dépannage

### Unbound ne démarre pas

```bash
sudo systemctl status unbound.service
sudo journalctl -xeu unbound.service
sudo unbound-checkconf
```

### Pas de résolution DNS

```bash
dig @127.0.0.1 -p 5335 google.com
sudo unbound-control stats_noreset
```

### Voir les logs en temps réel

```bash
sudo journalctl -u unbound -f
sudo journalctl -u AdGuardHome -f
```

## 📜 Licence

Ce projet est sous licence MIT. Voir le fichier [LICENSE](LICENSE) pour plus de détails.

## 🙏 Crédits

- Inspiré par [tteck's Proxmox VE Helper-Scripts](https://github.com/community-scripts/ProxmoxVE)
- [AdGuard Home](https://adguard.com/adguard-home/overview.html)
- [NLnet Labs Unbound](https://nlnetlabs.nl/projects/unbound/about/)

## ⚠️ Disclaimer

Ce script modifie la configuration système. Utilisez-le à vos propres risques. Il est recommandé de faire des sauvegardes avant toute modification majeure.
