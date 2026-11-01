"""Nakli SMTP (sirf local test): har aayi email ko file me likhta hai. TLS / AUTH nahi."""
import socketserver, sys, json

LOG = sys.argv[1]

class H(socketserver.StreamRequestHandler):
    def w(self, line):
        self.wfile.write((line + "\r\n").encode())

    def handle(self):
        self.w("220 fake-smtp ready")
        mail = {"from": None, "to": [], "data": ""}
        while True:
            raw = self.rfile.readline()
            if not raw:
                return
            cmd = raw.decode("utf-8", "replace").strip()
            up = cmd.upper()
            if up.startswith("EHLO") or up.startswith("HELO"):
                self.w("250 fake-smtp")
            elif up.startswith("MAIL FROM"):
                mail["from"] = cmd[10:]; self.w("250 OK")
            elif up.startswith("RCPT TO"):
                mail["to"].append(cmd[8:]); self.w("250 OK")
            elif up == "DATA":
                self.w("354 End with .")
                lines = []
                while True:
                    l = self.rfile.readline().decode("utf-8", "replace")
                    if l.rstrip("\r\n") == ".":
                        break
                    lines.append(l)
                mail["data"] = "".join(lines)
                with open(LOG, "a", encoding="utf-8") as f:
                    f.write(json.dumps(mail, ensure_ascii=False) + "\n")
                mail = {"from": None, "to": [], "data": ""}
                self.w("250 queued")
            elif up == "QUIT":
                self.w("221 bye"); return
            else:
                self.w("250 OK")

socketserver.ThreadingTCPServer.allow_reuse_address = True
socketserver.ThreadingTCPServer(("127.0.0.1", 2525), H).serve_forever()
