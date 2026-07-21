# POC ArgoCD + Vault (self-hosted)

Problème : en GitOps, les secrets ne doivent jamais être commit.
Solution testée : Vault self-hosted + Vault Secrets Operator (VSO),
auth Kubernetes, injection au déploiement.

## Architecture
```
                         ┌─────────────┐
                         │   Git repo  │  Chart Helm
                         │  (0 secret) │  nginx + postgres
                         └──────┬──────┘
                                │ sync
                                ▼
   ┌──────────────────────────────────────────────────┐
   │                  Cluster K8s                     │
   │                                                  │
   │   ┌──────────┐         ┌──────────────────┐      │
   │   │  ArgoCD  │────────▶│  nginx  postgres │      │
   │   └──────────┘ deploy  └────────▲─────────┘      │
   │                                 │ env / volume   │
   │                        ┌────────┴─────────┐      │
   │                        │  Secret K8s      │      │
   │                        └────────▲─────────┘      │
   │                                 │ créé par       │
   │                        ┌────────┴─────────┐      │
   │                        │ Vault Secrets    │      │
   │                        │ Operator (VSO)   │      │
   │                        └────────┬─────────┘      │
   └─────────────────────────────────┼────────────────┘
                                     │ Kubernetes auth
                                     │ (ServiceAccount token)
                                     ▼
                            ┌──────────────────┐
                            │  Vault (VM)      │
                            │  KV v2 engine    │
                            │  policy + role   │
                            └──────────────────┘
```
## Résultat
Chart Helm nginx + postgres déployé via ArgoCD, secrets récupérés
depuis le moteur KV v2 sans jamais transiter par Git.

## Reproduire : 

### Partie 1 — L'app de test

→ Créer un chart Helm à deux composants (nginx + postgres), sans aucun secret dedans
→ Le connecter à ArgoCD (créer l'Application qui pointe sur le repo)

### Partie 2 — Vault

→ Installer Vault en self-hosted sur la VM
→ Pousser les secrets dans le moteur KV v2
→ Activer l'auth Kubernetes, créer policy + role
→ Installer le Vault Secrets Operator (VSO) dans le cluster
→ Déclarer VaultAuth + un VaultStaticSecret par composant
→ Tester le cycle complet

### Pourquoi ce POC

ArgoCD nous renvoyait le `values.yaml` en clair qui était stocké dans ArgoCD, ce qui n'était pas bon — surtout si quelqu'un se faisait compromettre son compte, il pouvait voir tous nos credentials.

À chaque CI, quand on appelait ArgoCD pour qu'il fasse le rollout, celui-ci nous renvoyait tout dans les logs de la CI. On a donc trouvé une micro-correction :

```bash
curl -k -s -o /dev/null -w "\nHTTP_CODE=%{http_code}\n" -X PATCH "$ARGOCD_URL/api/v1/applications/${APP_NAME}" \
  --cert "$CERT" --key "$KEY" \
  -H "Authorization: Bearer $ARGOCD_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$REQUEST"
```

Le `-o /dev/null` nous permettait de n'avoir aucune sortie, mais ce n'était pas viable.

Un premier POC avec SOPS + Age avait été mené. Il fonctionnait, mais laissait trois points ouverts :

- **Les secrets restent dans Git.** Chiffrés, mais présents dans tout l'historique, de façon permanente.
- **La clé privée Age est dans un Secret du namespace `argocd`.** Quiconque a accès à ce namespace peut déchiffrer l'intégralité de l'historique. Le scénario "compte compromis" n'est pas couvert, il est déplacé.
- **Aucun audit des lectures, aucune révocation possible.**

Ce POC vient donc évaluer si Vault règle réellement le problème.

## Le principe : deux boucles indépendantes

Point important à comprendre avant de commencer : **avec VSO, Helm ne va jamais chercher dans Vault.**

- **VSO** : Vault → `Secret` Kubernetes, en continu (`refreshAfter`)
- **ArgoCD / Helm** : Git → Deployment, sur commit ou patch API

Il n'y a pas de "moment Helm" où Vault interviendrait. Le pod démarre et monte un `Secret` qui existe déjà, créé par VSO dans une boucle de réconciliation séparée.

C'est ce découplage qui fait la force du pattern — et son unique point dur : si le `Secret` n'existe pas encore et que Vault est indisponible, le pod ne démarre pas.

### L'architecture du POC

Deux composants, pour démontrer le dispatch multi-app :

```
Vault                          Secret K8s        Pod
─────────────────────────────────────────────────────────────
kv/poc/preprod/nginx      →    poc-nginx     →   poc-nginx
kv/poc/preprod/postgres   →    poc-postgres  →   poc-postgres
```

Le mot de passe Postgres n'est écrit **qu'une fois** dans Vault. Il sert à la fois à initialiser la base (`POSTGRES_PASSWORD` lu par l'image officielle) et à construire la `DATABASE_URL` consommée par nginx.

Le lien entre les deux mondes tient à une seule chose : **le nom du Secret Kubernetes**, fixé des deux côtés (`destination.name` dans le CR VSO, `secretRef` dans le chart). Rien d'autre ne les connecte.

### Contexte de la VM

| | |
|---|---|
| IP VM | `192.168.10.179` |
| UI ArgoCD | `https://192.168.10.179:30443/` |
| Vault | `http://192.168.10.179:8200` |
| Repo | `https://github.com/victor54454/POC-VAULT-ARGOCD` |
| Namespace applicatif | `poc` |

**Dimensionnement** : prévoir au moins 20 Go de disque. Un nœud K8s + ArgoCD + Vault + les images (~3 Go de containerd) passe difficilement sous 15 Go, et un `DiskPressure` évince les pods en cascade sans rapport avec Vault.

### Création d'une GitHub App

→ GitHub → ton profil → Settings → Developer settings → GitHub Apps → New GitHub App

Une fois cela fait, on peut voir que nous avons notre App ID : c'est la 1ère valeur.
Il ne faut pas générer de client secret, ça sert à l'OAuth, pas pour ArgoCD. Ce qu'il nous faut, c'est une private key en .pem.

#### → Générer la private key

Descends sur cette page General, plus bas que "Client secrets", tu vas trouver une section Private keys → clique Generate a private key. Ça télécharge un fichier .pem. C'est la 3ème valeur.

#### → Installer l'App sur ton repo

Menu gauche → Install App → clique Install sur ton compte @victor54454 → choisis Only select repositories → sélectionne POC-VAULT-ARGOCD → valide.

#### → Récupérer l'Installation ID

Après l'install, regarde l'URL du navigateur :

```
https://github.com/settings/installations/XXXXXXXX
```

Le nombre à la fin = ton Installation ID (2ème valeur).

#### → Connecter le repo dans ArgoCD

UI ArgoCD → Settings → Repositories → CONNECT REPO → méthode GITHUB APP, en renseignant les 3 valeurs (App ID, Installation ID, private key .pem).

**Attention au champ Project** : mettre `default`, pas `poc`. Le repo est scopé au projet ; si l'Application est dans `default` et le repo dans `poc`, elle ne le verra pas.

### Le repo POC-VAULT-ARGOCD

Structure :

```
POC-VAULT-ARGOCD/
├── Chart.yaml
├── values.yaml          ← aucun secret
└── templates/
    ├── nginx.yaml       ← Deployment + Service
    └── postgres.yaml    ← Deployment + Service
```

Il n'y a **aucun** `templates/secret.yaml`. C'est VSO qui crée les `Secret` dans le cluster. Le chart consomme des `Secret` dont il ignore l'origine.

Un fichier par composant, chacun avec son bloc dans `values.yaml`, même structure.

#### `Chart.yaml`

```yaml
apiVersion: v2
name: POC
description: POC secrets Vault + VSO
type: application
version: 0.1.0
appVersion: "1.0"
```

#### `values.yaml`

```yaml
nginx:
  replicaCount: 1
  image:
    repository: nginx
    tag: "1.27-alpine"
    pullPolicy: IfNotPresent
  service:
    type: NodePort
    port: 80
    targetPort: 80
    nodePort: 30000

postgres:
  replicaCount: 1
  image:
    repository: postgres
    tag: "16-alpine"
    pullPolicy: IfNotPresent
  service:
    type: ClusterIP
    port: 5432
    targetPort: 5432
```

#### `templates/nginx.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}-nginx
spec:
  replicas: {{ .Values.nginx.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Release.Name }}-nginx
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}-nginx
    spec:
      containers:
        - name: nginx
          image: "{{ .Values.nginx.image.repository }}:{{ .Values.nginx.image.tag }}"
          imagePullPolicy: {{ .Values.nginx.image.pullPolicy }}
          ports:
            - containerPort: {{ .Values.nginx.service.targetPort }}
          envFrom:
            - secretRef:
                name: {{ .Release.Name }}-nginx
---
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}-nginx
spec:
  type: {{ .Values.nginx.service.type }}
  selector:
    app: {{ .Release.Name }}-nginx
  ports:
    - port: {{ .Values.nginx.service.port }}
      targetPort: {{ .Values.nginx.service.targetPort }}
      {{- if eq .Values.nginx.service.type "NodePort" }}
      nodePort: {{ .Values.nginx.service.nodePort }}
      {{- end }}
```

#### `templates/postgres.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}-postgres
spec:
  replicas: {{ .Values.postgres.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Release.Name }}-postgres
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}-postgres
    spec:
      containers:
        - name: postgres
          image: "{{ .Values.postgres.image.repository }}:{{ .Values.postgres.image.tag }}"
          imagePullPolicy: {{ .Values.postgres.image.pullPolicy }}
          ports:
            - containerPort: {{ .Values.postgres.service.targetPort }}
          envFrom:
            - secretRef:
                name: {{ .Release.Name }}-postgres
---
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}-postgres
spec:
  type: {{ .Values.postgres.service.type }}
  selector:
    app: {{ .Release.Name }}-postgres
  ports:
    - port: {{ .Values.postgres.service.port }}
      targetPort: {{ .Values.postgres.service.targetPort }}
```

Avec la release `poc`, `{{ .Release.Name }}-postgres` rend `poc-postgres` : le Deployment, le Service et le Secret attendu portent le même nom. Idem pour nginx.

`POSTGRES_PASSWORD`, `POSTGRES_USER` et `POSTGRES_DB` sont les variables que l'image officielle Postgres lit à l'initialisation. Les clés dans Vault portent exactement ces noms — **aucun mapping nulle part**.

Push :

```bash
git add .
git commit -m "Chart POC nginx + postgres, aucun secret"
git push
```

### Créer l'Application ArgoCD

+ NEW APP :

#### General

→ Application Name : poc
→ Project Name : default
→ Sync Policy : Automatic
→ Coche Prune Resources et Self Heal
→ Coche Auto-Create Namespace

#### Source

→ Repository URL : sélectionne https://github.com/victor54454/POC-VAULT-ARGOCD dans la liste déroulante
→ Revision : main
→ Path : .
→ Type de source : **Helm** (pas de plugin, on n'en a plus besoin)

Laisser VALUES FILES et VALUES vides. Les PARAMETERS affichés sont les valeurs par défaut lues dans `values.yaml` — on ne les surcharge pas.

#### Destination

→ Cluster URL : https://kubernetes.default.svc
→ Namespace : poc

#### → État attendu à ce stade

```bash
kubectl get pods -n poc
# CreateContainerConfigError sur les deux pods
```

**C'est normal.** Les `envFrom: secretRef` pointent vers des Secrets qui n'existent pas encore. Vault et VSO ne sont pas installés.

```bash
kubectl describe pod -n poc | grep -A2 Events
# secret "poc-nginx" not found
```

C'est exactement le Cas B du Test 8 : le pod ne démarre pas tant que le Secret n'existe pas. Ça se résoudra tout seul dès que VSO aura créé les Secrets — sans re-sync ArgoCD. C'est la démonstration du découplage.

### Installation de Vault

Récupérer la dernière version :

```bash
curl -s https://api.github.com/repos/hashicorp/vault/releases/latest | grep '"tag_name"'
```

Installer :

```bash
curl -Lo vault.zip https://releases.hashicorp.com/vault/1.18.3/vault_1.18.3_linux_amd64.zip
unzip vault.zip
sudo mv vault /usr/local/bin/
rm vault.zip
vault version
```

#### → Lancer Vault en mode dev

Le mode dev démarre Vault unsealed, en mémoire, avec un root token fixe. **POC uniquement** : tout est perdu au redémarrage — y compris un simple reboot de la VM.

```bash
vault server -dev -dev-listen-address=0.0.0.0:8200 -dev-root-token-id=root
```

Garder ce terminal ouvert (ou passer par `tmux` / `nohup`).

Dans un autre terminal :

```bash
export VAULT_ADDR=http://192.168.10.179:8200
export VAULT_TOKEN=root
vault status
```

L'UI Vault est accessible sur `http://192.168.10.179:8200` (token : `root`).

`VAULT_TOKEN` est le token d'authentification du client CLI, pas un mot de passe modifiable à la volée : il doit valoir exactement ce qui a été passé à `-dev-root-token-id`.

### Pousser les secrets dans Vault

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
```

Vérification :

```bash
vault kv list kv/poc/preprod
# nginx
# postgres

vault kv get kv/poc/preprod/postgres
```

Convention de chemin retenue : `<app>/<env>/<composant>`. En prod on préfixera par le cluster : `kv/<cluster>/<app>/<env>/<composant>`.

Le `DATABASE_URL` de nginx pointe sur `poc-postgres` — le nom du Service rendu par le chart — et embarque le même mot de passe que celui poussé dans `kv/poc/preprod/postgres`. Un seul endroit de vérité.

**Note** : `vault kv list kv/poc/preprod/nginx` renvoie `No value found` — c'est normal, `nginx` est un secret, pas un dossier.

### Auth Kubernetes

Vault tourne sur la VM, **hors du cluster**. Il faut donc lui donner l'URL de l'API Kubernetes, le CA, et un token lui permettant de valider les JWT des pods.

```bash
vault auth enable kubernetes

kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d > /tmp/k8s-ca.crt

K8S_HOST=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
echo "$K8S_HOST"
```

**Attention** : si `$K8S_HOST` sort `https://127.0.0.1:6443`, remplacer par l'IP réelle — Vault doit pouvoir joindre l'API depuis la VM :

```bash
K8S_HOST="https://192.168.10.179:6443"
```

#### → Le token reviewer (obligatoire quand Vault est hors du cluster)

Quand un pod se présente, Vault doit vérifier son token auprès de l'API Kubernetes (`TokenReview`). Pour cela il lui faut lui-même une identité dans le cluster.

Si Vault tourne **dans** le cluster, il utilise son propre ServiceAccount automatiquement (`disable_local_ca_jwt=false`, le défaut). Ici Vault est sur la VM : il n'a aucun SA, donc chaque login échoue en `403 permission denied`.

On crée donc un SA dédié, autorisé à faire du TokenReview :

```bash
kubectl create ns vault-auth
kubectl create sa vault-reviewer -n vault-auth

kubectl create clusterrolebinding vault-reviewer-binding \
  --clusterrole=system:auth-delegator \
  --serviceaccount=vault-auth:vault-reviewer

REVIEWER_JWT=$(kubectl create token vault-reviewer -n vault-auth --duration=8760h)
```

Le ClusterRole `system:auth-delegator` donne exactement une chose : le droit d'appeler `TokenReview` et `SubjectAccessReview`. Aucun accès aux secrets, aux pods, à rien d'autre.

#### → Configurer l'auth method

```bash
vault write auth/kubernetes/config \
  kubernetes_host="$K8S_HOST" \
  kubernetes_ca_cert=@/tmp/k8s-ca.crt \
  token_reviewer_jwt="$REVIEWER_JWT" \
  disable_local_ca_jwt=true
```

Vérification — les deux valeurs qui comptent :

```bash
vault read auth/kubernetes/config | grep -E 'token_reviewer_jwt_set|disable_local_ca_jwt'
# token_reviewer_jwt_set    true
# disable_local_ca_jwt      true
```

Si `token_reviewer_jwt_set` est à `false`, tous les logins échoueront en 403.

#### → La policy

Lecture seule, une seule règle avec wildcard pour couvrir les deux composants.

```bash
vault policy write poc - <<'EOF'
path "kv/data/poc/preprod/*" {
  capabilities = ["read"]
}
EOF
```

Deux points :

- **`kv/data/...`** : en KV v2 le chemin API contient `data`, contrairement au chemin CLI (`kv/poc/preprod/nginx`)
- **Pas de `list`** : VSO lit des paths précis, il n'énumère jamais. Ajouter `list` sur `kv/metadata/...` ne servirait qu'à la navigation dans l'UI, et révélerait les noms des secrets — un écart au moindre privilège inutile ici. Pour naviguer dans l'UI, utiliser le root token.

C'est le wildcard qui rend le pattern réplicable : une policy par app/env, quel que soit le nombre de composants dedans.

#### → Le role

Il lie un ServiceAccount Kubernetes à la policy.

```bash
vault write auth/kubernetes/role/poc \
  bound_service_account_names=vso-poc \
  bound_service_account_namespaces=poc \
  policies=poc \
  ttl=1h
```

Seul le SA `vso-poc` du namespace `poc` pourra s'authentifier avec ce role. Le warning sur l'`audience` est bénin (durcissement optionnel du JWT).

### Installation du Vault Secrets Operator

VSO est un chart Helm officiel HashiCorp. Pas d'image custom, pas de plugin, pas de patch du repo-server.

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

helm install vault-secrets-operator hashicorp/vault-secrets-operator \
  -n vault-secrets-operator --create-namespace \
  --set defaultVaultConnection.enabled=true \
  --set defaultVaultConnection.address=http://192.168.10.179:8200
```

`defaultVaultConnection.address` doit pointer sur l'IP de la VM, pas sur `localhost` : le pod VSO tourne dans le cluster, pas sur la VM.

Vérification :

```bash
kubectl get pods -n vault-secrets-operator
kubectl get crd | grep secrets.hashicorp.com
```

### Les CRs dans le namespace poc

Un `VaultStaticSecret` par Secret à produire. Le ServiceAccount et le `VaultAuth` sont partagés.

Fichier `vso-poc.yaml` :

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vso-poc
  namespace: poc
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: vault-auth
  namespace: poc
spec:
  method: kubernetes
  mount: kubernetes
  kubernetes:
    role: poc
    serviceAccount: vso-poc
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: poc-nginx
  namespace: poc
spec:
  vaultAuthRef: vault-auth
  mount: kv
  type: kv-v2
  path: poc/preprod/nginx
  refreshAfter: 30s
  destination:
    name: poc-nginx
    create: true
  rolloutRestartTargets:
    - kind: Deployment
      name: poc-nginx
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: poc-postgres
  namespace: poc
spec:
  vaultAuthRef: vault-auth
  mount: kv
  type: kv-v2
  path: poc/preprod/postgres
  refreshAfter: 30s
  destination:
    name: poc-postgres
    create: true
  rolloutRestartTargets:
    - kind: Deployment
      name: poc-postgres
```

Points importants :

- `mount: kubernetes` correspond au path de l'auth method (`vault auth enable kubernetes`)
- `path:` est le chemin **CLI** (sans `data`), VSO ajoute `data` lui-même
- `destination.name` doit correspondre au `secretRef` du chart
- `rolloutRestartTargets.name` doit viser le **nom rendu** du Deployment (`poc-nginx`, pas `nginx`)
- Les deux CRs réutilisent le même `vault-auth` et le même SA : seuls le path et la destination changent

Ces CRs sont volontairement **hors du chart** : ils relèvent de l'infra, pas de l'app. On les applique directement.

```bash
kubectl apply -f vso-poc.yaml
kubectl get secret -n poc
```

Et les pods qui étaient en erreur se débloquent tout seuls :

```bash
kubectl get pods -n poc -w
```

**Aucun sync ArgoCD n'a été déclenché.** Les Secrets sont apparus, kubelet a pu monter les env vars, les pods ont démarré. C'est le découplage en action.

Chaque Secret contient une clé de plus que ce qui a été poussé : `_raw`, le JSON complet renvoyé par Vault, ajouté par VSO. Sans impact sur `envFrom` — mais à filtrer en production.

#### → Diagnostic

Deux sources à consulter — ce sont **les Events du CR qui portent les erreurs métier** (auth, lecture), pas les logs du controller :

```bash
kubectl describe vaultstaticsecret poc-nginx -n poc | tail -25
kubectl logs -n vault-secrets-operator -l app.kubernetes.io/name=vault-secrets-operator --tail=30
```

**Erreur `403 permission denied` sur `/v1/auth/kubernetes/login`** : le `token_reviewer_jwt` n'est pas configuré. Voir la section "Le token reviewer". Après correction, forcer une reconciliation :

```bash
kubectl delete pod -n vault-secrets-operator -l app.kubernetes.io/name=vault-secrets-operator
kubectl get secret -n poc -w
```

### Validation du POC

#### → Test 1 — les secrets sont provisionnés dans les pods

```bash
kubectl exec -n poc deploy/poc-nginx -- env | grep APP_SECRET
# _raw={"data":{"APP_SECRET":"mon-super-secret-applicatif","DATABASE_URL":"..."},"metadata":{...}}
# APP_SECRET=mon-super-secret-applicatif

kubectl exec -n poc deploy/poc-postgres -- env | grep POSTGRES_USER
# POSTGRES_USER=pocuser
```

Les secrets ne sont jamais passés par Git ni par Helm.

**Note sur `_raw`** : VSO ajoute cette clé au `Secret`, contenant le JSON complet renvoyé par Vault. Avec `envFrom`, elle se retrouve donc en variable d'environnement du process — tous les secrets d'un coup, dans une seule variable. Sans gravité ici, mais à filtrer en production via une `SecretTransformation` avec `excludes: ["_raw"]`.

#### → Test 2 — Postgres applique réellement le mot de passe de Vault

Le test qui prouve que la chaîne est réelle et pas seulement cosmétique.

**Ne pas tester depuis l'intérieur du conteneur** — ça ne prouve rien :

```bash
kubectl exec -n poc deploy/poc-postgres -- \
  env PGPASSWORD='mauvais' psql -U pocuser -d pocdb -c "SELECT 1;"
# ?column?
#        1     ← ça passe malgré le mauvais mot de passe !
```

L'image Postgres configure `pg_hba.conf` en `trust` pour les connexions locales (socket Unix). Le mot de passe n'est jamais vérifié. Il faut passer **par le réseau**, depuis un autre pod.

**Bon mot de passe → doit passer :**

```bash
kubectl run pgtest -n poc --restart=Never \
  --image=postgres:16-alpine -- \
  sh -c 'PGPASSWORD="Vault-P0stgres-2026" psql -h poc-postgres -U pocuser -d pocdb -c "SELECT version();"'

sleep 5
kubectl logs pgtest -n poc
kubectl delete pod pgtest -n poc
```

```
                                         version
------------------------------------------------------------------------------------------
 PostgreSQL 16.14 on x86_64-pc-linux-musl, compiled by gcc (Alpine 15.2.0) 15.2.0, 64-bit
(1 row)
```

**Mauvais mot de passe → doit échouer :**

```bash
kubectl run pgtest -n poc --rm -it --restart=Never \
  --image=postgres:16-alpine -- \
  sh -c 'PGPASSWORD="mauvais" psql -h poc-postgres -U pocuser -d pocdb -c "SELECT 1;"'
```

```
psql: error: connection to server at "poc-postgres" (10.106.250.113), port 5432 failed:
FATAL:  password authentication failed for user "pocuser"
```

La paire prouve que Postgres a initialisé sa base avec le mot de passe venu de Vault, et nulle part ailleurs.

Et l'URL côté nginx est cohérente :

```bash
kubectl exec -n poc deploy/poc-nginx -- sh -c 'echo $DATABASE_URL'
# postgres://pocuser:Vault-P0stgres-2026@poc-postgres:5432/pocdb
```

#### → Test 3 — l'API ArgoCD ne renvoie aucun secret

On récupère un token et on interroge l'API :

```bash
ARGOCD_TOKEN=$(curl -k -s https://192.168.10.179:30443/api/v1/session \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"MOT_DE_PASSE"}' | jq -r .token)
```

Le spec de l'application :

```bash
curl -k -s "https://192.168.10.179:30443/api/v1/applications/poc" \
  -H "Authorization: Bearer $ARGOCD_TOKEN" | grep -iE 'mon-super-secret|Vault-P0stgres'
```

Les manifests rendus — **c'est le test qui compte** :

```bash
curl -k -s "https://192.168.10.179:30443/api/v1/applications/poc/manifests" \
  -H "Authorization: Bearer $ARGOCD_TOKEN" | grep -iE 'mon-super-secret|Vault-P0stgres'
```

Résultat vide sur les deux. Vérifier que l'API répond bien, pour écarter un token expiré qui donnerait aussi un grep vide :

```bash
curl -k -s "https://192.168.10.179:30443/api/v1/applications/poc/manifests" \
  -H "Authorization: Bearer $ARGOCD_TOKEN" | head -c 300
# {"manifests":["{\"apiVersion\":\"v1\",\"kind\":\"Service\",...
```

L'API répond, les manifests sont là, et aucun secret dedans. Il n'y a plus de `templates/secret.yaml`, donc aucun `Secret` n'est rendu par Helm : **il n'y a structurellement rien à fuiter**.

Le `-o /dev/null` dans les CI devient une simple défense en profondeur, plus une nécessité.

#### → Test 4 — un update Helm ne change rien aux secrets

Reproduit le comportement de la CI (patch du tag d'image via l'API).

Le endpoint `PATCH /api/v1/applications/{name}` attend un body contenant trois champs : `name`, `patch` (une **string** de JSON échappé) et `patchType`. Le `jq -n --arg` fait l'échappement proprement.

```bash
PATCH='{"spec":{"source":{"helm":{"parameters":[{"name":"nginx.image.tag","value":"1.28-alpine"}]}}}}'

REQUEST=$(jq -n --arg p "$PATCH" \
  '{name:"poc", patch:$p, patchType:"merge"}')

curl -k -s -o /dev/null -w "\nHTTP_CODE=%{http_code}\n" \
  -X PATCH "https://192.168.10.179:30443/api/v1/applications/poc" \
  -H "Authorization: Bearer $ARGOCD_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$REQUEST"
# HTTP_CODE=200
```

Deux pièges sur ce endpoint :

- passer le `patchType` en query param → **500** `grpc: error while marshaling: proto: required field "patchType" not set`
- utiliser le MIME type comme valeur → **400** `Patch type 'application/merge-patch+json' is not supported`

Les seules valeurs acceptées sont `merge` et `json`.

Vérification :

```bash
kubectl rollout status deploy/poc-nginx -n poc
kubectl get deploy poc-nginx -n poc -o jsonpath='{.spec.template.spec.containers[0].image}'
# nginx:1.28-alpine
kubectl exec -n poc deploy/poc-nginx -- env | grep APP_SECRET
```

Le nouveau pod a le secret. Helm n'a rien fait de particulier : le `Secret` était déjà là.

Retirer le paramètre après le test, sinon il reste attaché à l'Application :

```bash
PATCH='{"spec":{"source":{"helm":{"parameters":[]}}}}'
REQUEST=$(jq -n --arg p "$PATCH" '{name:"poc", patch:$p, patchType:"merge"}')
curl -k -s -o /dev/null -w "\nHTTP_CODE=%{http_code}\n" \
  -X PATCH "https://192.168.10.179:30443/api/v1/applications/poc" \
  -H "Authorization: Bearer $ARGOCD_TOKEN" \
  -H "Content-Type: application/json" -d "$REQUEST"
```

#### → Test 5 — rotation depuis Vault

```bash
vault kv put kv/poc/preprod/nginx \
  APP_SECRET="nouveau-secret-rotation" \
  DATABASE_URL="postgres://pocuser:Vault-P0stgres-2026@poc-postgres:5432/pocdb" \
  DOCKERHUB_TOKEN="dckr_pat_exemple_token_12345"

kubectl get pods -n poc -w
```

Sous 30 secondes : le `Secret` est mis à jour et le Deployment redémarre automatiquement (`rolloutRestartTargets`).

```bash
kubectl exec -n poc deploy/poc-nginx -- env | grep APP_SECRET
# APP_SECRET=nouveau-secret-rotation

kubectl describe vaultstaticsecret poc-nginx -n poc | grep RolloutRestart
# Normal  RolloutRestartTriggered  Rollout restart triggered for {Deployment poc-nginx}
```

**Zéro commit, zéro sync ArgoCD, zéro Git.** C'est ce que SOPS ne sait pas faire : il aurait fallu rechiffrer, commiter, pusher, attendre le sync.

**Le piège Postgres** : `POSTGRES_PASSWORD` n'est lu qu'**au premier démarrage**, quand le volume de données est vide. Une rotation dans Vault redémarre bien le pod, mais ne change pas le mot de passe en base. Ici il n'y a pas de PVC — chaque restart repart de zéro, donc le nouveau mot de passe est appliqué. Avec un PVC (le cas réel), il faudrait un `ALTER USER ... PASSWORD`.

C'est exactement le problème que les **dynamic secrets** Vault résolvent : Vault crée et révoque les comptes Postgres lui-même, avec un TTL court. Hors périmètre de ce POC, mais c'est la suite logique — et le vrai argument pour Vault au-delà du simple stockage.

#### → Test 6 — révocation

```bash
vault policy delete poc

vault kv put kv/poc/preprod/nginx \
  APP_SECRET="test-revocation" \
  DATABASE_URL="x" \
  DOCKERHUB_TOKEN="y"
```

**Le token en cache reste valide.** Supprimer une policy n'invalide pas les tokens déjà émis : VSO garde le sien jusqu'à expiration (`ttl=1h` sur le role). Pour observer la révocation, forcer un re-login :

```bash
kubectl delete pod -n vault-secrets-operator -l app.kubernetes.io/name=vault-secrets-operator
sleep 30
```

L'erreur remonte dans les **Events du CR**, pas dans les logs du controller :

```bash
kubectl describe vaultstaticsecret poc-nginx -n poc | tail -25
```

```
Warning  VaultClientError  Failed to read Vault secret: Error making API request.
URL: GET http://192.168.10.179:8200/v1/kv/data/poc/preprod/nginx
Code: 403. Errors:
* permission denied
```

Et la valeur `test-revocation` n'est jamais arrivée dans le cluster :

```bash
kubectl get secret poc-nginx -n poc -o jsonpath='{.data.APP_SECRET}' | base64 -d; echo
# nouveau-secret-rotation  ← la valeur d'avant la révocation
```

L'accès est coupé. Avec SOPS, révoquer un accès impose de rechiffrer avec une nouvelle clé Age **et** de considérer tout l'historique Git comme compromis.

**Nuance à retenir** : la révocation Vault est immédiate sur les **nouveaux** logins, mais les tokens en cours conservent leurs droits jusqu'à expiration. Pour couper immédiatement sans attendre le TTL :

```bash
vault token revoke -mode=path auth/kubernetes/login
```

Restaurer la policy et la valeur pour la suite :

```bash
vault policy write poc - <<'EOF'
path "kv/data/poc/preprod/*" {
  capabilities = ["read"]
}
EOF

vault kv put kv/poc/preprod/nginx \
  APP_SECRET="mon-super-secret-applicatif" \
  DATABASE_URL="postgres://pocuser:Vault-P0stgres-2026@poc-postgres:5432/pocdb" \
  DOCKERHUB_TOKEN="dckr_pat_exemple_token_12345"
```

#### → Test 7 — audit

```bash
vault audit enable file file_path=/tmp/vault-audit.log
tail -f /tmp/vault-audit.log
```

Chaque lecture par VSO produit une entrée JSON contenant :

| Champ | Valeur observée |
|---|---|
| Qui | `display_name: kubernetes-poc-vso-poc`, `service_account_name: vso-poc`, `service_account_namespace: poc`, `role: poc` |
| Quoi | `operation: read`, `path: kv/data/poc/preprod/nginx` |
| Quand | `time: 2026-07-16T09:46:03Z` |
| D'où | `remote_address: 10.10.43.29` (le pod VSO) |
| Décision | `policy_results.granting_policies: [{name: poc, type: acl}]` |
| Client | `user-agent: vso/1.4.1` |

**Les valeurs des secrets sont hashées** (`hmac-sha256:...`), jamais en clair. L'audit log est donc exploitable — shipping vers ELK, corrélation, alerting — sans devenir lui-même un secret à protéger.

SOPS n'a aucun équivalent : il n'existe aucune trace de qui a déchiffré quoi.

Filtrer les lectures de secrets :

```bash
jq -c 'select(.request.path | startswith("kv/data/poc/preprod")) | select(.type == "response")
  | {time, sa: .auth.metadata.service_account_name, path: .request.path}' /tmp/vault-audit.log
```

#### → Test 8 — Vault indisponible

Le point dur du pattern. À mesurer, pas à ignorer.

**Cas A — le Secret Kubernetes existe déjà :**

```bash
sudo pkill vault
vault status
# connection refused

kubectl rollout restart deploy/poc-nginx -n poc
kubectl get pods -n poc
kubectl exec -n poc deploy/poc-nginx -- env | grep APP_SECRET
```

Le pod démarre normalement, en quelques secondes, secret présent. Le `Secret` est persisté dans etcd — **VSO n'est pas sur le chemin critique du démarrage**.

**Cas B — le Secret n'existe pas :**

```bash
kubectl delete secret poc-nginx -n poc
kubectl rollout restart deploy/poc-nginx -n poc
sleep 10
kubectl get pods -n poc
```

```
NAME                             READY   STATUS                       RESTARTS   AGE
poc-nginx-846dbf66b8-qnmtz       0/1     CreateContainerConfigError   0          17s
poc-nginx-8b5dcff8c-xkxkc        1/1     Running                      0          78s
```

C'est le SPOF — le même état qu'avant l'installation de VSO.

**Mais l'ancien pod tourne toujours.** Le nouveau échoue, donc le rollout est bloqué et Kubernetes ne termine pas l'ancien ReplicaSet. Le service reste disponible.

La formulation juste est donc : **Vault down n'interrompt pas ce qui tourne, ça empêche de déployer.** C'est un incident de déploiement, pas un incident de production — sauf si un nœud tombe simultanément et qu'il faut replanifier des pods sur du matériel neuf.

Ça reste une raison suffisante pour exiger Vault en Raft 3 nœuds en production, pas un mode dev sur une VM.

Redémarrer Vault et tout repousser (le mode dev est volatile) :

```bash
vault server -dev -dev-listen-address=0.0.0.0:8200 -dev-root-token-id=root
# puis rejouer : "Pousser les secrets dans Vault" + "Auth Kubernetes"
```

Le SA `vault-reviewer`, son ClusterRoleBinding et les CRs VSO survivent (ils sont dans etcd). En revanche `/tmp/k8s-ca.crt` disparaît à chaque reboot — le régénérer.

### Bilan de la comparaison

| | SOPS + Age | Vault + VSO |
|---|---|---|
| Secrets dans Git | Oui, chiffrés, à vie | Non |
| Secret dans le manifest rendu | Oui (`templates/secret.yaml`) | Non |
| Composant maison à maintenir | Image custom + plugin CMP bash | Aucun |
| Suit la version d'ArgoCD | Oui (rebuild à chaque bump) | Non |
| Rotation d'un secret | Rechiffrer + commit + push + sync | `vault kv put`, propagation 30s |
| Révocation d'accès | Impossible rétroactivement | Immédiate sur les nouveaux logins |
| Audit des lectures | Aucun | Complet, valeurs hashées |
| Granularité d'accès | Par clé Age | Par path / namespace / role |
| Dynamic secrets | Non | Oui (hors POC) |
| Coût opérationnel | Faible | Élevé (HA, unseal, backup, DR) |
| SPOF | Aucun | Vault (bloque les déploiements, pas le run) |

**Limite connue de VSO** : le secret existe en clair dans etcd. Qui a `get secrets` sur le namespace `poc` peut le lire. Ça se traite par l'encryption-at-rest sur etcd + RBAC serré — de l'hygiène cluster indépendante de Vault.

L'alternative **Bank-Vaults** (mutating webhook, injection en mémoire, zéro secret dans etcd) existe. Elle impose de réécrire chaque deployment avec des annotations et des références `vault:kv/...`, et surtout elle durcit le SPOF : chaque démarrage de pod interroge Vault, donc Vault down = plus aucun pod ne redémarre nulle part. Le SPOF passe du chemin de déploiement au chemin de run. Le Cas A du Test 8 n'existerait plus.

Les deux cohabitent (même Vault, même auth K8s, mêmes policies) : si un audit impose un jour zéro-secret-dans-etcd, on ajoute le webhook sur les apps concernées. Le coût de changement d'avis reste faible.

### Le dispatch multi-app en pratique

Ce que le POC démontre à deux composants se réplique tel quel :

**Par app**, le cas courant :

```yaml
spec:
  path: app-a/preprod
  destination: {name: app-a-secrets}
---
spec:
  path: app-b/preprod
  destination: {name: app-b-secrets}
```

Cloisonnement naturel : une policy par app, une app ne peut pas lire les secrets d'une autre.

**Plusieurs Secrets pour une même app**, si on veut séparer par domaine :

```yaml
envFrom:
  - secretRef: {name: app-a-db}
  - secretRef: {name: app-a-apis}
```

**Un secret partagé** entre plusieurs apps : un `VaultStaticSecret` par namespace pointant sur le même path Vault. Les CRs sont namespaced, ils ne traversent pas.

Ce qui se duplique par **namespace** : le ServiceAccount, le `VaultAuth`, un role Vault.
Ce qui se duplique par **Secret** : un `VaultStaticSecret`.

### Passage en production (hors POC)

Le mode dev ne se déploie pas. L'écart à combler :

- **Vault** : 3 VMs dédiées, hors des clusters K8s, storage Raft
- **Unseal** : auto-unseal via KMS (OVH KMS ou Scaleway Key Manager) — jamais de unseal manuel
- **Recovery keys** : 5 keys / seuil 3, distribuées, procédure de garde documentée
- **TLS** : cert-manager sur l'endpoint Vault
- **Auth** : une auth method par cluster (`k8s-serpent`, `k8s-dragon`), role par namespace
- **Token reviewer** : un SA `vault-reviewer` par cluster. Le JWT généré ici expire (8760h = 1 an) — à renouveler avant échéance, sinon toutes les auths du cluster s'arrêtent. À mettre sous alerte, ou à remplacer par un Secret de type `kubernetes.io/service-account-token` (token non-expirant, legacy mais valide)
- **Arborescence** : `kv/<cluster>/<app>/<env>/<composant>`
- **Filtrage `_raw`** : `SecretTransformation` avec `excludes: ["_raw"]` sur chaque `VaultStaticSecret`
- **Audit** : audit device fichier, shippé vers ELK
- **Backup** : snapshot Raft en cron (`vault operator raft snapshot save`) → GPG → OVH S3, même pattern que les backups Postgres. Restauration testée au moins une fois.
- **Monitoring** : `/v1/sys/metrics`, alerte sur `vault_core_unsealed == 0`
- **Dynamic secrets** : la suite logique pour les bases de données. Vault crée et révoque les comptes Postgres lui-même avec un TTL court — fini les mots de passe statiques à faire tourner à la main.

**Migration réelle** : les secrets déjà historisés dans Git sont à considérer comme compromis. Rotation obligatoire de tout ce qui est migré.

**Licence** : Vault est en BUSL 1.1 depuis août 2023. Usage interne = OK. Pour un usage type revente de Vault managé à des clients, basculer sur OpenBao (fork Linux Foundation, MPL 2.0, API-compatible, VSO fonctionne dessus).

### Liens utiles

```
https://developer.hashicorp.com/vault/docs/platform/k8s/vso
https://developer.hashicorp.com/vault/docs/auth/kubernetes
https://developer.hashicorp.com/vault/docs/secrets/kv/kv-v2
https://developer.hashicorp.com/vault/docs/secrets/databases/postgresql
https://blog.stephane-robert.info/docs/pipeline-cicd/argocd/installation/
```