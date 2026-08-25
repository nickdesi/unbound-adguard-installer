# CONTRIBUTING.md

## 🎯 Guide de Contribution

Merci de votre intérêt pour améliorer ce projet ! Ce guide vous aidera à contribuer efficacement.

## 📋 Prérequis

- Bash 4.0+ (vérifiez avec `bash --version`)
- Shellcheck installé pour le linting (`apk add shellcheck` ou `apt-get install shellcheck`)
- Accès à un environnement Proxmox VE (pour les tests)
- Connaissance des bonnes pratiques bash

## 🏗️ Architecture du Code

```
unbound-adguard-installer/
├── install_unbound_interactive.sh  # Script principal
├── lib/
│   ├── common.sh                   # Fonctions utilitaires communes
│   └── health_checks.sh            # Tests de santé DNS
├── tests/
│   └── test_suite.sh               # Suite de tests automatisés
└── docs/
    ├── ARCHITECTURE.md             # Documentation architecture
    └── TROUBLESHOOTING.md          # Guide dépannage
```

## 🔍 Standards de Code

### 1. Style de Code Bash

Nous suivons les standards **bash-pro** et **bash-defensive-patterns** :

```bash
# ✅ Bon exemple
readonly CONSTANT_VALUE="immutable"
local variable_name="mutable"

# Utiliser [[ ]] au lieu de [ ]
if [[ "$var" == "value" ]]; then
    echo "OK"
fi

# Toujours quoter les variables
echo "${variable_name}"

# ❌ Mauvais exemple
constant=something  # Pas readonly
if [ $var = "value" ]; then  # Pas de quotes, utilise [ ]
    echo $variable  # Pas de quotes
fi
```

### 2. Gestion d'Erreurs

```bash
# Toujours vérifier les codes de retour
if ! command_that_might_fail; then
    msg_error "Description de l'erreur"
    return 1
fi

# Utiliser set -Eeuo pipefail au début des scripts
set -Eeuo pipefail
trap cleanup EXIT
trap 'error_handler $? $LINENO $BASH_COMMAND' ERR
```

### 3. Documentation

#### Commentaires de Fonction

```bash
# Description courte de la fonction
# Usage: nom_fonction <param1> [param2]
# Returns: 0 on success, 1 on error
nom_fonction() {
    local param1="$1"
    local param2="${2:-default_value}"

    # Logique de la fonction
}
```

#### Commentaires Inline

```bash
# Expliquer le "pourquoi", pas le "quoi"
# ✅ Bon
# Retry logic because GitHub API rate limits can cause failures
for ((i=0; i<3; i++)); do
    ...
done

# ❌ Mauvais
# Loop 3 times
for ((i=0; i<3; i++)); do
    ...
done
```

## 🧪 Tests

### Exécuter les Tests

```bash
# Tous les tests
./tests/test_suite.sh

# Tests spécifiques
./tests/test_suite.sh --test validation
./tests/test_suite.sh --test health_checks
```

### Écrire de Nouveaux Tests

```bash
# Dans tests/test_suite.sh
test_votre_fonction() {
    local result
    result=$(votre_fonction "param")

    if [[ "$result" == "expected" ]]; then
        pass "Test votre_fonction"
    else
        fail "Test votre_fonction: attendu 'expected', obtenu '$result'"
    fi
}
```

## 📝 Processus de Contribution

### 1. Fork & Clone

```bash
git clone https://github.com/VOTRE_USERNAME/unbound-adguard-installer.git
cd unbound-adguard-installer
```

### 2. Créer une Branche

```bash
git checkout -b feature/amelioration-xyz
# ou
git checkout -b fix/correction-bug-xyz
```

### 3. Développer & Tester

```bash
# Linting
shellcheck install_unbound_interactive.sh

# Tests
./tests/test_suite.sh

# Test manuel dans un LXC
pct exec 100 -- bash install_unbound_interactive.sh --install
```

### 4. Commit avec Messages Clairs

Suivre le format [Conventional Commits](https://www.conventionalcommits.org/) :

```bash
git commit -m "feat: ajouter validation CIDR pour IP"
git commit -m "fix: corriger bug timeout dans download_with_retry"
git commit -m "docs: améliorer guide health checks"
git commit -m "refactor: extraire logique réseau dans common.sh"
```

Types de commits :
- `feat`: Nouvelle fonctionnalité
- `fix`: Correction de bug
- `docs`: Documentation uniquement
- `refactor`: Refactoring sans changement fonctionnel
- `test`: Ajout/modification de tests
- `perf`: Amélioration de performance
- `chore`: Tâches de maintenance

### 5. Push & Pull Request

```bash
git push origin feature/amelioration-xyz
```

Créer une Pull Request sur GitHub avec :
- **Titre clair** : `feat: ajouter support IPv6 pour Unbound`
- **Description** :
  - Quel problème ça résout ?
  - Comment ça a été testé ?
  - Captures d'écran si pertinent (logs, outputs)
  - Références issues (Closes #123)

## 🐛 Signaler un Bug

Utiliser le template d'issue GitHub avec :

1. **Environnement**
   - OS (Debian 12, Ubuntu 22.04, etc.)
   - Type de conteneur (LXC privilégié/non-privilégié)
   - Version du script (`grep SCRIPT_VERSION install_unbound_interactive.sh`)

2. **Comportement Attendu vs Actuel**

3. **Logs**
   ```bash
   # Coller les logs pertinents
   tail -100 /var/log/adguard-unbound-installer.log
   ```

4. **Étapes pour Reproduire**

## 💡 Demander une Fonctionnalité

Ouvrir une issue "Feature Request" avec :

1. **Cas d'usage** : Pourquoi cette fonctionnalité serait utile ?
2. **Proposition** : Comment devrait-elle fonctionner ?
3. **Alternatives** : Avez-vous envisagé d'autres solutions ?

## 🔐 Sécurité

Pour signaler une vulnérabilité de sécurité :
- **NE PAS** créer d'issue publique
- Envoyer un email à : security@[domaine_projet]
- Utiliser la fonctionnalité GitHub Security Advisories

## ✅ Checklist avant Pull Request

- [ ] Code respecte les standards (shellcheck passe)
- [ ] Tests ajoutés/modifiés si nécessaire
- [ ] Tests passent (`./tests/test_suite.sh`)
- [ ] Documentation mise à jour (README, ARCHITECTURE, etc.)
- [ ] Commits suivent Conventional Commits
- [ ] Testé manuellement dans un LXC
- [ ] Pas de secrets/credentials dans le code

## 📚 Ressources

- [Bash Best Practices](https://github.com/rtk-ai/rtk) (RTK bash-pro skill)
- [ShellCheck](https://www.shellcheck.net/)
- [Proxmox VE Documentation](https://pve.proxmox.com/pve-docs/)
- [AdGuard Home](https://github.com/AdguardTeam/AdGuardHome)
- [Unbound](https://nlnetlabs.nl/documentation/unbound/)

## 🙏 Remerciements

Toutes les contributions sont appréciées ! Merci de rendre ce projet meilleur.

---

**Questions ?** Ouvrez une discussion GitHub ou rejoignez notre [Discord/Forum/Chat].
