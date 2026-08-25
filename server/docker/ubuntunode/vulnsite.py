#!/usr/bin/env python3
import http.server, urllib.parse, sqlite3, hashlib

# The session secret. Only the server knows it. A session cookie carries the username and a hash
# of that username with this secret, so a client cannot forge a cookie naming a different user.
# This is the deliberately weak scheme the book describes for the MyUni site: it is enough to stop
# a client inventing a session, and useless against anyone who can read the cookie off the wire.
SECRET = "myuni-server-secret"

db = sqlite3.connect(":memory:", check_same_thread=False)
db.execute("CREATE TABLE users (username TEXT, password TEXT, role TEXT)")
db.execute("INSERT INTO users VALUES ('alice','wonderland','student')")
db.execute("INSERT INTO users VALUES ('bob','redgum77','student')")
db.execute("INSERT INTO users VALUES ('admin','s3cr3t','admin')")
db.commit()

def session_cookie(u):
    return "%s|%s" % (u, hashlib.sha256((u + SECRET).encode()).hexdigest()[:16])

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/account'):
            return self.account()
        self.send_response(200); self.end_headers()
        self.wfile.write(b"<form method=post>user <input name=username> "
                         b"pass <input name=password> <button>login</button></form>")
    def account(self):
        # Identify the user from the cookie alone -- no password is sent on this request.
        c = self.headers.get('Cookie', '')
        v = c.split('session=', 1)[1].split(';', 1)[0].strip() if 'session=' in c else ''
        u = v.split('|', 1)[0]
        body = b"Not signed in"
        if v and v == session_cookie(u):
            row = db.execute("SELECT role FROM users WHERE username=?", (u,)).fetchone()
            if row:
                body = ("Signed in as %s, role=%s" % (u, row[0])).encode()
        self.send_response(200); self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        f = urllib.parse.parse_qs(self.rfile.read(n).decode())
        u = f.get('username', [''])[0]
        p = f.get('password', [''])[0]
        q = "SELECT role FROM users WHERE username='%s' AND password='%s'" % (u, p)
        print("SQL:", q)                       # so you can watch the query
        row = db.execute(q).fetchone()
        self.send_response(200)
        if row:
            # Sent in clear text, because this site is plain HTTP.
            self.send_header("Set-Cookie", "session=%s; Path=/" % session_cookie(u))
        self.end_headers()
        self.wfile.write(("Welcome, role=%s" % row[0]).encode() if row else b"Login failed")

http.server.HTTPServer(("0.0.0.0", 8080), H).serve_forever()
