#!/usr/bin/env python3
"""Wait for an uploaded build to finish processing in App Store Connect.

Run by .github/workflows/build.yml after the upload. It polls the App Store
Connect API until the build with the given build number is processed, then
makes sure every internal TestFlight group can test it, so "uploaded" in the
log means "installable from TestFlight", not just "sent".

Environment: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (the .p8 file),
BUNDLE_ID, BUILD_NUMBER. Optional: WAIT_MINUTES (default 45).
Needs PyJWT and cryptography.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com"


def token() -> str:
    with open(os.environ["ASC_KEY_PATH"], "rb") as handle:
        key = handle.read()
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1100,
         "aud": "appstoreconnect-v1"},
        key, algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


def call(method: str, path: str, params: dict | None = None,
         body: dict | None = None) -> dict:
    url = API + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {token()}",
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise RuntimeError(f"{method} {path} failed with {error.code}: {detail}")


def notice(message: str) -> None:
    print(f"::notice::{message}", flush=True)


def fail(message: str) -> None:
    print(f"::error::{message}", flush=True)
    sys.exit(1)


def main() -> None:
    bundle_id = os.environ["BUNDLE_ID"]
    build_number = os.environ["BUILD_NUMBER"]
    deadline = time.time() + 60 * int(os.environ.get("WAIT_MINUTES", "45"))

    apps = call("GET", "/v1/apps", {"filter[bundleId]": bundle_id})["data"]
    if not apps:
        fail(f"No app with bundle ID {bundle_id} in App Store Connect.")
    app_id = apps[0]["id"]
    print(f"App: {apps[0]['attributes'].get('name')} ({app_id})", flush=True)

    build = None
    state = None
    while time.time() < deadline:
        found = call("GET", "/v1/builds", {
            "filter[app]": app_id,
            "filter[version]": build_number,
            "fields[builds]": "version,processingState,uploadedDate,expired",
        })["data"]
        if found:
            build = found[0]
            state = build["attributes"].get("processingState")
            print(f"Build {build_number}: {state}", flush=True)
            if state == "VALID":
                break
            if state in ("FAILED", "INVALID"):
                fail(f"App Store Connect rejected build {build_number} "
                     f"({state}). Its email to the account holder says why.")
        else:
            print(f"Build {build_number} not listed yet", flush=True)
        time.sleep(60)
    else:
        fail(f"Build {build_number} was still {state or 'not listed'} after "
             "the wait. It may still finish; check TestFlight.")

    groups = call("GET", f"/v1/apps/{app_id}/betaGroups",
                  {"limit": "50"})["data"]
    internal = [g for g in groups if g["attributes"].get("isInternalGroup")]
    if not internal:
        notice(f"Build {build_number} is processed and ready to test, but the "
               "app has no internal TestFlight group yet. Add one under "
               "TestFlight > Internal Testing and include yourself.")
        return
    for group in internal:
        name = group["attributes"].get("name")
        if group["attributes"].get("hasAccessToAllBuilds"):
            print(f"Internal group '{name}' gets every build automatically.")
            continue
        try:
            call("POST", f"/v1/betaGroups/{group['id']}/relationships/builds",
                 body={"data": [{"type": "builds", "id": build["id"]}]})
            print(f"Added build {build_number} to internal group '{name}'.")
        except RuntimeError as error:
            print(f"Could not add the build to '{name}': {error}")
    notice(f"Build {build_number} is processed and available in TestFlight.")


if __name__ == "__main__":
    main()
