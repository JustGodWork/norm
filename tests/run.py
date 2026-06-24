#!/usr/bin/env python3
"""Run the Norm self-test against the BUILT bundle with real Lua 5.4 (via lupa).

    pip install lupa
    python build via:  (any lua) lua build.lua
    python tests/run.py

Loads, in order, exactly like a host would: light-class.lua then dist/norm.lua
(no host `require` involved), then the self-test.
"""
import os, sys

try:
    from lupa import lua54 as lupa
except ImportError:
    sys.exit("This runner needs lupa with Lua 5.4: pip install lupa")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))

lua = lupa.LuaRuntime(unpack_returned_tuples=True)
load = lua.globals().load


def run_file(path, name):
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()
    res = load(src, "@" + name)
    chunk = res[0] if isinstance(res, tuple) else res
    if chunk is None:
        sys.exit(f"LOAD ERROR in {name}: {res}")
    try:
        return chunk()
    except lupa.LuaError as e:
        sys.exit(f"LUA ERROR in {name}: {e}")


# The bundle is self-contained: it embeds light-class and sets globals `class` + `Norm`.
bundle = os.path.join(ROOT, "dist", "norm.lua")
if not os.path.exists(bundle):
    sys.exit("dist/norm.lua not found - run the build first (lua build.lua)")
run_file(bundle, "norm.lua")
run_file(os.path.join(HERE, "selftest.lua"), "selftest.lua")
