#!/usr/bin/env bash
# Maintainer: Amirreza Sedighi A.K.A 0XV

set -Eeuo pipefail

BASE_URL="${DOFFLINE_BASE_URL:-https://download.docker.com/linux}"
HTTP_USER_AGENT="${DOFFLINE_USER_AGENT:-Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/126.0 Safari/537.36}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STANDARD_PACKAGES=(
  "containerd.io"
  "docker-ce"
  "docker-ce-cli"
  "docker-buildx-plugin"
  "docker-compose-plugin"
)
STATIC_PACKAGES=(
  "docker"
  "docker-rootless-extras"
)

declare -a PACKAGE_NAMES=()
declare -a PACKAGE_FILES=()
declare -a PACKAGE_VERSIONS=()
declare -a PACKAGE_DATES=()
declare -a PACKAGE_INSTALLED_VERSIONS=()
declare -a PACKAGE_INSTALLED_STATES=()
declare -a SELECTED_INDEXES=()
declare -A LATEST_FILE=()
declare -A LATEST_VERSION=()
declare -A LATEST_DATE=()
SELECTED_RELEASE=""
SELECTED_CHANNEL=""
SELECTED_ARCHITECTURE=""
PACKAGE_URL=""
INSTALL_FAILURES=0

RED=""
GREEN=""
YELLOW=""
CYAN=""
BOLD=""
RESET=""

if [[ -t 1 ]]; then
  RED=$'\033[31m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  CYAN=$'\033[36m'
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
fi

die() {
  printf '%sError: %s%s\n' "$RED" "$*" "$RESET" >&2
  exit 1
}

info() {
  printf '%s%s%s\n' "$CYAN" "$*" "$RESET"
}

success() {
  printf '%s%s%s\n' "$GREEN" "$*" "$RESET"
}

warning() {
  printf '%sWarning: %s%s\n' "$YELLOW" "$*" "$RESET" >&2
}

usage() {
  cat <<'EOF'
Docker Offline Downloader

Usage:
  ./doffline.sh
  ./doffline.sh --help

Environment:
  DOFFLINE_BASE_URL   Override the Docker Linux repository URL.

Supported repository layouts:
  Debian-based (.deb)   ubuntu, debian, raspbian
  RPM-based (.rpm)      centos, fedora, rhel, rocky, alma, oracle, sles
  Static binaries       static

The script interactively selects:
  distribution -> release -> channel -> architecture -> packages
  (static omits the release step)

After downloading, it can:
  install the downloaded packages or static binaries
  enable and start Docker
  add the current user to the docker group
  verify Docker daemon and non-root access
EOF
}

cleanup() {
  if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}

trap cleanup EXIT
trap 'printf "\n"; die "Operation interrupted."' INT TERM

fetch_url() {
  local url=$1
  local output=${2:-}
  local destination=$output
  local temporary_output=""
  local curl_status=127
  local wget_status=127
  local -a curl_args=(
    --fail
    --location
    --silent
    --show-error
    --http1.1
    --user-agent "$HTTP_USER_AGENT"
    --header "Accept: text/html,application/xhtml+xml,application/octet-stream;q=0.9,*/*;q=0.8"
    --retry 3
    --retry-delay 2
    --connect-timeout 15
    --max-time 180
  )
  local -a wget_args=(
    --quiet
    --user-agent="$HTTP_USER_AGENT"
    --header="Accept: text/html,application/xhtml+xml,application/octet-stream;q=0.9,*/*;q=0.8"
    --tries=3
    --timeout=30
  )

  if [[ -z "$destination" ]]; then
    temporary_output=$(mktemp)
    destination=$temporary_output
  fi

  if command -v curl >/dev/null 2>&1; then
    if curl "${curl_args[@]}" --output "$destination" "$url"; then
      if [[ -n "$temporary_output" ]]; then
        cat "$temporary_output"
        rm -f -- "$temporary_output"
      fi
      return 0
    else
      curl_status=$?
    fi
    rm -f -- "$destination"
    warning "curl could not fetch $url (exit code $curl_status). Trying wget..."
  fi

  if command -v wget >/dev/null 2>&1; then
    if wget "${wget_args[@]}" --output-document="$destination" "$url"; then
      if [[ -n "$temporary_output" ]]; then
        cat "$temporary_output"
        rm -f -- "$temporary_output"
      fi
      return 0
    else
      wget_status=$?
    fi
    rm -f -- "$destination"
  fi

  [[ -n "$temporary_output" ]] && rm -f -- "$temporary_output"
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    die "curl or wget is required."
  fi

  warning "Both HTTP clients failed for $url (curl=$curl_status, wget=$wget_status). Check proxy/VPN rules, DNS, system time, or CDN access."
  return 1
}

download_url() {
  local url=$1
  local output=$2
  local curl_status=127
  local wget_status=127
  local -a curl_args=(
    --fail
    --location
    --show-error
    --http1.1
    --user-agent "$HTTP_USER_AGENT"
    --header "Accept: application/octet-stream,*/*;q=0.8"
    --retry 3
    --retry-delay 2
    --connect-timeout 15
    --continue-at -
  )
  local -a wget_args=(
    --continue
    --user-agent="$HTTP_USER_AGENT"
    --header="Accept: application/octet-stream,*/*;q=0.8"
    --tries=3
    --timeout=30
  )

  if command -v curl >/dev/null 2>&1; then
    if curl "${curl_args[@]}" --output "$output" "$url"; then
      return 0
    else
      curl_status=$?
    fi
    warning "curl download failed for $url (exit code $curl_status). Trying wget..."
  fi

  if command -v wget >/dev/null 2>&1; then
    if wget "${wget_args[@]}" --output-document="$output" "$url"; then
      return 0
    else
      wget_status=$?
    fi
  fi

  warning "Both HTTP clients failed for $url (curl=$curl_status, wget=$wget_status)."
  return 1
}

html_directories() {
  sed -nE 's/.*href="([^"]+\/)".*/\1/p' |
    sed -E 's#/$##' |
    grep -Ev '^(\.\.|\.|https?:|//|\?|$)' |
    sort -u
}

load_directories() {
  local url=$1
  local listing

  listing=$(fetch_url "${url%/}/") || return 1
  mapfile -t DIRECTORIES < <(printf '%s\n' "$listing" | html_directories)
  ((${#DIRECTORIES[@]} > 0))
}

choose_one() {
  local prompt=$1
  shift
  local -a choices=("$@")
  local answer
  local index

  CHOSEN_VALUE=""
  ((${#choices[@]} > 0)) || die "No options were found for: $prompt"

  printf '\n%s%s%s\n' "$BOLD" "$prompt" "$RESET"
  for index in "${!choices[@]}"; do
    printf '  %2d) %s\n' "$((index + 1))" "${choices[index]}"
  done

  while true; do
    read -r -p "Enter a number (q to quit): " answer
    if [[ "$answer" == "q" || "$answer" == "Q" ]]; then
      printf 'Exiting without changes.\n'
      exit 0
    fi
    if [[ "$answer" =~ ^[0-9]+$ ]] &&
      ((answer >= 1 && answer <= ${#choices[@]})); then
      CHOSEN_VALUE=${choices[answer - 1]}
      return 0
    fi
    warning "Invalid selection."
  done
}

confirm() {
  local prompt=$1
  local default=${2:-yes}
  local answer
  local suffix="[Y/n]"

  [[ "$default" == "no" ]] && suffix="[y/N]"
  while true; do
    read -r -p "$prompt $suffix: " answer
    answer=${answer:-$default}
    case "${answer,,}" in
      y | yes)
        return 0
        ;;
      n | no)
        return 1
        ;;
      *)
        warning "Please answer yes or no."
        ;;
    esac
  done
}

detect_repo_type() {
  local distro=$1

  if [[ "$distro" == "static" ]]; then
    REPO_TYPE=static
    PACKAGE_GLOB="*.tgz"
    return 0
  fi

  if fetch_url "${BASE_URL%/}/$distro/dists/" >/dev/null 2>&1; then
    REPO_TYPE=deb
    PACKAGE_GLOB="*.deb"
    return 0
  fi

  if fetch_url "${BASE_URL%/}/$distro/" >/dev/null 2>&1; then
    REPO_TYPE=rpm
    PACKAGE_GLOB="*.rpm"
    return 0
  fi

  die "Could not detect a supported repository layout for '$distro'."
}

get_native_architecture() {
  if command -v dpkg >/dev/null 2>&1; then
    dpkg --print-architecture
    return 0
  fi

  if command -v rpm >/dev/null 2>&1; then
    rpm --eval '%{_arch}' 2>/dev/null
    return 0
  fi

  case "$(uname -m)" in
    x86_64) printf '%s\n' x86_64 ;;
    aarch64 | arm64) printf '%s\n' aarch64 ;;
    armv7l | armv6l) printf '%s\n' armhf ;;
    ppc64le) printf '%s\n' ppc64le ;;
    s390x) printf '%s\n' s390x ;;
    *) uname -m ;;
  esac
}

version_is_newer() {
  local candidate=$1
  local current=$2

  if [[ "$REPO_TYPE" == "rpm" ]] && command -v rpm >/dev/null 2>&1; then
    rpm --compare-versions "$candidate" gt "$current"
  elif [[ "$REPO_TYPE" == "deb" ]] && command -v dpkg >/dev/null 2>&1; then
    dpkg --compare-versions "$candidate" gt "$current"
  else
    [[ "$(printf '%s\n%s\n' "$current" "$candidate" | sort -V | tail -n 1)" == "$candidate" &&
      "$candidate" != "$current" ]]
  fi
}

installed_version_is_current() {
  local installed_version=$1
  local repository_version=$2
  local installed_epoch=""
  local comparable_repository_version=$repository_version

  if [[ "$REPO_TYPE" == "deb" && "$installed_version" == *:* && "$repository_version" != *:* ]]; then
    installed_epoch=${installed_version%%:*}
    comparable_repository_version="${installed_epoch}:${repository_version}"
  fi

  if [[ "$REPO_TYPE" == "rpm" ]] && command -v rpm >/dev/null 2>&1; then
    rpm --compare-versions "$installed_version" ge "$repository_version"
  elif [[ "$REPO_TYPE" == "deb" ]] && command -v dpkg >/dev/null 2>&1; then
    dpkg --compare-versions "$installed_version" ge "$comparable_repository_version"
  else
    ! version_is_newer "$comparable_repository_version" "$installed_version"
  fi
}

get_installed_package_version() {
  local package=$1
  local package_status
  local installed_version

  if [[ "$REPO_TYPE" == "rpm" ]] && command -v rpm >/dev/null 2>&1; then
    installed_version=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$package" 2>/dev/null || true)
    [[ -n "$installed_version" && "$installed_version" != *"not installed"* ]] || return 1
    printf '%s\n' "$installed_version"
    return 0
  fi

  if [[ "$REPO_TYPE" == "static" ]]; then
    if [[ "$package" == "docker" ]] && command -v docker >/dev/null 2>&1; then
      installed_version=$(docker version --format '{{.Client.Version}}' 2>/dev/null || true)
      [[ -n "$installed_version" ]] || return 1
      printf '%s\n' "$installed_version"
      return 0
    fi
    return 1
  fi

  command -v dpkg-query >/dev/null 2>&1 || return 1
  package_status=$(dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null || true)
  [[ "$package_status" == "ii " ]] || return 1
  installed_version=$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null || true)
  [[ -n "$installed_version" ]] || return 1
  printf '%s\n' "$installed_version"
}

display_package_version() {
  local version=$1

  case "$REPO_TYPE" in
    deb)
      version=${version#*:}
      version=${version%%~*}
      ;;
    rpm)
      version=${version%%-*}
      ;;
    static)
      version=${version%-ce}
      ;;
  esac

  printf '%s\n' "$version"
}

record_latest_package() {
  local package=$1
  local filename=$2
  local version=$3
  local published=$4

  if [[ -z "${LATEST_VERSION[$package]+x}" ]] ||
    version_is_newer "$version" "${LATEST_VERSION[$package]}" ||
    [[ "$version" == "${LATEST_VERSION[$package]}" && "$published" > "${LATEST_DATE[$package]}" ]]; then
    LATEST_FILE["$package"]=$filename
    LATEST_VERSION["$package"]=$version
    LATEST_DATE["$package"]=$published
  fi
}

extract_published_date() {
  local line=$1
  local published

  published=$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}(:[0-9]{2})?' <<<"$line" | head -n 1 || true)
  published=${published%% *}
  [[ -n "$published" ]] || published="Unknown"
  printf '%s\n' "$published"
}

parse_latest_deb_packages() {
  local listing_file=$1
  local line
  local filename
  local package
  local version
  local published

  while IFS= read -r line; do
    filename=$(sed -nE 's/.*href="([^"]+\.deb)".*/\1/p' <<<"$line")
    [[ -n "$filename" ]] || continue
    filename=${filename//%7E/\~}
    filename=${filename//%7e/\~}
    package=${filename%%_*}
    [[ "$filename" == *_* ]] || continue
    version=${filename#*_}
    version=${version%_*}
    published=$(extract_published_date "$line")
    record_latest_package "$package" "$filename" "$version" "$published"
  done <"$listing_file"
}

parse_latest_rpm_packages() {
  local listing_file=$1
  local line
  local filename
  local package
  local version
  local published

  while IFS= read -r line; do
    filename=$(sed -nE 's/.*href="([^"]+\.rpm)".*/\1/p' <<<"$line")
    [[ -n "$filename" ]] || continue

    if [[ "$filename" =~ ^(.+)-([0-9][0-9A-Za-z._~]*-[0-9A-Za-z._~.+]+)\.(x86_64|aarch64|armhf|ppc64le|s390x|noarch)\.rpm$ ]]; then
      package=${BASH_REMATCH[1]}
      version=${BASH_REMATCH[2]}
    else
      continue
    fi

    published=$(extract_published_date "$line")
    record_latest_package "$package" "$filename" "$version" "$published"
  done <"$listing_file"
}

parse_latest_static_packages() {
  local listing_file=$1
  local line
  local filename
  local package
  local version
  local published

  while IFS= read -r line; do
    filename=$(sed -nE 's/.*href="([^"]+\.tgz)".*/\1/p' <<<"$line")
    [[ -n "$filename" ]] || continue

    if [[ "$filename" =~ ^docker-rootless-extras-(.+)\.tgz$ ]]; then
      package=docker-rootless-extras
      version=${BASH_REMATCH[1]}
    elif [[ "$filename" =~ ^docker-(.+)\.tgz$ ]]; then
      package=docker
      version=${BASH_REMATCH[1]}
    else
      continue
    fi

    published=$(extract_published_date "$line")
    record_latest_package "$package" "$filename" "$version" "$published"
  done <"$listing_file"
}

parse_latest_packages() {
  local listing_file=$1

  case "$REPO_TYPE" in
    deb) parse_latest_deb_packages "$listing_file" ;;
    rpm) parse_latest_rpm_packages "$listing_file" ;;
    static) parse_latest_static_packages "$listing_file" ;;
    *) die "Unsupported repository type: $REPO_TYPE" ;;
  esac
}

get_standard_packages() {
  local package

  case "$REPO_TYPE" in
    static)
      for package in "${STATIC_PACKAGES[@]}"; do
        printf '%s\n' "$package"
      done
      ;;
    *)
      for package in "${STANDARD_PACKAGES[@]}"; do
        printf '%s\n' "$package"
      done
      ;;
  esac
}

build_package_list() {
  local scope=$1
  local package
  local display_version
  local installed_version

  PACKAGE_NAMES=()
  PACKAGE_FILES=()
  PACKAGE_VERSIONS=()
  PACKAGE_DATES=()
  PACKAGE_INSTALLED_VERSIONS=()
  PACKAGE_INSTALLED_STATES=()

  if [[ "$scope" == "recommended" ]]; then
    while IFS= read -r package; do
      if [[ -n "${LATEST_FILE[$package]+x}" ]]; then
        PACKAGE_NAMES+=("$package")
        PACKAGE_FILES+=("${LATEST_FILE[$package]}")
        display_version=$(display_package_version "${LATEST_VERSION[$package]}")
        PACKAGE_VERSIONS+=("$display_version")
        PACKAGE_DATES+=("${LATEST_DATE[$package]}")
        if installed_version=$(get_installed_package_version "$package"); then
          PACKAGE_INSTALLED_VERSIONS+=("$(display_package_version "$installed_version")")
          if installed_version_is_current "$installed_version" "${LATEST_VERSION[$package]}"; then
            PACKAGE_INSTALLED_STATES+=("current")
          else
            PACKAGE_INSTALLED_STATES+=("outdated")
          fi
        else
          PACKAGE_INSTALLED_VERSIONS+=("Not installed")
          PACKAGE_INSTALLED_STATES+=("missing")
        fi
      else
        warning "Package $package was not found in this repository path."
      fi
    done < <(get_standard_packages)
  else
    while IFS= read -r package; do
      PACKAGE_NAMES+=("$package")
      PACKAGE_FILES+=("${LATEST_FILE[$package]}")
      display_version=$(display_package_version "${LATEST_VERSION[$package]}")
      PACKAGE_VERSIONS+=("$display_version")
      PACKAGE_DATES+=("${LATEST_DATE[$package]}")
      if installed_version=$(get_installed_package_version "$package"); then
        PACKAGE_INSTALLED_VERSIONS+=("$(display_package_version "$installed_version")")
        if installed_version_is_current "$installed_version" "${LATEST_VERSION[$package]}"; then
          PACKAGE_INSTALLED_STATES+=("current")
        else
          PACKAGE_INSTALLED_STATES+=("outdated")
        fi
      else
        PACKAGE_INSTALLED_VERSIONS+=("Not installed")
        PACKAGE_INSTALLED_STATES+=("missing")
      fi
    done < <(printf '%s\n' "${!LATEST_FILE[@]}" | sort)
  fi

  ((${#PACKAGE_NAMES[@]} > 0)) || die "No packages were found to display."
}

show_packages() {
  local index
  local installed_color

  printf '\n%sLatest available package versions%s\n' "$BOLD" "$RESET"
  printf '%-4s %-32s %-22s %-22s %-12s\n' "#" "Package" "Installed version" "Recommended version" "Date"
  printf '%-4s %-32s %-22s %-22s %-12s\n' "----" "--------------------------------" "----------------------" "----------------------" "------------"
  for index in "${!PACKAGE_NAMES[@]}"; do
    if [[ "${PACKAGE_INSTALLED_STATES[index]}" == "current" ]]; then
      installed_color=$GREEN
    else
      installed_color=$RED
    fi
    printf '%-4d %-32s %s%-22s%s %-22s %-12s\n' "$((index + 1))" "${PACKAGE_NAMES[index]}" "$installed_color" "${PACKAGE_INSTALLED_VERSIONS[index]}" "$RESET" "${PACKAGE_VERSIONS[index]}" "${PACKAGE_DATES[index]}"
  done
}

choose_packages() {
  local answer
  local token
  local index
  local -A seen=()

  printf '\nEnter package numbers separated by spaces.\n'
  printf '  a = all, q = quit; example: 1 3 5\n'

  while true; do
    SELECTED_INDEXES=()
    seen=()
    read -r -p "Selection: " answer
    [[ "$answer" == "q" || "$answer" == "Q" ]] && exit 0

    if [[ "$answer" == "a" || "$answer" == "A" ]]; then
      for index in "${!PACKAGE_NAMES[@]}"; do
        SELECTED_INDEXES+=("$index")
      done
      return 0
    fi

    for token in $answer; do
      if [[ "$token" =~ ^[0-9]+$ ]] &&
        ((token >= 1 && token <= ${#PACKAGE_NAMES[@]})); then
        index=$((token - 1))
        if [[ -z "${seen[$index]+x}" ]]; then
          SELECTED_INDEXES+=("$index")
          seen["$index"]=1
        fi
      else
        SELECTED_INDEXES=()
        break
      fi
    done

    ((${#SELECTED_INDEXES[@]} > 0)) && return 0
    warning "Invalid selection."
  done
}

write_checksums() {
  local output_dir=$1
  local -a package_files=()

  case "$REPO_TYPE" in
    deb) mapfile -t package_files < <(compgen -G "$output_dir/*.deb" || true) ;;
    rpm) mapfile -t package_files < <(compgen -G "$output_dir/*.rpm" || true) ;;
    static) mapfile -t package_files < <(compgen -G "$output_dir/*.tgz" || true) ;;
  esac

  ((${#package_files[@]} > 0)) || return 0

  (
    cd "$output_dir"
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum -- "${package_files[@]##*/}" >SHA256SUMS
    elif command -v shasum >/dev/null 2>&1; then
      shasum -a 256 -- "${package_files[@]##*/}" >SHA256SUMS
    else
      warning "sha256sum or shasum is not installed; checksums were not created."
    fi
  )
}

download_selected() {
  local package_url=$1
  local download_date
  local output_dir
  local manifest
  local index
  local filename
  local failed=0

  download_date=$(date '+%Y-%m-%d')
  output_dir="$SCRIPT_DIR/$download_date"
  mkdir -p -- "$output_dir"
  manifest="$output_dir/manifest.tsv"
  printf 'package\tversion\tpublished\tfilename\turl\n' >"$manifest"

  printf '\n%sOutput directory: %s%s\n' "$BOLD" "$output_dir" "$RESET"
  for index in "${SELECTED_INDEXES[@]}"; do
    filename=${PACKAGE_FILES[index]}
    info "Downloading ${PACKAGE_NAMES[index]} (${PACKAGE_VERSIONS[index]})..."
    if download_url "${package_url%/}/$filename" "$output_dir/$filename"; then
      printf '%s\t%s\t%s\t%s\t%s\n' "${PACKAGE_NAMES[index]}" "${PACKAGE_VERSIONS[index]}" "${PACKAGE_DATES[index]}" "$filename" "${package_url%/}/$filename" >>"$manifest"
    else
      failed=$((failed + 1))
      rm -f -- "$output_dir/$filename"
      warning "Failed to download $filename."
    fi
  done

  write_checksums "$output_dir"

  if ((failed > 0)); then
    warning "$failed download(s) failed. Successfully downloaded files remain in the output directory."
    return 1
  fi

  DOWNLOADED_OUTPUT_DIR=$output_dir
  success "All selected packages were downloaded successfully."
  printf 'Manifest: %s\n' "$manifest"
}

run_install_step() {
  local label=$1
  local log_file=$2
  shift 2

  info "$label..."
  if "$@" 2>&1 | tee -a "$log_file"; then
    success "$label: successful."
    return 0
  fi

  warning "$label failed. Review the command output above and $log_file."
  return 1
}

configure_docker_service() {
  local target_user=$1
  local log_file=$2
  local failures=$3

  if ! getent group docker >/dev/null 2>&1; then
    if ! run_install_step "Creating docker group" "$log_file" sudo groupadd docker; then
      failures=$((failures + 1))
    fi
  else
    success "Docker group already exists."
  fi

  if id -nG "$target_user" | tr ' ' '\n' | grep -qx docker; then
    success "User $target_user is already a member of the docker group."
  elif ! run_install_step "Adding $target_user to the docker group" "$log_file" sudo usermod -aG docker "$target_user"; then
    failures=$((failures + 1))
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if [[ ! -f /lib/systemd/system/docker.service && ! -f /usr/lib/systemd/system/docker.service && ! -f /etc/systemd/system/docker.service ]]; then
      warning "No Docker systemd unit was found. Static installs may require manual service setup."
      failures=$((failures + 1))
    elif ! run_install_step "Enabling and starting Docker service" "$log_file" sudo systemctl enable --now docker; then
      failures=$((failures + 1))
    fi
  elif command -v service >/dev/null 2>&1; then
    if ! run_install_step "Starting Docker service" "$log_file" sudo service docker start; then
      failures=$((failures + 1))
    fi
  else
    warning "Neither systemctl nor service is available; Docker could not be started automatically."
    failures=$((failures + 1))
  fi

  if command -v docker >/dev/null 2>&1; then
    if ! run_install_step "Verifying Docker daemon" "$log_file" sudo docker info; then
      failures=$((failures + 1))
    fi

    if command -v sg >/dev/null 2>&1; then
      if ! run_install_step "Verifying docker group access for $target_user" "$log_file" sudo -u "$target_user" sg docker -c 'docker info >/dev/null'; then
        failures=$((failures + 1))
      fi
    else
      warning "The sg command is unavailable; immediate non-root Docker access could not be verified."
      failures=$((failures + 1))
    fi
  else
    warning "The docker command is unavailable after installation."
    failures=$((failures + 1))
  fi

  INSTALL_FAILURES=$failures
}

print_install_summary() {
  local output_dir=$1
  local target_user=$2
  local log_file=$3
  local failures=$4

  printf '\n%sInstallation summary%s\n' "$BOLD" "$RESET"
  printf '  Packages: %s\n' "$output_dir"
  printf '  User:     %s\n' "$target_user"
  printf '  Log:      %s\n' "$log_file"

  if ((failures > 0)); then
    warning "Installation completed with $failures failed step(s). See the messages above and $log_file for the cause."
    return 1
  fi

  success "Docker was installed, started, and verified successfully."
  success "User $target_user was added to the docker group."
  printf 'Open a new login session to use Docker normally without sudo.\n'
  printf 'For the current terminal, run: newgrp docker\n'
}

install_deb_packages() {
  local output_dir=$1
  local target_user
  local log_file="$output_dir/install.log"
  local -a deb_files=()
  local failures=0

  target_user=${SUDO_USER:-${USER:-}}
  [[ -n "$target_user" && "$target_user" != "root" ]] ||
    die "Could not determine the non-root user to add to the docker group."
  command -v sudo >/dev/null 2>&1 || die "sudo is required for installation."
  command -v apt-get >/dev/null 2>&1 ||
    die "Automatic .deb installation requires apt-get on Debian, Ubuntu, or Raspbian."
  [[ "$(uname -s)" == "Linux" ]] || die "Automatic installation requires Linux."

  mapfile -t deb_files < <(find "$output_dir" -maxdepth 1 -type f -name '*.deb' -print | sort)
  ((${#deb_files[@]} > 0)) || die "No downloaded .deb files were found to install."

  : >"$log_file"
  printf 'Installation started: %s\n' "$(date --iso-8601=seconds)" >>"$log_file"
  printf 'Package type: deb\n' >>"$log_file"
  printf 'Target user: %s\n\n' "$target_user" >>"$log_file"

  info "Administrator privileges are required to install Docker and configure the docker group."
  warning "Membership in the docker group grants root-equivalent privileges. Continue only for a trusted user."
  if ! sudo -v; then
    warning "sudo authentication failed or was cancelled. Packages were downloaded but not installed."
    return 1
  fi

  if ! run_install_step "Installing downloaded packages" "$log_file" sudo apt-get install -y "${deb_files[@]}"; then
    failures=$((failures + 1))
  fi

  configure_docker_service "$target_user" "$log_file" "$failures"
  failures=$INSTALL_FAILURES
  print_install_summary "$output_dir" "$target_user" "$log_file" "$failures"
}

install_rpm_packages() {
  local output_dir=$1
  local target_user
  local log_file="$output_dir/install.log"
  local -a rpm_files=()
  local failures=0
  local install_cmd=()

  target_user=${SUDO_USER:-${USER:-}}
  [[ -n "$target_user" && "$target_user" != "root" ]] ||
    die "Could not determine the non-root user to add to the docker group."
  command -v sudo >/dev/null 2>&1 || die "sudo is required for installation."
  [[ "$(uname -s)" == "Linux" ]] || die "Automatic installation requires Linux."

  mapfile -t rpm_files < <(find "$output_dir" -maxdepth 1 -type f -name '*.rpm' -print | sort)
  ((${#rpm_files[@]} > 0)) || die "No downloaded .rpm files were found to install."

  if command -v dnf >/dev/null 2>&1; then
    install_cmd=(sudo dnf install -y "${rpm_files[@]}")
  elif command -v yum >/dev/null 2>&1; then
    install_cmd=(sudo yum install -y "${rpm_files[@]}")
  elif command -v rpm >/dev/null 2>&1; then
    install_cmd=(sudo rpm -Uvh "${rpm_files[@]}")
  else
    die "Automatic .rpm installation requires dnf, yum, or rpm."
  fi

  : >"$log_file"
  printf 'Installation started: %s\n' "$(date --iso-8601=seconds)" >>"$log_file"
  printf 'Package type: rpm\n' >>"$log_file"
  printf 'Target user: %s\n\n' "$target_user" >>"$log_file"

  info "Administrator privileges are required to install Docker and configure the docker group."
  warning "Membership in the docker group grants root-equivalent privileges. Continue only for a trusted user."
  if ! sudo -v; then
    warning "sudo authentication failed or was cancelled. Packages were downloaded but not installed."
    return 1
  fi

  if ! run_install_step "Installing downloaded packages" "$log_file" "${install_cmd[@]}"; then
    failures=$((failures + 1))
  fi

  configure_docker_service "$target_user" "$log_file" "$failures"
  failures=$INSTALL_FAILURES
  print_install_summary "$output_dir" "$target_user" "$log_file" "$failures"
}

install_static_binaries() {
  local output_dir=$1
  local target_user
  local log_file="$output_dir/install.log"
  local archive
  local extract_dir
  local docker_binary=""
  local dockerd_binary=""
  local failures=0

  target_user=${SUDO_USER:-${USER:-}}
  [[ -n "$target_user" && "$target_user" != "root" ]] ||
    die "Could not determine the non-root user to add to the docker group."
  command -v sudo >/dev/null 2>&1 || die "sudo is required for installation."
  [[ "$(uname -s)" == "Linux" ]] || die "Automatic installation requires Linux."

  for archive in "$output_dir"/docker-*.tgz; do
    [[ -f "$archive" ]] || continue
    [[ "$(basename "$archive")" == docker-rootless-extras-* ]] && continue
    break
  done
  [[ -f "${archive:-}" ]] || die "No docker static binary archive was found to install."

  : >"$log_file"
  printf 'Installation started: %s\n' "$(date --iso-8601=seconds)" >>"$log_file"
  printf 'Package type: static\n' >>"$log_file"
  printf 'Target user: %s\n\n' "$target_user" >>"$log_file"

  info "Administrator privileges are required to install Docker and configure the docker group."
  warning "Membership in the docker group grants root-equivalent privileges. Continue only for a trusted user."
  if ! sudo -v; then
    warning "sudo authentication failed or was cancelled. Packages were downloaded but not installed."
    return 1
  fi

  extract_dir=$(mktemp -d)
  if ! run_install_step "Extracting $(basename "$archive")" "$log_file" tar -xzf "$archive" -C "$extract_dir"; then
    rm -rf -- "$extract_dir"
    return 1
  fi

  docker_binary=$(find "$extract_dir" -type f -name docker -print | head -n 1 || true)
  dockerd_binary=$(find "$extract_dir" -type f -name dockerd -print | head -n 1 || true)
  [[ -n "$docker_binary" && -n "$dockerd_binary" ]] ||
    die "The static archive did not contain docker and dockerd binaries."

  if ! run_install_step "Installing static Docker binaries to /usr/local/bin" "$log_file" sudo cp -a "$extract_dir"/docker/. /usr/local/bin/; then
    failures=$((failures + 1))
  fi
  rm -rf -- "$extract_dir"

  if [[ ! -f /etc/systemd/system/docker.service &&
    ! -f /lib/systemd/system/docker.service &&
    ! -f /usr/lib/systemd/system/docker.service ]]; then
    if command -v systemctl >/dev/null 2>&1; then
      info "Creating a systemd unit for the static Docker daemon..."
      sudo tee /etc/systemd/system/docker.service >/dev/null <<'EOF'
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target firewalld.service containerd.service
Wants=network-online.target
Requires=docker.socket

[Service]
Type=notify
ExecStart=/usr/local/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock
ExecReload=/bin/kill -s HUP $MAINPID
TimeoutSec=0
RestartSec=2
Restart=always
StartLimitBurst=3
StartLimitInterval=60s
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
EOF
      sudo tee /etc/systemd/system/docker.socket >/dev/null <<'EOF'
[Unit]
Description=Docker Socket for the API

[Socket]
ListenStream=/var/run/docker.sock
SocketMode=0660
SocketUser=root
SocketGroup=docker

[Install]
WantedBy=sockets.target
EOF
      sudo systemctl daemon-reload
    fi
  fi

  configure_docker_service "$target_user" "$log_file" "$failures"
  failures=$INSTALL_FAILURES
  print_install_summary "$output_dir" "$target_user" "$log_file" "$failures"
}

install_downloaded_packages() {
  local output_dir=$1

  if compgen -G "$output_dir/*.deb" >/dev/null; then
    install_deb_packages "$output_dir"
  elif compgen -G "$output_dir/*.rpm" >/dev/null; then
    install_rpm_packages "$output_dir"
  elif compgen -G "$output_dir/*.tgz" >/dev/null; then
    install_static_binaries "$output_dir"
  else
    die "No supported package files were found to install."
  fi
}

navigate_deb_repo() {
  local distro=$1

  info "Fetching available $distro releases..."
  load_directories "${BASE_URL%/}/$distro/dists" ||
    die "No releases were found under $distro/dists."
  choose_one "Select an operating system release/codename:" "${DIRECTORIES[@]}"
  SELECTED_RELEASE=$CHOSEN_VALUE

  info "Fetching package channels for $SELECTED_RELEASE..."
  load_directories "${BASE_URL%/}/$distro/dists/$SELECTED_RELEASE/pool" ||
    die "No channels were found under $distro/dists/$SELECTED_RELEASE/pool."
  choose_one "Select a package channel:" "${DIRECTORIES[@]}"
  SELECTED_CHANNEL=$CHOSEN_VALUE

  info "Fetching available architectures..."
  load_directories "${BASE_URL%/}/$distro/dists/$SELECTED_RELEASE/pool/$SELECTED_CHANNEL" ||
    die "No architectures were found for the $SELECTED_CHANNEL channel."
  choose_one "Select an architecture:" "${DIRECTORIES[@]}"
  SELECTED_ARCHITECTURE=$CHOSEN_VALUE

  PACKAGE_URL="${BASE_URL%/}/$distro/dists/$SELECTED_RELEASE/pool/$SELECTED_CHANNEL/$SELECTED_ARCHITECTURE"
}

navigate_rpm_repo() {
  local distro=$1

  info "Fetching available $distro releases..."
  load_directories "${BASE_URL%/}/$distro" ||
    die "No releases were found under $distro."
  choose_one "Select an operating system release/version:" "${DIRECTORIES[@]}"
  SELECTED_RELEASE=$CHOSEN_VALUE

  info "Fetching available architectures..."
  load_directories "${BASE_URL%/}/$distro/$SELECTED_RELEASE" ||
    die "No architectures were found for $distro/$SELECTED_RELEASE."
  choose_one "Select an architecture:" "${DIRECTORIES[@]}"
  SELECTED_ARCHITECTURE=$CHOSEN_VALUE

  info "Fetching package channels..."
  load_directories "${BASE_URL%/}/$distro/$SELECTED_RELEASE/$SELECTED_ARCHITECTURE" ||
    die "No channels were found under $distro/$SELECTED_RELEASE/$SELECTED_ARCHITECTURE."
  choose_one "Select a package channel:" "${DIRECTORIES[@]}"
  SELECTED_CHANNEL=$CHOSEN_VALUE

  PACKAGE_URL="${BASE_URL%/}/$distro/$SELECTED_RELEASE/$SELECTED_ARCHITECTURE/$SELECTED_CHANNEL/Packages"
}

navigate_static_repo() {
  SELECTED_RELEASE=""

  info "Fetching package channels..."
  load_directories "${BASE_URL%/}/static" ||
    die "No channels were found under static."
  choose_one "Select a package channel:" "${DIRECTORIES[@]}"
  SELECTED_CHANNEL=$CHOSEN_VALUE

  info "Fetching available architectures..."
  load_directories "${BASE_URL%/}/static/$SELECTED_CHANNEL" ||
    die "No architectures were found under static/$SELECTED_CHANNEL."
  choose_one "Select an architecture:" "${DIRECTORIES[@]}"
  SELECTED_ARCHITECTURE=$CHOSEN_VALUE

  PACKAGE_URL="${BASE_URL%/}/static/$SELECTED_CHANNEL/$SELECTED_ARCHITECTURE"
}

confirm_architecture_mismatch() {
  local architecture=$1
  local native_architecture

  native_architecture=$(get_native_architecture)
  if [[ "$architecture" != "$native_architecture" ]]; then
    warning "Selected architecture '$architecture' does not match this system's '$native_architecture' architecture."
    if ! confirm "Continue downloading packages for $architecture?" "no"; then
      exit 0
    fi
  fi
}

main() {
  local distro
  local scope_choice
  local listing_file
  local -a scope_choices=(
    "Recommended Docker packages"
    "All package families"
  )

  if (($# > 0)); then
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      *)
        usage
        die "Unknown option: $1"
        ;;
    esac
  fi

  TEMP_DIR=$(mktemp -d)
  info "Fetching the Linux distribution list from Docker..."
  load_directories "$BASE_URL" || die "Could not fetch the distribution list."
  choose_one "Select a Linux distribution:" "${DIRECTORIES[@]}"
  distro=$CHOSEN_VALUE

  detect_repo_type "$distro"
  info "Detected repository type: $REPO_TYPE"

  case "$REPO_TYPE" in
    deb) navigate_deb_repo "$distro" ;;
    rpm) navigate_rpm_repo "$distro" ;;
    static) navigate_static_repo ;;
  esac

  if [[ "$REPO_TYPE" != "static" ]]; then
    confirm_architecture_mismatch "$SELECTED_ARCHITECTURE"
  fi

  listing_file="$TEMP_DIR/packages.html"
  info "Checking the latest available package versions..."
  fetch_url "${PACKAGE_URL%/}/" "$listing_file" ||
    die "Could not fetch the package list: $PACKAGE_URL"

  parse_latest_packages "$listing_file"
  ((${#LATEST_FILE[@]} > 0)) || die "No valid package files were found in the selected path."

  choose_one "Which packages should be displayed?" "${scope_choices[@]}"
  scope_choice=$CHOSEN_VALUE
  if [[ "$scope_choice" == "Recommended Docker packages" ]]; then
    build_package_list "recommended"
  else
    build_package_list "all"
  fi

  show_packages
  choose_packages
  download_selected "$PACKAGE_URL" || die "Download failed."

  if [[ "$REPO_TYPE" != "static" ]]; then
    if [[ "$SELECTED_ARCHITECTURE" != "$(get_native_architecture)" ]]; then
      die "Installation was blocked because the downloaded architecture does not match this system."
    fi
  fi
  install_downloaded_packages "$DOWNLOADED_OUTPUT_DIR"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
