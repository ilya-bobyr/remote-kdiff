#!/usr/bin/env bash

# Run this script locally, to setup a remote diff on a target machine that needs
# to have an ssh access with a pre-shared key.  Machine name is the only
# argument.

target=$1
shift

# Directory where the `remote-diff` executable will reside.
# "~/.local/bin/remote-diff", but "~/" is expanded on the remote machine.
remoteDiff=

# ---

set -o errexit
set -o nounset

if [[ -z "$target" ]]; then
  cat >&2 <<EOM
You need to specify a target machine as the first argument.
EOM
  exit 2
fi

debug=
if [[ $# -gt 0 && "$1" = "--debug" ]]; then
  debug=yes
  shift
  set -o xtrace
fi

here=$(realpath "$(dirname "${BASH_SOURCE[0]}")")

scratchDir=$( mktemp --tmpdir --directory remote-diff.XXXXX )

# FIFO form the ssh process
fromRemote="$scratchDir/from-remote"
mkfifo "$fromRemote"
# FIFO to the ssh process
toRemote="$scratchDir/to-remote"
mkfifo "$toRemote"
# SSH process id
sshPid=

# Location of the remote-diff-server on the remote machine
remoteDiffDir=

# Location of the client to server FIFO on the remote machine
remoteRequests=
# Location of the server to client FIFO on the remote machine
remoteResponses=

cleanup() {
  set +o errexit

  echo "Cleaning up..."

  exec 3>&-
  exec 4>&-

  if [[ -e "$toRemote" ]]; then
    bash -c 'printf "%s\n" end >"'"$toRemote"'"' &
    printEndPid=$!
    sleep 1s
    kill "$printEndPid" >/dev/null 2>&1
  fi
  if [[ -n "$sshPid" ]]; then
    kill "$sshPid" >/dev/null 2>&1
    wait -f "$sshPid"
  fi

  if [[ -n "$remoteDiffDir" ]]; then
    ssh "$target" "rm -rf '$remoteDiffDir' >/dev/null 2>&1"
  fi
  if [[ -n "$remoteDiff" ]]; then
    ssh "$target" "rm -f '$remoteDiff' >/dev/null 2>&1"
  fi

  if [[ -n "$scratchDir" ]]; then
    rm -rf "$scratchDir" >/dev/null 2>&1
  fi

  echo "  ... cleanup done"
}
trap cleanup EXIT

setupRemoteServer() {
  echo "Setting up remote diff server..."

  remoteDiffDir=$( 
      ssh "$target" "mktemp --tmpdir --directory remote-diff.XXXXX" 
    )
  scp -q "${here}/remote-diff-server.sh" \
    "$target:$remoteDiffDir/remote-diff-server"

  if [[ -z "$debug" ]]; then
    ssh "$target" bash -- "'$remoteDiffDir/remote-diff-server'" \
      <"$toRemote" >"$fromRemote" &
    sshPid=$!
  else
    ssh "$target" bash -- "'$remoteDiffDir/remote-diff-server'" --debug \
      <"$toRemote" >"$fromRemote" &
    sshPid=$!
  fi

  exec 4>"$toRemote"
  # ssh is waiting for some data on the standard input.
  printf "" >&4

  exec 3<"$fromRemote"

  local waitForMax=10
  local waitFor=$waitForMax
  while true; do
    if read -r -u 3 -t 3 remoteRequests; then
      break
    fi

    if [[ "$waitFor" -lt 1 ]]; then
      cat >&2 <<EOM
ERROR: Remote server did open the output channel in $waitForMax seconds.
EOM
    exit 1
    fi

    echo "  waiting for the server to start [${waitFor}s left maximum]"
    waitFor=$(( waitFor - 1 ))
    sleep 1s
  done

  if [[ "${remoteRequests}" != requests:* ]]; then
    cat >&2 <<EOM
ERROR: Remote server did not send expected "requests:" message.
  Got: "$remoteRequests"
EOM
    exit 1
  fi
  remoteRequests=${remoteRequests#requests:}

  if ! read -r -u 3 -t 3 remoteResponses; then
    cat >&2 <<EOM
ERROR: Failed when trying to read remote server "responses:" message.
EOM
    exit 1
  fi
  if [[ "${remoteResponses}" != responses:* ]]; then
    cat >&2 <<EOM
ERROR: Remote server did not send expected "responses:" message.
  Got: "$remoteResponses"
EOM
    exit 1
  fi
  remoteResponses=${remoteResponses#responses:}

  echo "  ... done with remote diff server"
}

setupRemoteClient() {
  echo "Setting up remote diff client..."

  remoteDiff=$( ssh "$target" "realpath ~/.local/bin/remote-diff" )

  if [[ -n "$( ssh "$target" "test -e '$remoteDiff' && echo exists" )" ]]; then
    cat >&2 <<EOM
ERROR: Remote machine "$target" already has "$remoteDiff"
EOM
    exit 1
  fi

  ssh "$target" "mkdir -p '""$( dirname "$remoteDiff" )""'"
  sed --expression='
      s@__DEBUG__@'"$debug"'@g
      s@__REQUESTS__@'"$remoteRequests"'@g
      s@__RESPONSES__@'"$remoteResponses"'@g
    ' "${here}/remote-diff-client.sh" \
    | ssh "$target" "cat >'$remoteDiff'"
  ssh "$target" "chmod +x '$remoteDiff'"

  echo "  ... done with remote diff client"
}

mainLoop() {
  local base local remote merged exitCode

  echo "Ready for diffs"

  while true; do
    read -r -u 3 request || break

    case "$request" in
      diff:*)
        request=${request#diff:}

        base=${request%%:*}
        request=${request#*:}

        local=${request%%:*}
        request=${request#*:}

        remote=${request%%:*}
        merged=${request#*:}

        echo "Fetching files for comparison..."
        scp -q "$target:$base" "$scratchDir/base"
        scp -q "$target:$local" "$scratchDir/local"
        scp -q "$target:$remote" "$scratchDir/remote"
        scp -q "$target:$merged" "$scratchDir/merged"
        echo "  ... fetched all files"

        set +o errexit
        kdiff3 --out "$scratchDir/merged" \
          --L1 base --L2 local --L3 remote \
          "$scratchDir/base" "$scratchDir/local" "$scratchDir/remote"
        exitCode=$?
        set -o errexit

        if [[ $exitCode -eq 0 ]]; then
          echo "Copying result of a successful merge..."
          scp -q "$scratchDir/merged" "$target:$merged"
          printf "success\n" >&4
          echo "  ... done"
        else
          printf "exit:%s\n" "$exitCode" >&4
        fi
        ;;

      *)
        cat >&2 <<EOM
ERROR: Unexpected request from client.
  Command: [$request]
EOM
        printf "end\n" >&4
        exit 2
      ;;
    esac
  done

  echo "Shutting down ..."
}

setupRemoteServer
setupRemoteClient
mainLoop
