# Fiche mémo — Écrire une policy Vault

Aide-mémoire pour écrire des policies sans tout retenir par cœur. On ne mémorise
pas la syntaxe (ça se retrouve) ; on comprend les **concepts** et les **pièges**.

---

## 1. La structure de base

Une policy = une liste de **règles**. Chaque règle = **où** (path) + **quoi**
(capabilities).

```hcl
path "<chemin API>" {
  capabilities = ["<opérations autorisées>"]
}
```

Une policy peut contenir **plusieurs blocs** `path` — c'est UN fichier, pas une
policy par besoin.

⚠️ C'est du **HCL**, pas du YAML. Le fichier se nomme `.hcl`.

---

## 2. Les capabilities (le « quoi »)

| Capability | Permet | Note |
|---|---|---|
| `read`   | lire une entrée | GET |
| `create` | créer du **nouveau** | ≠ update |
| `update` | modifier de l'**existant** | ≠ create ; aussi utilisé pour déclencher des *actions* |
| `delete` | supprimer | |
| `list`   | lister le contenu d'un dossier | pour la navigation / l'UI |
| `sudo`   | accéder aux chemins protégés/racine | sensible |
| `deny`   | **interdire** | prioritaire sur tout |
| `patch`  | modification partielle | rare |

**`create` vs `update`** : créer un secret qui n'existe pas ≠ écraser un secret
existant. En pratique, pour « écrire des secrets », mettre **les deux**.

---

## 3. LE concept le plus important : deny par défaut

> **Tout ce qui n'est pas explicitement autorisé est interdit.**

- Pour empêcher une opération → il suffit de **ne pas l'autoriser** (ne pas mettre
  `delete`, ne pas mettre les blocs UI…). Rien à écrire.
- Le `deny` **explicite** ne sert QUE pour bloquer une **exception** au milieu
  d'une autorisation large (ex. « accès à tout SAUF la prod »).

La sécurité d'une policy se juge autant à ce qu'on **n'y met pas** qu'à ce qu'on
y met. C'est le **moindre privilège**.

---

## 4. Le piège KV v2 : data ≠ metadata

En KV v2, un même secret est éclaté sur plusieurs sous-chemins d'API. Le chemin
CLI (`kv/poc/nginx`) n'est PAS le chemin de policy.

| Sous-chemin | Contient | Capabilities typiques |
|---|---|---|
| `kv/data/<x>`     | **les valeurs** du secret | read, create, update, delete |
| `kv/metadata/<x>` | **infos sur** le secret (versions, dates, inventaire), pas les valeurs | list, read, delete |
| `kv/delete/<x>`   | soft-delete d'une version (réversible) | update |
| `kv/undelete/<x>` | restaurer une version soft-deleted | update |
| `kv/destroy/<x>`  | destruction **définitive** d'une version | update |

- **`list` sur `kv/metadata/*`** = indispensable pour naviguer l'arborescence et
  pour que l'**UI** affiche les secrets. Sans lui : « no secrets » même avec le
  droit de lire les valeurs.
- **Ne jamais mettre `list` sur `data/`** — ça n'existe pas, le listing ne vit
  que sur `metadata/`.
- Intérêt de la séparation : donner « voir quels secrets existent » (metadata list)
  **sans** « lire leur contenu » (data read) → rôle auditeur.

### Les deux usages de `metadata`

Un même sous-chemin, deux capabilities, deux effets distincts :

| Capability sur `kv/metadata/...` | Ce que ça fait |
|---|---|
| `list` | voir les **noms** des clés d'un dossier (navigation) |
| `read` | voir l'**historique des versions** d'un secret précis |

### Les quatre façons de supprimer — et leur logique

| But | Chemin | Capability |
|---|---|---|
| soft delete d'une version | `kv/delete/...` | `update` |
| annuler un soft delete | `kv/undelete/...` | `update` |
| destroy d'une version | `kv/destroy/...` | `update` |
| tout effacer, secret + historique | `kv/metadata/...` | `delete` |

> `delete/`, `undelete/`, `destroy/` sont des **actions** qu'on déclenche →
> capability `update`.
> `metadata/` est un **objet** qu'on supprime → capability `delete`.

---

## 5. Moteur ≠ chemin (sys/mounts)

Deux niveaux à ne pas confondre :

- **Moteur** (armoire) = un espace de secrets monté, ex. `kv/`, `secret/`.
  Géré via `sys/mounts`.
- **Chemin/secret** (dossier dans l'armoire) = ex. `kv/poc/preprod/nginx`.
  Géré via `kv/data/...`.

`vault secrets list` → liste les **moteurs**. `vault kv list kv/` → liste le
**contenu** d'un moteur. Un `poc/` créé via `vault kv put kv/poc/...` est un
**chemin dans kv/**, PAS un moteur → il n'apparaît jamais dans `vault secrets list`.

### Règle générale « conteneur vs élément »

Pattern valable sur TOUS les chemins Vault :

| Chemin | Sens | Capabilities |
|---|---|---|
| `xxx` (sans nom final) | le **conteneur** → lister ce qu'il contient | `list` / `read` |
| `xxx/<élément>` ou `xxx/*` | un **élément** → agir dessus | `create` / `read` / `update` / `delete` |

Exemples : `sys/mounts` (lister les moteurs) vs `sys/mounts/*` (créer/supprimer un
moteur) ; `kv/metadata` vs `kv/metadata/nginx` ; `auth/token` vs
`auth/token/renew-self`.

### `sys/mounts` vs `sys/mounts/*` — le détail

Quatre chemins contiennent le mot « mounts » et font des choses différentes.
Deux axes seulement : **CLI ou UI**, et **liste ou détail**.

| Chemin | Client | Ce que ça donne |
|---|---|---|
| `sys/mounts` | CLI | la **liste** des moteurs |
| `sys/mounts/prod` | CLI | la **config** du moteur prod (type, TTL, options) |
| `sys/internal/ui/mounts` | UI | la **liste** des moteurs |
| `sys/internal/ui/mounts/prod` | UI | la **config** du moteur prod |

**`sys/mounts` (chemin nu)** — un seul objet : la liste. `vault secrets list`
tape dessus et reçoit tous les moteurs d'un coup :

```
cubbyhole/    cubbyhole
kv/           kv
prod/         kv
```

Capability : `read` — ⚠️ **pas `list`**, qui ne fait rien ici. Le token voit
quels moteurs existent, rien de plus. Inoffensif, on peut le donner largement.

**`sys/mounts/*` (wildcard)** — un objet par moteur, chacun avec sa propre
fiche (`sys/mounts/prod`, `sys/mounts/kv`) :

| Capability | Effet |
|---|---|
| `read` | lire la config du moteur (type, version KV, TTL, description) |
| `create` | **monter** un nouveau moteur à ce chemin |
| `update` | reconfigurer un moteur existant (tune) |
| `delete` | **démonter** le moteur — tous ses secrets disparaissent |

Privilège d'administrateur. Jamais dans une policy de dev.

> `sys/mounts` = le panneau d'affichage dans le hall, qui liste les portes.
> `sys/mounts/*` = les portes elles-mêmes, qu'on peut inspecter, poser ou arracher.

---

## 6. CLI et UI ne lisent pas les mêmes chemins

L'interface web n'appelle **pas** `sys/mounts`. Elle interroge un endpoint
interne dédié :

```hcl
# CLI — vault secrets list
path "sys/mounts" { capabilities = ["read"] }

# UI — affichage des tuiles de moteurs sur la page d'accueil
path "sys/internal/ui/mounts"   { capabilities = ["read"] }
path "sys/internal/ui/mounts/*" { capabilities = ["read"] }
```

Le wildcard est nécessaire côté UI (contrairement au CLI) parce que l'interface
charge automatiquement les détails de chaque moteur en affichant la page.

**Symptôme sans ces blocs** : l'UI n'affiche que `cubbyhole/` (toujours visible,
propre à chaque token) plus les moteurs que la policy nomme explicitement
ailleurs. Un moteur `prod/` absent de la policy reste invisible, même si le token
a des droits dessus par wildcard.

### Les trois niveaux de visibilité

Vault comme un immeuble :

1. **Voir les portes du couloir** → `sys/mounts` (CLI) et
   `sys/internal/ui/mounts` (UI). Je vois qu'il existe une porte `prod/` et une
   porte `kv/`. C'est tout, je ne sais pas ce qu'il y a derrière.
2. **Voir les tiroirs dans la pièce** → `kv/metadata/...` en `list`.
   J'ouvre `kv/`, je vois `poc/`, puis dedans `preprod/`, puis `postgres`.
3. **Lire le papier dans le tiroir** → `kv/data/poc/preprod/postgres` en `read`.

Sans le niveau 2, en UI la pièce paraît vide. En CLI ça marche quand même, parce
qu'on tape l'adresse directement sans parcourir les tiroirs.

---

## 7. Wildcards : `*` vs `+`

- **`*`** = tout ce qui suit, **toute profondeur**. Uniquement en **fin** de
  chemin. `kv/data/team/*` couvre `kv/data/team/nginx` ET `kv/data/team/prod/db`.
- **`+`** = **un seul segment**. Peut être au milieu. `kv/data/+/config` couvre
  `kv/data/app1/config` mais PAS `kv/data/app1/sub/config`.

Piège courant : mettre `+` en pensant `*` → la policy ne couvre plus les
sous-dossiers. Et inversement, `*/data/*` ne matche **rien** — `*` doit être le
dernier caractère.

### Les trois portées, en pratique

| Écriture | `app/db` | `app/backend/redis` |
|---|---|---|
| `prod/data/app` | non | non |
| `prod/data/app/+` | oui | non |
| `prod/data/app/*` | oui | oui |

Un slash orphelin (`prod/delete/app/`) ne matche rien d'utile : soit on s'arrête
avant, soit on continue avec `*`.

**Pour naviguer dans toute une arborescence, il faut souvent les deux formes :**

```hcl
path "prod/metadata/app"   { capabilities = ["list"] }   # le contenu de app/
path "prod/metadata/app/*" { capabilities = ["list"] }   # tout ce qui est en dessous
```

**Couvrir tous les moteurs, présents et futurs** : `+` remplace le nom du moteur.

```hcl
path "+/data/*"     { capabilities = ["create", "read", "update"] }
path "+/metadata/*" { capabilities = ["list", "read", "delete"] }
```

---

## 8. Les trois préfixes `sys/` d'administration

| Préfixe | Ce qu'on y gère | Note |
|---|---|---|
| `sys/mounts/*` | moteurs de secrets | — |
| `sys/auth/*` | méthodes d'authentification | **`sudo` obligatoire** |
| `sys/policies/acl/*` | policies ACL | **= root de fait** |

Sans `sudo`, `vault auth enable userpass` échoue même avec `create` :
l'activation et la désactivation d'une méthode d'auth sont root-protected.

```hcl
path "sys/auth/*" { capabilities = ["create", "read", "update", "delete", "sudo"] }
path "sys/auth"   { capabilities = ["read", "list"] }   # vault auth list
```

---

## 9. Escalade de privilèges par les policies

```hcl
path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
```

Le raisonnement en trois temps :

1. Le token a le droit d'**écrire** des policies.
2. Une policy, c'est ce qui **définit** les droits d'un token.
3. Donc il a le droit de **redéfinir ses propres droits**.

En une commande, il se donne tout :

```bash
vault policy write ma-policy - <<'EOF'
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF
```

**Conséquences :**

- Tout `deny` ailleurs dans sa policy devient cosmétique — il le réécrit.
- Pas de demi-mesure possible : restreindre à `sys/policies/acl/dev-*` ne suffit
  pas si le token peut aussi créer des tokens (`auth/token/create`) — il attache
  sa nouvelle policy à un token neuf et contourne.

**Règle : ce bloc en écriture = administrateur Vault, point.** Ça se justifie
pour un vrai admin, qui a de toute façon les clés de la maison. Jamais pour un
profil « un peu plus que dev ».

---

## 10. Chemins utiles à connaître

```hcl
# Un token renouvelle / consulte le SIEN (utile pour une CI)
path "auth/token/renew-self"  { capabilities = ["update"] }
path "auth/token/lookup-self" { capabilities = ["read"] }

# Liste des moteurs montés
path "sys/mounts" { capabilities = ["read"] }          # CLI
path "sys/internal/ui/mounts"   { capabilities = ["read"] }   # UI
path "sys/internal/ui/mounts/*" { capabilities = ["read"] }   # UI
```

---

## 11. Méthode pour écrire une policy

1. **Qui / quoi** doit agir ? (humain, CI, auditeur…)
2. **Sur quels secrets** ? (tout, un projet, un environnement…)
3. **Quelles opérations** ? (lire seul, gérer, administrer…)
4. Pour chaque zone : penser **data ET metadata** (KV v2).
5. Besoin d'un accès UI ? → ajouter `sys/internal/ui/mounts` **et** les `list`
   sur `metadata` des niveaux intermédiaires.
6. Ce qui doit être **interdit** → ne pas l'autoriser (deny par défaut).
7. Vérifier : guillemets autour des paths, tous les `}` fermés, orthographe de
   `capabilities`.

Tester ce qu'un token peut faire :

```bash
vault token capabilities <token> kv/data/poc/preprod/nginx
```

Écrire / lister / lire une policy :

```bash
vault policy write <nom> - <<'EOF'
... blocs ...
EOF

vault policy write <nom> fichier.hcl   # ou depuis un fichier

vault policy list
vault policy read <nom>
```

---

## 12. Se connecter et gérer les users

### Diagnostic

```bash
vault auth list                          # méthodes d'auth activées
vault secrets list                       # moteurs montés
vault policy list                        # policies existantes
vault list auth/userpass/users           # users userpass
vault read auth/userpass/users/victor    # ses policies, son TTL
```

### Se connecter

```bash
vault login -method=userpass username=victor
vault login -method=ldap username=victor
vault login <token>
```

**Sans écraser sa session root** (`vault login` écrit dans `~/.vault-token`) :

```bash
TOKEN=$(vault login -method=userpass username=victor -format=json | jq -r '.auth.client_token')
VAULT_TOKEN=$TOKEN vault secrets list
VAULT_TOKEN=$TOKEN vault kv list prod
```

### Créer / supprimer un user

```bash
vault write auth/userpass/users/victor \
  password="..." \
  token_policies="developer" \
  token_ttl="1h"

vault delete auth/userpass/users/victor
vault token revoke -mode=path auth/userpass/   # ⚠️ les tokens émis survivent au user
vault policy delete secrets-admin
```

Utiliser `token_policies` et non `policies` — c'est le champ moderne.

---

## 13. Erreurs classiques

| Erreur | Correction |
|---|---|
| `list` sur `data/` | Le listing est sur `metadata/` uniquement |
| Oublier `data/` dans le chemin | KV v2 : `prod/app/db` → `prod/data/app/db` |
| `*/data/*` | `*` doit être en **fin** de chemin → `+/data/*` |
| Slash orphelin `prod/delete/app/` | Soit `app`, soit `app/*` |
| `list` sur `sys/mounts` | C'est `read` qui renvoie la liste |
| `sys/mounts` pour l'UI | L'UI appelle `sys/internal/ui/mounts` |
| `delete` sur `data/` | La suppression passe par `delete/`, `destroy/` ou `metadata/` |
| Oublier `sudo` sur `sys/auth/*` | `vault auth enable` échoue |
| Faute de frappe `capabilites` | Vault refuse le fichier entier |
| Fichier nommé `.yaml` | C'est du **HCL** → `.hcl` |

---

## Exemples

### Lecture seule sur un projet

```hcl
path "kv/data/poc/*"     { capabilities = ["read"] }
path "kv/metadata/poc/*" { capabilities = ["list", "read"] }
```

### Gestion complète d'un projet, prod interdite (deny explicite)

```hcl
path "kv/data/app1/*"      { capabilities = ["create", "read", "update", "delete"] }
path "kv/metadata/app1/*"  { capabilities = ["list", "read", "delete"] }

# Exception : prod totalement bloquée (sur tous les sous-chemins)
path "kv/data/app1/prod/*"     { capabilities = ["deny"] }
path "kv/metadata/app1/prod/*" { capabilities = ["deny"] }
```

### Développeur (écrit sur prod, lit un seul secret ailleurs, aucun droit admin)

```hcl
# --- prod/ : lecture, écriture, navigation, historique. Aucune suppression. ---
path "prod/data/*"     { capabilities = ["create", "read", "update"] }
path "prod/metadata/*" { capabilities = ["list", "read"] }

# --- kv/ : lecture d'un seul secret ---
path "kv/data/poc/preprod/postgres" { capabilities = ["read"] }

# Navigation UI jusqu'à ce secret (expose les NOMS des voisins, pas leur contenu)
path "kv/metadata"             { capabilities = ["list"] }
path "kv/metadata/poc"         { capabilities = ["list"] }
path "kv/metadata/poc/preprod" { capabilities = ["list"] }

# --- Liste des moteurs. Pas de sys/mounts/* : aucun droit de monter/démonter. ---
path "sys/mounts"               { capabilities = ["read"] }
path "sys/internal/ui/mounts"   { capabilities = ["read"] }
path "sys/internal/ui/mounts/*" { capabilities = ["read"] }
```

### Compte machine CI/CD (lit cicd, écrit builds, jamais de delete, pas d'UI)

```hcl
path "kv/data/cicd/*"        { capabilities = ["read"] }
path "kv/data/cicd/builds/*" { capabilities = ["create", "update"] }

path "auth/token/renew-self"  { capabilities = ["update"] }
path "auth/token/lookup-self" { capabilities = ["read"] }

# Pas de delete, pas de sys/mounts → interdits par défaut (deny implicite)
```

### Admin Vault complet (`infra`)

```hcl
# --- Secrets : tous moteurs KV v2, existants et futurs ---
path "+/data/*"     { capabilities = ["create", "read", "update"] }
path "+/metadata/*" { capabilities = ["list", "read", "delete"] }
path "+/delete/*"   { capabilities = ["update"] }
path "+/undelete/*" { capabilities = ["update"] }
path "+/destroy/*"  { capabilities = ["update"] }

# --- Gestion des moteurs de secrets ---
path "sys/mounts/*" { capabilities = ["create", "read", "update", "delete"] }
path "sys/mounts"   { capabilities = ["read"] }

# --- Listing des moteurs dans l'UI ---
path "sys/internal/ui/mounts"   { capabilities = ["read"] }
path "sys/internal/ui/mounts/*" { capabilities = ["read"] }

# --- Policies ACL ---
# ATTENTION : ce bloc permet au porteur de réécrire sa propre policy,
# donc de s'octroyer tous les droits. Assumé : ce token est admin Vault.
# Conséquence : les blocs "deny" ci-dessous sont déclaratifs, pas contraignants.
path "sys/policies/acl/*" { capabilities = ["create", "read", "update", "delete", "list"] }

# --- Méthodes d'authentification (sudo requis) ---
path "sys/auth/*" { capabilities = ["create", "read", "update", "delete", "sudo"] }
path "sys/auth"   { capabilities = ["read", "list"] }

# --- Interdictions explicites (déclaratives, cf. bloc policies ci-dessus) ---
path "sys/seal"            { capabilities = ["deny"] }
path "sys/generate-root/*" { capabilities = ["deny"] }
```

---

## Organisation : un moteur unique vs un moteur par environnement

- **Un moteur, séparation par chemin** (`kv/prod/…`, `kv/preprod/…`) : simple,
  suffisant pour un POC. Séparation gérée par les wildcards de policy → plus
  fragile (une erreur de chemin expose un env).
- **Un moteur par environnement** (`prod/`, `preprod/` montés séparément) :
  frontière **dure**. Un compte sans policy sur `prod/` ne peut PAS y accéder,
  quelle que soit l'erreur de chemin. Recommandé pour isoler la prod. Coût : plus
  de config (chaque moteur a ses réglages/rotation/policies).

```bash
vault secrets enable -path=preprod kv-v2   # crée un moteur "preprod/"
vault kv put preprod/nginx ...             # y range un secret
```