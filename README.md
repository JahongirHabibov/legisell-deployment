# Legisell — Production Deployment

Server-admin deployment package. No application source code is included — images are pulled from GHCR.

## Prerequisites

- Docker Engine ≥ 26 with Docker Compose v2 (`docker compose version`)
- A GHCR Personal Access Token (PAT) with `read:packages` scope
- [Tailscale](https://tailscale.com/) installed and authenticated on the server
- DNS A-records for `admin.legisell.de` and `api.legisell.de` pointing to the server's public IP
- TLS certificates (see step 3)

---

## 1. Authenticate with GHCR

```sh
echo "<your-ghcr-pat>" | docker login ghcr.io -u <github-username> --password-stdin
```

---

## 2. Configure the environment

```sh
cp .env.example .env
nano .env   # fill in every value marked with <...>
```

### Required values

| Variable | How to generate |
|---|---|
| `IMAGE_BACKEND` | `ghcr.io/<owner>/legisell-backend:<tag>` |
| `IMAGE_FRONTEND` | `ghcr.io/<owner>/legisell-frontend:<tag>` |
| `IMAGE_UPDATER` | `ghcr.io/<owner>/legisell-updater:<tag>` |
| `IMAGE_BACKUP` | `ghcr.io/<owner>/legisell-backup:<tag>` |
| `TAILSCALE_LOCAL_IP` | `tailscale ip -4` |
| `POSTGRES_PASSWORD` | `openssl rand -base64 32 \| tr -d '/+=' \| head -c 32` |
| `REDIS_PASSWORD` | `openssl rand -base64 32 \| tr -d '/+=' \| head -c 32` |
| `JWT_SECRET` | `openssl rand -hex 32` |
| `JWT_REFRESH_SECRET` | `openssl rand -hex 32` (different value) |
| `SECRETS_ENCRYPTION_KEY` | `python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"` |
| `ADMIN_PASSWORD` | any strong temporary password |
| `BACKUP_USER` | any username for the backup web UI |
| `BACKUP_PASSWORD` | any strong password for the backup web UI |

> **`SECRETS_VAULT_PASSWORD_HASH`** must **not** be set in `.env`. Bcrypt hashes contain `$`
> which Docker Compose misinterprets as variable substitution. Configure it via the Admin UI
> after first login (Settings → Secrets Vault).

---

## 3. SSL Certificates

Place `fullchain.pem` and `privkey.pem` in the `./ssl/` directory.

**Option A — Self-signed (IP / testing only):**

```sh
openssl req -x509 -nodes -newkey rsa:4096 \
  -keyout ssl/privkey.pem -out ssl/fullchain.pem \
  -days 365 -subj "/CN=legisell"
```

**Option B — Let's Encrypt (domain):**

```sh
cp /etc/letsencrypt/live/<domain>/fullchain.pem ssl/
cp /etc/letsencrypt/live/<domain>/privkey.pem   ssl/
```

---

## 4. Deploy

```sh
docker compose up -d
```

Docker Compose automatically loads `.env`. All images are pulled from GHCR on first run.

**Check status:**

```sh
docker compose ps
docker compose logs -f backend
```

---

## 5. First Login

1. Open `https://admin.legisell.de` in a browser connected to the Tailscale network.
2. Log in with `ADMIN_USERNAME` / `ADMIN_PASSWORD` from your `.env`.
3. **Change the admin password immediately.**
4. Configure the Secrets Vault password hash via Settings → Secrets Vault.

---

## Updating

Use the **Updater UI** at `https://admin.legisell.de/updater/` — it checks GitHub Releases,
patches `.env`, pulls new images from GHCR, and does a rolling-recreate with rollback support.

Or manually:

```sh
# 1. Edit IMAGE_BACKEND / IMAGE_FRONTEND / IMAGE_UPDATER / IMAGE_BACKUP in .env
# 2. Pull new images and recreate containers
docker compose pull
docker compose up -d
```

---

## Network Layout

| Port | Bound to | Purpose |
|------|----------|---------|
| 443 | `TAILSCALE_LOCAL_IP` | Admin panel (VPN-only) |
| 80 | `TAILSCALE_LOCAL_IP` | HTTP → HTTPS redirect (VPN-only) |
| 8400 | `TAILSCALE_LOCAL_IP` | Backup web UI (VPN-only) |
| 8443 | `0.0.0.0` (public) | POS License API |

---

## Backup

PostgreSQL backups run inside the `backup` container with a web UI at:

```
http://<TAILSCALE_LOCAL_IP>:8400
```

This port is bound to `TAILSCALE_LOCAL_IP` — reachable only via Tailscale VPN.
Log in with `BACKUP_USER` / `BACKUP_PASSWORD` from your `.env`.

Backup files are stored in the `./backups/` directory (bind-mounted into the container).
Retention, scheduling, and restore operations are managed through the web UI.

---

## Automated Updates (GitHub Releases)

Dieses Repo dient zusätzlich als **öffentliche Versions-Datenbank** für den
Updater-Sidecar im Admin-Panel. Der Updater fragt anonym die GitHub Releases API ab:

```
GET https://api.github.com/repos/<owner>/legisell-deployment/releases/latest
```

### Was ein Release enthält

| Feld | Pflicht | Beispiel |
|------|---------|----------|
| `tag_name` | ✅ | `v0.1.3` (semver: `vMAJOR.MINOR.PATCH`) |
| `published_at` | optional (UI) | `2026-04-20T12:00:00Z` |
| `body` | optional (Markdown) | Changelog im Conventional-Commits-Format |
| `release-body.json` | Asset (Fallback) | Strukturiertes Changelog als JSON |

**Markdown-Body-Format (bevorzugt):**

```markdown
## v0.1.3 (2026-04-20)

- **feature**: Neue Lizenzverwaltung
- **fix**: Berechtigungsfehler beim Login behoben
- **perf**: Dashboard lädt 40% schneller
```

**release-body.json (Fallback-Asset):**

```json
{
  "version": "v0.1.3",
  "date": "2026-04-20",
  "changes": [
    { "type": "feature", "text": "Neue Lizenzverwaltung" },
    { "type": "fix",     "text": "Berechtigungsfehler beim Login behoben" },
    { "type": "perf",    "text": "Dashboard lädt 40% schneller" }
  ]
}
```

### CI-Workflow (im privaten Repo)

Ein Template des Workflows liegt unter [`.github/workflows/create-release.yml`](.github/workflows/create-release.yml)
als Referenz. **Der Workflow muss in das private Legisell-Repo kopiert werden.**

Bei jedem `git push --tags v*.*.*` im privaten Repo passiert automatisch:

1. Conventional Commits seit dem letzten Tag werden geparst (`feat:`, `fix:`, `perf:`)
2. `release-body.json` wird generiert
3. `gh release create` erstellt das Release auf `<owner>/legisell-deployment`
4. Markdown-Notes + `release-body.json` werden angehängt

### Voraussetzung: `LEGISELL_DEPLOYMENT_RELEASE_TOKEN`

Ein GitHub **Fine-grained Personal Access Token** (PAT) muss als Repository Secret
im **privaten** Repo hinterlegt sein. Der Standard-`GITHUB_TOKEN` reicht nicht,
da er nicht repo-übergreifend schreiben kann.

**PAT erstellen — Schritt für Schritt:**

1. Öffne https://github.com/settings/tokens?type=beta (Fine-grained tokens)
2. Klicke **"Generate new token"**
3. Einstellungen:
   - **Token name:** `legisell-deployment-releases`
   - **Expiration:** max. 1 Jahr (Erinnerung setzen!)
   - **Repository access → Only select repositories:** `<owner>/legisell-deployment`
   - **Permissions → Repository permissions:**
     - `Contents` → **Read and write** (zum Erstellen von Releases + Assets)
   - Alle anderen Permissions auf **No access** belassen
4. Klicke **"Generate token"** und kopiere den Token sofort

**Token als Secret hinterlegen:**

1. Öffne das **private** Legisell-Repo → Settings → Secrets and variables → Actions
2. Klicke **"New repository secret"**
3. Name: `LEGISELL_DEPLOYMENT_RELEASE_TOKEN`
4. Value: den kopierten Token einfügen
5. Speichern

**Testen:**

```sh
# Neuen Tag erstellen und pushen
git tag v0.1.0
git push origin v0.1.0

# Prüfen ob Release erstellt wurde
curl -s https://api.github.com/repos/<owner>/legisell-deployment/releases/latest | jq '.tag_name'
```

> **Hinweis:** Wenn der Token abläuft, schlägt der Workflow fehl.
> Erneuere den Token rechtzeitig und aktualisiere das Secret.

---

## Repository Structure

```
.
├── docker-compose.yml                          # Self-contained production stack
├── .env.example                                # Environment template (copy to .env)
├── ssl/                                        # TLS certificates (not committed)
│   ├── fullchain.pem                           # ← place here
│   └── privkey.pem                             # ← place here
├── backups/                                    # PostgreSQL backup files (bind-mount target)
└── .github/workflows/
    └── create-release.yml                      # CI-Template (→ ins private Repo kopieren)
```
