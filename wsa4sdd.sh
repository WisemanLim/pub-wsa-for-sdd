#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# WSA4SDD App (v1.1.0) — Service Deployment and Distribution Shell
# ─────────────────────────────────────────────────────────────────────────────
set -u

# ══ ANSI Styling & Escape Sequences ═══════════════════════════════════════════
ESC=$'\033'
CSI="${ESC}["
C_RST="${ESC}[0m"
C_BOLD="${ESC}[1m"
C_DIM="${ESC}[2m"
# Semantic colors are theme-driven (set by apply_theme). Defaults filled below.
C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""; C_WHITE=""; C_BG_BLUE=""

# ══ Themes (Claude-CLI style) ═════════════════════════════════════════════════
# 6 presets mirroring the Claude Code theme set. Roles: GREEN=success/select,
# YELLOW=warning, RED=error, CYAN=accent/prompt, WHITE=bright text.
THEME="dark"
_THEME_SET=0   # 1 once a theme has been chosen/loaded (suppresses first-run prompt)
THEME_NAMES=(dark light dark-daltonized light-daltonized dark-ansi light-ansi)

theme_label() {
  case "$1" in
    dark)             printf 'Dark' ;;
    light)            printf 'Light' ;;
    dark-daltonized)  printf 'Dark (colorblind-friendly)' ;;
    light-daltonized) printf 'Light (colorblind-friendly)' ;;
    dark-ansi)        printf 'Dark (ANSI 16-color)' ;;
    light-ansi)       printf 'Light (ANSI 16-color)' ;;
    *)                printf '%s' "$1" ;;
  esac
}

apply_theme() {
  local t="${1:-dark}"
  case "${t}" in
    dark)
      C_GREEN="${ESC}[32m"; C_YELLOW="${ESC}[33m"; C_RED="${ESC}[31m"
      C_CYAN="${ESC}[36m";  C_WHITE="${ESC}[97m"; C_BG_BLUE="${ESC}[44m" ;;
    light)
      C_GREEN="${ESC}[32m"; C_YELLOW="${ESC}[33m"; C_RED="${ESC}[31m"
      C_CYAN="${ESC}[34m";  C_WHITE="${ESC}[30m"; C_BG_BLUE="${ESC}[44m" ;;
    dark-daltonized)
      # avoid green/red confusion: success=blue, error=orange, accent=sky
      C_GREEN="${ESC}[38;5;39m";  C_YELLOW="${ESC}[38;5;220m"; C_RED="${ESC}[38;5;208m"
      C_CYAN="${ESC}[38;5;45m";   C_WHITE="${ESC}[97m";        C_BG_BLUE="${ESC}[48;5;24m" ;;
    light-daltonized)
      C_GREEN="${ESC}[38;5;26m";  C_YELLOW="${ESC}[38;5;136m"; C_RED="${ESC}[38;5;166m"
      C_CYAN="${ESC}[38;5;31m";   C_WHITE="${ESC}[30m";        C_BG_BLUE="${ESC}[48;5;153m" ;;
    dark-ansi)
      C_GREEN="${ESC}[32m"; C_YELLOW="${ESC}[33m"; C_RED="${ESC}[31m"
      C_CYAN="${ESC}[36m";  C_WHITE="${ESC}[37m"; C_BG_BLUE="${ESC}[44m" ;;
    light-ansi)
      C_GREEN="${ESC}[32m"; C_YELLOW="${ESC}[33m"; C_RED="${ESC}[31m"
      C_CYAN="${ESC}[34m";  C_WHITE="${ESC}[30m"; C_BG_BLUE="${ESC}[47m" ;;
    *)
      apply_theme dark; return ;;
  esac
  THEME="${t}"
}
apply_theme "dark"

# ══ Logging Helpers ═══════════════════════════════════════════════════════════
log()   { printf '%s▶%s %s\n' "${C_CYAN}"   "${C_RST}" "$*" >&2; }
ok()    { printf '%s✓%s %s\n' "${C_GREEN}"  "${C_RST}" "$*" >&2; }
warn()  { printf '%s!%s %s\n' "${C_YELLOW}" "${C_RST}" "$*" >&2; }
err()   { printf '%s✗%s %s\n' "${C_RED}"    "${C_RST}" "$*" >&2; }
die()   { err "$*"; cache_delete; _cleanup; exit 1; }

clog()   { log "$*"; }
cok()    { ok "$*"; }
cwarn()  { warn "$*"; }
cerr()   { err "$*"; }
cprint() { printf "%s\n" "$*"; }

# ══ Global Parameters & Configuration ═════════════════════════════════════════
WORKSPACE_DIR=""
OPS_NAME=""
declare -a INPUT_REPOS=()
NO_RUN=0
AUTH_METHOD=""
GITHUB_USERNAME=""
GITHUB_PAT=""
DEFAULT_TARGET=""
BOOTSTRAP_DONE=0

# Operational values determined dynamically during execution
OPS_DIR=""
CONF_FILE=""
declare -a SYNCED_NAMES=()
declare -a COMPOSE_FILES=()
OS_KIND=""
OS_FAMILY=""
PKG_MGR=""
PKG_INSTALL=""
DAEMON_NEEDS_SG=0
# Direct build/run detection (when ops repo has no compose/Makefile).
# One entry per detected app (parallel arrays — bash 3.2 has no assoc arrays).
declare -a RUN_APP_DIR=()    # absolute build-context dir per app
declare -a RUN_APP_KIND=()   # python | node
declare -a RUN_APP_ENTRY=()  # full Dockerfile CMD as a JSON array string
declare -a RUN_APP_NAME=()   # compose service name (sanitized)
declare -a RUN_APP_PORT=()   # container port (web/api/db apps) or "" if none
declare -a RUN_APP_ROLE=()   # ops | frontend | backend | database | cli | generic
AUTO_GENERATED=0             # 1 if compose/Makefile were auto-generated this run

# ══ Cache Management ══════════════════════════════════════════════════════════
_CACHE="/tmp/.wsa4sdd-${UID}.cache"

cache_save() {
  {
    printf 'CACHE_REPOS=%q\n'     "${INPUT_REPOS[*]:-}"
    printf 'CACHE_WORKSPACE=%q\n' "${WORKSPACE_DIR:-}"
    printf 'CACHE_OPS=%q\n'       "${OPS_NAME:-}"
    printf 'CACHE_AUTH=%q\n'      "${AUTH_METHOD:-}"
    printf 'CACHE_USER=%q\n'      "${GITHUB_USERNAME:-}"
    printf 'CACHE_TARGET=%q\n'    "${DEFAULT_TARGET:-}"
    printf 'CACHE_BOOTSTRAPPED=%q\n' "${BOOTSTRAP_DONE:-0}"
  } > "${_CACHE}"
  chmod 600 "${_CACHE}"
}

cache_load() {
  [[ -f "${_CACHE}" ]] || return 0
  local CACHE_REPOS="" CACHE_WORKSPACE="" CACHE_OPS=""
  local CACHE_AUTH="" CACHE_USER="" CACHE_TARGET="" CACHE_BOOTSTRAPPED=""
  # Load the cache file variables safely
  # shellcheck disable=SC1090
  . "${_CACHE}"
  [[ -n "${CACHE_REPOS}" ]]     && read -r -a INPUT_REPOS <<< "${CACHE_REPOS}" || true
  [[ -n "${CACHE_WORKSPACE}" ]] && WORKSPACE_DIR="${CACHE_WORKSPACE}"
  [[ -n "${CACHE_OPS}" ]]       && OPS_NAME="${CACHE_OPS}"
  [[ -n "${CACHE_AUTH}" ]]      && AUTH_METHOD="${CACHE_AUTH}"
  [[ -n "${CACHE_USER}" ]]      && GITHUB_USERNAME="${CACHE_USER}"
  [[ -n "${CACHE_TARGET}" ]]    && DEFAULT_TARGET="${CACHE_TARGET}"
  [[ -n "${CACHE_BOOTSTRAPPED}" ]] && BOOTSTRAP_DONE="${CACHE_BOOTSTRAPPED}"
}

cache_delete() {
  # Deletes the session cache ONLY. The theme cache is persistent and is never
  # removed here (Req: keep theme across /exit, Ctrl+C, dist-run success).
  rm -f "${_CACHE}" 2>/dev/null || true
}

# ── Theme cache (persistent, independent of the session cache) ────────────────
_THEME_CACHE="/tmp/.wsa4sdd-theme-${UID}.cache"

theme_save() {
  printf 'CACHE_THEME=%q\n' "${THEME:-dark}" > "${_THEME_CACHE}"
  chmod 600 "${_THEME_CACHE}" 2>/dev/null || true
}

theme_load() {
  [[ -f "${_THEME_CACHE}" ]] || return 0
  local CACHE_THEME=""
  # shellcheck disable=SC1090
  . "${_THEME_CACHE}"
  if [[ -n "${CACHE_THEME}" ]]; then apply_theme "${CACHE_THEME}"; _THEME_SET=1; fi
}

# ══ Interactive Prompt Inputs & Selectors ═════════════════════════════════════
MENU_IDX=0

run_menu() {
  local title="$1" sel="$2"; shift 2
  local -a items=("$@")
  local count="${#items[@]}"
  local total_lines=$(( count + 1 ))

  # Print title
  printf "  %s%s%s\n" "${C_BOLD}" "${title}" "${C_RST}"
  local i
  for (( i=0; i<count; i++ )); do
    if (( i == sel )); then
      printf "  %s▶ %s%s\n" "${C_GREEN}${C_BOLD}" "${items[$i]}" "${C_RST}"
    else
      printf "    %s\n" "${items[$i]}"
    fi
  done

  # Save current TTY settings and set raw mode to read arrow keys
  local old_stty; old_stty=$(stty -g 2>/dev/null)
  stty -echo -icanon min 1 time 0 2>/dev/null || true

  while true; do
    local key=""
    local char=""
    IFS= read -r -s -n1 char 2>/dev/null || char=""
    if [[ "${char}" == $'\x1b' ]]; then
      local next1="" next2=""
      stty -echo -icanon min 0 time 1 2>/dev/null || true
      IFS= read -r -s -n1 next1 2>/dev/null || next1=""
      if [[ "${next1}" == "[" || "${next1}" == "O" ]]; then
        IFS= read -r -s -n1 next2 2>/dev/null || next2=""
        case "${next2}" in
          A) key="UP";;
          B) key="DOWN";;
        esac
      fi
      stty -echo -icanon min 1 time 0 2>/dev/null || true
    elif [[ "${char}" == $'\n' || "${char}" == $'\r' || -z "${char}" ]]; then
      key="ENTER"
    elif [[ "${char}" == "q" || "${char}" == "Q" || "${char}" == $'\x1b' ]]; then
      key="ESC"
    elif [[ "${char}" == "k" ]]; then
      key="UP"
    elif [[ "${char}" == "j" ]]; then
      key="DOWN"
    fi

    if [[ "${key}" == "UP" ]]; then
      sel=$(( (sel - 1 + count) % count ))
    elif [[ "${key}" == "DOWN" ]]; then
      sel=$(( (sel + 1) % count ))
    elif [[ "${key}" == "ENTER" ]]; then
      # Erase menu lines and write selection
      printf "\033[%dA" "${total_lines}"
      printf "\033[J"
      printf "  %s%s:%s %s\n" "${C_BOLD}" "${title}" "${C_RST}" "${items[$sel]}"
      MENU_IDX="${sel}"
      stty "${old_stty}" 2>/dev/null || true
      return 0
    elif [[ "${key}" == "ESC" ]]; then
      # Erase menu lines and exit
      printf "\033[%dA" "${total_lines}"
      printf "\033[J"
      MENU_IDX=-1
      stty "${old_stty}" 2>/dev/null || true
      return 1
    fi

    # Redraw the list
    printf "\033[%dA" "${count}"
    for (( i=0; i<count; i++ )); do
      printf "\r\033[K"
      if (( i == sel )); then
        printf "  %s▶ %s%s\n" "${C_GREEN}${C_BOLD}" "${items[$i]}" "${C_RST}"
      else
        printf "    %s\n" "${items[$i]}"
      fi
    done
  done
}

cinput() {
  local prompt="$1" varname="$2" opt="${3:-}"
  printf "%s%s%s " "${C_CYAN}${C_BOLD}" "${prompt}" "${C_RST}"

  local val=""
  if [[ "${opt}" == "secret" ]]; then
    stty -echo 2>/dev/null || true
    read -r val
    stty echo 2>/dev/null || true
    printf "\n"
  else
    read -r val
  fi

  # trim whitespace
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"

  eval "${varname}=\"${val}\""
}

# ══ OS & Dependency Detection ═════════════════════════════════════════════════
detect_os() {
  OS_KIND=""; OS_FAMILY=""; PKG_MGR=""; PKG_INSTALL=""
  case "$(uname -s)" in
    Darwin)
      OS_KIND="macos"
      if command -v brew >/dev/null 2>&1; then
        PKG_MGR="brew"; PKG_INSTALL="brew install"
      else
        cwarn "Homebrew not found. Install from https://brew.sh"
      fi
      ;;
    Linux)
      OS_KIND="linux"
      if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID_LIKE:-$ID}" in
          *debian*|*ubuntu*)
            OS_FAMILY="debian"; PKG_MGR="apt"
            PKG_INSTALL="sudo apt-get update && sudo apt-get install -y" ;;
          *fedora*|*rhel*|*centos*|*rocky*|*almalinux*)
            OS_FAMILY="fedora"
            if command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"; else PKG_MGR="yum"; fi
            PKG_INSTALL="sudo ${PKG_MGR} install -y" ;;
          *arch*)
            OS_FAMILY="arch"; PKG_MGR="pacman"
            PKG_INSTALL="sudo pacman -S --noconfirm" ;;
          *)
            OS_FAMILY="unknown" ;;
        esac
      fi
      ;;
    *)
      die "Unsupported OS: $(uname -s)"
      ;;
  esac
  cok "OS: ${OS_KIND} (${OS_FAMILY:-unknown}), pkg=${PKG_MGR:-none}"
}

install_pkg() {
  local pkg="$1"
  [[ -n "${PKG_INSTALL}" ]] || die "No package manager — install ${pkg} manually."
  clog "Installing ${pkg}..."
  eval "${PKG_INSTALL} ${pkg}"
}

ensure_cmd() {
  local cmd="$1" pkg="${2:-$1}"
  if command -v "${cmd}" >/dev/null 2>&1; then
    cok "${cmd}: OK"
  else
    cwarn "${cmd} missing — installing"
    install_pkg "${pkg}"
    command -v "${cmd}" >/dev/null 2>&1 || die "${cmd} still missing after install"
  fi
}

repair_apt_gh_keyring() {
  [[ "${OS_FAMILY}" == "debian" ]] || return 0
  local out; out="$(sudo apt-get update 2>&1 || true)"
  grep -qE 'NO_PUBKEY[[:space:]]+23F3D4EA75716059|cli\.github\.com.*not signed' <<<"${out}" || return 0
  cwarn "GitHub CLI APT keyring broken — repairing"
  sudo mkdir -p /etc/apt/keyrings
  if curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null 2>&1; then
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    if sudo apt-get update -y 2>&1 | grep -qE 'NO_PUBKEY|not signed'; then
      cwarn "Keyring fix failed — disabling gh APT repo"
      sudo rm -f /etc/apt/sources.list.d/github-cli.list \
                 /etc/apt/keyrings/githubcli-archive-keyring.gpg
      sudo apt-get update -y >/dev/null 2>&1
    else
      cok "GitHub CLI keyring restored"
    fi
  fi
}

install_docker_debian() {
  clog "Installing Docker via official APT repo"
  sudo apt-get install -y ca-certificates curl gnupg >/dev/null 2>&1
  sudo install -m 0755 -d /etc/apt/keyrings
  if [[ ! -s /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  local distro codename arch
  distro="$(. /etc/os-release && echo "${ID}")"
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
  arch="$(dpkg --print-architecture)"
  [[ "${distro}" == "ubuntu" || "${distro}" == "debian" ]] || distro="ubuntu"
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${distro} ${codename} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -y >/dev/null 2>&1
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1
}

install_docker_rhel() {
  clog "Installing Docker via official ${PKG_MGR} repo"
  sudo "${PKG_MGR}" remove -y podman-docker >/dev/null 2>&1 || true
  command -v dnf >/dev/null 2>&1 \
    && sudo dnf install -y dnf-plugins-core >/dev/null 2>&1 \
    || sudo yum install -y yum-utils >/dev/null 2>&1
  local repo_distro
  case "$(. /etc/os-release && echo "${ID}")" in
    fedora) repo_distro="fedora" ;; rhel) repo_distro="rhel" ;; *) repo_distro="centos" ;;
  esac
  local repo_url="https://download.docker.com/linux/${repo_distro}/docker-ce.repo"
  if command -v dnf >/dev/null 2>&1; then
    sudo dnf config-manager --add-repo "${repo_url}" >/dev/null 2>&1 \
      || sudo dnf config-manager addrepo --from-repofile="${repo_url}" >/dev/null 2>&1
  else
    sudo yum-config-manager --add-repo "${repo_url}" >/dev/null 2>&1
  fi
  sudo "${PKG_MGR}" install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    cwarn "docker missing — installing"
    case "${OS_KIND}" in
      macos) install_pkg "--cask docker" ;;
      linux)
        case "${OS_FAMILY}" in
          debian) repair_apt_gh_keyring; install_docker_debian ;;
          fedora) install_docker_rhel ;;
          arch)   install_pkg "docker docker-compose" ;;
          *)      die "Unsupported Linux family for docker: ${OS_FAMILY}" ;;
        esac ;;
      *) die "Unsupported OS for docker install: ${OS_KIND}" ;;
    esac
    command -v docker >/dev/null 2>&1 || die "docker install failed"
  fi
  cok "docker: OK"

  DAEMON_NEEDS_SG=0
  if docker info >/dev/null 2>&1; then
    cok "docker daemon: running"
  elif sudo -n docker info >/dev/null 2>&1 || sudo docker info >/dev/null 2>&1; then
    cwarn "Docker daemon running, but socket not accessible without 'docker' group."
    DAEMON_NEEDS_SG=1
  else
    case "${OS_KIND}" in
      linux)
        clog "Starting docker daemon..."
        sudo systemctl enable --now docker >/dev/null 2>&1 || die "Failed to start docker" ;;
      macos)
        cwarn "Docker not running — launching Docker.app"
        open -ga Docker 2>/dev/null || true
        clog "Waiting up to 60s for docker daemon..."
        local i; for i in {1..30}; do docker info >/dev/null 2>&1 && break; sleep 2; done ;;
    esac
    docker info >/dev/null 2>&1 || sudo docker info >/dev/null 2>&1 \
      || die "docker daemon offline"
    cok "docker daemon: running"
  fi

  if [[ "${OS_KIND}" == "linux" ]]; then
    local me="${USER:-$(id -un)}"
    if ! getent group docker 2>/dev/null | grep -qE "(:|,)${me}(,|\$)"; then
      clog "Adding ${me} to docker group"
      sudo usermod -aG docker "${me}" 2>/dev/null || cwarn "usermod failed"
    fi
    if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
      cok "docker group: active"
      DAEMON_NEEDS_SG=0
    else
      cwarn "docker group not active in current shell — using sg docker -c"
      DAEMON_NEEDS_SG=1
    fi
  fi
  export DAEMON_NEEDS_SG

  if ! docker compose version >/dev/null 2>&1; then
    clog "docker compose v2 missing — installing plugin"
    case "${OS_FAMILY}" in
      debian) repair_apt_gh_keyring; install_docker_debian ;;
      fedora) install_docker_rhel ;;
      arch)   install_pkg "docker-compose" ;;
      *)      cwarn "Install docker compose v2 manually for ${OS_KIND}" ;;
    esac
    docker compose version >/dev/null 2>&1 || die "docker compose v2 still missing"
  fi
  cok "docker compose: OK"
}

ensure_make() {
  if command -v make >/dev/null 2>&1; then
    cok "make: OK"
    return
  fi
  cwarn "make missing — installing"
  install_pkg make
  command -v make >/dev/null 2>&1 || die "make install failed"
}

# ══ Repo Sync & Resolution ════════════════════════════════════════════════════
# A repo "spec" is "<url>" or "<url>#<branch>". Helpers split the two parts.
repo_url_part()    { printf '%s' "${1%%#*}"; }
repo_branch_part() { case "$1" in *#*) printf '%s' "${1#*#}" ;; *) printf '' ;; esac; }
repo_name_from_url() { local u; u="$(repo_url_part "$1")"; u="${u%.git}"; basename "${u}"; }

ssh_to_https() {
  local url="$1"
  [[ "${url}" =~ ^git@([^:]+):(.+)$ ]] \
    && printf 'https://%s/%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" \
    || printf '%s' "${url}"
}

sync_repo() {
  local spec="$1"
  local url branch
  url="$(repo_url_part "${spec}")"
  branch="$(repo_branch_part "${spec}")"
  local name; name="$(repo_name_from_url "${spec}")"
  local target="${WORKSPACE_DIR}/${name}"
  local -a git_opts=()
  local clone_url="${url}"

  if [[ "${AUTH_METHOD}" == "pat" && -n "${_PAT_CRED_FILE}" ]]; then
    clone_url="$(ssh_to_https "${url}")"
    git_opts+=("-c" "credential.helper=store --file=${_PAT_CRED_FILE}")
  fi

  local tmpf; tmpf="$(mktemp)"; local rc=0

  if [[ -d "${target}/.git" ]]; then
    local cur want
    cur="$(git -C "${target}" symbolic-ref --quiet --short HEAD 2>/dev/null || echo main)"
    want="${branch:-${cur}}"
    clog "Pulling ${name} (branch: ${want})..."
    git ${git_opts+"${git_opts[@]}"} -C "${target}" fetch --all --prune >"${tmpf}" 2>&1 || true
    if [[ -n "${branch}" && "${branch}" != "${cur}" ]]; then
      git ${git_opts+"${git_opts[@]}"} -C "${target}" checkout "${branch}" >>"${tmpf}" 2>&1 || rc=$?
    fi
    git ${git_opts+"${git_opts[@]}"} -C "${target}" pull --ff-only origin "${want}" >>"${tmpf}" 2>&1 || rc=$?
    (( rc == 0 )) && cok "Pulled: ${name} (${want})" || cwarn "${name}: pull skipped (rc=${rc})"
  elif [[ -e "${target}" ]]; then
    cwarn "${target} exists but not a git repo — skipping"
  else
    if [[ -n "${branch}" ]]; then
      clog "Cloning ${name} (branch: ${branch})..."
      git ${git_opts+"${git_opts[@]}"} clone -b "${branch}" "${clone_url}" "${target}" >"${tmpf}" 2>&1 || rc=$?
    else
      clog "Cloning ${name}..."
      git ${git_opts+"${git_opts[@]}"} clone "${clone_url}" "${target}" >"${tmpf}" 2>&1 || rc=$?
    fi
    if (( rc != 0 )); then
      cerr "Clone failed: ${name}${branch:+ (branch: ${branch})}"
      while IFS= read -r line; do cwarn "  ${line}"; done < "${tmpf}"
      rm -f "${tmpf}"
      return 1   # signal failure to caller (do NOT die: this runs in a $() subshell)
    fi
    cok "Cloned: ${name}${branch:+ (${branch})}"
  fi
  rm -f "${tmpf}"
  printf '%s\n' "${name}"
}

sync_all_repos() {
  clog "Workspace: ${WORKSPACE_DIR}"
  SYNCED_NAMES=()
  local url name rc fail=0
  for url in "${INPUT_REPOS[@]}"; do
    [[ -n "${url}" ]] || continue
    rc=0
    name="$(sync_repo "${url}")" || rc=$?
    if (( rc != 0 )) || [[ -z "${name}" ]]; then
      cerr "Repository sync failed: ${url}"
      fail=1
      continue
    fi
    SYNCED_NAMES+=("${name}")
  done
  if (( fail )); then
    cerr "One or more repositories failed to sync — aborting."
    return 1
  fi
  [[ ${#SYNCED_NAMES[@]} -gt 0 ]] || { cerr "No repositories synced."; return 1; }
  cok "Synced: ${SYNCED_NAMES[*]}"
}

find_compose_files() {
  find "$1" \
    \( -name .git -o -name node_modules -o -name vendor -o -name dist \
       -o -name build -o -name .venv -o -name venv -o -name __pycache__ \) -prune -o \
    -maxdepth 6 -type f \
    \( -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' \
       -o -name 'compose.yml' -o -name 'compose.yaml' \) \
    -print 2>/dev/null
}

resolve_ops_dir() {
  if [[ -z "${OPS_NAME}" ]]; then
    local n
    for n in "${SYNCED_NAMES[@]}"; do
      if [[ -n "$(find_compose_files "${WORKSPACE_DIR}/${n}" | head -n1)" ]]; then
        OPS_NAME="${n}"; break
      fi
    done
    [[ -n "${OPS_NAME}" ]] || OPS_NAME="${SYNCED_NAMES[0]}"
  fi
  OPS_DIR="${WORKSPACE_DIR}/${OPS_NAME}"
  [[ -d "${OPS_DIR}" ]] || die "Ops dir not found: ${OPS_DIR}"
  CONF_FILE="${OPS_DIR}/.dist-standard.conf"
  cok "Ops project: ${OPS_NAME}"
}

load_compose_files() {
  COMPOSE_FILES=()
  if [[ -f "${OPS_DIR}/Makefile" ]]; then
    cok "Makefile already present"
    return
  fi
  local abs rel
  while IFS= read -r abs; do
    [[ -z "${abs}" ]] && continue
    rel="${abs#${OPS_DIR}/}"; COMPOSE_FILES+=("${rel}")
  done < <(find_compose_files "${OPS_DIR}" | sort)
  if [[ ${#COMPOSE_FILES[@]} -eq 0 ]]; then
    cwarn "No docker-compose*.yml under ${OPS_DIR} — deployment target list may be empty"
    NO_RUN=1; return
  fi
  clog "Compose files found: ${COMPOSE_FILES[*]}"
}

generate_makefile() {
  local mk="${OPS_DIR}/Makefile"
  [[ -f "${mk}" ]] && { cok "Makefile already present"; return; }
  [[ ${#COMPOSE_FILES[@]} -gt 0 ]] || return
  cwarn "Makefile missing — generating from compose files"

  local TAB; TAB=$'\t'   # real tab for recipe lines (echo -e would mangle '\n' in recipes)
  local base="" f bn shallowest=99 depth
  for f in "${COMPOSE_FILES[@]}"; do
    bn="$(basename "${f}")"
    if [[ "${bn}" == "docker-compose.yml" || "${bn}" == "compose.yml" \
       || "${bn}" == "docker-compose.yaml" || "${bn}" == "compose.yaml" ]]; then
      depth="$(awk -F/ '{print NF}' <<<"${f}")"
      (( depth < shallowest )) && { shallowest="${depth}"; base="${f}"; }
    fi
  done

  {
    echo "SHELL := /bin/bash"
    echo "# Auto-generated by WSA4SDD App"
    echo ""
    local flags=""; [[ -n "${base}" ]] && flags="-f ${base}"
    echo ".PHONY: help up down ps logs build clean"
    echo ""
    echo "help:"
    echo "${TAB}@grep -E '^[a-zA-Z0-9_-]+:.*?## ' \$(MAKEFILE_LIST) | awk 'BEGIN{FS=\":.*?## \"};{printf \"  %-30s %s\\n\", \$\$1, \$\$2}'"
    echo ""
    local dir tag dtag
    for f in "${COMPOSE_FILES[@]}"; do
      [[ "${f}" == "${base}" ]] && continue
      bn="$(basename "${f}")"; dir="$(dirname "${f}")"
      tag="${bn%.yml}"; tag="${tag%.yaml}"
      tag="${tag#docker-compose.}"; tag="${tag#docker-compose}"
      tag="${tag#compose.}"; tag="${tag#compose}"
      if [[ "${dir}" != "." ]]; then
        dtag="${dir//\//-}"
        [[ -n "${tag}" ]] && tag="${dtag}-${tag}" || tag="${dtag}"
      fi
      [[ -z "${tag}" ]] && continue
      echo "up-${tag}: ## up: ${f}"
      echo "${TAB}docker compose ${flags} -f ${f} up -d"
      echo "down-${tag}: ## down: ${f}"
      echo "${TAB}docker compose ${flags} -f ${f} down"
      echo ""
    done
    if [[ -n "${base}" ]]; then
      echo "up: ## up base (${base})"
      echo "${TAB}docker compose ${flags} up -d"
      echo "down: ## down base"
      echo "${TAB}docker compose ${flags} down"
      echo "ps:"
      echo "${TAB}docker compose ${flags} ps"
      echo "logs:"
      echo "${TAB}docker compose ${flags} logs -f --tail=200"
      echo "build:"
      echo "${TAB}docker compose ${flags} build"
      echo "clean:"
      echo "${TAB}docker compose ${flags} down -v --remove-orphans"
    fi
  } > "${mk}"
  cok "Generated Makefile under ${mk}"
}

# Populate COMPOSE_FILES (relative paths) from the ops dir — no side effects.
scan_compose_files() {
  COMPOSE_FILES=()
  local abs rel
  while IFS= read -r abs; do
    [[ -z "${abs}" ]] && continue
    rel="${abs#${OPS_DIR}/}"; COMPOSE_FILES+=("${rel}")
  done < <(find_compose_files "${OPS_DIR}" | sort)
}

# Is this dir already recorded as an app?
_app_seen() {
  local d="$1" i
  for (( i=0; i<${#RUN_APP_DIR[@]}; i++ )); do
    [[ "${RUN_APP_DIR[$i]}" == "${d}" ]] && return 0
  done
  return 1
}

# Is this dir inside (a subdir of) an already-recorded app dir?
_app_under() {
  local d="$1" i
  for (( i=0; i<${#RUN_APP_DIR[@]}; i++ )); do
    case "${d}/" in "${RUN_APP_DIR[$i]}/"*) return 0 ;; esac
  done
  return 1
}

# Find a Python entry (relative to the app dir) using common conventions.
_find_python_entry() {
  local d="$1" c found
  for c in main.py app.py hello.py app/main.py src/main.py wsgi.py asgi.py __main__.py; do
    [[ -f "${d}/${c}" ]] && { printf '%s' "${c}"; return 0; }
  done
  found="$(find "${d}" \( -name .venv -o -name venv -o -name .git \) -prune -o \
           -maxdepth 2 -type f -name '*.py' -print 2>/dev/null | sort | head -n1)"
  [[ -n "${found}" ]] && { printf '%s' "${found#${d}/}"; return 0; }
  return 1
}

# Build the Python Dockerfile CMD (JSON) for an app. Echoes "CMD_JSON|PORT".
# Uses uvicorn when fastapi/uvicorn is a dependency and an ASGI app is found.
_python_cmd_for() {
  local d="$1" entry="$2" dotted asgivar
  if grep -qiE 'fastapi|uvicorn|starlette' "${d}/pyproject.toml" "${d}/requirements.txt" "${d}/setup.py" 2>/dev/null; then
    dotted="${entry%.py}"; dotted="${dotted//\//.}"
    asgivar="$(grep -hoE '^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*FastAPI\(' "${d}/${entry}" 2>/dev/null \
               | head -n1 | sed -E 's/[[:space:]]*=.*//')"
    [[ -n "${asgivar}" ]] || asgivar="app"
    printf '["uvicorn","%s:%s","--host","0.0.0.0","--port","8000"]|8000' "${dotted}" "${asgivar}"
    return 0
  fi
  printf '["python","%s"]|' "${entry}"
}

# Classify a service role from its name + signals, to drive compose wiring.
_classify_role() {  # name kind entry port
  local name="$1" kind="$2" entry="$3" port="$4"
  case "${name}" in
    *db|db-*|*-db|*-db-*|*database*|*postgres*|*mysql*|*mariadb*|*mongo*|*redis*) printf 'database'; return ;;
    *cli*|*-tool*|*command*|*-cmd*|*worker*|*-job*) printf 'cli'; return ;;
    *backend*|*-api|*-api-*|api-*|*-server|server-*|*gateway*) printf 'backend'; return ;;
    *frontend*|*front*|*-web|web-*|*-webui*|*-ui|ui-*|*client*) printf 'frontend'; return ;;
  esac
  case "${entry}" in *uvicorn*) printf 'backend'; return ;; esac
  if [[ "${kind}" == node ]]; then
    case "${entry}" in
      *hello.js*) printf 'cli'; return ;;
      *) printf 'frontend'; return ;;          # server.js/index.js/npm start → web frontend
    esac
  fi
  [[ -n "${port}" ]] && { printf 'backend'; return; }
  printf 'cli'                                  # python standalone script (prints & exits)
}

_app_add() {  # dir kind entry-json port
  local role; role="$(_classify_role "$(_app_name_from_dir "$1")" "$2" "$3" "$4")"
  local port="$4"
  # Default ports by role so containers are reachable / wiring matches.
  [[ "${role}" == frontend && -z "${port}" ]] && port="3000"
  [[ "${role}" == database && -z "${port}" ]] && port="5432"
  RUN_APP_DIR+=("$1"); RUN_APP_KIND+=("$2"); RUN_APP_ENTRY+=("$3"); RUN_APP_PORT+=("${port}")
  RUN_APP_NAME+=("$(_app_name_from_dir "$1")"); RUN_APP_ROLE+=("${role}")
}

# Derive a sanitized, globally-unique compose service name from an app dir.
# Apps inside the ops repo use their path within it; apps in OTHER repos are
# prefixed by their repo name (relative to the workspace) so names never clash.
_app_name_from_dir() {
  local d="$1" rel name
  if [[ "${d}" == "${OPS_DIR}" ]]; then rel="app"
  elif [[ "${d}" == "${OPS_DIR}/"* ]]; then rel="${d#${OPS_DIR}/}"
  elif [[ -n "${WORKSPACE_DIR}" && "${d}" == "${WORKSPACE_DIR}/"* ]]; then rel="${d#${WORKSPACE_DIR}/}"
  else rel="$(basename "${d}")"; fi
  name="$(printf '%s' "${rel}" | tr '/' '-' | tr '[:upper:]' '[:lower:]' \
          | sed -E -e 's/(^|-)apps(-|$)/\1\2/g' -e 's/[^a-z0-9-]/-/g' -e 's/-{2,}/-/g' -e 's/^-//' -e 's/-$//')"
  [[ -n "${name}" ]] || name="app"
  printf '%s' "${name}"
}

# Repos to scan for runnable apps: every synced repo (Req: check all repos),
# falling back to the ops dir when no sync list is available (e.g. unit tests).
_scan_roots() {
  if [[ ${#SYNCED_NAMES[@]} -gt 0 && -n "${WORKSPACE_DIR}" ]]; then
    local n
    for n in "${SYNCED_NAMES[@]}"; do [[ -n "${n}" ]] && printf '%s\n' "${WORKSPACE_DIR}/${n}"; done
  else
    printf '%s\n' "${OPS_DIR}"
  fi
}

# docker-compose build context (relative to the ops dir) for an app dir,
# using ../<repo>/... for apps that live in sibling repos.
_app_build_context() {
  local d="$1"
  if [[ "${d}" == "${OPS_DIR}" ]]; then printf '.'
  elif [[ "${d}" == "${OPS_DIR}/"* ]]; then printf '%s' "${d#${OPS_DIR}/}"
  elif [[ -n "${WORKSPACE_DIR}" && "${d}" == "${WORKSPACE_DIR}/"* ]]; then printf '../%s' "${d#${WORKSPACE_DIR}/}"
  else printf '%s' "${d}"; fi
}

# (Req 1) Detect ALL direct build/run apps under the ops repo (no compose/Makefile).
# Populates RUN_APP_* arrays — one entry per app dir. Returns 0 if any found.
detect_run_apps() {
  RUN_APP_DIR=(); RUN_APP_KIND=(); RUN_APP_ENTRY=(); RUN_APP_NAME=(); RUN_APP_PORT=(); RUN_APP_ROLE=()
  local f dir entry cmdport root
  local -a roots=()
  while IFS= read -r root; do [[ -n "${root}" ]] && roots+=("${root}"); done < <(_scan_roots)

  # Scan EVERY registered repo (Req: not just the ops repo).
  for root in "${roots[@]}"; do
    [[ -d "${root}" ]] || continue

    # Node apps: each dir containing a package.json.
    while IFS= read -r f; do
      [[ -z "${f}" ]] && continue
      dir="$(dirname "${f}")"
      _app_seen "${dir}" && continue
      if grep -qE '"start"[[:space:]]*:' "${f}" 2>/dev/null; then entry='["npm","start"]'
      elif [[ -f "${dir}/index.js"  ]]; then entry='["node","index.js"]'
      elif [[ -f "${dir}/server.js" ]]; then entry='["node","server.js"]'
      elif [[ -f "${dir}/hello.js"  ]]; then entry='["node","hello.js"]'
      else entry='["npm","start"]'; fi
      _app_add "${dir}" "node" "${entry}" ""
    done < <(find "${root}" \( -name node_modules -o -name .git \) -prune -o \
              -maxdepth 5 -type f -name package.json -print 2>/dev/null | sort)

    # Python apps — prefer the MANIFEST dir as build context so deps install
    # even when the entry is nested (app/main.py).
    while IFS= read -r f; do
      [[ -z "${f}" ]] && continue
      dir="$(dirname "${f}")"
      _app_seen "${dir}" && continue
      entry="$(_find_python_entry "${dir}")" || continue
      cmdport="$(_python_cmd_for "${dir}" "${entry}")"
      _app_add "${dir}" "python" "${cmdport%%|*}" "${cmdport#*|}"
    done < <(find "${root}" \( -name .git -o -name .venv -o -name venv \) -prune -o \
              -maxdepth 5 -type f \( -name pyproject.toml -o -name requirements.txt -o -name setup.py \) -print 2>/dev/null | sort)

    # Python apps without a manifest — a standalone entry script's dir.
    while IFS= read -r f; do
      [[ -z "${f}" ]] && continue
      dir="$(dirname "${f}")"
      _app_seen "${dir}" && continue
      _app_under "${dir}" && continue
      _app_add "${dir}" "python" "[\"python\",\"$(basename "${f}")\"]" ""
    done < <(find "${root}" \( -name .git -o -name .venv -o -name venv \) -prune -o \
              -maxdepth 5 -type f \( -name hello.py -o -name main.py -o -name app.py \) -print 2>/dev/null | sort)
  done

  [[ ${#RUN_APP_DIR[@]} -gt 0 ]]
}

# Write a per-app Dockerfile (kind-specific) if absent.
_write_app_dockerfile() {
  local dir="$1" kind="$2" entry="$3"
  local df="${dir}/Dockerfile"
  [[ -f "${df}" ]] && return 0
  case "${kind}" in
    python)
      {
        echo "# Auto-generated by WSA4SDD App"
        echo "FROM python:3.12-slim"
        echo "WORKDIR /app"
        echo "COPY . ."
        echo "RUN if [ -f requirements.txt ]; then pip install --no-cache-dir -r requirements.txt; fi"
        echo "RUN if [ -f pyproject.toml ]; then pip install --no-cache-dir . || true; fi"
        # Guarantee server deps for detected ASGI apps even if pyproject packaging is imperfect.
        case "${entry}" in *uvicorn*)
          echo 'RUN pip install --no-cache-dir fastapi "uvicorn[standard]"'
          echo "EXPOSE 8000" ;;
        esac
        echo "CMD ${entry}"
      } > "${df}" ;;
    node)
      {
        echo "# Auto-generated by WSA4SDD App"
        echo "FROM node:22-slim"
        echo "WORKDIR /app"
        echo "COPY . ."
        echo "RUN if [ -f package.json ]; then npm install --omit=dev || npm install || true; fi"
        echo "CMD ${entry}"
      } > "${df}" ;;
    *) return 1 ;;
  esac
  cok "Generated Dockerfile ($(_app_build_context "${dir}")/Dockerfile)"
}

# (Req 2) Generate Dockerfiles + a docker-compose.yml with ONE service per app.
generate_compose_from_apps() {
  local compose="${OPS_DIR}/docker-compose.yml" i dir name rel repo port role
  [[ ${#RUN_APP_DIR[@]} -gt 0 ]] || return 1
  repo="$(basename "${OPS_DIR}")"

  for (( i=0; i<${#RUN_APP_DIR[@]}; i++ )); do
    _write_app_dockerfile "${RUN_APP_DIR[$i]}" "${RUN_APP_KIND[$i]}" "${RUN_APP_ENTRY[$i]}" \
      || { cerr "Dockerfile generation failed for ${RUN_APP_NAME[$i]}"; return 1; }
  done

  # Identify the backend & database services so frontends/backends can be wired.
  local backend_svc="" backend_port="8000" db_svc=""
  for (( i=0; i<${#RUN_APP_DIR[@]}; i++ )); do
    if [[ -z "${backend_svc}" && "${RUN_APP_ROLE[$i]}" == backend ]]; then
      backend_svc="${RUN_APP_NAME[$i]}"; backend_port="${RUN_APP_PORT[$i]:-8000}"
    fi
    [[ -z "${db_svc}" && "${RUN_APP_ROLE[$i]}" == database ]] && db_svc="${RUN_APP_NAME[$i]}"
  done

  {
    echo "# Auto-generated by WSA4SDD App"
    echo "services:"
    local host_port used=" "
    for (( i=0; i<${#RUN_APP_DIR[@]}; i++ )); do
      dir="${RUN_APP_DIR[$i]}"; name="${RUN_APP_NAME[$i]}"
      port="${RUN_APP_PORT[$i]}"; role="${RUN_APP_ROLE[$i]}"
      rel="$(_app_build_context "${dir}")"   # ../<repo>/... for sibling-repo apps
      echo "  ${name}:"
      echo "    build: ${rel}"
      echo "    image: ${repo}-${name}"

      # environment + depends_on by role (frontend→backend, backend→database)
      if [[ "${role}" == frontend && -n "${backend_svc}" ]]; then
        echo "    environment:"
        echo "      - BACKEND_URL=http://${backend_svc}:${backend_port}"
        echo "    depends_on:"
        echo "      - ${backend_svc}"
      elif [[ "${role}" == backend && -n "${db_svc}" ]]; then
        echo "    environment:"
        echo "      - DATABASE_URL=postgresql://app:app@${db_svc}:5432/app"
        echo "    depends_on:"
        echo "      - ${db_svc}"
      fi

      # publish a host port (collision-free) for reachable roles; cli gets none
      if [[ -n "${port}" ]]; then
        host_port="${port}"
        while [[ "${used}" == *" ${host_port} "* ]]; do host_port=$(( host_port + 1 )); done
        used="${used}${host_port} "
        echo "    ports:"
        echo "      - \"${host_port}:${port}\""
      fi
    done
  } > "${compose}"
  cok "Generated docker-compose.yml with ${#RUN_APP_DIR[@]} service(s): ${RUN_APP_NAME[*]}"
}

# (Req 2) Generate a Makefile with base + per-service targets covering every app.
generate_makefile_for_apps() {
  local mk="${OPS_DIR}/Makefile" i name TAB; TAB=$'\t'
  {
    echo "SHELL := /bin/bash"
    echo "# Auto-generated by WSA4SDD App"
    echo ""
    printf '.PHONY: help up down ps logs build clean'
    for (( i=0; i<${#RUN_APP_NAME[@]}; i++ )); do printf ' up-%s down-%s' "${RUN_APP_NAME[$i]}" "${RUN_APP_NAME[$i]}"; done
    echo ""
    echo ""
    echo "help:"
    echo "${TAB}@grep -E '^[a-zA-Z0-9_-]+:.*?## ' \$(MAKEFILE_LIST) | awk 'BEGIN{FS=\":.*?## \"};{printf \"  %-30s %s\\n\", \$\$1, \$\$2}'"
    echo ""
    echo "up: ## up all services"
    echo "${TAB}docker compose up -d"
    for (( i=0; i<${#RUN_APP_NAME[@]}; i++ )); do
      name="${RUN_APP_NAME[$i]}"
      echo "up-${name}: ## up ${name}"
      echo "${TAB}docker compose up -d ${name}"
    done
    echo "down: ## down all services"
    echo "${TAB}docker compose down"
    for (( i=0; i<${#RUN_APP_NAME[@]}; i++ )); do
      name="${RUN_APP_NAME[$i]}"
      echo "down-${name}: ## stop & remove ${name}"
      echo "${TAB}docker compose rm -sf ${name}"
    done
    echo "ps:"
    echo "${TAB}docker compose ps"
    echo "logs:"
    echo "${TAB}docker compose logs -f --tail=200"
    echo "build:"
    echo "${TAB}docker compose build"
    echo "clean:"
    echo "${TAB}docker compose down -v --remove-orphans"
  } > "${mk}"
  cok "Generated Makefile (${#RUN_APP_NAME[@]} app(s), per-service up-*/down-* targets)"
}

# Orchestrate ops preparation per Req 1-3. Returns 0 if /dist-run can proceed.
ensure_runnable_ops() {
  AUTO_GENERATED=0
  local mk="${OPS_DIR}/Makefile"

  # (Req 3, part A) Makefile already present → use it as-is.
  if [[ -f "${mk}" ]]; then
    cok "Makefile already present — using it"
    return 0
  fi

  # (Req 3, part B) docker-compose present but no Makefile → generate Makefile from compose.
  scan_compose_files
  if [[ ${#COMPOSE_FILES[@]} -gt 0 ]]; then
    clog "docker-compose found, Makefile missing — generating Makefile from compose"
    generate_makefile || { cerr "Makefile generation failed."; return 1; }
    return 0
  fi

  # (Req 1) No compose and no Makefile → look for direct build/run apps (all of them).
  cwarn "No docker-compose and no Makefile in '${OPS_NAME}'."
  clog "Detecting direct build/run apps (python/node)..."
  if detect_run_apps; then
    cok "Detected ${#RUN_APP_DIR[@]} app(s): ${RUN_APP_NAME[*]}"
    # (Req 2) Generate one compose service per app, then a Makefile covering all.
    generate_compose_from_apps   || { cerr "Failed to generate docker-compose."; return 1; }
    generate_makefile_for_apps   || { cerr "Makefile generation failed."; return 1; }
    AUTO_GENERATED=1
    cok "Auto-generated docker-compose.yml + Makefile for '${OPS_NAME}' (${#RUN_APP_DIR[@]} app(s))."
    return 0
  fi

  # (Req 1, fail) Nothing runnable detected → /dist-run cannot proceed.
  cerr "No docker-compose, no Makefile, and no recognizable build/run method in '${OPS_NAME}'."
  cerr "Cannot prepare a deployment — /dist-run is not available for this repository."
  return 1
}

list_make_up_targets() {
  local mk="${OPS_DIR}/Makefile"; [[ -f "${mk}" ]] || return
  local all up_only
  all="$(awk -F: '/^[A-Za-z0-9_.\/-]+[ \t]*:/{name=$1;sub(/[ \t]+$/,"",name);if(name~/^\./||name=="help"||name=="list-targets")next;print name}' "${mk}" | sort -u)"
  up_only="$(grep -E '^up(-|$)' <<<"${all}" || true)"
  [[ -n "${up_only}" ]] && printf '%s\n' "${up_only}" || printf '%s\n' "${all}"
}

load_default() {
  [[ -f "${CONF_FILE:-}" ]] || { DEFAULT_TARGET=""; return; }
  # shellcheck disable=SC1090
  . "${CONF_FILE}"
  DEFAULT_TARGET="${LAST_TARGET:-}"
}

save_default() {
  [[ -n "${CONF_FILE:-}" ]] || return 0
  printf 'LAST_TARGET=%q\nLAST_RUN=%q\n' "$1" "$(date -u +%FT%TZ)" > "${CONF_FILE}"
}

dump_unhealthy_logs() {
  cwarn "Collecting logs from unhealthy containers..."
  local use_sg=0
  [[ "${OS_KIND}" == "linux" && "${DAEMON_NEEDS_SG:-0}" -eq 1 ]] \
    && command -v sg >/dev/null 2>&1 && use_sg=1

  local listing
  (( use_sg )) \
    && listing="$(sg docker -c 'docker ps -a --format "{{.Names}}\t{{.Status}}"' 2>/dev/null || true)" \
    || listing="$(docker ps -a --format '{{.Names}}\t{{.Status}}' 2>/dev/null || true)"
  [[ -n "${listing}" ]] || { cwarn "No containers found"; return; }

  while IFS=$'\t' read -r name status; do
    [[ -z "${name}" ]] && continue
    [[ "${status}" == *"(healthy)"* ]] && continue
    { [[ "${status}" == "Up "* ]] && [[ "${status}" != *"(unhealthy)"* ]]; } && continue
    clog "── ${name} (${status}) ──"
    local logs
    (( use_sg )) \
      && logs="$(sg docker -c "docker logs --tail=40 '${name}' 2>&1" || true)" \
      || logs="$(docker logs --tail=40 "${name}" 2>&1 || true)"
    while IFS= read -r line; do printf "  %s\n" "${line}"; done <<< "${logs}"
  done <<< "${listing}"
}

_finalize_docker_access() {
  [[ "${OS_KIND}" == "linux" ]] || return 0
  [[ "${DAEMON_NEEDS_SG:-0}" -eq 1 ]] || return 0
  command -v sg >/dev/null 2>&1 || { cwarn "'sg' not available — log out/in to activate docker group"; return 0; }

  local items=("sg docker 서브셸 실행 (권장)" "활성화 방법 안내" "건너뜀")
  run_menu "Docker Group 활성화" 0 "${items[@]}" || return 0

  case "${MENU_IDX}" in
    0) exec sg docker -c "${SHELL:-/bin/bash}" ;;
    1)
      printf "\n현재 터미널에서 아래 중 하나를 실행하세요:\n"
      printf "  %snewgrp docker%s\n" "${C_GREEN}" "${C_RST}"
      printf "  %sexec sg docker -c \"\$SHELL\"%s\n" "${C_GREEN}" "${C_RST}"
      printf "  로그아웃 후 재로그인\n\n" ;;
  esac
}

# ══ State Helpers (NOT SET / PENDING / DONE) ══════════════════════════════════
# 설정 상태를 한곳에서 판정한다. repo/workspace/auth 가 모두 채워져야 bootstrap 가능.
is_valid_repo_url() {
  local u; u="$(repo_url_part "$1")"   # validate URL part; "#branch" suffix is allowed
  [[ -n "${u}" ]] || return 1
  case "${u}" in
    git@*:*)               return 0 ;;   # SSH shorthand (git@host:owner/repo)
    ssh://*/*)             return 0 ;;
    https://*/*|http://*/*) return 0 ;;
  esac
  # Local path that exists (a directory or a bare/working git repo)
  [[ -e "${u}" ]] && return 0
  return 1
}

count_valid_repos() {
  local n=0 u
  for u in "${INPUT_REPOS[@]:-}"; do
    [[ -n "${u}" ]] || continue
    is_valid_repo_url "${u}" && n=$((n + 1))
  done
  printf '%d' "${n}"
}

repo_is_set()      { [[ "$(count_valid_repos)" -ge 1 ]]; }
workspace_is_set() { [[ -n "${WORKSPACE_DIR}" ]]; }
auth_is_set()      { [[ -n "${AUTH_METHOD}" ]]; }
bootstrap_ready()  { repo_is_set && workspace_is_set && auth_is_set; }

# Bootstrap is DONE only when every prerequisite is set AND bootstrap has run.
# Otherwise it is PENDING (Req 5).
bootstrap_status_str() {
  if bootstrap_ready && [[ "${BOOTSTRAP_DONE:-0}" -eq 1 ]]; then
    printf 'DONE'
  else
    printf 'PENDING'
  fi
}

# Print which prerequisites are still [NOT SET] (used by /status and /dist-run).
print_not_set_items() {
  repo_is_set      || printf "    %s• Repos%s     %s[NOT SET]%s  → run %s/repo%s\n"      "${C_BOLD}" "${C_RST}" "${C_RED}" "${C_RST}" "${C_BOLD}" "${C_RST}"
  workspace_is_set || printf "    %s• Workspace%s %s[NOT SET]%s  → run %s/workspace%s\n" "${C_BOLD}" "${C_RST}" "${C_RED}" "${C_RST}" "${C_BOLD}" "${C_RST}"
  auth_is_set      || printf "    %s• Auth%s      %s[NOT SET]%s  → run %s/auth%s\n"      "${C_BOLD}" "${C_RST}" "${C_RED}" "${C_RST}" "${C_BOLD}" "${C_RST}"
}

# Invalidate a completed bootstrap whenever configuration changes (Req 5 integrity).
invalidate_bootstrap() { BOOTSTRAP_DONE=0; }

# ══ Module: System Environment Check ══════════════════════════════════════════
# 시스템 환경 확인 — 설치 없이 OS 감지 + 필수 도구 존재 여부만 보고한다.
system_env_check() {
  clog "System environment check (no install)..."
  detect_os
  local tool
  for tool in git docker make; do
    if command -v "${tool}" >/dev/null 2>&1; then
      cok "${tool}: present"
    else
      cwarn "${tool}: missing (pre-install will handle)"
    fi
  done
  if [[ "${AUTH_METHOD}" == "gh" ]]; then
    command -v gh >/dev/null 2>&1 && cok "gh: present" || cwarn "gh: missing (pre-install will handle)"
  fi
}

# ══ Module: Pre-Install Dependencies ══════════════════════════════════════════
# 사전 설치 — 누락된 의존성을 설치하고 인증/데몬 전제를 준비한다.
pre_install_deps() {
  clog "Pre-install: ensuring dependencies..."
  if [[ "${AUTH_METHOD}" == "gh" ]]; then
    ensure_cmd git
    ensure_cmd gh
    if ! gh auth status >/dev/null 2>&1; then
      cwarn "gh CLI not authenticated. Running gh auth login..."
      gh auth login || { cerr "gh auth login failed."; return 1; }
    fi
  else
    ensure_cmd git
  fi
  ensure_docker
  ensure_make
}

# ══ Commands Logic ════════════════════════════════════════════════════════════
move_item_loop() {
  local ref_list_name="$1"
  local idx="$2"
  eval "local -a list=(\"\${${ref_list_name}[@]}\")"
  local count="${#list[@]}"
  local total_lines=$(( count + 2 ))

  while true; do
    printf "  %sMove the selected item [Up/Down], Enter to lock, ESC to cancel:%s\n" "${C_BOLD}" "${C_RST}"
    local i
    for (( i=0; i<count; i++ )); do
      if (( i == idx )); then
        printf "  %s⇄ %d) %s%s\n" "${C_YELLOW}${C_BOLD}" $((i+1)) "${list[$i]}" "${C_RST}"
      else
        printf "    %d) %s\n" $((i+1)) "${list[$i]}"
      fi
    done
    printf "    Done\n"

    local key=""
    local char=""
    IFS= read -r -s -n1 char 2>/dev/null || char=""
    if [[ "${char}" == $'\x1b' ]]; then
      local next1="" next2=""
      stty -echo -icanon min 0 time 1 2>/dev/null || true
      IFS= read -r -s -n1 next1 2>/dev/null || next1=""
      if [[ "${next1}" == "[" || "${next1}" == "O" ]]; then
        IFS= read -r -s -n1 next2 2>/dev/null || next2=""
        case "${next2}" in
          A) key="UP";;
          B) key="DOWN";;
        esac
      fi
      stty -echo -icanon min 1 time 0 2>/dev/null || true
    elif [[ "${char}" == $'\n' || "${char}" == $'\r' || -z "${char}" ]]; then
      key="ENTER"
    elif [[ "${char}" == "q" || "${char}" == "Q" || "${char}" == $'\x1b' ]]; then
      key="ESC"
    elif [[ "${char}" == "k" ]]; then
      key="UP"
    elif [[ "${char}" == "j" ]]; then
      key="DOWN"
    fi

    if [[ "${key}" == "UP" ]]; then
      if (( idx > 0 )); then
        local temp="${list[$idx]}"
        list[$idx]="${list[$((idx-1))]}"
        list[$((idx-1))]="${temp}"
        idx=$((idx - 1))
      fi
    elif [[ "${key}" == "DOWN" ]]; then
      if (( idx < count - 1 )); then
        local temp="${list[$idx]}"
        list[$idx]="${list[$((idx+1))]}"
        list[$((idx+1))]="${temp}"
        idx=$((idx + 1))
      fi
    elif [[ "${key}" == "ENTER" || "${key}" == "ESC" ]]; then
      printf "\033[%dA" "${total_lines}"
      printf "\033[J"
      eval "${ref_list_name}=(\"\${list[@]}\")"
      return 0
    fi

    printf "\033[%dA" "$((total_lines - 1))"
  done
}

reorder_repos_ui() {
  local ref_name="$1"
  eval "local -a list=(\"\${${ref_name}[@]}\")"
  local count="${#list[@]}"
  local sel=0
  local total_lines=$(( count + 2 ))

  local old_stty; old_stty=$(stty -g 2>/dev/null)
  stty -echo -icanon min 1 time 0 2>/dev/null || true

  while true; do
    printf "  %sSelect repository to move, or choose Done:%s\n" "${C_BOLD}" "${C_RST}"
    local i
    for (( i=0; i<count; i++ )); do
      if (( i == sel )); then
        printf "  %s▶ %d) %s%s\n" "${C_GREEN}${C_BOLD}" $((i+1)) "${list[$i]}" "${C_RST}"
      else
        printf "    %d) %s\n" $((i+1)) "${list[$i]}"
      fi
    done
    if (( sel == count )); then
      printf "  %s▶ Done%s\n" "${C_GREEN}${C_BOLD}" "${C_RST}"
    else
      printf "    Done\n"
    fi

    local key=""
    local char=""
    IFS= read -r -s -n1 char 2>/dev/null || char=""
    if [[ "${char}" == $'\x1b' ]]; then
      local next1="" next2=""
      stty -echo -icanon min 0 time 1 2>/dev/null || true
      IFS= read -r -s -n1 next1 2>/dev/null || next1=""
      if [[ "${next1}" == "[" || "${next1}" == "O" ]]; then
        IFS= read -r -s -n1 next2 2>/dev/null || next2=""
        case "${next2}" in
          A) key="UP";;
          B) key="DOWN";;
        esac
      fi
      stty -echo -icanon min 1 time 0 2>/dev/null || true
    elif [[ "${char}" == $'\n' || "${char}" == $'\r' || -z "${char}" ]]; then
      key="ENTER"
    elif [[ "${char}" == "q" || "${char}" == "Q" || "${char}" == $'\x1b' ]]; then
      key="ESC"
    elif [[ "${char}" == "k" ]]; then
      key="UP"
    elif [[ "${char}" == "j" ]]; then
      key="DOWN"
    fi

    if [[ "${key}" == "UP" ]]; then
      sel=$(( (sel - 1 + count + 1) % (count + 1) ))
    elif [[ "${key}" == "DOWN" ]]; then
      sel=$(( (sel + 1) % (count + 1) ))
    elif [[ "${key}" == "ENTER" ]]; then
      if (( sel == count )); then
        printf "\033[%dA" "${total_lines}"
        printf "\033[J"
        stty "${old_stty}" 2>/dev/null || true
        eval "${ref_name}=(\"\${list[@]}\")"
        return 0
      else
        printf "\033[%dA" "${total_lines}"
        printf "\033[J"
        move_item_loop list "${sel}"
        stty -echo -icanon min 1 time 0 2>/dev/null || true
      fi
    elif [[ "${key}" == "ESC" ]]; then
      printf "\033[%dA" "${total_lines}"
      printf "\033[J"
      stty "${old_stty}" 2>/dev/null || true
      eval "${ref_name}=(\"\${list[@]}\")"
      return 0
    fi

    printf "\033[%dA" "$((total_lines - 1))"
  done
}

handle_repo() {
  if [[ $# -gt 0 ]]; then
    local -a valid=() u
    # Accept comma-separated specs too (e.g. "url1#dev,url2").
    local -a args=(); local a
    for a in "$@"; do a="${a//,/ }"; read -r -a _split <<< "${a}"; args+=("${_split[@]:-}"); done
    for u in "${args[@]:-}"; do
      [[ -n "${u}" ]] || continue
      if is_valid_repo_url "${u}"; then
        valid+=("${u}")
      else
        cwarn "Invalid repo URL skipped: ${u}"
      fi
    done
    if [[ ${#valid[@]} -gt 0 ]]; then
      INPUT_REPOS=("${valid[@]}")
      cok "Repositories updated: ${INPUT_REPOS[*]}"
      invalidate_bootstrap
      cache_save
    else
      cwarn "No valid repositories provided. Repos remain [NOT SET]."
    fi
  else
    local -a temp_repos=("${INPUT_REPOS[@]:-}")
    while true; do
      printf "\n%s━━ Repository Manager ━━%s\n" "${C_BOLD}" "${C_RST}"
      if [[ ${#temp_repos[@]} -eq 0 ]]; then
        printf "  %s(No repositories registered)%s\n" "${C_DIM}" "${C_RST}"
      else
        local i
        for (( i=0; i<${#temp_repos[@]}; i++ )); do
          printf "  %d) %s\n" $((i+1)) "${temp_repos[$i]}"
        done
      fi
      printf "\n"

      local -a items=()
      items+=("Add Repository")
      if [[ ${#temp_repos[@]} -gt 0 ]]; then
        items+=("Delete Repository")
        items+=("Clear All")
      fi
      if [[ ${#temp_repos[@]} -gt 1 ]]; then
        items+=("Change Order (Reorder)")
      fi
      items+=("Save & Exit")
      items+=("Cancel & Discard")

      run_menu "Actions" 0 "${items[@]}"
      local action="${items[${MENU_IDX:-0}]}"

      if [[ "${MENU_IDX}" -eq -1 ]]; then
        cwarn "Discarded changes."
        return 0
      fi

      case "${action}" in
        "Add Repository")
          if [[ ${#temp_repos[@]} -ge 8 ]]; then
            cwarn "Maximum limit of 8 repositories reached."
            continue
          fi
          local input=""
          cinput "Repo URL(s) — space/comma separated, optional #branch:" input
          if [[ -n "${input}" ]]; then
            input="${input//,/ }"
            local -a specs=(); read -r -a specs <<< "${input}"
            local s
            for s in "${specs[@]:-}"; do
              [[ -n "${s}" ]] || continue
              if [[ ${#temp_repos[@]} -ge 8 ]]; then
                cwarn "Maximum limit of 8 repositories reached."
                break
              fi
              if is_valid_repo_url "${s}"; then
                temp_repos+=("${s}")
                cok "Added: ${s}"
              else
                cwarn "Invalid repo URL: ${s} (expected https://, git@host:…, ssh://, or an existing path; optional #branch)"
              fi
            done
          fi
          ;;
        "Delete Repository")
          run_menu "Select Repository to Delete" 0 "${temp_repos[@]}"
          if (( MENU_IDX >= 0 )); then
            local deleted="${temp_repos[${MENU_IDX}]}"
            local -a next_repos=()
            local i
            for (( i=0; i<${#temp_repos[@]}; i++ )); do
              if (( i != MENU_IDX )); then
                next_repos+=("${temp_repos[$i]}")
              fi
            done
            temp_repos=("${next_repos[@]}")
            cok "Deleted: ${deleted}"
          fi
          ;;
        "Clear All")
          local confirm_items=("Yes, Clear All" "No, Keep Them")
          run_menu "Are you sure you want to clear all registered repositories?" 1 "${confirm_items[@]}"
          if (( MENU_IDX == 0 )); then
            temp_repos=()
            cok "Cleared all repositories."
          fi
          ;;
        "Change Order (Reorder)")
          reorder_repos_ui temp_repos
          ;;
        "Save & Exit")
          INPUT_REPOS=("${temp_repos[@]:-}")
          invalidate_bootstrap
          cok "Saved repositories changes."
          cache_save
          return 0
          ;;
        "Cancel & Discard")
          cwarn "Discarded changes."
          return 0
          ;;
      esac
    done
  fi
}

handle_workspace() {
  if [[ $# -gt 0 ]]; then
    WORKSPACE_DIR="$1"
    mkdir -p "${WORKSPACE_DIR}"
    WORKSPACE_DIR="$(cd "${WORKSPACE_DIR}" && pwd)"
    cok "Workspace updated: ${WORKSPACE_DIR}"
    invalidate_bootstrap
    cache_save
  else
    local cwd="${PWD}"
    local parent; parent="$(cd "${cwd}/.." && pwd)"
    local items=(
      "Current dir  →  ${cwd}"
      "Parent dir   →  ${parent}"
      "Custom path..."
    )
    run_menu "Select Clone Workspace" 0 "${items[@]}"
    case "${MENU_IDX}" in
      0) WORKSPACE_DIR="${cwd}" ;;
      1) WORKSPACE_DIR="${parent}" ;;
      2)
        local custom=""
        cinput "Custom path:" custom
        custom="${custom/#\~/$HOME}"
        WORKSPACE_DIR="${custom:-${cwd}}"
        ;;
      *) return ;;
    esac
    mkdir -p "${WORKSPACE_DIR}"
    WORKSPACE_DIR="$(cd "${WORKSPACE_DIR}" && pwd)"
    cok "Workspace resolved: ${WORKSPACE_DIR}"
    invalidate_bootstrap
    cache_save
  fi
}

# Build the temporary git credential file from GITHUB_USERNAME/GITHUB_PAT.
set_pat_credentials() {
  [[ -n "${GITHUB_PAT}" ]] || return 1
  _PAT_CRED_FILE="$(mktemp)"; chmod 600 "${_PAT_CRED_FILE}"
  if [[ -n "${GITHUB_USERNAME}" ]]; then
    printf 'https://%s:%s@github.com\n' "${GITHUB_USERNAME}" "${GITHUB_PAT}" > "${_PAT_CRED_FILE}"
  else
    printf 'https://x-access-token:%s@github.com\n' "${GITHUB_PAT}" > "${_PAT_CRED_FILE}"
  fi
}

# Current GitHub login name (empty if gh missing or not logged in).
gh_current_user() {
  command -v gh >/dev/null 2>&1 || return 1
  gh api user -q .login 2>/dev/null
}

# Auth action 1 — show gh login status & current user.
auth_gh_status() {
  if ! command -v gh >/dev/null 2>&1; then
    cerr "gh CLI not installed. Choose 'Register PAT' or install gh first."
    return 1
  fi
  gh auth status 2>&1 | while IFS= read -r line; do printf "  %s\n" "${line}"; done
  local u; u="$(gh_current_user || true)"
  if [[ -n "${u}" ]]; then
    GITHUB_USERNAME="${u}"; AUTH_METHOD="gh"
    cok "Current GitHub user: ${u}"
    invalidate_bootstrap; cache_save
  else
    cwarn "Not logged in to gh. Use 'gh auth login'."
  fi
}

# Auth action 2 — switch active gh account.
auth_gh_switch() {
  if ! command -v gh >/dev/null 2>&1; then cerr "gh CLI not installed."; return 1; fi
  gh auth switch || { cwarn "gh auth switch did not complete."; return 1; }
  local u; u="$(gh_current_user || true)"
  GITHUB_USERNAME="${u}"; AUTH_METHOD="gh"
  cok "Switched account. Current user: ${u:-unknown}"
  invalidate_bootstrap; cache_save
}

# Auth action 3 — interactive gh login.
auth_gh_login() {
  if ! command -v gh >/dev/null 2>&1; then cerr "gh CLI not installed."; return 1; fi
  gh auth login || { cerr "gh auth login failed."; return 1; }
  local u; u="$(gh_current_user || true)"
  GITHUB_USERNAME="${u}"; AUTH_METHOD="gh"
  cok "Logged in. Current user: ${u:-unknown}"
  invalidate_bootstrap; cache_save
}

# Auth action 4 — register a Personal Access Token (PAT).
auth_pat_register() {
  cinput "GitHub Username (선택사항):" GITHUB_USERNAME
  cinput "Personal Access Token:" GITHUB_PAT "secret"
  if [[ -n "${GITHUB_PAT}" ]]; then
    AUTH_METHOD="pat"
    set_pat_credentials
    cok "PAT saved to temporary credentials file."
    invalidate_bootstrap; cache_save
  else
    cwarn "PAT is empty — Auth remains [NOT SET]."
  fi
}

handle_auth() {
  # Non-interactive / scripting path (also keeps gh|pat|none for back-compat).
  if [[ $# -gt 0 ]]; then
    case "$1" in
      status) auth_gh_status ;;
      switch) auth_gh_switch ;;
      login)  auth_gh_login ;;
      pat)    auth_pat_register ;;
      gh|none)
        AUTH_METHOD="$1"
        cok "Auth method updated: ${AUTH_METHOD}"
        invalidate_bootstrap; cache_save
        ;;
      *)
        cerr "Unknown auth action: $1. Use: status | switch | login | pat | gh | none"
        return
        ;;
    esac
    return
  fi

  # Interactive menu — the 4 actions required by the spec (Req 4).
  local items=(
    "gh login status   — 현재 로그인 사용자 확인"
    "gh auth switch    — 계정 전환"
    "gh auth login     — 신규 로그인"
    "Register PAT      — Personal Access Token 등록"
  )
  run_menu "Select Auth Action" 0 "${items[@]}"
  case "${MENU_IDX}" in
    0) auth_gh_status ;;
    1) auth_gh_switch ;;
    2) auth_gh_login ;;
    3) auth_pat_register ;;
    *) return ;;
  esac
}

handle_bootstrap() {
  # Req 5: bootstrap proceeds only when repo + workspace + auth are all set.
  if ! bootstrap_ready; then
    cwarn "Bootstrap is [PENDING] — the following are [NOT SET]:"
    print_not_set_items
    cerr "Set the items above, then run /bootstrap again."
    return 1
  fi

  # Module 1: system environment check (detect + report, no install).
  system_env_check

  # Module 2: pre-install missing dependencies.
  pre_install_deps || return 1

  clog "Synchronizing repositories..."
  sync_all_repos || { cerr "Bootstrap aborted: repository sync failed. (Bootstrap stays [PENDING])"; return 1; }

  clog "Resolving operations directory..."
  resolve_ops_dir || { cerr "Bootstrap aborted: could not resolve ops directory."; return 1; }

  clog "Preparing deployment (compose / Makefile)..."
  if ! ensure_runnable_ops; then
    cerr "Bootstrap aborted: '${OPS_NAME}' has no runnable deployment. (Bootstrap stays [PENDING])"
    return 1
  fi

  cok "Bootstrap completed successfully!"
  if (( AUTO_GENERATED )); then
    cok "docker-compose.yml & Makefile were auto-generated — run /dist-run (or /D) to deploy."
  fi
  BOOTSTRAP_DONE=1
  cache_save
}

# Render a one-line swatch of the current theme's semantic colors.
theme_preview() {
  printf "    %s✓ success%s  %s! warning%s  %s✗ error%s  %s▶ accent%s  %sbright%s\n" \
    "${C_GREEN}" "${C_RST}" "${C_YELLOW}" "${C_RST}" "${C_RED}" "${C_RST}" \
    "${C_CYAN}${C_BOLD}" "${C_RST}" "${C_WHITE}${C_BOLD}" "${C_RST}"
}

handle_theme() {
  # Non-interactive / scripting path.
  if [[ $# -gt 0 ]]; then
    case "$1" in
      dark|light|dark-daltonized|light-daltonized|dark-ansi|light-ansi)
        apply_theme "$1"; _THEME_SET=1
        cok "Theme: $(theme_label "${THEME}")"
        theme_preview
        theme_save ;;
      *)
        cerr "Unknown theme: $1. Options: ${THEME_NAMES[*]}"; return ;;
    esac
    return
  fi

  # Interactive selector (default selection = current theme).
  local items=() t cur=0 i=0
  for t in "${THEME_NAMES[@]}"; do
    items+=("$(theme_label "${t}")")
    [[ "${t}" == "${THEME}" ]] && cur="${i}"
    i=$((i + 1))
  done
  run_menu "Select Theme" "${cur}" "${items[@]}" || return 0
  apply_theme "${THEME_NAMES[${MENU_IDX}]}"; _THEME_SET=1
  cok "Theme: $(theme_label "${THEME}")"
  theme_preview
  theme_save
}

# First-run theme picker (only when no theme has been chosen yet).
first_run_theme() {
  (( _THEME_SET )) && return 0
  printf "\n  %s🎨 Choose a theme%s %s(change anytime with /theme)%s\n" \
    "${C_BOLD}${C_CYAN}" "${C_RST}" "${C_DIM}" "${C_RST}"
  handle_theme
}

handle_status() {
  printf "\n%s━━ WSA4SDD Configuration Status ━━%s\n" "${C_BOLD}" "${C_RST}"

  # Workspace
  if [[ -n "${WORKSPACE_DIR}" ]]; then
    printf "  Workspace : %s%s%s\n" "${C_GREEN}" "${WORKSPACE_DIR}" "${C_RST}"
  else
    printf "  Workspace : %s[NOT SET]%s (Use /workspace to set)\n" "${C_RED}" "${C_RST}"
  fi

  # Repositories — [NOT SET] when 0 repos or none are valid (Req 2)
  if repo_is_set; then
    printf "  Repos     : %s%s%s\n" "${C_GREEN}" "${INPUT_REPOS[*]}" "${C_RST}"
  else
    printf "  Repos     : %s[NOT SET]%s (Use /repo to set)\n" "${C_RED}" "${C_RST}"
  fi

  # Auth Method — shows method + current GitHub user when known (Req 4)
  if auth_is_set; then
    if [[ -n "${GITHUB_USERNAME}" ]]; then
      printf "  Auth      : %s%s (user: %s)%s\n" "${C_GREEN}" "${AUTH_METHOD}" "${GITHUB_USERNAME}" "${C_RST}"
    else
      printf "  Auth      : %s%s%s\n" "${C_GREEN}" "${AUTH_METHOD}" "${C_RST}"
    fi
  else
    printf "  Auth      : %s[NOT SET]%s (Use /auth to set)\n" "${C_RED}" "${C_RST}"
  fi

  # Ops Project
  if [[ -n "${OPS_NAME}" ]]; then
    printf "  Ops Repo  : %s%s%s\n" "${C_GREEN}" "${OPS_NAME}" "${C_RST}"
  else
    printf "  Ops Repo  : %s[NOT SET]%s (Resolved during /bootstrap)\n" "${C_DIM}" "${C_RST}"
  fi

  # Bootstrap status — DONE only when all prerequisites set AND bootstrapped (Req 5)
  if [[ "$(bootstrap_status_str)" == "DONE" ]]; then
    printf "  Bootstrap : %s[DONE]%s\n" "${C_GREEN}" "${C_RST}"
  else
    printf "  Bootstrap : %s[PENDING]%s (Run /bootstrap once Repos/Workspace/Auth are set)\n" "${C_YELLOW}" "${C_RST}"
    if ! bootstrap_ready; then
      print_not_set_items
    fi
  fi

  # Theme
  printf "  Theme     : %s%s%s\n" "${C_CYAN}" "$(theme_label "${THEME}")" "${C_RST}"

  printf "\n"
}

handle_dist_run() {
  # Req 6: dist-run does NOT auto-bootstrap. If bootstrap is [PENDING],
  # guide the user, show what is [NOT SET], and abort without running.
  if [[ "$(bootstrap_status_str)" != "DONE" ]]; then
    cwarn "Bootstrap is [PENDING] — run /bootstrap (or /B) before /dist-run."
    if bootstrap_ready; then
      clog "All prerequisites are set. Just run /bootstrap to proceed."
    else
      cwarn "The following are [NOT SET]:"
      print_not_set_items
    fi
    cerr "Deployment aborted — nothing was executed."
    return 1
  fi

  # 3. Present Make Target menu
  load_default
  local raw=()
  while IFS= read -r _t; do
    [[ -n "${_t}" ]] && raw+=("${_t}")
  done < <(list_make_up_targets)

  if [[ ${#raw[@]} -eq 0 ]]; then
    cerr "No make targets found in ${OPS_DIR}/Makefile. Cannot run deployment."
    return 1
  fi

  local display=() def_idx=0 i
  for (( i=0; i<${#raw[@]}; i++ )); do
    if [[ "${raw[$i]}" == "${DEFAULT_TARGET}" ]]; then
      display+=("${raw[$i]}  (last used)")
      def_idx="${i}"
    else
      display+=("${raw[$i]}")
    fi
  done
  display+=("Custom target…")

  run_menu "Select Make Target [ops: ${OPS_NAME}]" "${def_idx}" "${display[@]}" || return 1

  local target=""
  if (( MENU_IDX == ${#display[@]}-1 )); then
    cinput "Custom target:" target
    [[ -z "${target}" ]] && return 1
  else
    target="${raw[${MENU_IDX}]}"
  fi
  DEFAULT_TARGET="${target}"
  cache_save

  # 4. Pre-run commands
  clog "Pre-run commands (Optional. Enter empty line to skip)"
  while true; do
    local ucmd=""
    cinput "Command:" ucmd
    [[ -z "${ucmd}" ]] && break
    clog "Running: ${ucmd}"
    local rc=0
    if [[ "${OS_KIND}" == "linux" && "${DAEMON_NEEDS_SG:-0}" -eq 1 ]] && command -v sg >/dev/null 2>&1; then
      sg docker -c "cd \"${OPS_DIR}\" && ${ucmd}" || rc=$?
    else
      ( cd "${OPS_DIR}" && bash -c "${ucmd}" ) || rc=$?
    fi
    if (( rc != 0 )); then
      cwarn "Command exited with status ${rc}"
    else
      cok "Done"
    fi
  done

  # 5. Confirm Deployment
  local items=("▶ Run Now" "✗ Cancel")
  run_menu "Deploy?" 0 "${items[@]}" || return 1
  if (( MENU_IDX == 1 )); then
    cwarn "Deployment cancelled."
    return 1
  fi

  # 6. Execute Make target
  clog "Executing: make -C \"${OPS_DIR}\" ${target}"
  save_default "${target}"

  local exit_code=0
  if [[ "${OS_KIND}" == "linux" && "${DAEMON_NEEDS_SG:-0}" -eq 1 ]] && command -v sg >/dev/null 2>&1; then
    sg docker -c "cd \"${OPS_DIR}\" && make ${target}" || exit_code=$?
  else
    ( cd "${OPS_DIR}" && make "${target}" ) || exit_code=$?
  fi

  if (( exit_code != 0 )); then
    cerr "Deployment failed (make exited with ${exit_code})"
    dump_unhealthy_logs
    return "${exit_code}"
  fi

  cok "Deployment completed successfully!"

  # 7. Finalize Docker Access (Linux only)
  _finalize_docker_access

  # Delete cache on successful completion
  cache_delete
  exit 0
}

# ══ UI Lifecycle & Screen Redrawing ═══════════════════════════════════════════
print_welcome() {
  printf "\n"
  printf "  %sWSA4SDD App (v1.1.0)%s — Service Deployment and Distribution Shell\n" "${C_BOLD}${C_CYAN}" "${C_RST}"
  printf "  %sLives in your terminal, manages git repos, and deploys docker-compose.%s\n" "${C_DIM}" "${C_RST}"
  printf "  %s─────────────────────────────────────────────────────────────────────────────%s\n" "${C_DIM}" "${C_RST}"
  printf "  Commands:\n"
  printf "    %s/repo, /R [url[#branch] ...]%s   Configure repo URLs (space/comma sep, optional #branch); manager if empty\n" "${C_BOLD}" "${C_RST}"
  printf "    %s/workspace, /W [path]%s       Configure target workspace directory path (or open menu if empty)\n" "${C_BOLD}" "${C_RST}"
  printf "    %s/auth, /A [status|switch|login|pat]%s  GitHub auth: gh status/switch/login or PAT (menu if empty)\n" "${C_BOLD}" "${C_RST}"
  printf "    %s/bootstrap, /B%s              System check + pre-install + sync repos (needs Repos/Workspace/Auth set)\n" "${C_BOLD}" "${C_RST}"
  printf "    %s/status, /S%s                 Show current configuration status\n" "${C_BOLD}" "${C_RST}"
  printf "    %s/theme, /T [name]%s           Switch color theme (dark|light|*-daltonized|*-ansi; menu if empty)\n" "${C_BOLD}" "${C_RST}"
  printf "    %s/dist-run, /D%s               Verify configurations and run make deployment\n" "${C_BOLD}" "${C_RST}"
  printf "    %s/help, /H%s                   Show this help message\n" "${C_BOLD}" "${C_RST}"
  printf "    %s/exit, /E%s                   Exit wsa4sdd shell and clear cache\n" "${C_BOLD}" "${C_RST}"
  printf "    %s! <command>%s                 Execute a shell command and display the output\n" "${C_BOLD}" "${C_RST}"
  printf "  %s─────────────────────────────────────────────────────────────────────────────%s\n" "${C_DIM}" "${C_RST}"
  printf "\n"

  if [[ -f "${_CACHE}" ]]; then
    printf "  %s⚡ Loaded previous session cache.%s\n" "${C_YELLOW}" "${C_RST}"
    printf "\n"
  fi
}

# ══ Traps & Signal Handlers ═══════════════════════════════════════════════════
_PAT_CRED_FILE=""
_cleanup() {
  [[ -n "${_PAT_CRED_FILE:-}" ]] && rm -f "${_PAT_CRED_FILE}" 2>/dev/null || true
  stty sane 2>/dev/null || true
}
trap '_cleanup' EXIT TERM HUP

_INT_LAST=0
_int_handler() {
  local now="${SECONDS}"
  if (( now - _INT_LAST <= 2 )); then
    cache_delete
    _cleanup
    exit 130
  fi
  _INT_LAST="${now}"
  printf "\n%s!%s Press Ctrl+C again within 2 seconds to exit (clears cache)\n" "${C_YELLOW}" "${C_RST}"
}
trap '_int_handler' INT

# ══ Modes Execution ═══════════════════════════════════════════════════════════
# ══ REPL Line Editor & History ════════════════════════════════════════════════
declare -a REPL_HISTORY=()
REPL_HIST_FILE="/tmp/.wsa4sdd_history"

load_history() {
  if [[ -f "${REPL_HIST_FILE}" ]]; then
    while IFS= read -r line; do
      [[ -n "${line}" ]] && REPL_HISTORY+=("${line}")
    done < "${REPL_HIST_FILE}"
  fi
}

save_history() {
  local h
  printf "" > "${REPL_HIST_FILE}"
  for h in "${REPL_HISTORY[@]:-}"; do
    if [[ -n "${h}" ]]; then
      printf "%s\n" "${h}" >> "${REPL_HIST_FILE}"
    fi
  done
}

repl_read() {
  local buffer=""
  local cursor=0
  local hist_pos=${#REPL_HISTORY[@]}
  local prompt="${C_BOLD}${C_GREEN}>    ${C_RST}"
  local menu_sel=0
  local menu_closed=0

  local old_stty; old_stty=$(stty -g 2>/dev/null)
  stty -echo -icanon min 1 time 0 2>/dev/null || true

  while true; do
    # 1. Filter commands and determine menu state
    local -a all_commands=(
      "/repo"
      "/workspace"
      "/auth"
      "/bootstrap"
      "/status"
      "/theme"
      "/dist-run"
      "/help"
      "/exit"
    )
    local -a filtered_items=()
    local menu_active=0

    if (( ! menu_closed )) && [[ "${buffer}" == /* && "${buffer}" != *" "* ]]; then
      local cmd
      for cmd in "${all_commands[@]}"; do
        if [[ "${cmd}" == "${buffer}"* ]]; then
          filtered_items+=("${cmd}")
        fi
      done
      if (( ${#filtered_items[@]} > 0 )); then
        menu_active=1
        # Clamp menu_sel
        if (( menu_sel >= ${#filtered_items[@]} )); then
          menu_sel=0
        elif (( menu_sel < 0 )); then
          menu_sel=$(( ${#filtered_items[@]} - 1 ))
        fi
      fi
    fi

    # 2. Redraw prompt and menu
    # Clear current line and below
    printf "\r\033[J"
    # Print prompt and buffer
    printf "%s%s" "${prompt}" "${buffer}"

    local menu_lines=0
    if (( menu_active )); then
      printf "\n  %sAutocomplete Command%s" "${C_BOLD}" "${C_RST}"
      menu_lines=1
      local i
      for (( i=0; i<${#filtered_items[@]}; i++ )); do
        if (( i == menu_sel )); then
          printf "\n  %s▶ %s%s" "${C_GREEN}${C_BOLD}" "${filtered_items[$i]}" "${C_RST}"
        else
          printf "\n    %s" "${filtered_items[$i]}"
        fi
        menu_lines=$((menu_lines + 1))
      done
    fi

    # Move cursor back to prompt line if menu was drawn
    if (( menu_lines > 0 )); then
      printf "\033[%dA" "${menu_lines}"
    fi

    # Position cursor at the edit column
    printf "\r%s%s" "${prompt}" "${buffer:0:cursor}"

    # 3. Read key
    local char=""
    IFS= read -r -s -n1 char 2>/dev/null || char=""

    if [[ "${char}" == $'\x1b' ]]; then
      local next1="" next2=""
      stty -echo -icanon min 0 time 1 2>/dev/null || true
      IFS= read -r -s -n1 next1 2>/dev/null || next1=""
      if [[ -z "${next1}" ]]; then
        # ESC key pressed
        menu_closed=1
      elif [[ "${next1}" == "[" || "${next1}" == "O" ]]; then
        IFS= read -r -s -n1 next2 2>/dev/null || next2=""
        case "${next2}" in
          A) # UP ARROW
            if (( menu_active )); then
              menu_sel=$(( menu_sel - 1 ))
            else
              if (( hist_pos > 0 )); then
                hist_pos=$((hist_pos - 1))
                buffer="${REPL_HISTORY[$hist_pos]}"
                cursor=${#buffer}
              fi
            fi
            ;;
          B) # DOWN ARROW
            if (( menu_active )); then
              menu_sel=$(( menu_sel + 1 ))
            else
              if (( hist_pos < ${#REPL_HISTORY[@]} )); then
                hist_pos=$((hist_pos + 1))
                if (( hist_pos == ${#REPL_HISTORY[@]} )); then
                  buffer=""
                else
                  buffer="${REPL_HISTORY[$hist_pos]}"
                fi
                cursor=${#buffer}
              fi
            fi
            ;;
          C) # RIGHT ARROW
            if (( cursor < ${#buffer} )); then
              cursor=$((cursor + 1))
            fi
            ;;
          D) # LEFT ARROW
            if (( cursor > 0 )); then
              cursor=$((cursor - 1))
            fi
            ;;
          3) # Delete key
            local next3=""
            IFS= read -r -s -n1 next3 2>/dev/null || next3=""
            if [[ "${next3}" == "~" ]]; then
              if (( cursor < ${#buffer} )); then
                buffer="${buffer:0:cursor}${buffer:cursor+1}"
              fi
            fi
            ;;
        esac
      fi
      stty -echo -icanon min 1 time 0 2>/dev/null || true
    elif [[ -z "${char}" ]]; then
      # Enter key pressed
      if (( menu_active )); then
        buffer="${filtered_items[$menu_sel]} "
        cursor=${#buffer}
        menu_closed=0
      else
        if (( menu_active )); then
          printf "\r\033[J"
        fi
        printf "\n"
        stty "${old_stty}" 2>/dev/null || true

        if [[ -n "${buffer}" ]]; then
          local last_idx=$(( ${#REPL_HISTORY[@]} - 1 ))
          if (( last_idx < 0 )) || [[ "${REPL_HISTORY[$last_idx]}" != "${buffer}" ]]; then
            REPL_HISTORY+=("${buffer}")
            save_history
          fi
        fi

        REPL_READ_RESULT="${buffer}"
        return 0
      fi
    elif [[ "${char}" == $'\x7f' || "${char}" == $'\x08' ]]; then
      if (( cursor > 0 )); then
        buffer="${buffer:0:cursor-1}${buffer:cursor}"
        cursor=$((cursor - 1))
      fi
      menu_closed=0
    else
      local ascii_val
      ascii_val=$(printf '%d' "'${char}" 2>/dev/null || echo 0)
      if (( ascii_val >= 32 && ascii_val <= 126 )); then
        buffer="${buffer:0:cursor}${char}${buffer:cursor}"
        cursor=$((cursor + 1))
        menu_closed=0
      fi
    fi
  done
}

run_tui_mode() {
  cache_load
  load_history
  theme_load       # restore persistent theme (survives session cache deletion)
  first_run_theme
  print_welcome

  local line cmd args
  while true; do
    repl_read
    line="${REPL_READ_RESULT}"

    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    [[ -z "${line}" ]] && continue

    if [[ "${line}" == "!"* ]]; then
      local external_cmd="${line#!}"
      external_cmd="${external_cmd#"${external_cmd%%[![:space:]]*}"}"
      external_cmd="${external_cmd%"${external_cmd##*[![:space:]]}"}"
      if [[ -z "${external_cmd}" ]]; then
        cwarn "Usage: ! <command>"
      else
        clog "Running external command: ${external_cmd}"
        echo ""
        eval "${external_cmd}"
        echo ""
      fi
      continue
    fi

    read -r cmd args <<< "${line}"

    case "${cmd}" in
      /repo|/R)
        local -a cmd_args=()
        read -r -a cmd_args <<< "${args}"
        handle_repo "${cmd_args[@]:-}"
        ;;
      /workspace|/W)
        handle_workspace ${args}
        ;;
      /auth|/A)
        handle_auth ${args}
        ;;
      /bootstrap|/B)
        handle_bootstrap
        ;;
      /status|/S)
        handle_status
        ;;
      /theme|/T)
        handle_theme ${args}
        ;;
      /dist-run|/D)
        handle_dist_run
        ;;
      /help|/H|help)
        print_welcome
        ;;
      /exit|/E)
        cok "Exiting WSA4SDD App. Clearing cache..."
        cache_delete
        _cleanup
        exit 0
        ;;
      *)
        cerr "Unknown command: ${cmd}. Type /help for available commands."
        ;;
    esac
  done
}

run_cli_mode() {
  clog "Running WSA4SDD App in non-interactive CLI mode..."

  if [[ ${#INPUT_REPOS[@]} -eq 0 ]]; then
    die "Missing repositories. Specify repository URLs using -I or --input."
  fi

  # Req 2: drop invalid repo URLs; abort if none remain valid.
  local -a _valid=() _u
  for _u in "${INPUT_REPOS[@]}"; do
    [[ -n "${_u}" ]] || continue
    if is_valid_repo_url "${_u}"; then _valid+=("${_u}"); else cwarn "Invalid repo URL skipped: ${_u}"; fi
  done
  [[ ${#_valid[@]} -gt 0 ]] || die "No valid repositories (Repos [NOT SET])."
  INPUT_REPOS=("${_valid[@]}")

  if [[ -z "${WORKSPACE_DIR}" ]]; then
    WORKSPACE_DIR="${PWD}"
  fi

  mkdir -p "${WORKSPACE_DIR}"
  WORKSPACE_DIR="$(cd "${WORKSPACE_DIR}" && pwd)"

  cok "Workspace resolved: ${WORKSPACE_DIR}"
  cok "Repositories: ${INPUT_REPOS[*]}"

  # In CLI mode, default to 'none' if no auth method is specified
  if [[ -z "${AUTH_METHOD}" ]]; then
    AUTH_METHOD="none"
  fi

  detect_os
  ensure_cmd git

  if [[ "${AUTH_METHOD}" == "gh" ]]; then
    ensure_cmd gh
    gh auth status >/dev/null 2>&1 || die "gh CLI not logged in"
  fi

  ensure_docker
  ensure_make

  clog "Syncing repositories..."
  sync_all_repos || die "Repository sync failed."

  resolve_ops_dir
  ensure_runnable_ops || die "Cannot prepare a deployment for '${OPS_NAME}' (no compose/Makefile and no detectable run method)."
  (( AUTO_GENERATED )) && cok "docker-compose.yml & Makefile were auto-generated."

  if [[ "${NO_RUN}" -eq 1 ]]; then
    warn "--no-run is set. Skipping deployment execution."
    exit 0
  fi

  load_default
  local raw=()
  while IFS= read -r _t; do
    [[ -n "${_t}" ]] && raw+=("${_t}")
  done < <(list_make_up_targets)

  if [[ ${#raw[@]} -eq 0 ]]; then
    warn "No make targets found. Skipping deployment execution."
    exit 0
  fi

  local target=""
  if [[ -n "${DEFAULT_TARGET}" ]]; then
    target="${DEFAULT_TARGET}"
    cok "Using default target: ${target}"
  else
    target="${raw[0]}"
    cok "No default target set. Using first available target: ${target}"
  fi

  clog "Executing: make -C \"${OPS_DIR}\" ${target}"
  local exit_code=0
  if [[ "${OS_KIND}" == "linux" && "${DAEMON_NEEDS_SG:-0}" -eq 1 ]] && command -v sg >/dev/null 2>&1; then
    sg docker -c "cd \"${OPS_DIR}\" && make ${target}" || exit_code=$?
  else
    ( cd "${OPS_DIR}" && make "${target}" ) || exit_code=$?
  fi

  if (( exit_code != 0 )); then
    cerr "Deployment failed (make exited with ${exit_code})"
    dump_unhealthy_logs
    exit "${exit_code}"
  fi

  cok "Deployment completed successfully!"
  exit 0
}

usage() {
  cat <<EOF
WSA4SDD App (v1.1.0) — TUI & CLI Service Deployment & Distribution Tool

Usage:
  ./wsa4sdd.sh                          # Interactive TUI mode (normal REPL)
  ./wsa4sdd.sh -I "url1 url2"           # TUI mode with pre-filled repositories
  ./wsa4sdd.sh -I "url1" --cli          # Non-interactive CLI mode (direct deploy)
  ./wsa4sdd.sh -I url -w ~/work -o ops  # TUI mode with pre-filled settings
  ./wsa4sdd.sh -I url --no-run          # Non-interactive CLI dry-run (no deploy)
  ./wsa4sdd.sh -I "url1 url2" -a <PAT> --default-env   # Default env: ws=cwd, ops=first repo, auth=pat

Options:
  -I, --input <repos>    Space-separated git repository URLs (required)
  -w, --workspace <dir>  Workspace directory to clone repositories
  -o, --ops <name>       Ops repository name containing Makefile/docker-compose
  -a, --auth <value>     Auth: a PAT token (method=pat), or a keyword gh|pat|none
  --default-env          Default non-interactive env: requires -I and -a;
                         sets workspace=current dir, ops=first repo, auth method=pat
  -c, --cli              Force non-interactive CLI mode execution
  --no-run               Skip targets deployment execution (forces CLI mode)
  -h, --help             Show this help guide
EOF
}

# ══ Entry Point ═══════════════════════════════════════════════════════════════
main() {
  local force_cli=0 default_env=0 _AUTH_ARG="" _auth_seen=0

  # 1. Parse CLI arguments
  while (( $# )); do
    case "$1" in
      -I|--input)
        [[ $# -ge 2 ]] || die "--input needs a value"
        shift
        while (( $# )) && [[ "$1" != -* ]]; do
          read -r -a _tmp <<< "$1"
          INPUT_REPOS+=("${_tmp[@]}")
          shift
        done
        ;;
      -w|--workspace) WORKSPACE_DIR="$2"; shift 2 ;;
      -o|--ops)       OPS_NAME="$2"; shift 2 ;;
      -a|--auth)
        [[ $# -ge 2 ]] || die "-a/--auth needs a value (a PAT token, or gh|pat|none)"
        _AUTH_ARG="$2"; _auth_seen=1; shift 2 ;;
      --default-env)  default_env=1; shift ;;
      --no-run)       NO_RUN=1; shift ;;
      -c|--cli)       force_cli=1; shift ;;
      -h|--help)      usage; exit 0 ;;
      *)              printf 'Unknown arg: %s\n' "$1" >&2; usage; exit 1 ;;
    esac
  done

  # 1b. Apply -a/--auth: a bare keyword is the method; anything else is a PAT token.
  if (( _auth_seen )); then
    case "${_AUTH_ARG}" in
      gh)   AUTH_METHOD="gh" ;;
      none) AUTH_METHOD="none" ;;
      pat)  AUTH_METHOD="pat" ;;                                   # method only; token still required
      "")   die "-a/--auth value is empty" ;;
      *)    AUTH_METHOD="pat"; GITHUB_PAT="${_AUTH_ARG}"; set_pat_credentials ;;  # token carried directly
    esac
  fi

  # 1c. --default-env: configure a non-interactive default environment.
  if (( default_env )); then
    force_cli=1
    # (1) repositories are mandatory
    [[ ${#INPUT_REPOS[@]} -gt 0 ]] \
      || die "--default-env: repositories are required. Provide -I/--input <urls>."
    # (2) workspace = current path, ops repo = first repository
    WORKSPACE_DIR="${PWD}"
    OPS_NAME="$(repo_name_from_url "${INPUT_REPOS[0]}")"
    # (3) auth (-a) is mandatory; default method pat; the value must be present
    (( _auth_seen )) \
      || die "--default-env: -a/--auth is required (default method 'pat'; pass a PAT token)."
    if [[ "${AUTH_METHOD}" == "pat" && -z "${GITHUB_PAT}" ]]; then
      die "--default-env: a PAT value is required. Pass it as -a <token>."
    fi
    cok "Default env: ws=${WORKSPACE_DIR}, ops=${OPS_NAME}, auth=${AUTH_METHOD}"
  fi

  # 2. Determine TUI vs CLI execution mode
  local run_tui=1
  if (( NO_RUN )) || (( force_cli )); then
    run_tui=0
  fi

  # 3. If TUI mode is desired but stdin is piped (e.g. curl | bash), try to redirect stdin to TTY
  if (( run_tui )) && [[ ! -t 0 ]]; then
    if [[ -c /dev/tty ]]; then
      exec < /dev/tty
    else
      run_tui=0
    fi
  fi

  # 4. Run the selected mode
  if (( run_tui )) && [[ -t 0 ]]; then
    run_tui_mode
  else
    run_cli_mode
  fi
}

# Run only when executed directly; allow sourcing for tests.
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  main "$@"
fi

