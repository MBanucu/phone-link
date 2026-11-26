#!/usr/bin/env python3
"""Render the running sing-box config from the store template.

The store config has placeholders for the three things that change at run time:
the host the toggle found reachable, the port the panel chose, and the password
from the root-only secrets file. Reading the template as JSON keeps the
password off the command line and any character in it intact; the result is
root-only.

    phone-tun-config.py TEMPLATE TARGET PORT_FILE HOST_FILE \
        FALLBACK_HOST FALLBACK_PORT HOST...

PHONE_SOCKS_PASS must be in the environment (the unit's EnvironmentFile).
"""

import json
import os
import sys
import tempfile


def main(argv):
    if len(argv) < 7:
        sys.stderr.write(__doc__)
        return 2
    template, target, port_file, host_file = argv[1:5]
    fallback_host = argv[5]
    fallback_port = int(argv[6])
    hosts = argv[7:]

    try:
        with open(port_file, encoding="utf-8") as f:
            port = int(f.read().strip())
    except (OSError, ValueError):
        port = fallback_port
    if not 0 < port < 65536:
        port = fallback_port

    try:
        with open(host_file, encoding="utf-8") as f:
            host = f.read().strip()
    except OSError:
        host = fallback_host
    if host not in hosts:
        host = fallback_host

    password = os.environ["PHONE_SOCKS_PASS"]

    with open(template, encoding="utf-8") as f:
        config = json.load(f)
    for outbound in config["outbounds"]:
        if outbound.get("tag") == "phone":
            outbound["server"] = host
            outbound["server_port"] = port
            outbound["password"] = password

    directory = os.path.dirname(target)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".config.", dir=directory)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(config, f, indent=2)
            f.write("\n")
        os.replace(tmp, target)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
