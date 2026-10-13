#!/usr/bin/env bash
# Exercises an extracted archive the way the local bundle uses it: a fresh cluster on a unix socket
# only, both extensions, an HNSW and a trigram index, a clean stop. Installs into, and puts its
# socket under, a path containing a space.
set -euo pipefail

archive=$(cd "$(dirname "${1:?usage: smoke.sh <archive.tar.gz>}")" && pwd)/$(basename "$1")
[[ $(id -u) != 0 ]] || { echo "smoke: run as a non-root user; Postgres refuses root" >&2; exit 2; }

# /tmp, not $TMPDIR: macOS's $TMPDIR is long enough to push the socket path past its 104-byte limit.
root=$(mktemp -d "/tmp/kcap pg smoke.XXXXXX")
pg="$root/install dir"
data="$root/data"
run="$root/run dir"

stop() {
    if [[ -f $data/postmaster.pid ]]; then
        "$pg/bin/pg_ctl" -D "$data" -m immediate -w stop >/dev/null 2>&1 || true
    fi
    rm -rf "$root"
}
trap stop EXIT

mkdir -p "$pg" && mkdir -m 700 "$run"
tar -xzf "$archive" -C "$pg"

build_prefix=$(sed -n 's/.*"build_prefix": *"\([^"]*\)".*/\1/p' "$pg/kcap-postgres.json")
[[ -n $build_prefix && ! -e $build_prefix ]] \
    || { echo "smoke: build prefix '$build_prefix' exists here, so relocation is not proven" >&2; exit 1; }

"$pg/bin/initdb" -D "$data" --username=kcap --locale=C --encoding=UTF8 \
    --auth-local=trust --auth-host=reject >"$root/initdb.log"
cat >>"$data/postgresql.conf" <<EOF
listen_addresses = ''
unix_socket_directories = '$run'
unix_socket_permissions = 0700
max_connections = 26
shared_buffers = 64MB
timezone = 'UTC'
EOF
"$pg/bin/pg_ctl" -D "$data" -l "$root/postgres.log" -w start >/dev/null

sql() { "$pg/bin/psql" -h "$run" -U kcap -d postgres -v ON_ERROR_STOP=1 -qAt -c "$1"; }
expect() { [[ $2 == *"$3"* ]] || { echo "smoke: $1: expected '$3' in: $2" >&2; exit 1; }; }
expect_eq() { [[ $2 == "$3" ]] || { echo "smoke: $1: expected '$3', got: $2" >&2; exit 1; }; }

sql "CREATE EXTENSION vector; CREATE EXTENSION pg_trgm;"
expect_eq "extensions" "$(sql "SELECT string_agg(extname, ',' ORDER BY extname) FROM pg_extension")" "pg_trgm,plpgsql,vector"
expect_eq "timezone" "$(sql "SHOW timezone")" "UTC"

sql "CREATE TABLE vec (id int PRIMARY KEY, embedding vector(1024));
     INSERT INTO vec SELECT i, (SELECT array_agg(random())::real[] FROM generate_series(1, 1024) WHERE i IS NOT NULL)::vector
       FROM generate_series(1, 200) i;
     CREATE INDEX vec_hnsw ON vec USING hnsw (embedding vector_cosine_ops);"
expect "hnsw plan" "$(sql "SET enable_seqscan = off; EXPLAIN (COSTS OFF)
     SELECT id FROM vec ORDER BY embedding <=> (SELECT embedding FROM vec WHERE id = 1) LIMIT 5")" "vec_hnsw"
expect_eq "hnsw result" "$(sql "SET enable_seqscan = off;
     SELECT id FROM vec ORDER BY embedding <=> (SELECT embedding FROM vec WHERE id = 1) LIMIT 1")" "1"

sql "CREATE TABLE txt (id int, body text);
     INSERT INTO txt SELECT i, 'session ' || i FROM generate_series(1, 2000) i;
     CREATE INDEX txt_trgm ON txt USING gin (body gin_trgm_ops);"
expect "trigram plan" "$(sql "SET enable_seqscan = off; EXPLAIN (COSTS OFF) SELECT id FROM txt WHERE body ILIKE '%ion 1234%'")" "txt_trgm"
expect_eq "trigram result" "$(sql "SET enable_seqscan = off; SELECT id FROM txt WHERE body ILIKE '%ion 1234%'")" "1234"

"$pg/bin/pg_ctl" -D "$data" -m fast -w stop >/dev/null
[[ ! -e $data/postmaster.pid && ! -e $run/.s.PGSQL.5432 ]] || { echo "smoke: stop left a pid file or socket" >&2; exit 1; }

echo "smoke: OK"
