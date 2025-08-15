
# AMP Generic Template: Minecraft (CurseForge Auto-Update)

**v3.2.2 — Self-bootstrapping**

This build makes new instances pull the scripts automatically on first **Update** from:
`crameep/amp-cf-updater`

## How it works
- The template's **UpdateExecutable** checks for `scripts/cf-sync.sh` and `scripts/start-detected.sh`.
- If missing, it downloads them from your GitHub repo, `chmod +x`, then runs the updater.
- From then on, **Update** and **Start** work normally.

## Quick Start
1. Add this repo to ADS: **Configuration → Instance Deployment → Configuration Repositories → Add** (your Git repo URL).
2. Create an instance with **Minecraft (CurseForge Auto-Update)**.
3. Open the instance → set **CF_API_KEY** and either **CF_PAGE_URL** or **CF_SLUG**.
4. Click **Update** (this will bootstrap scripts automatically), then **Start**.

> All other v3.2.1 features remain: robust slug parsing, nested-folder unzip, retries, rules validation, CF file pinning, JAR selection (SERVER_JAR/JAR_GLOB/JAR_PRIORITY), SNAPSHOT_ENABLED toggle.
