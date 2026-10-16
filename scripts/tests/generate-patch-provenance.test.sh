#!/usr/bin/env bash
# generate-patch-provenance.test.sh (TRIO-079)
#
# Runs scripts/generate-patch.sh end to end in a throwaway repo and checks the
# Trio-Patch-* provenance trailers it writes: auto-generated trailers (keys,
# base, tip, source commits, patch-ids), an explicit --message-trailers-file
# overriding them (also given as a relative path), tmp/ source branches getting
# none, and uncommitted worktree changes (-w) getting none. Also statically checks
# that the real mid-stack-update.sh / generate-patch.sh source the shared
# library and do not redefine its helpers.
#
# Run from Trio-dev:  bash scripts/tests/generate-patch-provenance.test.sh
# Needs no network (origin is a local bare repo) and touches only a mktemp dir,
# so it is safe in the Claude Code Bash sandbox. KEEP_TMP=1 keeps the scratch dir.

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_GP="$SCRIPTS_DIR/generate-patch.sh"
REAL_MSU="$SCRIPTS_DIR/mid-stack-update.sh"
REAL_LIB="$SCRIPTS_DIR/lib/patch-provenance.sh"

T=$(mktemp -d "${TMPDIR:-/tmp}/gp-provenance-test.XXXXXX")
cleanup() {
    if [ "${KEEP_TMP:-0}" = "1" ]; then
        echo "# KEEP_TMP=1: scratch dir kept at $T"
    else
        rm -rf "$T"
    fi
}
trap cleanup EXIT

# Hermetic git: no operator config, signing, or hooks.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Provenance Test"
export GIT_AUTHOR_EMAIL="prov-test@example.invalid"
export GIT_COMMITTER_NAME="Provenance Test"
export GIT_COMMITTER_EMAIL="prov-test@example.invalid"

g() { git -c commit.gpgsign=false "$@"; }

TESTNUM=0
FAILS=0
ok() { TESTNUM=$((TESTNUM + 1)); echo "ok $TESTNUM - $1"; }
not_ok() {
    TESTNUM=$((TESTNUM + 1)); FAILS=$((FAILS + 1))
    echo "not ok $TESTNUM - $1${2:+ ($2)}"
}
check() { # check <name> <reason-on-fail> <command...>
    local name="$1" reason="$2"; shift 2
    if "$@"; then ok "$name"; else not_ok "$name" "$reason"; fi
}

for f in "$REAL_GP" "$REAL_LIB"; do
    if [ ! -f "$f" ]; then
        echo "Bail out! missing $f" >&2
        exit 1
    fi
done

# --- fixture -----------------------------------------------------------------
R="$T/Trio-dev"
ORIGIN="$T/origin.git"
git init -q --bare -b dev "$ORIGIN"
mkdir -p "$R/scripts/lib"
cd "$R"
git init -q -b dev
git remote add origin "$ORIGIN"
cp "$REAL_GP" scripts/generate-patch.sh
cp "$REAL_LIB" scripts/lib/patch-provenance.sh
chmod +x scripts/generate-patch.sh
echo "base" > a.txt
git add -A
g commit -q -m "initial"
git push -q origin dev

git checkout -q -b feature/prov-test
echo "changed" >> a.txt
g commit -q -am "modify a"
echo "b" > b.txt
git add b.txt
g commit -q -m "add b"
git checkout -q -b side
echo "c" > c.txt
git add c.txt
g commit -q -m "add c on side"
git checkout -q feature/prov-test
g merge -q --no-ff side -m "merge side into feature"
g commit -q --allow-empty -m "empty tip"
git branch -q -D side
git checkout -q dev

# Expected values, computed independently of the script under test.
MB=$(git merge-base dev feature/prov-test)
TIP=$(git rev-parse feature/prov-test)
ALL_SHAS=$(git rev-list "$MB..$TIP")
EXP_IDS=""
for sha in $(git log --reverse --no-merges --format=%H "$MB..$TIP"); do
    id=$(git show --no-color "$sha" | git patch-id --stable | awk '{print $1}' | head -1 || true)
    [ -n "$id" ] || continue
    EXP_IDS="${EXP_IDS:+$EXP_IDS
}$id"
done

# shellcheck source=/dev/null
. "$REAL_LIB"

trailer_count() { grep -c "^$2:" "$1" || true; }
trailer_value() { sed -n "s/^$2: *//p" "$1" | head -1; }

# run_gp <log> <args...>: run generate-patch.sh in the scratch repo, tail log on failure.
run_gp() {
    local log="$1"; shift
    if ./scripts/generate-patch.sh -n --all-files -d prov "$@" >"$log" 2>&1; then
        return 0
    fi
    echo "# generate-patch.sh failed; log tail ($log):"
    tail -n 20 "$log" | sed 's/^/#   /'
    return 1
}

# --- case 1: auto provenance -------------------------------------------------
P1="$T/auto.patch"
if run_gp "$T/run1.log" -s feature/prov-test -t dev -o "$P1" && [ -s "$P1" ]; then
    ok "auto provenance: generate-patch.sh exits 0 and writes the patch"
else
    not_ok "auto provenance: generate-patch.sh exits 0 and writes the patch" "see log tail above"
fi
[ -f "$P1" ] || : > "$P1"  # keep later reads safe if generation failed

for key in Trio-Patch-Source-Branch Trio-Patch-Base Trio-Patch-Feature-Tip \
           Trio-Patch-Generated Trio-Patch-Source-Commits Trio-Patch-PatchIds-Note \
           Trio-Patch-Source-PatchIds; do
    n=$(trailer_count "$P1" "$key")
    check "auto provenance: $key appears exactly once" "found $n" [ "$n" = "1" ]
done

v=$(trailer_value "$P1" Trio-Patch-Source-Branch)
check "auto provenance: Source-Branch is feature/prov-test" "got '$v'" [ "$v" = "feature/prov-test" ]
v=$(trailer_value "$P1" Trio-Patch-Base)
check "auto provenance: Base equals merge-base" "got '$v' want '$MB'" [ "$v" = "$MB" ]
v=$(trailer_value "$P1" Trio-Patch-Feature-Tip)
check "auto provenance: Feature-Tip equals tip" "got '$v' want '$TIP'" [ "$v" = "$TIP" ]

missing=""
for sha in $ALL_SHAS; do
    grep -q "^ $sha" "$P1" || missing="$missing $sha"
done
check "auto provenance: Source-Commits lists every sha in merge-base..tip (merge and empty included)" \
    "missing:${missing}" [ -z "$missing" ]

errf="$T/ids.err"
got_ids=$(_recorded_patch_ids "$P1" 2>"$errf" || true)
check "auto provenance: _recorded_patch_ids prints the expected ids in order" \
    "got '$got_ids' want '$EXP_IDS'" [ "$got_ids" = "$EXP_IDS" ]
n=$(printf '%s\n' "$got_ids" | grep -c . || true)
check "auto provenance: _recorded_patch_ids prints 3 ids" "got $n" [ "$n" = "3" ]
check "auto provenance: _recorded_patch_ids writes nothing to stderr" \
    "stderr: $(cat "$errf")" [ ! -s "$errf" ]
v=$(_recorded_source_branch "$P1" 2>/dev/null || true)
check "auto provenance: _recorded_source_branch prints feature/prov-test" "got '$v'" [ "$v" = "feature/prov-test" ]

WT="$T/apply-wt"
if git worktree add -q --detach "$WT" dev >/dev/null 2>&1 \
   && (cd "$WT" && g am -q "$P1" >"$T/am.log" 2>&1); then
    ok "auto provenance: patch applies with git am on a fresh dev worktree"
else
    not_ok "auto provenance: patch applies with git am on a fresh dev worktree" "$(tail -n 3 "$T/am.log" 2>/dev/null || true)"
fi
git worktree remove --force "$WT" >/dev/null 2>&1 || true

# --- case 2: explicit trailers file wins -------------------------------------
TF="$T/trailers.txt"
printf 'Trio-Patch-Source-Branch: custom/branch\nX-Test-Trailer: 1\n' > "$TF"
P2="$T/explicit.patch"
run_gp "$T/run2.log" -s feature/prov-test -t dev -o "$P2" --message-trailers-file "$TF" || true
[ -f "$P2" ] || : > "$P2"
check "explicit trailers: patch contains Source-Branch: custom/branch" "line absent" \
    grep -q '^Trio-Patch-Source-Branch: custom/branch$' "$P2"
check "explicit trailers: patch contains X-Test-Trailer: 1" "line absent" \
    grep -q '^X-Test-Trailer: 1$' "$P2"
check "explicit trailers: no auto Trio-Patch-Base: line" "line present" \
    sh -c '! grep -q "^Trio-Patch-Base:" "$1"' _ "$P2"

# --- case 2b: relative trailers file ----------------------------------------
cp "$TF" ./rel-trailers.txt
P2B="$T/relative.patch"
run_gp "$T/run2b.log" -s feature/prov-test -t dev -o "$P2B" --message-trailers-file rel-trailers.txt || true
rm -f ./rel-trailers.txt
[ -f "$P2B" ] || : > "$P2B"
check "relative trailers file: patch contains X-Test-Trailer: 1" "line absent" \
    grep -q '^X-Test-Trailer: 1$' "$P2B"

# --- case 3: tmp/ source gets none -------------------------------------------
git branch -q tmp/prov-test "$TIP"
P3="$T/tmp-source.patch"
run_gp "$T/run3.log" -s tmp/prov-test -t dev -o "$P3" || true
[ -f "$P3" ] || : > "$P3"
check "tmp/ source: patch was generated" "patch missing or empty" [ -s "$P3" ]
check "tmp/ source: no line starting with Trio-Patch-" "trailer present" \
    sh -c '! grep -q "^Trio-Patch-" "$1"' _ "$P3"

# --- case 3b: worktree changes included get none ----------------------------
git checkout -q feature/prov-test
echo "uncommitted-line" >> a.txt
P3B="$T/worktree.patch"
run_gp "$T/run3b.log" -s feature/prov-test -t dev -w -o "$P3B" || true
[ -f "$P3B" ] || : > "$P3B"
check "worktree changes included gets none: patch was generated" "patch missing or empty" [ -s "$P3B" ]
check "worktree changes included gets none: patch contains the uncommitted line" "uncommitted line missing" \
    grep -q 'uncommitted-line' "$P3B"
check "worktree changes included gets none: worktree path was taken" "no worktree diff in log" \
    grep -q 'includes staged+unstaged on feature/prov-test' "$T/run3b.log"
check "worktree changes included gets none: provenance skip is reported" "no skip warning in log" \
    grep -q 'Provenance not recorded: the patch includes uncommitted worktree changes' "$T/run3b.log"
check "worktree changes included gets none: no line starting with Trio-Patch-" "trailer present" \
    sh -c '! grep -q "^Trio-Patch-" "$1"' _ "$P3B"
git checkout -- a.txt
git checkout -q dev

# --- case 4: static checks against the real scripts --------------------------
for f in "$REAL_MSU" "$REAL_GP"; do
    b=$(basename "$f")
    check "static: $b sources lib/patch-provenance.sh" "no source line" \
        grep -Eq '^[[:space:]]*(source|\.)[[:space:]].*lib/patch-provenance\.sh' "$f"
    check "static: $b does not define _patch_id() or _recorded_patch_ids()" "definition found" \
        sh -c '! grep -Eq "^(_patch_id|_recorded_patch_ids)\(\)" "$1"' _ "$f"
done

echo "# $((TESTNUM - FAILS))/$TESTNUM passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
