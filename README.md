# WSA4SDD (Wise Shell App for Service Deployment & Distribution)

WSA4SDD(Wise Shell App)는 터미널 안에서 명령어로 분산 다중 저장소 서비스를 수집하고 Docker Compose 프로젝트의 수명주기를 조율하는 **Claude Code 스타일 대화형 배포 및 배포 쉘**입니다.

기존의 단순 마법사형 배포 스크립트들의 경직된 환경을 개선하여, 사용자가 원하는 순서대로 명령어를 통해 변수를 설정하고 환경을 검증하며, 최종적으로 Docker Compose 배포 명령을 안전하게 내릴 수 있는 유연한 TUI REPL을 제공합니다.

또한, CLI 인수 파싱과 논인터랙티브 파이프라인 대응 기능을 포함하여 `curl -fsSL ... | bash`를 통한 원격 완전 자동 배포도 동일하게 지원합니다.

## 데모 (Demo)

![WSA4SDD 사용 데모](wsa4sdd.gif)

> 하나의 저장소(`wsa4sdd-samples`)를 `python-cli` → `node-cli` → `pb-nf` 세 브랜치로 차례로 전환하며, 각 브랜치마다 `repo → workspace → auth → bootstrap → status → dist-run` 흐름으로 배포한 뒤 `docker ps -a` 확인과 `make down`까지 시연합니다.

---

## 1. 주요 특징 (Core Features)

### A. Claude Code 스타일 TUI & REPL

- 실행 시 시스템 상태와 명령어 도움말을 직관적으로 설명하는 웰컴 헤더와 구분선(`───`)을 제공합니다.
- 자체 구현된 고급 라인 에디터 REPL 프롬프트 영역(`>    `)을 제공합니다.
  - **입력 히스토리**: 위/아래 화살표 키를 통해 이전 실행한 명령어 기록(세션 파일 `/tmp/.wsa4sdd_history` 연동)을 탐색하고 다시 불러옵니다.
  - **입력 편집**: 좌/우 화살표 키로 실시간 커서 이동이 가능하며, Backspace 및 Delete 키를 통한 자연스러운 글자 삽입 및 삭제를 지원합니다.
  - **자동완성 팝오버**: 빈 입력창 상태에서 `/` 키를 입력하면 선택 가능한 명령어 리스트가 화면 하단에 드롭다운 형태로 팝업되어 위/아래 키와 `Enter`로 손쉽게 자동 완성할 수 있습니다.
- TTY가 없는 자동화 파이프라인(`! -t 0`) 또는 CLI 인수 설정 시 대화형 TUI를 건너뛰고 direct CLI 모드로 실행됩니다.

### B. 명령어 기반 개별 단계 관리

배포의 흐름을 대화형 쉘 안에서 각각 제어할 수 있습니다.

- `/repo [url[#branch] ...]`, `/R …`: 배포할 Git 저장소를 **1개 또는 여러 개** 등록합니다. **공백 또는 콤마로 여러 개를 한 번에** 입력할 수 있고, `<url>#<branch>`로 **브랜치를 지정**하면 그 브랜치로 clone/pull 합니다. 인자를 생략하면 대화형 Repository Manager(추가, 삭제, 순서 정렬)를 기동합니다. URL 유효성을 검증하며(`https://`, `git@host:owner/repo`, `ssh://`, 로컬 경로; 선택적 `#branch`), **0개이거나 모두 무효이면 `[NOT SET]`**입니다.
- `/workspace [path]`, `/W [path]`: 워크스페이스 경로. **실행 전까지 `[NOT SET]`**이며, 인자를 생략하면 TUI 메뉴에서 **현재(Current) / 상위(Parent) / 사용자 지정(Custom path)** 3가지 중 선택/지정한 값으로 정의됩니다.
- `/auth [status|switch|login|pat]`, `/A …`: GitHub 인증. **실행 전까지 `[NOT SET]`**이며, 인자를 생략하면 TUI 메뉴에서 **4가지** 중 선택합니다 — **gh login status**(현재 로그인 사용자 확인) / **gh auth switch**(계정 전환) / **gh auth login**(신규 로그인) / **PAT 등록**.
- `/bootstrap`, `/B`: **repo·workspace·auth가 모두 `[NOT SET]`이 아닐 때만** 진행됩니다. ① 시스템 환경 확인 모듈(OS 감지 + git/gh/docker/make 존재 보고, 설치 안 함) ② 사전 설치 모듈(누락 의존성 설치) → 레포 동기화 → Makefile 생성. 미충족 시 `[PENDING]`으로 실행을 거부하고 `[NOT SET]` 항목을 안내합니다. **저장소 동기화 등 어느 단계라도 실패하면 `[DONE]`이 되지 않고 중단되어 `[PENDING]`을 유지합니다.** ops repo 배포자산은 다음 규칙으로 준비합니다 — ① Makefile 있으면 그대로 사용 ② docker-compose만 있으면 compose 기반 Makefile 생성 ③ 둘 다 없으면 직접 실행법(python `hello.py` 등, node `package.json` 등) 탐지 — **하위의 모든 앱을 빠짐없이** 찾아(예: `apps/python-cli`·`node-cli`·`python-backend`·`node-frontend`) **앱마다 Dockerfile + compose 서비스 1개씩** 생성하고, 전체 `up`/`down` + 앱별 `up-<name>` 타겟을 가진 Makefile을 자동생성(자동생성 알림 후 `/dist-run` 가능). 없으면 **`/dist-run` 불가 안내 후 종료**. (Python 앱은 **매니페스트 디렉터리**(`pyproject.toml`/`requirements.txt`/`setup.py`)를 빌드컨텍스트로 삼아 의존성을 설치하고, FastAPI/uvicorn 앱이면 `uvicorn <module>:<app>` + 포트 publish로 생성.) **repo를 여러 개 지정하면 ops repo뿐 아니라 등록된 모든 repo를 스캔**하여 앱을 찾고, 생성물은 ops repo에 두며 타 repo 앱은 `../<repo>/...` 빌드컨텍스트로 참조합니다(서비스명 repo 접두로 충돌 방지). 또한 각 서비스의 **역할(frontend/backend/database/cli)** 을 인식해 compose를 **연동된 구성**으로 작성합니다 — frontend엔 `BACKEND_URL`+`depends_on`+포트, backend엔 포트(+db 있으면 `DATABASE_URL`+`depends_on`), cli는 포트 없음. host 포트는 충돌 시에만 증가(단일 backend=8000 유지).
- `/status`, `/S`: 현재 설정값, `[NOT SET]` 현황, bootstrap 상태(`[PENDING]`/`[DONE]`), 적용 테마를 표시합니다.
- `/theme`, `/T [name]`: Claude CLI 스타일 **색상 테마** 전환(6종). 인자 생략 시 선택 메뉴 + 색 스와치 미리보기. **최초 실행 시** 한 번 선택받아 캐시에 저장합니다(재실행 시 미질문).
- `/dist-run`, `/D`: **bootstrap이 `[PENDING]`이면 자동 부트스트랩하지 않고** `/bootstrap` 실행을 안내하며, bootstrap 외 `[NOT SET]` 항목을 함께 출력하고 **아무것도 실행하지 않은 채 종료**합니다. `[DONE]`일 때만 Makefile 타겟 선택 메뉴를 구동합니다.
- `/help`, `/H`: 사용 설명 및 도움말 호출.
- `/exit`, `/E`: 프로그램 세션 종료 및 세션 캐시 전체 삭제.
- `! <command>`: 대화형 REPL 모드에서 로컬 쉘 명령어(예: `! pwd`, `! ls -la`)를 즉시 실행하고 결과를 출력합니다.

### C. 대화형 저장소 순서 변경 및 관리 (Interactive Reordering)

- `/repo` 명령을 인수 없이 실행하면 대화형 **Repository Manager**가 구동됩니다.
- 레포지토리를 **추가(Add)**하거나, 선택하여 **삭제(Delete)**할 수 있습니다.
- 특히 **Reorder** 기능을 선택하면 터미널 상에서 방향키(`UP`/`DOWN` 또는 `k`/`j`)를 이용해 선택한 저장소의 동기화 및 조율 순서를 물리적으로 바꿀 수 있으며, `Enter` 키로 그 자리에서 락(Lock)을 걸어 순서를 변경합니다.

### D. 지능적 세션 캐시 (Session Cache)

- 명령어 입력으로 설정된 변수들은 `/tmp/.wsa4sdd-${UID}.cache` 파일로 매번 직렬화되어 보관됩니다.
- 도중에 연결이 끊어지거나 임의 종료되더라도, 재기동 시 세션 상태가 고스란히 복원됩니다.
- 배포가 완전히 끝났거나(`/dist-run` 정상 종료), 사용자가 `/exit` 또는 2회 연속 `Ctrl+C`를 눌러 명시적으로 종료할 경우에는 캐시를 완벽히 소거하여 임시 파일을 남기지 않습니다.

---

## 2. TUI 구성 및 레이아웃 (Layout & Commands)

실행 시 터미널 화면에 아래와 같이 구성된 웰컴 안내가 출력됩니다.

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

### 상세 명령어 가이드

#### 1. 저장소 구성 (`/repo`, `/R`)

- **CLI direct**: `/repo <url1> <url2#branch> …` — 1개 이상 등록. 공백/콤마로 여러 개 동시 입력. 무효 URL은 거부·경고.
- **TUI interactive**: `/repo`만 입력 시 관리 메뉴 동작.
  - `Add Repository`에서 **한 줄에 공백/콤마로 여러 URL** 입력 가능(각 검증), `Delete` 삭제, `Change Order` 순서 변경.
- **브랜치 지정**: `<url>#<branch>` (예: `https://github.com/o/r.git#dev`, `git@host:o/r.git#release/1.0`). 지정 시 그 브랜치로 clone(`-b`)·pull(`checkout`+`pull origin <branch>`). 미지정 시 기본/현재 브랜치.
- **유효 형식**: `https://…/…`, `git@host:owner/repo`, `ssh://…`, 로컬 경로 (선택적 `#branch`).
- **상태**: 등록된 유효 저장소가 0개이면 `/status`에 `[NOT SET]`.

#### 2. 워크스페이스 디렉터리 (`/workspace`, `/W`)

- **실행 전까지 `[NOT SET]`** — 실행해야 값이 정해집니다.
- **CLI direct**: `/workspace /path/to/dir`
- **TUI interactive**: `/workspace`만 입력 시 **① 현재 디렉터리(Current) ② 상위 디렉터리(Parent) ③ 사용자 지정(Custom path…)** 3가지 메뉴 중 선택/지정합니다.

#### 3. 인증 방식 (`/auth`, `/A`)

- **실행 전까지 `[NOT SET]`** — 실행 시 아래 **4가지** 중 선택/지정합니다.
- **TUI interactive** (`/auth`만 입력):
  1. **gh login status** — `gh auth status`로 현재 로그인 사용자를 확인하고 표시.
  2. **gh auth switch** — 여러 계정 간 활성 계정 전환.
  3. **gh auth login** — 신규 GitHub 로그인.
  4. **Register PAT** — Username(선택) + Personal Access Token 입력. 토큰은 임시 파일에 600 권한으로 저장되고 종료 시 자동 삭제됩니다.
- **CLI direct**: `/auth status|switch|login|pat` (스크립팅 호환용 `gh`/`none`도 허용).
- `/status`에는 인증 방식과 함께 확인된 현재 GitHub 사용자명이 표시됩니다.

#### 4. 배포 실행 (`/dist-run`, `/D`)

- **bootstrap 상태가 `[DONE]`이 아니면 실행하지 않습니다.** `[PENDING]`이면:
  - `/bootstrap`을 먼저 실행하라고 안내하고,
  - bootstrap 외에 `[NOT SET]`인 항목(Repos/Workspace/Auth)을 함께 출력한 뒤,
  - **아무것도 실행하지 않고 종료**합니다. (자동 부트스트랩하지 않습니다.)
- `[DONE]`일 때만 Makefile 배포 타겟(`up-*` 등)을 수집해 동적 TUI 메뉴로 제공합니다.
- pre-run 명령어 입력 단계를 거쳐 `make <target>`을 실행하고, 성공 시 캐시를 삭제하고 종료합니다.

> **상태 모델 요약**: 설정(repo·workspace·auth)은 채워지기 전 `[NOT SET]`. bootstrap은 셋 다 set일 때만
> 실행 가능하며 완료 시 `[DONE]`, 그 외에는 `[PENDING]`. 설정이 바뀌면 `[DONE]`은 다시 `[PENDING]`으로 무효화됩니다.

#### 5. 색상 테마 (`/theme`, `/T`)

Claude CLI 스타일의 색상 테마를 제공합니다. **최초 실행 시** 테마를 한 번 선택받고 캐시에 저장하여, 이후 재실행 시에는 다시 묻지 않습니다.

| 테마 | 설명 |
|---|---|
| `dark` | 어두운 배경용 기본 테마 |
| `light` | 밝은 배경용(어두운 텍스트) |
| `dark-daltonized` | 색약 친화(녹/적 혼동 회피 — 성공=파랑, 오류=주황) · 어두운 배경 |
| `light-daltonized` | 색약 친화 · 밝은 배경 |
| `dark-ansi` | 256/트루컬러 미사용, 16색 ANSI만 · 어두운 배경 |
| `light-ansi` | 16색 ANSI만 · 밝은 배경 |

- **CLI direct**: `/theme dark-daltonized` 형태로 즉시 전환.
- **TUI interactive**: `/theme`만 입력 시 현재 테마가 기본 선택된 메뉴가 뜨고, 선택 후 색 스와치(✓/!/✗/▶)를 미리보기로 출력합니다.
- 선택값은 **전용 영속 캐시** `/tmp/.wsa4sdd-theme-${UID}.cache`에 저장되어 `/status`에 표시됩니다.
- `/theme`,`/T`로 재설정하지 않으면 이전 캐시 값을 그대로 사용합니다. **세션 캐시 삭제(`/exit`·Ctrl+C 2회·배포 성공)에도 테마 캐시는 삭제되지 않습니다.**

---

## 3. 원격 직접 실행 및 설치 방법 (Execution & Installation)

### A. 원격 직접 실행 (curl | bash)

CI/CD 파이프라인이나 일회성 배포 환경에서 파일 다운로드 없이 원격 주소의 스크립트를 즉시 실행할 수 있습니다.

```bash
# 1) 원격 TUI 모드 실행 (인수 사전 입력 + 대화형 REPL 기동)
curl -fsSL https://raw.githubusercontent.com/WisemanLim/pub-wsa-for-sdd/main/wsa4sdd.sh \
  | bash -s -- -I "https://github.com/ClaroPessoas/claro-svc" -w "~/workspace"

# 2) 원격 비대화형 CLI 모드 실행 (자동 배포 실행)
curl -fsSL https://raw.githubusercontent.com/WisemanLim/pub-wsa-for-sdd/main/wsa4sdd.sh \
  | bash -s -- -I "https://github.com/ClaroPessoas/claro-svc" --cli

# 3) 원격 비대화형 CLI 드라이런 실행 (배포 없이 구성/동기화만 수행)
curl -fsSL https://raw.githubusercontent.com/WisemanLim/pub-wsa-for-sdd/main/wsa4sdd.sh \
  | bash -s -- -I "https://github.com/ClaroPessoas/claro-svc" --no-run

# 4) 기본환경 일괄 구성 (--default-env): workspace=현재경로, ops=첫 repo, auth=pat
curl -fsSL https://raw.githubusercontent.com/WisemanLim/pub-wsa-for-sdd/main/wsa4sdd.sh \
  | bash -s -- -I "https://github.com/ClaroPessoas/claro-svc" -a "<PAT_TOKEN>" --default-env
```

#### `--default-env` 기본환경 플래그

원격/자동화에서 한 줄로 기본환경을 구성하는 비대화 모드입니다.

- **`-a, --auth <값>`**: CLI 인증. 값이 `gh`/`pat`/`none` 키워드면 인증 방식, 그 외 문자열이면 **PAT 토큰**으로 직접 운반(방식=pat). `-a`/`--auth` 양형 지원.
- **`--default-env`** 처리 시:
  1. **`-I/--input`(repo) 필수** — 없으면 에러 출력 후 종료.
  2. **workspace = 현재 경로(PWD)**, **ops repo = 첫 번째 repo 이름** 자동 지정.
  3. **`-a/--auth` 필수**, 기본 방식 `pat`, **토큰 값을 반드시 받아야 실행** — 없으면 에러 출력 후 종료.
- ⚠️ `-a <token>`는 토큰이 프로세스 인자(argv)에 노출됩니다(ps/히스토리). 자동화/데모 편의용이며, 운영 시 CI 시크릿 마스킹을 권장합니다.

---

### B. 스크립트 다운로드 및 설치 (Download & Local Install)

스크립트를 로컬 시스템에 직접 내려받아 영구 설치하여 명령어로 사용하고 싶은 경우 아래 순서대로 수행합니다.

1. **스크립트 다운로드 및 실행 권한 부여**:

   ```bash
   curl -fsSL -o wsa4sdd.sh https://raw.githubusercontent.com/WisemanLim/pub-wsa-for-sdd/main/wsa4sdd.sh
   chmod +x wsa4sdd.sh
   ```

2. **시스템 경로(PATH)에 등록하여 글로벌 실행 (선택 사항)**:

   ```bash
   # /usr/local/bin 또는 사용자 환경의 PATH 경로로 파일 이동
   sudo mv wsa4sdd.sh /usr/local/bin/wsa4sdd
   ```

3. **로컬 실행 및 파라미터 전달 예시**:

   ```bash
   # 단독 실행 (기본 TUI 모드 기동)
   wsa4sdd

   # 사전 설정을 주입한 대화형 TUI 모드 기동
   wsa4sdd -I "https://github.com/ClaroPessoas/claro-svc" -w "~/workspace"

   # 비대화형 CLI 모드로 즉시 자동 배포 실행
   wsa4sdd -I "https://github.com/ClaroPessoas/claro-svc" --cli

   # 비대화형 CLI 모드로 빌드/동기화 드라이런만 실행 (배포 생략)
   wsa4sdd -I "https://github.com/ClaroPessoas/claro-svc" --no-run
   ```

### CLI Options

| 옵션              | 설명                                                                                                      | 예시                 |
| :---------------- | :-------------------------------------------------------------------------------------------------------- | :------------------- |
| `-I, --input`     | 공백으로 분리된 깃 저장소 URL 목록.                                                                       | `-I "url1 url2"`     |
| `-w, --workspace` | 저장소들을 클론할 타겟 디렉터리.                                                                          | `-w ~/dev/workspace` |
| `-o, --ops`       | Makefile 및 Compose 환경을 내장한 메인 조율 저장소 명칭.                                                  | `-o my-ops-repo`     |
| `--no-run`        | 저장소 동기화와 도구 빌드(Makefile 생성 등)까지만 수행하고 실제 배포 타겟 선택 및 실행 단계를 건너뜁니다. | `--no-run`           |
| `-h, --help`      | 도움말을 출력합니다.                                                                                      | `-h`                 |

---

## 4. 호환성 및 제약사항 (Compatibility)

- **macOS Native 완벽 호환**: macOS의 기본 시스템 쉘은 `/bin/bash` 3.2.x 버전입니다. `wsa4sdd.sh`는 Bash 4.x+ 전용 기능(예: `local -n` 레퍼런스 지시어, Associative Arrays `declare -A` 등)을 배제하고 순수 Bash 3.2 호환 문법으로 설계 및 구현되었습니다.
- **의존성 자동 확인**: TUI 진입 또는 `/bootstrap` 과정에서 `git`, `docker`, `docker compose`, `make` 등의 의존 도구가 현재 시스템에 정상 설치되어 있는지 자동으로 감지하고 미비 시 알림을 줍니다.
