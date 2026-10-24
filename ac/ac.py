# Paddock AC control: the Midea AC in Peter's rig room. Route (2026-10-23): through Midea's server the way the Midea Air app
# does it (midea-beautiful-air, login saved by "Connect AC.cmd" in ac\cloud.bin, DPAPI-encrypted for this Windows user), because
# Midea no longer hands out the local key. A local key (ac\ac.json, msmart-ng) is still used first if one ever exists.
#   ac.py status | on | off | toggle | cooler | warmer | fan | auto | pcoff
# Prints ONE plain line for the Stream Deck message ("AC on - cooling to 70°F - room 75°F") and writes ac\state.json for the
# top screen. Temperatures are shown in °F (the AC itself works in °C, 0.5° steps).
# auto (run every 2 min by irdash): while the PC is on, cool when the room is warm, stop when it is cool again. It only turns
# OFF what it turned on itself, and a manual OFF from the deck pauses it for an hour so it never fights Peter.
import asyncio, ctypes, ctypes.wintypes as wt, json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
CONF = os.path.join(HERE, "ac.json")          # local route: ip, port, id, token, key (secret: not in git)
CLOUD = os.path.join(HERE, "cloud.bin")        # Midea Air route: login + appliance id, DPAPI-encrypted (secret: not in git)
SETTINGS = os.path.join(HERE, "settings.json")
STATE = os.path.join(HERE, "state.json")
DEFAULTS = {"auto": True, "on_above_f": 76, "off_below_f": 72, "cool_to_f": 70, "manual_pause_min": 60}
# Midea's own numbers (the same in both libraries)
MODE_AUTO, MODE_COOL, MODE_DRY, MODE_HEAT, MODE_FAN = 1, 2, 3, 4, 5
FAN_SILENT, FAN_LOW, FAN_MEDIUM, FAN_HIGH, FAN_MAX, FAN_AUTO = 20, 40, 60, 80, 100, 102
FAN_CYCLE = [FAN_LOW, FAN_MEDIUM, FAN_HIGH, FAN_AUTO]
FAN_WORD = {FAN_SILENT: "silent", FAN_LOW: "low", FAN_MEDIUM: "medium", FAN_HIGH: "high", FAN_MAX: "max", FAN_AUTO: "auto"}
MODE_WORD = {MODE_COOL: "cooling", MODE_HEAT: "heating", MODE_DRY: "drying", MODE_FAN: "fan only", MODE_AUTO: "auto"}


def f2c(f): return round((f - 32) * 5 / 9 * 2) / 2      # nearest 0.5 °C, what the AC accepts
def c2f(c): return None if c is None else round(c * 9 / 5 + 32)


def load(path, default):
    try:
        with open(path) as fh: return json.load(fh)
    except Exception: return dict(default)


def save(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as fh: json.dump(data, fh)
    os.replace(tmp, path)


def line(dev):
    room = c2f(dev.indoor_temperature)
    room_s = (" - room %d°F" % room) if room is not None else ""
    if not dev.power_state: return "AC off" + room_s
    mode = MODE_WORD.get(int(dev.operational_mode), "on")
    fan = FAN_WORD.get(int(dev.fan_speed), str(dev.fan_speed))
    return "AC on - %s to %d°F - fan %s%s" % (mode, c2f(dev.target_temperature), fan, room_s)


def auto_decision(ac_on, auto_on, room_f, s, paused):
    """The auto-cool rule: 'on', 'off' or None (leave it). Only switches OFF what it switched on itself."""
    if not s.get("auto") or room_f is None or paused: return None
    if not ac_on and room_f >= s["on_above_f"]: return "on"
    if ac_on and auto_on and room_f <= s["off_below_f"]: return "off"
    return None

class _BLOB(ctypes.Structure):
    _fields_ = [("cbData", wt.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]


def unprotect(data):
    src = _BLOB(len(data), ctypes.cast(ctypes.create_string_buffer(data, len(data)), ctypes.POINTER(ctypes.c_char)))
    out = _BLOB()
    if not ctypes.windll.crypt32.CryptUnprotectData(ctypes.byref(src), None, None, None, None, 0, ctypes.byref(out)):
        raise SystemExit("AC login could not be read - run 'Connect AC' again")
    try: return ctypes.string_at(out.pbData, out.cbData)
    finally: ctypes.windll.kernel32.LocalFree(out.pbData)


class CloudAC:
    """The AC through Midea's server (Midea Air route), with the same fields run() uses for the local one."""

    def __init__(self, conf):
        from midea_beautiful import connect_to_cloud, appliance_state
        self.cloud = connect_to_cloud(conf["account"], conf["password"], appname=conf.get("app", "Midea Air"))
        self.dev = appliance_state(cloud=self.cloud, use_cloud=True, appliance_id=conf["id"], appliance_type="0xac")
        self.s = self.dev.state

    power_state = property(lambda self: self.s.running, lambda self, v: setattr(self.s, "running", bool(v)))
    operational_mode = property(lambda self: self.s.mode, lambda self, v: setattr(self.s, "mode", int(v)))
    target_temperature = property(lambda self: self.s.target_temperature, lambda self, v: setattr(self.s, "target_temperature", float(v)))
    fan_speed = property(lambda self: self.s.fan_speed, lambda self, v: setattr(self.s, "fan_speed", int(v)))
    indoor_temperature = property(lambda self: self.s.indoor_temperature)

    async def apply(self): self.dev.apply(self.cloud)
    async def refresh(self): self.dev.refresh(self.cloud); self.s = self.dev.state


async def connect():
    c = load(CONF, {})
    if not c.get("token"):
        if not os.path.exists(CLOUD): raise SystemExit("AC not connected yet - run 'Connect AC' once")
        with open(CLOUD, "rb") as fh: conf = json.loads(unprotect(fh.read()))
        return CloudAC(conf)
    from msmart.device import AirConditioner as AC
    dev = AC(ip=c["ip"], device_id=int(c["id"]), port=int(c.get("port", 6444)))
    await dev.authenticate(c["token"], c["key"])
    await dev.refresh()
    if not dev.online: raise SystemExit("AC is not answering")
    return dev


async def run(verb):
    s = dict(DEFAULTS); s.update(load(SETTINGS, {}))
    st = load(STATE, {})
    dev = await connect()
    changed = False
    if verb in ("on", "toggle") and (verb == "on" or not dev.power_state):
        if not dev.power_state:
            dev.power_state = True               # like the remote's power button: the AC keeps its own last mode and temperature
            changed = True
        st["auto_on"] = False; st["pause_until"] = 0
    elif verb in ("off", "toggle"):
        if dev.power_state: dev.power_state = False; changed = True
        st["auto_on"] = False
        st["pause_until"] = time.time() + 60 * s["manual_pause_min"]   # don't let auto switch it straight back on
    elif verb in ("cooler", "warmer"):
        if not dev.power_state:
            dev.power_state = True; dev.operational_mode = MODE_COOL
            dev.target_temperature = f2c(s["cool_to_f"])
        step = -0.5 if verb == "cooler" else 0.5                 # 0.5 °C = about 1 °F
        dev.target_temperature = max(16.0, min(30.0, (dev.target_temperature or 21.0) + step))
        changed = True; st["auto_on"] = False
    elif verb == "fan":
        if not dev.power_state:
            dev.power_state = True; dev.operational_mode = MODE_COOL
            dev.target_temperature = f2c(s["cool_to_f"])
        if int(dev.operational_mode) in (MODE_AUTO, MODE_DRY):
            dev.operational_mode = MODE_COOL      # Midea locks the fan to auto in Auto / Dry mode: cooling lets it change
        cur = int(dev.fan_speed)
        nxt = FAN_CYCLE[(FAN_CYCLE.index(cur) + 1) % len(FAN_CYCLE)] if cur in FAN_CYCLE else FAN_CYCLE[0]
        dev.fan_speed = nxt; changed = True; st["auto_on"] = False
    elif verb == "pcoff":
        # the PC is going to sleep / shutting down: stop the cooling auto started (a manual ON is left alone)
        if dev.power_state and st.get("auto_on"): dev.power_state = False; changed = True
        st["auto_on"] = False
    elif verb == "auto":
        room = c2f(dev.indoor_temperature)
        if st.get("last_on") and not dev.power_state and not st.get("we_turned_off"):
            # switched off with the remote or the app since the last check: that is Peter saying no, so back off like a deck OFF
            st["auto_on"] = False; st["pause_until"] = time.time() + 60 * s["manual_pause_min"]
        what = auto_decision(bool(dev.power_state), bool(st.get("auto_on")), room, s, time.time() < st.get("pause_until", 0))
        if what == "on":
            dev.power_state = True; dev.operational_mode = MODE_COOL
            dev.target_temperature = f2c(s["cool_to_f"]); dev.fan_speed = FAN_AUTO
            changed = True; st["auto_on"] = True; st["auto_said"] = "room %d°F - cooling to %d°F" % (room, s["cool_to_f"])
        elif what == "off":
            dev.power_state = False; changed = True; st["auto_on"] = False
            st["auto_said"] = "room %d°F - cool enough, AC off" % room
    elif verb != "status":
        raise SystemExit("unknown: " + verb)
    if changed:
        await dev.apply()
        await asyncio.sleep(1)
        await dev.refresh()
    text = line(dev)
    st["we_turned_off"] = bool(changed and not dev.power_state)   # an OFF that came from Paddock itself (deck key, auto, PC off)
    st["last_on"] = bool(dev.power_state)
    st.update({"at": time.time(), "text": text, "on": bool(dev.power_state), "room_f": c2f(dev.indoor_temperature),
               "target_f": c2f(dev.target_temperature), "auto": bool(s["auto"]),
               "paused": time.time() < st.get("pause_until", 0)})
    save(STATE, st)
    # auto prints "AUTO <what it did>" only when it switched the AC, so irdash knows to show it on the top screen
    print(("AUTO " + st.get("auto_said", text)) if (verb == "auto" and changed) else text)


def main():
    verb = sys.argv[1].lower() if len(sys.argv) > 1 else "status"
    try:
        asyncio.run(run(verb))
    except SystemExit as e:
        if e.code not in (None, 0): print(str(e.code)); sys.exit(2)
    except Exception as e:
        print("AC did not answer (%s)" % type(e).__name__); sys.exit(1)


if __name__ == "__main__":
    main()
