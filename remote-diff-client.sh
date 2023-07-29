#!/usr/bin/env bash

# Should be invoked by `git mergetool` to start a diff on a remote machine.
# Interacts with a running `remote-diff-server`, via these fifos:
#
#   For requests: __REQUESTS__
#   For responses: __RESPONSES__

set -o errexit
set -o nounset

if [[ -n "__DEBUG__" ]]; then
  set -o xtrace
fi

base=$1
local=$2
remote=$3
merged=$4

requests="__REQUESTS__"
responses="__RESPONSES__"

exec 4>"$requests"

verifyIsSet() {
  local name=$1
  local value=$2
  local mustExist=$3

  if [[ -z "$value" ]]; then
    cat >&2 <<EOM
ERROR: "$name" must be set and be non-empty, but it is not.
EOM
    exit 1
  fi

  if [[ -n "$mustExist" && ! -e "$value" ]]; then
    cat >&2 <<EOM
ERROR: "$name" must point to an existing file, but it does not exist.
  \$$name: "$value"
EOM
    exit 1
  fi
}

echo "Setting up remote diff ..."

verifyIsSet 'base' "$base" yes
verifyIsSet 'local' "$local" yes
verifyIsSet 'remote' "$remote" yes
verifyIsSet 'merged' "$merged" ''

printf "diff:%s:%s:%s:%s\n" \
  "$( realpath "$base" )" \
  "$( realpath "$local" )" \
  "$( realpath "$remote" )" \
  "$( realpath "$merged" )" \
  >&4

exec 3<"$responses"
read -r -u 3 response || exit 1

case "$response" in
  success)
    echo "  ... successful merge"
    exit 0
    ;;

  exit:*)
    echo "  ... merge failed"
    exitCode=${response#exit:}
    exit "$exitCode"
    ;;

  end)
    echo "  ... diff terminated"
    exit 3
    ;;

  *)
    echo "  ... unexpected internal command"
    exit 4
    ;;
esac
