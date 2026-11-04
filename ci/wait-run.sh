#!/bin/sh
# wait-run.sh <run-id> [interval-seconds]: waits until the GitHub Actions run ends (at most six hours,
# polling every interval-seconds, default 30), then prints its conclusion and, for each failed job, only
# the failure report of its log: the test runner's `failures:` block and tally, or the `error:`, FAILED,
# panic and assertion lines when the job failed outside the tests. Start it in the background and keep
# working; its exit is the notification. Exit status: 0 when the run succeeded, 1 when it ended in any
# other way, 2 on a usage error, an unknown run, a wait past six hours, or five failed `gh` calls in a row.
set -u
[ $# -ge 1 ] && [ $# -le 2 ] || { echo "usage: sh ci/wait-run.sh <run-id> [interval-seconds]" >&2; exit 2; }
run=$1
interval=${2:-30}
case $interval in '' | *[!0-9]* | 0) echo "wait-run: interval must be a positive number of seconds" >&2; exit 2 ;; esac
polls=$((6 * 3600 / interval))
errors=0
while :; do
    if status=$(gh run view "$run" --json status --jq .status 2>&1); then
        errors=0
        [ "$status" = completed ] && break
    else
        case $status in *"HTTP 404"*) echo "wait-run: no run $run: $status" >&2; exit 2 ;; esac
        errors=$((errors + 1))
        [ $errors -lt 5 ] || { echo "wait-run: gh run view $run failed 5 times: $status" >&2; exit 2; }
    fi
    polls=$((polls - 1))
    [ $polls -gt 0 ] || { echo "wait-run: run $run did not end within six hours" >&2; exit 2; }
    sleep "$interval"
done

summary=$(gh run view "$run" --json conclusion,workflowName,headBranch,url \
    --jq '"\(.conclusion)\t\(.workflowName) on \(.headBranch): \(.conclusion) \(.url)"') || exit 2
conclusion=${summary%%"	"*}
echo "${summary#*"	"}"
[ "$conclusion" = success ] && exit 0

gh run view "$run" --json jobs \
    --jq '.jobs[] | select(.conclusion != "success" and .conclusion != "skipped") | "job: \(.name): \(.conclusion)"' || exit 2
# --log-failed prints "job<TAB>step<TAB>timestamp line". Per job, keep the first `failures:` block up to
# `slowest tests:`; without one, keep the error lines. Both at most 80 lines per job, plus the tally.
gh run view "$run" --log-failed | awk -F '\t' '
function flush() {
    if (job == "") return
    print "== " job
    if (nb > 0) for (i = 1; i <= nb; i++) print block[i]
    else for (i = 1; i <= ne; i++) print errs[i]
    if (tally != "") print tally
}
{
    line = $0
    sub(/^[^\t]*\t[^\t]*\t/, "", line)
    sub(/^\357\273\277/, "", line)
    sub(/^[0-9-]+T[0-9:.]+Z /, "", line)
    gsub(/\033\[[0-9;]*m/, "", line)
    if ($1 != job) { flush(); job = $1; nb = 0; ne = 0; tally = ""; state = 0 }
    if (line ~ /^[0-9]+ passed, [0-9]+ failed/) tally = line
    if (state == 0 && line == "failures:") state = 1
    if (state == 1 && line ~ /^slowest tests:/) state = 2
    if (state == 1 && nb < 80) block[++nb] = line
    if (line ~ /error:|FAILED|panicked|^panic|assertion failed|timed out/ && ne < 80) errs[++ne] = line
}
END { flush() }' || exit 2
exit 1
