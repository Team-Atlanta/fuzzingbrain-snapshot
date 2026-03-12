#!/bin/bash
# Docker wrapper for oss-crs: intercepts docker commands so FuzzingBrain
# strategies work without real Docker images.
#
# - `docker images <name> --format ...`  → returns a fake image name
# - `docker run -v host:/container ... IMAGE /container/binary args`
#     → translates container paths to host paths via -v mappings, then
#       runs the binary directly
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
                --format|--format=*) shift ;; # skip format flag and value
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
        SKIP_NEXT=""

        while [ $# -gt 0 ]; do
            if [ -n "$SKIP_NEXT" ]; then
                SKIP_NEXT=""
                shift
                continue
            fi
            case "$1" in
                --rm|--privileged) shift ;;
                --platform) shift 2 ;;   # --platform linux/amd64
                --platform=*) shift ;;
                --shm-size|--shm-size=*) shift ;;
                -e)
                    ENV_PAIRS+=("$2")
                    shift 2
                    ;;
                -v)
                    # Parse host:container (handle paths with colons carefully)
                    local_vol="$2"
                    # Split on first colon only
                    host_part="${local_vol%%:*}"
                    cont_part="${local_vol#*:}"
                    VOL_HOST+=("$host_part")
                    VOL_CONT+=("$cont_part")
                    shift 2
                    ;;
                -*)
                    # Unknown flag — check if next arg looks like a value
                    if [ $# -gt 1 ] && [[ "$2" != -* ]]; then
                        shift 2
                    else
                        shift
                    fi
                    ;;
                *)
                    # First positional arg = image name; rest = command
                    IMAGE="$1"
                    shift
                    break
                    ;;
            esac
        done

        # Now $@ is the command to run (e.g. /out/fuzzer -timeout=30 /out/blob)

        # Set environment variables
        for ev in "${ENV_PAIRS[@]}"; do
            export "$ev"
        done

        # Translate a container path to host path using volume mappings
        _translate() {
            local p="$1"
            local i
            for i in "${!VOL_CONT[@]}"; do
                local cpath="${VOL_CONT[$i]}"
                local hpath="${VOL_HOST[$i]}"
                # Exact match or prefix match with /
                if [ "$p" = "$cpath" ]; then
                    echo "$hpath"
                    return
                elif [[ "$p" == "${cpath}/"* ]]; then
                    echo "${hpath}/${p#${cpath}/}"
                    return
                fi
            done
            # No translation needed
            echo "$p"
        }

        if [ $# -eq 0 ]; then
            echo "docker-wrapper: no command after image name" >&2
            exit 1
        fi

        # Check if command is "bash -c ..." (coverage post-processing etc.)
        if [ "$1" = "bash" ] && [ "${2:-}" = "-c" ]; then
            # Translate paths inside the shell command string
            SHELL_CMD="$3"
            for i in "${!VOL_CONT[@]}"; do
                cpath="${VOL_CONT[$i]}"
                hpath="${VOL_HOST[$i]}"
                SHELL_CMD="${SHELL_CMD//${cpath}/${hpath}}"
            done
            exec bash -c "$SHELL_CMD"
        fi

        # Translate binary path and all arguments
        REAL_BIN="$(_translate "$1")"
        shift
        REAL_ARGS=()
        for arg in "$@"; do
            REAL_ARGS+=("$(_translate "$arg")")
        done

        # Make sure binary is executable
        if [ -f "$REAL_BIN" ] && [ ! -x "$REAL_BIN" ]; then
            chmod +x "$REAL_BIN"
        fi

        if [ ! -f "$REAL_BIN" ]; then
            echo "docker-wrapper: binary not found: $REAL_BIN" >&2
            exit 1
        fi

        exec "$REAL_BIN" "${REAL_ARGS[@]}"
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
