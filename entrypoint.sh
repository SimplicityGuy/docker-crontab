#!/bin/bash

set -e

if [ -z "${HOME_DIR}" ] && [ -n "${TEST_MODE}" ]; then
    HOME_DIR=/tmp/crontab-docker-testing
    CRONTAB_FILE=${HOME_DIR}/test
elif [ -z "${HOME_DIR}" ]; then
    echo "HOME_DIR not set."
    exit 1
else
    CRONTAB_FILE="${HOME_DIR}/crontab"
fi

# Ensure dir exist - in case of volume mapping.
# This needs to run as root to set proper permissions
if [ "$(id -u)" = "0" ]; then
    mkdir -p "${HOME_DIR}"/jobs "${HOME_DIR}"/crontabs
    # Only chown the directories we create, not the entire HOME_DIR (to avoid issues with read-only mounts)
    chown docker:docker "${HOME_DIR}"/jobs "${HOME_DIR}"/crontabs 2>/dev/null || true
    # Try to chown HOME_DIR itself, but ignore errors for read-only mounts
    chown docker:docker "${HOME_DIR}" 2>/dev/null || true
else
    # If not root, try to create directories (may fail if permissions are wrong)
    mkdir -p "${HOME_DIR}"/jobs "${HOME_DIR}"/crontabs 2>/dev/null || {
        echo "Warning: Cannot create ${HOME_DIR} directories. Ensure proper volume permissions."
        echo "Run: sudo chown -R $(id -u docker):$(id -g docker) /path/to/host/directory"
    }
fi

if [ -z "${DOCKER_HOST}" ] && [ -n "${DOCKER_PORT_2375_TCP}" ]; then
    export DOCKER_HOST="tcp://docker:2375"
fi

normalize_config() {
    JSON_CONFIG={}
    if [ -f "${HOME_DIR}/config.json" ]; then
        JSON_CONFIG="$(cat "${HOME_DIR}"/config.json)"
    elif [ -f "${HOME_DIR}/config.toml" ]; then
        JSON_CONFIG="$(yq -p toml -o json < "${HOME_DIR}/config.toml")"
    elif [ -f "${HOME_DIR}/config.yml" ]; then
        JSON_CONFIG="$(yq -o json < "${HOME_DIR}/config.yml")"
    elif [ -f "${HOME_DIR}/config.yaml" ]; then
        JSON_CONFIG="$(yq -o json < "${HOME_DIR}/config.yaml")"
    else
        echo "Warning: No config file found in ${HOME_DIR}. Checked config.json, config.toml, config.yml, config.yaml"
    fi

    jq -S -r 'if type == "array" then .
    else (."~~shared-settings" // {}) as $shared | del(."~~shared-settings") | to_entries | map_values($shared + .value + { name: .key })
    end' <<< "${JSON_CONFIG}" > "${HOME_DIR}"/config.working.json
}

slugify() {
    echo "${@}" | iconv -t ascii | sed -r s/[~^]+//g | sed -r s/[^a-zA-Z0-9]+/-/g | sed -r s/^-+\|-+$//g | tr '[:upper:]' '[:lower:]'
}

make_image_cmd() {
    DOCKERARGS=$(echo "${1}" | jq -r .dockerargs)
    ENVIRONMENT=$(echo "${1}" | jq -r 'select(.environment != null) | .environment | map("--env " + .) | join(" ")')
    EXPOSE=$(echo "${1}" | jq -r 'select(.expose != null) | .expose | map("--expose " + .) | join(" ")' )
    NAME=$(echo "${1}" | jq -r 'select(.name != null) | .name')
    NETWORKS=$(echo "${1}" | jq -r 'select(.networks != null) | .networks | map("--network " + .) | join(" ")')
    PORTS=$(echo "${1}" | jq -r 'select(.ports != null) | .ports | map("--publish " + .) | join(" ")')
    VOLUMES=$(echo "${1}" | jq -r 'select(.volumes != null) | .volumes | map("--volume " + .) | join(" ")')

    if [ "${DOCKERARGS}" == "null" ]; then DOCKERARGS=; fi
    # Add --rm unless already specified in dockerargs
    if ! echo "${DOCKERARGS}" | grep -q -- '--rm'; then
        DOCKERARGS="--rm ${DOCKERARGS}"
    fi
    DOCKERARGS+=" "
    if [ -n "${ENVIRONMENT}" ]; then DOCKERARGS+="${ENVIRONMENT} "; fi
    if [ -n "${EXPOSE}" ]; then DOCKERARGS+="${EXPOSE} "; fi
    if [ -n "${NAME}" ]; then DOCKERARGS+="--name \"${NAME}\" "; fi
    if [ -n "${NETWORKS}" ]; then DOCKERARGS+="${NETWORKS} "; fi
    if [ -n "${PORTS}" ]; then DOCKERARGS+="${PORTS} "; fi
    if [ -n "${VOLUMES}" ]; then DOCKERARGS+="${VOLUMES} "; fi

    IMAGE=$(echo "${1}" | jq -r .image | envsubst)
    if [ "${IMAGE}" == "null" ]; then return; fi

    COMMAND=$(echo "${1}" | jq -r .command)
    if [ "${COMMAND}" == "null" ]; then return; fi

    echo "docker run ${DOCKERARGS} \"${IMAGE}\" ${COMMAND}"
}

make_container_cmd() {
    DOCKERARGS=$(echo "${1}" | jq -r .dockerargs)
    if [ "${DOCKERARGS}" == "null" ]; then DOCKERARGS=; fi

    CONTAINER=$(echo "${1}" | jq -r .container | envsubst)
    if [ "${CONTAINER}" == "null" ]; then return; fi

    COMMAND=$(echo "${1}" | jq -r .command )
    if [ "${COMMAND}" == "null" ]; then return; fi

    echo "docker exec ${DOCKERARGS} \"${CONTAINER}\" ${COMMAND}"
}

make_cmd() {
    if [ "$(echo "${1}" | jq -r .image)" != "null" ]; then
        make_image_cmd "${1}"
    elif [ "$(echo "${1}" | jq -r .container)" != "null" ]; then
        make_container_cmd "${1}"
    else
        echo "${1}" | jq -r .command
    fi
}

parse_schedule() {
    IFS=" " read -r -a params <<< "$@"

    case ${params[0]} in
        "@yearly" | "@annually")
            echo "0 0 1 1 *"
            ;;
        "@monthly")
            echo "0 0 1 * *"
            ;;
        "@weekly")
            echo "0 0 * * 0"
            ;;
        "@daily")
            echo "0 0 * * *"
            ;;
        "@midnight")
            echo "0 0 * * *"
            ;;
        "@hourly")
            echo "0 * * * *"
            ;;
        "@random")
            M="*"
            H="*"
            D="*"

            for when in "${params[@]:1}"
            do
                case $when in
                    "@m")
                        M=$(shuf -i 0-59 -n 1)
                        ;;
                    "@h")
                        H=$(shuf -i 0-23 -n 1)
                        ;;
                    "@d")
                        D=$(shuf -i 0-6 -n 1)
                        ;;
                esac
            done

            echo "${M} ${H} * * ${D}"
            ;;
        "@every")
            echo "Error: '@every' schedule is not supported by BusyBox crond. Use standard cron syntax (e.g., '*/2 * * * *' instead of '@every 2m')." >&2
            return 1
            ;;
        *)
            echo "${params[@]}"
            ;;
    esac
}

function build_crontab() {
    rm -rf "${CRONTAB_FILE}"

    ONSTART=()
    JOB_NAMES=()
    JOB_SCHEDULES=()
    JOB_ONSTART_FLAGS=()
    while read -r i ; do
        KEY=$(jq -r .["$i"] "${CONFIG}")

        SCHEDULE=$(echo "${KEY}" | jq -r '.schedule')
        if [ "${SCHEDULE}" == "null" ]; then
            echo "'schedule' missing: '${KEY}'"
            continue
        fi
        if ! SCHEDULE=$(parse_schedule "${SCHEDULE}"); then
            echo "Skipping job: unsupported schedule"
            continue
        fi

        COMMAND=$(echo "${KEY}" | jq -r '.command')
        if [ "${COMMAND}" == "null" ]; then
            echo "'command' missing: '${KEY}'"
            continue
        fi

        COMMENT=$(echo "${KEY}" | jq -r '.comment' | tr -d '\n\r')

        SCRIPT_NAME=$(echo "${KEY}" | jq -r '.name')
        SCRIPT_NAME=$(slugify "${SCRIPT_NAME}")
        if [ "${SCRIPT_NAME}" == "null" ] || [ -z "${SCRIPT_NAME}" ]; then
            SCRIPT_NAME=$(cat /proc/sys/kernel/random/uuid)
        fi

        CRON_COMMAND=$(make_cmd "${KEY}")

        SCRIPT_PATH="${HOME_DIR}/jobs/${SCRIPT_NAME}.sh"

        # Detect slug collisions and append counter suffix
        if [ -f "${SCRIPT_PATH}" ]; then
            COLLISION_COUNT=1
            while [ -f "${HOME_DIR}/jobs/${SCRIPT_NAME}-${COLLISION_COUNT}.sh" ]; do
                COLLISION_COUNT=$((COLLISION_COUNT + 1))
            done
            SCRIPT_NAME="${SCRIPT_NAME}-${COLLISION_COUNT}"
            SCRIPT_PATH="${HOME_DIR}/jobs/${SCRIPT_NAME}.sh"
        fi

        # Build script content in temp file, then move atomically
        SCRIPT_TMP=$(mktemp)
        trap 'rm -f "${SCRIPT_TMP}"' EXIT
        {
            echo '#!/usr/bin/env bash'
            echo "set -e"
            echo ""
            echo "JOB_NAME=\"${SCRIPT_NAME}\""
            echo "TIMESTAMP=\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo "PID=\$\$"
            echo ""
            echo "# Log job start to database"
            echo "python3 /opt/crontab/webapp/db_logger.py start \"\${JOB_NAME}\" \"\${TIMESTAMP}\" \"cron\" \"\${PID}\" 2>&1 || true"
            echo ""
            echo "# Capture output to temp files"
            echo "STDOUT_FILE=\"/tmp/job-\${JOB_NAME}-\$\$.stdout\""
            echo "STDERR_FILE=\"/tmp/job-\${JOB_NAME}-\$\$.stderr\""
            echo ""
            echo "echo \"\$(date '+%Y-%m-%d %H:%M:%S') [start] ${SCRIPT_NAME}\""
            echo "set +e"
            echo "${CRON_COMMAND} > \"\${STDOUT_FILE}\" 2> \"\${STDERR_FILE}\""
            echo "EXIT_CODE=\$?"
            echo "set -e"
            echo ""
            echo "# Log job completion to database"
            echo "END_TIMESTAMP=\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo "python3 /opt/crontab/webapp/db_logger.py end \"\${JOB_NAME}\" \"\${END_TIMESTAMP}\" \"\${EXIT_CODE}\" \"\${STDOUT_FILE}\" \"\${STDERR_FILE}\" 2>&1 || true"
            echo ""
            echo "# Output to container logs"
            echo "cat \"\${STDOUT_FILE}\" 2>/dev/null || true"
            echo "cat \"\${STDERR_FILE}\" >&2 2>/dev/null || true"
            echo ""
            echo "# Clean up temp files"
            echo "rm -f \"\${STDOUT_FILE}\" \"\${STDERR_FILE}\""
        } > "${SCRIPT_TMP}"

        TRIGGER=$(echo "${KEY}" | jq -r '.trigger')
        if [ "${TRIGGER}" != "null" ]; then
            while read -r j ; do
                TRIGGER_KEY=$(echo "${KEY}" | jq -r .trigger["$j"])

                TRIGGER_COMMAND=$(echo "${TRIGGER_KEY}" | jq -r '.command')
                if [ "${TRIGGER_COMMAND}" == "null" ]; then
                    continue
                fi

                make_cmd "${TRIGGER_KEY}" >> "${SCRIPT_TMP}"
            done < <(echo "${KEY}" | jq -r '.trigger | keys[]')
        fi

        echo "echo \"\$(date '+%Y-%m-%d %H:%M:%S') [end] ${SCRIPT_NAME}\"" >> "${SCRIPT_TMP}"

        mv "${SCRIPT_TMP}" "${SCRIPT_PATH}"
        trap - EXIT
        chmod +x "${SCRIPT_PATH}"

        if [ "${COMMENT}" != "null" ]; then
            echo "# ${COMMENT}" >> "${CRONTAB_FILE}"
        fi
        # Redirect job output to container's stdout/stderr via PID 1's file descriptors
        # This ensures output appears in docker logs (BusyBox crond swallows pipe output)
        echo "${SCHEDULE} ${SCRIPT_PATH} > /proc/1/fd/1 2>/proc/1/fd/2" >> "${CRONTAB_FILE}"

        JOB_NAMES+=("${SCRIPT_NAME}")
        JOB_SCHEDULES+=("${SCHEDULE}")

        ONSTART_COMMAND=$(echo "${KEY}" | jq -r '.onstart')
        if [ "${ONSTART_COMMAND}" == "true" ]; then
            ONSTART+=("${SCRIPT_PATH}")
            JOB_ONSTART_FLAGS+=("yes")
        else
            JOB_ONSTART_FLAGS+=("")
        fi
    done < <(jq -r '. | keys[]' "${CONFIG}")

    # Ensure crontab file exists even if no valid jobs were found
    touch "${CRONTAB_FILE}"

    # Print job summary table
    local job_count=${#JOB_NAMES[@]}
    printf "\n"
    printf "┌─────────────────┬─────────────────────────────────────┬─────────┐\n"
    printf "│ %-15s │ %-35s │ %-7s │\n" "Schedule" "Job" "Onstart"
    printf "├─────────────────┼─────────────────────────────────────┼─────────┤\n"
    for (( idx=0; idx<job_count; idx++ )); do
        local name="${JOB_NAMES[$idx]}"
        # Truncate long names
        if [ ${#name} -gt 35 ]; then
            name="${name:0:32}..."
        fi
        printf "│ %-15s │ %-35s │ %-7s │\n" "${JOB_SCHEDULES[$idx]}" "${name}" "${JOB_ONSTART_FLAGS[$idx]}"
    done
    printf "└─────────────────┴─────────────────────────────────────┴─────────┘\n"
    printf "  %d job(s) scheduled\n\n" "${job_count}"

    # Copy crontab file to a directory owned by docker user
    # BusyBox crond expects files in the crontabs directory to be named after the user
    CRONTABS_DIR="${HOME_DIR}/crontabs"
    mkdir -p "${CRONTABS_DIR}"
    cp "${CRONTAB_FILE}" "${CRONTABS_DIR}/docker"
    rm -f "${CRONTAB_FILE}"
    chmod 700 "${CRONTABS_DIR}"
    chmod 600 "${CRONTABS_DIR}/docker"
    # Ensure ownership is correct
    if [ "$(id -u)" = "0" ]; then
        chown docker:docker "${CRONTABS_DIR}" "${CRONTABS_DIR}/docker"
    fi

    if [ ${#ONSTART[@]} -gt 0 ]; then
        printf "Running %d onstart job(s)...\n" "${#ONSTART[@]}"
    fi
    ONSTART_PIDS=()
    for ONSTART_COMMAND in "${ONSTART[@]}"; do
        printf "  → %s\n" "$(basename "${ONSTART_COMMAND}" .sh)"
        "${ONSTART_COMMAND}" > /proc/1/fd/1 2>/proc/1/fd/2 &
        ONSTART_PIDS+=($!)
    done
    for pid in "${ONSTART_PIDS[@]}"; do
        if ! wait "$pid"; then
            echo "Warning: onstart job (PID $pid) exited with non-zero status" >&2
        fi
    done

    printf "Cron daemon starting...\n"
}

init_webapp() {
    printf "##### initializing web app #####\n"

    # Initialize database schema
    python3 /opt/crontab/webapp/init_db.py

    # Sync jobs from config to database
    python3 /opt/crontab/webapp/sync_jobs.py "${CONFIG}"

    printf "##### web app initialized #####\n"
}

start_app() {
    normalize_config
    export CONFIG=${HOME_DIR}/config.working.json
    if [ ! -f "${CONFIG}" ]; then
        printf "missing generated %s. exiting.\n" "${CONFIG}"
        exit 1
    fi
    if [ "${1}" == "crond" ]; then
        build_crontab
        init_webapp
    fi

    # Use supervisord to manage crond and Flask if we're starting crond
    if [ "${1}" == "crond" ]; then
        if [ "$(id -u)" = "0" ]; then
            exec su-exec docker supervisord -c /opt/crontab/supervisord.conf
        else
            exec supervisord -c /opt/crontab/supervisord.conf
        fi
    fi

    # Filter out invalid crond flags
    # BusyBox crond doesn't support -s flag
    local filtered_args=()

    for arg in "$@"; do
        # Skip -s flag if it appears (was used in previous versions but not supported by BusyBox)
        if [ "$arg" = "-s" ]; then
            echo "Warning: Skipping unsupported -s flag for BusyBox crond"
            continue
        fi

        filtered_args+=("$arg")
    done

    printf "%s\n" "${filtered_args[@]}"

    # Run as docker user for security
    if [ "$(id -u)" = "0" ]; then
        exec su-exec docker "${filtered_args[@]}"
    else
        exec "${filtered_args[@]}"
    fi
}

printf "✨ starting crontab container ✨\n"
start_app "${@}"
