#!/bin/bash
set -euo pipefail
umask 077   # fichiers créés en 600 par défaut

# =============================================================================
# Backup Vault COMPLET, chiffré age, poussé sur S3 OVH. Produit deux .age :
#   1. le snapshot Raft    (données : KV, auth, policies, keyring)
#   2. le kit TLS + config  (/opt/vault/tls dont vault-ca.key + vault.hcl)
#
# Ensemble = de quoi reconstruire Vault de zéro (cf. doc "Bascule DR").
# Les unseal keys + root token vivent HORS de ce serveur (coffre) : ils ne
# sont NULLE PART sur disque, ce script ne les touche pas.
#
# Rétention : 30 jours en local, 7 versions par famille sur S3.
# =============================================================================

# --- Config Vault (hardcodée : cron ne lit pas ton .bashrc) ---
export VAULT_ADDR="https://192.168.10.179:8200"
export VAULT_CACERT="/home/orktk/vault-ca.crt"

BACKUP_DIR="/home/orktk/backup"
RETENTION_DAYS=30           # rétention LOCALE
TLS_DIR="/opt/vault/tls"
CONFIG_FILE="/etc/vault.d/vault.hcl"

# Clé PUBLIQUE age. La clé privée reste hors serveur (coffre/HSM).
AGE_RECIPIENT="age153rt7sr3c3ggqalfgztcntffs6e2q57q8t0txmlzzuru4eckw5lq30dqnh"

# --- Config S3 OVH (s5cmd, même profil que les autres backups RepairSoft) ---
MAX_BACKUP=7                # versions conservées PAR FAMILLE sur S3
S3="s3://database-repairsoft/"
ENDPOINT_URL="https://s3.rbx.io.cloud.ovh.net"
S3_PROFILE="database-repairsoft"
SNAP_FOLDER="vault/snapshots/"
KIT_FOLDER="vault/kits/"

DATE=$(date +%Y%m%d-%H%M%S)
SNAP_FILE="${BACKUP_DIR}/vault-snapshot-${DATE}.snap"
SNAP_ENC="${SNAP_FILE}.age"
KIT_TAR="${BACKUP_DIR}/vault-kit-tls-config-${DATE}.tar"
KIT_ENC="${KIT_TAR}.age"
STAGING="$(mktemp -d)"

cleanup() { rm -rf "${STAGING}"; }
trap cleanup EXIT

# --- Pré-vérifications ---
command -v age   >/dev/null 2>&1 || { echo "ERROR: 'age' non installé"; exit 1; }
command -v vault >/dev/null 2>&1 || { echo "ERROR: 'vault' non installé"; exit 1; }
command -v s5cmd >/dev/null 2>&1 || { echo "ERROR: 's5cmd' non installé"; exit 1; }
[[ -f "${VAULT_CACERT}" ]] || { echo "ERROR: CA introuvable: ${VAULT_CACERT}"; exit 1; }
[[ -d "${TLS_DIR}"      ]] || { echo "ERROR: ${TLS_DIR} introuvable"; exit 1; }
[[ -f "${CONFIG_FILE}"  ]] || { echo "ERROR: ${CONFIG_FILE} introuvable"; exit 1; }

mkdir -p "${BACKUP_DIR}"

vault status > /dev/null 2>&1 || {
  echo "ERROR: Vault inaccessible ou scellé (VAULT_ADDR=${VAULT_ADDR})"
  exit 1
}

# =============================================================================
# PARTIE 1 — Snapshot Raft (données Vault)
# =============================================================================

vault operator raft snapshot save "${SNAP_FILE}"

if [[ ! -s "${SNAP_FILE}" ]]; then
  echo "ERROR: Snapshot vide ou manquant"
  exit 1
fi

# Intégrité : le snapshot en clair est-il lisible ?
if ! vault operator raft snapshot inspect "${SNAP_FILE}" > /dev/null 2>&1; then
  echo "ERROR: Snapshot corrompu — backup annulée"
  rm -f "${SNAP_FILE}"
  exit 1
fi
echo "SUCCESS: Snapshot créé et vérifié ${SNAP_FILE}"

# Chiffrement age (X25519 + ChaCha20-Poly1305 authentifié)
if ! age -r "${AGE_RECIPIENT}" -o "${SNAP_ENC}" "${SNAP_FILE}"; then
  echo "ERROR: Échec du chiffrement du snapshot"
  rm -f "${SNAP_FILE}" "${SNAP_ENC}"
  exit 1
fi

# Chiffré produit + en-tête age présent ?
# (le vrai test de déchiffrement se fait ailleurs : la clé privée est hors serveur)
if [[ ! -s "${SNAP_ENC}" ]] || ! head -c 100 "${SNAP_ENC}" | grep -q "age-encryption.org"; then
  echo "ERROR: Snapshot chiffré vide ou en-tête age absent"
  rm -f "${SNAP_FILE}" "${SNAP_ENC}"
  exit 1
fi

shred -u "${SNAP_FILE}"
echo "SUCCESS: Snapshot chiffré ${SNAP_ENC}"

# =============================================================================
# PARTIE 2 — Kit TLS + config (matériel hors snapshot)
# =============================================================================

mkdir -p "${STAGING}/tls" "${STAGING}/config"
sudo cp -a "${TLS_DIR}/." "${STAGING}/tls/"
sudo cp -a "${CONFIG_FILE}" "${STAGING}/config/"
sudo chown -R "$(id -u):$(id -g)" "${STAGING}"

# vault-ca.key est LE fichier critique (piège n°2 de la doc DR)
if [[ ! -s "${STAGING}/tls/vault-ca.key" ]]; then
  echo "WARNING: vault-ca.key absente du kit — la CA ne pourra pas resigner de certif"
fi

tar -cf "${KIT_TAR}" -C "${STAGING}" tls config
if [[ ! -s "${KIT_TAR}" ]]; then
  echo "ERROR: Archive kit vide"
  rm -f "${KIT_TAR}"
  exit 1
fi

if ! age -r "${AGE_RECIPIENT}" -o "${KIT_ENC}" "${KIT_TAR}"; then
  echo "ERROR: Échec du chiffrement du kit"
  rm -f "${KIT_TAR}" "${KIT_ENC}"
  exit 1
fi

if [[ ! -s "${KIT_ENC}" ]] || ! head -c 100 "${KIT_ENC}" | grep -q "age-encryption.org"; then
  echo "ERROR: Kit chiffré vide ou en-tête age absent"
  rm -f "${KIT_TAR}" "${KIT_ENC}"
  exit 1
fi

shred -u "${KIT_TAR}"   # contient vault-ca.key : aucune trace en clair
echo "SUCCESS: Kit TLS+config chiffré ${KIT_ENC}"

# =============================================================================
# PARTIE 3 — Upload S3 (une famille par dossier)
# =============================================================================

echo "Upload S3 du snapshot vers ${S3}${SNAP_FOLDER}"
s5cmd --profile "${S3_PROFILE}" --endpoint-url "${ENDPOINT_URL}" cp \
  "${SNAP_ENC}" "${S3}${SNAP_FOLDER}"

echo "Upload S3 du kit vers ${S3}${KIT_FOLDER}"
s5cmd --profile "${S3_PROFILE}" --endpoint-url "${ENDPOINT_URL}" cp \
  "${KIT_ENC}" "${S3}${KIT_FOLDER}"

# =============================================================================
# PARTIE 4 — Rotation S3 (7 versions PAR FAMILLE)
# =============================================================================

rotate_s3() {
  local folder="$1" pattern="$2"
  local listing count to_delete

  listing=$(s5cmd --profile "${S3_PROFILE}" --endpoint-url "${ENDPOINT_URL}" \
    ls "${S3}${folder}" 2>/dev/null || true)

  # grep | wc -l ne renvoie jamais exit 1 (contrairement à grep -c)
  count=$(echo "${listing}" | grep "${pattern}" | wc -l || true)

  if [[ "${count}" -le "${MAX_BACKUP}" ]]; then
    echo "Rotation ${folder} : ${count} backup(s), seuil ${MAX_BACKUP} — rien à supprimer"
    return 0
  fi

  to_delete=$((count - MAX_BACKUP))
  echo "Rotation ${folder} : ${count} backup(s), suppression de ${to_delete} ancien(s)"

  # tri par nom (le timestamp dans le nom = ordre chrono), on vire les plus vieux
  while read -r KEY; do
    [[ -z "${KEY}" ]] && continue
    echo "Suppression : ${KEY}"
    s5cmd --profile "${S3_PROFILE}" --endpoint-url "${ENDPOINT_URL}" \
      rm "${S3}${folder}${KEY}"
  done < <(echo "${listing}" | grep "${pattern}" | sort | head -n "${to_delete}" | awk '{print $NF}')

  echo "Rotation ${folder} terminée"
}

rotate_s3 "${SNAP_FOLDER}" "\.snap\.age$"
rotate_s3 "${KIT_FOLDER}"  "\.tar\.age$"

# =============================================================================
# PARTIE 5 — Rétention LOCALE (30 jours)
# =============================================================================

find "${BACKUP_DIR}" -name "vault-snapshot-*.snap.age"      -mtime +${RETENTION_DAYS} -delete
find "${BACKUP_DIR}" -name "vault-kit-tls-config-*.tar.age" -mtime +${RETENTION_DAYS} -delete
echo "SUCCESS: Rétention locale appliquée (>${RETENTION_DAYS}j supprimés)"

echo "DONE: backup complet — local (${BACKUP_DIR}) + S3 (${S3}vault/)"
