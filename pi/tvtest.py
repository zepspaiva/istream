#!/usr/bin/env python3
"""Proves the high-value actions on the LG TV before we build the Raspberry Pi server.

    ./tvtest.sh info              pair with the TV (accept on screen), save its details, list apps and inputs
    ./tvtest.sh off               turn the TV off
    ./tvtest.sh stremio           TV on (if needed) -> Stremio, timed
    ./tvtest.sh input <name>      TV on (if needed) -> an HDMI input, by name or id (ps5, switch, hdmi2...)
    ./tvtest.sh deeplink [n]      which way of opening Stremio on a given title works (all tests, or test n)
    ./tvtest.sh title [link]      TV on (if needed) -> Nuvio on a title's page, timed
                                  (default: nuvio://movie/tt0111161, The Shawshank Redemption;
                                   a series: nuvio://series/tt0903747, Breaking Bad)
    ./tvtest.sh play [link] [--wait N]   as title, then presses OK on Play and watches for playback to start
                                  (--wait: seconds to wait for the title's page before pressing OK)
    ./tvtest.sh channel [app id]  phone <-> TV app messages without the Pi: opens the channel test app (default
                                  io.freemytv.channel), sends it messages, prints everything the TV sends back

The TV's address is in TV_IP below; the pairing key and the TV's MAC address are saved in tv.json next to this file.
"""
import asyncio
import json
import os
import socket
import sys
import time

from aiowebostv import WebOsClient

TV_IP = "192.168.1.34"
HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(HERE, "tv.json")
T0 = time.monotonic()


def say(msg):
    print(f"[{time.monotonic() - T0:5.1f}s] {msg}", flush=True)


def load():
    try:
        with open(STATE) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def save(state):
    with open(STATE, "w") as f:
        json.dump(state, f, indent=2)


def magic_packet(macs):
    """Wake-on-LAN: the magic packet to every MAC we know, on the usual broadcast addresses and ports."""
    for mac in macs:
        raw = bytes.fromhex(mac.replace(":", "").replace("-", ""))
        packet = b"\xff" * 6 + raw * 16
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            for addr in ("255.255.255.255", TV_IP.rsplit(".", 1)[0] + ".255", TV_IP):
                for port in (9, 7):
                    try:
                        s.sendto(packet, (addr, port))
                    except OSError:
                        pass


async def connect(state, timeout=4.0):
    client = WebOsClient(TV_IP, state.get("client_key"), connect_timeout=timeout)
    await client.connect()
    if client.client_key and client.client_key != state.get("client_key"):
        state["client_key"] = client.client_key
        save(state)
    return client


async def try_connect(state, timeout=3.0):
    client = WebOsClient(TV_IP, state.get("client_key"), connect_timeout=timeout)
    try:
        await client.connect()
        return client
    except Exception:
        try:
            await client.disconnect()
        except Exception:
            pass
        return None


async def tv_on(state):
    """Returns a connected client with the TV on (screen on), waking it if needed."""
    client = await try_connect(state)
    if client and client.tv_state.is_on:
        say("TV was already on")
        return client
    if client:
        say(f"TV answers but is in standby ({client.tv_state.power_state}); asking it to turn on")
        try:
            await client.power_on()
        except Exception as e:
            say(f"  turnOn failed: {e}")
    macs = state.get("macs") or []
    if not macs and not client:
        sys.exit("No MAC address saved: run './tvtest.sh info' once with the TV on.")
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        if not (client and client.tv_state.is_on):
            magic_packet(macs)
        if client is None:
            client = await try_connect(state)
            if client:
                say(f"TV answers (power: {client.tv_state.power_state})")
        if client and client.tv_state.is_on:
            say("TV is on")
            return client
        await asyncio.sleep(1)
    sys.exit("The TV didn't turn on within 45 s. Check 'Turn on via Wi-Fi' (TV On With Mobile) in the TV's settings.")


async def wait_for_app(client, app_id, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            cur = (await client.get_current_app()) or ""
        except Exception:
            cur = ""
        if cur == app_id:
            say(f"{app_id} is on screen")
            return True
        await asyncio.sleep(0.5)
    say(f"{app_id} not on screen after {seconds}s (current: {cur})")
    return False


async def cmd_info():
    state = load()
    say("Connecting... if the TV asks to allow a connection, accept it with the remote.")
    client = await connect(state, timeout=60)
    say("Connected and paired.")

    async def ask(call):   # some details need permissions the TV doesn't give remote apps: skip those
        try:
            return await call() or {}
        except Exception as e:
            print(f"  (TV refused {call.__name__}: {e})")
            return {}

    sw = await ask(client.get_software_info)
    sysinfo = await ask(client.get_system_info)
    conn = await ask(client.get_connection_info)
    macs = []
    for k in ("wiredInfo", "wifiInfo"):
        info = conn.get(k) or {}
        if info.get("macAddress"):
            macs.append(info["macAddress"])
            print(f"  {k}: MAC {info['macAddress']}, {info.get('state', '?')}")
    if not macs:   # the address this computer sees for the TV on the network
        import re
        import subprocess
        out = subprocess.run(["arp", "-n", TV_IP], capture_output=True, text=True).stdout
        m = re.search(r"(([0-9a-f]{1,2}[:-]){5}[0-9a-f]{1,2})", out, re.I)
        if m:
            mac = ":".join(p.zfill(2) for p in re.split("[:-]", m.group(1)))
            macs.append(mac)
            print(f"  MAC (from the network): {mac}")
        else:
            print("  Couldn't find the TV's MAC address: waking it from off won't work yet.")
    state["macs"] = macs
    hello = client.tv_info.hello or {}
    print(f"  Model: {sysinfo.get('modelName') or '?'}  webOS: {sw.get('product_name') or hello.get('deviceOSReleaseVersion') or '?'}"
          f"  ({hello.get('deviceOS', '')} {hello.get('deviceOSVersion', '')})")
    apps = client.tv_state.apps or {}
    print("\nApps (id: title):")
    for app_id, app in sorted(apps.items(), key=lambda a: a[1].get("title", "").lower()):
        mark = "  <-- Stremio" if "stremio" in (app_id + app.get("title", "")).lower() else ""
        print(f"  {app_id}: {app.get('title')}{mark}")
        if mark:
            state["stremio"] = app_id
    inputs = client.tv_state.inputs or {}
    print("\nInputs (app id: label, connected):")
    state["inputs"] = {}
    for app_id, i in inputs.items():
        print(f"  {app_id}: {i.get('label')}  connected={i.get('connected')}  id={i.get('id')}")
        state["inputs"][app_id] = i.get("label") or ""
    save(state)
    print(f"\nSaved to {STATE}. Power state now: {client.tv_state.power_state}")
    await client.disconnect()


async def cmd_off():
    state = load()
    client = await try_connect(state)
    if not client:
        say("The TV didn't accept a connection: it's off already (or turning off).")
        return
    await client.power_off()
    say("Off sent")


async def cmd_stremio():
    state = load()
    app_id = state.get("stremio")
    if not app_id:
        sys.exit("Stremio's id isn't saved: run './tvtest.sh info' first.")
    client = await tv_on(state)
    await client.launch_app(app_id)
    say(f"Asked to open {app_id}")
    await wait_for_app(client, app_id)
    say("Done")
    await client.disconnect()


async def cmd_input(name):
    state = load()
    want = name.lower()
    target = None
    for app_id, label in (state.get("inputs") or {}).items():
        if want in app_id.lower() or want in label.lower():
            target = app_id
            break
    if not target:
        sys.exit(f"No input matches '{name}'. Known: {state.get('inputs')}")
    client = await tv_on(state)
    await client.launch_app(target)
    say(f"Asked to switch to {target} ({state['inputs'][target]})")
    await wait_for_app(client, target)
    say("Done")
    await client.disconnect()


DETAIL = "stremio:///detail/movie/tt0111161/tt0111161"   # The Shawshank Redemption
WEB_DETAIL = "#/detail/movie/tt0111161/tt0111161"
SEARCH = "stremio:///search?search=matrix"

# The ways a webOS app can be handed a link when it's launched: which one (if any) Stremio's LG app reads.
VARIANTS = [
    ("params.contentTarget = stremio link", {"params": {"contentTarget": DETAIL}}),
    ("contentId = stremio link", {"contentId": DETAIL}),
    ("params.deepLink = stremio link", {"params": {"deepLink": DETAIL}}),
    ("params.url = stremio link", {"params": {"url": DETAIL}}),
    ("params.target = stremio link", {"params": {"target": DETAIL}}),
    ("params.contentTarget = #/detail route", {"params": {"contentTarget": WEB_DETAIL}}),
    ("params.route = #/detail route", {"params": {"route": WEB_DETAIL}}),
    ("params.contentTarget = search link", {"params": {"contentTarget": SEARCH}}),
]


async def cmd_deeplink(only=None):
    state = load()
    app_id = state.get("stremio") or "io.strem.tv"
    print("Each test closes Stremio, opens it with a link to 'The Shawshank Redemption' (the last one: a search for")
    print("'matrix'), and asks what you see on the TV.\n")
    results = []
    for n, (name, extra) in enumerate(VARIANTS, 1):
        if only and n != only:
            continue
        client = await tv_on(state)
        try:
            await client.request("system.launcher/close", {"id": app_id})
        except Exception:
            pass
        await asyncio.sleep(2)
        try:
            res = await client.request("system.launcher/launch", dict({"id": app_id}, **extra))
            say(f"Test {n}: {name} -> sent ({res.get('returnValue', res)})")
        except Exception as e:
            say(f"Test {n}: {name} -> the TV refused it: {e}")
            results.append((n, name, "refused"))
            await client.disconnect()
            continue
        await client.disconnect()
        seen = await asyncio.get_running_loop().run_in_executor(
            None, input, "   Wait for Stremio to load. What's on screen? [t]itle page / [s]earch results / [h]ome / [o]ther: ")
        results.append((n, name, {"t": "TITLE PAGE", "s": "SEARCH RESULTS", "h": "home"}.get(seen.strip()[:1].lower(), seen.strip() or "?")))
    print("\nResults:")
    for n, name, seen in results:
        print(f"  {n}. {name}: {seen}")


NUVIO = "space.nuvio.webos"


async def cmd_title(link):
    """Nuvio reads a nuvio:// link in params.contentTarget, at launch and when it's already open (webOSRelaunch)."""
    state = load()
    client = await tv_on(state)
    res = await client.request("system.launcher/launch", {"id": NUVIO, "params": {"contentTarget": link}})
    say(f"Asked Nuvio to open {link} ({res.get('returnValue', res)})")
    await wait_for_app(client, NUVIO)
    say("Done: the title's page should be on screen in a moment.")
    await client.disconnect()


async def media_state(client):
    """What the TV's media pipeline says is playing in the app on screen: [(appId, playState)]."""
    try:
        info = await client.get_media_foreground_app()
    except Exception as e:
        return f"(no answer: {e})"
    return [(i.get("appId"), i.get("playState")) for i in info] or "nothing"


async def cmd_play(link, wait):
    """Title page in Nuvio, then OK on its Play button. With Nuvio's Stream selection = First stream, that plays."""
    state = load()
    client = await tv_on(state)
    try:
        was_open = (await client.get_current_app()) == NUVIO
    except Exception:
        was_open = False
    res = await client.request("system.launcher/launch", {"id": NUVIO, "params": {"contentTarget": link}})
    say(f"Asked Nuvio to open {link} ({res.get('returnValue', res)})")
    await wait_for_app(client, NUVIO)
    pause = wait if wait is not None else (4 if was_open else 10)   # a cold start loads the app first
    say(f"Waiting {pause}s for the title's page to load ...")
    await asyncio.sleep(pause)
    await client.button("ENTER")
    say("Pressed OK (Play)")
    last = None
    deadline = time.monotonic() + 40
    while time.monotonic() < deadline:
        now = await media_state(client)
        if now != last:
            say(f"Media: {now}")
            last = now
        if isinstance(now, list) and any(s == "playing" for _, s in now):
            say("PLAYING")
            break
        await asyncio.sleep(1)
    else:
        say("Didn't see playback start within 40s. What's on screen?")
    await client.disconnect()


async def cmd_channel(app_id):
    """LG's app-to-app channel without the Pi: a phone (this Mac) joins a TV app and they exchange messages.

    Its own connection to the TV (the same handshake as aiowebostv, with the saved pairing key), printing every message.
    """
    import aiohttp
    from aiowebostv.handshake import REGISTRATION_PAYLOAD

    state = load()
    client = await tv_on(state)            # wakes the TV if needed, then opens the app
    say("TV on")
    await client.request("system.launcher/launch", {"id": app_id})
    await wait_for_app(client, app_id, 30)
    await client.disconnect()

    session = aiohttp.ClientSession()
    try:
        try:
            ws = await session.ws_connect(f"ws://{TV_IP}:3000", ssl=False)
        except (aiohttp.ClientConnectionError, aiohttp.WSServerHandshakeError):
            ws = await session.ws_connect(f"wss://{TV_IP}:3001", ssl=False)
        await ws.send_json({"id": "hello", "type": "hello", "payload": {}})
        await ws.receive_json()
        await ws.send_json({"id": "info", "type": "request", "uri": "ssap://system/getSystemInfo", "payload": {}})
        await ws.receive_json()
        reg = dict(REGISTRATION_PAYLOAD, **{"client-key": state["client_key"]})
        await ws.send_json({"id": "register", "type": "register", "payload": reg})
        while True:
            m = await ws.receive_json()
            if m.get("type") == "registered":
                break
            if m.get("type") == "error":
                sys.exit(f"Registration refused: {m}")
        say("Own connection registered.")

        received = []

        async def reader():
            async for raw in ws:
                if raw.type != aiohttp.WSMsgType.TEXT:
                    break
                m = json.loads(raw.data)
                received.append(m)
                say(f"<- {json.dumps(m)[:400]}")

        task = asyncio.create_task(reader())
        await ws.send_json({"id": "join", "type": "subscribe", "uri": "ssap://webapp/connectToApp", "payload": {"appId": app_id}})
        say("-> connectToApp(appId) (the TV waits for the app to register: up to 45 s)")
        for _ in range(90):
            await asyncio.sleep(0.5)
            if any(m.get("id") == "join" and (m.get("payload") or {}).get("state") == "CONNECTED" for m in received):
                say("CONNECTED")
                break
        else:
            say("Not connected after 45 s")
        for n in range(1, 4):
            await ws.send_json({"type": "p2p", "to": app_id, "payload": {"hello": "from the Mac", "n": n}})
            say(f"-> p2p {n}")
            await asyncio.sleep(2)
        say("Listening 10 s for the TV's replies ...")
        await asyncio.sleep(10)
        p2p = [m for m in received if m.get("type") == "p2p" or m.get("from")]
        say(f"Done: {len(received)} message(s) from the TV, {len(p2p)} from the app itself.")
        task.cancel()
        await ws.close()
    finally:
        await session.close()


def main():
    args = sys.argv[1:]
    if args and args[0] == "channel":
        asyncio.run(cmd_channel(args[1] if len(args) > 1 else "io.freemytv.channel3"))   # round 4
        return
    if args and args[0] == "play":
        rest = args[1:]
        wait = None
        if "--wait" in rest:
            i = rest.index("--wait")
            wait = float(rest[i + 1])
            rest = rest[:i] + rest[i + 2:]
        asyncio.run(cmd_play(rest[0] if rest else "nuvio://movie/tt0111161", wait))
        return
    if args and args[0] == "title":
        asyncio.run(cmd_title(args[1] if len(args) > 1 else "nuvio://movie/tt0111161"))
        return
    if args and args[0] == "deeplink":
        asyncio.run(cmd_deeplink(int(args[1]) if len(args) > 1 else None))
        return
    if not args or args[0] not in ("info", "off", "stremio", "input"):
        print(__doc__)
        sys.exit(1)
    if args[0] == "info":
        asyncio.run(cmd_info())
    elif args[0] == "off":
        asyncio.run(cmd_off())
    elif args[0] == "stremio":
        asyncio.run(cmd_stremio())
    else:
        if len(args) < 2:
            sys.exit("Which input? e.g. ./tvtest.sh input ps5")
        asyncio.run(cmd_input(" ".join(args[1:])))


if __name__ == "__main__":
    main()
