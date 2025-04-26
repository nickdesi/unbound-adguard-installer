# Unbound Installer pour AdGuard Home sur Proxmox LXC

Ce script Bash installe et configure **Unbound** comme un résolveur DNS récursif local sécurisé et performant, spécifiquement conçu pour fonctionner en tandem avec **AdGuard Home** dans un conteneur **Proxmox LXC** (basé sur Debian/Ubuntu).

Il pose des questions interactives sur les ressources (CPU/RAM) de votre LXC pour générer une **configuration Unbound ultra-optimisée**, axée sur la sécurité maximale et la rapidité.

## Fonctionnalités Clés

*   **Installation Automatisée** : Installe Unbound et les dépendances nécessaires (`ca-certificates`, `dnsutils`).
*   **Configuration Interactive Optimisée** : Adapte automatiquement les paramètres critiques (threads, caches, buffers) en fonction des cœurs CPU et de la RAM que vous spécifiez.
*   **Sécurité Renforcée** :
    *   Configuration durcie (`harden-*` directives).
    *   DNS-over-TLS (DoT) activé par défaut vers Cloudflare (facilement modifiable).
    *   Validation DNSSEC activée et renforcée.
    *   Protection contre le DNS Rebinding (`private-address`).
    *   Minimisation QNAME (mode strict) pour la confidentialité.
    *   Refus des requêtes ANY (`deny-any`).
*   **Performance** :
    *   Optimisé pour une faible latence (`prefetch`, `serve-expired`).
    *   Utilisation efficace des ressources CPU/RAM.
    *   `so-reuseport` activé pour de meilleures performances UDP.
*   **Intégration AdGuard Home Facile** : Unbound écoute sur `127.0.0.1:5335`, prêt à être utilisé comme unique serveur amont dans AdGuard Home.
*   **Gestion `systemd-resolved`** : Désactive `systemd-resolved` s'il risque d'interférer.
*   **Configuration `unbound-control`** : Active et configure `unbound-control` pour la gestion et les statistiques.
*   **Configuration Pare-feu (UFW)** : Ajoute automatiquement les règles UFW nécessaires si UFW est détecté.
*   **Test Intégré** : Vérifie la syntaxe de la configuration et teste la résolution DNS après installation.

## Prérequis

*   Un conteneur Proxmox LXC fonctionnel (basé sur Debian ou Ubuntu).
*   AdGuard Home déjà installé et fonctionnel dans ce même LXC.
*   Accès SSH ou console au LXC avec les privilèges `sudo`.
*   Connectivité Internet pour télécharger les paquets.

## Utilisation

1.  **Connectez-vous** à votre LXC AdGuard Home.
2.  **Téléchargez le script** (ou clonez le dépôt) :
    ```
    # Option 1: wget
    wget https://raw.githubusercontent.com/VOTRE_USER/VOTRE_REPO/main/install_unbound_interactive.sh

    # Option 2: curl
    curl -o install_unbound_interactive.sh https://raw.githubusercontent.com/VOTRE_USER/VOTRE_REPO/main/install_unbound_interactive.sh

    # Option 3: git clone (si vous clonez le dépôt entier)
    # git clone https://github.com/VOTRE_USER/VOTRE_REPO.git
    # cd VOTRE_REPO
    ```
    *(Remplacez `VOTRE_USER/VOTRE_REPO` par le chemin réel de votre dépôt GitHub une fois créé)*
3.  **Rendez le script exécutable** :
    ```
    chmod +x install_unbound_interactive.sh
    ```
4.  **Exécutez le script avec `sudo`** :
    ```
    sudo bash install_unbound_interactive.sh
    ```
5.  **Répondez aux questions** concernant le nombre de cœurs CPU et la quantité de RAM (en Mo) alloués à votre LXC.
6.  Le script va procéder à l'installation et à la configuration. Suivez les instructions affichées.

## Post-Installation

Après l'exécution réussie du script :

1.  Accédez à l'interface web de votre **AdGuard Home**.
2.  Allez dans `Paramètres` -> `Paramètres DNS`.
3.  Dans la section `Serveurs DNS en amont`, **supprimez tous les serveurs existants**.
4.  **Ajoutez** `127.0.0.1:5335` comme unique serveur DNS en amont.
5.  Cliquez sur `Appliquer`.
6.  (Optionnel mais recommandé) Choisissez `Requêtes parallèles` comme mode de fonctionnement.

Votre AdGuard Home utilisera maintenant votre instance Unbound locale, sécurisée et optimisée comme résolveur DNS.

## Dépannage

*   **Unbound ne démarre pas ?** Vérifiez les erreurs :
    ```
    sudo systemctl status unbound.service
    sudo journalctl -xeu unbound.service
    sudo unbound-checkconf
    ```
*   **Pas de résolution DNS ?**
    *   Vérifiez les logs Unbound (`journalctl -u unbound -f`).
    *   Testez Unbound directement : `dig @127.0.0.1 -p 5335 google.com`
    *   Vérifiez les logs AdGuard Home.
    *   Assurez-vous que le pare-feu (UFW ou autre) ne bloque pas le trafic sur `127.0.0.1:5335`.

## Licence

Ce projet est sous licence MIT. Voir le fichier `LICENSE` pour plus de détails.

## Disclaimer

Ce script modifie la configuration système. Utilisez-le à vos propres risques. Il est recommandé de faire des sauvegardes avant toute modification majeure.

