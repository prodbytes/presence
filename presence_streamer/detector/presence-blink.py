#!/usr/bin/env python3
"""The streamer's Blink helper (specs/streamer.md, "Blink cameras"):
blinkpy (https://pypi.org/project/blinkpy/) logs in to a Blink account and
fetches its cameras' clips, for presence-streamer, which turns each camera
into a Presence device. It speaks JSON lines on stdout; nothing else goes
there (blinkpy's log goes to stderr). The password never goes to a file.

  presence-blink.py login --token FILE
      Reads {"email", "password"} as one line on stdin. Prints
      {"state": "pin-required"} when Blink sends a 2FA PIN, then reads
      {"pin"} as the next line (in the same process: blinkpy's OAuth state
      is in memory). Prints {"state": "ok", "cameras": [...]} and saves the
      token (mode 600), or {"state": "error", "error"}.

  presence-blink.py cameras --token FILE
      {"state": "ok", "cameras": [{"id", "name", "network"}]}.

  presence-blink.py fetch --token FILE --since EPOCH --out DIR
      Downloads the clips made since EPOCH (seconds), not deleted, each to
      DIR/<camera id>/rec-blink-<UTC start>.mp4 (kept if it's there), one
      {"clip": {"camera", "name", "file", "start"}} line each, then
      {"state": "ok", "latest": EPOCH}.

Exit status 0, 2 for a login Blink refused (the token's no good: log in
again), 1 for anything else.
"""
import argparse
import asyncio
import datetime
import json
import logging
import os
import sys


def say(**fields):
    print(json.dumps(fields), flush=True)


def save_token(blink_auth, path):
    data = dict(blink_auth.login_attributes)
    # The password is never kept: the token and its refresh token do.
    data.pop("password", None)
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def cameras_of(blink):
    out = []
    for name, camera in blink.cameras.items():
        out.append({
            "id": str(getattr(camera, "camera_id", "") or name),
            "name": getattr(camera, "name", name) or name,
            "network": str(getattr(camera, "network_id", "") or ""),
        })
    return sorted(out, key=lambda c: c["name"].lower())


async def open_blink(session, token_path):
    from blinkpy.auth import Auth
    from blinkpy.blinkpy import Blink
    with open(token_path) as f:
        data = json.load(f)
    blink = Blink(session=session)
    blink.auth = Auth(data, no_prompt=True, session=session)
    if not await blink.start():
        raise PermissionError("Blink refused the saved login")
    save_token(blink.auth, token_path)
    return blink


async def login(args):
    from aiohttp import ClientSession
    from blinkpy.auth import Auth, BlinkTwoFARequiredError
    from blinkpy.blinkpy import Blink
    line = sys.stdin.readline()
    creds = json.loads(line or "{}")
    async with ClientSession() as session:
        blink = Blink(session=session)
        blink.auth = Auth({"username": creds.get("email", ""), "password": creds.get("password", "")},
                          no_prompt=True, session=session)
        try:
            ok = await blink.start()
        except BlinkTwoFARequiredError:
            say(state="pin-required")
            pin = json.loads(sys.stdin.readline() or "{}").get("pin", "")
            if not pin:
                say(state="error", error="no PIN came")
                return 2
            ok = await blink.send_2fa_code(str(pin).strip())
        if not ok:
            say(state="error", error="Blink refused the login (email, password or PIN)")
            return 2
        save_token(blink.auth, args.token)
        say(state="ok", cameras=cameras_of(blink))
        return 0


async def cameras(args):
    from aiohttp import ClientSession
    async with ClientSession() as session:
        blink = await open_blink(session, args.token)
        say(state="ok", cameras=cameras_of(blink))
        return 0


def start_of(created_at):
    """Blink's created_at (ISO, with a zone) as UTC."""
    t = datetime.datetime.fromisoformat(str(created_at).replace("Z", "+00:00"))
    if t.tzinfo is None:
        t = t.replace(tzinfo=datetime.timezone.utc)
    return t.astimezone(datetime.timezone.utc)


async def fetch(args):
    from aiohttp import ClientSession
    async with ClientSession() as session:
        blink = await open_blink(session, args.token)
        ids = {}
        for name, camera in blink.cameras.items():
            ids[name.lower()] = str(getattr(camera, "camera_id", "") or name)
        since = datetime.datetime.fromtimestamp(args.since, datetime.timezone.utc)
        # With its zone: blinkpy reads a time without one as local.
        items = await blink.get_videos_metadata(since=since.isoformat(), stop=10)
        latest = args.since
        for item in sorted(items, key=lambda i: str(i.get("created_at", ""))):
            try:
                start = start_of(item["created_at"])
                name = item["device_name"]
                address = item["media"]
            except (KeyError, ValueError):
                continue
            if item.get("deleted"):
                continue
            # Blink's since is when a clip last changed, not when it was
            # made: a clip from before where fetching got to comes back
            # (and would be fetched again each time). Skipped here.
            if int(start.timestamp()) < args.since:
                continue
            camera = str(item.get("device_id") or ids.get(str(name).lower()) or name)
            folder = os.path.join(args.out, camera)
            os.makedirs(folder, exist_ok=True)
            path = os.path.join(folder, "rec-blink-" + start.strftime("%Y%m%dT%H%M%S") + ".mp4")
            if not os.path.exists(path):
                response = await blink.do_http_get(address)
                body = await response.read()
                tmp = path + ".part"
                with open(tmp, "wb") as f:
                    f.write(body)
                os.replace(tmp, path)
                say(clip={"camera": camera, "name": name, "file": path, "start": start.isoformat()})
            latest = max(latest, int(start.timestamp()))
        save_token(blink.auth, args.token)
        say(state="ok", latest=latest)
        return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["login", "cameras", "fetch"])
    parser.add_argument("--token", required=True)
    parser.add_argument("--since", type=int, default=0)
    parser.add_argument("--out")
    args = parser.parse_args()
    logging.basicConfig(stream=sys.stderr, level=logging.WARNING)
    try:
        return asyncio.run({"login": login, "cameras": cameras, "fetch": fetch}[args.command](args))
    except PermissionError as e:
        say(state="error", error=str(e))
        return 2
    except Exception as e:  # noqa: BLE001 (told to the streamer, which logs it)
        say(state="error", error=f"{type(e).__name__}: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
