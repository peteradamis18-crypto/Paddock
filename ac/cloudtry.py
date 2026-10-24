# Midea Air route (2026-10-23): Midea no longer hands out the AC's local key, but the Midea Air app still controls the AC through
# Midea's server (/v1/appliance/transparent/send). This signs in once with Peter's Midea Air login, finds the AC and reads its state
# that way. If that works, the login is saved on THIS PC only, encrypted with Windows' own per-user protection (DPAPI), so the
# AC keys and auto-cool can use the same route. Nothing is saved if it fails.
import ctypes, ctypes.wintypes as wt, json, os, sys
from midea_beautiful import connect_to_cloud, appliance_state

HERE = os.path.dirname(os.path.abspath(__file__))
SAVE = os.path.join(HERE, "cloud.bin")
LOG = os.path.join(HERE, "getkey.log")


def log(s):
    print(s)
    try:
        import time
        with open(LOG, "a", encoding="utf-8") as fh: fh.write(time.strftime("%Y-%m-%d %H:%M:%S  ") + "cloud: " + s + "\n")
    except Exception: pass


class BLOB(ctypes.Structure):
    _fields_ = [("cbData", wt.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]


def protect(data: bytes) -> bytes:
    src = BLOB(len(data), ctypes.cast(ctypes.create_string_buffer(data, len(data)), ctypes.POINTER(ctypes.c_char)))
    out = BLOB()
    if not ctypes.windll.crypt32.CryptProtectData(ctypes.byref(src), None, None, None, None, 0, ctypes.byref(out)):
        raise OSError("CryptProtectData failed")
    try: return ctypes.string_at(out.pbData, out.cbData)
    finally: ctypes.windll.kernel32.LocalFree(out.pbData)


def main():
    account = input("  Midea Air email: ").strip()
    password = input("  Midea Air password: ").strip()
    log("account %s***@%s, password %d characters" % (account[:2], account.split("@")[-1], len(password)))
    try:
        cloud = connect_to_cloud(account, password, appname="Midea Air")
    except Exception as e:
        log("sign-in failed: %s" % ascii(str(e))[:150]); return 1
    log("signed in to Midea Air")
    try:
        apps = cloud.list_appliances()
    except Exception as e:
        log("could not list the appliances: %s" % ascii(str(e))[:150]); return 1
    for a in apps: log("appliance: id=%s type=%s name=%s" % (a.get("id"), a.get("type"), ascii(a.get("name"))))
    acs = [a for a in apps if str(a.get("type", "")).lower() == "0xac"]
    if not acs: log("no air conditioner on this account"); return 1
    ac = acs[0]
    try:
        dev = appliance_state(cloud=cloud, use_cloud=True, appliance_id=str(ac["id"]), appliance_type="0xac")
        s = dev.state
        log("AC answered through Midea Air: running=%s target=%sC room=%sC fan=%s mode=%s" % (
            s.running, s.target_temperature, getattr(s, "indoor_temperature", "?"), s.fan_speed, s.mode))
    except Exception as e:
        log("the AC did not answer through Midea Air: %s" % ascii(str(e))[:150]); return 1
    with open(SAVE, "wb") as fh:
        fh.write(protect(json.dumps({"account": account, "password": password, "app": "Midea Air", "id": str(ac["id"])}).encode()))
    log("OK saved (encrypted, this PC only) - the PC can control the AC now")
    return 0


if __name__ == "__main__":
    sys.exit(main())
