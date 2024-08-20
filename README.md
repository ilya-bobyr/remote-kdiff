# Remote kdiff3

A helper to run a diff that happens on a remote machine, via a kdiff3 on a local
machine.  X11 forwarding is horribly slow, especially on a high resolution
screen.  So, instead, I want to run kdiff3 locally, but update original files
and push the exit code back to the remote machine.

Make sure that you are using `ControlMaster`, `ControlPath` and `ControlPersist`
in your `.ssh/config` for the remote connection.  As the scripts are not really
optimized for the ssh connection usage and open a lot of connections.

## One time setup

### git config

Add this to your `~/.gitconfg` on the remote machine:

```gitconfig
[mergetool.remote-diff]
    cmd = remote-diff "$BASE" "$LOCAL" "$REMOTE" "$MERGED"
    trustExitCode = true
```

### `$PATH`

Make sure `~/.local/bin` is in `$PATH` on your remote machine.

### ssh keys

The script needs to be able to connect from your local machine to your remote
machine without any interactive operations.

Make sure `ssh <remote> "echo test"` just prints `"test"` and nothing else.

### kdiff3

Make sure `kdiff3` is installed and can be invoked as `kdiff3`.

## Usage

1. Run `./local-diff-server.sh <remote>` on your local machine in a separate
   console.  It establishes the remote connection and must be running for the
   remote diff operation to work.

2. Run a `git` operation on the remote machine that requires conflict
   resolution.

3. Use `git mergetool --tool=remote-diff`.  It should show `kdiff3` on your
   local machine.

   Currently, it may take up to a few seconds to set it up and a few seconds to
   send updated file back.

4. When finished with all diffs, press Ctrl+C in the `local-diff-server.sh`
   console, to allow the script to clean up everything and shutdown.

## TODO

 * Would it make sense for the script to just always use a dedicated control
   connection for ssh.  Rather than both sharing it with the default
   configuration and requiring a default configuration?

 * Add Nix configuration.
