#!/usr/bin/env python3
"""Register the Expanse system and the FIRETEC app with Tapis, then run the smoke tests.

  python3 tapis/deploy.py render                     fill templates from site.env into rendered/ (no Tapis calls)
  python3 tapis/deploy.py system [--update]          create the Expanse execution system (or patch it)
  python3 tapis/deploy.py credential                 register SSH_PRIVATE_KEY_FILE for EXPANSE_USER
  python3 tapis/deploy.py check                      confirm Tapis can see the archive, cases and scratch
  python3 tapis/deploy.py app [--update]             create the FIRETEC app version (or replace it)
  python3 tapis/deploy.py submit JOB.json [--watch]  submit a job template, e.g. tapis/jobs/smoke-fire.json
  python3 tapis/deploy.py watch JOB_UUID             follow a job until it ends
  python3 tapis/deploy.py smoke                      run the four smoke tests and check each outcome

Settings come from site.env (override any of them with an environment variable of the
same name). Auth: TAPIS_JWT if exported, otherwise TAPIS_USERNAME plus TAPIS_PASSWORD or
a password prompt. Requires: pip install tapipy
"""
import argparse
import getpass
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
PLACEHOLDER = re.compile(r"\{\{([A-Z0-9_]+)\}\}")
TERMINAL = {"FINISHED", "FAILED", "CANCELLED"}
# Fields accepted by PATCH /v3/systems (SystemPatchRequest.json). id, systemType,
# rootDir, canExec and owner cannot be changed after creation.
SYSTEM_PATCHABLE = {
    "description", "host", "effectiveUserId", "defaultAuthnMethod", "port", "useProxy",
    "proxyHost", "proxyPort", "dtnSystemId", "canRunBatch", "enableCmdPrefix", "mpiCmd",
    "jobRuntimes", "jobWorkingDir", "jobEnvVariables", "jobMaxJobs", "jobMaxJobsPerUser",
    "batchScheduler", "batchSchedulerProfile", "batchLogicalQueues", "batchDefaultLogicalQueue",
    "jobCapabilities", "tags", "notes", "allowChildren", "importRefId",
}
# (job template, expected final status, expected app exit status from the launcher)
SMOKE_TESTS = [
    ("smoke-nofire", "FINISHED", 0),
    ("smoke-fire", "FINISHED", 0),
    ("smoke-bad-decomp", "FAILED", 1),
    ("smoke-bad-input", "FAILED", 3),
]


# ----------------------------------------------------------------------------- settings
def load_settings(path):
    settings = {}
    if not path.exists():
        sys.exit(f"settings file not found: {path}")
    for n, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            sys.exit(f"{path}:{n}: expected KEY=VALUE")
        key, value = line.split("=", 1)
        value = re.split(r"\s+#", value, maxsplit=1)[0].strip().strip("\"'")
        settings[key.strip()] = value
    for key, value in os.environ.items():
        if key in settings or key.startswith(("TAPIS_", "EXPANSE_", "FIRETEC_", "MY_")):
            settings[key] = value
    for _ in range(5):  # resolve {{KEY}} references between settings; empty keys stay unresolved
        changed = False
        for key, value in settings.items():
            new = PLACEHOLDER.sub(lambda m: settings.get(m.group(1)) or m.group(0), value)
            if new != value:
                settings[key], changed = new, True
        if not changed:
            break
    return settings


def render(template, settings):
    text = Path(template).read_text()

    def fill(match):
        value = settings.get(match.group(1), "")
        return json.dumps(value)[1:-1] if value else match.group(0)

    text = PLACEHOLDER.sub(fill, text)
    unresolved = sorted(set(PLACEHOLDER.findall(text)))
    if unresolved:
        sys.exit(f"{Path(template).name}: set {', '.join(unresolved)} in site.env")
    for marker in ("xxxxxxx", "CHANGE_ME"):
        if marker in text:
            sys.exit(f"{Path(template).name}: site.env still contains the example value '{marker}'")
    return json.loads(text)


# ----------------------------------------------------------------------------- tapis helpers
def client(settings):
    try:
        from tapipy.tapis import Tapis
    except ImportError:
        sys.exit("tapipy is required: pip install tapipy")
    base_url = settings.get("TAPIS_BASE_URL") or sys.exit("set TAPIS_BASE_URL in site.env")
    if settings.get("TAPIS_JWT"):
        return Tapis(base_url=base_url, access_token=settings["TAPIS_JWT"])
    user = settings.get("TAPIS_USERNAME") or sys.exit("set TAPIS_USERNAME in site.env (or export TAPIS_JWT)")
    password = settings.get("TAPIS_PASSWORD") or getpass.getpass(f"Tapis password for {user} at {base_url}: ")
    tapis = Tapis(base_url=base_url, username=user, password=password)
    tapis.get_tokens()
    return tapis


def short(err):
    text = str(err)
    match = re.search(r"message:\s*(.*)", text, re.S)
    return (match.group(1) if match else text).strip().splitlines()[0][:300]


def exists(call, **kwargs):
    try:
        call(**kwargs)
        return True
    except Exception as err:  # tapipy raises typed errors; match on the 404 text to stay version-agnostic
        text = str(err)
        if "404" in text or "NOT_FOUND" in text or "not found" in text.lower():
            return False
        raise


def field(result, name, default=None):
    return getattr(result, name, default)


# ----------------------------------------------------------------------------- commands
def cmd_render(args, s):
    out = ROOT / "rendered"
    out.mkdir(exist_ok=True)
    templates = [HERE / "expanse-system.json", HERE / "firetec-app.json", *sorted((HERE / "jobs").glob("*.json"))]
    for template in templates:
        body = render(template, s)
        target = out / template.name
        target.write_text(json.dumps(body, indent=2) + "\n")
        print(f"rendered {target.relative_to(ROOT)}")


def cmd_system(args, s):
    body = render(HERE / "expanse-system.json", s)
    tapis, sid = client(s), body["id"]
    if exists(tapis.systems.getSystem, systemId=sid):
        if not args.update:
            sys.exit(f"system {sid} already exists; rerun with --update to patch it")
        patch = {k: v for k, v in body.items() if k in SYSTEM_PATCHABLE}
        tapis.systems.patchSystem(systemId=sid, **patch)
        print(f"patched system {sid}")
    else:
        tapis.systems.createSystem(**body)
        print(f"created system {sid}; next: deploy.py credential")


def cmd_credential(args, s):
    keyfile = Path(os.path.expanduser(s.get("SSH_PRIVATE_KEY_FILE", "")))
    if not keyfile.is_file():
        sys.exit("set SSH_PRIVATE_KEY_FILE in site.env to the private key Tapis should use")
    private = keyfile.read_text()
    public = None
    if shutil.which("ssh-keygen"):
        probe = subprocess.run(["ssh-keygen", "-y", "-P", "", "-f", str(keyfile)], capture_output=True, text=True)
        if probe.returncode != 0:
            sys.exit(f"{keyfile} needs a passphrase (or is unreadable); Tapis needs a passphrase-less key")
        public = probe.stdout.strip()
    pubfile = keyfile.with_name(keyfile.name + ".pub")
    if public is None and pubfile.is_file():
        public = pubfile.read_text().strip()
    if not public:
        sys.exit(f"could not read or derive the public key ({pubfile})")
    sid, user = s.get("SYSTEM_ID"), s.get("EXPANSE_USER")
    if not (sid and user):
        sys.exit("set SYSTEM_ID and EXPANSE_USER in site.env")
    # Static effectiveUserId: the credential is stored under the login user itself.
    client(s).systems.createUserCredential(systemId=sid, userName=user, privateKey=private, publicKey=public)
    print(f"registered key {keyfile.name} for {user} on {sid}; Tapis logged in to check it")


def cmd_check(args, s):
    tapis, sid = client(s), s.get("SYSTEM_ID")
    targets = [
        ("app archive", s.get("APP_ARCHIVE", "")),
        ("smoke cases", s.get("CASES_DIR", "")),
        ("parent of jobWorkingDir", str(Path(s.get("JOB_WORKING_DIR", "/")).parent)),
    ]
    ok = True
    for label, path in targets:
        if not path or PLACEHOLDER.search(path) or "xxxxxxx" in path:
            print(f"SKIP {label}: not set in site.env")
            ok = False
            continue
        try:
            entries = tapis.files.listFiles(systemId=sid, path=path.lstrip("/"))
            print(f"ok   {label}: {path} ({len(entries)} entr{'y' if len(entries) == 1 else 'ies'})")
        except Exception as err:
            print(f"FAIL {label}: {path}: {short(err)}")
            ok = False
    sys.exit(0 if ok else 1)


def cmd_app(args, s):
    body = render(HERE / "firetec-app.json", s)
    tapis, app_id, version = client(s), body["id"], body["version"]
    if exists(tapis.apps.getApp, appId=app_id, appVersion=version):
        if not args.update:
            sys.exit(f"app {app_id} {version} exists; set a new APP_VERSION for a new archive, or rerun with --update")
        tapis.apps.putApp(appId=app_id, appVersion=version, **{k: v for k, v in body.items() if k not in ("id", "version")})
        print(f"replaced app {app_id} {version}")
    else:
        tapis.apps.createAppVersion(**body)
        print(f"created app {app_id} {version}")


def submit(tapis, template, s):
    body = render(template, s)
    job = tapis.jobs.submitJob(**body)
    print(f"submitted {body['name']}: {job.uuid}")
    return job.uuid


def watch(tapis, uuid, poll=15):
    last = None
    while True:
        try:
            status = tapis.jobs.getJobStatus(jobUuid=uuid).status
        except Exception as err:
            print(f"  status check failed ({short(err)}); retrying")
            status = last
        if status != last:
            print(f"  {time.strftime('%H:%M:%S')}  {status}", flush=True)
            last = status
        if status in TERMINAL:
            break
        time.sleep(poll)
    job = tapis.jobs.getJob(jobUuid=uuid)
    print(f"  condition: {field(job, 'condition')}   app exit status: {field(job, 'remoteResultInfo')}")
    print(f"  last message: {field(job, 'lastMessage')}")
    print(f"  outputs on Expanse: {field(job, 'execSystemOutputDir')}/case  (launcher log: tapisjob.out)")
    return status, field(job, "remoteResultInfo")


def cmd_submit(args, s):
    tapis = client(s)
    uuid = submit(tapis, args.template, s)
    if args.watch:
        status, _ = watch(tapis, uuid)
        sys.exit(0 if status == "FINISHED" else 1)


def cmd_watch(args, s):
    status, _ = watch(client(s), args.uuid)
    sys.exit(0 if status == "FINISHED" else 1)


def cmd_smoke(args, s):
    tapis, rows = client(s), []
    for name, want_status, want_code in SMOKE_TESTS:
        print(f"\n== {name} (expect {want_status})")
        uuid = submit(tapis, HERE / "jobs" / f"{name}.json", s)
        status, info = watch(tapis, uuid)
        match = re.match(r"\s*(\d+)", str(info or ""))
        code = int(match.group(1)) if match else None
        passed = status == want_status and (code is None or code == want_code)
        rows.append((name, want_status, status, code, "PASS" if passed else "FAIL", uuid))
    print("\n{:<18} {:<9} {:<9} {:<5} {:<5} {}".format("test", "expected", "got", "exit", "", "job"))
    for row in rows:
        print("{:<18} {:<9} {:<9} {:<5} {:<5} {}".format(row[0], row[1], row[2], str(row[3]), row[4], row[5]))
    sys.exit(0 if all(r[4] == "PASS" for r in rows) else 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--site", type=Path, default=ROOT / "site.env", help="settings file (default: site.env)")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("render")
    sub.add_parser("system").add_argument("--update", action="store_true")
    sub.add_parser("credential")
    sub.add_parser("check")
    sub.add_parser("app").add_argument("--update", action="store_true")
    p = sub.add_parser("submit")
    p.add_argument("template", type=Path)
    p.add_argument("--watch", action="store_true")
    sub.add_parser("watch").add_argument("uuid")
    sub.add_parser("smoke")
    args = parser.parse_args()
    settings = load_settings(args.site)
    handlers = {"render": cmd_render, 
                "system": cmd_system, 
                "credential": cmd_credential, 
                "check": cmd_check,
                "app": cmd_app, 
                "submit": cmd_submit, 
                "watch": cmd_watch, 
                "smoke": cmd_smoke
            }
    try:
        handlers[args.command](args, settings)
    except KeyboardInterrupt:
        sys.exit(130)
    except SystemExit:
        raise
    except Exception as err:
        sys.exit(f"{args.command} failed: {short(err)}")


if __name__ == "__main__":
    main()
