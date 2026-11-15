#!/bin/sh
# bounded.sh SECONDS COMMAND [ARGS...]
#
# Runs COMMAND in a process group of its own and kills that whole group when COMMAND exits, when
# this script is interrupted, or after SECONDS, whichever comes first. Exits with COMMAND's status,
# or 124 on the time limit (as coreutils timeout does).
#
# Why: tlapm finds its prover children with ps, and the agent sandbox denies process listing, so a
# timed-out z3 outlived tlapm and held the owner's RAM until killed by hand (2026-10-24; Isabelle's
# poly did the same on 2026-10-23). Killing a process group needs no listing. The watchdog is a
# group of its own too, and checks every 2 seconds that this script is still alive: if this script
# is killed with SIGKILL (its agent or session died), the watchdog kills COMMAND's group at once
# instead of at the time limit (2026-10-25: a TLC and a z3 outlived their killed sessions).
set -m
[ $# -ge 2 ] || { echo 'usage: bounded.sh SECONDS COMMAND [ARGS...]' >&2; exit 2; }
limit=$1; shift
mark=$(mktemp "${TMPDIR:-/tmp}/bounded.XXXXXX") || exit 2
rm -f "$mark"
self=$$

"$@" &
pid=$!
(
	waited=0
	while [ "$waited" -lt "$limit" ]; do
		sleep 2
		waited=$((waited + 2))
		if ! kill -0 "$self" 2>/dev/null; then
			kill -TERM -"$pid" 2>/dev/null
			sleep 5
			kill -KILL -"$pid" 2>/dev/null
			exit 0
		fi
	done
	: > "$mark"
	echo "bounded.sh: $1 still running after ${limit}s, killing its process group" >&2
	kill -TERM -"$pid" 2>/dev/null
	sleep 5
	kill -KILL -"$pid" 2>/dev/null
) &
dog=$!

reap() {
	kill -TERM -"$pid" 2>/dev/null
	sleep 1
	kill -KILL -"$pid" 2>/dev/null
	kill -TERM -"$dog" 2>/dev/null
}
trap 'reap; exit 130' INT
trap 'reap; exit 143' TERM HUP

wait "$pid"
status=$?
# COMMAND is gone; anything it left behind in its group (a timed-out prover) goes now.
reap
wait "$dog" 2>/dev/null
if [ -e "$mark" ]; then
	rm -f "$mark"
	exit 124
fi
exit "$status"
