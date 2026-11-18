# ElegooSlicer for Debian

Unofficial Debian packages of [ElegooSlicer](https://github.com/elegooofficial/ElegooSlicer),
built from source with GitHub Actions. Similar in spirit to
[orcaslicer-debian](https://github.com/BasicAcid/orcaslicer-debian).

Packages are built for **Debian 12 (bookworm)** and **Debian 13 (trixie)**, amd64.

## Installation

Download the `.deb` for your Debian release from the
[Releases](../../releases) page and install it with apt (resolves dependencies):

```sh
sudo apt install ./elegoo-slicer_<version>~deb13_amd64.deb
```

The program is installed to `/opt/elegoo-slicer`, the launcher is
`/usr/bin/elegoo-slicer`, and a desktop entry is added.

### Differences to the official AppImage

* None regarding features: like the official release, the packages include
  the ELEGOO cloud features and therefore the **proprietary Agora RTM SDK**
  (`libagora_rtm_sdk.so`, `libaosl.so` in `/opt/elegoo-slicer/bin`).
  A build without them is available via `ELEGOO_CLOUD=0` (local build) or
  the `cloud` input of the *Build* workflow; it applies `patches/no-cloud/`
  and supports printing over the local network only.
* The launcher keeps your session locale, so the UI starts in your language.
  The upstream AppImage forces `LC_ALL=C`, which shows an "en_US failed"
  dialog and quits when `en_US.UTF-8` is not generated. Set
  `ELEGOO_SLICER_C_LOCALE=1` to get the upstream behaviour.
* The launcher points `SSL_CERT_FILE` to the Debian CA bundle, so the
  "use system SSL certificate" question at startup does not appear.

## How it works

| File | Purpose |
|------|---------|
| `.github/workflows/check-upstream.yml` | Runs every 6 hours, looks up the latest upstream release (no pre-releases). If there is no release `<tag>-1` here yet, it calls the build workflow. |
| `.github/workflows/build.yml` | Builds the given upstream tag for every Debian suite in a `debian:<suite>` container, test-installs the package into a clean container and publishes a GitHub release `<tag>-<revision>` with the packages and `SHA256SUMS`. Can also be started manually. |
| `docker/Dockerfile` | Build environment (system build dependencies). |
| `scripts/build-deb.sh` | Builds the bundled dependencies (cached between runs), the slicer itself, and assembles the `.deb` with `dpkg-deb`. Runtime dependencies are determined with `dpkg-shlibdeps`. |
| `scripts/test-install.sh` | Installs the package into a clean system and checks for unresolved libraries. |
| `patches/` | Patches applied to the upstream source (`git apply`); `patches/no-cloud/` only for `ELEGOO_CLOUD=0`. |
| `packaging/` | Control file template, launcher script, copyright file. |

### Upstream specifics

* The bundled `elegoo-link` library is fetched from its `main` branch by
  upstream. The build pins the commit that is current when the build starts;
  it is part of the dependency cache key and named in the release notes.
* The printer web UI is downloaded with upstream's `scripts/download_web_dep.sh`.
* If a patch no longer applies to a new upstream release, the build fails
  early with `patch ... does not apply` - update the patch in `patches/`.

### Versioning

Upstream tag `v1.5.3.5` becomes package version `1.5.3.5-1~deb12` (bookworm) or
`1.5.3.5-1~deb13` (trixie). The GitHub release is named `v1.5.3.5-1`.
To publish a fixed package for the same upstream release, start the *Build*
workflow manually with `revision` = `2`.

## Building locally

Requires Docker, about 30 GB of disk space and 1-3 hours of CPU time
(`JOBS=<n>` limits parallelism, about 2 GB RAM per job):

```sh
scripts/local-build.sh v1.5.3.5 trixie
ls out/
```

## Repository setup

* *Settings → Actions → General → Workflow permissions*: **Read and write**
  (needed to create releases).
* Scheduled workflows are disabled by GitHub after 60 days without repository
  activity; re-enable them in the *Actions* tab if that happens.

## License

The build scripts in this repository are licensed under the GNU General Public
License v3.0 or later, see [LICENSE](LICENSE). ElegooSlicer itself is licensed
under the GNU Affero General Public License v3.0.
