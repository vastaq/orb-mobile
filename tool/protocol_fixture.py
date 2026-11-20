"""Loopback-only deterministic provider for the existing Orb integration tests."""

import argparse
import base64
import io
import json
import re
import threading
import uuid
from datetime import date, datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from PIL import Image

MODELS = ("orb-fixture-text", "orb-fixture-vision")
log_lock = threading.Lock()


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def contents(message):
    value = message.get("content")
    if isinstance(value, str):
        return value
    return "\n".join(part["text"] for part in (value or []) if "text" in part)


def capture(pattern, value):
    match = re.search(pattern, value)
    if not match:
        raise ValueError("missing expected input " + pattern)
    return match.group(1)


def classify_image(content):
    parts = [p for p in content if p.get("type") == "image_url"]
    if len(parts) != 1:
        raise ValueError("one image_url required")
    raw = base64.b64decode(parts[0]["image_url"]["url"].split(",", 1)[1], validate=True)
    image = Image.open(io.BytesIO(raw)).convert("RGB")
    w, h = image.size
    if not (w == h and 50 <= w <= 2000):
        raise ValueError("unexpected image dimensions")

    # Confirm blue interior, a white surround, equal horizontal/vertical blue
    # diameters, and cross-section area consistent with a filled circle.
    def blue(pixel):
        r, g, b = pixel
        return b > 160 and r < 70 and g < 120

    if not blue(image.getpixel((w // 2, h // 2))) or min(image.getpixel((0, 0))) < 220:
        raise ValueError("unexpected colors")
    dx = sum(blue(image.getpixel((x, h // 2))) for x in range(w))
    dy = sum(blue(image.getpixel((w // 2, y))) for y in range(h))
    area = sum(blue(pixel) for pixel in image.getdata())
    if abs(dx - dy) > 3 or not 0.73 <= area / (dx * dy) <= 0.84:
        raise ValueError("unexpected shape")
    return "蓝色圆形"


def choose(body):
    messages = body["messages"]
    users = [i for i, m in enumerate(messages) if m["role"] == "user"]
    message = messages[users[-1]]
    query = contents(message)
    system = "\n".join(contents(m) for m in messages if m["role"] == "system")
    names = {t["function"]["name"] for t in body.get("tools", [])}
    history = "\n".join(
        contents(m) for m in messages[: users[-1]] if m["role"] == "user"
    )
    calls = {
        c["id"]: c["function"]["name"]
        for m in messages[users[-1] + 1 :]
        for c in m.get("tool_calls", [])
    }
    output = {}
    for m in messages[users[-1] + 1 :]:
        if m["role"] == "tool":
            receipt = json.loads(m["content"])
            if receipt.get("error") or receipt.get("ok") is False:
                raise ValueError("device rejected " + calls[m["tool_call_id"]])
            output[calls[m["tool_call_id"]]] = receipt

    def call(name, **args):
        if name not in names:
            raise ValueError("missing offered tool " + name)
        return name, args

    def due(hour):
        today = date.fromisoformat(
            capture(r"Device local time: (\d{4}-\d\d-\d\d)", system)
        )
        return (today + timedelta(days=1)).isoformat() + f"T{hour:02d}:00"

    def text(label, value):
        return label, str(value)

    if "本地记忆编辑器" in system:
        data = json.loads(query)
        spoken = data["utterance"]
        operations = []
        if spoken == "我每天早上都喝无糖咖啡。" and not any(
            spoken == m["text"] for m in data["candidates"]
        ):
            operations = [dict(kind="add", evidence=spoken, text=spoken)]
        return text("memory-plan", compact({"ops": operations}))
    if "那首曲子起了什么名字" in query:
        return text(
            "manual-memory", capture(r"给正在写的曲子定名叫《([^》]+)》", system)
        )
    if query == "我每天早上都喝无糖咖啡。":
        return text("memory-statement", "记住了。")
    if query.startswith("我每天早上习惯喝什么"):
        if "无糖咖啡" not in system:
            raise ValueError("memory missing from system context")
        return text("memory-recall", "无糖咖啡")
    if "刚才停下的地方" in query:
        if not any(
            m["role"] == "assistant" and "无糖咖啡" in contents(m) for m in messages
        ):
            raise ValueError("continuation missing earlier assistant response")
        return text("continuation", "，这是你早晨习惯喝的饮品。")
    if "工坊暗号是什么" in query:
        password = capture(r"工坊的暗号是([^。\n]+)", query)
        return text("document", password)
    if "图中间是什么颜色" in query:
        return text("image", classify_image(message["content"]))
    if "明天晚上八点提醒我整理" in query:
        if "schedule_create" in output:
            task = output["schedule_create"]["task"]
            return text("created", f"已设定任务 {task['id']}，下次执行 {task['due']}。")
        title = capture(r"《([^》]+)》", query)
        return call(
            "schedule_create",
            title=title + "读书笔记",
            body="整理《" + title + "》的读书笔记",
            due=due(20),
        )
    if "刚才这个提醒改到" in query:
        if "schedule_edit" in output:
            return text("updated", output["schedule_edit"]["task"]["due"])
        if "schedule_list" not in output:
            return call("schedule_list", query=capture(r"《([^》]+)》", history))
        found = output["schedule_list"]["tasks"]
        if len(found) != 1:
            raise ValueError("scheduled task match count differs from one")
        return call(
            "schedule_edit",
            action="update",
            id=found[0]["id"],
            revision=found[0]["revision"],
            due=due(21),
        )
    if "里写入一句" in query:
        if "workspace_write" in output:
            return text("written", output["workspace_write"]["path"])
        return call(
            "workspace_write",
            path=capture(r"工作区文件\s+(\S+)\s", query),
            text=capture(r"「([^」]+)」", query),
        )
    if "保留其余文字" in query:
        path = capture(r"把\s+(\S+)\s", query)
        if "workspace_edit" in output:
            return text("edited", output["workspace_edit"]["path"])
        if "workspace_read" not in output:
            return call("workspace_read", path=path)
        before, after = re.findall(r"「([^」]+)」", query)
        original = output["workspace_read"]
        if original["text"].count(before) != 1:
            raise ValueError(
                "requested replacement not found exactly once in device result"
            )
        return call(
            "workspace_edit",
            path=path,
            expected_hash=original["sha256"],
            old_text=before,
            new_text=after,
        )
    if "请读取工作区文件" in query:
        if any(n.startswith("schedule_") for n in names):
            raise ValueError(
                "background prompt must not receive scheduling capabilities"
            )
        if "workspace_read" in output:
            return text("scheduled-read", output["workspace_read"]["text"])
        return call("workspace_read", path=capture(r"工作区文件\s+(\S+?)，", query))
    raise ValueError("unknown test request")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def audit(self, **data):
        if self.server.audit_file is None:
            return
        detail = {"time": datetime.now().astimezone().isoformat(), **data}
        with log_lock:
            with self.server.audit_file.open("a") as sink:
                sink.write(compact(detail) + "\n")

    def send_data(self, code, mime, data):
        self.send_response(code)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", len(data))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/v1/models":
            data = {
                "object": "list",
                "data": [{"id": v, "object": "model"} for v in MODELS],
            }
            self.send_data(200, "application/json", compact(data).encode())
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            return self.send_error(404)
        try:
            if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
                data = bytearray()
                while True:
                    line = self.rfile.readline(100).split(b";")[0].strip()
                    size = int(line, 16)
                    if size == 0:
                        if self.rfile.readline(4096) != b"\r\n":
                            raise ValueError("unexpected trailers")
                        break
                    if size < 0 or len(data) + size > 2_000_000:
                        raise ValueError("request length")
                    data.extend(self.rfile.read(size))
                    if self.rfile.read(2) != b"\r\n":
                        raise ValueError("bad chunk")
            else:
                size = int(self.headers["Content-Length"])
                if not 1 <= size <= 2_000_000:
                    raise ValueError("request length")
                data = self.rfile.read(size)
            request = json.loads(data)
            model = request["model"]
            if model not in MODELS or request["stream"] is not True:
                raise ValueError("unsupported model or streaming option")
            label, answer = choose(request)
            self.audit(
                model=model,
                route=label,
                action="tool" if isinstance(answer, dict) else "reply",
            )
            if isinstance(answer, dict):
                call_id = "call_" + uuid.uuid4().hex[:12]
                arguments = compact(answer)
                split = max(1, len(arguments) // 2)
                chunks = [
                    {
                        "tool_calls": [
                            {
                                "index": 0,
                                "id": call_id,
                                "type": "function",
                                "function": {
                                    "name": label,
                                    "arguments": arguments[:split],
                                },
                            }
                        ]
                    },
                    {
                        "tool_calls": [
                            {"index": 0, "function": {"arguments": arguments[split:]}}
                        ]
                    },
                ]
                stop = "tool_calls"
            else:
                mid = max(1, len(answer) // 2)
                chunks = [
                    {"content": part} for part in [answer[:mid], answer[mid:]] if part
                ]
                stop = "stop"
            chunks.insert(0, {"role": "assistant"})
            parts = []
            for chunk in chunks:
                parts.append(
                    {"choices": [{"index": 0, "delta": chunk, "finish_reason": None}]}
                )
            parts.append(
                {"choices": [{"index": 0, "delta": {}, "finish_reason": stop}]}
            )
            parts.append(
                {
                    "choices": [],
                    "usage": {
                        "prompt_tokens": 8,
                        "completion_tokens": 4,
                        "total_tokens": 12,
                    },
                }
            )
            wire = (
                "".join("data: " + compact(chunk) + "\n\n" for chunk in parts)
                + "data: [DONE]\n\n"
            )
            self.send_data(200, "text/event-stream; charset=utf-8", wire.encode())
        except (KeyError, ValueError, TypeError, IndexError) as error:
            self.audit(route="error", error=str(error)[:160])
            self.send_data(
                422,
                "application/json",
                compact({"error": {"message": str(error)}}).encode(),
            )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", default=18334, type=int)
    parser.add_argument(
        "--audit", type=Path, help="optional path for test event metadata"
    )
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.audit_file = args.audit
    print("Serving controlled Orb test protocol at", server.server_address, flush=True)
    server.serve_forever()
