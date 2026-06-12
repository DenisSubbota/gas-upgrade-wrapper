# Upgrade runbook — gascan + PMM


> **Caution (PG / Mongo):** review PostgreSQL and MongoDB upgrade caveats before running.
>
> **Mongo (GAS-1147):** `MongoDBHighFragmentedData` alert rule deploys; `fragmented_mb` metric absent on lab mongo — team follow-up, not a deploy blocker.
>
> **PMM 3.8.0 breaking change (handled):** Grafana 12 notification-policies API — **gascan v1.26.0 (GAS-1190) required**. gascan ≤ v1.25.0 fails alerting (K1).
> UI-based PMM upgrades deprecated (removed 3.9.0).

## Change log

[v1.24.0…v1.26.0](https://github.com/percona/GAS/compare/v1.24.0...v1.26.0)

**automation**
- [GAS-1190](https://percona.atlassian.net/browse/GAS-1190) — migrate notification policies from the legacy Alertmanager API to the Grafana 12 provisioning API (PMM 3.8.0). **Headline change** — gates alerting on this release.
- [GAS-1177](https://percona.atlassian.net/browse/GAS-1177) — fix RDS instances with a shared endpoint prefix failing to register in PMM.
- [GAS-1080](https://percona.atlassian.net/browse/GAS-1080) — fix the PMM client tarball download being skipped under incomplete conditions.
- [GAS-998](https://percona.atlassian.net/browse/GAS-998) — adopt the newer Ansible `difference` filter behavior (upgrade preparation).
- [GAS-1133](https://percona.atlassian.net/browse/GAS-1133) — add the missing `always` tag to the `update.yaml` precheck task.
- [GAS-1163](https://percona.atlassian.net/browse/GAS-1163) — fix threshold changes for multi-parameter alerts not taking effect.
- [GAS-1171](https://percona.atlassian.net/browse/GAS-1171) — apply the new Percona branding to health & security reports.
- [GAS-1164](https://percona.atlassian.net/browse/GAS-1164) — improve report-task error capturing and external-PMM handling.

**gas-tools**
- [GAS-1156](https://percona.atlassian.net/browse/GAS-1156) — improve AWS RDS topology detection in `db_tree` (MySQL ✅; MariaDB ⚠ [GAS-1195](https://percona.atlassian.net/browse/GAS-1195) warn, not a blocker).
- [GAS-1160](https://percona.atlassian.net/browse/GAS-1160) — fix the dynamic inventory plugin promoting cluster-level custom payload to host scope.

**alerts**
- [GAS-1174](https://percona.atlassian.net/browse/GAS-1174) — MySQL alerting improvements: dual-threshold `MySQLTooManyThreadsRunning` (base + RDS).
- [GAS-1147](https://percona.atlassian.net/browse/GAS-1147) — new `MongoDBHighFragmentedData` alert (rule deploys ✅; `fragmented_mb` metric absent — team follow-up).

**other (CI/docs, no runtime impact)**
- [GAS-1167](https://percona.atlassian.net/browse/GAS-1167) — auto-update the PR base branch (CI workflow).
- [GAS-1165](https://percona.atlassian.net/browse/GAS-1165) — document the `/tmp` `noexec` workaround.

---

## Prerequisites (both paths)

- Target versions in ServiceNow **before** inventory refresh: gascan `v1.26.0`, gas-tools `v1.26.0`, PMM `3.8.0`.
- Run on the **monitor node**.
- PMM ≥3.8.0 requires gascan ≥v1.26.0 (GAS-1190 notification policies / Grafana 12).

## Semi-automated upgrade path

```bash
# Semi-automated — fetch + run from the wrapper repo, ON the monitor:
bash -c "$(curl -fsSL https://raw.githubusercontent.com/DenisSubbota/gas-upgrade-wrapper/main/gascan-v1.24.0-to-v1.26.0_pmm-3.7.0-to-3.8.0/upgrade.sh)"

# unattended after SN confirmed in step 1:
bash -c "$(curl -fsSL https://raw.githubusercontent.com/DenisSubbota/gas-upgrade-wrapper/main/gascan-v1.24.0-to-v1.26.0_pmm-3.7.0-to-3.8.0/upgrade.sh)" -- --batch
```

What it does, in order — each step has an equivalent manual section below:

1. **SN + Slack gate** — prints the ServiceNow variables to set (`gascan_version=v1.26.0`, `tools_gas_version=v1.26.0`, `pmm_version=3.8.0`) and the customer Slack text, then waits for your confirmation. The only manual stop; `--batch` confirms here and runs the rest unattended.
2. **Download gascan** — fetches the `v1.26.0` binary for the monitor's OS (auto-detected, both mirrors).
3. **Inventory gate** — refreshes inventory and **waits** for `gascan_version` / `tools_gas_version` / `pmm_version` to match SN, polling every 30s for up to ~12 min (SN edits can lag several minutes after you save them) before it lets the playbooks run. On timeout it shows what's still stale and offers a manual re-check.
4–7. **Playbooks** — gas-tools, alerting-only, PMM server, then PMM client, prompting before each (auto under `--batch`).
8. **Tracker reminder** — prints the PMM tracker link to update.

**Resume:** re-run the same command; completed steps are skipped (state in `/tmp/gascan-upgrade-<env>.state`). Start over with `rm /tmp/gascan-upgrade-*.state`.

**Do not mix** manual playbooks mid-run with a partial script run — pick one path (or `rm` the state file first).

## Manual upgrade path

### 1. Update ServiceNow variables

- **For Monitor:** `gascan_version=v1.26.0`, `tools_gas_version=v1.26.0`
- **For Customer Env:** `pmm_version=3.8.0`

### 2. Download gascan binary on monitor node

```bash
GASCAN_VERSION="v1.26.0" bash -c '
if [ -f /etc/os-release ]; then
  . /etc/os-release
  mkdir -p ~/bin
  case "${ID,,}-${VERSION_ID}" in
    centos-9*|rhel-9*|ol-9*|rocky-9*) target="centos-stream9"; bin="gascan-py3.9" ;;
    ubuntu-22*) target="ubuntu-jammy"; bin="gascan-py3.10" ;;
    ubuntu-24*) target="ubuntu-noble"; bin="gascan-py3.12" ;;
    debian-11) target="debian-bullseye"; bin="gascan-py3.9" ;;
    debian-12) target="debian-bookworm"; bin="gascan-py3.11" ;;
    debian-13) target="debian-trixie"; bin="gascan-py3.13" ;;
    *) echo "Unsupported OS: ${ID,,}-${VERSION_ID}"; exit 1 ;;
  esac
  curl --insecure -o ~/bin/gascan "https://cdba.percona.com/downloads/gascan/$GASCAN_VERSION/linux/amd64/$target/$bin" ||
  curl --insecure -o ~/bin/gascan "https://100.125.40.95:8443/gascan/$GASCAN_VERSION/linux/amd64/$target/$bin" ||
  { echo "Download failed from both sources."; exit 1; }
  chmod u+x ~/bin/gascan
fi'
gascan --version | head -n1
```

### 3. Refresh + verify inventory

```bash
gascan -get-inventory -refresh | egrep "gascan_version|tools_gas_version|pmm_version" | sort | uniq -c
```

Expect exactly: `v1.26.0`, `v1.26.0`, `3.8.0`. **SN edits propagate with a lag (often several minutes)** — if the refresh still shows the old versions, wait ~30s and re-run it until the values match (the script polls automatically, every 30s up to ~12 min). Do **not** run playbooks on stale values.

### Customer Slack

Send before the PMM upgrade window (also printed in `upgrade.sh` step 1):

```
@here Hi team — we will be upgrading PMM from 3.7.0 to 3.8.0 on your monitoring environment.
There is no alerting downtime; alerts continue to route throughout. No action required on
your side. We'll confirm once complete.
```

## Playbooks

> **If a playbook exits with an error:** judge by the PLAY RECAP per host, not gascan’s exit code (it is non-zero on any ansible issue). `unreachable=1` on one node → check it (`gascan -adhoc -- <host> -m ping` / `ssh <host>`); if the node is expectedly down (maintenance/decommission), continue the upgrade and re-run that playbook later with `--limit=<host>`; a transient blip → just re-run the playbook (completed hosts re-converge fast). `failed=1` → read that host’s task error before re-running. The `upgrade.sh` companion does this triage for you and pauses for a retry/continue/abort decision.

### gas-tools

```bash
time gascan --playbook tools.yaml --override=tools_gas_version=v1.26.0
gas-tools --version | head -n1
```

### Alerting only

```bash
time gascan --playbook pmm-server.yaml --limit=monitors --override=pmm_deploy_using=None
```

### PMM server upgrade only

```bash
time gascan --playbook pmm-server.yaml --limit=monitors --skip-tags=alerting --override=pmm_version=3.8.0
podman ps | grep pmm-server
```

### PMM client

```bash
# check version and health of pmm-clients
gascan -adhoc -- mongodb,mysql,postgresql,ha,monitors -m shell -a '~/pmm/bin/pmm-admin version | grep "^Ver"'
gascan -adhoc -- mongodb,mysql,postgresql,ha,monitors -m shell -a '~/pmm/bin/pmm-admin list'

# add silence for the pmm-client agent in case any issues appear
amtool silence add --duration="1h" 'alertname=Percona_MS_NodeAgentDown' --comment='PMM3.8.0 upgrade'

# run pmm-client playbook
time gascan --playbook pmm-client.yaml --override=pmm_version=3.8.0

# verify state of pmm-clients after upgrade
gascan -adhoc -- mongodb,mysql,postgresql,ha,monitors -m shell -a '~/pmm/bin/pmm-admin version | grep "^Ver"'
gascan -adhoc -- mongodb,mysql,postgresql,ha,monitors -m shell -a '~/pmm/bin/pmm-admin list'
# wait 5–10 min, then: amtool silence expire <id>
```

## Update the PMM tracker spreadsheet

Manual on both paths — step 8 of the semi-automated path just reminds you.

[PMM tracker spreadsheet](https://docs.google.com/spreadsheets/d/1Hylu_DSw5YJYBPZbJmajSjTCitN4gm7XllriOCp9jTI/edit?gid=1362692116#gid=1362692116)
