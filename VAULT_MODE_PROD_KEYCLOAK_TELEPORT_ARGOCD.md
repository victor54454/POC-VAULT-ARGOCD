# Vault en production — mono-nœud (systemd + TLS + Shamir)

Suite du POC ArgoCD + Vault. Le POC tournait en **mode dev** : Vault unsealed,
en mémoire, root token fixe, tout perdu au moindre reboot. Cette doc décrit le
passage à une installation **production-grade** sur un nœud unique, et le
rebranchement du Vault Secrets Operator (VSO) existant sur ce nouveau Vault.

> **Périmètre.** Cible réellement déployée : Vault **mono-nœud**, binaire géré
> par **systemd**, à côté du cluster K8s, storage **Raft** intégré, **TLS** avec
> CA interne, unseal **Shamir manuel**. Ce n'est pas la cible idéale (3 nœuds /
> auto-unseal KMS / cert-manager) mais la config applicable telle quelle sur un
> nœud unique de type `serpent`, avec son SPOF assumé (cf. Test 8 du POC).

## Sommaire

- [Ce qui change par rapport au mode dev](#ce-qui-change-par-rapport-au-mode-dev)
- [Contexte](#contexte)
- **0.** [Point de départ (ce qui doit déjà exister)](#0-point-de-départ-ce-qui-doit-déjà-exister)
- **Prérequis** — [nettoyer l'ancien binaire du POC](#prérequis--nettoyer-lancien-binaire-du-poc)
- **1.** [Installer Vault via le dépôt APT (version épinglée)](#1-installer-vault-via-le-dépôt-apt-version-épinglée)
- **2.** [Certificat TLS (CA interne + certif serveur)](#2-certificat-tls-ca-interne--certif-serveur)
- **3.** [Configuration Vault (Raft + listener TLS)](#3-configuration-vault-raft--listener-tls)
- **4.** [Démarrer et initialiser](#4-démarrer-et-initialiser)
- **5.** [Unseal (le geste à répéter à chaque redémarrage)](#5-unseal-le-geste-à-répéter-à-chaque-redémarrage)
- **6.** [Rejouer la config du POC sur le Vault vierge](#6-rejouer-la-config-du-poc-sur-le-vault-vierge) — KV v2, auth k8s, policy, role
- **7.** [Rebrancher le VSO en HTTPS](#7-rebrancher-le-vso-en-https-le-seul-vrai-écart-avec-le-mode-dev)
- **8.** [Vérifier la chaîne complète](#8-vérifier-la-chaîne-complète) — + test de rotation
- **9.** [Gestion des clés](#9-gestion-des-clés--rekey-root-token-accès-admin) — rekey, rotate, root token, accès admin
- **10.** [Keycloak — fournisseur d'identité OIDC](#10-keycloak--fournisseur-didentité-oidc)
- **11.** [Auth OIDC côté Vault](#11-auth-oidc-côté-vault)
- **12.** [Teleport devant Vault (App Access)](#12-teleport-devant-vault-app-access)
- **13.** [Firewall — verrouiller l'accès direct](#13-firewall--verrouiller-laccès-direct)
- [Pièges rencontrés (retour d'expérience)](#pièges-rencontrés-retour-dexpérience) — + architecture finale
- [Checklist de l'état atteint](#checklist-de-létat-atteint)
- [Durcissements restants](#durcissements-restants-avant-vraie-prod)
- [Licence](#licence)

## Ce qui change par rapport au mode dev

| | Mode dev (POC) | Prod (cette doc) |
|---|---|---|
| Lancement | `vault server -dev` en foreground | binaire + **systemd** |
| Stockage | mémoire (volatile) | **Raft** sur disque, chiffré |
| Survie au reboot | non | oui |
| Écoute | HTTP `:8200` | **HTTPS** `:8200` (TLS) |
| Root token | fixe (`root`) | généré à l'init, à révoquer ensuite |
| Démarrage | déjà unsealed | **sealed** → unseal Shamir manuel |

Le seul écart qui impacte le VSO est le passage **HTTP → HTTPS** : il faut lui
donner la nouvelle adresse **et** le CA pour valider le certificat.

## Contexte

| | |
|---|---|
| IP VM | `192.168.10.179` |
| Vault (nouveau) | `https://192.168.10.179:8200` |
| Version | Vault **1.21.4** (branche LTS) |
| Storage | Raft — `/opt/vault/data` |
| TLS | CA interne — `/opt/vault/tls/` |
| Namespace applicatif | `poc` |
| VSO | déjà installé (chart 1.4.1), à rebrancher |

> **Note version.** Depuis avril 2026, HashiCorp a sorti **Vault 2.0** (modèle de
> versioning/support IBM après l'acquisition), d'où le saut de 1.21 à 2.0. Pour
> une prod à maintenir, on reste sur la **branche LTS 1.21.x** (support étendu,
> comportement stable, identique au POC). À noter : un *breaking change* récent
> pose la capability `cap_ipc_lock` au build — sans impact en binaire systemd,
> à surveiller uniquement pour un futur Vault-in-K8s.

---

## 0. Point de départ (ce qui doit déjà exister)

Cette doc **ne part pas de zéro absolu** : elle remplace un Vault `-dev` par un
Vault prod, puis ajoute Keycloak, Teleport et le firewall. Elle suppose que le
**POC ArgoCD + Vault de base tourne déjà**. Avant de commencer, tu dois avoir :

- un **cluster Kubernetes** fonctionnel (ici mono-nœud `orktk`) ;
- **ArgoCD** installé, avec l'**Application POC** (chart nginx + postgres) déployée ;
- le **Vault Secrets Operator (VSO)** installé (chart `hashicorp/vault-secrets-operator`) ;
- les **CRs VSO** appliqués (`vso-poc.yaml` : ServiceAccount `vso-poc`, `VaultAuth`,
  `VaultStaticSecret` pour nginx et postgres) ;
- le **SA `vault-reviewer`** dans le namespace `vault-auth` + son
  ClusterRoleBinding `system:auth-delegator` (le token reviewer, pour l'auth
  kubernetes de Vault hors cluster).

> **Si tu pars d'une machine vierge**, ces éléments sont montés dans le **README
> du POC ArgoCD + Vault** (l'autre doc). Fais-le d'abord jusqu'à avoir un Vault
> `-dev` + VSO fonctionnels, puis reviens ici pour passer en prod. Les sections
> qui réutilisent l'existant sont : §6.2 (SA `vault-reviewer`), §7 (VSO à
> rebrancher).

**Ordre des grandes étapes** (important — l'IdP avant le proxy) :
Vault prod (§1-8) → gestion des clés (§9) → **Keycloak IdP (§10)** →
**auth OIDC Vault (§11)** → **Teleport devant (§12)** → **firewall (§13)**.
Keycloak doit exister **avant** de configurer l'OIDC de Vault, et l'OIDC doit
marcher **avant** d'ajouter Teleport (débugger les deux en même temps = pénible).

---

## Prérequis — nettoyer l'ancien binaire du POC

Le POC avait installé Vault via un **zip** dans `/usr/local/bin/vault`. Ce binaire
masque le paquet APT (il est prioritaire dans le `PATH`). Le supprimer d'abord,
sinon `vault version` continue de renvoyer l'ancienne version.

```bash
which -a vault
# /usr/local/bin/vault   ← le zip du POC (à virer)
# /usr/bin/vault         ← le paquet (à garder)

sudo rm /usr/local/bin/vault
hash -r                  # vide le cache de chemin du shell
```

Vérifier aussi le port : l'ancien `vault -dev` ne doit plus tourner.

```bash
sudo ss -ltnp | grep -E ':8200|:8201'   # doit être vide
```

---

## 1. Installer Vault via le dépôt APT (version épinglée)

Le dépôt APT est préférable au zip en prod : user système `vault`, unit systemd,
et mises à jour gérées.

```bash
sudo apt-get update && sudo apt-get install -y gpg wget lsb-release

wget -O- https://apt.releases.hashicorp.com/gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list

sudo apt-get update
```

Lister les versions 1.21 disponibles, puis installer la dernière en l'épinglant :

```bash
apt-cache madison vault | grep '1.21'
# vault | 1.21.4-1 | ... jammy/main amd64 Packages   ← la plus récente LTS

sudo apt-get install -y --allow-downgrades vault=1.21.4-1
sudo apt-mark hold vault        # gèle la version (pas de saut en 2.x sur apt upgrade)

vault version                   # → Vault v1.21.4
which vault                     # → /usr/bin/vault
apt-mark showhold               # → vault
```

Le paquet crée l'utilisateur système `vault`, le dossier `/etc/vault.d/`, le
dossier `/opt/vault/`, et l'unit systemd `vault.service` (qui pointe déjà sur
`/etc/vault.d/vault.hcl` et porte la capability `CAP_IPC_LOCK` pour mlock).

---

## 2. Certificat TLS (CA interne + certif serveur)

Vault écoute en HTTPS. On crée une **CA interne** et un **certificat serveur**
dont les SAN couvrent l'IP de la VM (indispensable : c'est par l'IP que le VSO et
le CLI joignent Vault).

```bash
sudo mkdir -p /opt/vault/tls
cd /tmp

# --- CA interne ---
openssl genrsa -out vault-ca.key 4096
openssl req -x509 -new -nodes -key vault-ca.key -sha256 -days 3650 \
  -out vault-ca.crt -subj "/CN=Vault Internal CA"

# --- Certif serveur avec SAN sur IP + localhost ---
cat > vault.cnf <<'EOF'
[req]
distinguished_name = dn
req_extensions = v3_req
prompt = no
[dn]
CN = vault.orktk.local
[v3_req]
subjectAltName = @alt
[alt]
IP.1  = 192.168.10.179
IP.2  = 127.0.0.1
DNS.1 = localhost
EOF

openssl genrsa -out vault.key 4096
openssl req -new -key vault.key -out vault.csr -config vault.cnf
openssl x509 -req -in vault.csr -CA vault-ca.crt -CAkey vault-ca.key \
  -CAcreateserial -out vault.crt -days 825 -sha256 \
  -extensions v3_req -extfile vault.cnf

# --- Installer + permissions ---
sudo cp vault.crt vault.key vault-ca.crt /opt/vault/tls/
sudo chown -R vault:vault /opt/vault/tls
sudo chmod 640 /opt/vault/tls/vault.key
sudo chmod 644 /opt/vault/tls/vault.crt /opt/vault/tls/vault-ca.crt

# Vérifier les SAN (l'IP DOIT y figurer)
sudo openssl x509 -in /opt/vault/tls/vault.crt -noout -text | grep -A1 "Subject Alternative Name"
# X509v3 Subject Alternative Name:
#     IP Address:192.168.10.179, IP Address:127.0.0.1, DNS:localhost
```

> Le CN `vault.orktk.local` est cosmétique (jamais résolu par un DNS public) ; seul
> le SAN sur l'IP compte fonctionnellement. Le certif serveur dure **825 jours**
> (max navigateur), la CA **10 ans** — à renouveler avant échéance, au même titre
> que le token reviewer.

---

## 3. Configuration Vault (Raft + listener TLS)

Remplacer le fichier par défaut `/etc/vault.d/vault.hcl` :

```bash
sudo tee /etc/vault.d/vault.hcl > /dev/null <<'EOF'
ui = true

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "vault-1"
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/opt/vault/tls/vault.crt"
  tls_key_file  = "/opt/vault/tls/vault.key"
}

api_addr     = "https://192.168.10.179:8200"
cluster_addr = "https://192.168.10.179:8201"

disable_mlock = false
EOF

sudo mkdir -p /opt/vault/data
sudo chown -R vault:vault /opt/vault/data /etc/vault.d
sudo chmod 640 /etc/vault.d/vault.hcl
```

Vérifier que l'unit systemd fournie pointe bien sur ce fichier et porte la
capability mlock (rien à réécrire côté systemd) :

```bash
systemctl cat vault | grep -E 'ExecStart|Capabilit|vault.hcl'
# ConditionFileNotEmpty=/etc/vault.d/vault.hcl
# AmbientCapabilities=CAP_IPC_LOCK
# ExecStart=/usr/bin/vault server -config=/etc/vault.d/vault.hcl
```

- **Raft** : storage intégré chiffré, pas besoin de Consul. `node_id` unique suffit en mono-nœud.
- **`disable_mlock = false`** : Vault verrouille sa mémoire (jamais de swap des secrets). La capability est fournie par l'unit ; si erreur `mlock` au boot, c'est la piste.
- **`api_addr`/`cluster_addr`** en `https://` : nécessaire pour que Vault s'annonce correctement.

---

## 4. Démarrer et initialiser

```bash
sudo systemctl enable --now vault
sudo systemctl status vault --no-pager        # → active (running)
```

Pointer le CLI sur Vault en TLS. Le CA n'étant lisible que par `vault`, en copier
une version dans le home pour l'usage CLI (le CA est public, pas sensible) :

```bash
sudo cp /opt/vault/tls/vault-ca.crt ~/vault-ca.crt
sudo chown "$USER":"$USER" ~/vault-ca.crt

export VAULT_ADDR="https://192.168.10.179:8200"
export VAULT_CACERT="$HOME/vault-ca.crt"

vault status
# Initialized  false
# Sealed       true            ← état attendu avant init
```

> **Bruit normal.** Tant que le VSO n'est pas rebranché, les logs Vault montrent
> des `TLS handshake error ... client sent an HTTP request to an HTTPS server`
> depuis une IP `10.10.43.x` : c'est le VSO qui tape encore en HTTP. Corrigé à
> l'étape 7.

**Initialisation — les 5 clés Shamir + le root token sortent ici, une seule fois :**

```bash
vault operator init -key-shares=5 -key-threshold=3
```

> ⚠️ **Copier immédiatement** les 5 Unseal Keys **et** le Initial Root Token dans
> un gestionnaire de secrets / coffre. Sans au moins **3 des 5** clés, Vault est
> définitivement scellé. Sans root token, plus d'administration. **Jamais dans
> Git ni dans cette doc.** En vraie prod, les 5 clés se distribuent à 5
> détenteurs distincts.

### Rappel du mécanisme Shamir

Les données Vault sont chiffrées sur disque par une **root key**, jamais stockée
en clair. Au démarrage Vault est **sealed** : il ne peut pas lire ses données.
L'**unseal** reconstruit la root key à partir des clés Shamir. Le découpage 5/3
signifie : root key scindée en 5 parts, **3 quelconques** suffisent à la
reconstruire, **2 ou moins** ne révèlent rien.

---

## 5. Unseal (le geste à répéter à chaque redémarrage)

```bash
vault operator unseal    # colle Unseal Key 1  → Progress 1/3
vault operator unseal    # colle Unseal Key 2  → Progress 2/3
vault operator unseal    # colle Unseal Key 3  → Sealed devient false

vault status             # → Sealed false, Initialized true, HA Mode active
vault login              # colle le Initial Root Token
```

> **À reproduire à chaque reboot / restart du service.** Sans KMS d'auto-unseal
> (indisponible ici), Vault repart **sealed** à chaque redémarrage : l'API répond
> `503 sealed`, le VSO ne peut plus sync tant que 3 clés n'ont pas été fournies.
> C'est le compromis assumé du mono-nœud sans KMS. Un script d'unseal peut
> automatiser la saisie (à sécuriser fortement).

---

## 6. Rejouer la config du POC sur le Vault vierge

Le nouveau Vault est vide : ni KV, ni auth, ni policy. On rejoue la config du POC
(identique, seul le transport passe en HTTPS). Vérifier les variables d'env :

```bash
export VAULT_ADDR="https://192.168.10.179:8200"
export VAULT_CACERT="$HOME/vault-ca.crt"
```

### 6.1 — KV v2 + secrets

```bash
vault secrets enable -path=kv kv-v2

vault kv put kv/poc/preprod/nginx \
  APP_SECRET="mon-super-secret-applicatif" \
  DATABASE_URL="postgres://pocuser:Vault-P0stgres-2026@poc-postgres:5432/pocdb" \
  DOCKERHUB_TOKEN="dckr_pat_exemple_token_12345"

vault kv put kv/poc/preprod/postgres \
  POSTGRES_PASSWORD="Vault-P0stgres-2026" \
  POSTGRES_USER="pocuser" \
  POSTGRES_DB="pocdb"

vault kv list kv/poc/preprod        # → nginx, postgres
```

### 6.2 — Auth Kubernetes

Le SA `vault-reviewer`, son ClusterRoleBinding et le namespace `vault-auth`
**survivent** au changement de Vault (ils sont dans etcd, pas dans Vault). Seul le
token reviewer est à régénérer.

```bash
vault auth enable kubernetes

kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d > /tmp/k8s-ca.crt

K8S_HOST=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
echo "$K8S_HOST"     # si 127.0.0.1 → forcer l'IP réelle :
# K8S_HOST="https://192.168.10.179:6443"

# SA reviewer déjà présent depuis le POC — on vérifie et on régénère un JWT
kubectl get sa vault-reviewer -n vault-auth
kubectl get clusterrolebinding vault-reviewer-binding
REVIEWER_JWT=$(kubectl create token vault-reviewer -n vault-auth --duration=8760h)
```

Configurer l'auth method (Vault hors cluster → `token_reviewer_jwt` obligatoire) :

```bash
vault write auth/kubernetes/config \
  kubernetes_host="$K8S_HOST" \
  kubernetes_ca_cert=@/tmp/k8s-ca.crt \
  token_reviewer_jwt="$REVIEWER_JWT" \
  disable_local_ca_jwt=true

vault read auth/kubernetes/config | grep -E 'token_reviewer_jwt_set|disable_local_ca_jwt'
# token_reviewer_jwt_set   true
# disable_local_ca_jwt     true
```

### 6.3 — Policy + role

```bash
vault policy write poc - <<'EOF'
path "kv/data/poc/preprod/*" {
  capabilities = ["read"]
}
EOF

vault write auth/kubernetes/role/poc \
  bound_service_account_names=vso-poc \
  bound_service_account_namespaces=poc \
  policies=poc \
  ttl=1h
```

> Rappels du POC : chemin API en **`kv/data/...`** (KV v2), pas de `list` (moindre
> privilège), warning `audience` bénin. Le wildcard rend la policy réplicable.

---

## 7. Rebrancher le VSO en HTTPS *(le seul vrai écart avec le mode dev)*

En mode dev le VSO parlait en HTTP. Maintenant il doit : (1) connaître la nouvelle
adresse `https://`, (2) valider le certif TLS via le CA. Sans le CA, il échoue en
`x509: certificate signed by unknown authority`.

### 7.1 — Pousser le CA dans le namespace du VSO

```bash
kubectl create secret generic vault-ca \
  -n vault-secrets-operator \
  --from-file=ca.crt="$HOME/vault-ca.crt"

# Le chart VSO 1.4.1 attend la clé "ca.crt" — vérifier :
kubectl get secret vault-ca -n vault-secrets-operator -o jsonpath='{.data}' | jq 'keys'
# ["ca.crt"]
```

### 7.2 — Passer l'adresse en HTTPS via Helm

```bash
helm upgrade vault-secrets-operator hashicorp/vault-secrets-operator \
  -n vault-secrets-operator \
  --reuse-values \
  --set defaultVaultConnection.address=https://192.168.10.179:8200 \
  --set defaultVaultConnection.caCertSecretRef=vault-ca
```

> ⚠️ **Piège rencontré.** Avec `--reuse-values`, le `--set caCertSecretRef` **n'a
> pas été propagé** jusqu'au `VaultConnection` (seule l'adresse a basculé). Le CR
> passait alors de « HTTP sur serveur HTTPS » à `x509: unknown authority` — donc
> HTTPS OK mais CA absent. Voir le patch ci-dessous.

### 7.3 — Patcher le VaultConnection pour ajouter le CA

```bash
# Vérifier l'état : address https OK mais pas de caCertSecretRef
kubectl get vaultconnection default -n vault-secrets-operator -o jsonpath='{.spec}' | jq

kubectl patch vaultconnection default -n vault-secrets-operator \
  --type merge \
  -p '{"spec":{"caCertSecretRef":"vault-ca"}}'

kubectl get vaultconnection default -n vault-secrets-operator -w
# HEALTHY True / READY True   ← en quelques secondes
```

> Le `VaultConnection` est managé par Helm : ce patch direct sera écrasé au
> prochain `helm upgrade` si la valeur n'est pas aussi portée dans les values du
> chart. Pour une prod pérenne, fixer `caCertSecretRef` dans un `values.yaml`
> versionné plutôt qu'en `--set`.

---

## 8. Vérifier la chaîne complète

```bash
# Les CR doivent être SYNCED
kubectl get vaultstaticsecret -n poc
# poc-nginx      True   True   True
# poc-postgres   True   True   True

# Events : on doit voir SecretSynced récent
kubectl describe vaultstaticsecret poc-nginx -n poc | tail -15

# La valeur remonte-t-elle depuis le NOUVEAU Vault ?
kubectl get secret poc-nginx -n poc -o jsonpath='{.data.APP_SECRET}' | base64 -d; echo
# mon-super-secret-applicatif

# Logs Vault propres (plus d'erreur TLS)
sudo journalctl -u vault --since "1 minute ago" --no-pager | tail
```

> **Nettoyage d'orphelins.** Un ancien `VaultStaticSecret` (ex. `poc-secrets`
> pointant sur le dossier `poc/preprod` — qui n'est pas un secret lisible)
> reste `SYNCED False` et boucle en erreur TLS, polluant les logs Vault. Vérifier
> son path et le supprimer :
>
> ```bash
> kubectl get vaultstaticsecret poc-secrets -n poc -o jsonpath='{.spec.path}'; echo
> kubectl delete vaultstaticsecret poc-secrets -n poc   # si orphelin confirmé
> ```

### Test de rotation (bout en bout)

```bash
vault kv put kv/poc/preprod/nginx \
  APP_SECRET="rotation-vault-prod-$(date +%H%M%S)" \
  DATABASE_URL="postgres://pocuser:Vault-P0stgres-2026@poc-postgres:5432/pocdb" \
  DOCKERHUB_TOKEN="dckr_pat_exemple_token_12345"

# ~30s (refreshAfter) puis :
kubectl exec -n poc deploy/poc-nginx -- env | grep APP_SECRET
# APP_SECRET=rotation-vault-prod-HHMMSS   ← propagé sans commit, sans sync ArgoCD
```

---

## 9. Gestion des clés — rekey, root token, accès admin

Trois secrets distincts sortent de l'`init`, à ne jamais confondre :

| Secret | Rôle | Régénération |
|---|---|---|
| **Unseal keys** (5, seuil 3) | reconstruisent la clé qui déchiffre la **root key** → desceller Vault | `vault operator rekey` |
| **Root key** (interne) | chiffre/déchiffre toutes les données ; jamais exposée en clair | `vault operator rotate` |
| **Root token** | s'authentifier pour administrer Vault | `vault operator generate-root` |

Les unseal keys et la root key sont **découplées** : c'est ce qui permet de changer
les unseal keys **sans re-chiffrer les données**, et inversement.

### 9.1 — Rekey : régénérer les unseal keys

À faire si les unseal keys ont fuité (ex. collées en clair quelque part), ou en
rotation périodique. Génère un **nouveau jeu**, invalide l'ancien, **données
intactes**. Nécessite le quorum actuel (3 des clés en cours) pour être autorisé.

```bash
# Le shell doit être authentifié (token valide) en plus des clés
vault token lookup | grep policies      # → [root] (ou une policy admin)

# Démarrer l'opération → note le Nonce renvoyé
vault operator rekey -init -key-shares=5 -key-threshold=3

# Fournir 3 clés ACTUELLES, une par commande, avec le nonce
vault operator rekey -nonce=<NONCE> <unseal-key-actuelle-1>
vault operator rekey -nonce=<NONCE> <unseal-key-actuelle-2>
vault operator rekey -nonce=<NONCE> <unseal-key-actuelle-3>
# → à la 3e, Vault affiche les NOUVELLES unseal keys
```

> ⚠️ Stocker les nouvelles clés dans un gestionnaire de secrets **sans les coller
> ailleurs** (chat, Git, ticket). Les anciennes sont mortes dès la fin du rekey :
> au prochain reboot, l'unseal se fait avec les nouvelles.

### 9.2 — Rotate : renouveler la clé de chiffrement des données

Rotation de sécurité de la clé de chiffrement (keyring). Nouvelle version de clé
pour les écritures **futures** ; les anciennes données restent lisibles (Vault
garde toutes les versions précédentes dans son *keyring* et sait quelle version
déchiffre quoi). **Aucune préparation, aucune cérémonie** :

```bash
vault operator rotate
```

- **Aucune interruption** : opération en ligne, instantanée, le VSO ne voit rien.
- **Aucun unseal à refaire** : les unseal keys ne changent pas (ça, c'est le
  `rekey`, §9.1).
- **Rien à redistribuer** : aucune clé ne sort de cette commande, tout est interne.
- **Prérequis unique** : un token avec les droits sur `sys/rotate` (en pratique,
  la session admin `generate-root`, §9.3).
- **Backups** : les snapshots Raft embarquent le keyring — un backup pris *avant*
  le rotate reste restaurable tel quel.

Vault fait aussi de la **rotation automatique** de cette clé selon une politique
configurable (par défaut : environ tous les 3,8 millions d'opérations de
chiffrement) :

```bash
vault read sys/rotate/config        # voir la politique actuelle
vault write sys/rotate/config max_operations=1000000 interval=720h
# exemple : rotation aussi tous les 30 jours en plus du seuil d'opérations
```

> Ne pas confondre les trois opérations : `rotate` = clé de chiffrement des
> données ; `rekey` (§9.1) = unseal keys ; `generate-root` (§9.3) = root token.

### 9.3 — Accès admin : OIDC via Keycloak (nominal) + generate-root (secours)

Principe retenu : **zéro identifiant humain permanent dans Vault**. Ni compte
local (`userpass`), ni root token qui traîne. Le VSO n'utilise **jamais** de token
humain — il s'authentifie via l'auth kubernetes avec son role `poc` (plan de
données, indépendant du plan admin).

Pour l'accès humain à l'UI/API, la solution standard est l'**OIDC** : Vault
délègue l'authentification à un fournisseur d'identité (IdP). Sans annuaire
d'entreprise existant, l'IdP open-source de référence est **Keycloak** :

- L'UI Vault propose la méthode « OIDC » → redirection vers Keycloak → login
  (avec MFA géré par Keycloak) → retour dans Vault **authentifié, sans token
  Vault à saisir**.
- Vault mappe les groupes Keycloak → policies Vault. Aucun compte, aucun mot de
  passe stocké dans Vault.
- Un départ = désactivation du compte Keycloak = accès Vault coupé.

> **Note.** Teleport (Community) ne peut pas jouer ce rôle : il n'est pas
> fournisseur OIDC pour des applications tierces. Teleport App Access route
> l'accès réseau vers Vault (nominatif + MFA + audit de session côté Teleport),
> mais l'UI Vault redemande sa propre authentification — d'où le besoin d'un IdP
> OIDC dédié pour le SSO applicatif.

| | Accès admin nominal | Accès de secours |
|---|---|---|
| Comment | UI Vault → bouton OIDC → login Keycloak | `generate-root` + 3 unseal keys |
| Identité | compte Keycloak (nominatif, MFA) | root anonyme régénéré |
| Compte dans Vault | aucun | aucun |
| Quand | au quotidien | uniquement si l'IdP est indisponible |

**Clôture après bootstrap** — une fois KV, auth k8s, policy et role en place et le
VSO `HEALTHY True`, on révoque le root token d'init (plus aucun accès admin ne
traîne ; l'accès nominal passera par OIDC) :

```bash
# Vérifier que le VSO tourne SANS root (auth kubernetes autonome)
kubectl get vaultconnection default -n vault-secrets-operator   # HEALTHY True
kubectl get vaultstaticsecret -n poc                            # SYNCED True

# Révoquer le root token courant
vault token revoke -self

# Vérifier qu'il est bien mort
vault token lookup            # → permission denied  (résultat attendu)
```

Le VSO continue de servir les secrets (plan de données) alors que le plan de
contrôle (admin) est coupé.

**Accès de secours — generate-root** (si l'IdP est down, ou avant sa mise en
place) : régénérer un root token temporaire avec 3 unseal keys, faire l'admin, le
re-révoquer :

```bash
vault operator generate-root -init                       # → OTP + Nonce
vault operator generate-root -nonce=<NONCE> <unseal-key-1>
vault operator generate-root -nonce=<NONCE> <unseal-key-2>
vault operator generate-root -nonce=<NONCE> <unseal-key-3>
vault operator generate-root -decode=<ENCODED_TOKEN> -otp=<OTP>
# → token en clair

vault login <le-token>
# ... admin (ex. vault kv get kv/poc/preprod/nginx) ...
vault token revoke -self                                 # tuer le token en fin de session
```

> **Sécurité du secours.** Les unseal keys deviennent *le* secret suprême : garde
> irréprochable (réparties entre plusieurs personnes, hors-ligne). Si chaque clé
> est détenue par une personne différente, l'accès de secours devient une action
> **collective** (3 personnes réunies). L'audit du root régénéré voit « un root a
> fait X », pas « qui » — le **nominatif** vient de l'OIDC pour l'accès quotidien.

> **Rappel unseal vs re-seal.** Desceller n'est pas « ouvrir puis refermer » :
> Vault **reste unsealed** en fonctionnement normal, les données restent chiffrées
> sur disque en permanence (rien à re-chiffrer). Le re-seal (`vault operator seal`)
> est une action d'urgence ; il se produit aussi automatiquement à chaque
> arrêt/reboot du service, d'où l'unseal manuel au redémarrage (§5).

---

## 10. Keycloak — fournisseur d'identité OIDC

Objectif : accès humain nominatif à Vault **sans compte ni token Vault**. Vault
délègue l'authentification à Keycloak (IdP OIDC). Un seul annuaire central, MFA
possible, révocation immédiate en désactivant le compte Keycloak.

> **Ordre.** Keycloak (§10) et l'auth OIDC Vault (§11) se font **avant** Teleport
> (§12) : l'IdP doit exister et le SSO doit fonctionner en accès direct avant
> d'ajouter le proxy par-dessus. Le firewall (§13) vient en dernier, une fois les
> deux chemins (direct + Teleport) validés.

### 10.1 — Déploiement (mode prod : PostgreSQL + `start`)

Keycloak est une app Java **stateless** : tout l'état (realms, users, clients)
vit dans PostgreSQL. Le pod peut mourir sans perte. Manifeste `keycloak.yaml`
(namespace `keycloak`, Postgres + Keycloak, NodePort `30808`) :

```yaml
apiVersion: v1
kind: Namespace
metadata: {name: keycloak}
---
apiVersion: v1
kind: Secret
metadata: {name: keycloak-db, namespace: keycloak}
type: Opaque
stringData:
  POSTGRES_DB: keycloak
  POSTGRES_USER: keycloak
  POSTGRES_PASSWORD: "Kc-P0stgres-2026"
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: keycloak-db, namespace: keycloak}
spec:
  replicas: 1
  selector: {matchLabels: {app: keycloak-db}}
  template:
    metadata: {labels: {app: keycloak-db}}
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          envFrom: [{secretRef: {name: keycloak-db}}]
          ports: [{containerPort: 5432}]
          volumeMounts: [{name: pgdata, mountPath: /var/lib/postgresql/data}]
      volumes:
        - name: pgdata
          hostPath: {path: /opt/keycloak-pgdata, type: DirectoryOrCreate}
---
apiVersion: v1
kind: Service
metadata: {name: keycloak-db, namespace: keycloak}
spec:
  selector: {app: keycloak-db}
  ports: [{port: 5432}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: keycloak, namespace: keycloak}
spec:
  replicas: 1
  selector: {matchLabels: {app: keycloak}}
  template:
    metadata: {labels: {app: keycloak}}
    spec:
      containers:
        - name: keycloak
          image: quay.io/keycloak/keycloak:26.7
          args: ["start"]
          env:
            - {name: KC_DB, value: postgres}
            - {name: KC_DB_URL, value: "jdbc:postgresql://keycloak-db:5432/keycloak"}
            - {name: KC_DB_USERNAME, valueFrom: {secretKeyRef: {name: keycloak-db, key: POSTGRES_USER}}}
            - {name: KC_DB_PASSWORD, valueFrom: {secretKeyRef: {name: keycloak-db, key: POSTGRES_PASSWORD}}}
            - {name: KC_HOSTNAME, value: "http://192.168.10.179:30808"}
            - {name: KC_HTTP_ENABLED, value: "true"}
            - {name: KC_BOOTSTRAP_ADMIN_USERNAME, value: "admin"}
            - {name: KC_BOOTSTRAP_ADMIN_PASSWORD, value: "ChangeMe-Keycloak-2026"}
          ports: [{containerPort: 8080}]
---
apiVersion: v1
kind: Service
metadata: {name: keycloak, namespace: keycloak}
spec:
  type: NodePort
  selector: {app: keycloak}
  ports: [{port: 8080, targetPort: 8080, nodePort: 30808}]
```

```bash
kubectl apply -f keycloak.yaml
kubectl get pods -n keycloak -w        # keycloak-db puis keycloak → Running
```

Console admin : `http://192.168.10.179:30808` (login `admin` / mot de passe du YAML).

Notes prod :
- `KC_DB` + `KC_DB_URL` + credentials : **PostgreSQL obligatoire** en mode `start`
  (H2 n'est pas supporté). C'est ce qui change du `start-dev`.
- `KC_HOSTNAME` **obligatoire** : Keycloak prod refuse de deviner son URL.
- `KC_HTTP_ENABLED=true` : HTTP assumé pour le POC réseau interne. En vraie prod,
  TLS via ingress/reverse-proxy devant.
- `KC_BOOTSTRAP_ADMIN_*` : compte admin **temporaire** (les anciennes variables
  `KEYCLOAK_ADMIN` sont dépréciées depuis la 26). Créer un vrai admin ensuite.

### 10.2 — Realm, groupe, utilisateur

Tout dans l'UI Keycloak. **Vérifier le sélecteur de realm en haut à gauche à
chaque étape** — créer quoi que ce soit dans `master` par erreur = invisible pour
Vault.

1. **Create realm** → nom `infra`. (Le realm `master` sert uniquement à
   administrer Keycloak ; les identités métier vont dans un realm dédié.)
2. **Groups → Create group** → `vault-admins`.
3. **Users → Create new user** → username `victor`, l'ajouter au groupe
   `vault-admins`. Puis **Credentials → Set password**, **Temporary : Off**.
   Renseigner email/prénom/nom (sinon Keycloak réclame un « Update Account
   Information » au premier login).

### 10.3 — Client OIDC `vault`

**Clients → Create client** :
- *General* : type `OpenID Connect`, Client ID `vault`.
- *Capability config* : **Client authentication : ON** (client confidentiel avec
  secret), Standard flow coché.
- *Login settings* → **Valid redirect URIs** (le SEUL champ qui compte —
  laisser Root/Home/Admin URL VIDES) :
  ```
  https://192.168.10.179:8200/ui/vault/auth/oidc/oidc/callback
  https://vault.teleport.local/ui/vault/auth/oidc/oidc/callback
  http://localhost:8250/oidc/callback
  ```
  **Web origins** :
  ```
  https://192.168.10.179:8200
  https://vault.teleport.local
  ```

> La ligne `vault.teleport.local` est ce qui permet le login **via Teleport**
> (§12). Elle doit être présente **des deux côtés** : ici (client Keycloak) ET
> dans le role Vault (`allowed_redirect_uris`, §11) — les deux listes doivent
> rester cohérentes. Avec un vrai domaine, c'est ce nom qu'on remplace (§12.1).
>
> ℹ️ **`vault.teleport.local` d'où ça sort ?** C'est le nom du proxy Teleport,
> qu'on a **inscrit dans `/etc/hosts`** faute de vrai domaine. Avec un vrai
> domaine, on ferait pareil mais sans `/etc/hosts` (résolution par le DNS). Détail
> complet et liste des endroits à changer : encadré du §12.1.

Récupérer le secret : onglet **Credentials → Client Secret** (regénérable à tout
moment).

**Mapper les groupes dans le token** (sinon Vault ne voit pas `vault-admins`) :
- Client `vault` → **Client scopes** → `vault-dedicated` → **Configure a new
  mapper** → **Group Membership**.
- Name `groups`, Token Claim Name `groups`, **Full group path : OFF** (sinon le
  claim vaut `/vault-admins` avec un slash et le mapping Vault échoue), Add to
  ID/access/userinfo token : ON.

---

## 11. Auth OIDC côté Vault

Nécessite un token admin (session `generate-root`, §9.3).

**Vérifier d'abord que Vault peut joindre le realm Keycloak** — l'OIDC échoue en
silence si l'URL de découverte n'est pas atteignable depuis la VM Vault :

```bash
curl -s http://192.168.10.179:30808/realms/infra/.well-known/openid-configuration | head -c 200
# → doit renvoyer du JSON (issuer, authorization_endpoint, ...)
```

Si ça ne répond pas : Keycloak n'est pas up, ou le realm n'est pas `infra`, ou
un firewall bloque le `30808`.

```bash
export VAULT_ADDR="https://192.168.10.179:8200"
export VAULT_CACERT="$HOME/vault-ca.crt"

# Nettoyage : retirer le reliquat auth/jwt (fausse piste Teleport-JWT), s'il existe
vault auth disable jwt 2>/dev/null || true

vault auth enable oidc

vault write auth/oidc/config \
  oidc_discovery_url="http://192.168.10.179:30808/realms/infra" \
  oidc_client_id="vault" \
  oidc_client_secret="<CLIENT_SECRET>" \
  default_role="admin"
```

Policy admin + role (mapping groupe Keycloak → policy). **Le role doit être écrit
via un payload JSON sur stdin** — les types map/liste passent mal en `K=V` inline :

```bash
vault policy write admin - <<'EOF'
path "*" { capabilities = ["create","read","update","delete","list","sudo"] }
EOF

vault write auth/oidc/role/admin - <<'EOF'
{
  "user_claim": "preferred_username",
  "groups_claim": "groups",
  "bound_audiences": "vault",
  "allowed_redirect_uris": [
    "https://192.168.10.179:8200/ui/vault/auth/oidc/oidc/callback",
    "https://vault.teleport.local/ui/vault/auth/oidc/oidc/callback",
    "http://localhost:8250/oidc/callback"
  ],
  "bound_claims": { "groups": ["vault-admins"] },
  "policies": "admin",
  "ttl": "1h"
}
EOF
```

Cœur du montage : `bound_claims.groups=["vault-admins"]` → seuls les utilisateurs
dont le token porte ce groupe obtiennent la policy `admin`. Les autres sont
rejetés.

**Test** : UI Vault → Method **OIDC** → Role `admin` → *Sign in with OIDC
Provider* → redirection Keycloak → login `victor` → retour dans Vault authentifié,
**sans token Vault saisi**.

---

## 12. Teleport devant Vault (App Access)

Teleport (sur `192.168.10.91`) devient le **passage obligé** des humains vers
Vault : login + MFA + audit de session. Le VSO, lui, garde son accès réseau
direct (App Access est pour les humains, pas pour les machines).

### 12.0 — Prérequis

- Une **machine séparée** de Vault (ici `192.168.10.91`, Ubuntu), sur le même LAN,
  capable de joindre Vault en `192.168.10.179:8200`. Séparer le proxy de la
  ressource qu'il protège est volontaire.
- Accès `sudo` sur cette machine.
- **Ports libres** : `443` (UI/proxy web), `3023` (proxy SSH), `3024` (tunnel
  inverse), `3025` (auth). Vérifier :
  ```bash
  sudo ss -ltnp | grep -E ':443|:3023|:3024|:3025'   # doit être vide
  ```

**Choix de version.** On épingle une version précise (ici `17.7.23`). Pour
connaître la dernière stable :

```bash
curl -s https://api.github.com/repos/gravitational/teleport/releases/latest \
  | grep tag_name
```

Remplacer le numéro dans l'URL de téléchargement du §12.1 en conséquence.

### 12.1 — Installation + TLS

Teleport refuse une IP nue : il faut un nom + un **wildcard DNS** (chaque app est
servie sur un sous-domaine du proxy). En LAN sans DNS, on utilise `/etc/hosts` +
un certif auto-signé wildcard.

> **Choix de nommage (à relire si tu reviens dessus plus tard).**
> On n'avait **pas de vrai nom de domaine**, donc on a inscrit le nom générique
> `teleport.local` (et `vault.teleport.local`) **dans `/etc/hosts`** pour qu'il
> soit résolu, avec un **certif auto-signé** dont la CA est distribuée sur chaque
> poste client. Suffisant pour un POC/LAN interne.
>
> **Avec un vrai nom de domaine** (ex. `teleport.mondomaine.fr`), on fait
> exactement pareil, mais **sans `/etc/hosts`** : c'est le **DNS** qui résout le
> nom (une entrée + wildcard `*.teleport.mondomaine.fr`). Seul le nom change, aux
> **4 endroits** suivants — la procédure reste identique :
> 1. La résolution du nom : `/etc/hosts` → remplacé par une entrée DNS + wildcard.
> 2. Les **SAN du certif** (`tele.cnf` : `DNS.1`, `DNS.2` wildcard) — ou, avec un
>    domaine public + accès Internet, remplacer le certif auto-signé par
>    **Let's Encrypt** (plus besoin de distribuer la CA).
> 3. `/etc/teleport.yaml` : `cluster_name`, `public_addr`, et le `public_addr` de
>    l'app dans `app_service`.
> 4. Les **redirect URIs** côté Keycloak (client `vault`) et côté role Vault
>    (`allowed_redirect_uris`, §11).
>
> Tout le reste (install, config, firewall) ne bouge pas : seul le nom change.

```bash
# Binaire (l'archive pose binaire + unit systemd ; le script one-liner peut ne
# pas installer le binaire — vérifier `which teleport`)
cd /tmp
curl -Lo teleport.tar.gz https://cdn.teleport.dev/teleport-v17.7.23-linux-amd64-bin.tar.gz
tar -xzf teleport.tar.gz && cd teleport && sudo ./install

# /etc/hosts sur la machine Teleport ET chaque poste client
echo "192.168.10.91  teleport.local vault.teleport.local" | sudo tee -a /etc/hosts

# CA interne + certif avec wildcard *.teleport.local dans les SAN
sudo mkdir -p /etc/teleport/tls && cd /tmp
openssl genrsa -out tele-ca.key 4096
openssl req -x509 -new -nodes -key tele-ca.key -sha256 -days 3650 \
  -out tele-ca.crt -subj "/CN=Teleport POC CA"
cat > tele.cnf <<'EOF'
[req]
distinguished_name = dn
req_extensions = v3_req
prompt = no
[dn]
CN = teleport.local
[v3_req]
subjectAltName = @alt
[alt]
DNS.1 = teleport.local
DNS.2 = *.teleport.local
IP.1  = 192.168.10.91
EOF
openssl genrsa -out tele.key 4096
openssl req -new -key tele.key -out tele.csr -config tele.cnf
openssl x509 -req -in tele.csr -CA tele-ca.crt -CAkey tele-ca.key \
  -CAcreateserial -out tele.crt -days 825 -sha256 -extensions v3_req -extfile tele.cnf
sudo cp tele.crt tele.key tele-ca.crt /etc/teleport/tls/
sudo chmod 600 /etc/teleport/tls/tele.key

# Teleport exige que sa CA soit dans le trust store du système
sudo cp /etc/teleport/tls/tele-ca.crt /usr/local/share/ca-certificates/teleport-ca.crt
sudo update-ca-certificates
```

### 12.2 — Configuration `/etc/teleport.yaml`

```yaml
version: v3
teleport:
  nodename: teleport.local
  data_dir: /var/lib/teleport
auth_service:
  enabled: true
  cluster_name: teleport.local
  listen_addr: 0.0.0.0:3025
  tokens:
    - proxy,node,app:file:/var/lib/teleport/token
proxy_service:
  enabled: true
  web_listen_addr: 0.0.0.0:443
  tunnel_listen_addr: 0.0.0.0:3024      # tunnel inverse (sinon app_service KO)
  listen_addr: 0.0.0.0:3023             # proxy SSH (sinon `tsh login` KO)
  public_addr: teleport.local:443
  https_keypairs:
    - key_file: /etc/teleport/tls/tele.key
      cert_file: /etc/teleport/tls/tele.crt
ssh_service:
  enabled: false
app_service:
  enabled: true
  apps:
    - name: vault
      uri: "https://192.168.10.179:8200"
      public_addr: "vault.teleport.local"
      insecure_skip_verify: true        # certif Vault signé par CA interne
```

```bash
sudo /usr/local/bin/teleport install systemd -o /etc/systemd/system/teleport.service
sudo systemctl daemon-reload && sudo systemctl enable --now teleport
sudo ss -ltnp | grep -E ':443|:3023|:3024|:3025'   # les 4 doivent écouter
```

> **Si le service crashe en boucle** (`status=1/FAILURE`), regarder
> `sudo journalctl -u teleport | tail -20`. Cause classique :
> `x509: certificate signed by unknown authority` → la CA interne n'est pas dans
> le trust store. C'est ce que règle le `update-ca-certificates` du §12.1 ; si
> l'erreur persiste, vérifier que la copie de `tele-ca.crt` dans
> `/usr/local/share/ca-certificates/` a bien été suivie de `update-ca-certificates`,
> puis `sudo systemctl restart teleport`.

### 12.3 — Utilisateur Teleport + accès

Créer l'utilisateur (l'app `vault` est déjà déclarée dans `app_service`, §12.2 —
elle remonte automatiquement dès que le service tourne) :

```bash
sudo tctl users add victor --roles=access,editor --logins=root
# → ouvre l'URL d'invitation dans le navigateur : mot de passe + MFA (OTP)
```

**Vérifier que Vault remonte bien dans Teleport.** Se connecter en CLI et lister
les apps :

```bash
tsh login --proxy=teleport.local:443 --user=victor
tsh apps ls
# vault   HTTP   vault.teleport.local     ← doit apparaître
```

Prouver que le tunnel Teleport → Vault fonctionne (le `curl` traverse le proxy et
atteint Vault) :

```bash
tsh apps login vault
curl \
  --cert "$HOME/.tsh/keys/teleport.local/victor-app/teleport.local/vault.crt" \
  --key  "$HOME/.tsh/keys/teleport.local/victor-app/teleport.local/vault.key" \
  --cacert /etc/teleport/tls/tele-ca.crt \
  https://vault.teleport.local/v1/sys/health
# → JSON de santé de Vault ("version":"1.21.4", "sealed":false) obtenu VIA Teleport
```

> Si l'app n'apparaît pas ou le tunnel échoue avec `dial tcp 127.0.0.1:3024` /
> `192.168.10.91:3023 connection refused` : les listeners `tunnel_listen_addr`
> (3024) et `listen_addr` (3023) manquent dans `proxy_service` (§12.2). Les
> ajouter, `systemctl restart teleport`, vérifier avec `ss -ltnp`.

**Accès navigateur** : `https://vault.teleport.local`. Non connecté à Teleport →
**redirection vers le login Teleport** (barrière d'accès) → puis UI Vault → OIDC →
Keycloak. Les redirect URIs `https://vault.teleport.local/...` sont déjà au client
Keycloak (§10.3) et au role Vault (§11).

---

## 13. Firewall — verrouiller l'accès direct

Sans ça, Teleport n'est qu'un chemin *parmi d'autres* : le port 8200 reste
joignable en direct sur tout le LAN. On ferme 8200 sauf pour Teleport, le VSO
(réseau des pods) et la VM elle-même.

> ⚠️ Sur un nœud Kubernetes, activer `ufw` en deny-par-défaut **sans** autoriser
> d'abord SSH, l'API k8s et le réseau des pods coupe la VM et le cluster. Poser
> les `allow` vitaux AVANT `enable`, tester dans une nouvelle session SSH, et
> seulement ensuite ajouter les règles Vault.

```bash
# 1. Vital, AVANT d'activer (ufw inactive)
sudo ufw allow 22/tcp comment 'SSH'
sudo ufw allow 6443/tcp comment 'k8s API'
sudo ufw allow 10250/tcp comment 'kubelet'
sudo ufw allow 30000:32767/tcp comment 'NodePorts'
sudo ufw allow from 10.10.0.0/16 comment 'pods calico'   # CRITIQUE
sudo ufw allow from 127.0.0.1

# 2. Activer + VÉRIFIER dans une NOUVELLE session SSH + kubectl get nodes
sudo ufw enable

# 3. Règles Vault (allow AVANT deny — premier match gagne)
sudo ufw allow from 192.168.10.91 to any port 8200 proto tcp comment 'Vault via Teleport'
sudo ufw allow from 192.168.10.179 to any port 8200 proto tcp comment 'Vault local VM'
sudo ufw deny 8200/tcp comment 'Vault deny direct LAN'

sudo ufw status verbose        # les ALLOW 8200 doivent précéder le DENY 8200
```

Le VSO (pod `10.10.x.x`) passe par la règle `10.10.0.0/16` — on n'ajoute PAS de
règle 8200 dédiée aux pods, elle est déjà couverte.

**Validation :**
- VSO : rotation `vault kv put ...` → le secret se propage et le pod redémarre
  (prouve que le VSO joint Vault à travers le firewall).
- Accès direct **depuis un autre poste du LAN** : `curl -k --max-time 5
  https://192.168.10.179:8200/v1/sys/health` → **timeout/refus**. (Ne pas tester
  depuis la VM `.179`, elle est autorisée.)
- Accès via Teleport : `https://vault.teleport.local` → répond.

---

## Pièges rencontrés (retour d'expérience)

- **Binaire du POC masquant le paquet.** L'ancien `vault` en `/usr/local/bin`
  (zip) reste prioritaire dans le `PATH` et fait mentir `vault version`.
  `rm /usr/local/bin/vault && hash -r` avant tout.
- **`--reuse-values` + `--set` (Helm VSO).** Le `caCertSecretRef` n'a pas été
  propagé au `VaultConnection` — patch direct `kubectl patch vaultconnection`
  nécessaire (§7.3).
- **Orphelin VSO.** Un `VaultStaticSecret` pointant sur un dossier (`poc/preprod`,
  pas un secret) boucle en erreur TLS et pollue les logs Vault. Le supprimer.
- **Fausse piste JWT Teleport.** Teleport injecte bien un header
  `Teleport-Jwt-Assertion`, mais l'UI Vault ne le lit pas → pas de SSO. Et
  **Teleport Community n'est pas IdP OIDC** pour des apps tierces. La solution
  SSO est un IdP dédié : **Keycloak**. (Le `auth/jwt` activé pour tester est à
  retirer : `vault auth disable jwt`.)
- **Teleport refuse l'IP nue.** Nom + wildcard DNS obligatoires ; `/etc/hosts` ne
  gère pas les wildcards mais suffit en listant chaque nom.
- **CA Teleport hors trust store.** Le service crash en boucle
  (`x509: unknown authority`) tant que la CA n'est pas dans
  `/usr/local/share/ca-certificates` + `update-ca-certificates`.
- **Listeners de tunnel absents.** `app_service` KO sur `3024` et `tsh login` KO
  sur `3023` tant que `tunnel_listen_addr`/`listen_addr` ne sont pas déclarés.
- **Redirect URIs Keycloak dans les mauvais champs.** Elles vont dans **Valid
  redirect URIs**, PAS dans Root/Home/Admin URL. Double `/oidc/oidc/` voulu
  (mount path + méthode).
- **Mapper « groups » prédéfini trompeur.** Le mapper prédéfini `groups` mappe
  les *realm roles*, pas les groupes. Il faut créer un mapper **Group
  Membership** à la main, `Full group path: OFF`.
- **`bound_claims` en K=V.** `bound_claims='{...}'` inline → erreur `expected a
  map, got string`. Passer le role en JSON sur stdin (`vault write ... -`).
- **`SYNCED False` trompeur après firewall.** Le champ met du temps à se
  rafraîchir ; la rotation réelle (secret propagé + pod redémarré) prouve que la
  synchro a eu lieu. Se fier au comportement, pas au seul flag.

### Architecture finale

```
Humain → vault.teleport.local → [Teleport: login + MFA + audit]
       → UI Vault → OIDC → [Keycloak: SSO, realm infra, groupe vault-admins]
       → session Vault (policy admin)                    ← zéro token, zéro compte Vault

VSO (pod 10.10.x.x) → 192.168.10.179:8200 direct         ← autorisé par firewall (pods)
Reste du LAN → 8200 refusé                                ← firewall deny
Admin de secours → generate-root + 3 unseal keys         ← si IdP/Teleport down
```

---

## Checklist de l'état atteint

- [x] Vault **1.21.4 LTS**, binaire + systemd, `enable` au boot
- [x] Storage **Raft** mono-nœud, données persistées et chiffrées
- [x] **TLS** avec CA interne (SAN sur `192.168.10.179`)
- [x] Unseal **Shamir 5/3** (manuel au reboot)
- [x] KV v2 + auth kubernetes + policy `poc` + role rejoués
- [x] VSO rebranché en **HTTPS** avec validation CA — `HEALTHY True`
- [x] Rotation live vérifiée
- [x] Unseal keys **rekey** (anciennes invalidées)
- [x] Root token **révoqué** — accès admin via `generate-root` à la demande
- [x] **Keycloak** (IdP OIDC) déployé — realm `infra`, groupe `vault-admins`
- [x] **Auth OIDC** Vault — SSO nominatif, zéro token, zéro compte Vault
- [x] **Teleport** devant Vault — passage obligé, login + MFA + audit
- [x] **Firewall** — 8200 fermé au LAN sauf Teleport + VSO, VSO préservé

---

## Durcissements restants (avant vraie prod)

Repris du bilan POC, non couverts par cette mise en route :

- **Root token** : ✅ révoqué (§9.3). Accès nominal via **OIDC/Keycloak** (§10-11)
  derrière **Teleport** (§12) ; `generate-root` réservé au secours.
- **Nettoyer `auth/jwt`** : reliquat de la fausse piste Teleport-JWT, à retirer
  (`vault auth disable jwt`) lors d'une session admin.
- **Auto-unseal** : sans KMS, l'unseal reste manuel → tout reboot nécessite une
  intervention. Documenter la procédure de garde, ou envisager un KMS.
- **HA réelle** : mono-nœud = SPOF (cf. Test 8 — Vault down bloque les
  déploiements, pas le run). Passer à Raft 3 nœuds pour une prod critique.
- **Filtrage `_raw`** : `SecretTransformation` avec `excludes: ["_raw"]` sur
  chaque `VaultStaticSecret` (le `_raw` expose tous les secrets en une variable).
- **Backup** : snapshot Raft en cron (`vault operator raft snapshot save`) →
  GPG → stockage objet. Restauration testée au moins une fois.
- **Monitoring** : `/v1/sys/metrics`, alerte sur `vault_core_unsealed == 0`.
- **Audit** : `vault audit enable file` shippé vers ELK.
- **caCertSecretRef versionné** : porter la valeur dans un `values.yaml` plutôt
  qu'en `--set`, pour survivre aux `helm upgrade`.
- **Certificats** : le certif serveur (825 j) et le token reviewer (1 an) sont à
  renouveler avant échéance — à mettre sous alerte.

## Licence

Vault reste en BUSL 1.1 (usage interne OK). Pour un usage type revente de Vault
managé, basculer sur **OpenBao** (fork Linux Foundation, MPL 2.0, API-compatible,
VSO fonctionne dessus).