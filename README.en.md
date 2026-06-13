# WSA4SDD (Wise Shell App for Service Deployment & Distribution)

WSA4SDD (Wise Shell App) is a **Claude Code-style interactive deployment and distribution shell** designed to manage multi-repository service syncs and Docker Compose configurations directly in your terminal.

Improving upon rigid, wizard-like deployment scripts, WSA4SDD introduces a flexible TUI REPL that lets users configure variables in any order, verify environment setups, run pre-flight checks, and trigger Docker Compose distributions safely using intuitive commands.

It also supports standard CLI arguments parsing and handles non-interactive pipelines (like `curl -fsSL ... | bash`) for completely automated remote deployments.

## Demo

![WSA4SDD usage demo](wsa4sdd.gif)

> A single repository (`wsa4sdd-samples`) is switched across three branches in turn — `python-cli` → `node-cli` → `pb-nf` — and for each branch it runs the `repo → workspace → auth → bootstrap → status → dist-run` flow, then demonstrates `docker ps -a` inspection and `make down`.

---

## 1. Core Features

### A. Claude Code-Style TUI & REPL
- Displays an intuitive welcome description banner and a horizontal divider line (`───`) outlining system state and available commands.
- Features a custom-built advanced line editor and REPL prompt (`>    `):
  - **Input History**: Navigate and recall previously executed command histories (synchronized with `/tmp/.wsa4sdd_history`) using UP/DOWN arrow keys.
  - **In-Place Editing**: Move the cursor interactively using LEFT/RIGHT arrow keys, and modify inputs using Backspace and Delete keys.
  - **Autocomplete Popover**: Pressing the `/` key on an empty prompt pops up a dropdown selection menu of all available commands. Navigate using UP/DOWN keys and press `Enter` to auto-fill the selected command into the prompt buffer.
- Detects non-interactive pipeline environments (`! -t 0`) or active CLI arguments, automatically bypassing the TUI to execute in direct CLI mode.

### B. Command-Driven Steps Configuration
Each stage of the deployment pipeline is managed as a standalone shell command:
- `/repo [url[#branch] ...]`, `/R …`: Register **one or more** repos. Pass **several at once, space- or comma-separated**, and use `<url>#<branch>` to **pin a branch** (cloned/pulled on that branch). Empty opens the Repository Manager (add, delete, reorder). URLs are validated (`https://`, `git@host:owner/repo`, `ssh://`, local path; optional `#branch`); if **none are registered or all are invalid, it is `[NOT SET]`**.
- `/workspace [path]`, `/W [path]`: Workspace folder. **`[NOT SET]` until run**; when run with no arg, pick one of **Current / Parent / Custom path** from the TUI menu.
- `/auth [status|switch|login|pat]`, `/A …`: GitHub auth. **`[NOT SET]` until run**; the menu offers **4 actions** — **gh login status** (show current user) / **gh auth switch** / **gh auth login** / **Register PAT**.
- `/bootstrap`, `/B`: Runs **only when repo, workspace, and auth are all set**. ① system environment check module (detect OS + report git/gh/docker/make, no install) ② pre-install module (install missing deps) → sync repos → generate Makefile. If any prerequisite is `[NOT SET]`, it stays `[PENDING]` and refuses, listing the missing items. **If any step (repo sync, ops resolution, Makefile generation, …) fails, it aborts without reaching `[DONE]` and stays `[PENDING]`.** Deployment assets in the ops repo are prepared as follows — (1) if a Makefile exists, use it; (2) if only docker-compose exists, generate a Makefile from it; (3) if neither exists, detect direct build/run apps (Python `hello.py`/…, Node `package.json`/entry) — **finds every app, none omitted** (e.g. `apps/python-cli`, `node-cli`, `python-backend`, `node-frontend`), generates **a Dockerfile + one compose service per app** and a Makefile with overall `up`/`down` plus per-app `up-<name>` targets (notifies you, then `/dist-run` is available); if none found, **report that `/dist-run` is unavailable and exit**. (Python apps use the **manifest dir** — `pyproject.toml`/`requirements.txt`/`setup.py` — as the build context so dependencies install even when the entry is nested like `app/main.py`; FastAPI/uvicorn apps get a `uvicorn <module>:<app>` CMD plus a published port.) **With multiple repos registered, every repo is scanned** (not just the ops repo); the generated compose/Makefile live in the ops repo and reference sibling-repo apps via `../<repo>/...` build contexts (service names are repo-prefixed to avoid clashes). It also classifies each service's **role (frontend/backend/database/cli)** and writes a **wired** compose — frontends get `BACKEND_URL`+`depends_on`+port, backends get a port (+`DATABASE_URL`+`depends_on` when a database exists), CLIs get no ports. Host ports only increment on collision (a single backend stays 8000).
- `/status`, `/S`: Shows current settings, `[NOT SET]` items, bootstrap state (`[PENDING]`/`[DONE]`), and the active theme.
- `/theme`, `/T [name]`: Switch the Claude-CLI-style **color theme** (6 presets). With no arg, opens a selector + color-swatch preview. On **first run** it asks once and persists the choice to the cache.
- `/dist-run`, `/D`: **Does not auto-bootstrap.** If bootstrap is `[PENDING]`, it guides you to run `/bootstrap`, prints the `[NOT SET]` items besides bootstrap, and **exits without executing anything**. Only when `[DONE]` does it launch the Make target selector.
- `/help`, `/H`: Displays the help instructions and command manual.
- `/exit`, `/E`: Exits the session and completely purges saved caches.
- `! <command>`: Executes a local shell command (e.g. `! pwd`, `! ls -la`) immediately within the interactive REPL and displays the output.

### C. Interactive Repository Manager & Reordering
- Typing `/repo` or `/R` without parameters opens the interactive **Repository Manager** sub-menu:
  - **Add Repository**: Registers new URLs (limit of 8).
  - **Delete Repository**: Opens a quick selector to remove registered items.
  - **Change Order (Reorder)**: An interactive selector that uses arrow keys (`UP`/`DOWN` or `k`/`j`) to swap positions in-place, allowing user-customized distribution sequences. Press `Enter` to lock the selected item, and select `Done` (or press `ESC`) to save and exit.

### D. Smart Session Cache
- Configured parameters are serialized to `/tmp/.wsa4sdd-${UID}.cache` on every update.
- If the terminal disconnects or terminates unexpectedly, the session state is restored upon reboot.
- If the deployment finishes successfully (`/dist-run` done) or if the user exits cleanly (via `/exit` or pressing `Ctrl+C` twice within 2 seconds), the cache file is deleted.

---

## 2. TUI Layout & Commands

When starting `wsa4sdd.sh` interactively, the terminal displays the welcome header:

```
  WSA4SDD App (v1.1.0) — Service Deployment and Distribution Shell
  Lives in your terminal, manages git repos, and deploys docker-compose.
  ─────────────────────────────────────────────────────────────────────────────
  Commands:
    /repo, /R [url[#branch] ...]         Register 1+ repos (space/comma sep, optional #branch)
    /workspace, /W [path]                Current / Parent / Custom ([NOT SET] until run)
    /auth, /A [status|switch|login|pat]  gh status/switch/login or PAT ([NOT SET] until run)
    /bootstrap, /B                       System check + pre-install + sync (needs all set)
    /status, /S                          Show config + [PENDING]/[DONE] + theme
    /theme, /T [name]                    Switch color theme (6 presets; menu if empty)
    /dist-run, /D                        Run deploy ([PENDING] -> guide + abort, no auto-bootstrap)
    /help, /H                            Show this help message
    /exit, /E                            Exit wsa4sdd shell and clear cache
    ! <command>                          Execute a shell command and display the output
  ─────────────────────────────────────────────────────────────────────────────

>    
```

### Detailed Commands Guide

#### 1. Repository Configuration (`/repo`, `/R`)
- **CLI direct**: `/repo <url1> <url2#branch> …` — one or more, space/comma separated. Invalid URLs rejected with a warning.
- **TUI interactive**: `/repo` with no args opens the manager. `Add Repository` accepts **multiple URLs on one line** (space/comma); `Delete`, `Change Order`.
- **Branch**: `<url>#<branch>` (e.g. `https://github.com/o/r.git#dev`, `git@host:o/r.git#release/1.0`) → clone (`-b`) / pull (`checkout` + `pull origin <branch>`) on that branch. Omit for default/current branch.
- **Valid formats**: `https://…/…`, `git@host:owner/repo`, `ssh://…`, local path (optional `#branch`).
- **State**: with zero valid repos, `/status` shows `[NOT SET]`.

#### 2. Target Workspace (`/workspace`, `/W`)
- **`[NOT SET]` until run** — running it is what defines the value.
- **CLI direct**: `/workspace /path/to/dir`
- **TUI interactive**: pick one of **① Current dir ② Parent dir ③ Custom path…**.

#### 3. Authentication Protocol (`/auth`, `/A`)
- **`[NOT SET]` until run** — running it offers **4 actions**:
  1. **gh login status** — `gh auth status`; shows and records the current GitHub user.
  2. **gh auth switch** — switch the active account.
  3. **gh auth login** — new GitHub login.
  4. **Register PAT** — Username (optional) + Personal Access Token, stored in a 0600 temp helper file and auto-removed on exit.
- **CLI direct**: `/auth status|switch|login|pat` (`gh`/`none` also accepted for scripting).
- `/status` shows the auth method plus the detected current GitHub username.

#### 4. Run Deployment (`/dist-run`, `/D`)
- **Will not run unless bootstrap is `[DONE]`.** If `[PENDING]`, it guides you to run `/bootstrap`, prints the `[NOT SET]` items (Repos/Workspace/Auth) besides bootstrap, and **exits without executing anything** (no auto-bootstrap).
- When `[DONE]`, it collects Makefile targets (such as `up-*`) into a dynamic arrow-key menu.
- Runs optional pre-run commands, triggers `make <target>`; on success the cache is wiped and the script exits.

> **State model**: settings (repo·workspace·auth) are `[NOT SET]` until filled. Bootstrap runs only when all
> three are set and becomes `[DONE]`; otherwise `[PENDING]`. Changing any setting invalidates `[DONE]` back to `[PENDING]`.

#### 5. Color Theme (`/theme`, `/T`)

A Claude-CLI-style color theme system. On **first run** the tool asks for a theme once and persists it to the cache, so subsequent runs don't prompt again.

| Theme | Description |
|---|---|
| `dark` | Default for dark backgrounds |
| `light` | For light backgrounds (dark text) |
| `dark-daltonized` | Colorblind-friendly (avoids green/red confusion — success=blue, error=orange), dark bg |
| `light-daltonized` | Colorblind-friendly, light bg |
| `dark-ansi` | 16-color ANSI only (no 256/truecolor), dark bg |
| `light-ansi` | 16-color ANSI only, light bg |

- **CLI direct**: `/theme dark-daltonized` switches immediately.
- **TUI interactive**: `/theme` opens a menu (current theme preselected) and prints a color swatch (✓/!/✗/▶) preview after selection.
- The choice is stored in a **dedicated persistent cache** `/tmp/.wsa4sdd-theme-${UID}.cache` and shown in `/status`.
- Unless you re-set it via `/theme`,`/T`, the previous cached value is reused. **The theme cache is NOT deleted when the session cache is cleared** (`/exit`, double Ctrl+C, successful deploy).

---

## 3. Remote Execution & Local Installation Guide

### A. Remote Direct Execution (curl | bash)
You can execute the script directly from the remote repository without downloading it, which is ideal for one-off tasks or CI/CD pipelines.
Arguments can be appended to configure the app before running, allowing you to choose between launching the interactive TUI or non-interactive CLI.

```bash
# 1) Remote TUI mode (pre-populate inputs, but launch interactive REPL)
curl -fsSL https://raw.githubusercontent.com/WisemanLim/pub-wsa-for-sdd/main/wsa4sdd.sh \
  | bash -s -- -I "https://github.com/ClaroPessoas/claro-svc" -w "~/workspace"

# 2) Remote non-interactive CLI mode (trigger automated deployment immediately)
curl -fsSL https://raw.githubusercontent.com/WisemanLim/pub-wsa-for-sdd/main/wsa4sdd.sh \
  | bash -s -- -I "https://github.com/ClaroPessoas/claro-svc" --cli

# 3) Remote non-interactive CLI dry-run (perform setup/sync but skip deployment)
curl -fsSL https://raw.githubusercontent.com/WisemanLim/pub-wsa-for-sdd/main/wsa4sdd.sh \
  | bash -s -- -I "https://github.com/ClaroPessoas/claro-svc" --no-run

# 4) One-shot default environment (--default-env): workspace=cwd, ops=first repo, auth=pat
curl -fsSL https://raw.githubusercontent.com/WisemanLim/pub-wsa-for-sdd/main/wsa4sdd.sh \
  | bash -s -- -I "https://github.com/ClaroPessoas/claro-svc" -a "<PAT_TOKEN>" --default-env
```

#### `--default-env` flag

A non-interactive mode that composes a default environment in one line for remote/automation use.

- **`-a, --auth <value>`**: CLI auth. A `gh`/`pat`/`none` keyword sets the method; any other string is treated as a **PAT token** (method=pat). Both `-a` and `--auth` spellings work.
- **`--default-env`**:
  1. **`-I/--input` (repo) is required** — error + exit if missing.
  2. **workspace = current dir (PWD)**, **ops repo = first repo's name** (auto-set).
  3. **`-a/--auth` is required**, default method `pat`, **a token value must be supplied to run** — error + exit if missing (or if only bare `pat` is given without a token).
- ⚠️ `-a <token>` exposes the token in process args (ps/history). Intended for automation/demo; mask CI secrets in production.

---

### B. Script Download & Local Installation
To download the script to your local system for persistent usage:

1. **Download and make executable**:
   ```bash
   curl -fsSL -o wsa4sdd.sh https://raw.githubusercontent.com/WisemanLim/pub-wsa-for-sdd/main/wsa4sdd.sh
   chmod +x wsa4sdd.sh
   ```

2. **Install to System PATH for global access (Optional)**:
   ```bash
   # Move the script to a folder in your system PATH (e.g. /usr/local/bin)
   sudo mv wsa4sdd.sh /usr/local/bin/wsa4sdd
   ```

3. **Local Execution & Parameter Passing Examples**:
   ```bash
   # Standalone execution (starts TUI mode by default)
   wsa4sdd
   
   # Pre-populate variables and launch interactive TUI mode
   wsa4sdd -I "https://github.com/ClaroPessoas/claro-svc" -w "~/workspace"
   
   # Force non-interactive CLI mode for immediate deployment
   wsa4sdd -I "https://github.com/ClaroPessoas/claro-svc" --cli
   
   # Force non-interactive CLI dry-run (skip deployment target execution)
   wsa4sdd -I "https://github.com/ClaroPessoas/claro-svc" --no-run
   ```


### CLI Options

| Option | Description | Example |
| :--- | :--- | :--- |
| `-I, --input` | Space-separated list of repository URLs. | `-I "url1 url2"` |
| `-w, --workspace` | Destination folder to clone repos. | `-w ~/dev/workspace` |
| `-o, --ops` | The name of the primary operations repository hosting the Makefile/docker-compose files. | `-o my-ops-repo` |
| `--no-run` | Syncs repositories and runs build bootstrapping (like Makefile generation) but skips target deployment. | `--no-run` |
| `-h, --help` | Shows the CLI arguments usage guide. | `-h` |

---

## 4. Compatibility & Requirements

- **100% Native macOS Support**: The default macOS shell is `/bin/bash` (v3.2.x). To ensure seamless execution without requiring bash upgrades or external packages, `wsa4sdd.sh` was built from the ground up to avoid Bash 4.x+ specific patterns, such as `local -n` (namerefs) and associative arrays (`declare -A`).
- **Automatic Environment Verification**: During interactive launch or `/bootstrap`, the script automatically checks if core dependencies (`git`, `docker`, `docker compose`, `make`) are installed on the host system, notifying the user about any missing requirements.
