# Vault — utilisateur userpass + MFA TOTP

Créer un compte local **userpass** dans Vault (login + mot de passe), avec une
**policy** sur mesure et un **MFA TOTP** bloquant à la connexion.

> **Quand l'utiliser.** Le montage principal privilégie l'OIDC (Keycloak) pour
> ne stocker aucun compte dans Vault. `userpass` réintroduit un compte **local à
> Vault** — utile comme compte d'administration indépendant de l'IdP, ou en accès
> de secours. Le MFA TOTP (Login MFA) est disponible en Vault **open-source
> depuis 1.10** ; ici testé en 1.21.4.

## Prérequis

- Vault descellé et **accès admin** (session `generate-root` + 3 unseal keys si le
  root est révoqué) :
  ```bash
  export VAULT_ADDR="https://192.168.10.179:8200"
  export VAULT_CACERT="$HOME/vault-ca.crt"
  vault operator generate-root -init
  vault operator generate-root -nonce=<NONCE> <unseal-key-1>
  vault operator generate-root -nonce=<NONCE> <unseal-key-2>
  vault operator generate-root -nonce=<NONCE> <unseal-key-3>
  vault operator generate-root -decode=<ENCODED_TOKEN> -otp=<OTP>
  vault login <le-token>
  ```

---

## 1. Policy sur mesure

Ne pas attacher la policy `admin` (`path "*"` + `sudo`) à un compte de gestion de
secrets — trop large. Créer une policy ciblée. Exemple **gestionnaire de secrets
qui peut aussi créer de nouveaux moteurs KV** :

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

# --- Créer et gérer des moteurs de secrets (nouveaux espaces KV) ---
path "sys/mounts" {
  capabilities = ["read", "list"]
}
path "sys/mounts/*" {
  capabilities = ["create", "read", "update", "delete"]
}
EOF
```

> Notes de portée : `kv/data/*` = les secrets (KV v2 range les valeurs sous
> `data/`) ; `kv/metadata/*` avec `list` = indispensable pour que l'UI affiche
> l'arborescence et les versions ; `sys/mounts/*` = créer/supprimer des moteurs.
> **Pas de `sudo`, pas de `sys/*` large** : ce compte gère les secrets, pas la
> config de Vault. Pour restreindre à un périmètre, remplacer `kv/data/*` par
> `kv/data/<projet>/*`.

Voir les policies existantes : `vault policy list` · contenu : `vault policy read <nom>`.

---

## 2. Activer userpass + créer l'utilisateur

```bash
vault auth enable userpass          # une seule fois pour le cluster

vault write auth/userpass/users/victor \
  password="<mot-de-passe-fort>" \
  token_policies="secrets-admin" \
  token_ttl="1h"
```

---

## 3. Entity + alias (nécessaire pour attacher le MFA)

Le TOTP s'attache à une **entity**, créée automatiquement au premier login — mais
pour enrôler **avant** le premier login, on la crée à la main. L'**alias** relie
l'entity au user userpass (sans lui, le TOTP ne s'appliquerait pas).

```bash
# Accessor de la méthode userpass (à réutiliser plus bas)
USERPASS_ACCESSOR=$(vault auth list -format=json | jq -r '.["userpass/"].accessor')
echo "$USERPASS_ACCESSOR"          # ex. auth_userpass_3f1e7f96

# Créer l'entity
vault write identity/entity name="victor" policies="secrets-admin"
ENTITY_ID=$(vault read -field=id identity/entity/name/victor)
echo "$ENTITY_ID"

# Lier l'entity au user userpass "victor"
vault write identity/entity-alias \
  name="victor" \
  canonical_id="$ENTITY_ID" \
  mount_accessor="$USERPASS_ACCESSOR"
```

---

## 4. Méthode MFA TOTP + enforcement

> ⚠️ **Piège algorithme (rencontré).** Créer la méthode en **SHA1**, pas SHA256.
> La plupart des apps (Google Authenticator en tête) génèrent en SHA1 en saisie
> manuelle et **ignorent** un paramètre SHA256 → les codes sont refusés
> (`failed to validate TOTP passcode`). SHA1 est le standard de facto, compatible
> partout. (FreeOTP/Authy gèrent SHA256, mais SHA1 évite le problème.)

```bash
# Créer la méthode TOTP (SHA1) → renvoie un method_id
vault write identity/mfa/method/totp \
  issuer="Vault" \
  period=30 \
  key_size=20 \
  algorithm=SHA1 \
  digits=6

vault list identity/mfa/method/totp          # récupérer le method_id (UUID)
```

Lier le MFA à la méthode userpass (**enforcement** — rend le TOTP obligatoire à
chaque login userpass) :

```bash
vault write identity/mfa/login-enforcement/userpass-mfa \
  mfa_method_ids="<METHOD_ID>" \
  auth_method_accessors="$USERPASS_ACCESSOR"
```

---

## 5. Enrôler l'utilisateur (générer le secret TOTP)

```bash
vault write identity/mfa/method/totp/admin-generate \
  method_id="<METHOD_ID>" \
  entity_id="$ENTITY_ID"
```

Renvoie :
- **`url`** : `otpauth://totp/...?algorithm=SHA1&...&secret=XXXX` — le champ
  `secret` est ce qu'on saisit dans l'app.
- **`barcode`** : QR code en base64 (souvent corrompu au copier-coller — préférer
  la saisie manuelle du `secret`).

**Dans l'app d'authentification** (Google Authenticator, Authy, FreeOTP…) :
ajouter un compte → *saisir une clé de configuration* → coller le `secret` → type
*basé sur le temps (TOTP)*.

> **Un seul secret à la fois par entity.** Un 2ᵉ `admin-generate` renvoie
> `Entity already has a secret for MFA method`. Pour regénérer (ex. après un
> changement d'algorithme), détruire d'abord :
> ```bash
> vault write identity/mfa/method/totp/admin-destroy \
>   method_id="<METHOD_ID>" entity_id="$ENTITY_ID"
> ```
> Pour changer l'algo d'une méthode existante, l'écrire sur son ID (garde le même
> method_id, l'enforcement reste valide) :
> ```bash
> vault write identity/mfa/method/totp/<METHOD_ID> \
>   issuer="Vault" period=30 key_size=20 algorithm=SHA1 digits=6
> ```

---

## 6. Tester le login

```bash
vault login -method=userpass username=victor
# → mot de passe, puis :
# Initiating Interactive MFA Validation...
# Enter the passphrase for methodID "<...>" of type "totp": <code 6 chiffres>
```

Ou via l'**UI Vault** : méthode **Userpass** → login + mot de passe → l'UI demande
le **code TOTP**. Code accepté → token avec la policy `secrets-admin`.

**Si le code est refusé :**
- Algorithme SHA256 au lieu de SHA1 (cause n°1) → §4/§5 pour recréer en SHA1.
- Décalage d'horloge : le TOTP travaille en temps **absolu** (pas le fuseau) — une
  VM en UTC et un téléphone en heure locale sont alignés. Vérifier seulement que
  l'horloge est **synchronisée** :
  ```bash
  timedatectl status | grep -E 'synchronized|NTP'   # → yes / active
  ```

---

## 7. Durcissement — rate limit anti-brute-force

Le Login MFA de Vault **ne limite pas** le brute-force des codes TOTP par défaut.
Appliquer un quota de débit sur les chemins de login et de validation MFA :

```bash
vault write sys/quotas/rate-limit/userpass-login \
  path="auth/userpass/login" \
  rate=5 interval="1m"

vault write sys/quotas/rate-limit/mfa-validate \
  path="sys/mfa/validate" \
  rate=5 interval="1m"
```

> Ajuste `rate`/`interval` selon le besoin. 5 tentatives/minute bloque le
> brute-force sans gêner un usage normal.

---

## Récapitulatif des objets créés

| Objet | Rôle |
|---|---|
| policy `secrets-admin` | droits du compte (secrets + moteurs KV) |
| `auth/userpass/users/victor` | le compte (login + mot de passe) |
| entity `victor` + entity-alias | identité stable, support du MFA |
| `identity/mfa/method/totp` (SHA1) | la méthode TOTP |
| `identity/mfa/login-enforcement/userpass-mfa` | rend le TOTP obligatoire |
| secret TOTP (admin-generate) | enrôlé dans l'app de l'utilisateur |
| quotas rate-limit | anti-brute-force |