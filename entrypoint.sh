#!/bin/bash

set -e

CRONTAB_FILE="${HOME_DIR}"/crontab

if [ -z "${HOME_DIR}" ] && [ -n "${TEST_MODE}" ]; then
    HOME_DIR=/tmp/crontab-docker-testing
    CRONTAB_FILE=${HOME_DIR}/test
elif [ -z "${HOME_DIR}" ]; then
    echo "HOME_DIR not set."
    exit 1
fi

# Ensure dir exist - in case of volume mapping.
# This needs to run as root to set proper permissions
if [ "$(id -u)" = "0" ]; then
    mkdir -p "${HOME_DIR}"/jobs
    chown -R docker:docker "${HOME_DIR}"
else
    # If not root, try to create directory (may fail if permissions are wrong)
    mkdir -p "${HOME_DIR}"/jobs 2>/dev/null || {
        echo "Warning: Cannot create ${HOME_DIR}/jobs directory. Ensure proper volume permissions."
        echo "Run: sudo chown -R $(id -u docker):$(id -g docker) /path/to/host/directory"
    }
fi

if [ -z "${DOCKER_HOST}" ] && [ -a "${DOCKER_PORT_2375_TCP}" ]; then
    export DOCKER_HOST="tcp://docker:2375"
fi

normalize_config() {
    JSON_CONFIG={}
    if [ -f "${HOME_DIR}/config.json" ]; then
        JSON_CONFIG="$(cat "${HOME_DIR}"/config.json)"
    elif [ -f "${HOME_DIR}/config.toml" ]; then
        JSON_CONFIG="$(rq -t <<< "$(cat "${HOME_DIR}"/config.toml)")"
    elif [ -f "${HOME_DIR}/config.yml" ]; then
        JSON_CONFIG="$(rq -y <<< "$(cat "${HOME_DIR}"/config.yml)")"
    elif [ -f "${HOME_DIR}/config.yaml" ]; then
        JSON_CONFIG="$(rq -y <<< "$(cat "${HOME_DIR}"/config.yaml)")"
    fi

    jq -S -r '."~~shared-settings" as $shared | del(."~~shared-settings") | to_entries | map_values(.value + { name: .key } + $shared)' <<< "${JSON_CONFIG}" > "${HOME_DIR}"/config.working.json
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
    DOCKERARGS+=" "
    if [ -n "${ENVIRONMENT}" ]; then DOCKERARGS+="${ENVIRONMENT} "; fi
    if [ -n "${EXPOSE}" ]; then DOCKERARGS+="${EXPOSE} "; fi
    if [ -n "${NAME}" ]; then DOCKERARGS+="--name ${NAME} "; fi
    if [ -n "${NETWORKS}" ]; then DOCKERARGS+="${NETWORKS} "; fi
    if [ -n "${PORTS}" ]; then DOCKERARGS+="${PORTS} "; fi
    if [ -n "${VOLUMES}" ]; then DOCKERARGS+="${VOLUMES} "; fi

    IMAGE=$(echo "${1}" | jq -r .image | envsubst)
    if [ "${IMAGE}" == "null" ]; then return; fi

    COMMAND=$(echo "${1}" | jq -r .command)

    echo "docker run ${DOCKERARGS} ${IMAGE} ${COMMAND}"
}

make_container_cmd() {
    DOCKERARGS=$(echo "${1}" | jq -r .dockerargs)
    if [ "${DOCKERARGS}" == "null" ]; then DOCKERARGS=; fi

    CONTAINER=$(echo "${1}" | jq -r .container | envsubst)
    if [ "${CONTAINER}" == "null" ]; then return; fi

    COMMAND=$(echo "${1}" | jq -r .command )
    if [ "${COMMAND}" == "null" ]; then return; fi

    echo "docker exec ${DOCKERARGS} ${CONTAINER} ${COMMAND}"
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
    IFS=" "
    read -r -a params <<< "$@"

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
        *)
            echo "${params[@]}"
            ;;
    esac
}

function build_crontab() {
    rm -rf "${CRONTAB_FILE}"

    ONSTART=()
    while read -r i ; do
        KEY=$(jq -r .["$i"] "${CONFIG}")

        SCHEDULE=$(echo "${KEY}" | jq -r '.schedule' | sed 's/\*/\\*/g')
        if [ "${SCHEDULE}" == "null" ]; then
            echo "'schedule' missing: '${KEY}"
            continue
        fi
        SCHEDULE=$(parse_schedule "${SCHEDULE}" | sed 's/\\//g')

        COMMAND=$(echo "${KEY}" | jq -r '.command')
        if [ "${COMMAND}" == "null" ]; then
            echo "'command' missing: '${KEY}'"
            continue
        fi

        COMMENT=$(echo "${KEY}" | jq -r '.comment')

        SCRIPT_NAME=$(echo "${KEY}" | jq -r '.name')
        SCRIPT_NAME=$(slugify "${SCRIPT_NAME}")
        if [ "${SCRIPT_NAME}" == "null" ]; then
            SCRIPT_NAME=$(cat /proc/sys/kernel/random/uuid)
        fi

        CRON_COMMAND=$(make_cmd "${KEY}")

        SCRIPT_PATH="${HOME_DIR}/jobs/${SCRIPT_NAME}.sh"

        touch "${SCRIPT_PATH}"
        chmod +x "${SCRIPT_PATH}"

        {
            echo "#\!/usr/bin/env bash"
            echo "set -e"
            echo ""
            echo "echo \"start cron job __${SCRIPT_NAME}__\""
            echo "${CRON_COMMAND}"
        }  > "${SCRIPT_PATH}"

        TRIGGER=$(echo "${KEY}" | jq -r '.trigger')
        if [ "${TRIGGER}" != "null" ]; then
            while read -r j ; do
                TRIGGER_KEY=$(echo "${KEY}" | jq -r .trigger["$j"])

                TRIGGER_COMMAND=$(echo "${TRIGGER_KEY}" | jq -r '.command')
                if [ "${TRIGGER_COMMAND}" == "null" ]; then
                    continue
                fi

                make_cmd "${TRIGGER_KEY}" >> "${SCRIPT_PATH}"
            done < <(echo "${KEY}" | jq -r '.trigger | keys[]')
        fi

        echo "echo \"end cron job __${SCRIPT_NAME}__\"" >> "${SCRIPT_PATH}"

        if [ "${COMMENT}" != "null" ]; then
            echo "# ${COMMENT}" >> "${CRONTAB_FILE}"
        fi
        echo "${SCHEDULE} ${SCRIPT_PATH}" >> "${CRONTAB_FILE}"

        ONSTART_COMMAND=$(echo "${KEY}" | jq -r '.onstart')
        if [ "${ONSTART_COMMAND}" == "true" ]; then
            ONSTART+=("${SCRIPT_PATH}")
        fi
    done < <(jq -r '. | keys[]' "${CONFIG}")

    printf "##### crontab generated #####\n"
    cat "${CRONTAB_FILE}"

    printf "##### run commands with onstart #####\n"
    for ONSTART_COMMAND in "${ONSTART[@]}"; do
        printf "%s\n" "${ONSTART_COMMAND}"
        ${ONSTART_COMMAND} &
    done

    printf "##### cron running #####\n"
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
    fi

    # Filter out invalid crond flags
    # BusyBox crond doesn't support -s flag
    local filtered_args=()
    local skip_next=false

    for arg in "$@"; do
        if [ "$skip_next" = true ]; then
            skip_next=false
            continue
        fi

        # Skip -s flag if it appears (was used in previous versions but not supported by BusyBox)
        if [ "$arg" = "-s" ]; then
            echo "Warning: Skipping unsupported -s flag for BusyBox crond"
            continue
        fi

        filtered_args+=("$arg")
    done

    printf "%s\n" "${filtered_args[@]}"

    # Run crond as root so it can switch users for cron jobs
    # Other commands run as docker user for security
    if [ "${1}" == "crond" ]; then
        exec "${filtered_args[@]}"
    elif [ "$(id -u)" = "0" ]; then
        exec su-exec docker "${filtered_args[@]}"
    else
        exec "${filtered_args[@]}"
    fi
}

printf "✨ starting crontab container ✨\n"
start_app "${@}"
