// The task store, over PostgreSQL. **This is the only file in the example that knows any SQL.**
//
// It is a plain object of five functions, which is what `tasks.sl` is written against -- so the
// application above it never sees a connection, a row, a SQLSTATE or a `pg` import, and a test can
// hand it something else entirely.
//
// **Every call here is a promise on the same loop that is answering HTTP**, which is `pg`'s whole
// argument for speaking the wire protocol in slate rather than binding libpq: `PQexec` blocks, and a
// blocking call on this loop would stop every other request while one of them waited on a database.

import { pg } from pg
import { env } from slate:process

// **`create table if not exists` rather than a migration**, an example being a thing somebody runs
// once against an empty database. A service that is deployed twice wants its schema somewhere a
// review can see it.
//
// `title` is UNIQUE, which is what makes `23505` a thing the application above can answer: the
// database refusing a duplicate is one round trip, and a `select` first would be a race between two
// requests.
val Schema = "create table if not exists tasks (id serial primary key, title text not null unique, done boolean not null default false)"

// What to connect with, read from the environment. **A deployment already carries this** and a
// program that made up its own names for it would be one more thing to configure.
//
// `PG_URL` is the whole of it in one string, which is what a hosted database hands out. With none,
// `pg` reads what `psql` reads -- `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE` -- so a
// machine where `psql` connects is a machine where this connects.
export configuration() = env("PG_URL") ?? (env("DATABASE_URL") ?? {})

// `postgres(config)` -- connect, make the table if it is not there, and answer the store.
//
// **It answers a result and does not throw.** A database that is not up, a password that is wrong
// and a role that may not create a table are all things a program handles rather than defects in it.
export async postgres(config)
    val made = await pg(config)

    if !made.ok then return { ok: false, error: made.error }

    val db = made.value
    val ready = await db.query(Schema)

    if !ready.ok
        db.close()

        return { ok: false, error: ready.error }

    { ok: true, value: store(db) }

// The five functions, and `close` beside them.
//
// **A refusal is passed up with its SQLSTATE and nothing is interpreted here.** Which codes mean
// something to a task list is the application's business; this layer's business is that the code
// survives the trip.
store(db: object) -> object
    async list()
        val r = await db.query("select id, title, done from tasks order by id")

        if !r.ok then return refused(r)

        { ok: true, value: r.value.rows }

    async add(title: string)
        val r = await db.query("insert into tasks (title) values ($1) returning id, title, done", title)

        if !r.ok then return refused(r)

        { ok: true, value: r.value.rows[0] }

    async done(id: integer)
        val r = await db.query("update tasks set done = true where id = $1 returning id, title, done", id)

        if !r.ok then return refused(r)

        val rows = r.value.rows

        { ok: true, value: if rows.length == 0 then null else rows[0] }

    async remove(id: integer)
        val r = await db.query("delete from tasks where id = $1", id)

        if !r.ok then return refused(r)

        { ok: true, value: r.value.count > 0 }

    // **The health check is a round trip and not a flag.** A connection object that still exists
    // says nothing about a database that has gone; a `select` that comes back says it is there.
    async ping()
        val r = await db.query("select 1 as up")

        if !r.ok then return refused(r)

        { ok: true }

    { list: list, add: add, done: done, remove: remove, ping: ping, close: () -> db.close() }

// **A parameter is never interpolated into the SQL above.** The server parses the statement before
// it is given a single value, so `$1` is the whole of the defence against injection and there is
// nothing here to escape.
refused(r: object) -> object = { ok: false, error: r.error, code: r.code ?? null }
