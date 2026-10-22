"""Exercise the release mod in a new, isolated offline DST world."""
from pathlib import Path
import argparse
import random
import shutil
import socket
import subprocess
import tempfile
import uuid

SOURCE = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("game", nargs="?", type=Path,
                    default=Path("D:/Program Files (x86)/Steam/steamapps/common/Don't Starve Together"))
parser.add_argument("--compat", action="store_true", help="Also load installed Arcadiea and Storeroom workshop mods")
parser.add_argument("--caves", action="store_true", help="Validate a fresh cave world")
args = parser.parse_args()
game = args.game.resolve()
storage = Path(tempfile.mkdtemp(prefix="autocook_", dir=SOURCE.parent)).resolve()
mod_name = "nearby_autocook_validation_" + uuid.uuid4().hex[:10]
mod = (game / "mods" / mod_name).resolve()
assert mod.parent == (game / "mods").resolve() and not mod.exists()
cluster = storage / "DoNotStarveTogether" / "NearbyAutoCookTest"
master = cluster / "Master"
master.mkdir(parents=True)
server_port = None
# Offline LAN servers reject ports outside this native engine range.
for candidate in random.sample(list(range(10998, 11019)), 21):
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.bind(("0.0.0.0", candidate))
        server_port = candidate
        break
    except OSError:
        continue
assert server_port is not None, "No free UDP port in the DST LAN range 10998-11018"
(cluster / "cluster.ini").write_text("""[GAMEPLAY]
game_mode = survival
max_players = 1
pvp = false
pause_when_empty = false
[NETWORK]
cluster_name = AutoCook Isolated Validation
offline_cluster = true
lan_only_cluster = true
cluster_password = autocook-test-only
[MISC]
console_enabled = true
[SHARD]
shard_enabled = false
""", encoding="utf-8")
(master / "server.ini").write_text(
    f"[NETWORK]\nserver_port = {server_port}\n[SHARD]\nis_master = true\n[ACCOUNT]\nencode_user_path = false\n", encoding="utf-8")
mods = [f'{mod_name} = {{ enabled = true }}']
if args.compat:
    workshop = game.parents[1] / "workshop/content/322330"
    for item in ("1872917938", "2784048339"):
        assert (workshop / item / "modinfo.lua").is_file(), f"Workshop dependency missing: {item}"
        mods.append(f'["workshop-{item}"] = {{ enabled = true }}')
(master / "modoverrides.lua").write_text("return { " + ", ".join(mods) + " }\n", encoding="utf-8")
preset = "DST_CAVE" if args.caves else "SURVIVAL_TOGETHER"
(master / "worldgenoverride.lua").write_text(
    f'return {{ override_enabled = true, preset = "{preset}", overrides = {{ world_size = "small" }} }}\n', encoding="utf-8")
try:
    mod.mkdir()
    shutil.copy2(SOURCE / "modinfo.lua", mod)
    shutil.copytree(SOURCE / "scripts", mod / "scripts")
    for folder in ("images", "anim"):
        if (SOURCE / folder).exists():
            shutil.copytree(SOURCE / folder, mod / folder)
    shutil.copy2(SOURCE / "tests/game_smoke.lua", mod / "scripts/nac_game_smoke.lua")
    shutil.copy2(SOURCE / "tests/flight_reference_smoke.lua", mod / "scripts/nac_flight_reference_smoke.lua")
    main = (SOURCE / "modmain.lua").read_text(encoding="utf-8")
    main += "\nGLOBAL.NAC_TEST_COMPAT = " + ("true" if args.compat else "false") + "\n"
    main += '''
AddSimPostInit(function()
    GLOBAL.TheWorld:DoTaskInTime(1, function()
        local ok, err = GLOBAL.xpcall(function()
            GLOBAL.require("nac_game_smoke")
        end, GLOBAL.debug.traceback)
        if not ok then
            print("AUTOCOOK_GAME_FAILURE " .. GLOBAL.tostring(err))
            GLOBAL.c_shutdown(false)
        end
    end)
end)
'''
    (mod / "modmain.lua").write_text(main, encoding="utf-8")
    exe = game / "bin64/dontstarve_dedicated_server_nullrenderer_x64.exe"
    log = storage / "engine_console.log"
    with log.open("wb") as output:
        process = subprocess.Popen([
            str(exe), "-console", "-offline", "-skip_update_server_mods", "-port", str(server_port),
            "-ugc_directory", str(game.parents[1] / "workshop"),
            "-persistent_storage_root", str(storage), "-conf_dir", "DoNotStarveTogether",
            "-cluster", "NearbyAutoCookTest", "-shard", "Master"],
            cwd=exe.parent, stdout=output, stderr=subprocess.STDOUT,
            creationflags=subprocess.CREATE_NO_WINDOW)
        print(f"Started isolated offline DST engine, PID {process.pid}; log: {log}", flush=True)
        try:
            process.wait(timeout=300)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=15)
            raise RuntimeError(f"Engine test timed out; see {log}")
    text = log.read_text(encoding="utf-8", errors="replace")
    for line in text.splitlines():
        if "AUTOCOOK_GAME_" in line or "AUTOCOOK_REFERENCE_FLIGHT_RESULT" in line or "AUTOCOOK_REFERENCE_FLIGHT_FAILURE" in line or "LUA ERROR" in line or "Error" in line:
            print(line)
    assert "AUTOCOOK_GAME_SUCCESS" in text, f"Engine validation failed; see {log}"
    assert "AUTOCOOK_REFERENCE_FLIGHT_RESULT passed=true" in text, f"Native flight comparison failed; see {log}"
    assert not any(marker in text for marker in ("AUTOCOOK_GAME_FAILURE", "AUTOCOOK_REFERENCE_FLIGHT_FAILURE", "LUA ERROR", "MOD ERROR")), f"Lua/mod errors found; see {log}"
finally:
    # The only deletion target is this exact newly created validation mod.
    if mod.exists() and mod.resolve().parent == (game / "mods").resolve() and mod.name == mod_name:
        shutil.rmtree(mod)
