#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the bitstreams on the project's Vivado CI runner instead of
# locally: push the current branch, run the fpga workflow for this commit
# (a push to main starts one by itself), wait, download the results.
#
#   scripts/ci-build.sh      (or: make ci)
#   -> build/ci/websdr_{hf,vhf}.bit, timing_*.txt, utilization_*.txt, SHA256SUMS
#
# Needs gh (logged in) and push access. CI builds the pushed commit, so
# commit first.
set -eu
top=$(git rev-parse --show-toplevel)
cd "$top"
if [ -n "$(git status --porcelain -- fpga)" ]; then
    echo "fpga/ has uncommitted changes; CI builds the pushed commit, commit first" >&2
    exit 1
fi
branch=$(git rev-parse --abbrev-ref HEAD)
sha=$(git rev-parse HEAD)
git push -q origin "HEAD:refs/heads/$branch"

run_for_commit() {
    gh run list --workflow fpga.yml --branch "$branch" --commit "$sha" -L 1 \
        --json databaseId -q '.[0].databaseId // empty'
}
id=
# a push to main with fpga/ changes starts a run by itself
for _ in 1 2 3 4 5 6; do
    id=$(run_for_commit)
    [ -n "$id" ] && break
    sleep 3
done
if [ -z "$id" ]; then
    gh workflow run fpga.yml --ref "$branch"
    while [ -z "$id" ]; do sleep 3; id=$(run_for_commit); done
fi
echo "CI run: $(gh run view "$id" --json url -q .url)"
st=0
gh run watch "$id" --exit-status >/dev/null || st=$?
out=fpga/build/ci
rm -rf "$out"
if gh run download "$id" -n bitstreams -D "$out" 2>/dev/null; then
    cat "$out/wns.txt" 2>/dev/null || true
    if grep -q "expires on" "$out/licence.txt" 2>/dev/null; then
        printf '\n*** %s ***\n\n' "$(cat "$out/licence.txt")" >&2
    fi
    ls -l "$out"
else
    echo "no bitstreams from run $id (status $st): gh run view $id --log-failed" >&2
fi
exit "$st"
