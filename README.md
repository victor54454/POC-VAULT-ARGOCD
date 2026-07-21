# Secrets GitOps — Vault + VSO + ArgoCD

Gestion des secrets en GitOps **sans jamais les commiter** : HashiCorp Vault +
Vault Secrets Operator (VSO), injectés au déploiement via l'auth Kubernetes.
Puis passage en **production** (systemd, TLS, Raft, Shamir) avec accès humain
**SSO nominatif** (Keycloak OIDC) derrière un **proxy d'accès** (Teleport) et
**firewall**.

Ce dépôt contient **deux documentations**. Ce fichier est le point d'entrée : il
oriente vers la bonne selon ce que tu cherches.

## Quelle doc lire ?

| Tu veux… | Doc |
|---|---|
| Comprendre le **POC de base** (pourquoi Vault plutôt que SOPS, le principe VSO) | [Mode DEV + ArgoCD](./VAULT_MODE_DEV_ARGOCD.md) |
| Monter **de zéro** : cluster K8s, ArgoCD, l'app de test, VSO, Vault `-dev` | [Mode DEV + ArgoCD](./VAULT_MODE_DEV_ARGOCD.md) |
| Les **8 tests** de validation (rotation, révocation, audit, Vault down…) | [Mode DEV + ArgoCD](./VAULT_MODE_DEV_ARGOCD.md) |
| Passer **Vault en prod** : binaire systemd, TLS, Raft, unseal Shamir | [Mode PROD + Keycloak + Teleport](./VAULT_MODE_PROD_KEYCLOAK_TELEPORT_ARGOCD.md) |
| **Rebrancher le VSO** en HTTPS sur le nouveau Vault | [Mode PROD](./VAULT_MODE_PROD_KEYCLOAK_TELEPORT_ARGOCD.md) (§7) |
| **Gérer les clés** : rekey, rotate, révocation du root token | [Mode PROD](./VAULT_MODE_PROD_KEYCLOAK_TELEPORT_ARGOCD.md) (§9) |
| Ajouter le **SSO** : Keycloak (IdP OIDC) + auth OIDC Vault | [Mode PROD](./VAULT_MODE_PROD_KEYCLOAK_TELEPORT_ARGOCD.md) (§10-11) |
| Mettre **Teleport** devant Vault (accès + MFA + audit) | [Mode PROD](./VAULT_MODE_PROD_KEYCLOAK_TELEPORT_ARGOCD.md) (§12) |
| **Verrouiller** l'accès direct (firewall) | [Mode PROD](./VAULT_MODE_PROD_KEYCLOAK_TELEPORT_ARGOCD.md) (§13) |

## Ordre de lecture

Les deux docs se suivent : la seconde **suppose** que le POC de base tourne déjà.

1. **[VAULT_MODE_DEV&ARGOCD](./VAULT_MODE_DEV_ARGOCD.md)** — les fondations :
   cluster, ArgoCD, chart de test (nginx + postgres), VSO, Vault `-dev`, et les
   tests qui prouvent que les secrets ne transitent jamais par Git. À faire
   **en premier**.
2. **[VAULT_MODE_PROD_KEYCLOAK_TELEPORT&ARGOCD](./VAULT_MODE_PROD_KEYCLOAK_TELEPORT_ARGOCD.md)**
   — le durcissement : on remplace le Vault `-dev` par une installation prod, puis
   on ajoute SSO (Keycloak), proxy d'accès (Teleport) et firewall. Commence par
   son **§0 « Point de départ »** qui liste ce qui doit déjà exister.

## Architecture finale (cible de la doc PROD)

```
Humain → vault.teleport.local → [Teleport : login + MFA + audit de session]
       → UI Vault → OIDC → [Keycloak : SSO, realm infra, groupe vault-admins]
       → session Vault (policy admin)              ← zéro token, zéro compte Vault

VSO (pod) → Vault:8200 en direct                   ← autorisé par firewall (pods)
Reste du LAN → Vault:8200 refusé                   ← firewall deny
Admin de secours → generate-root + 3 unseal keys   ← si IdP / Teleport indisponible
```

## Stack

HashiCorp Vault 1.21.x (LTS) · Vault Secrets Operator · ArgoCD · Kubernetes ·
Keycloak 26.7 (IdP OIDC) · Teleport 17.x (App Access) · Calico · ufw

> **Licence Vault** : BUSL 1.1 (usage interne OK). Pour de la revente managée,
> basculer sur **OpenBao** (fork Linux Foundation, MPL 2.0, API-compatible).