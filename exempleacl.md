# Vault — Exercices sur les policies ACL

Série d'exercices d'entraînement sur l'écriture des policies HashiCorp Vault (moteurs KV v2).

---

## Exercice 1

> Écris le bloc `path` qui permet de lire le secret dont le chemin CLI est `prod/app/db`. Rien d'autre : pas d'écriture, pas de listing.
>
> Rappel du seul truc à savoir ici : en KV v2, le chemin CLI `prod/app/db` devient `prod/data/app/db` dans la policy.

```hcl
path "prod/data/app/db" {
  capabilities = ["read"]
}
```

---

## Exercice 2

> Écris le bloc qui permet de lister les secrets contenus dans le dossier `prod/app/` — c'est-à-dire voir les noms `db`, `api`, etc.
>
> Rappel : le listing ne passe jamais par `data`.

```hcl
path "prod/metadata/app/*" {
  capabilities = ["list"]
}
```

### Correction

`prod/metadata/app/*` couvre ce qui est **sous** `app/` mais pas dans `app/` lui-même. Donc on peut lister `app/backend/` mais pas directement dans `app/`.

```hcl
path "prod/metadata/app/*" {
  capabilities = ["list"]
}

path "prod/metadata/app" {
  capabilities = ["list"]
}
```

On met les deux en pratique, comme ça on peut aussi voir plus loin que `app/`.

---

## Exercice 3

> Écris le bloc qui permet de créer et modifier les secrets situés n'importe où sous `prod/app/`.

```hcl
path "prod/data/app/*" {
  capabilities = ["create", "update"]
}
```

### Correction

C'est bon — juste, en pratique on ajoute un `read` en plus.

```hcl
path "prod/data/app/*" {
  capabilities = ["create", "update", "read"]
}
```

---

## Exercice 4

> Écris le bloc qui permet de faire un soft delete (suppression réversible d'une version) sur les secrets sous `prod/app/`.
>
> Rappel : le soft delete a son propre segment de chemin, et la capability n'est pas `delete`.

```hcl
path "prod/delete/app/*" {
  capabilities = ["update"]
}
```

---

## Exercice 5

> Écris le bloc qui permet la suppression définitive (destroy) d'une version d'un secret sous `prod/app/`.
>
> Même logique que l'exercice 4 : segment dédié, capability qui n'est pas celle qu'on croit.

```hcl
path "prod/destroy/app/*" {
  capabilities = ["update"]
}
```

---

## Exercice 6

> Écris le bloc qui permet de supprimer les métadonnées d'un secret sous `prod/app/` — c'est-à-dire effacer le secret et tout son historique de versions d'un coup.
>
> Attention : ici, contrairement aux exercices 4 et 5, ce n'est pas `update`.

```hcl
path "prod/metadata/app/*" {
  capabilities = ["delete"]
}
```

---

## Exercice 7

> Écris le bloc qui permet d'annuler une suppression sous `prod/app/`.

```hcl
path "prod/undelete/app/*" {
  capabilities = ["update"]
}
```

---

## Exercice 8

> Écris le bloc qui permet de voir la liste des moteurs de secrets montés, **en CLI uniquement**.
>
> Rappel : ce chemin vit sous `sys/`, et la capability n'est pas `list`.

```hcl
path "sys/mounts" {
  capabilities = ["read"]
}
```

---

## Exercice 9

> Écris les blocs qui permettent à l'UI d'afficher la liste des moteurs. Il en faut deux.

```hcl
path "sys/internal/ui/mounts" {
  capabilities = ["read"]
}

path "sys/internal/ui/mounts/*" {
  capabilities = ["read"]
}
```

---

## Exercice 10

> Écris le bloc qui permet de monter, configurer et démonter n'importe quel moteur de secrets.

```hcl
path "sys/mounts/*" {
  capabilities = ["create", "delete", "update", "read"]
}
```

---

## Exercice 11

> Écris le bloc qui permet de gérer les policies ACL — les lire, les créer, les modifier, les supprimer, et voir la liste de toutes celles qui existent.
>
> Rappel de l'énoncé `infra` du départ : c'est ce bloc qui permet à son porteur de s'auto-élever. Une fois écrit, dis-moi pourquoi.

```hcl
path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
```

### Pourquoi ?

Cette policy, si elle est donnée à une personne mal intentionnée, lui permet de créer une policy qui lui donne accès à tout et donc de s'auto-élever. C'est pour ça qu'il faut faire attention à qui on donne cette policy.

Il pourrait donc faire cela :

```bash
vault policy write infra - <<'EOF'
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF
```

Il vient de se donner tous les droits sur tout Vault. Il pourrait aussi écrire une nouvelle policy. Autrement dit, donner cette policy à une personne, c'est comme lui donner le root access.

---

## Exercice 12

> Écris le bloc qui permet de gérer les méthodes d'authentification — activer, configurer et désactiver.
>
> Même structure que l'exercice 10, autre préfixe.

```hcl
path "sys/auth/*" {
  capabilities = ["create", "read", "update", "delete", "sudo"]
}

path "sys/auth" {
  capabilities = ["read", "list"]
}
```

### Deux points à noter

**`sudo` est obligatoire ici.** Contrairement à `sys/mounts/*`, l'activation et la désactivation d'une méthode d'auth sont considérées comme des opérations root-protected. Sans `sudo`, `vault auth enable userpass` échoue même avec `create`.

**Le second bloc sert au listing.** `sys/auth` sans wildcard permet de voir les méthodes déjà activées (`vault auth list`).

### Récap des trois préfixes `sys/`

| Préfixe | Ce qu'on y gère |
|---|---|
| `sys/mounts/*` | moteurs de secrets |
| `sys/auth/*` | méthodes d'authentification (+ `sudo`) |
| `sys/policies/acl/*` | policies ACL (= root de fait) |

---

## Exercice 13 — Policy `infra`

> Le token doit pouvoir :
>
> 1. Sur tous les moteurs KV v2 existants et à venir : toutes les opérations sur les secrets, y compris soft delete, undelete, destroy, et suppression des métadonnées.
> 2. Monter, configurer, remonter et démonter n'importe quel moteur de secrets.
> 3. Lister les moteurs montés en CLI et en UI.
> 4. Lire, écrire et supprimer des policies ACL.
> 5. Gérer les méthodes d'authentification (activer, configurer, désactiver).
> 6. Il ne doit pas pouvoir sceller le Vault ni générer de root token.
>
> Contraintes : utilise un wildcard qui couvre les moteurs futurs sans les nommer un par un. Indique en commentaire, sur le bloc concerné, quel privilège permet à ce token de s'auto-élever — et pourquoi tu l'acceptes ou non.

```hcl
# --- Secrets : tous moteurs KV v2, existants et futurs ---
path "+/data/*" {
  capabilities = ["create", "update", "read"]
}
path "+/delete/*" { 
  capabilities = ["update"]
}
path "+/destroy/*" {
  capabilities = ["update"]
}
path "+/undelete/*" {
  capabilities = ["update"]
}
path "+/metadata/*" {
  capabilities = ["read", "list", "delete"]
}

# --- Gestion des moteurs de secrets ---
path "sys/mounts/*" {
  capabilities = ["read", "create", "update", "delete"]
}
path "sys/mounts" {
  capabilities = ["read"]
}

# --- Listing des moteurs dans l'UI ---
path "sys/internal/ui/mounts/*" {
  capabilities = ["read"]
}
path "sys/internal/ui/mounts" {
  capabilities = ["read"]
}

# --- Policies ACL ---
# ATTENTION : ce bloc permet au porteur de réécrire sa propre policy,
# donc de s'octroyer tous les droits. Assumé : ce token est admin Vault.
# Conséquence : les blocs "deny" ci-dessous sont déclaratifs, pas contraignants.
path "sys/policies/acl/*" {
  capabilities = ["read", "create", "delete", "update", "list"]
}

# --- Méthodes d'authentification (sudo requis) ---
path "sys/auth/*" {
  capabilities = ["create", "read", "update", "delete", "sudo"]
}
path "sys/auth" {
  capabilities = ["read", "list"]
}

# --- Interdictions explicites ---
path "sys/seal" {
  capabilities = ["deny"]
}
path "sys/generate-root/*" {
  capabilities = ["deny"]
}
```

## Exercice 14 - Policy `dev`
> Le token doit pouvoir :
>
> 1. Sur le moteur prod/ (KV v2) : lire n'importe quel secret, en créer de nouveaux, mettre à jour ceux qui existent, lister les clés à n'importe quel niveau de l'arborescence, et consulter l'historique des versions.
> 2. Il ne doit pas pouvoir supprimer un secret (ni soft delete, ni destroy, ni suppression de métadonnées) sur prod/.
> 3. Sur kv/, il a un unique accès : lecture du secret situé au chemin CLI kv/poc/preprod/postgres. Rien d'autre en lecture, rien en écriture.
> 4. Il doit pouvoir naviguer jusqu'à ce secret depuis l'UI (donc lister les niveaux intermédiaires de kv/).
> 5. Il ne doit pouvoir ni créer, ni modifier, ni supprimer un moteur de secrets.
> 6. Il doit voir la liste des moteurs montés, en CLI comme en UI.
>
> Contraintes : n'accorde aucune capability qui ne soit pas exigée par un des points ci-dessus. Justifie en commentaire chaque bloc sys/.
```hcl
path "prod/data/*" {
  capabilities = ["create", "update", "read"]
}
path "prod/metadata/*" {
  capabilities = ["read", "list"]
}

path "kv/data/poc/preprod/postgres" {
  capabilities = ["read"]
}

path "kv/metadata" {capabilities = ["list"]}
path "kv/metadata/poc" {capabilities = ["list"]}
path "kv/metadata/poc/preprod" {capabilities = ["list"]}
path "kv/metadata/poc/preprod/postgres" {capabilities = ["list"]}

path "sys/internal/ui/mounts/*" {
  capabilities = ["read"]
}
path "sys/internal/ui/mounts" {
  capabilities = ["read"]
}


path "sys/mounts" {
  capabilities = ["read"]
}
```