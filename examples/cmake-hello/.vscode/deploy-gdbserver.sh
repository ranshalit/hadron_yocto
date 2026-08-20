#!/usr/bin/env bash
# Copy the freshly built unstripped binary to the board and start gdbserver in
# the FOREGROUND on :PORT. Foreground streams "Listening on port ..." back to
# the VS Code terminal so the debugger knows when to attach.
#
# Args: <ip> <user> <password> <port> <appBinary>
set -euo pipefail

IP="${1:?device ip}"
USER="${2:?device user}"
PASS="${3:?device password}"
PORT="${4:-1234}"
APP="${5:?app binary name}"

SSH="sshpass -p ${PASS} ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SCP="sshpass -p ${PASS} scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Kill any stale gdbserver (and its inferior) so nothing keeps the old binary
# running or holds the port.
echo "==> Stopping any stale gdbserver on :${PORT}"
${SSH} "${USER}@${IP}" "pkill -9 -f 'gdbserver :${PORT}' 2>/dev/null; exit 0"

# Copy to a temp file then atomically rename. A running process may still hold
# the old binary's inode, but rename() over it always succeeds (no "Text file
# busy"); the new file is a fresh inode.
echo "==> Copying build/${APP} to ${USER}@${IP}"
${SCP} "build/${APP}" "${USER}@${IP}:~/.${APP}.new"
${SSH} "${USER}@${IP}" "mv -f ~/.${APP}.new ~/${APP}"

echo "==> Starting gdbserver :${PORT} on device (foreground)"
# Wait for the port to stop LISTENing (a just-killed server can linger a moment),
# then exec gdbserver in the foreground so its "Listening on port ..." line
# streams straight to the VS Code terminal.
#
# -tt forces a PTY: when VS Code ends this task the ssh session closes and the
# remote gdbserver receives SIGHUP and exits cleanly, freeing the port for the
# next F5 (otherwise it orphans and the next run hits "Address already in use").
${SSH} -tt "${USER}@${IP}" "
  for i in \$(seq 1 15); do
    ss -ltn 2>/dev/null | grep -q ':${PORT} ' || break
    echo '   port :${PORT} still busy, waiting...'; sleep 1;
  done
  exec gdbserver :${PORT} ./${APP}
"
