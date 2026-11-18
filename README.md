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

## Использование
Открываешь сессию на `gitlab-workbench` и пишешь, например:
- «Склонируй `mygroup/backend` и разберись, почему падает последний пайплайн в main»
- «В `mygroup/backend` при логине 500 при пустом email — почини и открой MR»

## Безопасность
- Токен живёт только в переменных окружения claude.ai/code, `bin/gl` не пишет его на диск и не вставляет в URL.
- По правилам из `CLAUDE.md` Claude не пушит в ветку по умолчанию и не мёржит MR.
- Отозвать доступ — удалить токен в GitLab.
