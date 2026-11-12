#!/bin/bash
# Tests the scan gate's settings reader, which once turned every false into true.
set -euo pipefail
cd "$(dirname "$0")/.."

config=$(mktemp)
trap 'rm -f "$config"' EXIT
# Take just the function out of the script; the rest needs a PAM session.
eval "$(sed -n '/^setting() {$/,/^}$/p' system/lock-gate)"
[[ $(type -t setting) == function ]] || { echo "setting() not found in lock-gate"; exit 1; }

check() {
  local got
  printf '%s' "$1" >"$config"
  got=$(setting "$2" "$3")
  [[ $got == "$4" ]] || { echo "FAIL: config=$1 key=$2 default=$3: got '$got', want '$4'"; exit 1; }
}

check '{"requireAttention":false}' requireAttention true false
check '{"requireAttention":true}'  requireAttention true true
check '{}'                         requireAttention true true
check '{"requireAttention":null}'  requireAttention true true
check 'not json'                   requireAttention true true
check '[1,2]'                      requireAttention true true
check '{"graceSeconds":0}'         graceSeconds 7 0
check '{"graceSeconds":12}'        graceSeconds 7 12
check '{}'                         graceSeconds 7 7
# No config file at all.
rm -f "$config"
[[ $(setting graceSeconds 7) == 7 && $(setting requireAttention true) == true ]] || { echo "FAIL: missing file"; exit 1; }
echo "lock-gate settings: ok"
