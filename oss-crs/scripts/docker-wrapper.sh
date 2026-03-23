#!/bin/bash
# Docker wrapper for oss-crs: intercepts docker commands so FuzzingBrain
# strategies work without real Docker images.
#
# - `docker images <name> --format ...`  → returns a fake image name
# - `docker run -v host:/container ... IMAGE /container/binary args`
#     → uses unshare + bind mounts to make container paths real, then
#       runs the binary directly (no path translation needed)
# - Other commands → passed through to real docker (may fail, that's OK)

REAL_DOCKER="${REAL_DOCKER_PATH:-}"
if [ -z "$REAL_DOCKER" ]; then
    # Find the real docker binary (skip ourselves)
    SELF="$(readlink -f "$0")"
    for p in $(type -ap docker 2>/dev/null); do
        if [ "$(readlink -f "$p")" != "$SELF" ]; then
            REAL_DOCKER="$p"
            break
        fi
    done
fi

case "${1:-}" in
    images)
        # Strategy calls: docker images <name> --format "{{.Repository}}:{{.Tag}}"
        # Return a fake image name so strategies think Docker images exist.
        shift
        IMAGE_NAME=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --format) shift 2 ;; # skip --format and its value
                --format=*) shift ;;
                -*) shift ;;
                *)
                    if [ -z "$IMAGE_NAME" ]; then
                        IMAGE_NAME="$1"
                    fi
                    shift
                    ;;
            esac
        done
        if [ -n "$IMAGE_NAME" ]; then
            echo "${IMAGE_NAME}:latest"
        fi
        exit 0
        ;;

    info)
        # DinD readiness check — just succeed
        echo "Docker wrapper (oss-crs direct-execution mode)"
        exit 0
        ;;

    run)
        shift  # consume "run"

        # Parse docker run flags
        declare -a VOL_HOST=()
        declare -a VOL_CONT=()
        declare -a ENV_PAIRS=()
        IMAGE=""

        while [ $# -gt 0 ]; do
            case "$1" in
                --rm|--privileged) shift ;;
                --platform) shift 2 ;;
                --platform=*) shift ;;
                --shm-size|--shm-size=*) shift ;;
                -e)
                    ENV_PAIRS+=("$2")
                    shift 2
                    ;;
                -v)
                    local_vol="$2"
                    host_part="${local_vol%%:*}"
                    cont_part="${local_vol#*:}"
                    VOL_HOST+=("$host_part")
                    VOL_CONT+=("$cont_part")
                    shift 2
                    ;;
                -*)
                    if [ $# -gt 1 ] && [[ "$2" != -* ]]; then
                        shift 2
                    else
                        shift
                    fi
                    ;;
                *)
                    IMAGE="$1"
                    shift
                    break
                    ;;
            esac
        done

        # $@ is now the command (e.g. /out/fuzzer -timeout=30 /out/blob)

        if [ $# -eq 0 ]; then
            echo "docker-wrapper: no command after image name" >&2
            exit 1
        fi

        # Set environment variables
        for ev in "${ENV_PAIRS[@]}"; do
            export "$ev"
        done

        # Build mount commands: create mount points and bind-mount host→container paths.
        # This makes container paths (like /out, /src, /work) real on the filesystem
        # so the binary can use them natively — no path translation needed.
        MOUNT_SCRIPT=""
        for i in "${!VOL_HOST[@]}"; do
            hpath="${VOL_HOST[$i]}"
            cpath="${VOL_CONT[$i]}"
            # Ensure both host dir and mount point exist
            mkdir -p "$hpath" 2>/dev/null || true
            mkdir -p "$cpath" 2>/dev/null || true
            MOUNT_SCRIPT="${MOUNT_SCRIPT}mount --bind '${hpath}' '${cpath}' && "
        done

        # Make sure the binary is executable (use container path directly)
        BIN="$1"
        shift
        if [ -f "$BIN" ] && [ ! -x "$BIN" ]; then
            chmod +x "$BIN"
        fi

        # Run in an isolated mount namespace so bind mounts don't leak
        exec unshare -m sh -c "${MOUNT_SCRIPT}exec \"\$@\"" -- "$BIN" "$@"
        ;;

    build)
        # docker build needs real Docker — pass through (may fail)
        if [ -n "$REAL_DOCKER" ]; then
            exec "$REAL_DOCKER" "$@"
        else
            echo "docker-wrapper: docker build requires real Docker (not available)" >&2
            exit 1
        fi
        ;;

    *)
        # Pass through to real docker
        if [ -n "$REAL_DOCKER" ]; then
            exec "$REAL_DOCKER" "$@"
        else
            echo "docker-wrapper: unknown command '$1' and real Docker not available" >&2
            exit 1
        fi
        ;;
esac
