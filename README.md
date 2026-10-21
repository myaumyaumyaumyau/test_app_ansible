# ansible-notes

Ansible-плейбук для блока 2 тестового задания. На «голой» Ubuntu 22.04 одной командой:
обновляет систему, ставит Docker + Compose plugin, настраивает логи Docker, firewall и cron,
клонирует приложение «Notes» из git, собирает образ **на самом хосте** (без Docker Hub) и запускает стек.

Приложение: <https://github.com/myaumyaumyaumyau/test_app> (ветка `master`).

## Запуск

**Что нужно.** Контроллер (ваша машина): Python 3.12 (подойдёт 3.10–3.13). Целевая VM: Ubuntu 22.04,
SSH-доступ, пользователь с `sudo`, интернет. Больше ничего на VM ставить не надо, Python ставится самим плейбуком.

**1. Установка Ansible** (в изолированное окружение внутри проекта):

```bash
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml
```

**2. Запуск** (подставьте IP VM и имя пользователя; **запятая после IP обязательна**):

```bash
ansible-playbook -i 192.168.64.10, -u ubuntu site.yml
```

Если вход по паролю, а не по ключу, добавьте `-k -K`: Ansible спросит пароль SSH и пароль sudo.

```bash
ansible-playbook -i 192.168.64.10, -u ubuntu site.yml -k -K
```

**3. Проверка:**

```bash
curl http://192.168.64.10:8000/readyz      # {"status":"ok","database":"ok"}
```

Пароль БД, `.env` и все остальные настройки создаются автоматически, править ничего не нужно.

**Чего ожидать.** Первый прогон занимает 5–10 минут (обновление системы, установка Docker, сборка образа).
Если обновилось ядро, хост один раз перезагрузится, плейбук дождётся его и продолжит.
Повторный запуск безопасен: на втором прогоне `changed=0`.

## Соответствие заданию

| Требование | Где реализовано |
|---|---|
| 1. Docker и Compose plugin | `site.yml`, блок «Docker» (репозиторий Docker, `docker-ce`, `docker-compose-plugin`) |
| 2. JSON-логи с ротацией | `templates/daemon.json.j2`, переменные `docker_log_max_size`, `docker_log_max_file` |
| 3. Копирование compose-проекта и запуск | `git clone` на хост (или `rsync`, см. ниже), `community.docker.docker_compose_v2` |
| 4. Cron `docker system prune -f` | модуль `cron`, каждый день в 03:00 |
| 5. iptables, только нужные порты | `templates/rules.v4.j2`, `rules.v6.j2`: открыты SSH (22) и порт приложения (8000) |
| 6. Старые контейнеры | блок «Legacy containers», политика `legacy_containers_policy` |
| 7. Переменные | `group_vars/all/main.yml` (роли нет, поэтому не `defaults/main.yml`) |
| Идемпотентность | штатные модули, `tests/idempotence.sh` |
| Inventory prod/staging | `inventories/staging`, `inventories/prod` |
| Тесты | `verify.yml`, `tests/idempotence.sh`, `ansible-lint` |

## Что делает плейбук

| # | Этап | Тег | Что происходит |
|---|---|---|---|
| 1 | Bootstrap | `bootstrap` | `raw`: ставит `python3` и `python3-apt`, если их нет |
| 2 | Система | `system` | `apt dist-upgrade`, reboot при необходимости, базовые пакеты |
| 3 | Docker | `docker` | Docker Engine, buildx, Compose plugin, `daemon.json` |
| 4 | Firewall | `firewall` | INPUT=DROP, открыты SSH и порт приложения; для портов Docker правила в `DOCKER-USER`; IPv6 тоже закрыт |
| 5 | Старые контейнеры | `legacy` | удаляет чужие контейнеры на порту приложения; тома сохраняются |
| 6 | Приложение | `app` | `git clone` в `/opt/notes`, `.env` (0600), `docker compose up --build --wait`, проверка `/readyz` |
| 7 | Cron | `cron` | `docker system prune -f` ежедневно |

Можно запускать часть: `--tags docker,app`.

## Структура

```
.
├── ansible.cfg
├── requirements.txt / requirements.yml    # ansible-core и коллекции
├── site.yml                               # плейбук
├── verify.yml                             # проверка результата на хосте
├── group_vars/all/main.yml                # ВСЕ переменные со значениями по умолчанию
├── inventories/
│   ├── staging/{hosts.yml, group_vars/staging/}
│   └── prod/{hosts.yml, group_vars/prod/}
├── templates/                             # daemon.json, .env, rules.v4, rules.v6
└── tests/idempotence.sh
```

## Настройка

**Через inventory вместо флагов.** IP VM в `inventories/<env>/hosts.yml` (`ansible_host`), пользователь в
`inventories/<env>/group_vars/<env>/main.yml` (`ansible_user`). Тогда запуск короче:

```bash
ansible-playbook site.yml                          # staging (по умолчанию)
ansible-playbook -i inventories/prod site.yml      # prod
```

Переменные по умолчанию лежат в `group_vars/all/main.yml`, переопределения по окружениям в
`inventories/<env>/group_vars/<env>/main.yml` (приоритет выше). Основные:

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `app_repo_url` / `app_repo_version` | `test_app` / `master` | Репозиторий и ветка/тег приложения |
| `app_port` | `8000` | Порт приложения (публикуется и открывается в firewall) |
| `docker_log_max_size` / `docker_log_max_file` | `10m` / `3` | Ротация логов контейнеров |
| `system_upgrade` / `system_reboot_if_required` | `true` | Обновление системы и reboot |
| `docker_prune_cron_hour` / `_minute` | `3` / `0` | Время ежедневной чистки |
| `legacy_containers_policy` | `conflicting` | `none` / `conflicting` / `all` |
| `legacy_container_names` | `[]` | Имена контейнеров, удаляемых принудительно |
| `firewall_enabled` / `firewall_ipv6` | `true` | Управление firewall |
| `vault_app_postgres_password` | генерируется | Пароль БД |

Полный список: `group_vars/all/main.yml`.

**Пароль БД.** Если не задан, генерируется один раз и хранится на контроллере в `.credentials/<хост>/`
(в git не попадает). Не удаляйте эту папку: Postgres запоминает пароль в volume при первой инициализации.
Для prod лучше vault:

```bash
cp inventories/prod/group_vars/prod/vault.yml.example inventories/prod/group_vars/prod/vault.yml
ansible-vault encrypt inventories/prod/group_vars/prod/vault.yml
ansible-playbook -i inventories/prod site.yml --ask-vault-pass
```

**Способы входа на хост.**

| Ситуация | Флаг | Переменная в inventory |
|---|---|---|
| Ключ (по умолчанию) | `--private-key ~/.ssh/id_ed25519` | `ansible_ssh_private_key_file` |
| Пароль SSH | `-k` (нужен `sshpass` на контроллере) | `ansible_password` |
| `sudo` с паролем | `-K` | `ansible_become_password` |
| Вход под root | `-u root` | `ansible_user: root` |

Пароли в inventory храните в vault, а не открытым текстом.

**Код приложения с контроллера вместо git:**

```bash
ansible-playbook -i 192.168.64.10, -u ubuntu site.yml -e app_source=local -e app_src_dir=/путь/к/проекту
```

В папке должны быть `Dockerfile`, `docker-compose.yml`, `requirements.txt`, `entrypoint.sh`, `app/`, `scripts/`.
Нужен `rsync` на контроллере и беспарольный `sudo` на хосте.

## Нюансы

- **Firewall и Docker.** Опубликованные порты Docker идут через `FORWARD`, минуя `INPUT`, поэтому ограничение
  стоит в цепочке `DOCKER-USER`. Порт Postgres наружу не публикуется. Правила сохраняются в `/etc/iptables/rules.v{4,6}`.
  При изменении правил Docker перезапускается, чтобы пересоздать свои цепочки.
- **Старые контейнеры.** Контейнеры проекта `notes` обрабатывает сам `docker compose`. Остальные при политике
  `conflicting` удаляются, только если публикуют порт приложения или названы в `legacy_container_names`. Тома не трогаются.
- **Логи.** `daemon.json` влияет только на новые контейнеры, поэтому при его изменении стек пересоздаётся.

## Тесты

Все команды ниже подключаются к хосту так же, как `site.yml`, поэтому **добавляйте те же флаги входа**.
Если `sudo` на VM спрашивает пароль (или вход по паролю), без `-k -K` проверки упадут с ошибкой
`Missing sudo password`, потому что обращаются к Docker и iptables через `sudo`.

```bash
ansible-lint site.yml verify.yml                                       # статическая проверка, хост не нужен

# проверка результата на хосте (после site.yml)
ansible-playbook -i 192.168.64.10, -u ubuntu verify.yml -k -K

# идемпотентность: два прогона подряд, на втором должно быть changed=0
tests/idempotence.sh 192.168.64.10, -u ubuntu -k -K
```

Если вход по ключу и `sudo` без пароля, `-k -K` не нужны. Скрипт идемпотентности запускает плейбук дважды,
поэтому пароли с `-k -K` он спросит два раза.

`verify.yml` проверяет: Compose plugin, `daemon.json` и драйвер логов, cron-задачу, правила iptables,
health обоих контейнеров, ответы `/healthz`, `/readyz`, `/api/notes`, доступность порта приложения
и недоступность 5432 снаружи.
