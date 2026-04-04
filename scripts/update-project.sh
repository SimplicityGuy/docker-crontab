#!/usr/bin/env bash
#
# update-project.sh - Comprehensive project dependency and version updater
#
# This script provides a safe and comprehensive way to update:
# - Docker base images in Dockerfile (Alpine, Docker dind)
# - rq binary version
# - GitHub Actions versions in all workflow files
# - Pre-commit hooks to latest versions (with frozen revs)
#
# Usage: ./scripts/update-project.sh [options]
#
# Options:
#   --no-backup     Skip creating backup files
#   --dry-run       Show what would be updated without making changes
#   --skip-tests    Skip running docker build test after updates
#   --help          Show this help message

set -euo pipefail

# Script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Default options
BACKUP=true
DRY_RUN=false
SKIP_TESTS=false
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CHANGES_MADE=false

# Emojis for visual logging
EMOJI_INFO="ℹ️"
EMOJI_SUCCESS="✅"
EMOJI_WARNING="⚠️"
EMOJI_ERROR="❌"
EMOJI_DOCKER="🐳"
EMOJI_TEST="🧪"
EMOJI_BACKUP="💾"
EMOJI_CHANGES="📝"

# Print colored output with emojis
print_info() {
  echo -e "\033[0;34m$EMOJI_INFO  [INFO]\033[0m $1"
}

print_success() {
  echo -e "\033[0;32m$EMOJI_SUCCESS  [SUCCESS]\033[0m $1"
}

print_warning() {
  echo -e "\033[1;33m$EMOJI_WARNING  [WARNING]\033[0m $1"
}

print_error() {
  echo -e "\033[0;31m$EMOJI_ERROR  [ERROR]\033[0m $1" >&2
}

print_section() {
  echo ""
  echo -e "\033[1;36m$1  $2\033[0m"
  echo -e "\033[1;36m$(printf '=%.0s' {1..60})\033[0m"
}

# Show usage
show_help() {
  head -n 18 "$0" | grep '^#' | sed 's/^# //' | sed 's/^#//'
  exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --no-backup)
      BACKUP=false
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --skip-tests)
      SKIP_TESTS=true
      shift
      ;;
    --help|-h)
      show_help
      ;;
    *)
      print_error "Unknown option: $1"
      show_help
      ;;
  esac
done

# Check if we're in the project root
if [[ ! -f "$PROJECT_ROOT/Dockerfile" ]] || [[ ! -f "$PROJECT_ROOT/entrypoint.sh" ]]; then
  print_error "This script must be run from the docker-crontab project root directory"
  exit 1
fi

# Check for required tools
check_requirements() {
  local missing=()

  for cmd in curl jq sed grep; do
    if ! command -v "$cmd" &> /dev/null; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    print_error "Missing required tools: ${missing[*]}"
    print_error "Please install missing tools and try again"
    exit 1
  fi
}

# Check for uncommitted changes (warn but continue)
check_git_status() {
  if [[ -n $(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null) ]]; then
    print_warning "You have uncommitted changes. Consider committing or stashing them for safe rollback."
  fi
}

# Create backup directory
BACKUP_DIR="$PROJECT_ROOT/backups/project-updates-${TIMESTAMP}"

# Backup function
backup_file() {
  local file="$1"
  if [[ "$BACKUP" == true ]] && [[ -f "$file" ]] && [[ "$DRY_RUN" == false ]]; then
    mkdir -p "$BACKUP_DIR"
    local backup_path="$BACKUP_DIR"
    cp "$file" "$backup_path/$(basename "$file").backup"
    print_info "$EMOJI_BACKUP Created backup: $(basename "$file")"
  fi
}

# Update file function with portable sed
update_in_file() {
  local file="$1"
  local old_pattern="$2"
  local new_value="$3"
  local description="$4"

  if [[ "$DRY_RUN" == true ]]; then
    print_info "[DRY RUN] Would update $description in $(basename "$file")"
    return 0
  fi

  if grep -q "$old_pattern" "$file"; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' "s|$old_pattern|$new_value|g" "$file"
    else
      sed -i "s|$old_pattern|$new_value|g" "$file"
    fi
    print_success "Updated $description in $(basename "$file")"
    CHANGES_MADE=true
    return 0
  else
    print_warning "Pattern not found for $description in $(basename "$file")"
    return 1
  fi
}

# Update summary tracking
declare -a UPDATE_SUMMARY=()

add_to_summary() {
  UPDATE_SUMMARY+=("$1")
}

# ─── Docker base images ─────────────────────────────────────────────────────

# Get latest Docker image tag
get_latest_docker_tag() {
  local image="$1"
  local repo="${image%%:*}"

  if [[ "$repo" == "alpine" ]]; then
    curl -s "https://hub.docker.com/v2/repositories/library/alpine/tags?page_size=100" | \
      jq -r '.results[].name' | \
      grep -E '^[0-9]+\.[0-9]+$' | \
      sort -V | \
      tail -1
  elif [[ "$repo" == "docker" ]]; then
    curl -s "https://hub.docker.com/v2/repositories/library/docker/tags?page_size=100&name=dind-alpine" | \
      jq -r '.results[].name' | \
      grep -E '^[0-9]+\.[0-9]+\.[0-9]+-dind-alpine[0-9.]+$' | \
      sort -V | \
      tail -1
  else
    print_warning "Unknown image repository: $repo"
    return 1
  fi
}

update_dockerfile() {
  print_section "$EMOJI_DOCKER" "Updating Dockerfile Dependencies"

  local dockerfile="$PROJECT_ROOT/Dockerfile"
  backup_file "$dockerfile"

  # Update Alpine base image
  local current_alpine
  current_alpine=$(grep 'FROM alpine:' "$dockerfile" | head -1 | sed -E 's/.*FROM alpine:([^ ]+).*/\1/')
  local latest_alpine
  latest_alpine=$(get_latest_docker_tag "alpine")

  if [[ -n "$latest_alpine" ]] && [[ "$current_alpine" != "$latest_alpine" ]]; then
    print_info "Alpine: $current_alpine → $latest_alpine"
    update_in_file "$dockerfile" "FROM alpine:${current_alpine}" "FROM alpine:${latest_alpine}" "Alpine base image"
    add_to_summary "Alpine: $current_alpine → $latest_alpine"
  else
    print_success "Alpine is up to date: $current_alpine"
  fi

  # Update Docker dind image
  local current_docker
  current_docker=$(grep 'FROM docker:' "$dockerfile" | head -1 | sed -E 's/.*FROM docker:([^ ]+).*/\1/')
  local latest_docker
  latest_docker=$(get_latest_docker_tag "docker")

  if [[ -n "$latest_docker" ]] && [[ "$current_docker" != "$latest_docker" ]]; then
    print_info "Docker: $current_docker → $latest_docker"
    update_in_file "$dockerfile" "FROM docker:${current_docker}" "FROM docker:${latest_docker}" "Docker dind image"
    add_to_summary "Docker dind: $current_docker → $latest_docker"
  else
    print_success "Docker is up to date: $current_docker"
  fi

  # Update RQ version
  local current_rq
  current_rq=$(grep 'ENV RQ_VERSION=' "$dockerfile" | sed -E 's/.*ENV RQ_VERSION=([^ ]+).*/\1/')
  local latest_rq
  latest_rq=$(get_latest_rq_version)

  if [[ -n "$latest_rq" ]] && [[ "$current_rq" != "$latest_rq" ]]; then
    print_info "rq: $current_rq → $latest_rq"
    update_in_file "$dockerfile" "ENV RQ_VERSION=${current_rq}" "ENV RQ_VERSION=${latest_rq}" "rq version"
    add_to_summary "rq: $current_rq → $latest_rq"
  else
    print_success "rq is up to date: $current_rq"
  fi
}

# ─── rq binary ───────────────────────────────────────────────────────────────

get_latest_rq_version() {
  curl -s "https://api.github.com/repos/dflemstr/rq/releases/latest" | \
    jq -r '.tag_name' | \
    sed 's/^v//'
}

# ─── GitHub Actions ──────────────────────────────────────────────────────────

get_latest_action_version() {
  local repo="$1"
  local latest_tag
  latest_tag=$(curl -s "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name')
  echo "$latest_tag" | sed -E 's/^(v[0-9]+).*/\1/'
}

update_github_actions() {
  print_section "🔧" "Updating GitHub Actions"

  # Update actions across ALL workflow files
  local actions=(
    "actions/checkout"
    "docker/login-action"
    "docker/metadata-action"
    "docker/setup-qemu-action"
    "docker/setup-buildx-action"
    "docker/build-push-action"
  )

  for workflow_file in "$PROJECT_ROOT"/.github/workflows/*.yml "$PROJECT_ROOT"/.github/workflows/*.yaml; do
    [[ -f "$workflow_file" ]] || continue

    local workflow_name
    workflow_name=$(basename "$workflow_file")
    local file_backed_up=false

    for repo in "${actions[@]}"; do
      local escaped_repo="${repo//\//\\/}"
      local current_version
      current_version=$(grep -E "uses: ${repo}@v[0-9]+" "$workflow_file" 2>/dev/null | head -1 | sed -E "s/.*${escaped_repo}@(v[0-9]+).*/\1/" || echo "")

      if [[ -z "$current_version" ]]; then
        continue
      fi

      local latest_version
      latest_version=$(get_latest_action_version "$repo")

      if [[ -n "$latest_version" ]] && [[ "$current_version" != "$latest_version" ]]; then
        if [[ "$file_backed_up" == false ]]; then
          backup_file "$workflow_file"
          file_backed_up=true
        fi
        print_info "$repo in $workflow_name: $current_version → $latest_version"
        update_in_file "$workflow_file" "uses: ${repo}@${current_version}" "uses: ${repo}@${latest_version}" "$repo action"
        add_to_summary "$repo ($workflow_name): $current_version → $latest_version"
      else
        print_success "$repo in $workflow_name is up to date: $current_version"
      fi
    done
  done
}

# ─── Pre-commit hooks ────────────────────────────────────────────────────────

update_precommit_hooks() {
  print_section "🪝" "Updating Pre-commit Hooks"

  if ! command -v pre-commit >/dev/null 2>&1; then
    print_warning "pre-commit not installed, skipping hook updates"
    print_info "Install with: pip install pre-commit"
    return
  fi

  local config_file="$PROJECT_ROOT/.pre-commit-config.yaml"
  if [[ ! -f "$config_file" ]]; then
    print_warning "No .pre-commit-config.yaml found, skipping"
    return
  fi

  if [[ "$DRY_RUN" == true ]]; then
    print_info "[DRY RUN] Would run: pre-commit autoupdate --freeze"
    return
  fi

  backup_file "$config_file"

  print_info "Updating pre-commit hooks to latest versions (with frozen revs)..."

  if (cd "$PROJECT_ROOT" && pre-commit autoupdate --freeze); then
    print_success "Pre-commit hooks updated successfully"
    add_to_summary "Pre-commit hooks: updated to latest versions (frozen)"
    CHANGES_MADE=true
  else
    print_warning "Failed to update pre-commit hooks"
  fi
}

# ─── Verification ────────────────────────────────────────────────────────────

run_verification() {
  if [[ "$SKIP_TESTS" == true ]]; then
    print_info "Skipping tests (--skip-tests)"
    return
  fi

  print_section "$EMOJI_TEST" "Running Verification"

  if [[ "$DRY_RUN" == true ]]; then
    print_info "[DRY RUN] Would run: docker build -t crontab:test ."
    return
  fi

  print_info "Running docker build to verify changes..."
  if (cd "$PROJECT_ROOT" && docker build -t crontab:test .); then
    print_success "Docker build succeeded"

    # Clean up test image
    docker rmi crontab:test >/dev/null 2>&1 || true
  else
    print_error "Docker build failed! Review changes before committing."
    print_info "Backup files are available in: $BACKUP_DIR/"
    return 1
  fi
}

# ─── Summary ─────────────────────────────────────────────────────────────────

print_summary() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "$EMOJI_CHANGES  Update Summary"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if [[ ${#UPDATE_SUMMARY[@]} -eq 0 ]]; then
    print_success "All dependencies are already up to date!"
  else
    echo ""
    echo "The following updates were made:"
    echo ""
    for update in "${UPDATE_SUMMARY[@]}"; do
      echo "  • $update"
    done
    echo ""

    if [[ "$DRY_RUN" == false ]]; then
      if [[ "$BACKUP" == true ]] && [[ -d "$BACKUP_DIR" ]]; then
        print_info "Backups saved in: $BACKUP_DIR/"
        echo ""
      fi

      print_info "Next steps:"
      echo "  1. Review the changes: git diff"
      echo "  2. Stage the changes: git add -p"
      echo "  3. Commit: git commit -m 'chore(deps): update project dependencies'"
    fi
  fi

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  print_section "🚀" "docker-crontab Project Update"

  check_requirements
  check_git_status

  cd "$PROJECT_ROOT"

  if [[ "$DRY_RUN" == true ]]; then
    print_warning "Running in DRY RUN mode — no changes will be made"
  fi

  # Run all updates
  update_dockerfile
  update_github_actions
  update_precommit_hooks
  run_verification

  # Print summary
  print_summary
}

# Run main function
main
