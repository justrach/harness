#!/usr/bin/env python3
"""Check the iOS App Store version, or attach a TestFlight build and submit it
for App Review.

Runs in the app-store workflow with the iOS team's App Store Connect key
(AC_API_KEY_PATH, AC_API_KEY_ID, AC_API_ISSUER_ID in the environment).

    scripts/app-store-submit.py check  [--build N]
    scripts/app-store-submit.py submit [--build N] [--release keep|after_approval|manual]

`check` changes nothing: it prints the version being prepared, its build,
screenshots, review details and any open review submission. `submit` attaches
the build, uploads the Apple Watch screenshots in apps/ios/app-store/watch if
the listing has none, and submits the version. Apple's own error text is
printed when it refuses a step (missing metadata, for example).
"""

import argparse
import hashlib
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "harness.codegraff.ios"
WATCH_SHOTS = pathlib.Path(__file__).resolve().parent.parent / "apps/ios/app-store/watch"
# 422 x 514, the Apple Watch Ultra slot; App Store Connect scales it for
# smaller watches.
WATCH_DISPLAY = "APP_WATCH_ULTRA"
EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"}
OPEN_SUBMISSION = {"READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES"}


class AppleError(Exception):
    pass


def token():
    import jwt  # PyJWT[crypto], installed by the workflow

    key = pathlib.Path(os.environ["AC_API_KEY_PATH"]).read_bytes()
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["AC_API_ISSUER_ID"], "iat": now, "exp": now + 1199, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": os.environ["AC_API_KEY_ID"], "typ": "JWT"},
    )


def api(method, path, body=None):
    url = path if path.startswith("https://") else API + path
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", f"Bearer {token()}")
    request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request) as response:
            raw = response.read()
    except urllib.error.HTTPError as error:
        raise AppleError(f"{method} {path.split('?')[0]}: {describe(error.read())}") from None
    return json.loads(raw) if raw else {}


def describe(raw):
    """Apple's errors, with the per-field reasons a refused submission carries."""
    try:
        errors = json.loads(raw).get("errors", [])
    except ValueError:
        return raw.decode(errors="replace")
    lines = []
    for error in errors:
        lines.append(f"{error.get('status')} {error.get('code')}: {error.get('title')} - {error.get('detail')}")
        for group in (error.get("meta") or {}).get("associatedErrors", {}).values():
            for item in group:
                lines.append(f"    {item.get('code')}: {item.get('detail')}")
    return "\n".join(lines) or raw.decode(errors="replace")


def find_app():
    apps = api("GET", f"/apps?filter[bundleId]={BUNDLE_ID}&fields[apps]=name,bundleId,primaryLocale")["data"]
    if len(apps) != 1:
        raise AppleError(f"Expected one app for {BUNDLE_ID}; found {len(apps)}.")
    return apps[0]


def find_build(app_id, number):
    query = f"/builds?filter[app]={app_id}&filter[processingState]=VALID&filter[expired]=false&sort=-uploadedDate&limit=1&include=preReleaseVersion"
    if number:
        query += f"&filter[version]={number}"
    reply = api("GET", query)
    if not reply["data"]:
        raise AppleError(f"No valid, unexpired build{' ' + number if number else ''} found.")
    build = reply["data"][0]
    marketing = next(
        item["attributes"]["version"] for item in reply.get("included", []) if item["type"] == "preReleaseVersions"
    )
    return build, marketing


def versions(app_id):
    return api(
        "GET",
        f"/apps/{app_id}/appStoreVersions?filter[platform]=IOS&limit=20"
        "&fields[appStoreVersions]=versionString,appVersionState,releaseType,createdDate",
    )["data"]


def pick_version(app_id, marketing, may_create):
    """The version to submit: the editable one, renamed to the build's
    marketing version if it differs, or a new one."""
    listed = versions(app_id)
    for version in listed:
        attributes = version["attributes"]
        print(f"  {attributes['versionString']}: {attributes['appVersionState']} (release {attributes.get('releaseType')})")
    editable = [v for v in listed if v["attributes"]["appVersionState"] in EDITABLE]
    if any(v["attributes"]["versionString"] == marketing and v not in editable for v in listed):
        state = next(v["attributes"]["appVersionState"] for v in listed if v["attributes"]["versionString"] == marketing)
        raise AppleError(
            f"Version {marketing} is already {state}. Raise MARKETING_VERSION in the Xcode project for a new release."
        )
    if editable:
        version = editable[0]
        if version["attributes"]["versionString"] != marketing:
            if not may_create:
                print(f"Would rename version {version['attributes']['versionString']} to {marketing}.")
                return version
            api("PATCH", f"/appStoreVersions/{version['id']}", {
                "data": {"type": "appStoreVersions", "id": version["id"], "attributes": {"versionString": marketing}},
            })
            print(f"Renamed version {version['attributes']['versionString']} to {marketing}.")
        return version
    if not may_create:
        print(f"Would create version {marketing}.")
        return None
    created = api("POST", "/appStoreVersions", {
        "data": {
            "type": "appStoreVersions",
            "attributes": {"platform": "IOS", "versionString": marketing},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
        },
    })["data"]
    print(f"Created version {marketing}.")
    return created


def localizations(version_id):
    return api(
        "GET",
        f"/appStoreVersions/{version_id}/appStoreVersionLocalizations"
        "?fields[appStoreVersionLocalizations]=locale,description,keywords,supportUrl,whatsNew",
    )["data"]


def screenshot_sets(localization_id):
    """(set id, display type, screenshot ids) for each slot."""
    reply = api(
        "GET",
        f"/appStoreVersionLocalizations/{localization_id}/appScreenshotSets?include=appScreenshots&limit=50",
    )
    return [
        (s["id"], s["attributes"]["screenshotDisplayType"], [i["id"] for i in s["relationships"]["appScreenshots"]["data"]])
        for s in reply["data"]
    ]


def report(app, build, marketing, version):
    print(f"Build {build['attributes']['version']} ({marketing}), uploaded {build['attributes']['uploadedDate']}.")
    if version is None:
        return
    attached = api("GET", f"/appStoreVersions/{version['id']}/build").get("data")
    print(f"Version {version['attributes']['versionString']} has build: "
          f"{attached['attributes']['version'] if attached else 'none'}")
    for localization in localizations(version["id"]):
        attributes = localization["attributes"]
        missing = [k for k in ("description", "keywords", "supportUrl") if not attributes.get(k)]
        print(f"  {attributes['locale']}: " + (f"missing {', '.join(missing)}" if missing else "text complete"))
        for _, display, shots in screenshot_sets(localization["id"]):
            print(f"    {display}: {len(shots)} screenshots")
    try:
        detail = api("GET", f"/appStoreVersions/{version['id']}/appStoreReviewDetail")["data"]
        attributes = detail["attributes"] if detail else {}
    except AppleError:
        attributes = {}
    contact = all(attributes.get(k) for k in ("contactFirstName", "contactLastName", "contactPhone", "contactEmail"))
    print(f"Review contact: {'set' if contact else 'MISSING'}; "
          f"demo account required: {attributes.get('demoAccountRequired')}; "
          f"notes: {'set' if attributes.get('notes') else 'none'}")
    for submission in open_submissions(app["id"]):
        print(f"Open review submission {submission['id']}: {submission['attributes']['state']}")


def open_submissions(app_id):
    reply = api(
        "GET",
        f"/reviewSubmissions?filter[app]={app_id}&filter[platform]=IOS"
        f"&filter[state]={','.join(sorted(OPEN_SUBMISSION))}&limit=10",
    )
    return reply["data"]


def upload_watch_shots(version_id):
    shots = sorted(WATCH_SHOTS.glob("*.png"))
    if not shots:
        print(f"No Watch screenshots in {WATCH_SHOTS.name}/; leaving the Watch slot as it is.")
        return
    for localization in localizations(version_id):
        locale = localization["attributes"]["locale"]
        sets = screenshot_sets(localization["id"])
        if any(display.startswith("APP_WATCH") and len(ids) >= len(shots) for _, display, ids in sets):
            print(f"  {locale}: Watch screenshots already there.")
            continue
        existing = next(((sid, ids) for sid, display, ids in sets if display == WATCH_DISPLAY), None)
        if existing:
            # A set an earlier run left part-way: start it again.
            set_id, ids = existing
            for screenshot_id in ids:
                api("DELETE", f"/appScreenshots/{screenshot_id}")
        else:
            set_id = api("POST", "/appScreenshotSets", {
                "data": {
                    "type": "appScreenshotSets",
                    "attributes": {"screenshotDisplayType": WATCH_DISPLAY},
                    "relationships": {"appStoreVersionLocalization": {
                        "data": {"type": "appStoreVersionLocalizations", "id": localization["id"]},
                    }},
                },
            })["data"]["id"]
        uploaded = {upload_screenshot(set_id, shot): shot.name for shot in shots}
        wait_for_processing(uploaded)
        print(f"  {locale}: uploaded {len(shots)} Watch screenshots.")


def upload_screenshot(set_id, path):
    data = path.read_bytes()
    reserved = api("POST", "/appScreenshots", {
        "data": {
            "type": "appScreenshots",
            "attributes": {"fileName": path.name, "fileSize": len(data)},
            "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}},
        },
    })["data"]
    for operation in reserved["attributes"]["uploadOperations"]:
        part = data[operation["offset"]:operation["offset"] + operation["length"]]
        request = urllib.request.Request(operation["url"], data=part, method=operation["method"])
        for header in operation.get("requestHeaders", []):
            request.add_header(header["name"], header["value"])
        urllib.request.urlopen(request).read()
    api("PATCH", f"/appScreenshots/{reserved['id']}", {
        "data": {
            "type": "appScreenshots",
            "id": reserved["id"],
            "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()},
        },
    })
    return reserved["id"]


def wait_for_processing(uploaded):
    """Apple processes screenshots after upload; it can take minutes."""
    pending = dict(uploaded)
    deadline = time.time() + 600
    while pending:
        for screenshot_id, name in list(pending.items()):
            reply = api("GET", f"/appScreenshots/{screenshot_id}?fields[appScreenshots]=assetDeliveryState")
            delivery = reply["data"]["attributes"]["assetDeliveryState"]
            if delivery["state"] == "COMPLETE":
                del pending[screenshot_id]
            elif delivery["state"] == "FAILED":
                raise AppleError(f"{name} was refused: {delivery.get('errors')}")
        if not pending:
            return
        if time.time() > deadline:
            raise AppleError(f"Still processing after ten minutes: {', '.join(sorted(pending.values()))}.")
        time.sleep(10)


def submit(app, build, marketing, release):
    version = pick_version(app["id"], marketing, may_create=True)
    api("PATCH", f"/appStoreVersions/{version['id']}/relationships/build", {
        "data": {"type": "builds", "id": build["id"]},
    })
    print(f"Attached build {build['attributes']['version']} to version {marketing}.")
    if release != "keep":
        api("PATCH", f"/appStoreVersions/{version['id']}", {
            "data": {"type": "appStoreVersions", "id": version["id"], "attributes": {"releaseType": release.upper()}},
        })
        print(f"Release type: {release.upper()}.")
    upload_watch_shots(version["id"])

    submissions = open_submissions(app["id"])
    pending = [s for s in submissions if s["attributes"]["state"] == "READY_FOR_REVIEW"]
    waiting = [s for s in submissions if s["attributes"]["state"] != "READY_FOR_REVIEW"]
    if waiting:
        raise AppleError(f"A submission is already {waiting[0]['attributes']['state']}; nothing to submit.")
    if pending:
        submission_id = pending[0]["id"]
    else:
        submission_id = api("POST", "/reviewSubmissions", {
            "data": {
                "type": "reviewSubmissions",
                "attributes": {"platform": "IOS"},
                "relationships": {"app": {"data": {"type": "apps", "id": app["id"]}}},
            },
        })["data"]["id"]
    items = api("GET", f"/reviewSubmissions/{submission_id}/items")["data"]
    if not items:
        api("POST", "/reviewSubmissionItems", {
            "data": {
                "type": "reviewSubmissionItems",
                "relationships": {
                    "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission_id}},
                    "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}},
                },
            },
        })
    done = api("PATCH", f"/reviewSubmissions/{submission_id}", {
        "data": {"type": "reviewSubmissions", "id": submission_id, "attributes": {"submitted": True}},
    })["data"]
    print(f"Submitted version {marketing} (build {build['attributes']['version']}) for App Review: "
          f"{done['attributes']['state']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=["check", "submit"])
    parser.add_argument("--build", default="", help="TestFlight build number (default: the newest valid one)")
    parser.add_argument("--release", default="keep", choices=["keep", "after_approval", "manual"])
    args = parser.parse_args()
    try:
        app = find_app()
        build, marketing = find_build(app["id"], args.build)
        if args.action == "check":
            print(f"{app['attributes']['name']} versions:")
            report(app, build, marketing, pick_version(app["id"], marketing, may_create=False))
        else:
            submit(app, build, marketing, args.release)
    except AppleError as error:
        print(f"::error::{error}".replace("\n", "%0A"))
        print(str(error), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
