const { execSync } = require('child_process');
const https = require('https');
const fs = require('fs');
const path = require('path');
const os = require('os');

const GITHUB_TOKEN = process.env.GITHUB_TOKEN;
const GITHUB_REPOSITORY = process.env.GITHUB_REPOSITORY;

if (!GITHUB_TOKEN || !GITHUB_REPOSITORY) {
  console.error("Erreur : GITHUB_TOKEN ou GITHUB_REPOSITORY manquant.");
  process.exit(1);
}

// Copier le script de résolution dans le répertoire temporaire du système
// afin de pouvoir l'exécuter même sur des branches anciennes qui ne l'ont pas encore.
const tempResolverPath = path.join(os.tmpdir(), 'resolve-bolt-conflict-temp.cjs');
console.log(`Copie du résolveur vers le fichier temporaire : ${tempResolverPath}`);
fs.copyFileSync(
  path.join(__dirname, 'resolve-bolt-conflict.cjs'),
  tempResolverPath
);

function makeRequest(url) {
  return new Promise((resolve, reject) => {
    const options = {
      headers: {
        'Authorization': `Bearer ${GITHUB_TOKEN}`,
        'Accept': 'application/vnd.github.v3+json',
        'User-Agent': 'Auto-Resolve-PR-Conflicts'
      }
    };
    https.get(url, options, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        if (res.statusCode === 200) {
          resolve(JSON.parse(data));
        } else {
          reject(new Error(`Status: ${res.statusCode}, Body: ${data}`));
        }
      });
    }).on('error', reject);
  });
}

async function run() {
  try {
    const pullsUrl = `https://api.github.com/repos/${GITHUB_REPOSITORY}/pulls?state=open`;
    console.log(`Récupération des PRs ouvertes depuis ${pullsUrl}...`);
    const prs = await makeRequest(pullsUrl);
    console.log(`Trouvé ${prs.length} PRs ouvertes.`);

    for (const pr of prs) {
      const prNumber = pr.number;
      const headBranch = pr.head.ref;
      const isFork = pr.head.repo.full_name !== GITHUB_REPOSITORY;

      if (isFork) {
        console.log(`La PR #${prNumber} provient d'un fork. Passage.`);
        continue;
      }

      console.log(`\n--- Vérification de la PR #${prNumber} (branche: ${headBranch}) ---`);

      try {
        // Configurer localement la branche pour suivre origin
        console.log(`Configuration locale de la branche ${headBranch}...`);
        try {
          execSync(`git fetch origin ${headBranch}:${headBranch}`, { stdio: 'pipe' });
        } catch (fetchErr) {
          execSync(`git fetch origin ${headBranch}`, { stdio: 'pipe' });
        }
        
        execSync(`git checkout ${headBranch}`, { stdio: 'inherit' });

        // Lancer le script de résolution de conflit pour cette branche
        console.log(`Lancement du résolveur de conflit pour la PR #${prNumber}...`);
        execSync(`node "${tempResolverPath}"`, {
          env: {
            ...process.env,
            BASE_BRANCH: 'main',
            HEAD_BRANCH: headBranch
          },
          stdio: 'inherit'
        });
      } catch (err) {
        console.error(`Erreur lors de la résolution de la PR #${prNumber}:`, err.message);
      }
    }

    // Retourner sur main à la fin
    execSync('git checkout main', { stdio: 'inherit' });
    console.log("\nVérification de toutes les PRs terminée.");

  } catch (error) {
    console.error("Une erreur est survenue dans auto-resolve-all-prs :", error);
    process.exit(1);
  } finally {
    // Nettoyer le fichier temporaire
    try {
      if (fs.existsSync(tempResolverPath)) {
        fs.unlinkSync(tempResolverPath);
      }
    } catch (cleanErr) {
      console.warn("Impossible de supprimer le fichier temporaire :", cleanErr.message);
    }
  }
}

run();
