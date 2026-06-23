#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Companion upgrade script: gascan v1.24.0 -> v1.26.0, PMM 3.7.0 -> 3.8.1
#
# Runs ON THE MONITOR NODE. Automates everything safely automatable, with a
# confirm gate before each state-changing step. ServiceNow variable changes and
# the PMM tracker spreadsheet update are MANUAL — the script pauses for them.
#
# Batch:  bash upgrade.sh --batch   step 1 SN + customer Slack (manual), then 2–7 unattended.
# Resume: progress is saved to /tmp/gascan-upgrade-<env>.state after each step.
# Re-run the same script to skip completed steps (same target versions only).
# Delete the state file to start fresh: rm /tmp/gascan-upgrade-*.state
# ============================================================================

# Target versions this run upgrades TO. The inventory GATE (step 3) asserts the
# refreshed inventory matches these and ABORTS otherwise.
EXPECT_GASCAN="v1.26.0"      # gascan_version
EXPECT_GASTOOLS="v1.26.0"  # tools_gas_version (independent of gascan)
EXPECT_PMM="3.8.1"                # pmm_version
PMM_FROM="3.7.0"
TOTAL_STEPS=8
BATCH=0
BATCH_REQUESTED=0

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes|--batch) BATCH_REQUESTED=1 ;;
    -h|--help)
      cat <<EOF
Usage: upgrade.sh [--batch]

  (default)  Confirm before each playbook and at the ServiceNow gate.
  --batch    Step 1: SN gate + customer Slack (manual). Steps 2–7: no further prompts.
  -y, --yes  Same as --batch.

Resume: re-run the same command; completed steps skip via /tmp/gascan-upgrade-<env>.state
EOF
      exit 0
      ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# gascan env — `bash upgrade.sh` over SSH does NOT source ~/.bashrc, so gascan's
# auth/inventory env is absent. Export it here (same four vars as the skill's
# _gascan_env.sh). See references/paths.md › gascan env vars over SSH.
# ---------------------------------------------------------------------------
export ANSIBLE_VAULT_PASSWORD_FILE="$HOME/.config/gascan/.vault-key"
export GASCAN_INVENTORY_CONFIG_FILE="$HOME/.config/gascan/inventory-config.json"
export GASCAN_DEFAULT_INVENTORY=0
export GASCAN_FLAG_PASSWORDLESS_SUDO=1

# ---------------------------------------------------------------------------
# Output helpers — structured, labeled progress the operator can follow + trust.
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  c_grn=$'\033[32m'; c_red=$'\033[31m'; c_ylw=$'\033[33m'; c_bld=$'\033[1m'; c_rst=$'\033[0m'
else
  c_grn=; c_red=; c_ylw=; c_bld=; c_rst=
fi
# clickable underlined light-blue hyperlink (OSC 8 + ANSI); plain URL when not a TTY
if [ -t 1 ]; then
  __o=$'\033]8;;'; __st=$'\033\\'; __lb=$'\033[4;94m'; __rs=$'\033[0m'
  hlink() { printf '%s%s%s%s%s%s%s' "$__o" "$1" "$__st" "$__lb" "${2:-$1}" "$__rs" "$__o$__st"; }
else
  hlink() { printf '%s' "${2:-$1}"; }
fi
step()   { echo; echo "${c_bld}━━━ STEP $1/${TOTAL_STEPS} — $2 ━━━${c_rst}"; }
expect() { echo "   expect: $1"; }
ok()     { echo "   ${c_grn}✓${c_rst} $1"; }
warn()   { echo "   ${c_ylw}!${c_rst} $1"; }
note()   { echo "   • $1"; }
fail()   { echo "   ${c_red}✗ $1${c_rst}" >&2; [ -n "${2:-}" ] && echo "     ${c_red}→ $2${c_rst}" >&2; exit 1; }
cmd()    { echo; echo "   ${c_bld}\$ $1${c_rst}"; echo; }

confirm() {
  if [ "$BATCH" -eq 1 ]; then
    local msg="${1%\?}"
    note "running: ${msg}"
    return 0
  fi
  read -rp "   > $1  [Enter to continue / Ctrl-C to abort] " _
}
manual_gate() {
  echo; echo "   ${c_bld}MANUAL (ServiceNow):${c_rst} $1"
  read -rp "   Applied in SN? [Enter to continue] " _
}

# ---------------------------------------------------------------------------
# run_playbook <step#> <gascan args…> — run a playbook and judge the PLAY RECAP
# per host (gascan's aggregate exit code is non-zero on ANY ansible issue, so it
# alone can't tell "one node unreachable" from "deploy broken"). On problem
# hosts it prints triage guidance and gates on the operator: retry / continue
# without the host / abort. Failures ALWAYS gate, even under --batch.
# ---------------------------------------------------------------------------
run_playbook() {
  local stepno="$1"; shift
  local log="/tmp/gascan-upgrade-${MON_ENV}-step${stepno}.log"
  local rc recap bad line ans
  # pmm-client.yaml needs the monitor in any --limit (it templates client config from monitor facts);
  # playbooks already limited (--limit=monitors) just re-run as-is — no extra --limit.
  local lim="--limit=<host>"
  case "$*" in
    *pmm-client.yaml*) lim="--limit=monitors,<host>" ;;
    *--limit=*)        lim="" ;;
  esac
  while :; do
    rc=0
    time gascan "$@" 2>&1 | tee "$log" || rc=$?
    recap=$(grep -E '^[A-Za-z0-9][A-Za-z0-9._-]*[[:space:]]*:[[:space:]]*ok=[0-9]' "$log" || true)
    bad=$(printf '%s\n' "$recap" | grep -E 'unreachable=[1-9]|failed=[1-9]' || true)
    if [ -n "$recap" ] && [ -z "$bad" ]; then
      [ "$rc" -ne 0 ] && note "gascan exited ${rc} but every host's PLAY RECAP is clean — recap is authoritative, proceeding"
      return 0
    fi
    echo
    if [ -z "$recap" ]; then
      warn "playbook exited ${rc} before any PLAY RECAP — env/auth/inventory problem, not a host failure"
      note "full output: ${log}"
      note "triage: read the error above; common checks: gascan -get-inventory -refresh, VPN up, ~/.config/gascan/* present"
    else
      warn "playbook finished with PROBLEM HOST(S) (gascan exit ${rc}) — everything else completed:"
      printf '%s\n' "$bad" | while IFS= read -r line; do echo "       ${c_red}${line}${c_rst}"; done
      note "full output: ${log}"
      echo
      note "unreachable=N → the node did not answer SSH. What to do:"
      echo "       - check it yourself:  gascan -adhoc -- <host> -m ping   (or: ssh <host>)"
      echo "       - node down / maintenance / decommissioned? confirm with the team; if it is"
      echo "         EXPECTED to be away → choose [c] continue, then once it is back run:"
      echo "           gascan $* ${lim}"
      echo "       - transient network/SSH blip → choose [r] retry (completed hosts re-converge fast)"
      note "failed=N → a real task failure on that host — read its task error above before deciding."
    fi
    echo
    # plain `ssh mon 'bash -c …'` has no TTY but stdin still reaches the operator — so
    # always TRY to ask; only EOF (stdin closed, e.g. curl|bash) hard-fails with the resume hint.
    if ! read -rp "   > [r] retry playbook   [c] continue WITHOUT the problem host(s)   [a] abort : " ans; then
      echo
      fail "step ${stepno} playbook needs an operator decision and stdin is closed" \
           "re-run upgrade.sh interactively — resume skips the completed steps"
    fi
    case "$ans" in
      r|R) note "retrying playbook…" ;;
      c|C)
        warn "continuing — host(s) above were NOT upgraded; once resolved, re-run: gascan $* ${lim}"
        return 0 ;;
      *) fail "aborted by operator at step ${stepno}" "fix the host, then re-run upgrade.sh — resume skips completed steps" ;;
    esac
  done
}

batch_activate() {
  if [ "$BATCH_REQUESTED" -ne 1 ] || [ "$BATCH" -eq 1 ]; then return 0; fi
  BATCH=1
  note "batch mode ON — steps 2–7 run without further prompts"
}

# monitor_env — CDBAng-Monitor-Name from inventory config (for banner + resume file).
monitor_env() {
  local cfg="$HOME/.config/gascan/inventory-config.json" env=""
  if [ -f "$cfg" ]; then
    if command -v jq >/dev/null 2>&1; then
      env=$(jq -r '."CDBAng-Monitor-Name" // empty' "$cfg" 2>/dev/null || true)
    fi
    [ -z "$env" ] && env=$(grep -oE '"CDBAng-Monitor-Name"[[:space:]]*:[[:space:]]*"[^"]*"' "$cfg" 2>/dev/null \
      | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' | head -n1 || true)
  fi
  printf '%s' "${env:-unknown-env}"
}

MON_ENV="$(monitor_env)"
STATE_FILE="${GASCAN_UPGRADE_STATE:-/tmp/gascan-upgrade-${MON_ENV}.state}"
LAST_COMPLETED=0

state_load() {
  local f_gascan="" f_tools="" f_pmm="" f_last="0"
  [ -f "$STATE_FILE" ] || return 0
  f_gascan=$(grep '^expect_gascan=' "$STATE_FILE" 2>/dev/null | cut -d= -f2- || true)
  f_tools=$(grep '^expect_gastools=' "$STATE_FILE" 2>/dev/null | cut -d= -f2- || true)
  f_pmm=$(grep '^expect_pmm=' "$STATE_FILE" 2>/dev/null | cut -d= -f2- || true)
  f_last=$(grep '^last_completed=' "$STATE_FILE" 2>/dev/null | cut -d= -f2- || true)
  if [ "$f_gascan" = "$EXPECT_GASCAN" ] && [ "$f_tools" = "$EXPECT_GASTOOLS" ] && [ "$f_pmm" = "$EXPECT_PMM" ]; then
    LAST_COMPLETED="${f_last:-0}"
    if [ "$LAST_COMPLETED" -gt 0 ]; then
      note "Resume: last completed step ${LAST_COMPLETED}/${TOTAL_STEPS} (${STATE_FILE})"
    fi
  elif [ -n "$f_gascan" ]; then
    warn "state file ignored (target versions differ) — rm ${STATE_FILE} to start fresh"
  fi
}

state_save() {
  local n="$1"
  cat >"$STATE_FILE" <<EOF
last_completed=${n}
expect_gascan=${EXPECT_GASCAN}
expect_gastools=${EXPECT_GASTOOLS}
expect_pmm=${EXPECT_PMM}
updated=$(date -u +%Y-%m-%dT%H:%M:%SZ)
mon_env=${MON_ENV}
EOF
}

state_clear() { rm -f "$STATE_FILE"; }

skip_step() {
  local n="$1" title="${2:-}"
  if [ "${LAST_COMPLETED:-0}" -ge "$n" ]; then
    ok "step ${n}/${TOTAL_STEPS} — ${title} · already completed (resume)"
    return 0
  fi
  return 1
}

show_banner() {
  echo
  echo "${c_bld}GASCAN + PMM upgrade — ${MON_ENV}${c_rst}"
  echo "   gascan v1.24.0 → ${EXPECT_GASCAN}   gas-tools → ${EXPECT_GASTOOLS}   PMM ${PMM_FROM} → ${EXPECT_PMM}"
  echo "   ${TOTAL_STEPS} steps · typical runtime ~10–15 min (inventory refresh may add retries)"
  echo "   Run on the monitor: bash upgrade.sh [--batch]  ·  manual path: upgrade-runbook.md in the run folder"
  if [ "$BATCH_REQUESTED" -eq 1 ]; then
    echo "   batch: step 1 waits for SN + customer Slack; steps 2–7 auto after SN confirmed"
  fi
  echo
}

show_customer_slack() {
  echo
  note "Customer Slack — copy/paste before the PMM upgrade window:"
  echo
  cat <<EOF
Hi team — we will be upgrading PMM from ${PMM_FROM} to ${EXPECT_PMM} on your monitoring environment. There is no alerting downtime; alerts continue to route throughout. No action required on your side. We'll confirm once complete.
EOF
  echo
}

# urlenc <string> — percent-encode for a URL query value.
urlenc() {
  local s="$1" out= c i
  for (( i=0; i<${#s}; i++ )); do
    c="${s:$i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

sn_links() {
  local cfg="$HOME/.config/gascan/inventory-config.json" env="$MON_ENV" b
  b="https://percona.service-now.com"
  if [ "$env" = "unknown-env" ]; then
    echo "Monitor node (gascan_version, tools_gas_version): $(hlink "${b}/u_cmdb_ci_percona_ms_monitor_list.do")  (could not derive env from ${cfg} — filter manually)"
    echo "Customer Env (pmm_version):                       $(hlink "${b}/u_cmdb_ci_customer_environment_list.do")  (filter manually)"
    return
  fi
  echo "Monitor node (gascan_version, tools_gas_version): $(hlink "${b}/u_cmdb_ci_percona_ms_monitor_list.do?sysparm_query=$(urlenc "name=${env}")")"
  echo "Customer Env (pmm_version):                       $(hlink "${b}/u_cmdb_ci_customer_environment_list.do?sysparm_query=$(urlenc "u_full_nameSTARTSWITH${env} -")")"
}

state_load
show_banner
[ "${LAST_COMPLETED:-0}" -ge 1 ] && batch_activate

# ---------------------------------------------------------------------------
# 1. ServiceNow variable changes (manual)
# ---------------------------------------------------------------------------
if ! skip_step 1 "ServiceNow variables"; then
  step 1 "ServiceNow variables"
  note "Open the SN CMDB records for THIS env (Monitor node + Customer Env are separate records):"
  sn_links | while IFS= read -r l; do echo "     $l"; done
  show_customer_slack
  manual_gate "Set gascan_version=${EXPECT_GASCAN} and tools_gas_version=${EXPECT_GASTOOLS} on the Monitor node; pmm_version=${EXPECT_PMM} on the Customer Env"
  state_save 1
  batch_activate
fi

# ---------------------------------------------------------------------------
# 2. Download the new gascan binary (OS auto-detect, both mirrors)
# ---------------------------------------------------------------------------
if ! skip_step 2 "gascan ${EXPECT_GASCAN} binary"; then
  step 2 "Ensure gascan ${EXPECT_GASCAN} binary"
  expect "~/bin/gascan reports ${EXPECT_GASCAN} (download only if missing/mismatched)"
  cur_gascan=$(gascan --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
  if [ "$cur_gascan" = "${EXPECT_GASCAN}" ]; then
    ok "gascan ${EXPECT_GASCAN} already installed — skipping download"
  else
    note "current gascan: ${cur_gascan:-<none>} — downloading ${EXPECT_GASCAN}"
    GASCAN_VERSION="${EXPECT_GASCAN}" bash -c '
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
fi' || fail "gascan binary download failed" "check cdba.percona.com reachability and that ${EXPECT_GASCAN} exists for this OS"
    ok "gascan binary in place: $(gascan --version 2>/dev/null | head -n1 || echo '<version check failed>')"
  fi
  state_save 2
fi

# ---------------------------------------------------------------------------
# 3. Refresh inventory + GATE on target versions
# ---------------------------------------------------------------------------
if ! skip_step 3 "inventory refresh + version GATE"; then
  step 3 "Refresh + verify inventory (GATE)"
  expect "gascan_version=${EXPECT_GASCAN}, tools_gas_version=${EXPECT_GASTOOLS}, pmm_version=${EXPECT_PMM}"
  # Read all three from the inventory dump; the `monitors -m debug -a var=` adhoc is unusable
  # (ansible.pex: "Invalid play strategy: locking"). SN edits lag minutes — poll until they match.
  INV_POLL_INTERVAL=30
  INV_POLL_MAX=24
  INV_POLL_MIN=$(( INV_POLL_INTERVAL * INV_POLL_MAX / 60 ))
  INV_FETCH_RETRIES=40   # fast inner retries for one clean CDBAng fetch (1s apart)

  inv_norm() { printf '%s\n' "$1" | sed '/^$/d' | sort -u | xargs; }
  inv_var() { printf '%s\n' "$INV" \
    | grep -oE "\"?$1\"?[[:space:]]*:[[:space:]]*\"?[^\",[:space:]]+" | sed -E 's/.*:[[:space:]]*"?//' || true; }
  # Fetch a clean inventory into $INV; retry fast past a transient CDBAng-unreachable fetch.
  # A bare CDBAng-Auth-Token error (no Skipping-key line) = gascan env not set → fatal.
  inv_fetch() {
    local a=0
    while :; do
      a=$((a+1))
      INV=$(gascan -get-inventory -refresh 2>&1 || true)
      if printf '%s' "$INV" | grep -q 'CDBAng-Auth-Token' && ! printf '%s' "$INV" | grep -q 'Skipping key'; then
        fail "inventory fetch failed with a bare CDBAng-Auth-Token error" \
             "gascan auth/inventory env not set for this shell — check ~/.config/gascan/* and the vars exported above, then re-run"
      fi
      if printf '%s' "$INV" | grep -q 'Skipping key (CDBAng-Auth-Id'; then
        [ "$a" -ge "$INV_FETCH_RETRIES" ] && return 1
        sleep 1; continue
      fi
      return 0
    done
  }
  inv_pending() {
    local p=""
    [ "$mon_gascan" != "${EXPECT_GASCAN}" ]   && p+=" gascan_version=[${mon_gascan:-∅}→${EXPECT_GASCAN}]"
    [ "$mon_tools"  != "${EXPECT_GASTOOLS}" ] && p+=" tools_gas_version=[${mon_tools:-∅}→${EXPECT_GASTOOLS}]"
    [ "$fleet_pmm"  != "${EXPECT_PMM}" ]      && p+=" pmm_version=[${fleet_pmm:-∅}→${EXPECT_PMM}]"
    printf '%s' "$p"
  }

  note "SN edits can lag several minutes — polling the refreshed inventory until it matches (every ${INV_POLL_INTERVAL}s, up to ~${INV_POLL_MIN} min)."
  i=0
  while :; do
    fetched=0
    if inv_fetch; then fetched=1; fi
    if [ "$fetched" -eq 1 ]; then
      mon_gascan=$(inv_norm "$(inv_var gascan_version)")
      mon_tools=$(inv_norm "$(inv_var tools_gas_version)")
      fleet_pmm=$(inv_norm "$(inv_var pmm_version)")
      [ "$mon_gascan" = "${EXPECT_GASCAN}" ] && [ "$mon_tools" = "${EXPECT_GASTOOLS}" ] && [ "$fleet_pmm" = "${EXPECT_PMM}" ] && break
    fi
    if [ "$i" -lt "$INV_POLL_MAX" ]; then
      i=$((i+1))
      if [ "$fetched" -eq 0 ]; then
        warn "inventory source (CDBAng) unreachable after ${INV_FETCH_RETRIES} fast retries — retry ${i}/${INV_POLL_MAX} in ${INV_POLL_INTERVAL}s"
      else
        warn "SN not propagated yet — retry ${i}/${INV_POLL_MAX} in ${INV_POLL_INTERVAL}s; pending:$(inv_pending)"
      fi
      sleep "$INV_POLL_INTERVAL"
    else
      note "gascan_version:    ${mon_gascan:-<none>}  (expect ${EXPECT_GASCAN})"
      note "tools_gas_version: ${mon_tools:-<none>}  (expect ${EXPECT_GASTOOLS})"
      note "pmm_version:       ${fleet_pmm:-<none>}  (expect ${EXPECT_PMM})"
      if [ "$BATCH" -eq 1 ] || [ ! -t 0 ]; then
        fail "inventory still does not match after ~${INV_POLL_MIN} min" "verify the SN variables for this env (step 1) are set to the targets, then re-run — do NOT deploy on stale/wrong inventory"
      fi
      warn "still not matching after ~${INV_POLL_MIN} min — confirm the SN vars for this env are saved to the targets."
      read -rp "   > [Enter to refresh + check once more / Ctrl-C to abort] " _
    fi
  done

  note "gascan_version:    ${mon_gascan}"
  note "tools_gas_version: ${mon_tools}"
  note "pmm_version:       ${fleet_pmm}"
  ok "inventory GATE passed — safe to deploy"
  state_save 3
fi

# ---------------------------------------------------------------------------
# 4. gas-tools
# ---------------------------------------------------------------------------
if ! skip_step 4 "gas-tools ${EXPECT_GASTOOLS}"; then
  step 4 "Upgrade gas-tools to ${EXPECT_GASTOOLS}"
  expect "gas-tools --version reports ${EXPECT_GASTOOLS} (tools.yaml run only if mismatched)"
  cur_tools=$(gas-tools --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
  note "current gas-tools: ${cur_tools:-<none>}"
  if [ "$cur_tools" = "${EXPECT_GASTOOLS}" ]; then
    ok "gas-tools already at ${EXPECT_GASTOOLS} — skipping tools.yaml"
  else
    pb=(--playbook tools.yaml --override=tools_gas_version="${EXPECT_GASTOOLS}")
    cmd "gascan ${pb[*]}"
    confirm "Upgrade gas-tools ${cur_tools:-<none>} -> ${EXPECT_GASTOOLS}?"
    run_playbook 4 "${pb[@]}"
    got=$(gas-tools --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
    note "gas-tools --version: ${got:-<unknown>}"
    case "$got" in
      "${EXPECT_GASTOOLS}") ok "gas-tools ${EXPECT_GASTOOLS} active" ;;
      # Intentionally team-facing (not a harness-only guard): GAS-1194 is a real product bug
      # any monitor can hit on re-deploy; this only prints on failure, with the repair.
      *) warn "gas-tools version != ${EXPECT_GASTOOLS} — symlink may be stale (GAS-1194); repair: rm -f ~/bin/gas-tools && ln -s gas-tools_${EXPECT_GASTOOLS} ~/bin/gas-tools && chmod u+x ~/bin/gas-tools_${EXPECT_GASTOOLS}, then re-check gas-tools --version" ;;
    esac
  fi
  state_save 4
fi

# <version-specific manual steps go here — fill from this release's test run; delete if none>


# ---------------------------------------------------------------------------
# 5. Alerting only (no server upgrade)
# ---------------------------------------------------------------------------
if ! skip_step 5 "alerting update"; then
  step 5 "Update alerting (no server upgrade)"
  expect "pmm-server.yaml alerting run completes (~3-4 min); PLAY RECAP failed=0"
  pb=(--playbook pmm-server.yaml --limit=monitors --override=pmm_deploy_using=None)
  cmd "gascan ${pb[*]}"
  confirm "Update alerting (no server upgrade)?"
  run_playbook 5 "${pb[@]}"
  ok "alerting updated"
  state_save 5
fi

# ---------------------------------------------------------------------------
# 6. PMM server
# ---------------------------------------------------------------------------
if ! skip_step 6 "PMM server ${EXPECT_PMM}"; then
  step 6 "Upgrade PMM server to ${EXPECT_PMM}"
  expect "pmm-server container running ${EXPECT_PMM} (pmm-server.yaml run only if mismatched)"
  cur_server=$(podman ps --format '{{.Image}}' 2>/dev/null | grep -i 'pmm-server' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
  note "current pmm-server image: ${cur_server:-<unknown>}"
  if [ "$cur_server" = "${EXPECT_PMM}" ]; then
    ok "pmm-server already at ${EXPECT_PMM} — skipping server upgrade"
  else
    pb=(--playbook pmm-server.yaml --limit=monitors --skip-tags=alerting --override=pmm_version="${EXPECT_PMM}")
    cmd "gascan ${pb[*]}"
    confirm "Upgrade PMM server ${cur_server:-<unknown>} -> ${EXPECT_PMM}?"
    run_playbook 6 "${pb[@]}"
    if podman ps | grep -q pmm-server; then ok "pmm-server container running"; else warn "pmm-server not visible in 'podman ps' — investigate before continuing"; fi
    podman ps --format '{{.Names}} {{.Image}} {{.Status}}' | grep -i pmm-server || true
  fi
  state_save 6
fi

# ---------------------------------------------------------------------------
# 7. PMM client
# ---------------------------------------------------------------------------
if ! skip_step 7 "PMM clients ${EXPECT_PMM}"; then
  step 7 "Upgrade PMM clients"
  expect "all clients report pmm-admin ${EXPECT_PMM} (pmm-client.yaml run only if any lag)"
  cur_clients=$(gascan -adhoc -- mongodb,mysql,postgresql,ha,monitors -m shell -a '~/pmm/bin/pmm-admin version 2>/dev/null | grep "^Ver"' 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -u | xargs || true)
  note "client pmm-admin versions present: ${cur_clients:-<unknown>}"
  if [ "$cur_clients" = "${EXPECT_PMM}" ]; then
    ok "all clients already at ${EXPECT_PMM} — skipping client upgrade"
  else
    note "client services BEFORE upgrade:"
    gascan -adhoc -- mongodb,mysql,postgresql,ha,monitors -m shell -a '~/pmm/bin/pmm-admin list' 2>/dev/null || true
    pb=(--playbook pmm-client.yaml --override=pmm_version="${EXPECT_PMM}")
    cmd "gascan ${pb[*]}"
    confirm "Upgrade PMM clients (present: ${cur_clients:-<unknown>}) -> ${EXPECT_PMM}?"
    amtool silence add --duration="1h" 'alertname=Percona_MS_NodeAgentDown' --comment="PMM${EXPECT_PMM} upgrade" >/dev/null 2>&1 || true
    silence_id=$(amtool silence query -q 'alertname=Percona_MS_NodeAgentDown' 2>/dev/null | head -n1 || true)
    if [ -n "$silence_id" ]; then ok "NodeAgentDown silenced (id: ${silence_id})"
    else warn "could not read back a NodeAgentDown silence id — check 'amtool silence' manually"; fi
    run_playbook 7 "${pb[@]}"
    note "client services AFTER upgrade (compare vs BEFORE — all should be present, version ${EXPECT_PMM}):"
    gascan -adhoc -- mongodb,mysql,postgresql,ha,monitors -m shell -a '~/pmm/bin/pmm-admin version | grep "^Ver"' 2>/dev/null || true
    gascan -adhoc -- mongodb,mysql,postgresql,ha,monitors -m shell -a '~/pmm/bin/pmm-admin list' 2>/dev/null || true
    ok "clients upgraded"
    echo
    warn "NodeAgentDown is STILL SILENCED (id: ${silence_id:-<see 'amtool silence'>}). Wait 5-10 min for clients to settle, then verify nothing real is firing:"
    echo
    echo "     # suppressed (under the DT silence) vs real alerts:"
    echo '     echo -e "\033[1;34m---=== Suppressed alerts (DT silence) ===---\033[0m"; amtool alert -s; echo; echo -e "\033[1;31m---=== Real alerts ===---\033[0m"; amtool alert'
    echo
    echo "     # just this alert under the silence:"
    echo "     amtool alert -s | grep -i Percona_MS_NodeAgentDown"
    echo
    echo "     # once NodeAgentDown is settled (NOT firing for real), expire the silence:"
    echo "     amtool silence expire ${silence_id:-<silence-id from 'amtool silence'>}"
  fi
  state_save 7
fi

# ---------------------------------------------------------------------------
# 8. Done — manual tracker update
# ---------------------------------------------------------------------------
if ! skip_step 8 "wrap-up"; then
  step 8 "Done"
  ok "upgrade sequence complete"
  note "MANUAL: update the PMM tracker -> $(hlink "https://docs.google.com/spreadsheets/d/1Hylu_DSw5YJYBPZbJmajSjTCitN4gm7XllriOCp9jTI/edit?gid=1362692116#gid=1362692116")"
  note "Customer Slack follow-up (optional): confirm PMM ${EXPECT_PMM} upgrade complete — no action required on customer side."
  state_clear
fi
