# Проверка bin/gl против подставного GitLab API (без сети и настоящего токена).
# Запуск: docker run --rm -v "$PWD:/w" python:3.12-slim bash /w/tests/test_gl.sh
set -e
apt-get -qq update >/dev/null && apt-get -qq install -y git curl >/dev/null
git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch main
bash -n /w/bin/gl && echo "syntax ok"

# подставной GitLab API: проверяет токен, отдаёт default_branch, принимает MR
cat > /tmp/mock.py <<'PY'
import json, http.server
class H(http.server.BaseHTTPRequestHandler):
    def _ok(self, d):
        if self.headers.get("PRIVATE-TOKEN") != "secret":
            self.send_response(401); self.end_headers(); return
        b = json.dumps(d).encode()
        self.send_response(200 if self.command == "GET" else 201); self.end_headers(); self.wfile.write(b)
    def do_GET(self): self._ok({"default_branch": "main"})
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        print("MR BODY", body, flush=True)
        self._ok({"iid": 7, "web_url": "https://gitlab.example/mr/7"})
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 8000), H).serve_forever()
PY
python3 /tmp/mock.py & sleep 1

git init -q --bare /tmp/origin.git
git clone -q /tmp/origin.git /tmp/seed
cd /tmp/seed && echo hi > a.txt && git add . && git commit -qm init && git push -q origin main
git checkout -qb fix/test && echo fix >> a.txt && git commit -qam fix

export GITLAB_TOKEN=secret GITLAB_API=http://127.0.0.1:8000
echo "--- mr:"; /w/bin/gl mr "Тестовый MR" 'описание с "кавычками"'
echo "--- pushed branches:"; git -C /tmp/origin.git branch --list "fix/*"
grep -rq secret /tmp/seed/.git && echo "TOKEN LEAKED TO DISK" || echo "token not on disk"
echo "--- mr from default branch:"; git checkout -q main; /w/bin/gl mr "x" 2>&1 | tail -1 || true
echo "--- no token:"; GITLAB_TOKEN= /w/bin/gl api projects/1 2>&1 | tail -1 || true
echo "--- wrong token:"; GITLAB_TOKEN=bad /w/bin/gl api projects/1 2>&1 | tail -1 || true
