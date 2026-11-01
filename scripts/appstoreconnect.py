#!/usr/bin/env python3
"""Small App Store Connect API client for the Release workflow.

  appstoreconnect.py register-devices UDID[,UDID...]
  appstoreconnect.py ensure-bundle-id IDENTIFIER NAME
  appstoreconnect.py setup-testflight BUNDLE_ID EMAIL[,EMAIL...]

Reads ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID from the environment.
Needs PyJWT and cryptography.
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

import jwt


def token():
    key = open(os.environ["ASC_KEY_PATH"]).read()
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900,
                       "aud": "appstoreconnect-v1"},
                      key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"]})


TOKEN = None


def call(method, path, body=None):
    global TOKEN
    TOKEN = TOKEN or token()
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, method=method,
                                 data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": "Bearer " + TOKEN,
                                          "Content-Type": "application/json"})
    with urllib.request.urlopen(req) as response:
        data = response.read()
        return json.loads(data) if data else {}


def error_text(e):
    try:
        return "; ".join(x.get("detail", x.get("title", "")) for x in json.loads(e.read())["errors"])
    except Exception:
        return str(e)


def register_devices(udids):
    known = {d["attributes"]["udid"].upper()
             for d in call("GET", "/v1/devices?limit=200&filter[platform]=IOS")["data"]}
    for n, udid in enumerate(u.strip() for u in udids.split(",") if u.strip()):
        if not re.fullmatch(r"[0-9A-Fa-f-]{24,40}", udid):
            print(f"::warning::Skipping {udid!r}: not a UDID")
        elif udid.upper() in known:
            print(f"{udid} is already registered")
        else:
            try:
                call("POST", "/v1/devices", {"data": {"type": "devices", "attributes": {
                    "name": f"iPhone {n + 1} (HMacViewer)", "udid": udid, "platform": "IOS"}}})
                print(f"Registered {udid}")
            except urllib.error.HTTPError as e:
                print(f"::warning::Could not register {udid}: {error_text(e)}")


def ensure_bundle_id(identifier, name):
    found = call("GET", f"/v1/bundleIds?filter[identifier]={identifier}")["data"]
    if any(b["attributes"]["identifier"] == identifier for b in found):
        print(f"Bundle ID {identifier} exists")
        return
    call("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {
        "identifier": identifier, "name": name, "platform": "IOS"}}})
    print(f"Registered bundle ID {identifier}")


def setup_testflight(bundle_id, emails):
    """An internal group that gets every build, with the given testers in it."""
    apps = call("GET", f"/v1/apps?filter[bundleId]={bundle_id}")["data"]
    if not apps:
        print(f"::warning::No App Store Connect app for {bundle_id}. Create it once: "
              "appstoreconnect.apple.com > Apps > + > New App, then run Release again.")
        return 1
    app = apps[0]["id"]
    groups = call("GET", f"/v1/apps/{app}/betaGroups?limit=50")["data"]
    group = next((g["id"] for g in groups if g["attributes"].get("isInternalGroup")
                  and g["attributes"].get("hasAccessToAllBuilds")), None)
    if group is None:
        group = call("POST", "/v1/betaGroups", {"data": {"type": "betaGroups",
            "attributes": {"name": "HMacViewer", "isInternalGroup": True, "hasAccessToAllBuilds": True},
            "relationships": {"app": {"data": {"type": "apps", "id": app}}}}})["data"]["id"]
        print("Created the internal TestFlight group")
    for email in (e.strip() for e in emails.split(",") if e.strip()):
        try:
            call("POST", "/v1/betaTesters", {"data": {"type": "betaTesters",
                "attributes": {"email": email},
                "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": group}]}}}})
            print(f"Invited {email} to TestFlight")
        except urllib.error.HTTPError as e:
            # 409: already a tester. Internal testers must be App Store Connect users.
            print(f"{email}: {error_text(e)}")
    return 0


if __name__ == "__main__":
    command, args = sys.argv[1], sys.argv[2:]
    try:
        if command == "register-devices":
            register_devices(*args)
        elif command == "ensure-bundle-id":
            ensure_bundle_id(*args)
        elif command == "setup-testflight":
            sys.exit(setup_testflight(*args))
        else:
            sys.exit(__doc__)
    except urllib.error.HTTPError as e:
        sys.exit(f"App Store Connect: {e.code} {error_text(e)}")
