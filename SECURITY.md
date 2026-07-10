# 🔒 Politique de sécurité

## Versions prises en charge

Ce projet est un **script d'installation/configuration locale**. Seule la branche `main` (et la dernière release) est suivie activement.

| Branche / Release | Support |
|-------------------|---------|
| `main` (dernière) | ✅ Active |
| Dernière release taguée | ✅ Correctifs si critique |
| Anciennes releases | ❌ Non maintenues |

## Signaler une vulnérabilité

⚠️ **Ne publiez pas** de failles de sécurité dans les issues publiques.

Signalez une vulnérabilité de l'une des manières suivantes :
- **GitHub Security Advisory** (recommandé) : `Security → Report a vulnerability` sur le dépôt.
- **Email** : contactez le mainteneur via les discussions GitHub du dépôt.

Nous accusons réception sous **72 h** et proposons un correctif ou une mitigation sous **15 jours** pour les problèmes critiques.

## Périmètre & bonnes pratiques

Ce script s'exécute en `root` et modifie des composants système sensibles. Il n'expose **aucun service réseau vers l'extérieur** (Unbound écoute sur `127.0.0.1:5335`, AdGuard Home sur l'interface du LXC).

Il touche notamment :
- Services systemd (`unbound`, `AdGuardHome`, désactivation éventuelle de `systemd-resolved`)
- `/etc/unbound/`, `/etc/resolv.conf`, `/etc/fstab`, `/etc/sysctl.d/`
- Paramètres réseau (sysctl), tmpfs cache

Recommandations :
- 🧪 Testez toujours avec `sudo ./install_unbound_interactive.sh --dry-run --install` avant toute modification réelle.
- 📦 Des **sauvegardes** (`.backup_*`, `.backup_<timestamp>`) sont créées avant d'écraser les fichiers sensibles.
- 🔐 Installez dans un **LXC dédié et isolé**, avec une IP fixe, jamais sur le nœud Proxmox VE.
- 🌐 Limitez l'exposition d'AdGuard Home (`:3000`) au réseau de confiance ; changez le mot de passe par défaut.
- 🔄 Préférez `--repair` / `--retune` (sans réinstaller) pour les mises à jour de configuration.

## Dépendances externes

Le script télécharge AdGuard Home depuis `github.com/AdguardTeam` et vérifie les **checksums officiels SHA256**. Les upstreams DoT par défaut sont Cloudflare, Quad9, Google et AdGuard.
