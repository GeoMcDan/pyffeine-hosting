# pyffeine-hosting

Docker Compose stack hosting **OpenWebUI** behind a **Cloudflare Tunnel** on a Contabo VPS.

- Live site: <https://gpt.pyffeine.top>
- Stack: `openwebui` (ghcr.io/open-webui/open-webui) + `cloudflared` (cloudflare/cloudflared)

## Architecture

```mermaid
flowchart LR
    subgraph GitHub
        R[GeoMcDan/pyffeine-hosting<br>main = live, dev = development]
    end
    subgraph VPS
        W[/home/george/pyffeine-hosting<br>working copy]
        L[/home/george/n8n-compose<br>live deployment - main]
        D[/home/george/pyffeine-dev<br>dev deployment - dev]
    end
    R -->|clone| W
    R -->|git pull| L
    R -->|git pull| D
    L -->|docker compose up -d| LC[openwebui + cloudflared<br>gpt.pyffeine.top]
    D -->|docker compose up -d| DC[openwebui dev<br>own .env]
```

## Repo Layout

```
.
├── docker-compose.yml    # canonical stack: openwebui + cloudflared
├── .env.example          # template - copy to .env, never commit real .env
├── .gitignore            # .env, *.bak, *.log, ...
├── deploy.sh             # deploy.sh [live|dev] -> git pull + compose up -d
└── README.md
```

## Branch Strategy

| Branch | Environment | Deployment dir on VPS |
|--------|-------------|-----------------------|
| `main` | live (production) | `/home/george/n8n-compose` |
| `dev`  | development      | `/home/george/pyffeine-dev` |

Work on `dev`, test, then merge to `main` and deploy live.

## Secrets Handling

- The real `.env` **never** lives in this repo — it is gitignored.
- Each deployment dir keeps its own local `.env` (untracked, preserved across `git pull`).
- Use `.env.example` as the template for new environments.

## One-Time Setup (VPS)

### 1. Working copy

```bash
mkdir -p /home/george/pyffeine-hosting
cd /home/george/pyffeine-hosting
git init -b main
git remote add origin git@github.com:GeoMcDan/pyffeine-hosting.git
# copy the cleaned tree (docker-compose.yml, .env.example, .gitignore, deploy.sh, README.md)
git add .
git commit -m "chore: initial clean structure (openwebui + cloudflared)"
git branch dev
git push -u origin main dev
```

> Note: this force-replaces the old single-commit history. If the remote already has
> commits you want to keep, use `git push --force` after confirming the old history
> contains no secrets (it does not — `.env` was never committed).

### 2. Live deployment dir

```bash
cd /home/george/n8n-compose
rm -rf .git                      # drop the old in-place repo
git init -b main
git remote add origin git@github.com:GeoMcDan/pyffeine-hosting.git
git fetch origin
git checkout -b main origin/main
# .env stays in place (untracked, gitignored)
```

### 3. Dev deployment dir

```bash
git clone -b dev git@github.com:GeoMcDan/pyffeine-hosting.git /home/george/pyffeine-dev
cd /home/george/pyffeine-dev
cp .env.example .env             # fill in dev values
```

## Update Workflow

```bash
# on the VPS, from the working copy
cd /home/george/pyffeine-hosting
git checkout dev
# ... edit files, commit, push ...

# deploy to dev
./deploy.sh dev

# merge to main and deploy live
git checkout main
git merge dev
git push origin main
./deploy.sh live
```

`deploy.sh` runs `git pull` in the target dir, validates with `docker compose config`,
then restarts with `docker compose up -d`.

## Dev Environment Notes

- The compose file references the external volume `open_webui_data` and the Cloudflare
  tunnel token. The dev environment currently shares these with live.
- To fully isolate dev later, parameterize the volume name and tunnel/domain via `.env`
  (e.g. `OPENWEBUI_VOLUME_NAME` and a separate `CLOUDFLARED_TOKEN` for a dev tunnel).

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `docker compose config` fails | Check `.env` exists in the deployment dir and all vars are set |
| Site down after deploy | `docker compose logs -f` in the deployment dir |
| Tunnel not connecting | Verify `CLOUDFLARED_TOKEN` in `.env` matches the Cloudflare tunnel |
| `.env` missing after clone | `cp .env.example .env` and fill in values |