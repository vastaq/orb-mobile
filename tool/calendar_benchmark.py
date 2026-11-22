"""Prepare and verify synthetic Calendar Provider rows on a dedicated Android emulator.

In a fresh emulator with Orb's calendar permission still undecided:

    python3 tool/calendar_benchmark.py --device emulator-5590 seed
    python3 tool/calendar_benchmark.py --device emulator-5590 verify before
    python3 tool/calendar_benchmark.py --device emulator-5590 observe

While the observer waits, run in another terminal:

    flutter test --no-uninstall -d emulator-5590 integration_test/android_calendar_provider_test.dart \
        --dart-define=ORB_CALENDAR_NATIVE_UAT=true

The observer operates Android's permission dialog and checks the system provider before each
test checkpoint proceeds. To verify an actual launch from the event receipt, leave the fixture
and grant in place. Use these two commands in separate terminals:

    python3 tool/calendar_benchmark.py --device emulator-5590 observe-open
    flutter test --no-uninstall -d emulator-5590 integration_test/android_calendar_provider_test.dart \
        --dart-define=ORB_CALENDAR_OPEN_UAT=true

The opening report identifies the external Activity Android actually displayed and records
whether the event title was visible. Inspect and clean the synthetic local account after the run:

    python3 tool/calendar_benchmark.py --device emulator-5590 inspect
    python3 tool/calendar_benchmark.py --device emulator-5590 cleanup
"""
import argparse
import json
import os
import re
import shlex
import subprocess
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

AUTHORITY = "content://com.android.calendar/"
ACCOUNT = "orb.calendar.benchmark"
CALENDAR = "Orb Calendar Lab"
GUARD = "Orb Calendar Guard"
CALENDAR_URI = AUTHORITY + "calendars"
EVENT_URI = AUTHORITY + "events"
SYNC = "?caller_is_syncadapter=true&account_name=" + ACCOUNT + "&account_type=LOCAL"
START = int(datetime(2032, 6, 12, 10, tzinfo=timezone.utc).timestamp() * 1000)
HOUR = 3600000
TEST_TITLE = "Exhibit pickup"
CONTROL_TITLE = "Keep this booking"


class Fixture:
    def __init__(self, serial):
        if not re.fullmatch(r"emulator-\d+", serial):
            raise ValueError("Use a dedicated Android emulator.")
        sdk = os.environ.get("ANDROID_HOME")
        adb = str(Path(sdk, "platform-tools", "adb")) if sdk else "adb"
        self.adb = [adb, "-s", serial]
        if self.shell("getprop", "ro.boot.qemu") != "1" and self.shell("getprop", "ro.kernel.qemu") != "1":
            raise ValueError("The selected device is not an emulator.")

    def shell(self, *args):
        result = subprocess.run(self.adb + ["shell", shlex.join(map(str, args))], check=True,
                                capture_output=True, text=True, timeout=60)
        text = result.stdout.strip()
        if "Error while accessing provider" in text or "java.lang." in text:
            raise RuntimeError("The emulator Calendar Provider rejected the fixture operation.")
        return text

    def rows(self, uri, columns, where):
        text = self.shell("content", "query", "--uri", uri, "--projection", ":".join(columns), "--where", where)
        result = []
        for line in text.splitlines():
            match = re.fullmatch(r"Row: \d+ (.*)", line)
            if match:
                # Only synthetic rows are selected. Their fixture fields contain no commas.
                result.append(dict(item.split("=", 1) for item in match[1].split(", ")))
            elif line.strip() != "No result found.":
                raise RuntimeError("Unexpected response from emulator Calendar Provider.")
        return result

    def calendars(self):
        rows = self.rows(CALENDAR_URI, ["_id", "calendar_displayName"],
                         f"account_name='{ACCOUNT}' AND account_type='LOCAL' AND deleted=0")
        return {r["calendar_displayName"]: int(r["_id"]) for r in rows}

    def insert(self, uri, **fields):
        args = []
        for name, value in fields.items():
            args += ["--bind", f"{name}:{'l' if isinstance(value, int) else 's'}:{value}"]
        self.shell("content", "insert", "--uri", uri, *args)

    def seed(self):
        if self.calendars():
            raise ValueError("This synthetic fixture already exists. Inspect or explicitly clean it first.")
        for title in [CALENDAR, GUARD]:
            self.insert(CALENDAR_URI + SYNC, account_name=ACCOUNT, account_type="LOCAL", name=title,
                        calendar_displayName=title, calendar_access_level=700, ownerAccount=ACCOUNT,
                        calendar_timezone="UTC", calendar_color=-16744448, visible=1, sync_events=1)
        calendars = self.calendars()
        if set(calendars) != {CALENDAR, GUARD}:
            raise RuntimeError("Synthetic local calendars were not created.")
        self.insert(EVENT_URI, calendar_id=calendars[GUARD], title=CONTROL_TITLE, dtstart=START,
                    dtend=START + HOUR, eventTimezone="UTC", eventLocation="Archive")
        self.insert(EVENT_URI, calendar_id=calendars[CALENDAR], title="Daily sample", dtstart=START-HOUR,
                    duration="PT30M", rrule="FREQ=DAILY;COUNT=3", eventTimezone="UTC")
        self.insert(EVENT_URI, calendar_id=calendars[CALENDAR], title="Day sample", dtstart=START-10*HOUR,
                    dtend=START+14*HOUR, allDay=1, eventTimezone="UTC")
        lab = calendars[CALENDAR]
        for name in ["Local group sample", "Only organizer sample"]:
            self.insert(EVENT_URI, calendar_id=lab, title=name, dtstart=START+3*HOUR,
                        dtend=START+4*HOUR, eventTimezone="UTC", hasAttendeeData=1)
            event = self.rows(EVENT_URI, ["_id"], f"calendar_id={lab} AND title='{name}' AND deleted=0")[0]
            self.insert(AUTHORITY+"attendees", event_id=int(event["_id"]), attendeeEmail=ACCOUNT,
                        attendeeRelationship=2, attendeeType=1, attendeeStatus=1)
            if name == "Local group sample":
                self.insert(AUTHORITY+"attendees", event_id=int(event["_id"]), attendeeEmail="guest@orb.invalid",
                            attendeeRelationship=1, attendeeType=1, attendeeStatus=1)
        return calendars

    def events(self, calendar):
        return self.rows(EVENT_URI, ["_id","title","dtstart","dtend","eventLocation","allDay","rrule"],
                         f"calendar_id={int(calendar)} AND deleted=0")

    def verify(self, stage):
        calendars = self.calendars()
        left, right = calendars[CALENDAR], calendars[GUARD]
        both = self.rows(EVENT_URI, ["calendar_id", "_id", "title", "dtstart", "dtend", "duration",
                                    "eventLocation", "allDay", "rrule"], f"calendar_id IN ({left},{right}) AND deleted=0")
        lab = [e for e in both if int(e["calendar_id"]) == left]
        guard = [e for e in both if int(e["calendar_id"]) == right]
        rows = [r for r in lab if r["title"] in (TEST_TITLE, TEST_TITLE + " revised")]
        def signature(r):
            return (r["title"], r["dtstart"], r["dtend"], r["duration"], r["eventLocation"], r["allDay"], r["rrule"])
        control = [signature(e) for e in guard] == [
            (CONTROL_TITLE, str(START), str(START+HOUR), "NULL", "Archive", "0", "NULL")]
        preserved = sorted(signature(e) for e in lab if e not in rows) == [
            ("Daily sample", str(START-HOUR), "NULL", "PT30M", "NULL", "0", "FREQ=DAILY;COUNT=3"),
            ("Day sample", str(START-10*HOUR), str(START+14*HOUR), "NULL", "NULL", "1", "NULL"),
            ("Local group sample", str(START+3*HOUR), str(START+4*HOUR), "NULL", "NULL", "0", "NULL"),
            ("Only organizer sample", str(START+3*HOUR), str(START+4*HOUR), "NULL", "NULL", "0", "NULL")]
        group = next((e for e in lab if e["title"] == "Local group sample"), None)
        participants = self.rows(AUTHORITY+"attendees", ["attendeeEmail"], f"event_id={group['_id']}") if group else []
        attendees_intact = {r["attendeeEmail"] for r in participants} == {ACCOUNT, "guest@orb.invalid"}
        if stage in ("created","updated"):
            delta = HOUR if stage == "updated" else 0
            expected_title = TEST_TITLE + (" revised" if delta else "")
            expected_room = "Studio B" if delta else "Studio A"
            correct = len(rows) == 1 and rows[0]["title"] == expected_title and rows[0]["eventLocation"] == expected_room and (
                int(rows[0]["dtstart"]), int(rows[0]["dtend"])) == (START + delta, START + delta + HOUR)
        else:
            correct = not rows
        return {"stage":stage, "target_correct":correct, "other_events_intact":preserved,
                "other_calendar_intact":control, "attendees_intact":attendees_intact,
                "passed":correct and preserved and control and attendees_intact}

    def cleanup(self):
        for id_ in self.calendars().values():
            self.shell("content", "delete", "--uri", f"{CALENDAR_URI}/{id_}{SYNC}")
        if self.calendars():
            raise RuntimeError("Synthetic calendar cleanup failed.")

    def window(self):
        xml = "/data/local/tmp/orb-calendar-uat-window.xml"
        self.shell("rm", "-f", xml)
        self.shell("uiautomator", "dump", xml)
        try:
            return ET.fromstring(self.shell("cat", xml))
        except (subprocess.CalledProcessError, ET.ParseError):
            return None
        finally:
            self.shell("rm", "-f", xml)

    def click(self, node):
        x1,y1,x2,y2 = map(int, re.findall(r"\d+", node.attrib["bounds"]))
        self.shell("input", "tap", (x1+x2)//2, (y1+y2)//2)

    def observe_open(self):
        since = self.shell("date", "+%m-%d %H:%M:%S.000")
        guard = self.calendars()[GUARD]
        event = next(e for e in self.events(guard) if e["title"] == CONTROL_TITLE)
        uri = f"{EVENT_URI}/{event['_id']}"
        component = self.shell("cmd", "package", "resolve-activity", "--brief", "-a",
                               "android.intent.action.VIEW", "-t", "vnd.android.cursor.item/event",
                               "-d", uri).splitlines()[-1]
        if "/" not in component:
            raise RuntimeError("No calendar application handles this event URI.")
        package = component.split("/", 1)[0]
        until = time.monotonic() + 600
        uid = self.shell("cmd", "package", "list", "packages", "-U", "studio.orb.orb_mobile").split("uid:")[-1]
        while time.monotonic() < until:
            log = self.shell("logcat", "-d", "-T", since, "-s", "ActivityTaskManager:I")
            launch = re.search(r"START [^\n]+act=android.intent.action.VIEW dat=content://com.android.calendar/[^\n]+cmp=" +
                               re.escape(component) + r"[^\n]+from uid " + re.escape(uid) + r"\b", log)
            displayed = re.findall(r"Displayed (" + re.escape(package) + r"/\S+) for user", log[launch.end():]) if launch else []
            if displayed:
                window = self.window()
                visible = window is not None and any(CONTROL_TITLE in n.get(k,"") for n in window.iter("node") for k in ("text","content-desc"))
                print(json.dumps({"resolved_component":component,"displayed_component":displayed[-1],
                                  "target_title_visible":visible}), flush=True)
                self.shell("run-as", "studio.orb.orb_mobile", "touch", "cache/orb-calendar-open-ack")
                for _ in range(3):
                    stack = self.shell("dumpsys", "activity", "activities")
                    if re.search(r"topResumedActivity=.*?studio\.orb\.orb_mobile/", stack):
                        break
                    self.shell("input", "keyevent", "BACK")
                    time.sleep(0.5)
                return
            time.sleep(0.5)
        raise RuntimeError(f"The system did not display a calendar activity for Orb's event intent to {component}.")

    def observe(self, start_at):
        package = "studio.orb.orb_mobile"
        ack = "cache/orb-calendar-uat-ack"
        stages = ["deny_permission", "denied", "allow_permission", "created", "updated", "deleted"]
        for stage in stages[stages.index(start_at):]:
            until = time.monotonic() + (600 if stage == "deny_permission" else 180)
            while time.monotonic() < until:
                try:
                    current = self.shell("run-as", package, "cat", "cache/orb-calendar-uat-step")
                except subprocess.CalledProcessError:
                    current = ""
                if current == stage:
                    break
                time.sleep(0.3)
            else:
                raise RuntimeError(f"Timed out waiting for {stage}.")
            if stage in ("allow_permission", "deny_permission"):
                button = "permission_allow_button" if stage == "allow_permission" else "permission_deny_button"
                while time.monotonic() < until:
                    window = self.window()
                    if window is not None:
                        hang = next((n for n in window.iter("node") if n.get("resource-id")=="android:id/aerr_wait"), None)
                        if hang is not None:
                            self.click(hang)
                            continue
                        for node in window.iter("node"):
                            if (node.get("resource-id", "").endswith(":id/" + button)
                                    and "permissioncontroller" in node.get("package", "")):
                                self.click(node)
                                break
                        else:
                            time.sleep(0.3)
                            continue
                        break
                else:
                    raise RuntimeError(f"System calendar permission dialog missing for {stage}.")
                print(json.dumps({"permission_dialog":stage}), flush=True)
            else:
                result = self.verify("cancelled" if stage == "denied" else stage)
                print(json.dumps(result), flush=True)
                if not result["passed"]:
                    raise RuntimeError("Independent Calendar Provider check failed.")
                self.shell("run-as", package, "sh", "-c", f"echo {stage} > {ack}")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--device", required=True)
    p.add_argument("--from-stage", default="deny_permission",
                   choices=["deny_permission", "denied", "allow_permission", "created", "updated", "deleted"])
    p.add_argument("action", choices=["seed", "inspect", "verify", "observe", "observe-open", "cleanup"])
    p.add_argument("stage", nargs="?", choices=["before", "cancelled", "created", "updated", "deleted"])
    args = p.parse_args()
    f = Fixture(args.device)
    if args.action == "seed":
        print(json.dumps(f.seed()))
    elif args.action == "inspect":
        print(json.dumps({k: {"id":v, "events":f.events(v)} for k,v in f.calendars().items()}))
    elif args.action == "observe":
        f.observe(args.from_stage)
    elif args.action == "observe-open":
        f.observe_open()
    elif args.action == "verify":
        if not args.stage:
            p.error("verify requires a stage")
        result = f.verify(args.stage)
        print(json.dumps(result))
        if not result["passed"]:
            raise SystemExit(1)
    else:
        f.cleanup()


if __name__ == "__main__":
    main()
