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
DOWNLOADED_OUTPUT_DIR=""
CHOSEN_VALUE=""

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

The script interactively selects:
  distribution -> release -> channel -> architecture -> packages

After downloading, it can:
  install the downloaded packages
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

version_is_newer() {
  local candidate=$1
  local current=$2

  if command -v dpkg >/dev/null 2>&1; then
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

  if [[ "$installed_version" == *:* && "$repository_version" != *:* ]]; then
    installed_epoch=${installed_version%%:*}
    comparable_repository_version="${installed_epoch}:${repository_version}"
  fi

  if command -v dpkg >/dev/null 2>&1; then
    dpkg --compare-versions "$installed_version" ge "$comparable_repository_version"
  else
    ! version_is_newer "$comparable_repository_version" "$installed_version"
  fi
}

get_installed_package_version() {
  local package=$1
  local package_status
  local installed_version

  command -v dpkg-query >/dev/null 2>&1 || return 1
  package_status=$(dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null || true)
  [[ "$package_status" == "ii " ]] || return 1
  installed_version=$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null || true)
  [[ -n "$installed_version" ]] || return 1
  printf '%s\n' "$installed_version"
}

display_package_version() {
  local version=$1

  version=${version#*:}
  version=${version%%~*}
  printf '%s\n' "$version"
}

parse_latest_packages() {
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
    published=$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}(:[0-9]{2})?' <<<"$line" | head -n 1 || true)
    published=${published%% *}
    [[ -n "$published" ]] || published="Unknown"

    if [[ -z "${LATEST_VERSION[$package]+x}" ]] ||
      version_is_newer "$version" "${LATEST_VERSION[$package]}" ||
      [[ "$version" == "${LATEST_VERSION[$package]}" && "$published" > "${LATEST_DATE[$package]}" ]]; then
      LATEST_FILE["$package"]=$filename
      LATEST_VERSION["$package"]=$version
      LATEST_DATE["$package"]=$published
    fi
  done <"$listing_file"
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
    for package in "${STANDARD_PACKAGES[@]}"; do
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
    done
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

  (
    cd "$output_dir"
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum -- *.deb >SHA256SUMS
    elif command -v shasum >/dev/null 2>&1; then
      shasum -a 256 -- *.deb >SHA256SUMS
    else
      warning "sha256sum or shasum is not installed; checksums were not created."
    fi
  )
}

download_selected() {
  local package_url=$1
  local distro=$2
  local release=$3
  local channel=$4
  local architecture=$5
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

  if compgen -G "$output_dir/*.deb" >/dev/null; then
    write_checksums "$output_dir"
  fi

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

install_downloaded_packages() {
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
    die "Automatic installation currently requires apt-get on Debian, Ubuntu, or Raspbian."
  [[ "$(uname -s)" == "Linux" ]] || die "Automatic installation requires Linux."

  mapfile -t deb_files < <(find "$output_dir" -maxdepth 1 -type f -name '*.deb' -print | sort)
  ((${#deb_files[@]} > 0)) || die "No downloaded .deb files were found to install."

  : >"$log_file"
  printf 'Installation started: %s\n' "$(date --iso-8601=seconds)" >>"$log_file"
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
    if ! run_install_step "Enabling and starting Docker service" "$log_file" sudo systemctl enable --now docker; then
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

main() {
  local distro
  local release
  local channel
  local architecture
  local scope_choice
  local package_url
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

  if ! fetch_url "${BASE_URL%/}/$distro/dists/" >/dev/null 2>&1; then
    die "This version supports package repositories with a dists directory. Select Ubuntu, Debian, or Raspbian."
  fi

  info "Fetching available $distro releases..."
  load_directories "${BASE_URL%/}/$distro/dists" ||
    die "No releases were found under $distro/dists."
  choose_one "Select an operating system release/codename:" "${DIRECTORIES[@]}"
  release=$CHOSEN_VALUE

  info "Fetching package channels for $release..."
  load_directories "${BASE_URL%/}/$distro/dists/$release/pool" ||
    die "No channels were found under $distro/dists/$release/pool."
  choose_one "Select a package channel:" "${DIRECTORIES[@]}"
  channel=$CHOSEN_VALUE

  info "Fetching available architectures..."
  load_directories "${BASE_URL%/}/$distro/dists/$release/pool/$channel" ||
    die "No architectures were found for the $channel channel."
  choose_one "Select an architecture:" "${DIRECTORIES[@]}"
  architecture=$CHOSEN_VALUE

  if command -v dpkg >/dev/null 2>&1; then
    local native_architecture
    native_architecture=$(dpkg --print-architecture)
    if [[ "$architecture" != "$native_architecture" ]]; then
      warning "Selected architecture '$architecture' does not match this system's '$native_architecture' architecture."
      if ! confirm "Continue downloading packages for $architecture?" "no"; then
        exit 0
      fi
    fi
  fi

  package_url="${BASE_URL%/}/$distro/dists/$release/pool/$channel/$architecture"
  listing_file="$TEMP_DIR/packages.html"
  info "Checking the latest available package versions..."
  fetch_url "${package_url%/}/" "$listing_file" ||
    die "Could not fetch the package list: $package_url"

  parse_latest_packages "$listing_file"
  ((${#LATEST_FILE[@]} > 0)) || die "No valid .deb files were found in the selected path."

  choose_one "Which packages should be displayed?" "${scope_choices[@]}"
  scope_choice=$CHOSEN_VALUE
  if [[ "$scope_choice" == "Recommended Docker packages" ]]; then
    build_package_list "recommended"
  else
    build_package_list "all"
  fi

  show_packages
  choose_packages
  download_selected "$package_url" "$distro" "$release" "$channel" "$architecture"

  if command -v dpkg >/dev/null 2>&1 &&
    [[ "$architecture" != "$(dpkg --print-architecture)" ]]; then
    die "Installation was blocked because the downloaded architecture does not match this system."
  fi
  install_downloaded_packages "$DOWNLOADED_OUTPUT_DIR"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
