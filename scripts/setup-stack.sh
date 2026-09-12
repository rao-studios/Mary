#!/bin/bash
# WHAT: One-time setup of the local Sewn / Thread / Fleet stack on a new machine.
# IN:   git, swift, python3. Checkout paths and ports mirror ServerSpec.Defaults
#       (Sources/MaryRuntime/Services/Servers/ServerSpec.swift) — the same places
#       Mary's Servers sheet points at, so the app finds what this script builds.
# OUT:  Cloned + built checkouts, seeded .env files, the embedding model, and the
#       --data-dir directories under ~/Documents/maryOS.
# PIN:  Idempotent and non-destructive. An existing checkout is never reset,
#       pulled, or rebased. An existing .env is NEVER overwritten — this script
#       reads key NAMES only and never prints or copies a secret's value.
#       SwiftPM has no Metal step: each server's build-metallib.sh runs after
#       `swift build`, or the first on-device model load dies inside MLX with
#       "Failed to load the default metallib".
#
#   ./scripts/setup-stack.sh
#   ./scripts/setup-stack.sh --no-fleet --skip-model
#   SEWN_DIR=~/src/Sewn THREAD_DIR=~/src/Thread ./scripts/setup-stack.sh
#
set -euo pipefail

# ── Where things go (override with the matching env var) ────────────────────
REPO_ROOT_DEFAULT="$HOME/Documents/rao/repositories"
SEWN_DIR="${SEWN_DIR:-$REPO_ROOT_DEFAULT/Sewn}"
THREAD_DIR="${THREAD_DIR:-$REPO_ROOT_DEFAULT/Thread}"
FLEET_DIR="${FLEET_DIR:-$REPO_ROOT_DEFAULT/Fleet}"
DATA_ROOT="${MARY_DATA_ROOT:-$HOME/Documents/maryOS}"

SEWN_URL="https://github.com/rao-studios/Sewn.git"
THREAD_URL="https://github.com/rao-studios/Thread.git"
FLEET_URL="https://github.com/rao-studios/Fleet.git"

# Ports Mary will hand these servers (ServerSpec.Defaults).
SEWN_PORT=8080;  SEWN_GRPC=9091
THREAD_PORT=8081; THREAD_GRPC=9090
FLEET_PORT=8083; FLEET_GRPC=9093

EMBED_MODEL="mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"

WANT_FLEET=1
SKIP_MODEL=0
SKIP_BUILD=0

for arg in "$@"; do
    case "$arg" in
        --no-fleet)   WANT_FLEET=0 ;;
        --skip-model) SKIP_MODEL=1 ;;
        --skip-build) SKIP_BUILD=1 ;;
        -h|--help)
            sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "unknown option: $arg (try --help)" >&2
            exit 2 ;;
    esac
done

# Collected and printed at the end, so one run tells you everything left to do.
TODO=()
note_todo() { TODO+=("$1"); }

say()  { echo "▸ $*"; }
warn() { echo "  ! $*"; }

# ── 1. Tools ───────────────────────────────────────────────────────────────
say "checking tools"
for tool in git swift; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: '$tool' not found — install it first." >&2
        exit 1
    fi
done
echo "    git $(git --version | awk '{print $3}') · swift $(swift --version 2>/dev/null | head -1 | sed 's/.*version \([0-9.]*\).*/\1/')"

HAVE_PY=0
if command -v python3 >/dev/null 2>&1; then
    HAVE_PY=1
else
    warn "python3 not found — the embedding model download will be skipped."
fi

# ── 2. Checkouts ───────────────────────────────────────────────────────────
# Clone only when absent. A checkout that already exists is reported and left
# exactly as it is: this script never pulls, resets, or switches branches.
clone_if_missing() {
    local name="$1" dir="$2" url="$3"
    if [ -d "$dir/.git" ]; then
        local branch dirty
        branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
        dirty="$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
        echo "    $name: already at $dir ($branch, $dirty local change(s)) — left alone"
        return 0
    fi
    if [ -e "$dir" ]; then
        warn "$name: $dir exists but is not a git checkout — skipping clone."
        note_todo "$name: $dir is not a git checkout; move it aside and re-run."
        return 0
    fi
    echo "    $name: cloning into $dir"
    mkdir -p "$(dirname "$dir")"
    if ! git clone --quiet "$url" "$dir"; then
        warn "$name: clone failed from $url"
        note_todo "$name: clone failed — check network/access, then re-run."
        return 0
    fi
}

say "checkouts"
clone_if_missing "Sewn"   "$SEWN_DIR"   "$SEWN_URL"
clone_if_missing "Thread" "$THREAD_DIR" "$THREAD_URL"
if [ "$WANT_FLEET" -eq 1 ]; then
    clone_if_missing "Fleet" "$FLEET_DIR" "$FLEET_URL"
fi

# ── 3. Environment files ───────────────────────────────────────────────────
# Secrets are per-machine and git-ignored, so a fresh clone has none. We write
# a scaffold of KEY NAMES with empty values and never touch an existing file.
SEWN_ENV_KEYS=(
    SUPABASE_URL SUPABASE_ANON_KEY SUPABASE_SERVICE_KEY ADMIN_USER_ID
    MISTRAL_API_KEY TINKER_API_KEY TINKER_MODEL SEWN_GLOBAL_LLM
    AIRTABLE_API_KEY
    COCKPIT_METRICS_ENDPOINT COCKPIT_LOGS_ENDPOINT COCKPIT_TOKEN METRICS_TOKEN
)

write_sewn_env_scaffold() {
    local target="$1"
    {
        echo "# Sewn — local configuration. Git-ignored; fill these in by hand."
        echo "# Written by Mary's scripts/setup-stack.sh. Values are never copied"
        echo "# between machines; each key below is blank on purpose."
        echo ""
        echo "# Account + storage"
        for k in SUPABASE_URL SUPABASE_ANON_KEY SUPABASE_SERVICE_KEY ADMIN_USER_ID; do
            echo "$k="
        done
        echo ""
        echo "# Generation"
        for k in MISTRAL_API_KEY TINKER_API_KEY TINKER_MODEL SEWN_GLOBAL_LLM; do
            echo "$k="
        done
        echo ""
        echo "# Corpora"
        echo "AIRTABLE_API_KEY="
        echo ""
        echo "# Telemetry (optional — Sewn runs without these)"
        for k in COCKPIT_METRICS_ENDPOINT COCKPIT_LOGS_ENDPOINT COCKPIT_TOKEN METRICS_TOKEN; do
            echo "$k="
        done
    } > "$target"
}

# True when the key is absent or has an empty value. Never echoes the value.
key_is_blank() {
    local file="$1" key="$2" line
    line="$(grep -E "^${key}=" "$file" 2>/dev/null | head -1 || true)"
    [ -z "$line" ] && return 0
    [ -z "${line#${key}=}" ] && return 0
    return 1
}

say "environment files"

if [ -d "$SEWN_DIR" ]; then
    if [ -f "$SEWN_DIR/.env" ]; then
        echo "    Sewn: .env present — not modified"
        # Only worth re-reporting for a file we did not just create blank.
        blank=""
        for k in MISTRAL_API_KEY SUPABASE_URL SUPABASE_ANON_KEY; do
            if key_is_blank "$SEWN_DIR/.env" "$k"; then
                blank="$blank $k"
            fi
        done
        if [ -n "$blank" ]; then
            note_todo "Sewn: still blank in .env —$blank"
        fi
    else
        write_sewn_env_scaffold "$SEWN_DIR/.env"
        echo "    Sewn: wrote a blank .env scaffold (${#SEWN_ENV_KEYS[@]} keys)"
        note_todo "Sewn: fill in $SEWN_DIR/.env — MISTRAL_API_KEY and the SUPABASE_* keys at minimum."
    fi
fi

if [ -d "$THREAD_DIR" ]; then
    if [ -f "$THREAD_DIR/.env" ]; then
        echo "    Thread: .env present — not modified"
    elif [ -f "$THREAD_DIR/.env.example" ]; then
        cp "$THREAD_DIR/.env.example" "$THREAD_DIR/.env"
        echo "    Thread: .env seeded from .env.example"
        note_todo "Thread: set MISTRAL_API_KEY in $THREAD_DIR/.env (or run thread with --use-mlx)."
    else
        echo "MISTRAL_API_KEY=" > "$THREAD_DIR/.env"
        echo "    Thread: wrote a blank .env"
        note_todo "Thread: set MISTRAL_API_KEY in $THREAD_DIR/.env (or run thread with --use-mlx)."
    fi
    if [ -f "$THREAD_DIR/.env" ] && key_is_blank "$THREAD_DIR/.env" MISTRAL_API_KEY; then
        note_todo "Thread: MISTRAL_API_KEY is blank — on-device embedding needs --use-mlx instead."
    fi
fi

# ── 4. Embedding model ─────────────────────────────────────────────────────
# ~500 MB, cached in ~/.cache/huggingface and shared by every consumer.
if [ "$SKIP_MODEL" -eq 1 ]; then
    say "embedding model — skipped (--skip-model)"
elif [ "$HAVE_PY" -eq 0 ]; then
    note_todo "Install python3, then: python3 -m huggingface_hub download $EMBED_MODEL"
else
    say "embedding model ($EMBED_MODEL)"
    if python3 -c "import huggingface_hub" >/dev/null 2>&1; then
        if python3 -m huggingface_hub download "$EMBED_MODEL" >/dev/null 2>&1; then
            echo "    cached under ~/.cache/huggingface"
        else
            warn "download failed — the on-device embedder will fall back or fail."
            note_todo "Retry: python3 -m huggingface_hub download $EMBED_MODEL"
        fi
    else
        # Deliberately not pip-installing into someone else's interpreter.
        warn "huggingface_hub not installed for this python3."
        note_todo "pip3 install huggingface_hub && python3 -m huggingface_hub download $EMBED_MODEL"
    fi
fi

# ── 5. Build ───────────────────────────────────────────────────────────────
# swift build, then the Metal shaders MLX loads from beside the binary.
build_server() {
    local name="$1" dir="$2" exe="$3"
    [ -d "$dir" ] || return 0
    echo "    $name: swift build -c release"
    if ! (cd "$dir" && swift build -c release > /tmp/setup-stack-$name.log 2>&1); then
        warn "$name: build failed — see /tmp/setup-stack-$name.log"
        note_todo "$name: build failed; read /tmp/setup-stack-$name.log and re-run."
        return 0
    fi
    local metallib=""
    for candidate in "scripts/build-metallib.sh" "build-metallib.sh"; do
        if [ -f "$dir/$candidate" ]; then
            metallib="$candidate"
            break
        fi
    done
    if [ -n "$metallib" ]; then
        if (cd "$dir" && bash "$metallib" release >/dev/null 2>&1); then
            echo "    $name: mlx.metallib ready"
        else
            warn "$name: mlx.metallib FAILED — on-device work in this server will abort."
            note_todo "$name: run 'bash $metallib release' in $dir and read the error."
        fi
    fi
    if [ -x "$dir/.build/release/$exe" ]; then
        echo "    $name: built → .build/release/$exe"
    else
        warn "$name: expected binary .build/release/$exe not found"
        note_todo "$name: build produced no '$exe' binary — check the package's products."
    fi
}

if [ "$SKIP_BUILD" -eq 1 ]; then
    say "build — skipped (--skip-build)"
else
    say "building (release; first run pulls dependencies and takes a while)"
    build_server "Sewn"   "$SEWN_DIR"   "sewn-server"
    build_server "Thread" "$THREAD_DIR" "thread"
    if [ "$WANT_FLEET" -eq 1 ]; then
        build_server "Fleet" "$FLEET_DIR" "fleet"
    fi
fi

# ── 6. Data directories ────────────────────────────────────────────────────
# One directory per server, never a shared root: Fleet's reconcile sweeps
# unknown entries out of its own.
say "data directories under $DATA_ROOT"
for d in sewn-db thread-db fleet-db; do
    mkdir -p "$DATA_ROOT/$d"
done
echo "    sewn-db · thread-db · fleet-db"

# ── 7. Ports ───────────────────────────────────────────────────────────────
say "ports Mary will use"
# A port held by the server that belongs there is the stack already running,
# not a conflict — only a stranger on the port is something to act on.
check_port() {
    local label="$1" port="$2" expect="$3" holder
    if ! command -v lsof >/dev/null 2>&1; then
        echo "    $label :$port (lsof unavailable — not checked)"
        return 0
    fi
    holder="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -Fc 2>/dev/null \
        | grep '^c' | head -1 | cut -c2-)"
    if [ -z "$holder" ]; then
        echo "    $label :$port free"
    elif [ "$holder" = "$expect" ]; then
        echo "    $label :$port already served by $holder — stack is up"
    else
        warn "$label :$port held by '$holder'"
        note_todo "Port $port ($label) is held by '$holder' — stop it, or change the port in Mary's Servers sheet."
    fi
}
check_port "Sewn HTTP"   "$SEWN_PORT"   "sewn-server"
check_port "Sewn gRPC"   "$SEWN_GRPC"   "sewn-server"
check_port "Thread HTTP" "$THREAD_PORT" "thread"
check_port "Thread gRPC" "$THREAD_GRPC" "thread"
if [ "$WANT_FLEET" -eq 1 ]; then
    check_port "Fleet HTTP" "$FLEET_PORT" "fleet"
    check_port "Fleet gRPC" "$FLEET_GRPC" "fleet"
fi

# ── 8. What is left ────────────────────────────────────────────────────────
echo ""
if [ ${#TODO[@]} -eq 0 ]; then
    echo "══ Stack ready."
else
    echo "══ Still to do (${#TODO[@]}):"
    for t in "${TODO[@]}"; do echo "   • $t"; done
fi
echo ""
echo "Mary starts these herself when 'Start servers automatically' is on."
echo "Confirm the paths in Mary → Servers (the server.rack button) if you"
echo "cloned anywhere other than $REPO_ROOT_DEFAULT:"
echo "   Sewn   $SEWN_DIR"
echo "   Thread $THREAD_DIR"
if [ "$WANT_FLEET" -eq 1 ]; then
    echo "   Fleet  $FLEET_DIR"
fi
