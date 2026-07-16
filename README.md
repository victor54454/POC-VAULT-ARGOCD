## Partie 1 — L'app de test

→ Créer une mini-app avec des secrets en YAML & la convertir en chart Helm  
→ La connecter à ArgoCD (créer l'Application qui pointe sur le repo)

## Partie 2 — Le chiffrement

→ Installer SOPS + Age  
→ Chiffrer les values/secrets  
→ Configurer ArgoCD pour déchiffrer à la volée  
→ Tester le cycle complet via CI

## Pourquoi ce POC

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

Ce POC vient donc aider à comprendre si l'utilisation d'ArgoCD avec SOPS pourrait régler notre problème.

## Création d'une GitHub App

→ GitHub → ton profil → Settings → Developer settings → GitHub Apps → New GitHub App

![alt text](/photo/image.png)
![alt text](/photo/image-1.png)
![alt text](/photo/image-2.png)
![alt text](/photo/image-3.png)

Une fois cela fait, on peut voir que nous avons notre App ID : c'est la 1ère valeur.  
Il ne faut pas générer de client secret, ça sert à l'OAuth, pas pour ArgoCD. Ce qu'il nous faut, c'est une private key en .pem.

### → Générer la private key

Descends sur cette page General, plus bas que "Client secrets", tu vas trouver une section Private keys → clique Generate a private key. Ça télécharge un fichier .pem. C'est la 3ème valeur.

### → Installer l'App sur ton repo

Menu gauche → Install App → clique Install sur ton compte @victor54454 → choisis Only select repositories → sélectionne POC → valide.

### → Récupérer l'Installation ID

Après l'install, regarde l'URL du navigateur :

https://github.com/settings/installations/XXXXXXXX

Le nombre à la fin = ton Installation ID (2ème valeur).

## Une fois le repo connecté via la GitHub App

Maintenant on crée l'Application. + NEW APP (en haut à gauche) et remplis :

### General

→ Application Name : poc  
→ Project Name : default  
→ Sync Policy : Automatic  
→ Coche Prune Resources et Self Heal  
→ Coche Auto-Create Namespace

### Source

→ Repository URL : sélectionne https://github.com/victor54454/POC dans la liste déroulante  
→ Revision : main (ou ta branche)  
→ Path : . (si ton chart est à la racine du repo)

### Destination

→ Cluster URL : https://kubernetes.default.svc  
→ Namespace : poc

## Installation de SOPS + Age

Les versions ci-dessous sont celles utilisées au moment du POC. Pour récupérer les dernières versions, utiliser l'API GitHub des releases (voir les commandes `curl ... releases/latest` plus bas).

### → Installer Age

Récupérer la dernière version :

```bash
curl -s https://api.github.com/repos/FiloSottile/age/releases/latest | grep "browser_download_url.*linux-amd64"
```

Installer (ici v1.3.1) :

```bash
curl -Lo age.tar.gz https://github.com/FiloSottile/age/releases/download/v1.3.1/age-v1.3.1-linux-amd64.tar.gz
tar xf age.tar.gz
sudo mv age/age age/age-keygen /usr/local/bin/
rm -rf age age.tar.gz
age --version
age-keygen --version
```

### → Installer SOPS

Récupérer la dernière version :

```bash
curl -s https://api.github.com/repos/getsops/sops/releases/latest | grep "browser_download_url.*linux.amd64"
```

Installer (ici v3.13.1) :

```bash
curl -Lo sops https://github.com/getsops/sops/releases/download/v3.13.1/sops-v3.13.1.linux.amd64
chmod +x sops
sudo mv sops /usr/local/bin/sops
sops --version
```

## Cycle de chiffrement / déchiffrement

### → Générer la paire de clés Age

```bash
mkdir -p ~/sops-poc && cd ~/sops-poc
age-keygen -o age.key
cat age.key
```

Le `cat age.key` affiche :

- `# public key: age1...` → la clé publique (sert à chiffrer)
- `AGE-SECRET-KEY-1...` → la clé privée (sert à déchiffrer)

### → Créer un fichier de test à chiffrer

```bash
cat > secrets.yaml << 'EOF'
secrets:
  APP_SECRET: "mon-super-secret-applicatif"
  DATABASE_URL: "postgres://user:password123@db:5432/mydb"
  DOCKERHUB_TOKEN: "dckr_pat_exemple_token_12345"
EOF
```

### → Chiffrer avec SOPS + Age

Remplacer `age1xxxx...` par ta clé publique (celle affichée au `cat age.key`) :

```bash
sops --encrypt --age age1xxxxxxxx... secrets.yaml > secrets.enc.yaml
```

### → Regarder le résultat chiffré

```bash
cat secrets.enc.yaml
```

Les valeurs sont transformées en `ENC[AES256_GCM,data:...]` — illisibles.

### → Tester le déchiffrement

```bash
export SOPS_AGE_KEY_FILE=~/sops-poc/age.key
sops --decrypt secrets.enc.yaml
```

Les secrets sont réaffichés en clair — preuve que le cycle chiffrement/déchiffrement fonctionne.

## Architecture côté ArgoCD

ArgoCD ne sait pas déchiffrer SOPS nativement. On ajoute un plugin (CMP) dans le `argocd-repo-server` via un sidecar. Le sidecar contient SOPS + helm-secrets + la clé privée Age, et déchiffre `secrets.enc.yaml` au moment du sync.
argocd-repo-server (pod)

├── conteneur principal (repo-server)

└── sidecar CMP "helm-secrets"

├── image custom : helm + sops + helm-secrets + age

├── monte la clé Age (Secret sops-age)

├── monte le plugin.yaml (ConfigMap)

└── exécute "helm secrets template" au render

## → Le Secret avec la clé Age

On stocke la clé privée Age dans un Secret du namespace argocd. C'est cette clé que le sidecar utilise pour déchiffrer.

```bash
kubectl create secret generic sops-age \
  --from-file=keys.txt=$HOME/sops-poc/age.key \
  -n argocd
```

Le nom `keys.txt` est imposé par la convention SOPS (variable `SOPS_AGE_KEY_FILE`).

Vérification :

```bash
kubectl get secret sops-age -n argocd -o jsonpath='{.data}' | jq 'keys'
# doit afficher ["keys.txt"]
```

## → L'image custom du sidecar

L'image de base ArgoCD ne contient ni sops, ni helm-secrets, ni curl. On build une image custom qui les ajoute. Ilfaut juste builder sont images et la push sur un repo docker hub sur le qu'elle nous avons accée et que nous pourrons pull c'est images facilement. 

```bash
touch Dockerfile
```

Dockerfile :

```dockerfile
# Image de base officielle ArgoCD (contient argocd-cmp-server)
# Le tag DOIT correspondre à la version d'ArgoCD (v2.14.9)
FROM quay.io/argoproj/argocd:v2.14.9

USER root

# curl + ca-certificates (absents de l'image de base)
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Versions figées pour la reproductibilité
ENV HELM_VERSION=v3.21.2
ENV SOPS_VERSION=v3.13.1
ENV AGE_VERSION=v1.3.1
ENV HELM_SECRETS_VERSION=v4.7.7

# Helm
RUN curl -fsSL -o /tmp/helm.tar.gz "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
    && tar -xzf /tmp/helm.tar.gz -C /tmp \
    && mv /tmp/linux-amd64/helm /usr/local/bin/helm \
    && chmod +x /usr/local/bin/helm \
    && rm -rf /tmp/helm.tar.gz /tmp/linux-amd64

# SOPS
RUN curl -fsSL -o /usr/local/bin/sops "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64" \
    && chmod +x /usr/local/bin/sops

# Age
RUN curl -fsSL -o /tmp/age.tar.gz "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-amd64.tar.gz" \
    && tar -xzf /tmp/age.tar.gz -C /tmp \
    && mv /tmp/age/age /usr/local/bin/age \
    && mv /tmp/age/age-keygen /usr/local/bin/age-keygen \
    && chmod +x /usr/local/bin/age /usr/local/bin/age-keygen \
    && rm -rf /tmp/age.tar.gz /tmp/age

# helm-secrets (installé pour l'utilisateur argocd, UID 999)
USER 999
ENV HELM_PLUGINS=/home/argocd/.local/share/helm/plugins
RUN helm plugin install https://github.com/jkroepke/helm-secrets --version ${HELM_SECRETS_VERSION}
```

Build + push sur DockerHub :

```bash
docker login
docker build -t victor54454/argocd-cmp-helm-secrets:v1.0.0 .
docker push victor54454/argocd-cmp-helm-secrets:v1.0.0
```

## → Le plugin.yaml (ConfigManagementPlugin)

Le manifest qui dit au sidecar comment détecter les apps et générer les manifests. Stocké dans une ConfigMap.

Fichier `cmp-plugin.yaml` :

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cmp-helm-secrets-plugin
  namespace: argocd
data:
  plugin.yaml: |
    apiVersion: argoproj.io/v1alpha1
    kind: ConfigManagementPlugin
    metadata:
      name: helm-secrets
    spec:
      version: v1.0
      init:
        command: [bash, -c]
        args:
          - |
            helm dependency build || true
      generate:
        command: [bash, -c]
        args:
          - |
            set -euo pipefail
            HELM_ARGS=("-f" "values.yaml")
            if [ -f "secrets.enc.yaml" ]; then
              HELM_ARGS+=("-f" "secrets://secrets.enc.yaml")
            fi
            helm secrets template "$ARGOCD_APP_NAME" . \
              --namespace "$ARGOCD_APP_NAMESPACE" \
              --include-crds \
              "${HELM_ARGS[@]}"
      discover:
        fileName: "Chart.yaml"
```

- **init** : `helm dependency build` télécharge les sous-charts (le `|| true` évite l'échec s'il n'y en a pas)
- **generate** : construit la liste des values, ajoute `secrets.enc.yaml` avec le préfixe `secrets://` qui déclenche le déchiffrement, puis lance `helm secrets template`
- **discover** : ArgoCD utilise ce plugin dès qu'il trouve un `Chart.yaml`

Application :

```bash
kubectl apply -f cmp-plugin.yaml
```

## → Patcher le argocd-repo-server

On ajoute le sidecar via les values Helm du chart argo-cd. Fichier `argocd-values.yaml` :

```yaml
repoServer:
  # Volumes partagés pour le sidecar CMP
  volumes:
    - name: cmp-helm-secrets-plugin
      configMap:
        name: cmp-helm-secrets-plugin
    - name: cmp-tmp
      emptyDir: {}
    - name: sops-age
      secret:
        secretName: sops-age

  # Le sidecar CMP
  extraContainers:
    - name: cmp-helm-secrets
      image: victor54454/argocd-cmp-helm-secrets:v1.0.0
      imagePullPolicy: Always
      command: ["/var/run/argocd/argocd-cmp-server"]
      env:
        - name: SOPS_AGE_KEY_FILE
          value: /home/argocd/sops-age/keys.txt
        - name: HELM_SECRETS_BACKEND
          value: sops
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
      volumeMounts:
        - name: var-files
          mountPath: /var/run/argocd
        - name: plugins
          mountPath: /home/argocd/cmp-server/plugins
        - name: cmp-tmp
          mountPath: /tmp
        - name: cmp-helm-secrets-plugin
          mountPath: /home/argocd/cmp-server/config/plugin.yaml
          subPath: plugin.yaml
        - name: sops-age
          mountPath: /home/argocd/sops-age
          readOnly: true
```

Points importants :

- `SOPS_AGE_KEY_FILE` pointe vers le chemin DANS le conteneur (où le Secret sops-age est monté), pas un chemin de la VM
- `var-files` et `plugins` sont des volumes déjà définis par le chart ArgoCD, on les réutilise
- `command` lance le binaire `argocd-cmp-server` copié par l'init container du repo-server

Application :

```bash
helm upgrade argocd argo/argo-cd \
  --namespace argocd \
  --version 7.8.23 \
  --reuse-values \
  -f argocd-values.yaml
```

Le `--reuse-values` garde les réglages précédents (NodePort, insecure) et ajoute juste le sidecar.

Vérification — le repo-server doit passer à 2/2 :

```bash
kubectl rollout status deployment/argocd-repo-server -n argocd
kgp argocd
```

Logs du sidecar pour confirmer que le plugin tourne :

```bash
kubectl logs -n argocd -l app.kubernetes.io/component=repo-server -c cmp-helm-secrets --tail=30
# doit afficher : argocd-cmp-server ... serving on .../helm-secrets-v1.0.sock
```

## → Préparer le repo POC

Structure finale :
POC/

├── Chart.yaml

├── values.yaml          ← valeurs publiques (PAS de secrets)

├── secrets.enc.yaml     ← les secrets, chiffrés SOPS

├── templates/

│   ├── deployment.yaml

│   ├── secret.yaml

│   └── service.yaml

Le `values.yaml` ne contient plus les secrets :

```yaml
replicaCount: 1
image:
  repository: nginx
  tag: "1.27-alpine"
  pullPolicy: IfNotPresent
service:
  type: NodePort
  port: 80
  nodePort: 30000
```

Le `templates/secret.yaml` lit `.Values.secrets.*` (valeurs injectées par le plugin après déchiffrement) :

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: {{ .Release.Name }}-secrets
type: Opaque
stringData:
  APP_SECRET: {{ .Values.secrets.APP_SECRET | quote }}
  DATABASE_URL: {{ .Values.secrets.DATABASE_URL | quote }}
  DOCKERHUB_TOKEN: {{ .Values.secrets.DOCKERHUB_TOKEN | quote }}
```

On copie `secrets.enc.yaml` (chiffré) à la racine du repo, puis push :

```bash
git add .
git commit -m "Ajout secrets chiffres SOPS, values nettoye"
git push
```

## → Recréer l'application en mode plugin

L'app POC utilisait le Helm natif (values inline). Pour qu'elle utilise le sidecar et déchiffre, il faut la basculer en mode plugin. On supprime l'app et on la recrée.

Suppression via l'UI : app poc → DELETE.

Recréation via + NEW APP :

### General

→ Application Name : poc  
→ Project Name : default  
→ Sync Policy : Automatic  
→ Coche Prune Resources et Self Heal  
→ Coche Auto-Create Namespace

### Source

→ Repository URL : https://github.com/victor54454/POC (attention à ne pas laisser d'espace au début)  
→ Revision : main  
→ Path : .  
→ Dans la liste déroulante du type de source, sélectionner Plugin → helm-secrets-v1.0

### Destination

→ Cluster URL : https://kubernetes.default.svc  
→ Namespace : poc

L'app passe en Synced + Healthy. Le sidecar a déchiffré secrets.enc.yaml et créé le Secret poc-secrets.

## Validation du POC

### → Test 1 — le secret est bien déchiffré dans le cluster

```bash
kubectl get secret poc-secrets -n poc -o jsonpath='{.data.APP_SECRET}' | base64 -d
# affiche : mon-super-secret-applicatif
```

### → Test 2 — l'API ArgoCD ne renvoie plus aucun secret

On récupère un token et on interroge l'API :

```bash
ARGOCD_TOKEN=$(curl -k -s http://192.168.10.169:30080/api/v1/session \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"MOT_DE_PASSE"}' | jq -r .token)

curl -k -s "http://192.168.10.169:30080/api/v1/applications/poc" \
  -H "Authorization: Bearer $ARGOCD_TOKEN" | jq . | grep 'APP_SECRET'
# résultat vide → aucun secret exposé
```

Le `spec.source` ne contient que la référence au plugin (`sourceType: Plugin`), aucun values inline, aucun secret. Le `-o /dev/null` dans les CI devient inutile : l'API n'a plus rien de sensible à renvoyer.

## Liens utiles

```
https://blog.stephane-robert.info/docs/pipeline-cicd/argocd/installation/
```