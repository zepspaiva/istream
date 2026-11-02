"""TV service: a small HTTP API on the Raspberry Pi that the Nuvio Web fork calls to control the LG TV.

    GET  /api/health
    GET  /api/status                      power, app on screen, playback state, the running job
    POST /api/play    {type, id, title}   TV on -> Nuvio on the title -> Play (Nuvio's "First stream" setting plays it)
    POST /api/open    {type, id, title}   the same, without pressing Play
    POST /api/launch  {target}            nuvio | stremio | ps5 | switch | an app id | an input name
    POST /api/off
    POST /api/button  {name}              UP DOWN LEFT RIGHT ENTER BACK HOME PLAY PAUSE ...
    POST /api/volume  {direction}         up | down | mute
    POST /api/text    {text, enter}       types into the text box selected on the TV
    POST /api/stream  {url, title, label, poster, meta, session}
                                          TV on -> Free My TV plays that video link (no Nuvio), showing the title's details
    GET  /api/session                     what's playing: the title and its episodes
    GET  /api/subs/<key>/list             the subtitles sent with that video {subs: [{i, lang, sdh}]}
    GET  /api/subs/<key>/<n>              one of them, as timed lines {cues: [{s, e, t}]}
    POST /api/subtitles {url, subtitles}  subtitles that came after the video: added to it on the TV
    POST /api/player/cmd {cmd}            audio | pause | play | stop, for Free My TV's player
    GET  /api/player/log                  what the TV's player reported (formats, tracks, errors)

Settings come from the environment: TV_IP (192.168.1.34), PORT (8080), DATA_DIR (/data, where tv.json keeps the
pairing key and the TV's MAC addresses).
"""
import collections
import hashlib
import json
import logging
import os
import re

from aiohttp import web

import subs as subtitles
from tv import NUVIO, STREMIO, TV

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"), format="%(asctime)s %(name)s %(message)s")
log = logging.getLogger("server")

tv = TV(os.environ.get("TV_IP", "192.168.1.34"), os.path.join(os.environ.get("DATA_DIR", "/data"), "tv.json"))

BUTTONS = {"UP", "DOWN", "LEFT", "RIGHT", "ENTER", "BACK", "HOME", "EXIT", "PLAY", "PAUSE", "STOP", "REWIND",
           "FASTFORWARD", "MENU", "INFO", "RED", "GREEN", "YELLOW", "BLUE", "CC", "MUTE"}
APPS = {"nuvio": (NUVIO, "Nuvio"), "stremio": (STREMIO, "Stremio"), "freemytv": ("io.freemytv", "Free My TV")}


def ok(**extra):
    return web.json_response(dict({"ok": True}, **extra))


def bad(message, status=400):
    return web.json_response({"error": message}, status=status)


async def body(request):
    try:
        return await request.json()
    except Exception:
        return {}


async def health(request):
    return ok()


async def status(request):
    return web.json_response(await tv.status())


async def play(request, press_play=True):
    b = await body(request)
    kind = "series" if b.get("type") == "series" else "movie"
    item_id = str(b.get("id") or "").strip()
    if not item_id or any(c in item_id for c in "/?#& "):
        return bad("Missing or odd title id")
    title = str(b.get("title") or item_id)[:120]
    return ok(job=tv.play(kind, item_id, title, press_play=press_play))


async def open_title(request):
    return await play(request, press_play=False)


async def launch(request):
    target = str((await body(request)).get("target") or "").strip()
    if target.lower() in APPS:
        app_id, label = APPS[target.lower()]
        return ok(job=tv.launch(app_id, label))
    app_id, label = tv.input_id(target)
    if app_id:
        return ok(job=tv.launch(app_id, label or target))
    if "." in target:
        return ok(job=tv.launch(target, target))
    return bad("Unknown target: %s" % target)


async def stream(request):
    b = await body(request)
    url = str(b.get("url") or "")
    if not url.startswith(("http://", "https://")):
        return bad("url must be http(s)")
    title = str(b.get("title") or "Video")[:120]
    port = int(os.environ.get("PORT", "8080"))
    log_url = "http://%s:%d/api/player/log" % (tv.own_address(), port)
    PLAYER_LOG.append("---- %s [%s]" % (title, str(b.get("label") or "")[:160]))
    poster = web_url(b.get("poster"))
    meta = clean_meta(b.get("meta"))
    session = clean_session(b.get("session"))
    subs = clean_subtitles(b.get("subtitles"))
    if session:
        session.update({"url": url, "title": title, "meta": meta, "poster": poster, "subtitles": subs})
        tv.set_session(session)
    return ok(job=tv.stream(url, title, str(b.get("label") or "")[:160], b.get("start"), log_url, poster, meta,
                            subs_params(url, subs)))


def subs_params(url, subs):
    """The subtitles for the TV: listed by place, read from /api/subs/<key>/<place> (key: this video, so an older
    list never answers for a newer video)."""
    key = hashlib.sha1(url.encode("utf-8")).hexdigest()[:12]
    SUBS[key] = subs
    while len(SUBS) > 20:
        SUBS.pop(next(iter(SUBS)))
    if not subs:
        return {}
    port = int(os.environ.get("PORT", "8080"))
    # Only where to ask: the TV refuses a launch whose message is too big, so it reads the list itself (<subsUrl>list).
    return {"subsUrl": "http://%s:%d/api/subs/%s/" % (tv.own_address(), port, key), "subsCount": len(subs)}


async def late_subtitles(request):
    """Subtitles that reached the phone after the video was sent: added to what's playing on the TV."""
    b = await body(request)
    url = str(b.get("url") or "")
    subs = clean_subtitles(b.get("subtitles"))
    if not url.startswith(("http://", "https://")) or not subs:
        return bad("url and subtitles needed")
    params = subs_params(url, subs)
    if tv.session and tv.session.get("url") == url:
        tv.session["subtitles"] = subs
        tv.set_session(tv.session)
    try:
        await tv.player_command("subs", dict(params, url=url))
    except Exception as e:
        return bad(str(e), 409)
    return ok()


# The subtitles each video was sent with: {key: [{lang, url, sdh, addon}]}, the newest last.
SUBS = collections.OrderedDict()
CUES = collections.OrderedDict()   # (key, index) -> parsed cues, the newest last


def clean_subtitles(items):
    out = []
    for x in (items or [])[:40] if isinstance(items, list) else []:
        if isinstance(x, dict) and web_url(x.get("url")):
            out.append({"lang": clip(x.get("lang"), 20) or "und", "url": web_url(x.get("url")), "sdh": bool(x.get("sdh")),
                        "addon": clip(x.get("addon"), 60) or ""})
    return out


async def list_subs(request):
    """The subtitles sent with a video, by place: [{i, lang, sdh}] (the TV reads them, then each one by its place)."""
    subs = SUBS.get(request.match_info["key"])
    if subs is None:
        return bad("No such video", 404)
    return web.json_response({"subs": [{"i": i, "lang": x["lang"], "sdh": x["sdh"]} for i, x in enumerate(subs)]})


async def get_subs(request):
    """A subtitle as timed lines for the TV: fetched from its add-on, read (SRT or WebVTT), kept for the next ask."""
    key, index = request.match_info["key"], request.match_info["index"]
    try:
        item = SUBS[key][int(index)]
    except (KeyError, IndexError, ValueError):
        return bad("No such subtitle", 404)
    cached = CUES.get((key, index))
    if cached is None:
        try:
            cached = await subtitles.fetch_cues(item["url"])
        except Exception as e:
            log.warning("subtitle %s/%s failed: %s", key, index, e)
            return bad("Couldn't get the subtitle", 502)
        CUES[(key, index)] = cached
        while len(CUES) > 30:
            CUES.popitem(last=False)
    return web.json_response({"lang": item["lang"], "cues": cached})


def web_url(value):
    value = str(value or "")[:1000]
    return value if value.startswith(("http://", "https://")) else ""


def clip(value, limit=600):
    return str(value)[:limit] if value not in (None, "") else None


def number(value):
    try:
        n = int(value)
        return n if 0 <= n < 10000 else None
    except (TypeError, ValueError):
        return None


def clean_meta(meta):
    """The title's details for the TV (its home screen's hero and start screen): only what it shows."""
    if not isinstance(meta, dict):
        return {}
    out = {
        "show": clip(meta.get("show"), 160),
        "season": number(meta.get("season")),
        "episode": number(meta.get("episode")),
        "episodeTitle": clip(meta.get("episodeTitle"), 160),
        "description": clip(meta.get("description"), 320),
        "backdrop": web_url(meta.get("backdrop")) or None,
        "logo": web_url(meta.get("logo")) or None,
        "year": clip(meta.get("year"), 20),
        "runtime": clip(meta.get("runtime"), 20),
        "country": clip(meta.get("country"), 80),
    }
    return {k: v for k, v in out.items() if v is not None}


def clean_session(session):
    """What's playing, kept on the Pi: the title and its episodes (for Next episode and the Episodes list)."""
    if not isinstance(session, dict) or not session.get("contentId"):
        return None
    episodes = []
    for e in (session.get("episodes") or [])[:2000]:
        if isinstance(e, dict) and e.get("videoId"):
            episodes.append({
                "videoId": clip(e.get("videoId"), 120), "season": number(e.get("season")), "episode": number(e.get("episode")),
                "title": clip(e.get("title"), 160), "overview": clip(e.get("overview"), 600),
                "thumbnail": web_url(e.get("thumbnail")) or None, "released": clip(e.get("released"), 40),
            })
    return {"type": "series" if session.get("type") == "series" else "movie", "contentId": clip(session.get("contentId"), 120),
            "videoId": clip(session.get("videoId"), 120), "episodes": episodes}


async def get_session(request):
    return web.json_response(tv.session or {})


async def player_cmd(request):
    cmd = str((await body(request)).get("cmd") or "")
    if cmd not in ("audio", "pause", "play", "stop"):
        return bad("Unknown player command")
    try:
        await tv.player_command(cmd)
    except Exception as e:
        return bad(str(e), 409)
    return ok()


# What the TV's player reports (formats, tracks, errors): it posts here, and anyone can read it back.
PLAYER_LOG = collections.deque(maxlen=400)


async def player_log_post(request):
    try:
        data = json.loads(await request.text())
        for line in data.get("lines", [])[:100]:
            PLAYER_LOG.append(str(line)[:2000])
    except Exception:
        return bad("bad log")
    return ok()


async def player_log_get(request):
    return web.Response(text="\n".join(PLAYER_LOG) + "\n", content_type="text/plain")


@web.middleware
async def cors(request, handler):
    """Free My TV runs from file:// on the TV: let it post its log and read subtitles."""
    if request.method == "OPTIONS":
        resp = web.Response()
    else:
        resp = await handler(request)
    if request.path.startswith(("/api/player/", "/api/subs/")):
        resp.headers["Access-Control-Allow-Origin"] = "*"
        resp.headers["Access-Control-Allow-Headers"] = "Content-Type"
        resp.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
    return resp


async def inputs(request):
    """The TV's HDMI inputs that have a name (the console's own, like "PS5"), for the app's TV tab."""
    named = {k: v for k, v in (tv.state.get("inputs") or {}).items()
             if v and not re.match(r"^(hdmi|av|component)\s*\d*$", v.strip(), re.I)}
    return web.json_response({"inputs": [{"id": k, "name": v.replace(" Game Console", "")} for k, v in named.items()]})


async def off(request):
    return ok(job=tv.off())


async def button(request):
    name = str((await body(request)).get("name") or "").upper()
    if name not in BUTTONS:
        return bad("Unknown button")
    try:
        await tv.button(name)
    except Exception as e:
        return bad(str(e), 409)
    return ok()


async def volume(request):
    direction = str((await body(request)).get("direction") or "")
    if direction not in ("up", "down", "mute"):
        return bad("direction: up, down or mute")
    try:
        await tv.volume(direction)
    except Exception as e:
        return bad(str(e), 409)
    return ok()


async def text(request):
    b = await body(request)
    try:
        await tv.type_text(str(b.get("text") or "")[:500], bool(b.get("enter")))
    except Exception as e:
        return bad(str(e), 409)
    return ok()


def make_app():
    app = web.Application(middlewares=[cors])
    app.add_routes([
        web.post("/api/stream", stream),
        web.post("/api/player/cmd", player_cmd),
        web.get("/api/session", get_session),
        web.post("/api/subtitles", late_subtitles),
        web.get("/api/subs/{key}/list", list_subs),
        web.get("/api/subs/{key}/{index}", get_subs),
        web.options("/api/subs/{key}/{index}", health),
        web.post("/api/player/log", player_log_post),
        web.get("/api/player/log", player_log_get),
        web.options("/api/player/log", health),
        web.get("/api/health", health),
        web.get("/api/status", status),
        web.get("/api/inputs", inputs),
        web.post("/api/play", play),
        web.post("/api/open", open_title),
        web.post("/api/launch", launch),
        web.post("/api/off", off),
        web.post("/api/button", button),
        web.post("/api/volume", volume),
        web.post("/api/text", text),
    ])
    return app


if __name__ == "__main__":
    web.run_app(make_app(), host=os.environ.get("HOST", "0.0.0.0"), port=int(os.environ.get("PORT", "8080")))
