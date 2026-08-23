#!/usr/bin/env python3
import http.server, urllib.parse, sqlite3

db = sqlite3.connect(":memory:", check_same_thread=False)
db.execute("CREATE TABLE users (username TEXT, password TEXT, role TEXT)")
db.execute("INSERT INTO users VALUES ('alice','wonderland','student')")
db.execute("INSERT INTO users VALUES ('admin','s3cr3t','admin')")
db.commit()

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(b"<form method=post>user <input name=username> "
                         b"pass <input name=password> <button>login</button></form>")
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        f = urllib.parse.parse_qs(self.rfile.read(n).decode())
        u = f.get('username', [''])[0]
        p = f.get('password', [''])[0]
        q = "SELECT role FROM users WHERE username='%s' AND password='%s'" % (u, p)
        print("SQL:", q)                       # so you can watch the query
        row = db.execute(q).fetchone()
        self.send_response(200); self.end_headers()
        self.wfile.write(("Welcome, role=%s" % row[0]).encode() if row else b"Login failed")

http.server.HTTPServer(("0.0.0.0", 8080), H).serve_forever()
