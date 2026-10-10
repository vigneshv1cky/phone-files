"""Phone Files: browse an Android phone from a Mac in the browser.

Run:  python3 server.py [--port 8777] [--open]
Then visit http://127.0.0.1:8777
"""

import argparse
import json
import mimetypes
import os
import shutil
import sys
import tempfile
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlparse

import mtp

HERE = os.path.dirname(os.path.abspath(__file__))
phone = mtp.Phone()
ALLOWED_HOSTS = set()


class Handler(BaseHTTPRequestHandler):
    server_version = "PhoneFiles/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.command, self.path))

    # -- helpers ----------------------------------------------------------

    def _json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _error(self, exc, status=500):
        self._json({"error": str(exc)}, status)

    def _guard(self, mutating):
        # Only answer requests addressed to this machine (blocks DNS rebinding),
        # and require a custom header on writes so other websites can't forge them.
        if self.headers.get("Host", "") not in ALLOWED_HOSTS:
            self._json({"error": "Bad host"}, 403)
            return False
        if mutating and self.headers.get("X-Phone-Files") != "1":
            self._json({"error": "Missing header"}, 403)
            return False
        return True

    def _body_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    # -- routes -----------------------------------------------------------

    def do_GET(self):
        if not self._guard(False):
            return
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        try:
            if url.path in ("/", "/index.html"):
                with open(os.path.join(HERE, "index.html"), "rb") as fh:
                    body = fh.read()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif url.path == "/api/status":
                if not phone.connected:
                    try:
                        phone.connect()
                    except mtp.MTPError as e:
                        return self._json({"connected": False, "error": str(e)})
                self._json({"connected": True, **phone.info, "battery": phone.battery()})
            elif url.path == "/api/storages":
                self._json(phone.storages())
            elif url.path == "/api/list":
                items = phone.list(int(q["storage"]), int(q.get("parent", mtp.ROOT)))
                items.sort(key=lambda f: (not f["folder"], f["name"].lower()))
                self._json(items)
            elif url.path.startswith("/api/thumb/"):
                data = phone.thumbnail(int(url.path.rsplit("/", 1)[1]))
                if not data:
                    self.send_response(404)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                ctype = "image/png" if data[:4] == b"\x89PNG" else "image/jpeg"
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Cache-Control", "private, max-age=3600")
                self.end_headers()
                self.wfile.write(data)
            elif url.path.startswith("/api/file/"):
                self._send_file(int(url.path.rsplit("/", 1)[1]), q.get("download") == "1")
            else:
                self._json({"error": "Not found"}, 404)
        except mtp.MTPError as e:
            self._error(e, 409)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:  # noqa: BLE001 - surface anything to the UI
            self._error(e)

    def _send_file(self, item_id, as_download):
        meta = phone.metadata(item_id)
        ctype = mimetypes.guess_type(meta["name"])[0] or "application/octet-stream"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(meta["size"]))
        disp = "attachment" if as_download else "inline"
        self.send_header("Content-Disposition", "%s; filename*=UTF-8''%s" % (disp, quote(meta["name"])))
        self.end_headers()
        phone.download(item_id, self.wfile.write)

    def do_POST(self):
        if not self._guard(True):
            return
        url = urlparse(self.path)
        try:
            if url.path == "/api/connect":
                phone.connect()
                self._json({"connected": True, **phone.info, "battery": phone.battery()})
            elif url.path == "/api/mkdir":
                b = self._body_json()
                name = b["name"].strip()
                if not name or "/" in name:
                    return self._json({"error": "Invalid folder name"}, 400)
                self._json({"id": phone.mkdir(name, int(b["storage"]), int(b["parent"]))})
            elif url.path == "/api/delete":
                phone.delete(int(self._body_json()["id"]))
                self._json({"ok": True})
            else:
                self._json({"error": "Not found"}, 404)
        except mtp.MTPError as e:
            self._error(e, 409)
        except Exception as e:  # noqa: BLE001
            self._error(e)

    def do_PUT(self):
        if not self._guard(True):
            return
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        if url.path != "/api/upload":
            return self._json({"error": "Not found"}, 404)
        name = os.path.basename(q.get("name", "")).strip()
        if not name:
            return self._json({"error": "Missing file name"}, 400)
        remaining = int(self.headers.get("Content-Length") or 0)
        tmpdir = tempfile.mkdtemp(prefix="phone-files-")
        path = os.path.join(tmpdir, name)
        try:
            # Stage on disk first: libmtp needs the size up front and a seekable source.
            with open(path, "wb") as out:
                while remaining > 0:
                    chunk = self.rfile.read(min(1 << 20, remaining))
                    if not chunk:
                        break
                    out.write(chunk)
                    remaining -= len(chunk)
            new_id = phone.upload(path, name, int(q["storage"]), int(q.get("parent", mtp.ROOT)))
            self._json({"id": new_id})
        except mtp.MTPError as e:
            self._error(e, 409)
        except Exception as e:  # noqa: BLE001
            self._error(e)
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--port", type=int, default=8777)
    ap.add_argument("--open", action="store_true", help="open the page in the default browser")
    args = ap.parse_args()
    ALLOWED_HOSTS.update({"127.0.0.1:%d" % args.port, "localhost:%d" % args.port})

    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    url = "http://127.0.0.1:%d" % args.port
    print("Phone Files running at %s  (Ctrl+C to stop)" % url, flush=True)
    if args.open:
        threading.Timer(0.5, webbrowser.open, [url]).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        phone.disconnect()


if __name__ == "__main__":
    main()
