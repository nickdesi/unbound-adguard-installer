#!/usr/bin/env bash

# ==========================================================================
# Script de Migration DNS : LXC Debian → LXC Alpine
# ==========================================================================
# Migration d'AdGuard Home + Unbound depuis un conteneur Debian vers Alpine
# À exécuter depuis l'hôte Proxmox VE
# ==========================================================================
# Auteur: Nicolas
# Version: 1.0.0
# Licence: MIT
# ==========================================================================

set -Eeuo pipefail

# --- Variables d'entrée ---
SOURCE_ID="${1:-}"
TARGET_ID="${2:-}"

# --- Couleurs et formatage ---
readonly RD='\033[01;31m'
readonly GN='\033[1;32m'
readonly YW='\033[33m'
readonly BL='\033[34m'
readonly CL='\033[m'
readonly CM="${GN}✓${CL}"
readonly CROSS="${RD}✗${CL}"
readonly INFO="${BL}ℹ${CL}"
readonly WARN="${YW}⚠${CL}"

# --- Chemins des fichiers à migrer ---
readonly AGH_DIR="/opt/AdGuardHome"
readonly AGH_YAML="${AGH_DIR}/AdGuardHome.yaml"
readonly AGH_DATA="${AGH_DIR}/data"
readonly UNBOUND_CONF="/etc/unbound/unbound.conf"
readonly UNBOUND_DIR="/etc/unbound"

# --- Répertoire temporaire pour la migration ---
readonly TEMP_DIR="/tmp/dns_migration_$$"

# --- Variables réseau (extraites dynamiquement) ---
SOURCE_IP=""
SOURCE_GW=""
SOURCE_CIDR=""
SOURCE_NET0=""

# ==========================================================================
# FONCTIONS D'AFFICHAGE
# ==========================================================================

msg_info() {
    echo -e " ${INFO} ${YW}$1${CL}"
}

msg_ok() {
    echo -e " ${CM} ${GN}$1${CL}"
}

msg_error() {
    echo -e " ${CROSS} ${RD}$1${CL}"
}

msg_warn() {
    echo -e " ${WARN} ${YW}$1${CL}"
}

header_info() {
    clear
    cat <<'EOF'
    __  ____                  __  _                ____  _   ______
   /  |/  (_)___ __________ _/ /_(_)___  ____     / __ \/ | / / __/
  / /|_/ / / __ `/ ___/ __ `/ __/ / __ \/ __ \   / / / /  |/ /\__ \ 
 / /  / / / /_/ / /  / /_/ / /_/ / /_/ / / / /  / /_/ / /|  /___/ / 
/_/  /_/_/\__, /_/   \__,_/\__/_/\____/_/ /_/  /_____/_/ |_//____/  
         /____/                                                      
            LXC Debian → LXC Alpine (Proxmox VE)
EOF
    echo -e "${BL}====================================================================${CL}"
    echo -e "${GN}   AdGuard Home + Unbound :: Migration Tool${CL}"
    echo -e "${BL}====================================================================${CL}"
    echo ""
}

# ==========================================================================
# FONCTIONS DE VÉRIFICATION
# ==========================================================================

usage() {
    echo "Usage: $0 <SOURCE_ID> <TARGET_ID>"
    echo ""
    echo "  SOURCE_ID : ID du conteneur LXC Debian source (ex: 100)"
    echo "  TARGET_ID : ID du conteneur LXC Alpine cible (ex: 101)"
    echo ""
    echo "Exemple: $0 100 101"
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        msg_error "Ce script doit être exécuté en tant que root sur l'hôte Proxmox."
        exit 1
    fi
}

check_pct() {
    if ! command -v pct &>/dev/null; then
        msg_error "Commande 'pct' non trouvée. Ce script doit être exécuté sur l'hôte Proxmox."
        exit 1
    fi
}

check_container_exists() {
    local container_id="$1"
    local container_name="$2"
    
    if ! pct status "$container_id" &>/dev/null; then
        msg_error "Le conteneur ${container_name} (ID: ${container_id}) n'existe pas."
        exit 1
    fi
    msg_ok "Conteneur ${container_name} (ID: ${container_id}) trouvé"
}

check_container_running() {
    local container_id="$1"
    local container_name="$2"
    
    local status
    status=$(pct status "$container_id" | awk '{print $2}')
    
    if [[ "$status" != "running" ]]; then
        msg_error "Le conteneur ${container_name} (ID: ${container_id}) n'est pas démarré (status: ${status})."
        msg_info "Démarrez-le avec: pct start ${container_id}"
        exit 1
    fi
    msg_ok "Conteneur ${container_name} est en cours d'exécution"
}

check_source_files() {
    msg_info "Vérification des fichiers sources sur le conteneur Debian..."
    
    local missing=0
    
    # Vérifier AdGuard Home YAML
    if ! pct exec "$SOURCE_ID" -- test -f "$AGH_YAML"; then
        msg_error "Fichier non trouvé sur source: ${AGH_YAML}"
        missing=1
    else
        msg_ok "Trouvé: ${AGH_YAML}"
    fi
    
    # Vérifier dossier data AdGuard
    if ! pct exec "$SOURCE_ID" -- test -d "$AGH_DATA"; then
        msg_warn "Dossier non trouvé sur source: ${AGH_DATA} (les stats seront vides)"
    else
        msg_ok "Trouvé: ${AGH_DATA}"
    fi
    
    # Vérifier config Unbound
    if ! pct exec "$SOURCE_ID" -- test -f "$UNBOUND_CONF"; then
        msg_error "Fichier non trouvé sur source: ${UNBOUND_CONF}"
        missing=1
    else
        msg_ok "Trouvé: ${UNBOUND_CONF}"
    fi
    
    if [[ $missing -eq 1 ]]; then
        msg_error "Fichiers sources manquants. Migration annulée."
        exit 1
    fi
}

# ==========================================================================
# FONCTIONS DE GESTION RÉSEAU
# ==========================================================================

extract_network_config() {
    msg_info "Extraction de la configuration réseau du conteneur source..."
    
    # Récupérer la config net0 complète
    SOURCE_NET0=$(pct config "$SOURCE_ID" | grep -E '^net0:' | sed 's/^net0: //')
    
    if [[ -z "$SOURCE_NET0" ]]; then
        msg_error "Impossible de trouver la configuration net0 du conteneur source."
        exit 1
    fi
    
    # Extraire l'IP avec CIDR (ex: 192.168.1.104/24) - compatible POSIX
    SOURCE_IP=$(echo "$SOURCE_NET0" | sed -n 's/.*ip=\([0-9.\/]*\).*/\1/p')
    
    # Extraire la gateway - compatible POSIX
    SOURCE_GW=$(echo "$SOURCE_NET0" | sed -n 's/.*gw=\([0-9.]*\).*/\1/p')
    
    if [[ -z "$SOURCE_IP" ]]; then
        msg_error "Impossible d'extraire l'IP du conteneur source."
        msg_info "Config net0: $SOURCE_NET0"
        exit 1
    fi
    
    msg_ok "IP source extraite: ${SOURCE_IP}"
    msg_ok "Gateway source: ${SOURCE_GW:-'non définie'}"
}

swap_network_config() {
    msg_info "Transfert de l'IP vers le conteneur cible..."
    
    # Récupérer la config net0 actuelle de la cible pour garder les autres paramètres
    local target_net0
    target_net0=$(pct config "$TARGET_ID" | grep -E '^net0:' | sed 's/^net0: //')
    
    # Extraire le nom de l'interface bridge (ex: vmbr0) - compatible POSIX
    local bridge
    bridge=$(echo "$target_net0" | sed -n 's/.*bridge=\([^,]*\).*/\1/p')
    
    # Extraire le nom de l'interface (ex: eth0) - compatible POSIX
    local iface_name
    iface_name=$(echo "$target_net0" | sed -n 's/.*name=\([^,]*\).*/\1/p')
    iface_name=${iface_name:-eth0}
    
    # Extraire l'adresse MAC (si présente) - compatible POSIX
    local hwaddr
    hwaddr=$(echo "$target_net0" | sed -n 's/.*hwaddr=\([^,]*\).*/\1/p')
    
    # Étape 1: Arrêter les deux conteneurs
    msg_info "Arrêt des conteneurs pour le changement d'IP..."
    pct stop "$SOURCE_ID" 2>/dev/null || true
    pct stop "$TARGET_ID" 2>/dev/null || true
    sleep 2
    
    # Étape 2: Passer la source en DHCP pour éviter le conflit
    msg_info "Passage du conteneur source en DHCP..."
    local source_net0_base
    source_net0_base=$(echo "$SOURCE_NET0" | sed -E 's/ip=[^,]+,?//g' | sed -E 's/gw=[^,]+,?//g' | sed 's/,,/,/g' | sed 's/,$//')
    pct set "$SOURCE_ID" -net0 "${source_net0_base},ip=dhcp"
    msg_ok "Source passée en DHCP"
    
    # Étape 3: Appliquer l'IP à la cible
    msg_info "Application de l'IP ${SOURCE_IP} au conteneur cible..."
    local new_net0="name=${iface_name},bridge=${bridge},ip=${SOURCE_IP}"
    
    if [[ -n "$SOURCE_GW" ]]; then
        new_net0="${new_net0},gw=${SOURCE_GW}"
    fi
    
    if [[ -n "$hwaddr" ]]; then
        new_net0="${new_net0},hwaddr=${hwaddr}"
    fi
    
    pct set "$TARGET_ID" -net0 "$new_net0"
    msg_ok "IP ${SOURCE_IP} appliquée au conteneur cible"
    
    # Étape 4: Redémarrer les conteneurs
    msg_info "Redémarrage des conteneurs..."
    pct start "$SOURCE_ID"
    pct start "$TARGET_ID"
    
    # Attendre que les conteneurs démarrent
    msg_info "Attente du démarrage des conteneurs..."
    sleep 5
    
    # Vérifier que la cible a bien la nouvelle IP
    local new_target_ip
    new_target_ip=$(pct exec "$TARGET_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "")
    
    if [[ "$new_target_ip" == "${SOURCE_IP%/*}" ]]; then
        msg_ok "Conteneur cible accessible sur ${new_target_ip}"
    else
        msg_warn "L'IP du conteneur cible est ${new_target_ip:-'non disponible'} (attendu: ${SOURCE_IP%/*})"
    fi
}

# ==========================================================================
# FONCTIONS DE MIGRATION
# ==========================================================================

create_temp_dir() {
    msg_info "Création du répertoire temporaire..."
    mkdir -p "${TEMP_DIR}/adguard/data"
    mkdir -p "${TEMP_DIR}/unbound"
    msg_ok "Répertoire temporaire créé: ${TEMP_DIR}"
}

cleanup() {
    if [[ -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}

trap cleanup EXIT

stop_services_source() {
    msg_info "Arrêt des services sur le conteneur source (Debian)..."
    
    # Arrêt AdGuard Home (systemd)
    if pct exec "$SOURCE_ID" -- systemctl is-active --quiet AdGuardHome 2>/dev/null; then
        pct exec "$SOURCE_ID" -- systemctl stop AdGuardHome
        msg_ok "AdGuard Home arrêté (source)"
    else
        msg_warn "AdGuard Home déjà arrêté ou inexistant (source)"
    fi
    
    # Arrêt Unbound (systemd)
    if pct exec "$SOURCE_ID" -- systemctl is-active --quiet unbound 2>/dev/null; then
        pct exec "$SOURCE_ID" -- systemctl stop unbound
        msg_ok "Unbound arrêté (source)"
    else
        msg_warn "Unbound déjà arrêté ou inexistant (source)"
    fi
}

stop_services_target() {
    msg_info "Arrêt des services sur le conteneur cible (Alpine)..."
    
    # Arrêt AdGuard Home (OpenRC)
    if pct exec "$TARGET_ID" -- rc-service adguardhome status &>/dev/null; then
        pct exec "$TARGET_ID" -- rc-service adguardhome stop 2>/dev/null || true
        msg_ok "AdGuard Home arrêté (cible)"
    else
        msg_warn "AdGuard Home non trouvé ou déjà arrêté (cible)"
    fi
    
    # Arrêt Unbound (OpenRC) - peut ne pas exister encore
    if pct exec "$TARGET_ID" -- rc-service unbound status &>/dev/null; then
        pct exec "$TARGET_ID" -- rc-service unbound stop 2>/dev/null || true
        msg_ok "Unbound arrêté (cible)"
    fi
}

backup_from_source() {
    msg_info "Sauvegarde des fichiers depuis le conteneur source..."
    
    # Récupérer AdGuardHome.yaml (contient: users, passwords, upstream DNS, settings)
    msg_info "  → Récupération de AdGuardHome.yaml (config + credentials)..."
    pct pull "$SOURCE_ID" "$AGH_YAML" "${TEMP_DIR}/adguard/AdGuardHome.yaml"
    msg_ok "  AdGuardHome.yaml récupéré"
    
    # Récupérer le dossier data COMPLET (stats, filtres, querylog, sessions)
    if pct exec "$SOURCE_ID" -- test -d "$AGH_DATA"; then
        msg_info "  → Récupération du dossier data (structure complète)..."
        
        # Créer un tar sur la source pour préserver la structure
        pct exec "$SOURCE_ID" -- tar -czf /tmp/adguard_data.tar.gz -C "$AGH_DIR" data 2>/dev/null
        
        # Récupérer l'archive
        pct pull "$SOURCE_ID" /tmp/adguard_data.tar.gz "${TEMP_DIR}/adguard_data.tar.gz"
        
        # Extraire localement
        tar -xzf "${TEMP_DIR}/adguard_data.tar.gz" -C "${TEMP_DIR}/adguard/"
        
        # Nettoyer sur la source
        pct exec "$SOURCE_ID" -- rm -f /tmp/adguard_data.tar.gz
        
        # Lister ce qui a été récupéré
        local data_count
        data_count=$(find "${TEMP_DIR}/adguard/data" -type f 2>/dev/null | wc -l)
        msg_ok "  Dossier data récupéré (${data_count} fichiers)"
        
        # Afficher les sous-dossiers importants
        if [[ -d "${TEMP_DIR}/adguard/data/filters" ]]; then
            local filter_count
            filter_count=$(find "${TEMP_DIR}/adguard/data/filters" -type f 2>/dev/null | wc -l)
            msg_ok "    ↳ Filtres: ${filter_count} fichiers"
        fi
    else
        msg_warn "  Dossier data non trouvé (stats/filtres vides)"
    fi
    
    # Récupérer unbound.conf
    msg_info "  → Récupération de unbound.conf..."
    pct pull "$SOURCE_ID" "$UNBOUND_CONF" "${TEMP_DIR}/unbound/unbound.conf"
    msg_ok "  unbound.conf récupéré"
    
    # Récupérer les fichiers de certificats Unbound (si existent)
    for cert_file in unbound_server.key unbound_server.pem unbound_control.key unbound_control.pem; do
        if pct exec "$SOURCE_ID" -- test -f "${UNBOUND_DIR}/${cert_file}"; then
            pct pull "$SOURCE_ID" "${UNBOUND_DIR}/${cert_file}" "${TEMP_DIR}/unbound/${cert_file}" 2>/dev/null || true
        fi
    done
    
    # Récupérer aussi les root.hints si présent
    if pct exec "$SOURCE_ID" -- test -f "/usr/share/dns/root.hints"; then
        pct pull "$SOURCE_ID" "/usr/share/dns/root.hints" "${TEMP_DIR}/unbound/root.hints" 2>/dev/null || true
        msg_ok "  root.hints récupéré"
    fi
    
    msg_ok "Sauvegarde terminée"
}

install_unbound_alpine() {
    msg_info "Installation d'Unbound sur le conteneur Alpine..."
    
    # Vérifier si Unbound est déjà installé
    if pct exec "$TARGET_ID" -- which unbound &>/dev/null; then
        msg_ok "Unbound déjà installé sur Alpine"
    else
        pct exec "$TARGET_ID" -- apk add --no-cache unbound
        msg_ok "Unbound installé sur Alpine"
    fi
    
    # S'assurer que le dossier /etc/unbound existe
    pct exec "$TARGET_ID" -- mkdir -p /etc/unbound
}

push_to_target() {
    msg_info "Envoi des fichiers vers le conteneur cible..."
    
    # Créer les dossiers nécessaires sur la cible
    pct exec "$TARGET_ID" -- mkdir -p "$AGH_DIR"
    pct exec "$TARGET_ID" -- mkdir -p "$UNBOUND_DIR"
    
    # Supprimer l'ancien dossier data sur la cible pour éviter les conflits
    pct exec "$TARGET_ID" -- rm -rf "$AGH_DATA" 2>/dev/null || true
    
    # Envoyer AdGuardHome.yaml (config + users + passwords)
    msg_info "  → Envoi de AdGuardHome.yaml (config + credentials)..."
    pct push "$TARGET_ID" "${TEMP_DIR}/adguard/AdGuardHome.yaml" "$AGH_YAML"
    msg_ok "  AdGuardHome.yaml envoyé"
    
    # Envoyer le dossier data complet via tar (préserve la structure)
    if [[ -d "${TEMP_DIR}/adguard/data" ]] && [[ "$(ls -A ${TEMP_DIR}/adguard/data 2>/dev/null)" ]]; then
        msg_info "  → Envoi du dossier data (structure complète)..."
        
        # Créer l'archive localement
        tar -czf "${TEMP_DIR}/adguard_data_push.tar.gz" -C "${TEMP_DIR}/adguard" data
        
        # Envoyer l'archive vers la cible
        pct push "$TARGET_ID" "${TEMP_DIR}/adguard_data_push.tar.gz" /tmp/adguard_data.tar.gz
        
        # Extraire sur la cible
        pct exec "$TARGET_ID" -- tar -xzf /tmp/adguard_data.tar.gz -C "$AGH_DIR"
        
        # Nettoyer sur la cible
        pct exec "$TARGET_ID" -- rm -f /tmp/adguard_data.tar.gz
        
        msg_ok "  Dossier data envoyé (filtres, stats, querylog, sessions)"
    fi
    
    # Envoyer unbound.conf
    msg_info "  → Envoi de unbound.conf..."
    pct push "$TARGET_ID" "${TEMP_DIR}/unbound/unbound.conf" "$UNBOUND_CONF"
    msg_ok "  unbound.conf envoyé"
    
    # Envoyer les certificats Unbound
    for cert_file in unbound_server.key unbound_server.pem unbound_control.key unbound_control.pem; do
        if [[ -f "${TEMP_DIR}/unbound/${cert_file}" ]]; then
            pct push "$TARGET_ID" "${TEMP_DIR}/unbound/${cert_file}" "${UNBOUND_DIR}/${cert_file}" 2>/dev/null || true
        fi
    done
    
    # Envoyer root.hints si présent
    if [[ -f "${TEMP_DIR}/unbound/root.hints" ]]; then
        pct exec "$TARGET_ID" -- mkdir -p /usr/share/dns
        pct push "$TARGET_ID" "${TEMP_DIR}/unbound/root.hints" /usr/share/dns/root.hints 2>/dev/null || true
        msg_ok "  root.hints envoyé"
    fi
    
    msg_ok "Tous les fichiers envoyés"
}

fix_permissions_alpine() {
    msg_info "Application des permissions sur Alpine..."
    
    # Vérifier si l'utilisateur unbound existe sur Alpine
    if pct exec "$TARGET_ID" -- id unbound &>/dev/null; then
        # Permissions pour Unbound
        pct exec "$TARGET_ID" -- chown -R unbound:unbound /etc/unbound
        pct exec "$TARGET_ID" -- chmod 755 /etc/unbound
        pct exec "$TARGET_ID" -- chmod 644 /etc/unbound/unbound.conf
        
        # Permissions pour les clés de contrôle (si existent)
        pct exec "$TARGET_ID" -- sh -c 'chmod 640 /etc/unbound/unbound_*.key /etc/unbound/unbound_*.pem 2>/dev/null || true'
        
        msg_ok "Permissions Unbound appliquées"
    else
        msg_warn "Utilisateur 'unbound' non trouvé sur Alpine, création..."
        pct exec "$TARGET_ID" -- adduser -S -D -H -h /etc/unbound -s /sbin/nologin unbound 2>/dev/null || true
        pct exec "$TARGET_ID" -- addgroup -S unbound 2>/dev/null || true
        pct exec "$TARGET_ID" -- chown -R unbound:unbound /etc/unbound
        msg_ok "Utilisateur unbound créé et permissions appliquées"
    fi
    
    # Permissions pour AdGuard Home (généralement root)
    pct exec "$TARGET_ID" -- chmod -R 755 "$AGH_DIR"
    msg_ok "Permissions AdGuard Home appliquées"
}

validate_unbound_config() {
    msg_info "Validation de la configuration Unbound..."
    
    if pct exec "$TARGET_ID" -- unbound-checkconf &>/dev/null; then
        msg_ok "Configuration Unbound valide"
    else
        msg_error "Configuration Unbound invalide !"
        msg_info "Détails de l'erreur:"
        pct exec "$TARGET_ID" -- unbound-checkconf 2>&1 || true
        msg_warn "Continuez manuellement pour corriger la configuration."
    fi
}

start_services_target() {
    msg_info "Démarrage des services sur le conteneur cible (Alpine)..."
    
    # Démarrer et activer Unbound (OpenRC)
    if pct exec "$TARGET_ID" -- rc-service unbound start; then
        msg_ok "Unbound démarré"
    else
        msg_error "Échec du démarrage d'Unbound"
    fi
    
    # Activer Unbound au démarrage
    pct exec "$TARGET_ID" -- rc-update add unbound default 2>/dev/null || true
    msg_ok "Unbound activé au démarrage"
    
    # Démarrer AdGuard Home (OpenRC)
    if pct exec "$TARGET_ID" -- rc-service adguardhome start 2>/dev/null; then
        msg_ok "AdGuard Home démarré"
    else
        msg_warn "Impossible de démarrer AdGuard Home via rc-service"
        msg_info "Tentative de démarrage direct..."
        pct exec "$TARGET_ID" -- /opt/AdGuardHome/AdGuardHome -s start 2>/dev/null || true
    fi
}

test_dns_resolution() {
    msg_info "Test de résolution DNS..."
    
    # Test Unbound direct
    if pct exec "$TARGET_ID" -- which dig &>/dev/null; then
        if pct exec "$TARGET_ID" -- dig @127.0.0.1 -p 5335 example.com +short &>/dev/null; then
            msg_ok "Unbound répond correctement (port 5335)"
        else
            msg_warn "Unbound ne répond pas sur le port 5335"
        fi
    else
        msg_info "Installation de bind-tools pour les tests DNS..."
        pct exec "$TARGET_ID" -- apk add --no-cache bind-tools &>/dev/null || true
        
        if pct exec "$TARGET_ID" -- dig @127.0.0.1 -p 5335 example.com +short &>/dev/null; then
            msg_ok "Unbound répond correctement (port 5335)"
        else
            msg_warn "Unbound ne répond pas sur le port 5335"
        fi
    fi
}

show_summary() {
    # Utiliser l'IP source qui a été transférée à la cible
    local target_ip="${SOURCE_IP%/*}"  # Enlever le CIDR (/24)
    
    echo ""
    echo -e "${GN}====================================================================${CL}"
    echo -e "${GN}                    MIGRATION TERMINÉE !${CL}"
    echo -e "${GN}====================================================================${CL}"
    echo ""
    echo -e "  ${INFO} Conteneur source (Debian): ${YW}CT ${SOURCE_ID}${CL} → maintenant en DHCP"
    echo -e "  ${INFO} Conteneur cible (Alpine):  ${YW}CT ${TARGET_ID}${CL} → IP: ${GN}${target_ip}${CL}"
    echo ""
    echo -e "  ${CM} Interface AdGuard Home: ${GN}http://${target_ip}:3000${CL}"
    echo ""
    echo -e "  ${INFO} Prochaines étapes:"
    echo -e "     1. Vérifiez la configuration AdGuard Home via l'interface web"
    echo -e "     2. Testez la résolution DNS: ${YW}dig @${target_ip} google.com${CL}"
    echo -e "     3. Si tout fonctionne, supprimez l'ancien conteneur: ${YW}pct destroy ${SOURCE_ID}${CL}"
    echo ""
}

# ==========================================================================
# POINT D'ENTRÉE PRINCIPAL
# ==========================================================================

main() {
    header_info
    
    # Vérification des arguments
    if [[ -z "$SOURCE_ID" ]] || [[ -z "$TARGET_ID" ]]; then
        usage
    fi
    
    # Vérifications préliminaires
    check_root
    check_pct
    
    echo -e "${INFO} Démarrage de la migration..."
    echo -e "  Source (Debian): ${YW}CT ${SOURCE_ID}${CL}"
    echo -e "  Cible (Alpine):  ${YW}CT ${TARGET_ID}${CL}"
    echo ""
    
    # Vérifier l'existence des conteneurs
    check_container_exists "$SOURCE_ID" "source"
    check_container_exists "$TARGET_ID" "cible"
    
    # Vérifier que les conteneurs sont démarrés
    check_container_running "$SOURCE_ID" "source"
    check_container_running "$TARGET_ID" "cible"
    
    # Vérifier les fichiers sources
    check_source_files
    
    # Extraire la configuration réseau de la source
    extract_network_config
    
    echo ""
    echo -e "${WARN} ATTENTION: Cette migration va:"
    echo -e "   1. Transférer l'IP ${YW}${SOURCE_IP}${CL} vers le conteneur Alpine (${TARGET_ID})"
    echo -e "   2. Passer le conteneur Debian (${SOURCE_ID}) en DHCP"
    echo -e "   3. Migrer toutes les configurations AdGuard Home et Unbound"
    echo ""
    read -rp "Continuer la migration ? (o/N) " confirm
    if [[ ! "$confirm" =~ ^[oOyY]$ ]]; then
        msg_warn "Migration annulée par l'utilisateur."
        exit 0
    fi
    echo ""
    
    # Créer le répertoire temporaire
    create_temp_dir
    
    # Arrêter les services sur les deux conteneurs
    stop_services_source
    stop_services_target
    
    # Sauvegarder depuis la source (AVANT le swap réseau)
    backup_from_source
    
    # Effectuer le swap réseau (arrête/redémarre les conteneurs)
    swap_network_config
    
    # Installer Unbound sur Alpine
    install_unbound_alpine
    
    # Envoyer vers la cible
    push_to_target
    
    # Corriger les permissions
    fix_permissions_alpine
    
    # Valider la config Unbound
    validate_unbound_config
    
    # Démarrer les services sur la cible
    start_services_target
    
    # Tester la résolution DNS
    test_dns_resolution
    
    # Afficher le résumé
    show_summary
}

main "$@"
