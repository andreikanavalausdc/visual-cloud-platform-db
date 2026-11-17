# Visual Cloud Platform — Database

PostgreSQL для визуальной платформы обработки файлов и данных.

## Запуск

Нужен только запущенный Docker с Docker Compose. На Windows достаточно Docker Desktop.

При первом запуске создай `.env` по шаблону `.env.example` и задай пароли. Docker Compose автоматически прочитает этот файл. Файл `.env` должен оставаться только на твоём компьютере.

Из папки проекта:

```sh
docker compose up -d --build --wait
```

При первом запуске автоматически создаются БД, таблицы, роли и демонстрационные данные. Имя БД, логины, пароли и порт берутся из `.env`. PostgreSQL и Python на компьютер устанавливать не нужно. `.env` не хранится в Git; `.env.example` содержит только шаблон.

## Проверка

```sh
docker compose exec -T db python3 scripts/verify_database.py
```

Ожидаемый результат — `"status": "pass"`, 69 проверок.

## Работа с БД

SQL-консоль под обычной ролью приложения:

```sh
docker compose exec db psql -U vcp_service -d visual_cloud
```

Для подключения из WebStorm, DBeaver или другого клиента: хост `localhost`, порт `DB_PORT`, база `POSTGRES_DB`, пользователь `APP_DB_USER`, пароль `APP_DB_PASSWORD` из `.env`. Команда SQL-консоли выше использует значения по умолчанию из шаблона.

## Остановка

```sh
docker compose down
```

Данные сохраняются в Docker volume. Для повторного запуска используй ту же команду запуска; таблицы и данные заново не создаются.

## Документация

- [Устройство БД](docs/database/design.md).
- [Словарь данных](docs/database/data-dictionary.md).
- [Схема](docs/database/schema-overview.svg), [полная ER-схема](docs/database/logical-schema.mmd).
- [Результаты проверок](docs/database/verification-report.json).

В БД 24 таблицы и 4 представления. Все демонстрационные запуски, прогнозы и измерения синтетические. API, интерфейс и выполнение в AWS пока не реализованы.
