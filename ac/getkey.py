# One-time: find the AC on the network and fetch its local token/key from Midea's cloud, then save them to ac\ac.json.
# msmart-ng's own discover stops after the first udpid form and only asks one cloud; this tries both clouds (NetHome Plus and
# SmartHome, which the MSmartHome app uses), every built-in region and both udpid byte orders, and keeps the pair the AC accepts.
# Optional: --account EMAIL (the password is asked for in the console, never on the command line or on disk).
import asyncio, json, os, sys, getpass
from msmart.discover import Discover
from msmart.cloud import NetHomePlusCloud, SmartHomeCloud, CloudError
from msmart.lan import AuthenticationError, Security

HOST = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "192.168.7.26"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ac.json")


async def main():
    account = password = None
    if "--account" in sys.argv:
        account = sys.argv[sys.argv.index("--account") + 1]
        password = getpass.getpass("MSmartHome password (it is not shown or saved): ")
    dev = await Discover.discover_single(HOST, auto_connect=False)
    if dev is None:
        print("FAIL the AC did not answer at " + HOST); return 1
    print("found id=%s version=%s port=%s type=%s" % (dev.id, dev.version, dev.port, dev.type))
    clouds = []
    for cls in (SmartHomeCloud, NetHomePlusCloud):
        for region in (["US"] if account else ["US", "DE", "KR"]):
            clouds.append((cls, region))
    for cls, region in clouds:
        name = cls.__name__ + "/" + region
        try:
            cloud = cls(region, account=account, password=password)
            await cloud.login()
        except Exception as e:
            print("  %s: login failed (%s)" % (name, str(e)[:80])); continue
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

sys.exit(asyncio.run(main()))
