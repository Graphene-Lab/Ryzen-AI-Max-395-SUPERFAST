#!/usr/bin/env python3
"""Run one read-only command on the Fedora host over SSH.

`ssh` reads the password from the terminal and this PC has no sshpass, so the
connection goes through paramiko with the password taken from SSHPW. The login
account is `user`; the command is wrapped in `bash -lc` so the login PATH finds
the local tools.

    SSHPW=... python tools/host-run.py 'systemctl --user list-units "superfast*"'
"""

import os
import shlex
import sys

import paramiko


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help"):
        sys.stdout.write(__doc__)
        return 0
    if not os.environ.get("SSHPW"):
        sys.stderr.write("SSHPW is not set: the host takes a password, not a key\n")
        return 2
    cmd = " ".join(sys.argv[1:]) or sys.stdin.read()
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(os.environ.get("HOST", "192.168.43.253"), username="user",
                   password=os.environ["SSHPW"], timeout=15,
                   allow_agent=False, look_for_keys=False)
    _, out, err = client.exec_command("bash -lc " + shlex.quote(cmd), timeout=120)
    sys.stdout.write(out.read().decode("utf-8", "replace"))
    sys.stderr.write(err.read().decode("utf-8", "replace"))
    code = out.channel.recv_exit_status()
    client.close()
    return code


if __name__ == "__main__":
    sys.exit(main())
