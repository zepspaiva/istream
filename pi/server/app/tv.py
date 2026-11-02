"""The LG TV: waking it, opening apps and inputs, pressing buttons, typing, and playing a title in Nuvio.

Every action opens its own short connection to the TV's remote API (port 3000/3001), the way the LG phone app does:
about 0.3 s when the TV is on, and nothing left half-open when it goes to sleep.
"""
import asyncio
import json
import logging
import os
import socket
import time

from aiowebostv import WebOsClient

log = logging.getLogger("tv")

NUVIO = "space.nuvio.webos"
STREMIO = "io.strem.tv"
PLAYER = "io.freemytv"   # Free My TV plays video links itself (web/player.js)


class TV:
    def __init__(self, host, state_path):
        self.host = host
        self.state_path = state_path
        self.state = self._load()
        self.lock = asyncio.Lock()          # one action at a time
        self.job = None                     # the running play/launch job (asyncio.Task)
        self.job_info = {"id": 0, "step": "", "done": True, "ok": True, "title": ""}
        self._status_cache = (0.0, None)
        self.session = self._load_session()   # what's playing: the title and its episodes (main.py: /api/stream)

    # --- state (pairing key, MAC addresses, input names) -------------------------------------------------------

    def _load(self):
        try:
            with open(self.state_path) as f:
                return json.load(f)
        except FileNotFoundError:
            return {}

    def _save(self):
        os.makedirs(os.path.dirname(self.state_path), exist_ok=True)
        with open(self.state_path, "w") as f:
            json.dump(self.state, f, indent=2)

    def _load_session(self):
        try:
            with open(os.path.join(os.path.dirname(self.state_path), "session.json")) as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    def set_session(self, session):
        """What's playing (the title and its episodes), kept across restarts."""
        self.session = session
        path = os.path.join(os.path.dirname(self.state_path), "session.json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            json.dump(session, f)

    # --- connection ---------------------------------------------------------------------------------------------

    async def connect(self, timeout=3.0):
        """A connected client, or None when the TV doesn't answer (off, or asleep without its network on)."""
        client = WebOsClient(self.host, self.state.get("client_key"), connect_timeout=timeout)
        try:
            await client.connect()
        except Exception as e:
            log.debug("connect failed: %s", e)
            try:
                await client.disconnect()
            except Exception:
                pass
            return None
        if client.client_key and client.client_key != self.state.get("client_key"):
            self.state["client_key"] = client.client_key   # first pairing from this machine
            self._save()
        if not self.state.get("inputs") and client.tv_state.inputs:
            self.state["inputs"] = {k: (v.get("label") or "") for k, v in client.tv_state.inputs.items()}
            self._save()
        return client

    def magic_packet(self):
        prefix = self.host.rsplit(".", 1)[0]
        for mac in self.state.get("macs") or []:
            raw = bytes.fromhex(mac.replace(":", "").replace("-", ""))
            packet = b"\xff" * 6 + raw * 16
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
                for addr in ("255.255.255.255", prefix + ".255", self.host):
                    for port in (9, 7):
                        try:
                            s.sendto(packet, (addr, port))
                        except OSError:
                            pass

    async def on(self, step=lambda s: None, seconds=45):
        """A connected client with the TV on, waking it if needed. Returns (client, was_already_on)."""
        client = await self.connect()
        if client and client.tv_state.is_on:
            return client, True
        step("Waking the TV")
        if client:
            try:
                await client.power_on()
            except Exception:
                pass
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if not (client and client.tv_state.is_on):
                self.magic_packet()
            if client is None:
                client = await self.connect()
            if client and client.tv_state.is_on:
                return client, False
            if client and not client.is_connected():
                client = None
            await asyncio.sleep(1)
        if client:
            await client.disconnect()
        raise RuntimeError("The TV didn't turn on. Is 'Turn on via Wi-Fi' on?")

    async def wait_for_app(self, client, app_id, seconds=20):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                if (await client.get_current_app()) == app_id:
                    return True
            except Exception:
                pass
            await asyncio.sleep(0.4)
        return False

    # --- jobs: long actions run in the background; the phone polls /api/status --------------------------------

    def start_job(self, title, coro_fn):
        if self.job and not self.job.done():
            self.job.cancel()
        info = {"id": self.job_info["id"] + 1, "step": "Starting", "done": False, "ok": True, "title": title}
        self.job_info = info

        def step(text):
            info["step"] = text
            log.info("[job %s] %s", info["id"], text)

        async def run():
            try:
                async with self.lock:
                    await coro_fn(step)
                info["ok"] = True
            except asyncio.CancelledError:
                info["ok"] = False
                info["step"] = "Cancelled"
                raise
            except Exception as e:
                log.exception("job failed")
                info["ok"] = False
                info["step"] = str(e) or e.__class__.__name__
            finally:
                info["done"] = True
                self._status_cache = (0.0, None)

        self.job = asyncio.create_task(run())
        return info["id"]

    async def _launch(self, step, app_id, params=None, label=None):
        client, was_on = await self.on(step)
        try:
            step("Opening %s" % (label or app_id))
            payload = {"id": app_id}
            if params:
                payload["params"] = params
            await client.request("system.launcher/launch", payload)
            await self.wait_for_app(client, app_id)
            step("Done")
        finally:
            await client.disconnect()

    def launch(self, app_id, label=None, params=None):
        return self.start_job(label or app_id, lambda step: self._launch(step, app_id, params, label))

    def input_id(self, name):
        want = name.lower()
        for app_id, label in (self.state.get("inputs") or {}).items():
            if want in app_id.lower() or want in (label or "").lower():
                return app_id, label
        return None, None

    async def _play(self, step, kind, item_id, title, press_play):
        link = "nuvio://%s/%s" % ("series" if kind == "series" else "movie", item_id)
        client, was_on = await self.on(step)
        try:
            try:
                was_open = was_on and (await client.get_current_app()) == NUVIO
            except Exception:
                was_open = False
            step("Opening %s in Nuvio" % title)
            await client.request("system.launcher/launch", {"id": NUVIO, "params": {"contentTarget": link}})
            await self.wait_for_app(client, NUVIO)
            if not press_play:
                step("Done")
                return
            # The title's page needs a moment: longer when Nuvio starts from scratch.
            await asyncio.sleep(4 if was_open else 12)
            step("Pressing Play")
            await client.button("ENTER")
            step("Loading the stream")
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                try:
                    media = await client.get_media_foreground_app()
                except Exception:
                    media = []
                if any(m.get("playState") == "playing" for m in media):
                    step("Playing")
                    return
                await asyncio.sleep(1)
            step("Sent Play; check the TV")
        finally:
            await client.disconnect()

    def play(self, kind, item_id, title, press_play=True):
        return self.start_job(title, lambda step: self._play(step, kind, item_id, title, press_play))

    def own_address(self):
        """This machine's address on the TV's network (what the TV can reach us at)."""
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            try:
                s.connect((self.host, 9))
                return s.getsockname()[0]
            except OSError:
                return "127.0.0.1"

    async def _stream(self, step, params, title):
        client, was_on = await self.on(step)
        try:
            step("Opening Free My TV")
            try:
                await client.request("system.launcher/launch", {"id": PLAYER, "params": params})
            except Exception as e:   # the TV can refuse a launch while the app is busy: once more, a moment later
                log.warning("launch refused (%s), trying again", e)
                await asyncio.sleep(1.5)
                try:
                    await client.request("system.launcher/launch", {"id": PLAYER, "params": params})
                except Exception as e2:
                    raise RuntimeError("The TV wouldn't open Free My TV with this video (%s)" % e2) from e2
            await self.wait_for_app(client, PLAYER)
            step("Loading the stream")
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                try:
                    media = await client.get_media_foreground_app()
                except Exception:
                    media = []
                if any(m.get("playState") == "playing" for m in media):
                    step("Playing")
                    return
                await asyncio.sleep(1)
            step("Sent to the player; check the TV")
        finally:
            await client.disconnect()

    def stream(self, url, title, label="", start=None, log_url=None, poster="", meta=None, extra=None):
        """Plays a video link in Free My TV's player on the TV (no Nuvio), with the title's details (meta) and
        anything else the player takes (extra: its subtitles)."""
        params = {"url": url, "title": title, "label": label, "poster": poster, "meta": meta or {}}
        params.update(extra or {})
        if start:
            params["start"] = start
        if log_url:
            params["logUrl"] = log_url
        return self.start_job(title, lambda step: self._stream(step, params, title))

    async def player_command(self, cmd, params=None):
        """A command for the open player, through a relaunch ({cmd: 'audio'}: next audio track; {cmd: 'subs', subs,
        subsUrl, url}: subtitles for the video at url)."""
        client = await self.connect()
        if not client:
            raise RuntimeError("The TV is off")
        try:
            await client.request("system.launcher/launch", {"id": PLAYER, "params": dict(params or {}, cmd=cmd)})
        finally:
            await client.disconnect()

    async def _off(self, step):
        client = await self.connect()
        if not client:
            step("Already off")
            return
        try:
            await client.power_off()
            step("Off")
        finally:
            await client.disconnect()

    def off(self):
        return self.start_job("TV", self._off)

    # --- quick actions (no job): buttons and typing ----------------------------------------------------------

    async def button(self, name):
        client = await self.connect()
        if not client:
            raise RuntimeError("The TV is off")
        try:
            await client.button(name)
        finally:
            await client.disconnect()

    async def type_text(self, text, enter=False):
        client = await self.connect()
        if not client:
            raise RuntimeError("The TV is off")
        try:
            if text:
                await client.request("com.webos.service.ime/insertText", {"text": text, "replace": 0})
            if enter:
                await client.request("com.webos.service.ime/sendEnterKey")
        finally:
            await client.disconnect()

    async def volume(self, direction):
        client = await self.connect()
        if not client:
            raise RuntimeError("The TV is off")
        try:
            if direction == "up":
                await client.volume_up()
            elif direction == "down":
                await client.volume_down()
            else:
                await client.set_mute(not client.tv_state.muted)
        finally:
            await client.disconnect()

    # --- status ------------------------------------------------------------------------------------------------

    async def status(self):
        at, cached = self._status_cache
        if cached and time.monotonic() - at < 2.5:
            return dict(cached, job=self.job_info)
        client = await self.connect(timeout=2.0)
        if not client:
            st = {"power": "off", "app": None, "appTitle": None, "media": None}
        else:
            try:
                ts = client.tv_state
                app = ts.current_app_id
                title = ((ts.apps or {}).get(app) or {}).get("title") or ((ts.inputs or {}).get(app) or {}).get("label")
                media = None
                if ts.is_on:
                    try:
                        m = await client.get_media_foreground_app()
                        media = m[0].get("playState") if m else None
                    except Exception:
                        pass
                st = {"power": "on" if ts.is_on else "standby", "app": app, "appTitle": title, "media": media,
                      "volume": ts.volume, "muted": ts.muted}
            finally:
                await client.disconnect()
        self._status_cache = (time.monotonic(), st)
        return dict(st, job=self.job_info)
