"""Sends the iPhone that shared the link a notification: transcript ready, fetched only, or why it failed.
Uses the Jot-only APNs key from the repo's Actions secrets. Never fails the run."""
import glob
import json
import os
import sys
import time

import httpx
import jwt

out = sys.argv[1]
key, kid = os.environ.get("APNS_KEY", ""), os.environ.get("APNS_KEY_ID", "")
if not key or not kid:
    print("No APNs key in this repo's secrets; skipping the push.")
    sys.exit(0)

def first_words(text, limit=90):
    text = " ".join(text.split())
    return text if len(text) <= limit else text[:limit].rsplit(" ", 1)[0] + "…"

info = {}
for p in glob.glob(f"{out}/source.info.json"):
    info = json.load(open(p))
who = info.get("uploader_id") or info.get("channel") or info.get("uploader") or ""
who = f"@{who}" if who and info.get("extractor_key", "").lower().startswith("instagram") and not who.startswith("@") else who

if os.environ.get("TRANSCRIBED") == "success":
    t = json.load(open(f"{out}/transcript.json"))
    said = first_words(" ".join(s["text"] for s in t["segments"]))
    again = os.environ.get("MODEL", "small") not in ("", "small")
    title, body = "Listened again" if again else "Transcript ready", f"{who}: {said}" if who else said
elif os.environ.get("FETCHED") == "success":
    title, body = "Fetched", "Open Jot to transcribe it."
else:
    err = open(f"{out}/error.txt").read() if os.path.exists(f"{out}/error.txt") else ""
    reason = "it needs a login" if "login" in err.lower() else "the post couldn't be fetched"
    title, body = "Couldn't get this one", f"{reason.capitalize()}. Open Jot for details."

payload = {"aps": {"alert": {"title": title, "body": body}, "sound": "default", "thread-id": "jot"},
           "request": os.environ["REQUEST"]}
token = jwt.encode({"iss": os.environ["APNS_TEAM"], "iat": int(time.time())}, key, algorithm="ES256", headers={"kid": kid})
sandbox = os.environ.get("SANDBOX") == "true"
with httpx.Client(http2=True, timeout=15) as client:
    for env in (sandbox, not sandbox):  # a build signed the other way uses the other APNs
        host = "api.sandbox.push.apple.com" if env else "api.push.apple.com"
        r = client.post(f"https://{host}/3/device/{os.environ['DEVICE']}", content=json.dumps(payload),
                        headers={"authorization": f"bearer {token}", "apns-topic": "com.kezlahd.jot",
                                 "apns-push-type": "alert", "apns-priority": "10"})
        print(host, r.status_code, r.text)
        if r.status_code == 200 or "BadDeviceToken" not in r.text:
            break
