"""设置专用 Cassandra 5.0.5 容器的协议、认证与线程预算。"""

import json
import os
from pathlib import Path
import re

authenticator = os.environ.get("CQL_AUTHENTICATOR", "AllowAllAuthenticator")
assert authenticator in ("AllowAllAuthenticator", "PasswordAuthenticator")
path = Path("/etc/cassandra/cassandra.yaml")
text = path.read_text(encoding="utf-8")
settings = {
    "native_transport_allow_older_protocols": False,
    "authenticator": authenticator,
    "concurrent_reads": 4,
    "concurrent_writes": 4,
    "concurrent_counter_writes": 4,
    "concurrent_materialized_view_writes": 4,
    "native_transport_max_threads": 16,
    "memtable_flush_writers": 1,
    "concurrent_compactors": 1,
}
for name, value in settings.items():
    line = name + ": " + json.dumps(value)
    if re.search("^" + name + ":", text, re.M):
        text = re.sub("^" + name + ":.*$", line, text, flags=re.M)
    else:
        text += "\n" + line + "\n"
path.write_text(text, encoding="utf-8", newline="\n")
