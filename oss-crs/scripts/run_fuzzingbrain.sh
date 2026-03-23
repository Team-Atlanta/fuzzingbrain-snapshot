#!/bin/bash
# Run-phase entry point for FuzzingBrain in oss-crs.
# Sets up workspace, configures environment, and runs the CRS.
set -e

###############################################################################
# 1. Start Docker daemon (DinD) — needed for coverage builds and some strategies
###############################################################################
echo "[fuzzing-brain] Starting Docker daemon..."
_start_dockerd() {
    dockerd --host=unix:///var/run/docker.sock \
            --tls=false \
            --log-level=warn \
            --storage-driver="$1" &
    DOCKERD_PID=$!
}

_start_dockerd overlay2

DOCKER_READY=0
for i in $(seq 1 10); do
    if docker info >/dev/null 2>&1; then
        DOCKER_READY=1
        break
    fi
    if ! kill -0 $DOCKERD_PID 2>/dev/null; then
        echo "[fuzzing-brain] overlay2 failed, retrying with vfs..."
        _start_dockerd vfs
    fi
    sleep 1
done

if [ "$DOCKER_READY" = "0" ]; then
    for i in $(seq 1 30); do
        if docker info >/dev/null 2>&1; then
            DOCKER_READY=1
            break
        fi
        sleep 1
    done
fi

if [ "$DOCKER_READY" = "0" ]; then
    echo "[fuzzing-brain] WARNING: Docker daemon failed to start (coverage builds will be skipped)"
else
    echo "[fuzzing-brain] Docker daemon ready."
fi

###############################################################################
# 2. Download build outputs from the build phase
###############################################################################
echo "[fuzzing-brain] Downloading build outputs..."
mkdir -p /out /src /bootup/fetch
libCRS download-build-output build /out
libCRS download-build-output src /src
libCRS download-build-output fetch /bootup/fetch 2>/dev/null || true

###############################################################################
# 3. Register submission directories with libCRS
###############################################################################
mkdir -p /artifacts/povs /artifacts/patches
libCRS register-submit-dir pov /artifacts/povs &
SUBMIT_POV_PID=$!
libCRS register-submit-dir patch /artifacts/patches &
SUBMIT_PATCH_PID=$!
# Seed submit/fetch registered below after WORKSPACE and HARNESS are known

###############################################################################
# 4. Fetch any bootup data (diffs, seeds, POVs)
###############################################################################
mkdir -p /bootup/diffs /bootup/seeds /bootup/povs
libCRS fetch diff /bootup/diffs 2>/dev/null || true
libCRS fetch seed /bootup/seeds 2>/dev/null || true
libCRS fetch pov /bootup/povs 2>/dev/null || true

###############################################################################
# 5. Set up workspace directory structure expected by FuzzingBrain
#
# FuzzingBrain expects:
#   <taskDir>/
#   ├── <focus>/                           # source code (e.g., "repo")
#   ├── fuzz-tooling/
#   │   ├── projects/<projectName>/        # oss-fuzz project config
#   │   │   └── project.yaml
#   │   └── build/out/
#   │       └── <projectName>-address/     # pre-built fuzzers
#   ├── diff/
#   │   └── ref.diff                       # optional, for delta mode
#   └── task_detail.json
###############################################################################
echo "[fuzzing-brain] Setting up workspace..."

PROJECT="${OSS_CRS_TARGET:-unknown}"
HARNESS="${OSS_CRS_TARGET_HARNESS:-}"
LANGUAGE="${FUZZING_LANGUAGE:-c}"
SANITIZER_NAME="${SANITIZER:-address}"

WORKSPACE="/workspace"
mkdir -p "$WORKSPACE"

# Source code
if [ -d "/src" ] && [ "$(ls -A /src 2>/dev/null)" ]; then
    # Find the actual repo directory under /src
    # oss-fuzz $SRC may contain multiple directories; find the main one
    REPO_DIR=""
    for d in /src/*/; do
        if [ -d "$d/.git" ]; then
            REPO_DIR="$d"
            break
        fi
    done
    if [ -z "$REPO_DIR" ]; then
        # No .git found, use /src directly
        REPO_DIR="/src"
    fi
    ln -sfn "$REPO_DIR" "$WORKSPACE/repo"
else
    mkdir -p "$WORKSPACE/repo"
fi

# Strategies expect <focus>-<sanitizer> directories (e.g. repo-address)
# which are normally created during Docker-based builds.  Since oss-crs
# pre-builds fuzzers, create symlinks so strategies can find the source.
ln -sfn "$WORKSPACE/repo" "$WORKSPACE/repo-${SANITIZER_NAME}"

# Fuzz-tooling project config
PROJ_CONFIG_DIR="$WORKSPACE/fuzz-tooling/projects/$PROJECT"
mkdir -p "$PROJ_CONFIG_DIR"

# Create project.yaml from oss-crs environment variables
cat > "$PROJ_CONFIG_DIR/project.yaml" <<YAML
sanitizers:
  - ${SANITIZER_NAME}
language: ${LANGUAGE}
YAML
echo "[fuzzing-brain] Created project.yaml: language=$LANGUAGE, sanitizer=$SANITIZER_NAME"

# Copy harness source files and build scripts from /src to project config dir
# so find_fuzzer_source() can locate them.  In oss-fuzz, the harness .c/.cc
# files and build.sh live under the oss-fuzz project dir, but after build
# they end up as loose files in /src/ or in /src/fuzz/ etc.
# Strategies expect them in fuzz-tooling/projects/<project>/.
if [ -d "/src" ]; then
    # Copy build.sh if present at /src level
    for f in /src/build.sh /src/Dockerfile; do
        [ -f "$f" ] && cp "$f" "$PROJ_CONFIG_DIR/" 2>/dev/null || true
    done
    # Copy harness source files from /src top-level
    for ext in c cc cpp h java; do
        for f in /src/*."$ext"; do
            [ -f "$f" ] && cp "$f" "$PROJ_CONFIG_DIR/" 2>/dev/null || true
        done
    done
    # Copy fuzz/ directory if it exists (common oss-fuzz layout)
    if [ -d "/src/fuzz" ]; then
        cp -a /src/fuzz "$PROJ_CONFIG_DIR/" 2>/dev/null || true
    fi
    # Also check for harness/ or tests/ directories
    for d in harness harnesses test tests; do
        if [ -d "/src/$d" ]; then
            cp -a "/src/$d" "$PROJ_CONFIG_DIR/" 2>/dev/null || true
        fi
    done
    HARNESS_COUNT=$(find "$PROJ_CONFIG_DIR" \( -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.java' \) 2>/dev/null | wc -l)
    echo "[fuzzing-brain] Copied $HARNESS_COUNT harness source files to $PROJ_CONFIG_DIR"
fi

# Pre-built fuzzers from oss-crs build phase
FUZZER_DIR="$WORKSPACE/fuzz-tooling/build/out/${PROJECT}-${SANITIZER_NAME}"
mkdir -p "$FUZZER_DIR"
if [ -d "/out" ] && [ "$(ls -A /out 2>/dev/null)" ]; then
    cp -a /out/* "$FUZZER_DIR/" 2>/dev/null || true
    FUZZER_COUNT=$(find "$FUZZER_DIR" -maxdepth 1 -type f -executable | wc -l)
    echo "[fuzzing-brain] Placed $FUZZER_COUNT pre-built fuzzers in $FUZZER_DIR"
fi

# Delta diff (if available)
# Check bootup fetch dir first, then OSS_CRS_FETCH_DIR (exchange dir)
_found_diff=0
for _diff_search in /bootup/diffs /OSS_CRS_FETCH_DIR/diffs /bootup/fetch/diffs; do
    if [ "$_found_diff" = "1" ]; then break; fi
    if [ -f "$_diff_search/ref.diff" ]; then
        mkdir -p "$WORKSPACE/diff"
        cp "$_diff_search/ref.diff" "$WORKSPACE/diff/ref.diff"
        _found_diff=1
    elif ls "$_diff_search"/*.diff 1>/dev/null 2>&1; then
        mkdir -p "$WORKSPACE/diff"
        cp "$(ls "$_diff_search"/*.diff | head -1)" "$WORKSPACE/diff/ref.diff"
        _found_diff=1
    fi
done
# Also search recursively in FETCH_DIR (exchange dir may nest under target/harness)
if [ "$_found_diff" = "0" ] && [ -d "/OSS_CRS_FETCH_DIR" ]; then
    _diff_file=$(find /OSS_CRS_FETCH_DIR -name "ref.diff" -type f 2>/dev/null | head -1)
    if [ -n "$_diff_file" ]; then
        mkdir -p "$WORKSPACE/diff"
        cp "$_diff_file" "$WORKSPACE/diff/ref.diff"
        _found_diff=1
    fi
fi
# Check if diff was provided during build phase (build_fetch_dir)
if [ "$_found_diff" = "0" ] && [ -d "/OSS_CRS_BUILD_OUT_DIR" ]; then
    _diff_file=$(find /OSS_CRS_BUILD_OUT_DIR -name "ref.diff" -type f 2>/dev/null | head -1)
    if [ -n "$_diff_file" ]; then
        mkdir -p "$WORKSPACE/diff"
        cp "$_diff_file" "$WORKSPACE/diff/ref.diff"
        _found_diff=1
    fi
fi
# Check if diff was bundled in the source tree (e.g. .aixcc/ref.diff)
if [ "$_found_diff" = "0" ] && [ -d "/src" ]; then
    _diff_file=$(find /src -name "ref.diff" -type f 2>/dev/null | head -1)
    if [ -n "$_diff_file" ]; then
        mkdir -p "$WORKSPACE/diff"
        cp "$_diff_file" "$WORKSPACE/diff/ref.diff"
        _found_diff=1
    fi
fi
if [ "$_found_diff" = "1" ]; then
    echo "[fuzzing-brain] Found delta diff, running in delta mode"
fi

# Seed corpus (if available)
if [ "$(ls -A /bootup/seeds 2>/dev/null)" ]; then
    SEED_CORPUS_DIR="$FUZZER_DIR/${HARNESS}_seed_corpus"
    mkdir -p "$SEED_CORPUS_DIR"
    cp -a /bootup/seeds/* "$SEED_CORPUS_DIR/" 2>/dev/null || true
    echo "[fuzzing-brain] Populated seed corpus"
fi

# Create task_detail.json
python3 /opt/fuzzing-brain-oss-crs/setup_workspace.py

###############################################################################
# 6. Install Docker wrapper (intercepts docker commands for direct execution)
#    Strategies call `docker images` / `docker run` to validate crash inputs.
#    In oss-crs containers there are no Docker images, so the wrapper fakes
#    image lookups and translates `docker run` into direct binary execution.
###############################################################################
WRAPPER_DIR="/opt/fuzzing-brain-oss-crs/bin"
mkdir -p "$WRAPPER_DIR"
cp /opt/fuzzing-brain-oss-crs/docker-wrapper.sh "$WRAPPER_DIR/docker"
chmod +x "$WRAPPER_DIR/docker"
export REAL_DOCKER_PATH="$(which docker 2>/dev/null || true)"
export PATH="$WRAPPER_DIR:$PATH"
echo "[fuzzing-brain] Installed docker wrapper (direct execution mode)"

###############################################################################
# 7. Start static analysis service (needed for full scan strategies)
###############################################################################
if [ -x /app/static-analysis-local ]; then
    echo "[fuzzing-brain] Starting static analysis service on :7082..."
    /app/static-analysis-local &
    ANALYSIS_PID=$!
else
    echo "[fuzzing-brain] WARNING: static-analysis-local not found, full scan analysis will be limited"
    ANALYSIS_PID=""
fi

###############################################################################
# 8. Configure environment for FuzzingBrain
###############################################################################
export LOCAL_TEST=1
export STRATEGY_BASE_DIR=/app/strategy
export CRS_WORKDIR=/crs-workdir
export OTEL_SDK_DISABLED=true
export FUZZER_SANITIZERS="${SANITIZER_NAME}"
export FUZZER_PREFERRED_SANITIZER="${SANITIZER_NAME}"
# Only run the harness specified by oss-crs (avoid wasting resources on other fuzzers)
if [ -n "$HARNESS" ]; then
    export FUZZER_SELECTED="${HARNESS}"
    export FUZZER_DISCOVERY_MODE=config
else
    export FUZZER_DISCOVERY_MODE=auto
fi
export GIT_DISCOVERY_ACROSS_FILESYSTEM=1
export WORKSPACE="$WORKSPACE"

# Strategy configuration — match original .env.example defaults:
#   Basic delta: xs*_delta_new.py (no match in jeff/ → basic phase skipped)
#   Advanced delta: xs0_delta.py (runs in advanced phase with multi-round budget)
#   Advanced full: as0_full.py
export STRATEGY_POV_ADVANCED_DELTA_PATTERN="${STRATEGY_POV_ADVANCED_DELTA_PATTERN:-xs0_delta.py}"
export STRATEGY_POV_ADVANCED_FULL_PATTERN="${STRATEGY_POV_ADVANCED_FULL_PATTERN:-as0_full.py}"
export STRATEGY_PATCH_DELTA_PATTERN="${STRATEGY_PATCH_DELTA_PATTERN:-patch0_delta.py}"
export STRATEGY_PATCH_FULL_PATTERN="${STRATEGY_PATCH_FULL_PATTERN:-patch0_full.py}"
export STRATEGY_XPATCH_SELECTED="${STRATEGY_XPATCH_SELECTED:-none}"
export STRATEGY_ENABLE_PATCHING="${STRATEGY_ENABLE_PATCHING:-true}"

# LLM configuration: use oss-crs LiteLLM proxy if available
if [ -n "$OSS_CRS_LLM_API_URL" ] && [ -n "$OSS_CRS_LLM_API_KEY" ]; then
    echo "[fuzzing-brain] Configuring LLM via oss-crs proxy: $OSS_CRS_LLM_API_URL"
    # Install usercustomize.py to monkey-patch litellm.completion and
    # google.generativeai so ALL model calls route through the proxy.
    # Install monkey-patch that routes all litellm/gemini calls through the proxy.
    # We use a .pth file to trigger auto-import at Python startup.
    SITE_PKG=$(python3 -c "import site; print(site.getsitepackages()[0])")
    cp /opt/fuzzing-brain-oss-crs/litellm_proxy_patch.py "$SITE_PKG/litellm_proxy_patch.py"
    echo "import litellm_proxy_patch" > "$SITE_PKG/litellm_proxy_patch.pth"
    echo "[fuzzing-brain] Installed LLM proxy patch via .pth in $SITE_PKG"

    # Export proxy env vars for both the patch and client.py
    export OSS_CRS_LLM_API_URL
    export OSS_CRS_LLM_API_KEY
    # Set ALL provider API keys to the proxy key so Go config validation
    # passes regardless of which model name is used.  The actual routing
    # to the real provider happens inside the litellm proxy.
    export OPENAI_API_KEY="${OSS_CRS_LLM_API_KEY}"
    export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-$OSS_CRS_LLM_API_KEY}"
    export GEMINI_API_KEY="${GEMINI_API_KEY:-$OSS_CRS_LLM_API_KEY}"
    # AI_MODEL: use Go default (claude-sonnet-4-20250514) unless overridden
    # via AI_MODEL env or compose additional_env
fi

# Per-fuzzer timeout (defaults to 60 minutes if not set)
if [ -n "$OSS_CRS_TIMEOUT" ]; then
    TIMEOUT_MINUTES=$(( OSS_CRS_TIMEOUT / 60 ))
    export FUZZER_PER_FUZZER_TIMEOUT_MINUTES="${TIMEOUT_MINUTES}"
fi

###############################################################################
# 8. Set up POV/patch artifact forwarding
#    Copy any POVs/patches found by FuzzingBrain to the libCRS submit dirs
###############################################################################
_forward_artifacts() {
    while true; do
        sleep 10
        # Forward POVs
        if [ -d "$WORKSPACE" ]; then
            find "$WORKSPACE" -path "*/successful_povs*/*" -name "*.bin" -newer /tmp/.last_pov_sync 2>/dev/null | while read -r pov; do
                cp "$pov" /artifacts/povs/ 2>/dev/null || true
            done
            # Forward patches
            find "$WORKSPACE" -path "*/successful_patches/*" -name "*.diff" -newer /tmp/.last_pov_sync 2>/dev/null | while read -r patch; do
                cp "$patch" /artifacts/patches/ 2>/dev/null || true
            done
        fi
        touch /tmp/.last_pov_sync
    done
}
touch /tmp/.last_pov_sync
_forward_artifacts &
FORWARD_PID=$!

###############################################################################
# 9. Register seed exchange with libCRS
#    FuzzingBrain has two seed directories:
#    - ${HARNESS}_corpus:      fuzzer persistent corpus (runtime seeds)
#    - ${HARNESS}_seed_corpus: LLM-generated seeds fed to fuzzer as additional_corpus
#    Submit from both so ensemble partners get all seeds.
#    Fetch into _corpus (fuzzer picks up via -reload=300).
###############################################################################
CORPUS_DIR="$WORKSPACE/${HARNESS}_corpus"
SEED_CORPUS_DIR="$WORKSPACE/${HARNESS}_seed_corpus"
mkdir -p "$CORPUS_DIR" "$SEED_CORPUS_DIR"
libCRS register-submit-dir seed "$CORPUS_DIR" &
SUBMIT_SEED_PID=$!
libCRS register-submit-dir seed "$SEED_CORPUS_DIR" &
libCRS register-fetch-dir seed "$CORPUS_DIR" &

###############################################################################
# 10. Run FuzzingBrain
###############################################################################
echo "[fuzzing-brain] Starting FuzzingBrain CRS..."
echo "[fuzzing-brain] Workspace: $WORKSPACE"
echo "[fuzzing-brain] Project: $PROJECT"
echo "[fuzzing-brain] Harness: $HARNESS"
echo "[fuzzing-brain] Language: $LANGUAGE"
echo "[fuzzing-brain] Sanitizer: $SANITIZER_NAME"

cd /app
/app/crs-local "$WORKSPACE"
EXIT_CODE=$?

echo "[fuzzing-brain] CRS exited with code $EXIT_CODE"

# Final artifact sync
sleep 2
if [ -d "$WORKSPACE" ]; then
    find "$WORKSPACE" -path "*/successful_povs*/*" -name "*.bin" 2>/dev/null | while read -r pov; do
        cp "$pov" /artifacts/povs/ 2>/dev/null || true
    done
    find "$WORKSPACE" -path "*/successful_patches/*" -name "*.diff" 2>/dev/null | while read -r patch; do
        cp "$patch" /artifacts/patches/ 2>/dev/null || true
    done
fi

# Give libCRS watchers time to sync artifacts to SUBMIT_DIR
echo "[fuzzing-brain] Waiting for libCRS to sync artifacts..."
sleep 10

# Cleanup
kill $SUBMIT_POV_PID $SUBMIT_SEED_PID $SUBMIT_PATCH_PID $FORWARD_PID $ANALYSIS_PID 2>/dev/null || true

exit $EXIT_CODE
