# Doffline

Interactive Docker package downloader and installer for Linux distributions supported by Docker's official repository.

`doffline.sh` reads Docker's official Linux package index, finds the latest package versions, compares them with locally installed versions, downloads selected packages, and configures Docker automatically.

## Supported Distributions

| Type | Distributions | Format | Navigation |
|------|---------------|--------|------------|
| Debian-based | ubuntu, debian, raspbian | `.deb` | release → channel → architecture |
| RPM-based | centos, fedora, rhel, rocky, alma, oracle, sles | `.rpm` | release → architecture → channel |
| Static binaries | static | `.tgz` | channel → architecture |

The script detects the repository layout automatically after you choose a distribution.

## Features

- Interactive distribution, release, channel, and architecture selection
- Live package discovery from Docker's official repository
- Latest Debian package version detection
- Installed versus recommended version comparison
- Color-coded package status:
  - Green: installed version is current or newer
  - Red: package is outdated or not installed
- Individual or batch package downloads
- Automatic SHA-256 checksum generation
- Download manifest generation
- Automatic package installation with `apt-get`
- Docker service enablement and startup
- Automatic `docker` group creation and user configuration
- Root and non-interactive install support through `DOFFLINE_TARGET_USER`
- Docker daemon and non-root access verification
- Automatic fallback from `curl` to `wget`
- Detailed installation log and failure reporting

## Recommended Packages

The default package set contains:

- `containerd.io`
- `docker-ce`
- `docker-ce-cli`
- `docker-buildx-plugin`
- `docker-compose-plugin`

You can also display and select every package family available in the chosen repository path, including optional components such as `docker-ce-rootless-extras`, `docker-model-plugin`, `docker-sbx`, and `docker-secrets-engine`.

## Installation

Clone the repository:

```bash
git clone https://github.com/0xamirreza/Doffline.git
cd Doffline
chmod +x doffline.sh
```

Run the script as a normal user:

```bash
./doffline.sh
```

Do not run the complete script with `sudo`. It requests administrator privileges only when installation and system configuration are required.

### Running as root

If you run the script directly as `root` (without `sudo`), the script cannot infer a non-root user automatically. In that case it will:

- Prompt interactively for a username to add to the `docker` group (leave empty to skip), or
- Use `DOFFLINE_TARGET_USER` when set, or
- Skip docker group configuration and install Docker for root-only use

Example:

```bash
DOFFLINE_TARGET_USER=deploy ./doffline.sh
```

When group configuration is skipped, root can use Docker immediately after installation. Other users must be added to the `docker` group manually.

## Example Selection

For Ubuntu 22.04 on an AMD64 system, select:

```text
ubuntu -> jammy -> stable -> amd64
```

For Fedora 42 on an AMD64 system, select:

```text
fedora -> 42 -> x86_64 -> stable
```

For static binaries on AMD64, select:

```text
static -> stable -> x86_64
```

The package table looks similar to:

```text
Latest available package versions
#    Package                          Installed version      Recommended version    Date
---- -------------------------------- ---------------------- ---------------------- ------------
1    containerd.io                    Not installed          2.2.6-1                2026-07-10
2    docker-ce                        Not installed          29.6.2-1               2026-07-16
3    docker-ce-cli                    Not installed          29.6.2-1               2026-07-16
4    docker-buildx-plugin             Not installed          0.35.0-1               2026-06-24
5    docker-compose-plugin            Not installed          5.3.1-1                2026-07-07
```

Enter `a` to download all displayed packages or enter package numbers separated by spaces:

```text
Selection: 1 2 3
```

## Output

Downloaded files are stored beside the script in a directory named with the current date:

```text
2026-07-21/
```

The directory contains:

```text
2026-07-21/
|-- containerd.io_..._amd64.deb
|-- docker-buildx-plugin_..._amd64.deb
|-- docker-ce-cli_..._amd64.deb
|-- docker-ce_..._amd64.deb
|-- docker-compose-plugin_..._amd64.deb
|-- install.log
|-- manifest.tsv
`-- SHA256SUMS
```

RPM downloads use the same layout with `.rpm` files. Static downloads store `.tgz` archives in the same date directory.

Running the script again on the same day reuses the same date directory.

## Automatic Installation

After all selected packages download successfully, the script automatically:

1. Requests administrator authentication with `sudo` (or runs directly when already root)
2. Installs the downloaded packages with `apt-get`, `dnf`/`yum`, or extracts static binaries
3. Creates the `docker` group if necessary
4. Adds a target user to the `docker` group when one is known
5. Enables and starts the Docker service
6. Verifies the Docker daemon
7. Verifies Docker access through the `docker` group for the target user

The target user is resolved in this order:

| Priority | Source |
|----------|--------|
| 1 | `DOFFLINE_TARGET_USER` environment variable |
| 2 | `SUDO_USER` when the script was started with `sudo` |
| 3 | Current user when not `root` |
| 4 | Interactive prompt when running as `root` |
| 5 | Skipped when running as `root` non-interactively without `DOFFLINE_TARGET_USER` |

Full installation output is written to:

```text
YYYY-MM-DD/install.log
```

After a successful installation for a non-root user, open a new login session or activate the group in the current terminal:

```bash
newgrp docker
```

Verify Docker access:

```bash
docker version
docker run --rm hello-world
```

When the script runs as `root` and no target user is configured, verify directly as root without `newgrp`.

## Requirements

- Linux
- Bash 4 or newer
- `curl` or `wget`
- `dpkg` and `dpkg-query` for `.deb` status checks and installation on Debian-based systems
- `rpm`, `dnf`, or `yum` for `.rpm` status checks and installation on RPM-based systems
- `sudo`
- `apt-get` for automatic `.deb` installation
- `dnf`, `yum`, or `rpm` for automatic `.rpm` installation
- `systemctl` or `service`
- `sha256sum` or `shasum`
- `sg` for immediate group-access verification

Automatic package installation supports:

- Debian-based systems through `apt-get`
- RPM-based systems through `dnf`, `yum`, or `rpm`
- Static binaries through extraction to `/usr/local/bin` and optional systemd unit creation

Static installs do not include `containerd` packages from the repository; use `.deb` or `.rpm` packages when you need the full engine stack with package-manager dependencies.

## Offline Usage Note

The selected Docker packages are saved locally and can be transferred to another compatible system.

However, package-manager installs may download missing operating-system dependencies from configured repositories. For a fully disconnected installation, download all required dependency packages separately before moving the directory to the offline machine.

The target system must also match the selected:

- Distribution
- Release or codename
- CPU architecture

The script blocks automatic installation when the selected package architecture does not match the current system architecture.

## Environment Variables

### Custom Repository URL

Override Docker's default Linux repository:

```bash
DOFFLINE_BASE_URL="https://download.docker.com/linux" ./doffline.sh
```

### Custom User-Agent

Override the HTTP User-Agent if a proxy or CDN rejects the default request:

```bash
DOFFLINE_USER_AGENT="Mozilla/5.0" ./doffline.sh
```

### Target User for Docker Group

Specify which user should be added to the `docker` group. Useful when running as `root` or in non-interactive environments:

```bash
DOFFLINE_TARGET_USER=deploy ./doffline.sh
```

The user must already exist on the system. When unset and the script runs as `root` without a TTY, docker group membership is skipped.

The script uses HTTP/1.1 and automatically tries `wget` if `curl` fails.

## Troubleshooting

### HTTP 403

The script automatically uses a browser-compatible User-Agent and falls back to `wget`. If both clients fail, check:

- Proxy or VPN rules
- Firewall restrictions
- DNS configuration
- System date and time
- Direct access to `download.docker.com`

### Docker Works Only With `sudo`

Open a new login session or run:

```bash
newgrp docker
```

Then verify:

```bash
docker info
```

### Installation Failure

Review the terminal error and the generated log:

```bash
cat YYYY-MM-DD/install.log
```

Downloaded packages and successful partial downloads remain in the date directory.

To install packages that were already downloaded without re-running the full script:

```bash
sudo apt-get install -y YYYY-MM-DD/*.deb
sudo systemctl enable --now docker
```

Replace `apt-get` with `dnf install -y` or `rpm -Uvh` for `.rpm` packages.

### Running as root Without a Target User

If you run the script as `root` and see `Running as root without a target user`, Docker is installed but no user is added to the `docker` group. Either:

- Set `DOFFLINE_TARGET_USER` before running, or
- Add users manually: `usermod -aG docker username`

### Check Download Integrity

From inside the output directory:

```bash
sha256sum --check SHA256SUMS
```

## Security Warning

Membership in the `docker` group grants root-equivalent access through the Docker daemon. Add only trusted users to this group.

## Help

```bash
./doffline.sh --help
```

## Maintainer

Amirreza Sedighi A.K.A. `0XV`

Repository: `https://github.com/0xamirreza/Doffline`
