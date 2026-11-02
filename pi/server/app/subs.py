"""Subtitles for the TV: a subtitle file from an add-on (SRT or WebVTT, any encoding, maybe gzipped) as timed lines.

The TV draws them itself, so it gets plain cues: [{"s": start seconds, "e": end seconds, "t": text}].
"""
import gzip
import re

import aiohttp

TIME = r"(?:(\d+):)?(\d{1,2}):(\d{1,2})[,.](\d{1,3})"
CUE = re.compile(TIME + r"\s*-->\s*" + TIME)
TAGS = re.compile(r"<[^>]*>|\{\\[^}]*\}")   # <i>, <font ...>, and ASS overrides like {\an8}


def _seconds(h, m, s, ms):
    return int(h or 0) * 3600 + int(m) * 60 + int(s) + int((ms + "00")[:3]) / 1000.0


def decode(raw):
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    for enc in ("utf-8-sig", "cp1252", "latin-1"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", "replace")


def parse(text):
    """SRT and WebVTT alike: every block with a "start --> end" line; the lines after it are the text."""
    cues = []
    blocks = re.split(r"\r?\n\s*\r?\n", text.replace("\r\n", "\n"))
    for block in blocks:
        lines = block.strip("\n").split("\n")
        for i, line in enumerate(lines):
            m = CUE.search(line)
            if not m:
                continue
            g = m.groups()
            start, end = _seconds(*g[0:4]), _seconds(*g[4:8])
            body = "\n".join(TAGS.sub("", x).strip() for x in lines[i + 1:]).strip()
            if body and end > start:
                cues.append({"s": round(start, 3), "e": round(end, 3), "t": body[:400]})
            break
    cues.sort(key=lambda c: c["s"])
    return cues


async def fetch_cues(url):
    timeout = aiohttp.ClientTimeout(total=20)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        async with session.get(url, headers={"User-Agent": "FreeMyTV/1.0"}) as resp:
            resp.raise_for_status()
            # The whole file (content.read(n) stops at what has arrived so far: a subtitle cut after a few minutes).
            raw = bytearray()
            async for chunk in resp.content.iter_chunked(65536):
                raw += chunk
                if len(raw) > MAX_BYTES:
                    break
    return parse(decode(bytes(raw)))


MAX_BYTES = 8 * 1024 * 1024
