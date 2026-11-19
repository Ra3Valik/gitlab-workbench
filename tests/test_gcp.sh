# Проверка bin/gcp против подставных API Google (без сети и настоящих учётных данных).
# Запуск: bash tests/test_gcp.sh   (нужен только python3)
set -e
cd "$(dirname "$0")/.."
T="$(mktemp -d)"; trap 'kill $MOCK 2>/dev/null; rm -rf "$T"' EXIT
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' bin/gcp && echo "syntax ok"

cat > "$T/mock.py" <<'PY'
import json, http.server, urllib.parse, sys
LOG = open(sys.argv[1], "a")
class H(http.server.BaseHTTPRequestHandler):
    def send(self, code, d):
        b = json.dumps(d).encode(); self.send_response(code); self.end_headers(); self.wfile.write(b)
    def authed(self):
        if self.headers.get("Authorization") != "Bearer AT-123":
            self.send(401, {"error": {"message": "bad token"}}); return False
        return True
    def do_GET(self):
        if self.path.startswith("/oauth/tokeninfo"):
            return self.send(200, {"email": "me@example.com", "scope": "cloud-platform", "expires_in": 3599})
        if not self.authed(): return
        if self.path.endswith("/instances"):
            return self.send(200, {"items": [{"name": "db1", "databaseVersion": "POSTGRES_16", "region": "us-east4", "state": "RUNNABLE",
                "settings": {"dataApiAccess": "ALLOW_DATA_API", "databaseFlags": [{"name": "cloudsql.iam_authentication", "value": "on"}]}}]})
        if self.path.endswith("/databases"):
            return self.send(200, {"items": [{"name": "postgres"}, {"name": "app"}]})
        self.send(404, {"error": {"message": "nope"}})
    def do_POST(self):
        raw = self.rfile.read(int(self.headers["Content-Length"])).decode()
        LOG.write(f"{self.command} {self.path} {raw}\n"); LOG.flush()
        if self.path == "/oauth/token":
            f = urllib.parse.parse_qs(raw)
            if f.get("refresh_token") != ["RT-secret"]:
                return self.send(400, {"error": "invalid_grant", "error_description": "Bad Request"})
            return self.send(200, {"access_token": "AT-123", "expires_in": 3599})
        if not self.authed(): return
        if self.path == "/logging/entries:list":
            return self.send(200, {"entries": [
                {"timestamp": "2026-11-19T10:00:00.123456Z", "severity": "ERROR", "resource": {"type": "cloud_run_revision", "labels": {"service_name": "api"}}, "textPayload": "boom"},
                {"timestamp": "2026-11-19T09:59:00Z", "severity": "INFO", "resource": {"type": "cloud_run_revision", "labels": {"service_name": "api"}}, "jsonPayload": {"message": "hello"}}]})
        if self.path.endswith(":executeSql") or self.path.endswith("/executeSql"):
            return self.send(200, {"results": [{"message": "BEGIN"},
                {"columns": [{"name": "id"}, {"name": "email"}], "rows": [{"values": [{"value": "1"}, {"nullValue": True}]}]},
                {"message": "ROLLBACK"}]})
        self.send(404, {"error": {"message": "nope"}})
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 8765), H).serve_forever()
PY
python3 "$T/mock.py" "$T/requests.log" & MOCK=$!; sleep 1

B=http://127.0.0.1:8765
export GCP_OAUTH_URL=$B/oauth GCP_LOGGING_API=$B/logging GCP_SQLADMIN_API=$B/sql GCP_CRM_API=$B/crm
export GCP_ADC_B64="$(printf '{"type":"authorized_user","client_id":"c","client_secret":"s","refresh_token":"RT-secret"}' | base64 -w0)"
export GCP_PROJECT=proj HOME="$T"
unset GCP_SQL_USER GCP_SQL_PASSWORD_SECRET

fail() { echo "FAIL: $*"; exit 1; }
out() { bin/gcp "$@" 2>&1 || true; }

echo "--- whoami";   out whoami | tee "$T/o"; grep -q "me@example.com" "$T/o" || fail whoami
echo "--- logs";     out logs -n 5 --since 2h 'severity>=ERROR' | tee "$T/o"; grep -q "ERROR.*api  boom" "$T/o" && grep -q "hello" "$T/o" || fail logs
grep "entries:list" "$T/requests.log" | grep -q 'AND (severity>=ERROR)' || fail "logs filter"
echo "--- instances"; out sql-instances | tee "$T/o"; grep -q "iam_auth=on" "$T/o" || fail instances
echo "--- dbs";      out sql-dbs db1 | tee "$T/o"; grep -q "^app$" "$T/o" || fail dbs
echo "--- sql";      out sql db1 app "select id, email from users;" | tee "$T/o"; grep -q "^1	NULL$" "$T/o" || fail sql
grep executeSql "$T/requests.log" | grep -q '"sqlStatement": "BEGIN TRANSACTION READ ONLY; select id, email from users; ROLLBACK;"' || fail "sql wrapper"
grep executeSql "$T/requests.log" | grep -q '"autoIamAuthn": true' || fail "iam authn"
GCP_SQL_USER=ro GCP_SQL_PASSWORD_SECRET=projects/p/locations/us-east4/secrets/s/versions/1 bin/gcp sql db1 app "select 1" >/dev/null 2>&1
tail -1 "$T/requests.log" | grep -q '"user": "ro"' || fail "sql user"
echo "--- json";     out sql --json db1 app "select 1" | grep -q '"email": null' || fail json

echo "--- запись запрещена:"
for q in "delete from users" "update users set x=1" "drop table users" "select 1; delete from users" \
         "select 1; commit; delete from users" "insert into t values (1)" "explain analyze delete from t" ; do
  n=$(wc -l < "$T/requests.log")
  bin/gcp sql db1 app "$q" >/dev/null 2>&1 && fail "пропустил: $q"
  [ "$(wc -l < "$T/requests.log")" = "$n" ] || fail "запрос ушёл в API: $q"
  echo "  отклонено: $q"
done
# WITH ... DELETE проходит фильтр по первому слову, но уходит только внутри BEGIN READ ONLY — Postgres его отклонит.
bin/gcp sql db1 app "with x as (delete from t returning *) select * from x" >/dev/null 2>&1 || true
tail -1 "$T/requests.log" | grep -q '"BEGIN TRANSACTION READ ONLY; with x as (delete from t returning \*) select \* from x; ROLLBACK;"' || fail "with-delete не обёрнут"
echo "  with-delete уходит только внутри READ ONLY"

echo "--- нет учётных данных:"; GCP_ADC_B64= bin/gcp logs 2>&1 | grep -q "GCP_ADC_B64 не задан" || fail "no creds"
echo "--- неверный refresh token:"
GCP_ADC_B64="$(printf '{"type":"authorized_user","client_id":"c","client_secret":"s","refresh_token":"bad"}' | base64 -w0)" bin/gcp logs 2>&1 | tee "$T/o" | grep -q "HTTP 400" || fail "bad rt"
grep -q "RT-secret\|AT-123" "$T/o" && fail "секрет в выводе"
echo "--- секреты не на диске:"
grep -rqs "RT-secret\|AT-123" "$HOME" --exclude=requests.log --exclude=mock.py && fail "секрет на диске" || echo "  ok"
echo "ALL OK"
