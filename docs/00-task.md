# 00. Task Statement

## Original text (Ukrainian, verbatim)

> Назви таблиць/полів/функцій у завданні не сприймати "буквально", окрім явно вказаних назв та типів.
>
> 1. Створити партиціоновану таблицю Т1 з полями "дата", "айді", "сума", "стан", "гуід операції",
>    "повідомлення" (жсонб) яке включає номер рахунку, айді клієнта, тип операції - онлайн чи офлайн
> 2. Згенерувати дані для заповнення таблиці Т1 за допомогою збереженої процедури чи функції
>    (загалом не менше 100 тис. рядків і за період три чи чотири місяці)
> 3. Забезпечити унікальність даних по полю гуід операції
> 4. Створити регламентне завдання, яке буде викликати функцію/процедуру додавання запису в таблицю Т1 кожні 5 секунд із "стан"-ом операції = 0
> 5. Створити регламентне завдання, яке кожні три секунди буде оновлювати поле "стан" таблиці Т1 з 0 на 1 для парних та непарних "айді"
>    (тобто якщо кількість секунд парна - оновлюються з 0 на 1 парні айді, інакше - непарні)
> 6. Створити механізм зберігання поточної загальної суми поля "сума" по "айді клієнта" та "типу" операції в матеріалізованому представленні
>    з оновленням при кожному оновленні поля "стан" таблиці Т1 з 0 на 1
> 7. Налаштувати реплікацію створеної таблиці Т1 на інший інстанс

## English translation

> Table/field/function names in the task are not to be taken literally, except for explicitly specified names and types.
>
> 1. Create a partitioned table T1 with fields "date", "id", "amount", "status", "operation guid",
>    "message" (jsonb) which contains account number, client id, operation type — online or offline.
> 2. Generate data to fill T1 using a stored procedure or function
>    (at least 100k rows total, covering a period of three or four months).
> 3. Ensure uniqueness of data by the "operation guid" field.
> 4. Create a scheduled job that calls a function/procedure inserting a row into T1 every 5 seconds with status = 0.
> 5. Create a scheduled job that every 3 seconds updates "status" in T1 from 0 to 1 for even and odd "id"
>    (i.e. if the number of seconds is even — even ids are updated 0→1, otherwise — odd ids).
> 6. Create a mechanism that stores the current total of "amount" per "client id" and operation "type" in a materialized view,
>    refreshed on every update of T1 "status" from 0 to 1.
> 7. Set up replication of T1 to another instance.

## Initial breakdown: what is explicit vs. what must be decided

| # | Requirement | Explicitly given | Open questions (resolved in grilling) |
|---|-------------|------------------|----------------------------------------|
| 1 | Partitioned T1 | field set, `jsonb` for message | partition key & granularity, column types, creation of future partitions |
| 2 | Data generation | function/procedure, ≥100k rows, 3–4 months | data distribution, status of historical rows, account/client formats |
| 3 | GUID uniqueness | — | on a partitioned table a UNIQUE constraint must include the partition key → how to guarantee *global* uniqueness |
| 4 | Job every 5 s | status = 0 | which scheduler (classic cron granularity is 1 minute) |
| 5 | Job every 3 s | seconds parity → `id` parity | seconds of which moment, which "id" exactly |
| 6 | Aggregate in a materialized view | "materialized view", refresh on every 0→1 | real `MATERIALIZED VIEW` vs incrementally maintained table; which rows are summed |
| 7 | Replicate T1 | "to another instance" | logical vs physical, how the environment is provisioned |

## Working process

1. **Grilling sessions** — rounds of questions on key design decisions. Every decision is recorded with options, the choice, and the reasoning (`docs/01-grilling-session-*.md`).
2. **Plan** — consolidated implementation plan derived from the decisions (`docs/02-plan.md`).
3. **Plan review** — traceability check, feasibility spike on a throwaway PostgreSQL 17 container, findings and amendments (`docs/03-plan-review.md`, `docs/spikes/`).
4. **Implementation** — SQL scripts + environment, with an execution & verification log (`docs/04-implementation-log.md`).
5. **Decision log** — one-line index of all decisions (`docs/decisions.md`).
