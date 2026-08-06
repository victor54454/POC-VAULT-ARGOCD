#!/bin/bash
set -euo pipefail
umask 077

# =============================================================================
# Restauration DR d'un Vault mono-nœud depuis les backups age sur S3 OVH.
# (cf. doc "Bascule DR").
#
# Usage en DEUX temps :
#   ./restore-vault.sh phase1  → télécharge snapshot + kit depuis S3, pose TLS +
#                                config, installe/démarre Vault, init (clés
#                                JETABLES), unseal jetable. PUIS S'ARRÊTE.
#   ./restore-vault.sh phase2  → restore le snapshot, demande tes 3 ANCIENNES
#                                clés Shamir, unseal, rebranche le VSO au cluster.
#
# Les clés jetables de phase1 MEURENT au restore. Seules tes anciennes clés
# Shamir descellent le Vault restauré (doc §3.6).
#
# NOTE : la phase2 rebranche le VSO → à lancer sur une machine qui a kubectl
# et accès au cluster (la machine où vit le cluster K8s). Si kubectl est
# absent, l'étape VSO est sautée (avec avertissement) et le reste se fait.
# =============================================================================

# =========================== CONFIG (à adapter) ==============================
VAULT_HOST="192.168.10.222"          # nouvelle IP/nom du Vault (ou l'ancienne si REGEN_CA=false)
VAULT_ADDR="https://${VAULT_HOST}:8200"
VAULT_VERSION="1.21.4-1"

# --- Régénérer CA+config (true si IP change) OU réutiliser le kit (false) ---
REGEN_CA=true
VAULT_CN="vault.orktk.local"         # utilisé seulement si REGEN_CA=true

# --- Backups age ---
BACKUP_DIR="/home/orktk/backup"
AGE_KEY="/home/orktk/vault-backup-key.txt"   # clé privée age (déchiffrement)

# --- S3 OVH ---
S3="s3://repairsoft-backup-test-xsjbxqsaz047d/"
ENDPOINT_URL="https://s3.rbx.io.cloud.ovh.net"
S3_PROFILE="database-repairsoft"
SNAP_FOLDER="vault/snapshots/"
KIT_FOLDER="vault/kits/"
CA_FOLDER="vault/ca/"          # CA du nouveau Vault, déposée en phase2 pour la phase3

# --- Ajouter les variables Vault au ~/.bashrc (plus besoin de les retaper) ---
ADD_TO_BASHRC=true
BASHRC="${HOME}/.bashrc"

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

# FIX : tous les logs sur STDERR. Sinon, capturés par $(fetch_latest ...),
# ils polluent le STATE_FILE avec des codes couleur (bug rencontré).
log()  { echo -e "\n\033[1;36m[*] $*\033[0m" >&2; }
ok()   { echo -e "\033[1;32m[OK] $*\033[0m" >&2; }
warn() { echo -e "\033[1;33m[!] $*\033[0m" >&2; }
die()  { echo -e "\033[1;31m[ERROR] $*\033[0m" >&2; exit 1; }

export VAULT_ADDR
export VAULT_CACERT="${CA_CLI}"

s3() { s5cmd --profile "${S3_PROFILE}" --endpoint-url "${ENDPOINT_URL}" "$@"; }

# --- Ajoute (une seule fois) les variables Vault au bashrc ---
persist_env_bashrc() {
  [[ "${ADD_TO_BASHRC}" == "true" ]] || return 0
  grep -q "# >>> vault-restore env >>>" "${BASHRC}" 2>/dev/null && return 0
  cat >> "${BASHRC}" <<EOF

# >>> vault-restore env >>>
export VAULT_ADDR="${VAULT_ADDR}"
export VAULT_CACERT="${CA_CLI}"
# <<< vault-restore env <<<
EOF
  ok "Variables ajoutées à ${BASHRC} (fais 'source ${BASHRC}' ou ouvre un nouveau shell)"
}

# --- Télécharge le plus récent objet S3 matchant un motif.
#     FIX : n'écrit QUE le chemin sur stdout ; logs et cp sur stderr. ---
fetch_latest() {
  local folder="$1" pattern="$2" dest="$3"
  local key
  key=$(s3 ls "${S3}${folder}" 2>/dev/null | grep "${pattern}" | sort | tail -1 | awk '{print $NF}')
  [[ -n "${key}" ]] || die "Aucun objet ${pattern} dans ${S3}${folder}"
  log "Téléchargement ${folder}${key}"
  s3 cp "${S3}${folder}${key}" "${dest}/" >&2
  printf '%s\n' "${dest}/${key}"
}

# =============================================================================
# PHASE 1
# =============================================================================
phase1() {
  log "PHASE 1 — reconstruction du Vault sur ${VAULT_ADDR}"

  command -v age   >/dev/null 2>&1 || die "'age' non installé"
  command -v s5cmd >/dev/null 2>&1 || die "'s5cmd' non installé"
  command -v jq    >/dev/null 2>&1 || die "'jq' non installé"
  [[ -f "${AGE_KEY}" ]] || die "Clé privée age introuvable: ${AGE_KEY}"
  mkdir -p "${BACKUP_DIR}"

  # --- Télécharger snapshot + kit depuis S3 ---
  local snap_enc kit_enc
  snap_enc=$(fetch_latest "${SNAP_FOLDER}" "\.snap\.age$" "${BACKUP_DIR}")
  kit_enc=$(fetch_latest "${KIT_FOLDER}" "\.tar\.age$" "${BACKUP_DIR}")

  # --- Écrire le STATE_FILE PROPREMENT (printf seuls, aucun log ici) ---
  {
    printf 'SNAP_ENC=%s\n' "${snap_enc}"
    printf 'REGEN_CA=%s\n' "${REGEN_CA}"
  } > "${STATE_FILE}"
  chmod 600 "${STATE_FILE}"

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
    # -------- CA + config NEUVES (cas IP différente) --------
    log "REGEN_CA=true → génération CA + certif + config neufs (SAN: ${VAULT_HOST})"
    local T; T="$(mktemp -d)"
    local SAN_LINE
    if [[ "${VAULT_HOST}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      SAN_LINE="IP.1  = ${VAULT_HOST}"
    else
      SAN_LINE="DNS.2 = ${VAULT_HOST}"
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
    warn "Nouvelle CA → repush au VSO en phase 2 (piège n°2)"
    rm -rf "${T}"

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
    # -------- RÉUTILISER le kit S3 (même nom/IP) --------
    log "Déchiffrement du kit S3 → pose TLS + config (même SAN/api_addr qu'avant)"
    local KT; KT="$(mktemp -d)"
    age -d -i "${AGE_KEY}" -o "${KT}/kit.tar" "${kit_enc}" || die "Déchiffrement du kit échoué"
    tar -xf "${KT}/kit.tar" -C "${KT}"
    [[ -f "${KT}/tls/vault-ca.key" ]] || warn "vault-ca.key absente du kit"
    sudo cp -a "${KT}/tls/." "${TLS_DIR}/"
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

  sudo openssl x509 -in "${TLS_DIR}/vault.crt" -noout -text | grep -A1 "Subject Alternative Name" >&2 || true

  # --- Démarrer + init (clés JETABLES) ---
  log "Démarrage de Vault + init (clés jetables)"
  sudo systemctl enable --now vault
  sleep 3

  local INIT_JSON; INIT_JSON="$(vault operator init -key-shares=5 -key-threshold=3 -format=json)"
  local UK1 UK2 UK3 RT
  UK1=$(echo "${INIT_JSON}" | jq -r '.unseal_keys_b64[0]')
  UK2=$(echo "${INIT_JSON}" | jq -r '.unseal_keys_b64[1]')
  UK3=$(echo "${INIT_JSON}" | jq -r '.unseal_keys_b64[2]')
  RT=$(echo "${INIT_JSON}"  | jq -r '.root_token')

  vault operator unseal "${UK1}" >/dev/null
  vault operator unseal "${UK2}" >/dev/null
  vault operator unseal "${UK3}" >/dev/null

  # Ajouter le root token jetable au STATE_FILE (printf propre)
  printf 'ROOT_TOKEN_JETABLE=%s\n' "${RT}" >> "${STATE_FILE}"

  persist_env_bashrc

  echo >&2
  ok "PHASE 1 terminée — Vault installé, initialisé, DESCELLÉ (clés jetables)."
  echo "  Root token jetable (mémorisé pour phase2) : ${RT}" >&2
  echo "  ➜ vault status (Sealed=false), puis : ./restore-vault.sh phase2" >&2
}

# =============================================================================
# PHASE 2
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

  echo >&2
  warn "Vault re-scellé. Descelle avec tes 3 ANCIENNES clés Shamir (coffre)."
  local i
  for i in 1 2 3; do
    read -rsp "  Ancienne clé Shamir ${i}/3 : " OLDKEY; echo >&2
    vault operator unseal "${OLDKEY}" >/dev/null || die "Clé ${i} rejetée (pas une clé de la source ?)"
    unset OLDKEY
  done

  vault status -format=json 2>/dev/null | jq -e '.sealed == false' >/dev/null \
    && ok "Vault DESCELLÉ avec les clés de la source" || die "Toujours scellé — clés insuffisantes ?"

  echo >&2
  read -rsp "  Ancien root token (source) : " OLD_RT; echo >&2
  echo "${OLD_RT}" | vault login - >/dev/null || die "Login ancien root échoué"
  unset OLD_RT

  log "Données restaurées :"
  vault secrets list >&2 || true; vault auth list >&2 || true; vault policy list >&2 || true

  # --- Déposer la CA du nouveau Vault sur S3, pour que la phase3 (sur le
  #     cluster) la récupère sans scp ni copie manuelle. On dépose aussi un
  #     petit fichier d'adresse, pour que phase3 sache quelle IP viser. ---
  log "Dépôt de la CA + de l'adresse du nouveau Vault sur S3 (pour la phase3)"
  s3 cp "${CA_CLI}" "${S3}${CA_FOLDER}vault-ca.crt" >&2
  printf 'VAULT_ADDR=%s\nREGEN_CA=%s\n' "${VAULT_ADDR}" "${REGEN_CA}" > /tmp/vault-target.env
  s3 cp /tmp/vault-target.env "${S3}${CA_FOLDER}vault-target.env" >&2
  rm -f /tmp/vault-target.env
  ok "CA + adresse déposées sur ${S3}${CA_FOLDER}"

  rm -f "${STATE_FILE}"
  echo >&2
  ok "PHASE 2 terminée — Vault restauré et descellé sur ${VAULT_ADDR}."
  warn "Le cluster n'est PAS encore rebranché sur ce Vault."
  echo "  ➜ Va sur la machine du CLUSTER (celle qui a kubectl + accès au cluster) et lance :" >&2
  echo "        ./restore-vault.sh phase3" >&2
  echo "     Elle récupérera la CA depuis le S3 et repointera le VSO sur ce Vault." >&2
}

# =============================================================================
# PHASE 3 — À exécuter SUR LA MACHINE DU CLUSTER. Rebranche le VSO sur le nouveau
#           Vault : récupère la CA depuis S3, repointe la VaultConnection,
#           recrée les CR. Ne touche PAS au Vault, seulement à Kubernetes.
# =============================================================================
phase3() {
  log "PHASE 3 — rebranchement du cluster sur le nouveau Vault"

  command -v kubectl >/dev/null 2>&1 || die "kubectl absent : la phase3 doit tourner sur la machine du cluster (celle qui a kubectl + accès au cluster)."
  command -v s5cmd  >/dev/null 2>&1 || die "'s5cmd' non installé"

  # Récupérer l'adresse cible + REGEN_CA déposés par la phase2
  local TARGET="/tmp/vault-target.env"
  s3 cp "${S3}${CA_FOLDER}vault-target.env" "${TARGET}" >&2     || die "Adresse cible introuvable sur S3 (${S3}${CA_FOLDER}). La phase2 a-t-elle tourné ?"
  # shellcheck disable=SC1090
  source "${TARGET}"; rm -f "${TARGET}"
  [[ -n "${VAULT_ADDR:-}" ]] || die "VAULT_ADDR introuvable dans le fichier cible S3."
  log "Cible : ${VAULT_ADDR} (REGEN_CA=${REGEN_CA:-false})"

  # Repush de la CA au VSO seulement si elle a changé (REGEN_CA=true)
  if [[ "${REGEN_CA:-false}" == "true" ]]; then
    log "Récupération de la CA du nouveau Vault depuis S3 + push au VSO"
    local CA_TMP="/tmp/vault-ca-new.crt"
    s3 cp "${S3}${CA_FOLDER}vault-ca.crt" "${CA_TMP}" >&2       || die "CA introuvable sur S3 (${S3}${CA_FOLDER}vault-ca.crt)."
    kubectl delete secret "${VSO_CA_SECRET}" -n "${VSO_NS}" 2>/dev/null || true
    kubectl create secret generic "${VSO_CA_SECRET}" -n "${VSO_NS}"       --from-file=ca.crt="${CA_TMP}"
    rm -f "${CA_TMP}"
    ok "CA du nouveau Vault poussée au VSO"
  else
    ok "REGEN_CA=false → CA inchangée, rien à repousser au VSO"
  fi

  # Repointer la VaultConnection (LE lien cluster → Vault)
  log "Repointage de la VaultConnection sur ${VAULT_ADDR}"
  kubectl patch vaultconnection default -n "${VSO_NS}" --type merge     -p "{\"spec\":{\"address\":\"${VAULT_ADDR}\"}}"

  # Restart opérateur + recréation des CR (purge le client en cache, piège n°3)
  kubectl rollout restart deployment "${VSO_DEPLOY}" -n "${VSO_NS}"
  kubectl rollout status  deployment "${VSO_DEPLOY}" -n "${VSO_NS}"

  local CR
  for CR in ${VSO_CRS}; do
    kubectl get vaultstaticsecret "${CR}" -n "${APP_NS}" -o yaml > "/tmp/cr-${CR}.yaml" 2>/dev/null       && kubectl delete vaultstaticsecret "${CR}" -n "${APP_NS}"       && kubectl apply -f "/tmp/cr-${CR}.yaml"       && rm -f "/tmp/cr-${CR}.yaml" || warn "CR ${CR} : à vérifier à la main"
  done

  echo >&2
  ok "PHASE 3 terminée — Cluster REBRANCHÉ sur ${VAULT_ADDR}."
  echo "  Vérifie la resynchro :" >&2
  echo "     kubectl get vaultstaticsecret -n ${APP_NS} -w   (attendu : SYNCED True)" >&2
  echo "  Test final : rotation d'un secret (doc Phase 5)." >&2
}

usage() {
  echo -e "" >&2
  echo -e "\033[1;31mERREUR : argument manquant ou invalide.\033[0m" >&2
  echo -e "" >&2
  echo -e "Ce script se lance en TROIS temps. Tu dois préciser la phase à exécuter :" >&2
  echo -e "" >&2
  echo -e "  \033[1;36m$0 phase1\033[0m" >&2
  echo -e "      Reconstruit un Vault vierge sur la machine cible :" >&2
  echo -e "        - télécharge le snapshot + le kit TLS/config depuis S3" >&2
  echo -e "        - installe Vault, pose la CA/config, démarre le service" >&2
  echo -e "        - initialise (clés JETABLES) et déscelle" >&2
  echo -e "      -> PUIS S'ARRÊTE. À lancer sur la machine qui hébergera le Vault." >&2
  echo -e "" >&2
  echo -e "  \033[1;36m$0 phase2\033[0m" >&2
  echo -e "      Restaure les données dans le nouveau Vault :" >&2
  echo -e "        - restaure le snapshot dans le Vault vierge" >&2
  echo -e "        - demande tes 3 ANCIENNES clés Shamir (coffre) pour déscéller" >&2
  echo -e "        - demande l'ancien root token" >&2
  echo -e "        - dépose la CA du nouveau Vault sur le S3 (pour la phase3)" >&2
  echo -e "      -> À lancer APRÈS phase1, sur la machine" >&2
  echo -e "         qui héberge le nouveau Vault (kubectl PAS requis ici)." >&2
  echo -e "" >&2
  echo -e "  \033[1;36m$0 phase3\033[0m" >&2
  echo -e "      Rebranche le cluster sur le nouveau Vault :" >&2
  echo -e "        - récupère la CA du nouveau Vault depuis le S3" >&2
  echo -e "        - repointe la VaultConnection + recrée les CR du VSO" >&2
  echo -e "      -> À lancer sur la MACHINE DU CLUSTER (celle qui a kubectl)." >&2
  echo -e "         C'est CETTE phase qui relie le cluster à Vault." >&2
  echo -e "" >&2
  echo -e "Ordre : \033[1;36mphase1\033[0m (nouveau Vault) -> \033[1;36mphase2\033[0m (nouveau Vault)" >&2
  echo -e "        -> \033[1;36mphase3\033[0m (machine du cluster)." >&2
  echo -e "" >&2
  exit 1
}

case "${1:-}" in
  phase1) phase1 ;;
  phase2) phase2 ;;
  phase3) phase3 ;;
  *) usage ;;
esac