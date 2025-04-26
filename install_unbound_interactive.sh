#!/bin/bash

# ==========================================================================
# Unbound DNS Installer INTERACTIF pour AdGuard Home sur Proxmox LXC
# ==========================================================================
# Ce script installe et configure Unbound comme résolveur récursif
# sur un LXC Proxmox existant avec AdGuard Home.
# Il optimise la configuration en fonction des ressources (CPU/RAM) fournies par l'utilisateur.
# Inclut les corrections et optimisations discutées précédemment.
# ==========================================================================

# --- Variables de couleur ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- Paramètres par défaut ---
UNBOUND_PORT=5335
DEFAULT_CPU_CORES=$(nproc --all)
DEFAULT_RAM_MB=512

# --- Fonctions ---

# Fonction pour valider une entrée numérique positive
validate_positive_integer() {
    local input="$1"
    local default_value="$2"
    local var_name="$3"
    if ! [[ "$input" =~ ^[1-9][0-9]*$ ]]; then
        echo -e "${YELLOW}Entrée invalide pour ${var_name}. Utilisation de la valeur par défaut : ${default_value}${NC}" >&2
        input=$default_value
    fi
    echo "$input"
}

# Fonction pour calculer les paramètres optimisés
calculate_optimized_settings() {
    local cores=$1
    local ram_mb=$2

    # Calcul du nombre de threads
    NUM_THREADS=$cores

    # Calcul des slabs (puissance de 2 proche de num_threads)
    if [ "$cores" -le 1 ]; then
        CACHE_SLABS=2 # Min 2 même pour 1 core
    elif [ "$cores" -eq 2 ]; then
        CACHE_SLABS=2
    elif [ "$cores" -le 4 ]; then
        CACHE_SLABS=4
    elif [ "$cores" -le 8 ]; then
        CACHE_SLABS=8
    else
        CACHE_SLABS=16 # Cap pour les très grosses configs
    fi

    # Calcul des tailles de cache basées sur la RAM (heuristique)
    # Objectif: utiliser ~15-30% de RAM pour les caches, priorité à rrset
    if [ "$ram_mb" -lt 512 ]; then
        RRSET_CACHE_SIZE="32m"
        MSG_CACHE_SIZE="16m"
        SO_BUF="512k"
    elif [ "$ram_mb" -lt 1024 ]; then # 512MB - 1023MB
        RRSET_CACHE_SIZE="64m"
        MSG_CACHE_SIZE="32m"
        SO_BUF="1m"
    elif [ "$ram_mb" -lt 2048 ]; then # 1GB - 2GB
        RRSET_CACHE_SIZE="128m"
        MSG_CACHE_SIZE="64m"
        SO_BUF="2m"
    else # >= 2GB
        RRSET_CACHE_SIZE="256m"
        MSG_CACHE_SIZE="128m"
        SO_BUF="4m"
    fi

    echo -e "${BLUE}Paramètres optimisés calculés :${NC}"
    echo -e "- ${BOLD}Threads :${NC} ${NUM_THREADS}"
    echo -e "- ${BOLD}Slabs :${NC} ${CACHE_SLABS}"
    echo -e "- ${BOLD}Cache RRset :${NC} ${RRSET_CACHE_SIZE}"
    echo -e "- ${BOLD}Cache Message :${NC} ${MSG_CACHE_SIZE}"
    echo -e "- ${BOLD}SO Buffers :${NC} ${SO_BUF}"
}

# --- Début du script ---

echo -e "${BLUE}${BOLD}======== Installation Interactive d'Unbound DNS pour AdGuard Home ========${NC}"

# 1. Vérification root
echo -e "\n${YELLOW}[1/11] Vérification des privilèges root...${NC}"
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}ERREUR : Ce script doit être exécuté en tant que root ou avec sudo.${NC}" >&2
  exit 1
fi
echo -e "${GREEN}✓ Exécuté en tant que root.${NC}"

# 2. Collecte interactive des ressources
echo -e "\n${YELLOW}[2/11] Collecte des informations sur les ressources du LXC...${NC}"
read -p "Combien de cœurs CPU sont alloués à ce LXC ? [Défaut: ${DEFAULT_CPU_CORES}]: " user_cpu_input
USER_CPU_CORES=$(validate_positive_integer "$user_cpu_input" "$DEFAULT_CPU_CORES" "CPU Cores")

read -p "Combien de RAM (en Mo) est allouée à ce LXC ? [Défaut: ${DEFAULT_RAM_MB}]: " user_ram_input
USER_RAM_MB=$(validate_positive_integer "$user_ram_input" "$DEFAULT_RAM_MB" "RAM (MB)")

echo -e "${BLUE}Configuration basée sur ${USER_CPU_CORES} cœurs et ${USER_RAM_MB} Mo de RAM.${NC}"

# Calculer les paramètres optimisés
calculate_optimized_settings "$USER_CPU_CORES" "$USER_RAM_MB"

# 3. Mise à jour système et installation des dépendances
echo -e "\n${YELLOW}[3/11] Mise à jour système et installation des paquets nécessaires...${NC}"
apt update > /dev/null 2>&1 # Redirige stdout/stderr pour alléger la sortie
if ! apt upgrade -y > /dev/null 2>&1; then
    echo -e "${RED}ERREUR : Échec de la mise à jour système. Vérifiez vos sources APT ou l'état du réseau.${NC}"
    exit 1
fi
if ! apt install -y unbound ca-certificates dnsutils > /dev/null 2>&1; then
    echo -e "${RED}ERREUR : Échec de l'installation des paquets (unbound, ca-certificates, dnsutils).${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Système mis à jour et paquets installés.${NC}"

# 4. Arrêt d'Unbound pour la configuration
echo -e "\n${YELLOW}[4/11] Préparation de la configuration Unbound...${NC}"
if systemctl is-active --quiet unbound; then
    systemctl stop unbound
    echo -e "${GREEN}✓ Service Unbound arrêté pour configuration.${NC}"
else
    echo -e "${YELLOW}Le service Unbound n'était pas actif.${NC}"
fi

# 5. Vérification et gestion de systemd-resolved
echo -e "\n${YELLOW}[5/11] Vérification de systemd-resolved...${NC}"
if systemctl is-active --quiet systemd-resolved; then
  echo -e "${YELLOW}systemd-resolved est actif. Vérification du port 53...${NC}"
  if ss -tulnp | grep -E ':(53|5353)\s' | grep -q 'systemd-resolve'; then
    echo -e "${YELLOW}systemd-resolved utilise un port potentiellement conflictuel (53 ou 5353). Désactivation...${NC}"
    systemctl disable --now systemd-resolved.service > /dev/null 2>&1
    # Supprimer le lien symbolique resolv.conf s'il est géré par systemd-resolved
    if [ -L /etc/resolv.conf ]; then
        TARGET=$(readlink -f /etc/resolv.conf)
        if [[ "$TARGET" == *"systemd/resolve"* ]]; then
             rm /etc/resolv.conf
             echo -e "${YELLOW}Lien symbolique /etc/resolv.conf géré par systemd-resolved supprimé.${NC}"
        fi
    fi
    echo -e "${GREEN}✓ systemd-resolved désactivé.${NC}"
  else
    echo -e "${GREEN}systemd-resolved n'utilise pas le port 53/5353. Aucune action nécessaire.${NC}"
  fi
else
  echo -e "${GREEN}systemd-resolved n'est pas actif. Aucune action nécessaire.${NC}"
fi

# 6. Génération de la configuration Unbound optimisée
echo -e "\n${YELLOW}[6/11] Génération de la configuration Unbound optimisée (/etc/unbound/unbound.conf)...${NC}"
# Sauvegarde de la configuration existante
CONF_FILE="/etc/unbound/unbound.conf"
if [ -f "$CONF_FILE" ]; then
  mv "$CONF_FILE" "${CONF_FILE}.backup.$(date +%Y%m%d%H%M%S)"
  echo -e "${YELLOW}Configuration existante sauvegardée en ${CONF_FILE}.backup.*${NC}"
fi

# Création de la nouvelle configuration
cat > "$CONF_FILE" << EOF
# ==================================================================
# Configuration Unbound ULTRA-OPTIMISÉE pour AdGuard Home sur LXC
# Générée par script interactif le $(date)
# Ressources : ${USER_CPU_CORES} CPU / ${USER_RAM_MB}MB RAM
# Priorités : Sécurité maximale & Rapidité
# ==================================================================

server:
    # -- Core & Interface --
    # Écoute uniquement sur localhost pour AdGuard Home
    interface: 127.0.0.1
    port: ${UNBOUND_PORT}
    do-ip4: yes
    do-ip6: yes # Garder si AdGuard et le réseau le supportent
    do-udp: yes
    do-tcp: yes
    # Utilisation des certificats système pour DoT/DNSSEC
    tls-cert-bundle: "/etc/ssl/certs/ca-certificates.crt"

    # -- Contrôle d'accès STRICT --
    access-control: 127.0.0.0/8 allow
    access-control: ::1/128 allow

    # -- Optimisation CPU & RAM --
    num-threads: ${NUM_THREADS}
    msg-cache-slabs: ${CACHE_SLABS}
    rrset-cache-slabs: ${CACHE_SLABS}
    infra-cache-slabs: ${CACHE_SLABS}
    key-cache-slabs: ${CACHE_SLABS}
    rrset-cache-size: ${RRSET_CACHE_SIZE}
    msg-cache-size: ${MSG_CACHE_SIZE}
    so-reuseport: yes
    so-rcvbuf: ${SO_BUF}
    so-sndbuf: ${SO_BUF}

    # -- Performance Cache & Résilience --
    prefetch: yes
    prefetch-key: yes
    serve-expired: yes
    serve-expired-ttl: 3600 # Servir l'expiré pendant max 1h (3600s)
    serve-expired-ttl-reset: yes # Réinitialiser le TTL si le client le demande

    # -- Minimisation & Confidentialité --
    minimal-responses: yes
    qname-minimisation: yes
    qname-minimisation-strict: yes # Mode strict

    # -- Sécurité Renforcée --
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: yes
    deny-any: yes # Utiliser deny-any au lieu de refuse-any
    harden-below-nxdomain: yes
    harden-referral-path: yes
    harden-algo-downgrade: yes

    # -- DNSSEC --
    auto-trust-anchor-file: "/var/lib/unbound/root.key"
    root-hints: "/usr/share/dns/root.hints"
    val-log-level: 1

    # -- Protection Adresses Privées --
    private-address: 192.168.0.0/16
    private-address: 172.16.0.0/12
    private-address: 10.0.0.0/8
    private-address: 169.254.0.0/16
    private-address: fd00::/8
    private-address: fe80::/10
    private-domain: "local"
    private-domain: "lan"
    private-domain: "home.arpa"

    # -- Statistiques & Contrôle --
    extended-statistics: yes
    statistics-interval: 0
    statistics-cumulative: yes

# -- Forwarding DNS-over-TLS (DoT) --
forward-zone:
    name: "."
    forward-ssl-upstream: yes
    # Cloudflare (IPv4 & IPv6)
    forward-addr: 1.1.1.1@853#cloudflare-dns.com
    forward-addr: 1.0.0.1@853#cloudflare-dns.com
    forward-addr: 2606:4700:4700::1111@853#cloudflare-dns.com
    forward-addr: 2606:4700:4700::1001@853#cloudflare-dns.com
    # Quad9 (Alternative, décommentez si besoin)
    # forward-addr: 9.9.9.9@853#dns.quad9.net
    # forward-addr: 149.112.112.112@853#dns.quad9.net
    # forward-addr: 2620:fe::fe@853#dns.quad9.net
    # forward-addr: 2620:fe::9@853#dns.quad9.net

# -- Contrôle à distance via unbound-control --
remote-control:
    control-enable: yes
    control-interface: 127.0.0.1
    control-port: 8953
    # Les chemins suivants sont les chemins par défaut après unbound-control-setup
    server-key-file: "/etc/unbound/unbound_server.key"
    server-cert-file: "/etc/unbound/unbound_server.pem"
    control-key-file: "/etc/unbound/unbound_control.key"
    control-cert-file: "/etc/unbound/unbound_control.pem"

# Fin de la configuration
EOF

# Vérification de la syntaxe
echo -e "\n${YELLOW}[7/11] Vérification de la syntaxe de la configuration Unbound...${NC}"
if unbound-checkconf "$CONF_FILE"; then
  echo -e "${GREEN}✓ Syntaxe de la configuration Unbound valide.${NC}"
else
  echo -e "${RED}ERREUR : Erreur de syntaxe dans ${CONF_FILE}. Veuillez vérifier le fichier.${NC}" >&2
  echo -e "${YELLOW}Restauration de la sauvegarde possible depuis ${CONF_FILE}.backup.*${NC}"
  exit 1
fi

# 7. Configuration de unbound-control
echo -e "\n${YELLOW}[8/11] Configuration de unbound-control (génération des clés)...${NC}"
# Vérifier si les clés existent déjà pour éviter de les écraser inutilement
if [ -f "/etc/unbound/unbound_server.key" ]; then
    echo -e "${YELLOW}Les clés pour unbound-control semblent déjà exister. Pas de regénération.${NC}"
else
    # Assurer que le répertoire /etc/unbound existe et appartient à unbound
    mkdir -p /etc/unbound
    chown unbound:unbound /etc/unbound
    chmod 770 /etc/unbound # Permissions pour groupe unbound aussi

    # Exécuter setup en tant qu'utilisateur unbound pour éviter les pbs de droits
    sudo -u unbound unbound-control-setup -d /etc/unbound
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Clés pour unbound-control générées dans /etc/unbound.${NC}"
    else
        echo -e "${RED}ERREUR : Échec de la génération des clés pour unbound-control. Tentative avec root...${NC}" >&2
        # Tentative en root si échec avec user unbound
        if unbound-control-setup -d /etc/unbound; then
             echo -e "${GREEN}✓ Clés pour unbound-control générées avec root.${NC}"
        else
             echo -e "${RED}ERREUR : Échec de la génération des clés même avec root.${NC}" >&2
        fi
    fi
fi
# Assurer les bonnes permissions pour le répertoire et les clés après génération
chown -R unbound:unbound /etc/unbound/
chmod 640 /etc/unbound/*.key # Clés privées lisibles uniquement par user+group
chmod 644 /etc/unbound/*.pem # Certs publics lisibles par tous
chmod 770 /etc/unbound # Répertoire

# 8. Configuration de /etc/resolv.conf
echo -e "\n${YELLOW}[9/11] Configuration de /etc/resolv.conf pour utiliser AdGuard localement...${NC}"
cat > /etc/resolv.conf << EOF
# Configuré par le script d'installation Unbound
# Le système utilise AdGuard Home (127.0.0.1:53) qui utilise Unbound (127.0.0.1:5335)
nameserver 127.0.0.1
options edns0 trust-ad
EOF
# Empêcher l'écrasement par Proxmox/DHCP
touch /etc/.pve-ignore.resolv.conf
echo -e "${GREEN}✓ /etc/resolv.conf configuré et protégé contre l'écrasement.${NC}"

# 9. Configuration du pare-feu (UFW)
echo -e "\n${YELLOW}[10/11] Configuration du pare-feu (UFW)...${NC}"
if command -v ufw &> /dev/null; then
    echo -e "${GREEN}UFW est installé. Ajout des règles pour Unbound sur localhost...${NC}"
    # Supprimer les anciennes règles potentielles pour être propre
    ufw delete allow from 127.0.0.1 to any port ${UNBOUND_PORT} proto udp > /dev/null 2>&1
    ufw delete allow from 127.0.0.1 to any port ${UNBOUND_PORT} proto tcp > /dev/null 2>&1
    # Ajouter les nouvelles règles
    ufw allow from 127.0.0.1 to any port ${UNBOUND_PORT} proto udp comment 'Allow Unbound from localhost (UDP)' > /dev/null
    ufw allow from 127.0.0.1 to any port ${UNBOUND_PORT} proto tcp comment 'Allow Unbound from localhost (TCP)' > /dev/null
    echo -e "${GREEN}✓ Règles UFW ajoutées pour le port ${UNBOUND_PORT} depuis localhost.${NC}"
    # Recharger UFW si actif
    if ufw status | grep -qw active; then
        echo -e "${YELLOW}UFW est actif. Rechargement des règles...${NC}"
        ufw reload > /dev/null
        echo -e "${GREEN}✓ Règles UFW rechargées.${NC}"
    else
        echo -e "${YELLOW}UFW n'est pas actif. Les règles sont ajoutées mais non appliquées. Activez UFW avec 'sudo ufw enable' si besoin.${NC}"
    fi
else
    echo -e "${YELLOW}UFW n'est pas installé. Aucune règle de pare-feu configurée par ce script.${NC}"
    echo -e "${YELLOW}Assurez-vous manuellement que le trafic sur 127.0.0.1:${UNBOUND_PORT} (UDP/TCP) n'est pas bloqué.${NC}"
fi

# 10. Démarrage, activation et test d'Unbound
echo -e "\n${YELLOW}[11/11] Démarrage, activation et test du service Unbound...${NC}"
systemctl daemon-reload # S'assurer que systemd prend en compte les changements
# Vérifier les permissions avant de démarrer
chown -R unbound:unbound /etc/unbound /var/lib/unbound > /dev/null 2>&1 || true

systemctl restart unbound
systemctl enable unbound > /dev/null 2>&1

sleep 3 # Donner un peu plus de temps au service de démarrer

if systemctl is-active --quiet unbound; then
  echo -e "${GREEN}✓ Service Unbound démarré et activé avec succès.${NC}"
  # Test DNS final
  echo -e "${YELLOW}Test de la résolution DNS via Unbound (127.0.0.1:${UNBOUND_PORT})...${NC}"
  # Utiliser dig avec +tries=1 et +time=2 pour un test rapide
  if dig @127.0.0.1 -p ${UNBOUND_PORT} google.com +short A +tries=1 +time=2 > /dev/null; then
    echo -e "${GREEN}✓ Test DNS réussi ! Unbound répond correctement.${NC}"
  else
    echo -e "${RED}ERREUR : Test DNS via Unbound a échoué. Unbound ne semble pas répondre correctement.${NC}" >&2
    echo -e "${YELLOW}Vérifiez les logs ('journalctl -u unbound') et la configuration réseau/pare-feu.${NC}"
  fi
else
  echo -e "${RED}ERREUR CRITIQUE : Le service Unbound n'a pas pu démarrer après configuration.${NC}" >&2
  echo -e "${RED}Veuillez vérifier les erreurs avec les commandes suivantes :${NC}" >&2
  echo -e "${BOLD}sudo systemctl status unbound.service${NC}" >&2
  echo -e "${BOLD}sudo journalctl -xeu unbound.service${NC}" >&2
  exit 1
fi

# --- Instructions Finales ---
echo -e "\n${BLUE}${BOLD}=== Installation et Configuration d'Unbound Terminées ====${NC}"
echo -e "\n${GREEN}${BOLD}Instructions pour configurer AdGuard Home:${NC}"
echo -e "1. Accédez à l'interface web d'AdGuard Home."
echo -e "2. Allez dans ${BOLD}Paramètres > Paramètres DNS${NC}."
echo -e "3. Dans la section ${BOLD}Serveurs DNS en amont${NC} :"
echo -e "   a. ${YELLOW}Supprimez${NC} tous les serveurs DNS publics existants (Google, Cloudflare, etc.)."
echo -e "   b. ${YELLOW}Ajoutez${NC} votre serveur Unbound local : ${BOLD}127.0.0.1:${UNBOUND_PORT}${NC}"
echo -e "   c. (Optionnel) Cliquez sur 'Tester les serveurs DNS en amont'."
echo -e "4. Cliquez sur ${BOLD}Appliquer${NC}."
echo -e "5. (Recommandé) Dans la section ${BOLD}Mode de fonctionnement des serveurs en amont${NC}, choisissez ${BOLD}Requêtes parallèles${NC}."

echo -e "\n${YELLOW}Résumé des paramètres optimisés pour ${USER_CPU_CORES} cœurs / ${USER_RAM_MB} Mo RAM :${NC}"
echo -e "- Port d'écoute Unbound : ${BOLD}${UNBOUND_PORT}${NC}"
echo -e "- Threads : ${BOLD}${NUM_THREADS}${NC}, Slabs : ${BOLD}${CACHE_SLABS}${NC}"
echo -e "- Cache RRset : ${BOLD}${RRSET_CACHE_SIZE}${NC}, Cache Message : ${BOLD}${MSG_CACHE_SIZE}${NC}"

echo -e "\n${BLUE}Commandes utiles pour la gestion d'Unbound :${NC}"
echo -e "- Voir le statut : ${BOLD}sudo systemctl status unbound${NC}"
echo -e "- Voir les logs : ${BOLD}sudo journalctl -u unbound -f${NC}"
echo -e "- Voir les statistiques : ${BOLD}sudo unbound-control stats_noreset${NC}"
echo -e "- Vider le cache : ${BOLD}sudo unbound-control flush_zone .${NC}"

echo -e "\n${GREEN}${BOLD}Le script a terminé avec succès !${NC}"

exit 0


