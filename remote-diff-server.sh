#!/usr/bin/env bash

# Sent to the remote machine and started in an ssh session.
# Listens to remote-diff-client.sh requests, sending queries back to the local
# machine for execution.

set -o errexit
set -o nounset

if [[ $# -gt 0 && "$1" = "--debug" ]]; then
  shift
  set -o xtrace
  exec 2>/tmp/remote-diff.log
fi

# It is expected to be started in a temporary folder.
here=$(realpath "$(dirname "${BASH_SOURCE[0]}")")

fifoDir=${XDG_CACHE_HOME:-$HOME/.cache}/remote-diff

mkdir -p $fifoDir
requests=$( mktemp --dry-run "$fifoDir"/requests.XXXXX )
mkfifo "$requests"
responses=$( mktemp --dry-run "$fifoDir"/responses.XXXXX )
mkfifo "$responses"

cleanup() {
  if [[ -n "$requests" && -e "$requests" ]]; then
    rm -f "$requests" >/dev/null 2>&1
  fi
  if [[ -n "$responses" && -e "$responses" ]]; then
    rm -f "$responses" >/dev/null 2>&1
  fi
  if [[ -n "$fifoDir" && -e "$fifoDir" ]]; then
    rm -d "$fifoDir" >/dev/null 2>&1
  fi
}
trap cleanup EXIT

printf "requests:%s\n" "$requests"
printf "responses:%s\n" "$responses"

# Process multiple request/response pairs.
while true; do

  # Process a single request/response pair.
  while true; do
    exec 3<"$requests"
    read -r -u 3 request || break
    printf '%s\n' "$request"
    if [[ "$request" = "end" ]]; then
      exit 0
    fi

    exec 4>"$responses"
    read -r response || break
    printf '%s\n' "$response" >&4
    if [[ "$response" = "end" ]]; then
      exit 0
    fi

    break
  done
done
