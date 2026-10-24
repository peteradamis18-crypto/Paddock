# One-time: find the AC on the network and fetch its local token/key from Midea's cloud, then save them to ac\ac.json.
# msmart-ng's own discover stops after the first udpid form and only asks one cloud; this tries both clouds (NetHome Plus and
# SmartHome, which the MSmartHome app uses), every built-in region and both udpid byte orders, and keeps the pair the AC accepts.
# Optional: --account EMAIL (the password is asked for in the console, never on the command line or on disk).
import asyncio, json, os, sys, getpass, time, base64
from secrets import token_hex
from hashlib import sha256
from Crypto.Cipher import AES
from Crypto.Util.Padding import pad
from msmart.discover import Discover
from msmart.cloud import NetHomePlusCloud, SmartHomeCloud, CloudError
from msmart.lan import AuthenticationError, Security

HOST = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "192.168.7.26"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ac.json")
LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "getkey.log")   # what each cloud answered (never the password)
_print = print
def print(*a):
    _print(*a)
    try:
        with open(LOG, "a", encoding="utf-8") as fh: fh.write(time.strftime("%Y-%m-%d %H:%M:%S  ") + " ".join(str(x) for x in a) + "\n")
    except Exception: pass


class MideaAirCloud(NetHomePlusCloud):
    """Midea Air (the app Peter's AC is in): NetHome Plus's server with its own app id and signing key."""
    APP_ID = "1117"

    class _Security(NetHomePlusCloud._Security):
        APP_KEY = "ff0cf6f5f0c3471de36341cab3f7a9af"

    def __init__(self, *a, **k):
        super().__init__(*a, **k)
        self._security = MideaAirCloud._Security()

async def account_server(account):
    """Ask Midea which server holds this account (midea-local PR 896): newer accounts are not on the default server, and
    the default server then answers 3102 'wrong password' without checking the password. Returns a base URL or None."""
    key = SmartHomeCloud._Security.LOGIN_KEY
    d = sha256(key.encode("ascii")).hexdigest()
    name = AES.new(d[:16].encode("ascii"), AES.MODE_CBC, d[16:32].encode("ascii")).encrypt(pad(account.encode("utf-8"), 16)).hex()
    c = SmartHomeCloud("US")
    auth = "Basic " + base64.b64encode((key + ":meicloud").encode()).decode()
    asks = [("/v1/unitcenter/router/user/name", {"clientType": 8, "clientSrc": 8, "userType": "0", "userName": name}),
            ("/v1/multicloud/platform/user/route", {"userType": "0", "userName": account})]
    for endpoint, extra in asks:
        body = c._build_request_body(extra); body.setdefault("platformId", "1")
        contents = json.dumps(body); rnd = str(int(time.time()))
        headers = {"Content-Type": "application/json; charset=utf-8", "secretVersion": "1", "sign": c._security.sign(contents, rnd),
                   "random": rnd, "x-recipe-app": SmartHomeCloud.APP_ID, "authorization": auth}
        try:
            r = await c._post_request("https://mp-prod.appsmb.com/mas/v5/app/proxy?alias=" + endpoint, headers=headers, raw_data=contents)
            url = (r or {}).get("masUrl") if isinstance(r, dict) else None
            print("  router %s: %s" % (endpoint, url or ascii(r)[:120]))
            if url: return url.split("/mas/")[0]
        except Exception as e:
            print("  router %s: %s" % (endpoint, ascii(str(e))[:120]))
    return None

async def alt_login(cloud, base, account, password):
    """Sign in the way midea-local does (its body shape plus the app headers). Fills msmart's session on success."""
    key = SmartHomeCloud._Security.LOGIN_KEY
    cloud._base_url = base
    if cloud._login_id is None: cloud._login_id = await cloud._get_login_id()
    sec = cloud._security
    stamp = time.strftime("%Y%m%d%H%M%S", time.gmtime())
    iot = cloud._build_request_body({})
    iot.update({"platformId": "1", "clientType": "1", "iampwd": sec.encrypt_iam_password(cloud._login_id, password),
                "loginAccount": account, "password": sec.encrypt_password(cloud._login_id, password), "stamp": stamp})
    body = {"iotData": iot, "data": {"appKey": key, "deviceId": iot.get("deviceId"), "platform": "2"}, "stamp": stamp, "reqId": token_hex(16)}
    contents = json.dumps(body); rnd = str(int(time.time()))
    headers = {"Content-Type": "application/json; charset=utf-8", "secretVersion": "1", "sign": sec.sign(contents, rnd), "random": rnd,
               "x-recipe-app": SmartHomeCloud.APP_ID, "authorization": "Basic " + base64.b64encode((key + ":meicloud").encode()).decode()}
    r = await cloud._post_request(base + "/mas/v5/app/proxy?alias=/mj/user/login", headers=headers, raw_data=contents)
    cloud._session = r
    cloud._access_token = r["mdata"]["accessToken"]

async def main():
    account = password = None
    if "--account" in sys.argv:
        account = sys.argv[sys.argv.index("--account") + 1]
        # shown while typing (Peter asked for no more blind typos); it is still never saved or logged
        password = input("  MSmartHome password: ").strip()
        print("account %s***@%s, password %d characters" % (account[:2], account.split("@")[-1], len(password)))
    dev = await Discover.discover_single(HOST, auto_connect=False)
    if dev is None:
        print("FAIL the AC did not answer at " + HOST); return 1
    print("found id=%s version=%s port=%s type=%s" % (dev.id, dev.version, dev.port, dev.type))
    # Newer US accounts live on Midea's US server: the default server answers 3102 "wrong password" for them without ever
    # checking the password (midea-lan/midea-local issue 895, Oct 2026). So the US server goes first.
    clouds = []
    if account:
        clouds.append((MideaAirCloud, "US", None))   # the app the AC is paired in: ask with the owner's own login first
        home = await account_server(account)
        if home and home not in ("https://mp-prod.appsmb.com", "https://mp-us-prod.appsmb.com"):
            clouds.append((SmartHomeCloud, "US", home))
    for region in (["US"] if account else ["US", "DE", "KR"]):
        clouds.append((SmartHomeCloud, region, "https://mp-us-prod.appsmb.com"))
        clouds.append((SmartHomeCloud, region, None))
        clouds.append((NetHomePlusCloud, region, None))
    for cls, region, server in clouds:
        name = cls.__name__ + "/" + region + (("@" + server.split("//")[-1]) if server else "")
        try:
            cloud = cls(region, account=account, password=password)
            if server: cloud._base_url = server
            await cloud.login()
        except Exception as e:
            print("  %s: login failed (%s)" % (name, str(e)[:80]))
            if not (account and cls is SmartHomeCloud): continue
            try:
                await alt_login(cloud, server or SmartHomeCloud.BASE_URL, account, password)
                print("  %s: signed in the midea-local way" % name)
            except Exception as e2:
                print("  %s: midea-local way failed too (%s)" % (name, ascii(str(e2))[:80])); continue
        for endian in ("little", "big"):
            udpid = Security.udpid(dev.id.to_bytes(6, endian)).hex()
            try:
                token, key = await cloud.get_token(udpid, dev.id)
            except Exception as e:
                print("  %s %s: no token (%s)" % (name, endian, str(e)[:80])); continue
            try:
                await dev.authenticate(token, key)
            except AuthenticationError:
                print("  %s %s: token refused by the AC" % (name, endian)); continue
            with open(OUT, "w") as f:
                json.dump({"ip": dev.ip, "port": dev.port, "id": dev.id, "token": token, "key": key, "version": dev.version}, f)
            print("OK key saved to ac\\ac.json (from %s, %s)" % (name, endian))
            return 0
    print("FAIL no cloud gave a key the AC accepts")
    return 1

if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
