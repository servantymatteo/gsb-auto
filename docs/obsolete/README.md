# Fichiers Obsolètes

Ce dossier contient les fichiers et scripts obsolètes qui ne sont plus utilisés dans la version actuelle du projet.

## Pourquoi ces fichiers sont obsolètes ?

### Ancienne approche : ISO + autounattend.xml

L'ancienne méthode de déploiement Windows utilisait :
- Un fichier `autounattend.xml` pour automatiser l'installation de Windows
- Un ISO personnalisé contenant ce fichier
- Installation complète de Windows à chaque déploiement (30-40 minutes)

**Problèmes** :
- ❌ Très lent (installation Windows complète à chaque fois)
- ❌ Complexe à maintenir (XML verbeux)
- ❌ Peu fiable (nombreux points de défaillance)
- ❌ Difficile à déboguer
- ❌ Incohérent avec l'approche LXC

### Nouvelle approche : Template + Cloud-Init

La nouvelle méthode utilise :
- Un template Windows Server pré-configuré avec cloudbase-init
- Cloud-init pour la configuration au premier boot
- Clonage rapide du template (5-10 minutes)

**Avantages** :
- ✅ Beaucoup plus rapide (5-10 min vs 30-40 min)
- ✅ Plus fiable et robuste
- ✅ Facile à maintenir (YAML simple)
- ✅ Cohérent avec l'approche cloud-init des LXC
- ✅ Meilleur débogage (logs clairs)

## Fichiers archivés

| Fichier | Description | Remplacé par |
|---------|-------------|--------------|
| `autounattend.xml` | Fichier de configuration pour installation automatique Windows | `terraform/cloud-init/windows-firstboot-adds.yml` |
| `WINDOWS-AUTOUNATTEND.md` | Ancien guide basé sur autounattend.xml | `docs/WINDOWS-SETUP-GUIDE.md` |
| `create_autounattend_iso.sh` | Script de création de l'ISO autounattend | Plus nécessaire (template) |
| `prepare_windows_iso.sh` | Script d'upload de l'ISO autounattend | `scripts/upload_cloud_init.sh` |

## Utiliser les anciens fichiers

Si vous souhaitez toujours utiliser l'ancienne méthode :

1. Restaurer les fichiers :
   ```bash
   cp docs/obsolete/autounattend.xml terraform/
   cp docs/obsolete/create_autounattend_iso.sh scripts/
   cp docs/obsolete/prepare_windows_iso.sh scripts/
   ```

2. Suivre l'ancien guide :
   ```bash
   cat docs/obsolete/WINDOWS-AUTOUNATTEND.md
   ```

**Note** : L'ancienne méthode n'est plus maintenue ni supportée.

## Recommandation

Utilisez la nouvelle approche cloud-init documentée dans :
- [docs/WINDOWS-SETUP-GUIDE.md](../WINDOWS-SETUP-GUIDE.md)
- [docs/windows-template-setup.md](../windows-template-setup.md)
