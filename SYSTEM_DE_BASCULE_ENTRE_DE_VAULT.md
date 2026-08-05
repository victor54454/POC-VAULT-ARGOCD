# Bascule DR d'un Vault mono-nœud vers une machine neuve

Procédure de reconstruction d'un Vault mort à partir de son kit de sauvegarde,
vers une **machine neuve avec une nouvelle IP et une nouvelle CA**. Complète la
doc « Vault prod mono-nœud » (section Backup), qu'elle prolonge côté restauration.

> **Périmètre exact testé.** Vault **1.21.4** mono-nœud, storage Raft, TLS CA
> interne, unseal Shamir 5/3, VSO (Vault Secrets Operator) qui consomme les
> secrets côté Kubernetes. Snapshot chiffré avec **`age`**. Scénario joué :
> Vault source `192.168.10.179` déclaré mort, reconstruit sur `192.168.10.83`
> (IP différente, CA régénérée). Pas de standby, pas de HA Vault : la résilience
> vient de la **capacité à restaurer**, pas d'un nœud de secours.

> **Statut.** Chaque commande ci-dessous a été **exécutée et vérifiée** lors de
> l'exercice. Les pièges notés sont ceux réellement rencontrés, pas des
> hypothèses.

---

## Contexte de l'exercice

| | Source (morte) | Cible (reconstruite) |
|---|---|---|
| IP | `192.168.10.179` | `192.168.10.83` |
| Vault | `1.21.4` | `1.21.4` (même version, épinglée) |
| Cluster K8s | `192.168.10.179:6443` | inchangé (le cluster survit) |
| CA TLS | perdue (voir piège n°2) | **régénérée** sur `.83` |
| VSO | pointait `.179` | rebranché sur `.83` |

Les deux VM ont le **même hostname** (`orktk`) — source de confusion permanente.
**Toujours vérifier `ip a` pour savoir sur quelle machine on est.**

---

## Le principe à comprendre avant tout

Un **snapshot Raft ne contient que les données Vault** : KV, montages de secrets
engines, méthodes d'auth, policies, et le **keyring** (matériel de chiffrement).

Il ne contient **PAS** :

- le certificat TLS ni la CA (`/opt/vault/tls/`) ;
- la configuration (`/etc/vault.d/vault.hcl`) ;
- les unseal keys Shamir.

Donc un snapshot seul **ne suffit pas** à remonter un Vault. Le kit de sauvegarde
doit rassembler le snapshot **et** ces éléments annexes.

---

## Phase 1 — Constituer le kit de sauvegarde (Vault source vivant)

À faire **pendant que la source vit**, car c'est la seule source du kit.

### 1.1 — Snapshot Raft chiffré (age)

```bash
export VAULT_ADDR="https://192.168.10.179:8200"
export VAULT_CACERT="$HOME/vault-ca.crt"

# snapshot
vault operator raft snapshot save ~/backup/vault-snapshot-$(date +%Y%m%d-%H%M%S).snap

# chiffrement age (clé publique du destinataire)
age -r <CLE_PUBLIQUE_AGE> \
  -o ~/backup/vault-snapshot-XXXXXXXX-XXXXXX.snap.age \
  ~/backup/vault-snapshot-XXXXXXXX-XXXXXX.snap

# supprimer le snapshot EN CLAIR une fois chiffré
shred -u ~/backup/vault-snapshot-XXXXXXXX-XXXXXX.snap
```

> Récupérer la clé publique depuis la clé privée : `age-keygen -y ~/vault-backup-key.txt`

### 1.2 — Matériel TLS

```bash
sudo cp /opt/vault/tls/vault.crt \
        /opt/vault/tls/vault.key \
        /opt/vault/tls/vault-ca.crt \
        /opt/vault/tls/vault-ca.key \
        ~/backup/tls/
```

> **La clé de CA (`vault-ca.key`) est le point critique — voir piège n°2.**
> Sans elle, impossible de resigner un certificat avec la même CA.

### 1.3 — Configuration

```bash
cp /etc/vault.d/vault.hcl ~/backup/config/
```

### 1.4 — Token reviewer (auth Kubernetes)

Ne pas copier le JWT (il expire). Ce qui compte : le SA `vault-reviewer` et son
binding survivent dans etcd du cluster. On **régénère** le JWT au moment du
restore. Vérifier qu'ils existent :

```bash
kubectl get sa vault-reviewer -n vault-auth
kubectl get clusterrolebinding vault-reviewer-binding
```

### 1.5 — Unseal keys + accès admin

Les unseal keys ne sont **nulle part sur disque** : ce sont celles notées à
l'`init`. S'assurer d'avoir **au moins 3 des 5** clés Shamir + le root token (ou
de quoi faire `generate-root`). **Sans elles, tout le reste du kit est inerte.**

### Validation du kit (avant de couper la source)

```bash
# a) inventaire
ls -R ~/backup/

# b) le snapshot chiffré est déchiffrable ET intègre — LE test qui compte
age -d -i ~/vault-backup-key.txt -o /tmp/verif.snap ~/backup/vault-snapshot-XXXXXXXX-XXXXXX.snap.age
vault operator raft snapshot inspect /tmp/verif.snap
rm -f /tmp/verif.snap

# c) le SAN du certif couvre bien l'IP source (ici .179)
openssl x509 -in ~/backup/tls/vault.crt -noout -text | grep -A1 "Subject Alternative Name"
```

`inspect` doit afficher les métadonnées (ID, Index, Term) et la liste des clés
(`sys/policy`, `core/keyring`, `core/mounts`, `auth/...`) sans erreur.

---

## Phase 2 — Simuler / constater la panne

Sur la machine **source** (`ip a` → `.179`) :

```bash
sudo systemctl stop vault
sudo systemctl disable vault
vault status        # → connection refused = source morte
```

À partir d'ici, **on ne retouche plus à la source**. Tout se fait avec le kit.

---

## Phase 3 — Restauration sur la machine neuve

### 3.0 — Transfert du kit vers la cible

Le kit nécessaire sur `.83` : le **snapshot chiffré**, la **clé privée age**
(`vault-backup-key.txt`), la **config**. (Le TLS du kit ne servira pas ici : on
régénère une CA neuve — voir piège n°2.)

```bash
# copier un DOSSIER : option -r obligatoire
scp -r ~/backup/config orktk@192.168.10.83:~/backup/
scp ~/backup/vault-snapshot-*.snap.age orktk@192.168.10.83:~/backup/
scp ~/vault-backup-key.txt orktk@192.168.10.83:~/backup/
```

Vérifier sur `.83` que le snapshot est déchiffrable **localement** :

```bash
# SUR .83
age -d -i ~/backup/vault-backup-key.txt -o /tmp/test.snap ~/backup/vault-snapshot-*.snap.age
vault operator raft snapshot inspect /tmp/test.snap
rm -f /tmp/test.snap
```

### 3.1 — Installer Vault (version épinglée, identique à la source)

```bash
sudo apt-get update && sudo apt-get install -y gpg wget lsb-release
wget -O- https://apt.releases.hashicorp.com/gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update

sudo apt-get install -y --allow-downgrades vault=1.21.4-1
sudo apt-mark hold vault
vault version    # → Vault v1.21.4
```

### 3.2 — Nouvelle CA + certif serveur, SAN sur la nouvelle IP

Puisque `vault-ca.key` de la source est perdue (piège n°2), on crée une **CA
neuve**. SAN sur `.83`.

```bash
sudo mkdir -p /opt/vault/tls
cd /tmp

# Nouvelle CA
openssl genrsa -out vault-ca.key 4096
openssl req -x509 -new -nodes -key vault-ca.key -sha256 -days 3650 \
  -out vault-ca.crt -subj "/CN=Vault Internal CA"

# Certif serveur, SAN sur .83
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
IP.1  = 192.168.10.83
IP.2  = 127.0.0.1
DNS.1 = localhost
EOF

openssl genrsa -out vault.key 4096
openssl req -new -key vault.key -out vault.csr -config vault.cnf
openssl x509 -req -in vault.csr -CA vault-ca.crt -CAkey vault-ca.key \
  -CAcreateserial -out vault.crt -days 825 -sha256 \
  -extensions v3_req -extfile vault.cnf

sudo cp vault.crt vault.key vault-ca.crt /opt/vault/tls/
sudo chown -R vault:vault /opt/vault/tls
sudo chmod 640 /opt/vault/tls/vault.key
sudo chmod 644 /opt/vault/tls/vault.crt /opt/vault/tls/vault-ca.crt

# CETTE FOIS, sauvegarder vault-ca.key hors machine (leçon piège n°2)
cp /tmp/vault-ca.key ~/backup/tls/vault-ca.key

# Vérifier le SAN (doit montrer .83)
sudo openssl x509 -in /opt/vault/tls/vault.crt -noout -text | grep -A1 "Subject Alternative Name"
```

### 3.3 — Configuration adaptée à la nouvelle IP

Reprendre la config du kit mais **basculer `api_addr`/`cluster_addr` sur `.83`** :

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

api_addr     = "https://192.168.10.83:8200"
cluster_addr = "https://192.168.10.83:8201"

disable_mlock = false
EOF

sudo mkdir -p /opt/vault/data
sudo chown -R vault:vault /opt/vault/data /etc/vault.d
sudo chmod 640 /etc/vault.d/vault.hcl

grep -E 'api_addr|cluster_addr' /etc/vault.d/vault.hcl   # doit montrer .83
sudo ls -la /opt/vault/data                              # doit être vide
```

### 3.4 — Démarrer + init temporaire (clés jetables)

Un Vault vierge doit être **initialisé et descellé** avant d'accepter un
`snapshot restore`. Les clés produites ici sont **jetables** : elles seront
écrasées par le restore.

```bash
sudo systemctl enable --now vault

# pointer le CLI sur .83 avec la NOUVELLE CA
cp /opt/vault/tls/vault-ca.crt ~/vault-ca.crt   # via sudo si besoin de droits
export VAULT_ADDR="https://192.168.10.83:8200"
export VAULT_CACERT="$HOME/vault-ca.crt"

vault status                                   # Initialized false / Sealed true

vault operator init -key-shares=5 -key-threshold=3   # clés JETABLES
vault operator unseal    # x3 (clés jetables) → Sealed false
```

### 3.5 — Restaurer le snapshot (le cœur)

```bash
vault login          # root token JETABLE (de l'init ci-dessus)

age -d -i ~/backup/vault-backup-key.txt -o /tmp/restore.snap \
  ~/backup/vault-snapshot-*.snap.age

vault operator raft snapshot restore -force /tmp/restore.snap
```

Après le restore, **Vault se re-scelle** (le keyring vient d'être remplacé par
celui de la source). C'est **normal et attendu** :

```bash
vault status         # → Sealed true   (attendu !)
```

### 3.6 — Unseal avec les ANCIENNES clés Shamir

```bash
vault operator unseal    # ANCIENNE clé de la source  x3 → Sealed false
```

> Si tu tentes une clé jetable ici, elle est **rejetée** (le progress n'avance
> pas) : c'est le bon révélateur que le keyring restauré est bien celui de la
> source.

### 3.7 — Vérifier les données restaurées

```bash
vault login          # ANCIEN root token de la source

vault secrets list   # kv + tes autres montages
vault auth list      # kubernetes, oidc, userpass...
vault policy list    # admin, poc...
vault kv get kv/poc/preprod/nginx
vault kv get kv/poc/preprod/postgres
```

Indices de succès observés : le `Cluster ID` redevient celui de la source, le
`Raft Applied Index` saute à la valeur du snapshot.

---

## Phase 4 — Rebrancher le VSO sur la nouvelle IP

Toutes ces commandes se lancent depuis une machine ayant `kubectl` (le cluster,
ici `.179`), avec le **client** `vault` pointé sur `.83`. Rappel : le serveur
`.179` reste mort — on n'utilise que `kubectl` (cluster vivant) et le binaire
`vault` en client distant.

### 4.1 — Reconfigurer l'auth Kubernetes (reviewer JWT frais)

```bash
export VAULT_ADDR="https://192.168.10.83:8200"
export VAULT_CACERT="/chemin/vers/ca-de-.83.crt"   # la CA de .83 !
vault login                                        # ANCIEN root token

REVIEWER_JWT=$(kubectl create token vault-reviewer -n vault-auth --duration=8760h)
K8S_HOST=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > /tmp/k8s-ca.crt

vault write auth/kubernetes/config \
  kubernetes_host="$K8S_HOST" \
  kubernetes_ca_cert=@/tmp/k8s-ca.crt \
  token_reviewer_jwt="$REVIEWER_JWT" \
  disable_local_ca_jwt=true

vault read auth/kubernetes/config | grep -E 'token_reviewer_jwt_set|disable_local_ca_jwt|kubernetes_host'
```

> `kubernetes_host` reste l'API du cluster (`.179:6443`), pas Vault. Il ne change
> pas lors de la bascule.

### 4.2 — Pousser la NOUVELLE CA au VSO

Le secret `vault-ca` du cluster contient encore l'ancienne CA. On le remplace par
celle de `.83` :

```bash
kubectl delete secret vault-ca -n vault-secrets-operator
kubectl create secret generic vault-ca \
  -n vault-secrets-operator \
  --from-file=ca.crt=/chemin/vers/ca-de-.83.crt
```

### 4.3 — Repointer l'adresse

```bash
kubectl patch vaultconnection default -n vault-secrets-operator \
  --type merge \
  -p '{"spec":{"address":"https://192.168.10.83:8200"}}'

kubectl get vaultconnection default -n vault-secrets-operator -o jsonpath='{.spec.address}'; echo
```

### 4.4 — Restart de l'opérateur + RECRÉATION des CR

Le restart seul **ne suffit pas** (piège n°3). Recréer les `VaultStaticSecret`
est le geste fiable :

```bash
kubectl rollout restart deployment vault-secrets-operator-controller-manager -n vault-secrets-operator
kubectl rollout status deployment vault-secrets-operator-controller-manager -n vault-secrets-operator

# purge fiable du client caché : delete + apply des CR
kubectl get vaultstaticsecret poc-nginx -n poc -o yaml > /tmp/nginx-cr.yaml
kubectl get vaultstaticsecret poc-postgres -n poc -o yaml > /tmp/pg-cr.yaml
kubectl delete vaultstaticsecret poc-nginx poc-postgres -n poc
kubectl apply -f /tmp/nginx-cr.yaml -f /tmp/pg-cr.yaml

kubectl get vaultstaticsecret -n poc -w   # → SYNCED True (AGE repart à quelques secondes)
```

---

## Phase 5 — Test de rotation (juge de paix)

Prouve la chaîne vivante : Vault `.83` → VSO → secret K8s → pod.

```bash
vault kv put kv/poc/preprod/nginx \
  APP_SECRET="dr-bascule-ok-$(date +%H%M%S)" \
  DATABASE_URL="postgres://pocuser:...@poc-postgres:5432/pocdb" \
  DOCKERHUB_TOKEN="test"

# ~30s (refreshAfter) puis :
kubectl exec -n poc deploy/poc-nginx -- env | grep APP_SECRET
# → dr-bascule-ok-HHMMSS   = bascule prouvée bout en bout
```

---

## Pièges rencontrés (retour d'expérience réel)

1. **Le TLS n'est pas dans le snapshot.** Le certif et la CA vivent dans
   `/opt/vault/tls/`, hors du storage Raft. Un restore ne les ramène pas → le VSO
   casse en `x509: certificate signed by unknown authority` tant que la CA n'est
   pas réalignée. **À sauvegarder séparément dans le kit.**

2. **`vault-ca.key` perdue.** La doc d'install génère la clé de CA dans `/tmp`,
   ne la copie jamais, et `/tmp` est purgé au reboot. Résultat : impossible de
   resigner un certif avec la même CA → obligation de créer une **nouvelle CA** +
   la redistribuer à tous les clients (VSO). **Correctif : sauvegarder
   `vault-ca.key` dans le kit** (secret critique, hors machine), ou adopter une CA
   longue durée conservée hors-ligne et ne régénérer que le certif serveur.

3. **Le VSO garde un client Vault en cache.** Après un changement d'adresse de la
   `VaultConnection`, certains `VaultStaticSecret` restent collés à l'ancien
   client (erreur pointant l'ancienne IP) **même après** un `rollout restart` de
   l'opérateur. Le seul geste fiable à 100 % : **delete + apply des CR**.

4. **Hostname identique sur les deux VM.** Les deux machines s'appellent `orktk`,
   ce qui rend le prompt trompeur. **Toujours `ip a`** pour savoir où on est avant
   toute commande.

5. **Variables d'env qui sautent.** `VAULT_ADDR`/`VAULT_CACERT` ne traversent pas
   un `sudo -s` (nouveau shell = variables perdues) et pointer un CA dans `/tmp`
   le fait disparaître au nettoyage. Garder un seul contexte utilisateur et
   stocker le CA dans le home (pas `/tmp`).

6. **`vault kv list` sur un secret.** `list` ne marche que sur un chemin parent
   (`kv/poc/preprod`), pas sur un secret feuille (`kv/poc/preprod/nginx` →
   `No value found`). Pour lire un secret : `vault kv get`. Ce n'est **pas** une
   perte de données.

7. **`scp` d'un dossier** nécessite l'option `-r`, sinon `not a regular file`.

---

## Ce que cet exercice recommande pour la vraie prod

- **DNS devant Vault** (nom stable, pas d'IP en dur dans le SAN, l'`api_addr`, le
  `caCertSecretRef`, etc.). Avec un nom DNS + une CA stable, une bascule vers une
  nouvelle machine se réduit à : recopier le TLS, restaurer le snapshot, unseal,
  changer 1 enregistrement DNS. Toute la gymnastique IP/CA de cet exercice
  disparaît.
- **CA longue durée hors-ligne**, réutilisée entre déploiements → seul le certif
  serveur change, le VSO garde la même CA en confiance.
- **Kit de sauvegarde complet et versionné** : snapshot chiffré + `vault-ca.key` +
  TLS + config + unseal keys, tous stockés **hors** de la machine Vault.
- **Tester la restauration périodiquement** — un backup jamais restauré n'est pas
  un backup.

---

## Checklist de bascule (mémo)

- [ ] Kit complet et snapshot déchiffrable vérifié (Phase 1)
- [ ] Source coupée, plus aucune modif dessus (Phase 2)
- [ ] Vault installé, version identique épinglée (3.1)
- [ ] Nouvelle CA + certif SAN sur la nouvelle IP, `vault-ca.key` sauvegardée (3.2)
- [ ] Config avec `api_addr`/`cluster_addr` sur la nouvelle IP, data vide (3.3)
- [ ] Init jetable + unseal jetable (3.4)
- [ ] `snapshot restore -force` (3.5)
- [ ] Unseal avec les ANCIENNES clés Shamir (3.6)
- [ ] Données vérifiées : secrets, auth, policies (3.7)
- [ ] Auth k8s reconfigurée, reviewer JWT frais (4.1)
- [ ] Nouvelle CA poussée au VSO (4.2)
- [ ] Adresse VSO repointée (4.3)
- [ ] Opérateur redémarré + CR recréés (4.4)
- [ ] Test de rotation OK — secret propagé au pod (Phase 5)