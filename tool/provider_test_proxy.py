"""Forward the selected Orb integration test protocol from localhost to its provider.

    python3 tool/provider_test_proxy.py deepseek --port 18961
    python3 tool/provider_test_proxy.py openai --port 18961
    adb -s EMULATOR_SERIAL reverse tcp:18961 tcp:18961

The default credential source is macOS Keychain service studio.orb.mobile.api-tests,
account deepseek or openai. Pass --credential-source env to use only
ORB_TEST_DEEPSEEK_API_KEY or ORB_TEST_OPENAI_API_KEY for the selected provider.
"""

import argparse
import http.client
import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROUTES = {
    "deepseek": ("api.deepseek.com", "/v1/chat/completions"),
    "openai": ("api.openai.com", "/v1/responses"),
}
SERVICE = "studio.orb.mobile.api-tests"
MAX_BODY = 4 * 1024 * 1024


def credential(provider, source):
    if source == "env":
        key = os.environ.get(f"ORB_TEST_{provider.upper()}_API_KEY", "")
    else:
        try:
            result = subprocess.run(
                [
                    "/usr/bin/security",
                    "find-generic-password",
                    "-s",
                    SERVICE,
                    "-a",
                    provider,
                    "-w",
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=30,
                check=True,
            )
            key = result.stdout.decode("ascii").rstrip("\r\n")
        except (OSError, subprocess.SubprocessError, UnicodeError):
            key = ""
    if not key or not all("!" <= c <= "~" for c in key):
        raise SystemExit(f"No usable {provider} test key from {source}.")
    return key


def read_body(handler):
    lengths = handler.headers.get_all("Content-Length", [])
    transfers = handler.headers.get_all("Transfer-Encoding", [])
    if (
        len(lengths) == 1
        and not transfers
        and lengths[0].isascii()
        and lengths[0].isdigit()
    ):
        size = int(lengths[0])
        if not 0 < size <= MAX_BODY:
            raise ValueError
        data = handler.rfile.read(size)
        if len(data) != size:
            raise ValueError
        return data
    if lengths or [value.lower() for value in transfers] != ["chunked"]:
        raise ValueError
    # Dart HttpClient normally sends JSON as chunked transfer encoding.
    data = bytearray()
    while True:
        line = handler.rfile.readline(256)
        if not line.endswith(b"\r\n"):
            raise ValueError
        token = line[:-2].split(b";", 1)[0]
        if not token or any(c not in b"0123456789abcdefABCDEF" for c in token):
            raise ValueError
        size = int(token, 16)
        if len(data) + size > MAX_BODY:
            raise ValueError
        if size:
            chunk = handler.rfile.read(size)
            if len(chunk) != size:
                raise ValueError
            data.extend(chunk)
        if handler.rfile.read(2) != b"\r\n":
            raise ValueError
        if not size:
            return bytes(data)


class Relay(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = 30

    def log_message(self, *_):
        pass

    def reject(self, status, message):
        body = json.dumps({"error": {"message": message}}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def do_POST(self):
        host, route = self.server.route
        if self.path != route:
            return self.reject(404, "Unknown test endpoint.")
        if self.headers.get("Origin") is not None or self.headers.get("Host") not in {
            f"127.0.0.1:{self.server.server_port}",
            f"localhost:{self.server.server_port}",
        }:
            return self.reject(403, "A loopback test client is required.")
        if self.headers.get_content_type() != "application/json":
            return self.reject(415, "Expected an application/json request.")
        try:
            body = read_body(self)
        except (ValueError, OSError):
            return self.reject(400, "Invalid or oversized test request.")
        upstream = http.client.HTTPSConnection(host, timeout=120)
        started = False
        try:
            upstream.request(
                "POST",
                route,
                body=body,
                headers={
                    "Content-Type": "application/json",
                    "Accept": "text/event-stream",
                    "Authorization": f"Bearer {self.server.test_key}",
                },
            )
            response = upstream.getresponse()
            if not 200 <= response.status < 300:
                # Provider error bodies may quote an invalid credential.
                return self.reject(
                    response.status, f"Provider returned HTTP {response.status}."
                )
            self.send_response(response.status)
            self.send_header(
                "Content-Type", response.getheader("Content-Type", "text/event-stream")
            )
            if encoding := response.getheader("Content-Encoding"):
                self.send_header("Content-Encoding", encoding)
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()
            started = True
            while data := response.read1(32768):
                self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
        except (OSError, http.client.HTTPException):
            if not started:
                self.reject(502, "Could not reach the selected provider.")
        finally:
            self.close_connection = True
            upstream.close()


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("provider", choices=ROUTES)
    parser.add_argument("--port", type=int, default=18961)
    parser.add_argument(
        "--credential-source", choices=("keychain", "env"), default="keychain"
    )
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("--port must be between 1 and 65535")
    key = credential(args.provider, args.credential_source)
    with ThreadingHTTPServer(("127.0.0.1", args.port), Relay) as server:
        server.test_key = key
        server.route = ROUTES[args.provider]
        print(
            f"{args.provider} test relay: http://127.0.0.1:{args.port}{server.route[1]}",
            flush=True,
        )
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
