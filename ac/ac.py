# Paddock AC control: the Midea AC in Peter's rig room, on the local network (msmart-ng, no cloud after the one-time key).
#   ac.py status | on | off | toggle | cooler | warmer | fan | auto | pcoff
# Prints ONE plain line for the Stream Deck message ("AC on - cooling to 70°F - room 75°F") and writes ac\state.json for the
# top screen. Temperatures are shown in °F (the AC itself works in °C, 0.5° steps).
# auto (run every 2 min by irdash): while the PC is on, cool when the room is warm, stop when it is cool again. It only turns
# OFF what it turned on itself, and a manual OFF from the deck pauses it for an hour so it never fights Peter.
import asyncio, json, os, sys, time
from msmart.device import AirConditioner as AC

HERE = os.path.dirname(os.path.abspath(__file__))
CONF = os.path.join(HERE, "ac.json")          # ip, port, id, token, key (secret: not in git)
SETTINGS = os.path.join(HERE, "settings.json")
STATE = os.path.join(HERE, "state.json")
DEFAULTS = {"auto": True, "on_above_f": 76, "off_below_f": 72, "cool_to_f": 70, "manual_pause_min": 60}
FAN_CYCLE = [AC.FanSpeed.LOW, AC.FanSpeed.MEDIUM, AC.FanSpeed.HIGH, AC.FanSpeed.AUTO]
FAN_WORD = {AC.FanSpeed.SILENT: "silent", AC.FanSpeed.LOW: "low", AC.FanSpeed.MEDIUM: "medium",
            AC.FanSpeed.HIGH: "high", AC.FanSpeed.MAX: "max", AC.FanSpeed.AUTO: "auto"}
MODE_WORD = {AC.OperationalMode.COOL: "cooling", AC.OperationalMode.HEAT: "heating", AC.OperationalMode.DRY: "drying",
             AC.OperationalMode.FAN_ONLY: "fan only", AC.OperationalMode.AUTO: "auto"}


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
    mode = MODE_WORD.get(dev.operational_mode, "on")
    fan = FAN_WORD.get(dev.fan_speed, str(dev.fan_speed))
    return "AC on - %s to %d°F - fan %s%s" % (mode, c2f(dev.target_temperature), fan, room_s)


def auto_decision(ac_on, auto_on, room_f, s, paused):
    """The auto-cool rule: 'on', 'off' or None (leave it). Only switches OFF what it switched on itself."""
    if not s.get("auto") or room_f is None or paused: return None
    if not ac_on and room_f >= s["on_above_f"]: return "on"
    if ac_on and auto_on and room_f <= s["off_below_f"]: return "off"
    return None

async def connect():
    c = load(CONF, {})
    if not c.get("token"): raise SystemExit("AC not connected yet - run 'Connect AC' once")
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
            dev.power_state = True
            dev.operational_mode = AC.OperationalMode.COOL     # Peter mostly wants cooling; HEAT stays possible from the remote/app
            dev.target_temperature = f2c(s["cool_to_f"])
            changed = True
        st["auto_on"] = False; st["pause_until"] = 0
    elif verb in ("off", "toggle"):
        if dev.power_state: dev.power_state = False; changed = True
        st["auto_on"] = False
        st["pause_until"] = time.time() + 60 * s["manual_pause_min"]   # don't let auto switch it straight back on
    elif verb in ("cooler", "warmer"):
        if not dev.power_state:
            dev.power_state = True; dev.operational_mode = AC.OperationalMode.COOL
            dev.target_temperature = f2c(s["cool_to_f"])
        step = -0.5 if verb == "cooler" else 0.5                 # 0.5 °C = about 1 °F
        dev.target_temperature = max(16.0, min(30.0, (dev.target_temperature or 21.0) + step))
        changed = True; st["auto_on"] = False
    elif verb == "fan":
        if not dev.power_state:
            dev.power_state = True; dev.operational_mode = AC.OperationalMode.COOL
            dev.target_temperature = f2c(s["cool_to_f"])
        cur = dev.fan_speed
        nxt = FAN_CYCLE[(FAN_CYCLE.index(cur) + 1) % len(FAN_CYCLE)] if cur in FAN_CYCLE else FAN_CYCLE[0]
        dev.fan_speed = nxt; changed = True; st["auto_on"] = False
    elif verb == "pcoff":
        # the PC is going to sleep / shutting down: stop the cooling auto started (a manual ON is left alone)
        if dev.power_state and st.get("auto_on"): dev.power_state = False; changed = True
        st["auto_on"] = False
    elif verb == "auto":
        room = c2f(dev.indoor_temperature)
        what = auto_decision(bool(dev.power_state), bool(st.get("auto_on")), room, s, time.time() < st.get("pause_until", 0))
        if what == "on":
            dev.power_state = True; dev.operational_mode = AC.OperationalMode.COOL
            dev.target_temperature = f2c(s["cool_to_f"]); dev.fan_speed = AC.FanSpeed.AUTO
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
