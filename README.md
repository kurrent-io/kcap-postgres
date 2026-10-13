# kcap-postgres

A portable PostgreSQL 18 with [pgvector](https://github.com/pgvector/pgvector) and `pg_trgm`, built from source for the local edition of Kurrent Capacitor. Each release holds one archive per platform that runs from any directory, with no installer and nothing extracted at runtime.

It is a build input for Capacitor's server bundle, which signs it and ships it. It is not meant to be installed on its own.

## Platforms

| Runtime identifier | Built on | Runs on |
| -- | -- | -- |
| `osx-arm64` | `macos-15` | macOS 15 or later, Apple silicon |
| `linux-x64` | `manylinux_2_28` | glibc 2.28 or later (RHEL 8, Debian 10, Ubuntu 18.10 and later) |
| `linux-arm64` | `manylinux_2_28` | the same, on aarch64 |

## What is in an archive

`kcap-postgres-<version>-<rid>.tar.gz` holds:

* `bin/`: `postgres`, `initdb`, `pg_ctl`, `pg_controldata`, `pg_isready`, `pg_dump`, `pg_dumpall`, `pg_restore`, `pg_upgrade`, `pg_resetwal`, `psql`.
* `lib/`: `libpq`, the server's own modules, `pg_trgm` and `vector`.
* `share/`: catalog files, extension scripts, Postgres's own timezone data, and the PostgreSQL and pgvector licences under `share/licenses/`.
* `kcap-postgres.json`: the versions, the pgvector commit, the configure flags and the CI run that built it.

Every release also has a `SHA256SUMS` covering its archives.

The build leaves out ICU, libxml2, OpenSSL, readline, LLVM, GSSAPI and LDAP, because the server uses none of them. The archive depends only on the C library and zlib from the operating system. `scripts/check-deps.sh` enforces that on every build.

## Running it

The settings the local edition uses, and that `scripts/smoke.sh` tests:

```bash
bin/initdb -D data --username=kcap --locale=C --encoding=UTF8 --auth-local=trust --auth-host=reject
cat >> data/postgresql.conf <<EOF
listen_addresses = ''
unix_socket_directories = '/path/to/run'
unix_socket_permissions = 0700
max_connections = 26
shared_buffers = 64MB
timezone = 'UTC'
EOF
bin/pg_ctl -D data -l postgres.log -w start
```

Postgres refuses to run as root. A unix socket path is limited to 104 bytes on macOS and 108 on Linux.

## Building

```bash
bash scripts/build.sh osx-arm64 out                 # on an Apple-silicon Mac with Xcode command-line tools
bash scripts/build-in-container.sh linux-arm64 out  # with Docker; linux-x64 runs under emulation on a Mac
bash scripts/smoke.sh out/kcap-postgres-*-osx-arm64.tar.gz
```

`build.sh` verifies the Postgres source digest and the pgvector commit from `versions.env` before building, and runs `check-deps.sh` on the result.

## Releasing

1. Change `versions.env`. A Postgres or pgvector bump, or a change to the build, needs a release. Set `PACKAGE_REVISION` back to `1` when `PG_VERSION` changes, and increment it otherwise.
2. Merge to `main` once CI is green.
3. Tag `main` with `<PG_VERSION>-<PACKAGE_REVISION>`, for example `18.6-1`, and push the tag.

The release workflow builds and smoke-tests every platform, then publishes the archives and `SHA256SUMS`. It refuses a tag that does not match `versions.env`, and it refuses a release that already has assets, because downstream pins archives by digest.

## Consuming

kcap-server pins one release in `eng/kcap-postgres.env` (the version and one SHA-256 per runtime identifier), and `scripts/fetch-postgres.sh <rid> <dest>` downloads, verifies and extracts it.

## Licence

The scripts in this repository are under the Apache License 2.0. PostgreSQL and pgvector are under the PostgreSQL Licence; their licence files ship in every archive.
