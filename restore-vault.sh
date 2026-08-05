#!/bin/bash
set -euo pipefail
umask 077

# =============================================================================
# Restauration DR d'un Vault mono-nœud depuis les backups age sur S3 OVH.
# (cf. doc "Bascule DR"). La machine qui remonte reprend le MÊME nom/IP que
# l'ancienne → on RÉUTILISE la CA + la config du kit S3 (pas de régénération,
# pas de nouvelle CA à pousser au VSO — piège n°2 évité).
#
# Usage en DEUX temps :
#   ./restore-vault.sh phase1  → télécharge snapshot + kit depuis S3, pose TLS +
#                                config du kit, installe/démarre Vault, init
#                                (clés JETABLES), unseal jetable. PUIS S'ARRÊTE.
#   ./restore-vault.sh phase2  → restore le snapshot, demande tes 3 ANCIENNES
#                                clés Shamir (coffre), unseal, rebranche le VSO.
#
# Les clés jetables de phase1 MEURENT au restore. Seules tes anciennes clés
# Shamir descellent le Vault restauré (doc §3.6).
# =============================================================================

# =========================== CONFIG (à adapter) ==============================
# --- Cible : même nom/IP que l'ancien Vault (le kit contient déjà le bon SAN) ---
VAULT_HOST="192.168.10.179"          # ex. "vault.preprod.mondomaine.fr"
VAULT_ADDR="https://${VAULT_HOST}:8200"
VAULT_VERSION="1.21.4-1"             # version épinglée, identique à la source

# --- Régénérer CA+config au lieu de réutiliser le kit ? (seulement si IP change) ---
REGEN_CA=false
VAULT_CN="vault.orktk.local"         # utilisé seulement si REGEN_CA=true

# --- Backups age ---
BACKUP_DIR="/home/orktk/backup"
AGE_KEY="/home/orktk/backup/vault-backup-key.txt"   # clé privée age (déchiffrement)

# --- S3 OVH (mêmes réglages que le script de backup) ---
S3="s3://database-repairsoft/"
ENDPOINT_URL="https://s3.rbx.io.cloud.ovh.net"
S3_PROFILE="database-repairsoft"
SNAP_FOLDER="vault/snapshots/"
KIT_FOLDER="vault/kits/"

# --- VSO (phase2) ---
VSO_NS="vault-secrets-operator"
VSO_CA_SECRET="vault-ca"
APP_NS="poc"
VSO_CRS="poc-nginx poc-postgres"
VSO_DEPLOY="vault-secrets-operator-controller-manager"

# --- Fichiers internes ---
TLS_DIR="/opt/vault/tls"
CONFIG_FILE="/etc/vault.d/vault.hcl"
CA_CLI="/home/orktk/vault-ca-restore.crt"
STATE_FILE="/home/orktk/.vault-restore-state"
# ============================================================================

log()  { echo -e "\n\033[1;36m[*] $*\033[0m"; }
ok()   { echo -e "\033[1;32m[OK] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
die()  { echo -e "\033[1;31m[ERROR] $*\033[0m" >&2; exit 1; }

export VAULT_ADDR
export VAULT_CACERT="${CA_CLI}"

s3() { s5cmd --profile "${S3_PROFILE}" --endpoint-url "${ENDPOINT_URL}" "$@"; }

# --- Télécharger le plus récent objet d'un dossier S3 correspondant à un motif ---
fetch_latest() {
  local folder="$1" pattern="$2" dest="$3"
  local key
  key=$(s3 ls "${S3}${folder}" 2>/dev/null | grep "${pattern}" | sort | tail -1 | awk '{print $NF}')
  [[ -n "${key}" ]] || die "Aucun objet ${pattern} dans ${S3}${folder}"
  log "Téléchargement ${folder}${key}"
  s3 cp "${S3}${folder}${key}" "${dest}"
  echo "${dest}/${key}"
}

# =============================================================================
# PHASE 1 — Télécharger S3, poser TLS+config du kit, installer, init jetable
# =============================================================================
phase1() {
  log "PHASE 1 — reconstruction du Vault sur ${VAULT_ADDR}"

  command -v age   >/dev/null 2>&1 || die "'age' non installé"
  command -v s5cmd >/dev/null 2>&1 || die "'s5cmd' non installé"
  command -v jq    >/dev/null 2>&1 || die "'jq' non installé"
  [[ -f "${AGE_KEY}" ]] || die "Clé privée age introuvable: ${AGE_KEY}"
  mkdir -p "${BACKUP_DIR}"

  # --- Télécharger snapshot + kit depuis S3 ---
  SNAP_ENC=$(fetch_latest "${SNAP_FOLDER}" "\.snap\.age$" "${BACKUP_DIR}")
  echo "SNAP_ENC=${SNAP_ENC}" > "${STATE_FILE}"; chmod 600 "${STATE_FILE}"
  KIT_ENC=$(fetch_latest "${KIT_FOLDER}" "\.tar\.age$" "${BACKUP_DIR}")

  # --- Install Vault (version épinglée) ---
  if ! command -v vault >/dev/null 2>&1 || [[ "$(vault version 2>/dev/null)" != *"${VAULT_VERSION%%-*}"* ]]; then
    log "Installation de Vault ${VAULT_VERSION}"
    sudo apt-get update && sudo apt-get install -y gpg wget lsb-release
    wget -qO- https://apt.releases.hashicorp.com/gpg | \
      sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
      sudo tee /etc/apt/sources.list.d/hashicorp.list
    sudo apt-get update
    sudo apt-get install -y --allow-downgrades "vault=${VAULT_VERSION}"
    sudo apt-mark hold vault
  fi
  ok "vault $(vault version)"

  sudo mkdir -p "${TLS_DIR}"

  if [[ "${REGEN_CA}" == "true" ]]; then
    # -------- Fallback : CA + config NEUVES (cas IP différente) --------
    log "REGEN_CA=true → génération CA + certif + config neufs (SAN: ${VAULT_HOST})"
    local T; T="$(mktemp -d)"
    if [[ "${VAULT_HOST}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      local SAN_LINE="IP.1  = ${VAULT_HOST}"
    else
      local SAN_LINE="DNS.2 = ${VAULT_HOST}"
    fi
    openssl genrsa -out "${T}/vault-ca.key" 4096
    openssl req -x509 -new -nodes -key "${T}/vault-ca.key" -sha256 -days 3650 \
      -out "${T}/vault-ca.crt" -subj "/CN=Vault Internal CA"
    cat > "${T}/vault.cnf" <<EOF
[req]
distinguished_name = dn
req_extensions = v3_req
prompt = no
[dn]
CN = ${VAULT_CN}
[v3_req]
subjectAltName = @alt
[alt]
IP.2  = 127.0.0.1
DNS.1 = localhost
${SAN_LINE}
EOF
    openssl genrsa -out "${T}/vault.key" 4096
    openssl req -new -key "${T}/vault.key" -out "${T}/vault.csr" -config "${T}/vault.cnf"
    openssl x509 -req -in "${T}/vault.csr" -CA "${T}/vault-ca.crt" -CAkey "${T}/vault-ca.key" \
      -CAcreateserial -out "${T}/vault.crt" -days 825 -sha256 \
      -extensions v3_req -extfile "${T}/vault.cnf"
    sudo cp "${T}/vault.crt" "${T}/vault.key" "${T}/vault-ca.crt" "${TLS_DIR}/"
    cp "${T}/vault-ca.key" "${BACKUP_DIR}/vault-ca-restore.key"
    warn "Nouvelle CA → il FAUDRA repousser cette CA au VSO en phase 2 (piège n°2)"
    rm -rf "${T}"

    # config neuve
    sudo tee "${CONFIG_FILE}" > /dev/null <<EOF
ui = true
storage "raft" { path = "/opt/vault/data" node_id = "vault-1" }
listener "tcp" {
  address = "0.0.0.0:8200"
  tls_cert_file = "${TLS_DIR}/vault.crt"
  tls_key_file  = "${TLS_DIR}/vault.key"
}
api_addr     = "https://${VAULT_HOST}:8200"
cluster_addr = "https://${VAULT_HOST}:8201"
disable_mlock = false
EOF
  else
    # -------- Cas nominal : RÉUTILISER le kit S3 (même nom/IP) --------
    log "Déchiffrement du kit S3 → pose TLS + config (même SAN/api_addr qu'avant)"
    local KT; KT="$(mktemp -d)"
    age -d -i "${AGE_KEY}" -o "${KT}/kit.tar" "${KIT_ENC}" || die "Déchiffrement du kit échoué"
    tar -xf "${KT}/kit.tar" -C "${KT}"
    [[ -f "${KT}/tls/vault-ca.key" ]] || warn "vault-ca.key absente du kit"
    sudo cp "${KT}/tls/." "${TLS_DIR}/" -a
    sudo cp "${KT}/config/vault.hcl" "${CONFIG_FILE}"
    rm -rf "${KT}"
    ok "TLS + config restaurés depuis le kit"
  fi

  # Permissions + CA pour le CLI
  sudo chown -R vault:vault "${TLS_DIR}"
  sudo chmod 640 "${TLS_DIR}/vault.key"
  sudo chmod 644 "${TLS_DIR}/vault.crt" "${TLS_DIR}/vault-ca.crt"
  sudo cp "${TLS_DIR}/vault-ca.crt" "${CA_CLI}"; sudo chown "$(id -u):$(id -g)" "${CA_CLI}"

  sudo mkdir -p /opt/vault/data
  sudo chown -R vault:vault /opt/vault/data /etc/vault.d
  sudo chmod 640 "${CONFIG_FILE}"

  if sudo ls -A /opt/vault/data 2>/dev/null | grep -q .; then
    die "/opt/vault/data n'est pas vide — Vault déjà initialisé ? Nettoie d'abord."
  fi

  sudo openssl x509 -in "${TLS_DIR}/vault.crt" -noout -text | grep -A1 "Subject Alternative Name" || true

  # --- Démarrer + init (clés JETABLES) ---
  log "Démarrage de Vault + init (clés jetables)"
  sudo systemctl enable --now vault
  sleep 3
  vault status 2>/dev/null || true

  local INIT_JSON; INIT_JSON="$(vault operator init -key-shares=5 -key-threshold=3 -format=json)"
  local UK1 UK2 UK3 RT
  UK1=$(echo "${INIT_JSON}" | jq -r '.unseal_keys_b64[0]')
  UK2=$(echo "${INIT_JSON}" | jq -r '.unseal_keys_b64[1]')
  UK3=$(echo "${INIT_JSON}" | jq -r '.unseal_keys_b64[2]')
  RT=$(echo "${INIT_JSON}"  | jq -r '.root_token')

  vault operator unseal "${UK1}" >/dev/null
  vault operator unseal "${UK2}" >/dev/null
  vault operator unseal "${UK3}" >/dev/null

  echo "ROOT_TOKEN_JETABLE=${RT}" >> "${STATE_FILE}"
  echo "REGEN_CA=${REGEN_CA}"     >> "${STATE_FILE}"

  echo
  ok "PHASE 1 terminée — Vault installé, initialisé, DESCELLÉ (clés jetables)."
  echo "---------------------------------------------------------------"
  echo "  Clés JETABLES (mortes après le restore) — root token jetable :"
  echo "    ${RT}"
  echo "  (snapshot déjà téléchargé, mémorisé pour la phase 2)"
  echo "---------------------------------------------------------------"
  echo "  ➜ Vérifie 'vault status' (Sealed=false), puis : ./restore-vault.sh phase2"
}

# =============================================================================
# PHASE 2 — Restore snapshot, unseal ANCIENNES clés, rebrancher VSO
# =============================================================================
phase2() {
  log "PHASE 2 — restauration du snapshot + unseal + VSO"

  [[ -f "${STATE_FILE}" ]] || die "État phase1 introuvable. Lance phase1 d'abord."
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
  [[ -n "${ROOT_TOKEN_JETABLE:-}" ]] || die "Root token jetable manquant."
  [[ -n "${SNAP_ENC:-}" && -f "${SNAP_ENC}" ]] || die "Snapshot .age introuvable (${SNAP_ENC:-vide})."
  [[ -f "${AGE_KEY}" ]] || die "Clé privée age introuvable: ${AGE_KEY}"
  log "Snapshot : ${SNAP_ENC}"

  echo "${ROOT_TOKEN_JETABLE}" | vault login - >/dev/null || die "Login root jetable échoué"

  local SNAP_CLEAR="/tmp/vault-restore-$$.snap"
  age -d -i "${AGE_KEY}" -o "${SNAP_CLEAR}" "${SNAP_ENC}" || die "Déchiffrement age échoué"
  vault operator raft snapshot inspect "${SNAP_CLEAR}" >/dev/null 2>&1 || die "Snapshot invalide"
  ok "Snapshot déchiffré et vérifié"

  log "Restauration (Vault va se re-sceller, normal)"
  vault operator raft snapshot restore -force "${SNAP_CLEAR}"
  shred -u "${SNAP_CLEAR}"

  echo
  warn "Vault re-scellé. Descelle avec tes 3 ANCIENNES clés Shamir (coffre)."
  echo "  (les clés jetables de phase1 sont MORTES — elles seront rejetées)"
  echo
  local i
  for i in 1 2 3; do
    read -rsp "  Ancienne clé Shamir ${i}/3 : " OLDKEY; echo
    vault operator unseal "${OLDKEY}" >/dev/null || die "Clé ${i} rejetée (pas une clé de la source ?)"
    unset OLDKEY
  done

  vault status -format=json 2>/dev/null | jq -e '.sealed == false' >/dev/null \
    && ok "Vault DESCELLÉ avec les clés de la source" || die "Toujours scellé — clés insuffisantes ?"

  echo
  read -rsp "  Ancien root token (source) : " OLD_RT; echo
  echo "${OLD_RT}" | vault login - >/dev/null || die "Login ancien root échoué"
  unset OLD_RT

  log "Données restaurées :"
  vault secrets list || true; vault auth list || true; vault policy list || true

  # --- Rebrancher le VSO ---
  log "Rebranchement du VSO K8s sur ${VAULT_ADDR}"
  if ! command -v kubectl >/dev/null 2>&1; then
    warn "kubectl absent — étape VSO sautée (doc Phase 4 à la main)."
  else
    # CA neuve → il faut la repousser. CA réutilisée (kit) → inutile.
    if [[ "${REGEN_CA:-false}" == "true" ]]; then
      warn "CA régénérée → repush de la CA au VSO"
      kubectl delete secret "${VSO_CA_SECRET}" -n "${VSO_NS}" 2>/dev/null || true
      kubectl create secret generic "${VSO_CA_SECRET}" -n "${VSO_NS}" \
        --from-file=ca.crt="${CA_CLI}"
    else
      ok "CA réutilisée depuis le kit → pas de nouvelle CA à pousser au VSO"
    fi

    kubectl patch vaultconnection default -n "${VSO_NS}" --type merge \
      -p "{\"spec\":{\"address\":\"${VAULT_ADDR}\"}}"
    kubectl rollout restart deployment "${VSO_DEPLOY}" -n "${VSO_NS}"
    kubectl rollout status  deployment "${VSO_DEPLOY}" -n "${VSO_NS}"

    local CR
    for CR in ${VSO_CRS}; do
      kubectl get vaultstaticsecret "${CR}" -n "${APP_NS}" -o yaml > "/tmp/cr-${CR}.yaml" 2>/dev/null \
        && kubectl delete vaultstaticsecret "${CR}" -n "${APP_NS}" \
        && kubectl apply -f "/tmp/cr-${CR}.yaml" \
        && rm -f "/tmp/cr-${CR}.yaml" || warn "CR ${CR} : à vérifier à la main"
    done
    ok "VSO rebranché — kubectl get vaultstaticsecret -n ${APP_NS} -w"
  fi

  rm -f "${STATE_FILE}"
  echo
  ok "PHASE 2 terminée — Vault restauré, descellé, VSO rebranché."
  echo "  Test final : rotation d'un secret (doc Phase 5)."
}

case "${1:-}" in
  phase1) phase1 ;;
  phase2) phase2 ;;
  *) echo "Usage: $0 {phase1|phase2}"; exit 1 ;;
esac