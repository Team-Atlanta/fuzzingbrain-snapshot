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
mkdir -p /out /src
libCRS download-build-output build /out
libCRS download-build-output src /src

###############################################################################
# 3. Register submission directories with libCRS
###############################################################################
mkdir -p /artifacts/povs /artifacts/seeds /artifacts/patches
libCRS register-submit-dir pov /artifacts/povs &
SUBMIT_POV_PID=$!
libCRS register-submit-dir seed /artifacts/seeds &
SUBMIT_SEED_PID=$!
libCRS register-submit-dir patch /artifacts/patches &
SUBMIT_PATCH_PID=$!

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

# Pre-built fuzzers from oss-crs build phase
FUZZER_DIR="$WORKSPACE/fuzz-tooling/build/out/${PROJECT}-${SANITIZER_NAME}"
mkdir -p "$FUZZER_DIR"
if [ -d "/out" ] && [ "$(ls -A /out 2>/dev/null)" ]; then
    cp -a /out/* "$FUZZER_DIR/" 2>/dev/null || true
    FUZZER_COUNT=$(find "$FUZZER_DIR" -maxdepth 1 -type f -executable | wc -l)
    echo "[fuzzing-brain] Placed $FUZZER_COUNT pre-built fuzzers in $FUZZER_DIR"
fi

# Delta diff (if available)
if [ -f "/bootup/diffs/ref.diff" ]; then
    mkdir -p "$WORKSPACE/diff"
    cp /bootup/diffs/ref.diff "$WORKSPACE/diff/ref.diff"
    echo "[fuzzing-brain] Found delta diff, running in delta mode"
elif ls /bootup/diffs/*.diff 1>/dev/null 2>&1; then
    mkdir -p "$WORKSPACE/diff"
    cp /bootup/diffs/*.diff "$WORKSPACE/diff/ref.diff" 2>/dev/null || \
    cp "$(ls /bootup/diffs/*.diff | head -1)" "$WORKSPACE/diff/ref.diff"
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
# 6. Configure environment for FuzzingBrain
###############################################################################
export LOCAL_TEST=1
export STRATEGY_BASE_DIR=/app/strategy
export CRS_WORKDIR=/crs-workdir
export OTEL_SDK_DISABLED=true
export FUZZER_SANITIZERS="${SANITIZER_NAME}"
export FUZZER_PREFERRED_SANITIZER="${SANITIZER_NAME}"
export FUZZER_DISCOVERY_MODE=auto
export GIT_DISCOVERY_ACROSS_FILESYSTEM=1
export WORKSPACE="$WORKSPACE"

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
    # Set OPENAI_API_KEY so Go config validation passes and litellm has a key
    export OPENAI_API_KEY="${OPENAI_API_KEY:-$OSS_CRS_LLM_API_KEY}"
    # Default model must match what the proxy actually serves.
    # The Go backend validates that the matching API key env var is set.
    # Use gpt-4o as default since it's always available in the example config.
    export AI_MODEL="${AI_MODEL:-gpt-4o}"
fi

# Per-fuzzer timeout (defaults to 60 minutes if not set)
if [ -n "$OSS_CRS_TIMEOUT" ]; then
    TIMEOUT_MINUTES=$(( OSS_CRS_TIMEOUT / 60 ))
    export FUZZER_PER_FUZZER_TIMEOUT_MINUTES="${TIMEOUT_MINUTES}"
fi

###############################################################################
# 7. Set up POV/patch artifact forwarding
#    Copy any POVs/patches found by FuzzingBrain to the libCRS submit dirs
###############################################################################
_forward_artifacts() {
    while true; do
        sleep 10
        # Forward POVs
        if [ -d "$WORKSPACE" ]; then
            find "$WORKSPACE" -path "*/successful_povs/*" -name "*.bin" -newer /tmp/.last_pov_sync 2>/dev/null | while read -r pov; do
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
# 8. Run FuzzingBrain
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
    find "$WORKSPACE" -path "*/successful_povs/*" -name "*.bin" 2>/dev/null | while read -r pov; do
        cp "$pov" /artifacts/povs/ 2>/dev/null || true
    done
    find "$WORKSPACE" -path "*/successful_patches/*" -name "*.diff" 2>/dev/null | while read -r patch; do
        cp "$patch" /artifacts/patches/ 2>/dev/null || true
    done
fi

# Cleanup
kill $SUBMIT_POV_PID $SUBMIT_SEED_PID $SUBMIT_PATCH_PID $FORWARD_PID 2>/dev/null || true

exit $EXIT_CODE
