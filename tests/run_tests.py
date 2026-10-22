"""Lua 5.1 syntax and behavioral checks. Native-engine coverage is separate."""
from pathlib import Path
import os
import sys

SOURCE = Path(__file__).resolve().parents[1]
ROOT = SOURCE.parent
sys.path.insert(0, str(ROOT / ".tools/lua_test_runtime"))
from lupa.lua51 import LuaRuntime

scripts = Path(os.environ.get("DST_SCRIPTS_PATH", ROOT / "game_scripts_reference/scripts"))
syntax = LuaRuntime()
files = list(SOURCE.rglob("*.lua"))
for file in files:
    syntax.execute("assert(loadstring(...))", file.read_text(encoding="utf-8"))
print(f"AUTOCOOK_SYNTAX_SUCCESS {len(files)} files", flush=True)
for name in ("test_storage.lua", "test_ui.lua", "test_fx.lua", "test_rpc.lua"):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().NAC_MOD_ROOT = SOURCE.as_posix()
    lua.globals().NAC_GAME_SCRIPTS = scripts.as_posix()
    lua.globals().package.path = ";".join([
        (SOURCE / "scripts/?.lua").as_posix(), (scripts / "?.lua").as_posix(), lua.globals().package.path,
    ])
    lua.execute((SOURCE / "tests" / name).read_text(encoding="utf-8"))
