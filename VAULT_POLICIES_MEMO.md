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
- Intérêt de la séparation : donner « voir quels secrets existent » (metadata list)
  **sans** « lire leur contenu » (data read) → rôle auditeur.

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

---

## 6. Wildcards : `*` vs `+`

- **`*`** = tout ce qui suit, **toute profondeur**. Uniquement en **fin** de
  chemin. `kv/data/team/*` couvre `kv/data/team/nginx` ET `kv/data/team/prod/db`.
- **`+`** = **un seul segment**. Peut être au milieu. `kv/data/+/config` couvre
  `kv/data/app1/config` mais PAS `kv/data/app1/sub/config`.

Piège courant : mettre `+` en pensant `*` → la policy ne couvre plus les
sous-dossiers.

---

## 7. Chemins utiles à connaître

```hcl
# Un token renouvelle / consulte le SIEN (utile pour une CI)
path "auth/token/renew-self"  { capabilities = ["update"] }
path "auth/token/lookup-self" { capabilities = ["read"] }

# L'UI liste les moteurs montés
path "sys/mounts" { capabilities = ["read", "list"] }
```

---

## 8. Méthode pour écrire une policy

1. **Qui / quoi** doit agir ? (humain, CI, auditeur…)
2. **Sur quels secrets** ? (tout, un projet, un environnement…)
3. **Quelles opérations** ? (lire seul, gérer, administrer…)
4. Pour chaque zone : penser **data ET metadata** (KV v2).
5. Ce qui doit être **interdit** → ne pas l'autoriser (deny par défaut).
6. Vérifier : guillemets autour des paths, tous les `}` fermés.

Tester ce qu'un token peut faire :
```bash
vault token capabilities <token> kv/data/poc/preprod/nginx
```

Écrire / lister / lire une policy :
```bash
vault policy write <nom> - <<'EOF'
... blocs ...
EOF
vault policy list
vault policy read <nom>
```

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

### Lead d'équipe (gère son équipe, lit le partagé, crée des moteurs, UI)
```hcl
path "kv/data/team-alpha/*"     { capabilities = ["read", "create", "update", "delete"] }
path "kv/metadata/team-alpha/*" { capabilities = ["list", "read", "delete"] }

path "kv/data/shared/*"     { capabilities = ["read"] }
path "kv/metadata/shared/*" { capabilities = ["list", "read"] }

path "sys/mounts/*" { capabilities = ["create", "read", "update", "delete"] }
path "sys/mounts"   { capabilities = ["read"] }
```

### Compte machine CI/CD (lit cicd, écrit builds, jamais de delete, pas d'UI)
```hcl
path "kv/data/cicd/*"        { capabilities = ["read"] }
path "kv/data/cicd/builds/*" { capabilities = ["create", "update"] }

path "auth/token/renew-self"  { capabilities = ["update"] }
path "auth/token/lookup-self" { capabilities = ["read"] }

# Pas de delete, pas de sys/mounts → interdits par défaut (deny implicite)
```

### Admin des secrets (tous les KV + créer des moteurs, mais pas admin de Vault)
```hcl
path "kv/data/*"     { capabilities = ["create", "read", "update", "delete"] }
path "kv/metadata/*" { capabilities = ["list", "read", "delete"] }
path "kv/delete/*"   { capabilities = ["update"] }
path "kv/undelete/*" { capabilities = ["update"] }
path "kv/destroy/*"  { capabilities = ["update"] }

path "sys/mounts"   { capabilities = ["read", "list"] }
path "sys/mounts/*" { capabilities = ["create", "read", "update", "delete"] }
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