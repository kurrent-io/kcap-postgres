#!/usr/bin/env bash
# Builds a relocatable Postgres with pg_trgm and pgvector for one runtime identifier, trims it to
# what the local bundle runs, makes every library reference relative, checks it and archives it.
# win-x64 runs in Git Bash with the MSVC x64 environment loaded (vcvars64), plus meson and win_bison.
set -euo pipefail

usage="usage: build.sh <osx-arm64|linux-x64|linux-arm64|win-x64> <out-dir>"
repo=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=versions.env
source "$repo/versions.env"
rid=${1:?$usage}
mkdir -p "${2:?$usage}" && out=$(cd "$2" && pwd)

case "$(uname -s)" in MINGW*|MSYS*) os=Windows ;; *) os=$(uname -s) ;; esac
host="$os/$(uname -m)"
case "$rid" in
    osx-arm64) expected_host=Darwin/arm64 ;;
    linux-x64) expected_host=Linux/x86_64 ;;
    linux-arm64) expected_host=Linux/aarch64 ;;
    win-x64) expected_host=Windows/x86_64 ;;
    *) echo "$usage" >&2; exit 2 ;;
esac
[[ $host == "$expected_host" ]] || { echo "build: $rid builds on $expected_host, not $host" >&2; exit 2; }

# Source tarballs carry no generated parsers since Postgres 17, so bison, flex and perl are needed.
case "$rid" in
    linux-*) tools=(curl git make cc tar bison flex perl file patchelf strip readelf objdump) ;;
    osx-*) tools=(curl git make cc tar bison flex perl file install_name_tool codesign otool xcrun strip) ;;
    win-*) tools=(curl git tar perl cygpath meson ninja cl nmake dumpbin) ;;
esac
for t in "${tools[@]}"; do command -v "$t" >/dev/null || { echo "build: missing tool $t" >&2; exit 2; }; done
if [[ $rid == win-* ]]; then
    command -v bison >/dev/null || command -v win_bison >/dev/null || { echo "build: missing tool win_bison" >&2; exit 2; }
    [[ -n ${VCToolsRedistDir:-} ]] || { echo "build: VCToolsRedistDir is unset; load vcvars64 first" >&2; exit 2; }
    # Git Bash's /usr/bin has a link.exe of its own, which meson would take for the linker.
    PATH="$(dirname "$(command -v cl)"):$PATH"
fi

tag="$PG_VERSION-$PACKAGE_REVISION"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Postgres installs a flat lib/ and share/ only when the prefix contains "postgres"; the random
# parent guarantees the prefix exists on no machine that later runs the archive.
prefix="$work/postgresql"
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }

curl -fsSL --retry 3 -o "$work/pg.tar.gz" "https://ftp.postgresql.org/pub/source/v$PG_VERSION/postgresql-$PG_VERSION.tar.gz"
[[ $(sha256 "$work/pg.tar.gz") == "$PG_SHA256" ]] || { echo "build: postgresql-$PG_VERSION.tar.gz digest mismatch" >&2; exit 1; }
tar -xzf "$work/pg.tar.gz" -C "$work"
git clone -q --depth 1 --branch "v$PGVECTOR_VERSION" https://github.com/pgvector/pgvector.git "$work/pgvector" 2>/dev/null
[[ $(git -C "$work/pgvector" rev-parse HEAD) == "$PGVECTOR_COMMIT" ]] || { echo "build: pgvector v$PGVECTOR_VERSION is not $PGVECTOR_COMMIT" >&2; exit 1; }
src="$work/postgresql-$PG_VERSION"

if [[ $rid == win-* ]]; then
    curl -fsSL --retry 3 -o "$work/zlib.tar.gz" "https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.gz"
    [[ $(sha256 "$work/zlib.tar.gz") == "$ZLIB_SHA256" ]] || { echo "build: zlib-$ZLIB_VERSION.tar.gz digest mismatch" >&2; exit 1; }
    tar -xzf "$work/zlib.tar.gz" -C "$work"
    (cd "$work/zlib-$ZLIB_VERSION" && nmake -nologo -f win32/Makefile.msc zlib.lib >"$work/zlib.log") \
        || { tail -30 "$work/zlib.log" >&2; exit 1; }
    zlib_dir=$(cygpath -w "$work/zlib-$ZLIB_VERSION")
    export INCLUDE="$zlib_dir;$INCLUDE" LIB="$zlib_dir;$LIB"

    # Of contrib, only pg_trgm, as the make build does.
    sed -i "/^subdir('/{/^subdir('pg_trgm')/!d}" "$src/contrib/meson.build"
    # The build's perl scripts pass /-style flags to MSVC tools, which Git Bash's own perl rewrites as paths.
    # Asked, not judged by path: on a runner Git's perl is on PATH as /c/Program Files/Git/usr/bin.
    perl=
    while read -r p; do
        if "$p" -e 'exit($^O eq "MSWin32" ? 0 : 1)'; then perl=$p; break; fi
    done < <(type -ap perl)
    [[ -n $perl ]] || { echo "build: needs a native Windows perl such as Strawberry Perl on PATH" >&2; exit 2; }
    flags=(--buildtype=release -Dauto_features=disabled -Dzlib=enabled -Dssl=none -Duuid=none)
    meson setup "$work/build" "$src" --prefix="$(cygpath -w "$prefix")" "${flags[@]}" -DPERL="$(cygpath -w "$perl")" >"$work/configure.log" \
        || { tail -30 "$work/configure.log" >&2; exit 1; }
    meson install -C "$work/build" --quiet >"$work/build.log" \
        || { grep -A20 -m3 '^FAILED' "$work/build.log" >&2 || tail -30 "$work/build.log" >&2; exit 1; }

    (cd "$work/pgvector" && PGROOT=$(cygpath -w "$prefix") nmake -nologo -f Makefile.win >/dev/null \
        && PGROOT=$(cygpath -w "$prefix") nmake -nologo -f Makefile.win install >/dev/null)
    exe=.exe
else
    flags=(--disable-rpath --without-icu --without-libxml --without-libxslt
        --without-openssl --without-readline --without-llvm --without-gssapi --without-ldap --with-zlib)
    if [[ $rid == osx-* ]]; then export MACOSX_DEPLOYMENT_TARGET; fi
    jobs=$(getconf _NPROCESSORS_ONLN)
    (cd "$src" && ./configure --prefix="$prefix" "${flags[@]}" >"$work/configure.log") || { tail -30 "$work/configure.log" >&2; exit 1; }
    make -C "$src" -j"$jobs" -s >/dev/null
    make -C "$src" install -s >/dev/null
    make -C "$src/contrib/pg_trgm" -j"$jobs" -s >/dev/null
    make -C "$src/contrib/pg_trgm" install -s >/dev/null

    vector_args=(PG_CONFIG="$prefix/bin/pg_config" OPTFLAGS=)
    if [[ $rid == osx-* ]]; then vector_args+=(PG_SYSROOT="$(xcrun --show-sdk-path)"); fi
    make -C "$work/pgvector" -j"$jobs" "${vector_args[@]}" >/dev/null
    make -C "$work/pgvector" install "${vector_args[@]}" >/dev/null
    exe=
fi

# Trim to what the local stack runs; pg_upgrade needs pg_dump, pg_dumpall, pg_restore, pg_resetwal.
pkg="$work/pkg"
mkdir -p "$pkg/bin" "$pkg/lib" "$pkg/share/licenses"
for b in postgres initdb pg_ctl pg_controldata pg_isready pg_dump pg_dumpall pg_restore pg_upgrade pg_resetwal psql; do
    cp -p "$prefix/bin/$b$exe" "$pkg/bin/"
done
(cd "$prefix/lib" && find . -maxdepth 1 \( -type f -o -type l \) \
    ! -name '*.a' ! -name '*.lib' ! -name '*.pdb' ! -name 'libecpg*' ! -name 'libpgtypes*' -exec cp -P {} "$pkg/lib/" \;)
cp -R "$prefix/share/." "$pkg/share/"
cp "$src/COPYRIGHT" "$pkg/share/licenses/postgresql-COPYRIGHT"
cp "$work/pgvector/LICENSE" "$pkg/share/licenses/pgvector-LICENSE"

if [[ $rid == win-* ]]; then
    # Windows looks for a DLL beside the executable first: libpq, and the VC++ runtime, which ships
    # here rather than as a system install that would need administrator rights.
    cp -p "$prefix/bin/libpq.dll" "$pkg/bin/"
    cp "$work/zlib-$ZLIB_VERSION/LICENSE" "$pkg/share/licenses/zlib-LICENSE"
    crt=$(compgen -G "$(cygpath -u "$VCToolsRedistDir")x64/Microsoft.VC*.CRT" | tail -1)
    [[ -n $crt ]] || { echo "build: no VC++ runtime under $VCToolsRedistDir" >&2; exit 1; }
    while read -r dll; do
        if [[ -f $crt/$dll ]]; then cp "$crt/$dll" "$pkg/bin/$dll"; fi
    done < <(find "$pkg/bin" "$pkg/lib" -type f \( -name '*.exe' -o -name '*.dll' \) -print0 \
        | xargs -0 -n1 cygpath -w | xargs -d '\n' dumpbin -nologo -dependents \
        | awk 'NF == 1 && tolower($1) ~ /\.dll$/ {print tolower($1)}' | sort -u)
elif [[ $rid == linux-* ]]; then
    while IFS= read -r -d '' f; do
        if readelf -h "$f" >/dev/null 2>&1; then strip --strip-unneeded "$f"; fi
    done < <(find "$pkg/bin" "$pkg/lib" -type f -print0)
    # shellcheck disable=SC2016 # $ORIGIN is the literal the dynamic loader expands
    for f in "$pkg"/bin/*; do patchelf --set-rpath '$ORIGIN/../lib' "$f"; done
else
    while IFS= read -r -d '' f; do
        file -b "$f" | grep -q 'Mach-O' || continue
        strip -x "$f" 2>/dev/null || true
        if [[ $f == "$pkg"/lib/*.dylib ]]; then
            install_name_tool -id "@loader_path/../lib/$(basename "$f")" "$f" 2>/dev/null
        fi
        while read -r dep; do
            if [[ $dep == "$prefix"/lib/* ]]; then
                install_name_tool -change "$dep" "@loader_path/../lib/$(basename "$dep")" "$f" 2>/dev/null
            fi
        done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
        # arm64 macOS kills an unsigned binary. strip and install_name_tool re-sign only what the
        # linker signed, so sign every file explicitly; the bundle step re-signs with Kurrent's identity.
        codesign --force -s - "$f" 2>/dev/null
    done < <(find "$pkg/bin" "$pkg/lib" -type f -print0)
fi

build_run=${GITHUB_RUN_ID:+$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID}
cat >"$pkg/kcap-postgres.json" <<EOF
{
  "version": "$tag",
  "rid": "$rid",
  "postgres": "$PG_VERSION",
  "pgvector": "$PGVECTOR_VERSION",
  "pgvector_commit": "$PGVECTOR_COMMIT",
  "configure": "${flags[*]}",
  "build_prefix": "$prefix",
  "build_run": "${build_run:-local}"
}
EOF

bash "$repo/scripts/check-deps.sh" "$pkg"
archive="$out/kcap-postgres-$tag-$rid.tar.gz"
tar -czf "$archive" -C "$pkg" bin lib share kcap-postgres.json
echo "$archive"
