# GitLab workbench для claude.ai/code

claude.ai/code подключается только к GitHub. Этот репозиторий — «точка входа»: сессия открывается на нём, а Claude по инструкции из `CLAUDE.md` клонирует нужный проект из GitLab, разбирается, чинит и открывает MR через `bin/gl`.

## Настройка (один раз)

### 1. Токен GitLab
GitLab → аватар → **Preferences → Access tokens → Add new token**:
- Name: `claude-code-web`
- Expiration: 30–90 дней (потом выпустить новый)
- Scopes: `api` (чтение кода, пайплайнов, создание MR), `write_repository` (push веток)

Для рабочего GitLab лучше **Project/Group access token** с ролью Developer — доступ только к нужным проектам. Сначала уточни, разрешено ли давать стороннему AI доступ к коду.

### 2. Репозиторий на GitHub
Создай пустой приватный репозиторий `gitlab-workbench` и запушь сюда эти файлы.

### 3. Окружение в claude.ai/code
claude.ai/code → выбрать репозиторий `gitlab-workbench` → настройки окружения (environment):
- **Environment variables:**
  - `GITLAB_TOKEN` = токен из шага 1
  - `GITLAB_HOST` = `gitlab.com` (или адрес своего GitLab, без https://)
- **Network access:** разрешить домен GitLab (для своего GitLab — добавить его адрес в список разрешённых).

### 4. (по желанию) Google Cloud: логи и Cloud SQL только на чтение — `bin/gcp`
Доступ идёт от твоего Google-аккаунта: Claude видит то же, что видишь ты. Режим «только чтение» обеспечивают три уровня:
1. в `bin/gcp` нет ни одной команды, которая что-то меняет в GCP: только список проектов, чтение логов, список инстансов и баз, SQL-запрос;
2. SQL принимается только как один `SELECT / WITH / EXPLAIN / SHOW / TABLE / VALUES` без `;` и выполняется внутри `BEGIN TRANSACTION READ ONLY … ROLLBACK`, так что Postgres сам отклонит любую запись;
3. правила в `CLAUDE.md` запрещают обращаться к GCP мимо `bin/gcp`.

Сам refresh token при этом даёт полные права твоего аккаунта: Google не даёт выпустить ADC-токен с меньшими правами. Поэтому для гарантии на уровне БД лучше завести отдельную read-only роль (см. ниже), а переменную окружения не давать чужим людям.

**Учётные данные** — на своём компьютере:
```bash
gcloud auth application-default login
base64 -w0 ~/.config/gcloud/application_default_credentials.json   # macOS: base64 -i <файл>
```
Windows (PowerShell; gcloud ставится `winget install Google.CloudSDK`, потом открыть новое окно PowerShell):
```powershell
gcloud auth application-default login
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:APPDATA\gcloud\application_default_credentials.json")) | Set-Clipboard
```
Вывод положить в переменные окружения claude.ai/code:
- `GCP_ADC_B64` = строка base64 (в чат её не вставлять);
- `GCP_PROJECT` = проект по умолчанию (например `mawari-chain-staging-493218`), необязательно.

Новая сессия подхватит переменные. Проверка: `bin/gcp whoami`. Отозвать доступ — `gcloud auth application-default revoke` на своём компьютере (или https://myaccount.google.com/permissions). Если в организации включено ограничение длительности сессии Google Cloud, токен будет протухать, и шаг придётся повторять.

**Cloud SQL (PostgreSQL).** Подключиться к порту БД из облачной сессии нельзя (наружу выпускается только HTTPS), поэтому запросы идут через [ExecuteSql API](https://docs.cloud.google.com/sql/docs/postgres/admin-api/rest/v1/instances/executeSql). Для инстанса нужно (делает админ GCP):
- включить Data API: `gcloud sql instances patch INSTANCE --data-api-access=ALLOW_DATA_API`. Для инстанса только с приватным IP это открывает доступ к нему через API из интернета (с IAM-проверкой) — решение за владельцем инфраструктуры;
- одно из двух:
  - **IAM-вход твоим аккаунтом** (по умолчанию): флаг `cloudsql.iam_authentication=on`, `gcloud sql users create you@company.com --instance=INSTANCE --type=cloud_iam_user`, в базе дать роли только чтение: `GRANT pg_read_all_data TO "you@company.com";`;
  - **отдельная read-only роль** (надёжнее, если у твоего аккаунта в БД есть права на запись): `CREATE ROLE claude_ro LOGIN PASSWORD '…'; GRANT pg_read_all_data TO claude_ro;`, пароль положить в Secret Manager в регионе инстанса, а в окружение claude.ai/code добавить `GCP_SQL_USER=claude_ro` и `GCP_SQL_PASSWORD_SECRET=projects/<p>/locations/<region>/secrets/<s>/versions/latest`.

Проверка `bin/gcp`: `bash tests/test_gcp.sh` (подставные API, без сети и настоящих учётных данных).

## Использование
Открываешь сессию на `gitlab-workbench` и пишешь, например:
- «Склонируй `mygroup/backend` и разберись, почему падает последний пайплайн в main»
- «В `mygroup/backend` при логине 500 при пустом email — почини и открой MR»

## Безопасность
- Токен живёт только в переменных окружения claude.ai/code, `bin/gl` не пишет его на диск и не вставляет в URL.
- По правилам из `CLAUDE.md` Claude не пушит в ветку по умолчанию и не мёржит MR.
- Отозвать доступ — удалить токен в GitLab.
