# Vault — Installation et gestion des utilisateurs (userpass + MFA)

Installation de HashiCorp Vault en production sur un nœud unique (binaire systemd,
storage Raft, TLS interne, unseal Shamir), puis création d'un compte utilisateur
local avec policy dédiée et MFA TOTP obligatoire.

## Contexte

| | |
|---|---|
| Adresse Vault | `https://<IP_VAULT>:8200` |
| Version | Vault 1.21.x (branche LTS) |
| Storage | Raft — `/opt/vault/data` |
| TLS | CA interne — `/opt/vault/tls/` |

Remplacer `<IP_VAULT>` par l'adresse IP de la machine Vault dans toutes les
commandes.

---

# Partie 1 — Installation de Vault

## 1. Installer Vault via le dépôt APT

```bash
sudo apt-get update && sudo apt-get install -y gpg wget lsb-release

wget -O- https://apt.releases.hashicorp.com/gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list

sudo apt-get update
```

Installer la dernière version 1.21 et l'épingler :

```bash
apt-cache madison vault | grep '1.21'

sudo apt-get install -y --allow-downgrades vault=1.21.4-1
sudo apt-mark hold vault        # gèle la version

vault version
which vault                     # → /usr/bin/vault
```

Le paquet crée l'utilisateur système `vault`, les dossiers `/etc/vault.d/` et
`/opt/vault/`, et l'unit systemd `vault.service`.

## 2. Certificat TLS (CA interne + certificat serveur)

Le SAN du certificat serveur doit couvrir l'IP de la machine.

```bash
sudo mkdir -p /opt/vault/tls
cd /tmp

# --- CA interne ---
openssl genrsa -out vault-ca.key 4096
openssl req -x509 -new -nodes -key vault-ca.key -sha256 -days 3650 \
  -out vault-ca.crt -subj "/CN=Vault Internal CA"

# --- Certificat serveur avec SAN sur IP + localhost ---
cat > vault.cnf <<'EOF'
[req]
distinguished_name = dn
req_extensions = v3_req
prompt = no
[dn]
CN = vault.internal.local
[v3_req]
subjectAltName = @alt
[alt]
IP.1  = <IP_VAULT>
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

# Vérifier que l'IP figure dans les SAN
sudo openssl x509 -in /opt/vault/tls/vault.crt -noout -text | grep -A1 "Subject Alternative Name"
```

## 3. Configuration Vault (Raft + listener TLS)

Remplacer `/etc/vault.d/vault.hcl` :

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

api_addr     = "https://<IP_VAULT>:8200"
cluster_addr = "https://<IP_VAULT>:8201"

disable_mlock = false
EOF

sudo mkdir -p /opt/vault/data
sudo chown -R vault:vault /opt/vault/data /etc/vault.d
sudo chmod 640 /etc/vault.d/vault.hcl
```

## 4. Démarrer et initialiser

```bash
sudo systemctl enable --now vault
sudo systemctl status vault --no-pager        # → active (running)
```

Pointer le CLI sur Vault (copie du CA dans le home pour l'usage CLI) :

```bash
sudo cp /opt/vault/tls/vault-ca.crt ~/vault-ca.crt
sudo chown "$USER":"$USER" ~/vault-ca.crt

export VAULT_ADDR="https://<IP_VAULT>:8200"
export VAULT_CACERT="$HOME/vault-ca.crt"

vault status
# Initialized  false
# Sealed       true
```

Initialiser — les 5 clés Shamir et le root token sortent ici, une seule fois :

```bash
vault operator init -key-shares=5 -key-threshold=3
```

> ⚠️ Copier immédiatement les 5 Unseal Keys **et** le Initial Root Token dans un
> gestionnaire de secrets. Sans au moins 3 des 5 clés, Vault reste scellé
> définitivement. Ne jamais les stocker dans Git ni dans un fichier en clair. En
> production, distribuer les 5 clés à 5 détenteurs distincts.

## 5. Unseal (à répéter à chaque redémarrage)

```bash
vault operator unseal    # Unseal Key 1  → Progress 1/3
vault operator unseal    # Unseal Key 2  → Progress 2/3
vault operator unseal    # Unseal Key 3  → Sealed devient false

vault status             # → Sealed false, Initialized true
vault login              # → Initial Root Token
```

Sans KMS d'auto-unseal, Vault repart **sealed** à chaque redémarrage du service :
l'unseal manuel (3 clés) est à refaire à chaque reboot.

## 6. Activer le moteur de secrets KV v2

```bash
vault secrets enable -path=kv kv-v2
vault kv list kv/        # vérifier le moteur monté
```

---

# Partie 2 — Création d'un utilisateur (userpass + MFA TOTP)

Compte local dans Vault (login + mot de passe), avec policy dédiée et MFA TOTP
bloquant à la connexion. Remplacer `<USER>` par le nom du compte à créer.

## 1. Policy sur mesure

Exemple d'une policy de gestion de secrets (lecture/écriture KV + création de
moteurs) plutôt que la policy `admin` complète :

```bash
vault policy write secrets-admin - <<'EOF'
# --- Gérer les secrets dans tous les moteurs KV ---
path "kv/data/*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "kv/metadata/*" {
  capabilities = ["list", "read", "delete"]
}
path "kv/delete/*"   { capabilities = ["update"] }
path "kv/undelete/*" { capabilities = ["update"] }
path "kv/destroy/*"  { capabilities = ["update"] }

# --- Créer et gérer des moteurs de secrets ---
path "sys/mounts" {
  capabilities = ["read", "list"]
}
path "sys/mounts/*" {
  capabilities = ["create", "read", "update", "delete"]
}
EOF
```

Pour restreindre à un périmètre, remplacer `kv/data/*` par `kv/data/<projet>/*`.
Lister les policies : `vault policy list` · lire une policy : `vault policy read <nom>`.

## 2. Activer userpass + créer l'utilisateur

```bash
vault auth enable userpass          # une seule fois pour le cluster

vault write auth/userpass/users/<USER> \
  password="<mot-de-passe-fort>" \
  token_policies="secrets-admin" \
  token_ttl="1h"
```

## 3. Entity + alias (support du MFA)

Le TOTP s'attache à une entity. On la crée à la main pour pouvoir enrôler le MFA
avant le premier login. L'alias relie l'entity au compte userpass.

```bash
# Accessor de la méthode userpass (réutilisé plus bas)
USERPASS_ACCESSOR=$(vault auth list -format=json | jq -r '.["userpass/"].accessor')
echo "$USERPASS_ACCESSOR"

# Créer l'entity
vault write identity/entity name="<USER>" policies="secrets-admin"
ENTITY_ID=$(vault read -field=id identity/entity/name/<USER>)
echo "$ENTITY_ID"

# Lier l'entity au compte userpass
vault write identity/entity-alias \
  name="<USER>" \
  canonical_id="$ENTITY_ID" \
  mount_accessor="$USERPASS_ACCESSOR"
```

## 4. Méthode MFA TOTP + enforcement

Créer la méthode en **SHA1** (les applications d'authentification génèrent en SHA1
par défaut en saisie manuelle ; SHA256 fait échouer la validation des codes).

```bash
vault write identity/mfa/method/totp \
  issuer="Vault" \
  period=30 \
  key_size=20 \
  algorithm=SHA1 \
  digits=6

vault list identity/mfa/method/totp          # récupérer le method_id (UUID)
```

Rendre le TOTP obligatoire à chaque login userpass (enforcement) :

```bash
vault write identity/mfa/login-enforcement/userpass-mfa \
  mfa_method_ids="<METHOD_ID>" \
  auth_method_accessors="$USERPASS_ACCESSOR"
```

## 5. Enrôler l'utilisateur (générer le secret TOTP)

```bash
vault write identity/mfa/method/totp/admin-generate \
  method_id="<METHOD_ID>" \
  entity_id="$ENTITY_ID"
```

La commande renvoie une `url` `otpauth://totp/...?secret=XXXX`. Dans l'application
d'authentification (Google Authenticator, Authy, FreeOTP…) : ajouter un compte →
saisir une clé de configuration → coller le `secret` → type basé sur le temps
(TOTP).

Un seul secret par entity : pour regénérer, détruire d'abord avec
`vault write identity/mfa/method/totp/admin-destroy method_id="<METHOD_ID>" entity_id="$ENTITY_ID"`.

## 6. Tester le login

```bash
vault login -method=userpass username=<USER>
# → mot de passe, puis :
# Enter the passphrase for methodID "<...>" of type "totp": <code 6 chiffres>
```

Ou via l'UI Vault : méthode Userpass → login + mot de passe → saisie du code TOTP.

Si le code est refusé, vérifier l'algorithme (SHA1 attendu) et la synchronisation
de l'horloge : `timedatectl status | grep -E 'synchronized|NTP'`.

## 7. Rate limit anti-brute-force

Le Login MFA ne limite pas le brute-force des codes par défaut. Poser un quota :

```bash
vault write sys/quotas/rate-limit/userpass-login \
  path="auth/userpass/login" \
  rate=5 interval="1m"

vault write sys/quotas/rate-limit/mfa-validate \
  path="sys/mfa/validate" \
  rate=5 interval="1m"
```

---

## Récapitulatif des objets créés

| Objet | Rôle |
|---|---|
| policy `secrets-admin` | droits du compte (secrets + moteurs KV) |
| `auth/userpass/users/<USER>` | le compte (login + mot de passe) |
| entity `<USER>` + entity-alias | identité stable, support du MFA |
| `identity/mfa/method/totp` (SHA1) | la méthode TOTP |
| `identity/mfa/login-enforcement/userpass-mfa` | rend le TOTP obligatoire |
| secret TOTP (admin-generate) | enrôlé dans l'app de l'utilisateur |
| quotas rate-limit | anti-brute-force |

---

# Partie 3 — Vault Secrets Operator (VSO)

Le VSO tourne dans le cluster Kubernetes et alimente des Secrets Kubernetes à
partir de Vault, en continu. Vault étant hors du cluster, il faut d'abord
configurer l'auth Kubernetes côté Vault (pour que les pods puissent
s'authentifier), puis installer et brancher le VSO en HTTPS.

Remplacer `<NAMESPACE>` par le namespace applicatif, `<IP_VAULT>` par l'IP de
Vault, et `<APP>` par le nom de l'application.

## 1. Auth Kubernetes côté Vault

Vault tourne hors du cluster : il lui faut l'URL de l'API Kubernetes, le CA du
cluster, et un token lui permettant de valider les JWT des pods (token reviewer).

```bash
export VAULT_ADDR="https://<IP_VAULT>:8200"
export VAULT_CACERT="$HOME/vault-ca.crt"

vault auth enable kubernetes

# CA du cluster
kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d > /tmp/k8s-ca.crt

# URL de l'API Kubernetes
K8S_HOST=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
echo "$K8S_HOST"     # si 127.0.0.1 → forcer l'IP réelle joignable depuis Vault :
# K8S_HOST="https://<IP_API_K8S>:6443"
```

## 2. Token reviewer (obligatoire quand Vault est hors cluster)

ServiceAccount dédié autorisé à faire du TokenReview :

```bash
kubectl create ns vault-auth
kubectl create sa vault-reviewer -n vault-auth

kubectl create clusterrolebinding vault-reviewer-binding \
  --clusterrole=system:auth-delegator \
  --serviceaccount=vault-auth:vault-reviewer

REVIEWER_JWT=$(kubectl create token vault-reviewer -n vault-auth --duration=8760h)
```

Configurer l'auth method :

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

Si `token_reviewer_jwt_set` est à `false`, tous les logins échoueront en 403.

## 3. Policy + role

```bash
vault policy write <APP> - <<'EOF'
path "kv/data/<APP>/preprod/*" {
  capabilities = ["read"]
}
EOF

vault write auth/kubernetes/role/<APP> \
  bound_service_account_names=vso-<APP> \
  bound_service_account_namespaces=<NAMESPACE> \
  policies=<APP> \
  ttl=1h
```

Le chemin API en KV v2 contient `data` (`kv/data/...`), contrairement au chemin
CLI (`kv/<APP>/...`). Seul le ServiceAccount `vso-<APP>` du namespace
`<NAMESPACE>` pourra s'authentifier avec ce role.

## 4. Installer le VSO

Chart Helm officiel HashiCorp. On le branche directement en HTTPS avec le CA de
Vault.

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

helm install vault-secrets-operator hashicorp/vault-secrets-operator \
  -n vault-secrets-operator --create-namespace \
  --set defaultVaultConnection.enabled=true \
  --set defaultVaultConnection.address=https://<IP_VAULT>:8200 \
  --set defaultVaultConnection.caCertSecretRef=vault-ca

kubectl get pods -n vault-secrets-operator
```

`defaultVaultConnection.address` doit pointer sur l'IP de la machine Vault, pas
sur `localhost` (le pod VSO tourne dans le cluster).

## 5. Pousser le CA de Vault dans le namespace du VSO

Sans le CA, le VSO échoue en `x509: certificate signed by unknown authority`.

```bash
kubectl create secret generic vault-ca \
  -n vault-secrets-operator \
  --from-file=ca.crt="$HOME/vault-ca.crt"

kubectl get secret vault-ca -n vault-secrets-operator -o jsonpath='{.data}' | jq 'keys'
# ["ca.crt"]
```

Vérifier que la connexion est saine :

```bash
kubectl get vaultconnection default -n vault-secrets-operator
# HEALTHY True / READY True
```

Si `caCertSecretRef` n'a pas été propagé au `VaultConnection` (connexion en
erreur CA), le patcher directement :

```bash
kubectl patch vaultconnection default -n vault-secrets-operator \
  --type merge \
  -p '{"spec":{"caCertSecretRef":"vault-ca"}}'
```

## 6. Pousser les secrets dans Vault

```bash
vault kv put kv/<APP>/preprod/<APP> \
  CLE_1="valeur1" \
  CLE_2="valeur2"

vault kv list kv/<APP>/preprod
```

## 7. Déclarer les CRs VSO

Un `ServiceAccount`, un `VaultAuth`, et un `VaultStaticSecret` par Secret à
produire. Fichier `vso-<APP>.yaml` :

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vso-<APP>
  namespace: <NAMESPACE>
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: vault-auth
  namespace: <NAMESPACE>
spec:
  method: kubernetes
  mount: kubernetes
  kubernetes:
    role: <APP>
    serviceAccount: vso-<APP>
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: <APP>
  namespace: <NAMESPACE>
spec:
  vaultAuthRef: vault-auth
  mount: kv
  type: kv-v2
  path: <APP>/preprod/<APP>
  refreshAfter: 30s
  destination:
    name: <APP>
    create: true
  rolloutRestartTargets:
    - kind: Deployment
      name: <APP>
```

```bash
kubectl apply -f vso-<APP>.yaml
kubectl get secret -n <NAMESPACE>
```

Points d'attention : `mount: kubernetes` correspond au path de l'auth method ;
`path:` est le chemin CLI (sans `data`, le VSO l'ajoute lui-même) ;
`destination.name` doit correspondre au `secretRef` consommé par le déploiement ;
`rolloutRestartTargets.name` doit viser le nom rendu du Deployment.

## 8. Vérifier la chaîne

```bash
kubectl get vaultstaticsecret -n <NAMESPACE>
# <APP>   True   True   True

kubectl get secret <APP> -n <NAMESPACE> -o jsonpath='{.data.CLE_1}' | base64 -d; echo
```

Test de rotation bout en bout :

```bash
vault kv put kv/<APP>/preprod/<APP> CLE_1="nouvelle-valeur" CLE_2="valeur2"

# ~30s (refreshAfter) : le Secret est mis à jour et le Deployment redémarre
kubectl get pods -n <NAMESPACE> -w
```

## Diagnostic

Les erreurs d'auth et de lecture remontent dans les **Events du CR**, pas dans les
logs du controller :

```bash
kubectl describe vaultstaticsecret <APP> -n <NAMESPACE> | tail -25
kubectl logs -n vault-secrets-operator -l app.kubernetes.io/name=vault-secrets-operator --tail=30
```

Une erreur `403 permission denied` sur `/v1/auth/kubernetes/login` indique un
`token_reviewer_jwt` mal configuré (voir §2). Après correction, forcer une
reconciliation :

```bash
kubectl delete pod -n vault-secrets-operator -l app.kubernetes.io/name=vault-secrets-operator
```