"""Run storage transactions against vanilla DST Container/Stackable (Lua 5.1).

Requires Python + lupa; this workspace's bundled .tools/lua_test_runtime is used
when present. Set DST_SCRIPTS_PATH or --scripts to extracted vanilla scripts.
No workshop mods or running game are needed.
"""
from pathlib import Path
import argparse
import os
import sys

SOURCE = Path(__file__).resolve().parents[1]
ROOT = SOURCE.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    "--scripts",
    type=Path,
    default=Path(os.environ.get("DST_SCRIPTS_PATH", ROOT / "game_scripts_reference/scripts")),
)
args = parser.parse_args()
sys.path.insert(0, str(ROOT / ".tools/lua_test_runtime"))
from lupa.lua51 import LuaRuntime

if not (args.scripts / "components/container.lua").is_file():
    parser.error("--scripts must point to extracted vanilla DST scripts")

lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().package.path = ";".join([
    (SOURCE / "scripts/?.lua").as_posix(),
    (args.scripts.resolve() / "?.lua").as_posix(),
    lua.globals().package.path,
])
lua.execute("assert(loadstring(...))", (SOURCE / "scripts/nac_storage.lua").read_text(encoding="utf-8"))
lua.execute((Path(__file__).parent / "test_storage.lua").read_text(encoding="utf-8"))
