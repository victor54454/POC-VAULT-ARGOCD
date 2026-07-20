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
- **`api_addr`/`cluster_addr`** en `https://` : nécessaire pour que Vault s'annonce correctement (et pour Teleport ensuite).

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

Rotation de sécurité de la **root key** elle-même. Nouvelle version de clé pour les
écritures **futures** ; les anciennes données restent lisibles (Vault garde les
versions précédentes). Transparent, sans interruption.

```bash
vault operator rotate
```

### 9.3 — Accès admin : Teleport (nominal) + generate-root (secours)

**Deux niveaux d'authentification à ne pas confondre :**

- **Niveau 1 — l'humain s'authentifie auprès de Teleport.** C'est là que vit une
  identité (compte local Teleport avec login + MFA, ou SSO). Le mot de passe, s'il
  y en a un, est **côté Teleport, jamais côté Vault**.
- **Niveau 2 — Teleport prouve à Vault qui tu es.** Une fois authentifié, Teleport
  présente un **JWT signé** que Vault vérifie (auth method `jwt`). **Aucun compte,
  aucun mot de passe stocké dans Vault** — Vault ne connaît que la clé publique de
  Teleport.

Résultat : **zéro identifiant humain permanent dans Vault**, quel que soit le mode.
Le VSO, lui, n'utilise **jamais** de token humain — il s'authentifie via l'auth
kubernetes avec son role `poc` (plan de données, indépendant du plan admin).

| | Accès admin nominal | Accès de secours |
|---|---|---|
| Comment | se connecter à **Teleport** → UI/API Vault via JWT (§10) | `generate-root` + 3 unseal keys |
| Identité | compte Teleport (nominatif, MFA, session enregistrée) | root anonyme régénéré |
| Compte dans Vault | aucun | aucun |
| Quand | au quotidien | uniquement si Teleport est indisponible |

**Clôture après bootstrap** — une fois KV, auth k8s, policy et role en place et le
VSO `HEALTHY True`, on révoque le root token d'init (plus aucun accès admin ne
traîne ; l'accès nominal passera par Teleport, cf. §10) :

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

**Accès de secours — generate-root** (si Teleport est down, ou avant sa mise en
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
> fait X », pas « qui » — le **nominatif** est justement ce que Teleport apporte
> pour l'accès quotidien (§10).

> **Rappel unseal vs re-seal.** Desceller n'est pas « ouvrir puis refermer » :
> Vault **reste unsealed** en fonctionnement normal, les données restent chiffrées
> sur disque en permanence (rien à re-chiffrer). Le re-seal (`vault operator seal`)
> est une action d'urgence ; il se produit aussi automatiquement à chaque
> arrêt/reboot du service, d'où l'unseal manuel au redémarrage (§5).

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

---

## Durcissements restants (avant vraie prod)

Repris du bilan POC, non couverts par cette mise en route :

- **Root token** : ✅ révoqué (§9.3). Accès admin via `generate-root` à la demande.
  Pour du **nominatif** (savoir *qui* administre) sans monter d'annuaire → Teleport
  devant Vault, voir §10.
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