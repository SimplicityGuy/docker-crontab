# crontab

![crontab](https://github.com/SimplicityGuy/docker-crontab/actions/workflows/build.yml/badge.svg) ![License: MIT](https://img.shields.io/github/license/SimplicityGuy/docker-crontab) [![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit)](https://github.com/pre-commit/pre-commit)

A simple wrapper over `docker` to all complex cron job to be run in other containers.

## Why?

Yes, I'm aware of [mcuadros/ofelia](https://github.com/mcuadros/ofelia) (>250MB when this was created), it was the main inspiration for this project.
A great project, don't get me wrong. It was just missing certain key enterprise features I felt were required to support where docker is heading.

## Features

- Easy to read schedule syntax allowed.
- Allows for comments, cause we all need friendly reminders of what `update_script.sh` actually does.
- Start an image using `image`.
- Run command in a container using `container`.
- Ability to trigger scripts in other containers on completion cron job using `trigger`.
- Ability to share settings between cron jobs using `~~shared-settings` as a key.

## Config file

The config file can be specified in any of `json`, `toml`, or `yaml`, and can be defined as either an array or mapping (top-level keys will be ignored; can be useful for organizing commands)

- `name`: Human readable name that will be used as the job filename. Will be converted into a slug. Optional.
- `comment`: Comments to be included with crontab entry. Optional.
- `schedule`: Crontab schedule syntax as described in https://en.wikipedia.org/wiki/Cron. Examples: `@hourly`, `@every 1h30m`, `* * * * *`. Required.
- `command`: Command to be run on in crontab container or docker container/image. Required.
- `image`: Docker images name (ex `library/alpine:3.5`). Optional.
- `container`: Full container name. Ignored if `image` is included. Optional.
- `dockerargs`: Command line docker `run`/`exec` arguments for full control. Defaults to ` `.
- `trigger`: Array of docker-crontab subset objects. Sub-set includes: `image`, `container`, `command`, `dockerargs`
- `onstart`: Run the command on `crontab` container start, set to `true`. Optional, defaults to false.

See [`config-samples`](config-samples) for examples.

```json
{
    "logrotate": {
        "schedule":"@every 5m",
        "command":"/usr/sbin/logrotate /etc/logrotate.conf"
    },
    "cert-regen": {
        "comment":"Regenerate Certificate then reload nginx",
        "schedule":"43 6,18 * * *",
        "command":"sh -c 'dehydrated --cron --out /etc/ssl --domain ${LE_DOMAIN} --challenge dns-01 --hook dehydrated-dns'",
        "dockerargs":"--it --env-file /opt/crontab/env/letsencrypt.env",
        "volumes":["webapp_nginx_tls_cert:/etc/ssl", "webapp_nginx_acme_challenge:/var/www/.well-known/acme-challenge"],
        "image":"willfarrell/letsencrypt",
        "trigger":[{
            "command":"sh -c '/etc/scripts/make_hpkp ${NGINX_DOMAIN} && /usr/sbin/nginx -t && /usr/sbin/nginx -s reload'",
            "container":"nginx"
        }],
        "onstart":true
    }
}
```

## Architecture & Security

### Security Model

The container is designed with security best practices:

- **Non-root execution**: Container runs as the `docker` user (not root) for security
- **Privilege separation**: Starts as root to set up directories, then drops to `docker` user via `su-exec`
- **Read-only Docker socket**: Docker socket is mounted read-only to prevent container escape
- **User-writable directories**: Crontab and job files stored in `/opt/crontab/` owned by `docker` user
- **SUID crontab**: The `crontab` command has SUID bit set for proper crontab file management

### Directory Structure

- `/opt/crontab/` - Main working directory (can be volume mounted)
  - `config.json` (or `.yaml`, `.toml`) - Your configuration file
  - `config.working.json` - Normalized configuration (auto-generated)
  - `jobs/` - Generated shell scripts for each cron job
  - `crontabs/` - Crontab files for BusyBox crond
    - `docker` - Crontab file for the `docker` user

## How to use

### Docker Group ID Configuration

This container needs to access the Docker socket to manage other containers. To do this, the `docker` user inside the container must have the same group ID (GID) as the `docker` group on the host system.

By default, the Dockerfile uses GID 999, which is common for the `docker` group on many systems. If your host system uses a different GID, you need to specify it during the build:

```bash
# Find your host's docker group ID
getent group docker | cut -d: -f3
# Or alternatively
stat -c '%g' /var/run/docker.sock

# Then build with the correct GID
docker build --build-arg DOCKER_GID=<your_docker_gid> -t crontab .
```

If you encounter the error `failed switching to "docker": operation not permitted`, it means the GIDs don't match. Rebuild the image with the correct GID.

### Command Line

```bash
docker build -t crontab .
docker run -d \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -v ./env:/opt/env:ro \
    -v /path/to/config/dir:/opt/crontab:rw \
    -v /path/to/logs:/var/log/crontab:rw \
    crontab
```

### Use with docker-compose

1. Figure out which network name used for your docker-compose containers
   - use `docker network ls` to see existing networks
   - if your `docker-compose.yml` is in `my_dir` directory, you probably has network `my_dir_default`
   - otherwise [read the docker-compose docs](https://docs.docker.com/compose/networking/)
1. Add `dockerargs` to your docker-crontab `config.json`
   - use `--network NETWORK_NAME` to connect new container into docker-compose network
   - use `--name NAME` to use named container
   - e.g. `"dockerargs": "--it"`

### Dockerfile

```Dockerfile
FROM registry.gitlab.com/simplicityguy/docker/crontab

COPY config.json ${HOME_DIR}/
```

### Logrotate Dockerfile

This example shows how to extend the crontab image for custom use cases:

```Dockerfile
FROM ghcr.io/simplicityguy/crontab

RUN apk add --no-cache logrotate
COPY logrotate.conf /etc/logrotate.conf
# Use the config.json approach instead of manually editing crontab files
COPY config.json ${HOME_DIR}/
```

## Troubleshooting

### Permission Errors

**Issue**: `failed switching to 'docker': operation not permitted`

**Cause**: Docker group GID mismatch between host and container.

**Solution**: Rebuild the image with the correct Docker group ID:

```bash
# Find your host's docker group ID
stat -c '%g' /var/run/docker.sock

# Rebuild with the correct GID
docker build --build-arg DOCKER_GID=$(stat -c '%g' /var/run/docker.sock) -t crontab .
```

### Jobs Not Executing

**Issue**: Cron jobs defined in config but not running.

**Troubleshooting steps**:

1. Check if crontab file was generated:

   ```bash
   docker exec <container> cat /opt/crontab/crontabs/docker
   ```

1. Verify job scripts exist:

   ```bash
   docker exec <container> ls -la /opt/crontab/jobs/
   ```

1. Check crond is running:

   ```bash
   docker exec <container> ps aux | grep crond
   ```

1. View container logs for cron execution output:

   ```bash
   docker logs <container>
   ```

### Directory Permission Issues

**Issue**: Container can't create directories when using volume mounts.

**Solution**: Ensure the host directory has correct permissions before mounting:

```bash
# Create directory and set ownership
mkdir -p /path/to/crontab
chown -R $(id -u):$(id -g) /path/to/crontab

# Then run container with volume mount
docker run -v /path/to/crontab:/opt/crontab:rw ...
```

Alternatively, let the container create the directories on first run (it starts as root, creates directories, then drops to `docker` user).
