#!/usr/bin/env python3
import http.server, urllib.parse

comments = []   # in-memory store for the guestbook (stored XSS)

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(url.query)
        if url.path == "/hello":
            name = q.get('name', ['stranger'])[0]
            body = "<h1>Hello, " + name + "</h1>"          # reflected, unescaped
        elif url.path == "/guestbook":
            body = "<h1>Guestbook</h1>"
            body += "<form method=post action=/guestbook>"
            body += "comment <input name=comment><button>post</button></form>"
            for c in comments:
                body += "<p>" + c + "</p>"                 # stored, unescaped
        else:
            body = "<a href=/hello?name=you>hello</a> | <a href=/guestbook>guestbook</a>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(("<html><body>" + body + "</body></html>").encode())

    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        f = urllib.parse.parse_qs(self.rfile.read(n).decode())
        comments.append(f.get('comment', [''])[0])         # store whatever was sent
        self.send_response(303)
        self.send_header("Location", "/guestbook")
        self.end_headers()

http.server.HTTPServer(("0.0.0.0", 8080), H).serve_forever()
