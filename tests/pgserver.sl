// A PostgreSQL server written in slate, for the one test that needs a real one.
//
// **It declares no tests of its own**, so `slate test tests` walking this directory finds nothing in
// it to run. `tests/postgres.sl` is what drives it.
//
// **The messages are written out longhand from the protocol**, which is `pg`'s own arrangement and
// is taken here for the same reason: what passes is `examples/tasks/postgres.sl` agreeing with the
// wire rather than with whichever PostgreSQL happens to be installed, and the suite needs no server,
// no cluster and no password. `pg` keeps its `wire.sl` private -- a consumer imports the client and
// not the message layout -- so this is written from the message formats rather than borrowed.
//
// **It answers per MESSAGE and never per chunk.** A loopback delivers two statements written in one
// turn as one, two or three reads depending on nothing a test controls, so a server answering every
// arrival answers the wrong number of times and the failure lands in the teardown as a reset.

import { listen, onBytes, send, close as closeSocket, localPort } from slate:net

// `server(answer)` -- a server that logs in anybody and asks `answer(sql, params)` what to say.
//
// **The login is not what this is for.** `pg`'s own suite does SCRAM in both directions; here every
// connection is `AuthenticationOk` at once, so that what a test is looking at is the SQL a store
// sent and the rows it read back.
//
// `answer` gives back one of:
//
//     { fields: [{ name, oid }], rows: [[text or null]], tag: "SELECT 1" }
//     { error: { code: "23505", message: "…" } }
export server(answer) = listen(0, (sock) -> joined(answer, sock))

export portOf(s) = localPort(s)

joined(answer, sock)
    var started = false
    var asked = false
    var held = []
    var sql = null
    var params = []

    // One whole message, and what this server says back to it.
    //
    // **The extended protocol is answered at `Sync` and at nothing before it.** A client writes
    // `Parse`, `Bind`, `Describe`, `Execute` and `Sync` in one flush, and every reply belongs after
    // the last of them.
    heard(tag: string, body: array)
        if tag == "Q"
            send(sock, replyTo(answer(reader(body).text(), []), false))
        elif tag == "P"
            val r = reader(body)

            r.text()

            sql = r.text()
            params = []
        elif tag == "B"
            val r = reader(body)

            r.text()
            r.text()

            val formats = r.int16()

            for i in 0..<formats
                r.int16()

            val given = r.int16()

            for i in 0..<given
                val size = r.int32()

                push(params, if size < 0 then null else fromBytes(r.bytes(size)).value)
        elif tag == "S"
            send(sock, replyTo(answer(sql, params), true))
        elif tag == "X"
            closeSocket(sock)

    arrived(chunk)
        if chunk == null
            closeSocket(sock)

            return

        putBytes(held, chunk)

        // **The startup packet has no tag**, so it is read by length before the framed reader takes
        // over. Everything after it is an ordinary tagged message.
        if !started
            if held.length < 4 then return

            val size = sizeAt(held, 0)

            if held.length < size then return

            // **The SSLRequest arrives BEFORE the startup packet and is shaped like one**: eight
            // bytes, a length and a magic number where a protocol version goes. It is answered with
            // one bare byte and no framing, which is the only message in the protocol that has
            // none. This server has no certificate, so the answer is always `N` and the connection
            // carries on in the clear -- which is what `sslmode: "prefer"`, the default, does.
            if !asked && size == 8 && sizeAt(held, 4) == 80877103
                asked = true
                held = held[8..]

                send(sock, "N")

                return

            val rest = held[size..]

            started = true
            held = []

            send(sock, joined4(authOk(),
                               parameterStatus("server_version", "16.0"),
                               backendKey(1234, 5678),
                               readyFor("I")))

            putBytes(held, rest)

        while true
            if held.length < 5 then return

            val size = sizeAt(held, 1)

            if held.length < size + 1 then return

            val tag = fromBytes([held[0]]).value
            val body = held[5..<(size + 1)]

            held = held[(size + 1)..]

            heard(tag, body)

    onBytes(sock, arrived)

// What a server says about one statement, as bytes.
replyTo(said: object, extended: boolean) -> array
    var out = []

    if extended
        putBytes(out, parseComplete())
        putBytes(out, bindComplete())

    if has(said, "error")
        putBytes(out, errorResponse([{ kind: "S", text: "ERROR" },
                                     { kind: "C", text: said.error.code },
                                     { kind: "M", text: said.error.message }]))
        putBytes(out, readyFor("I"))

        return out

    val fields = said.fields ?? []

    // **A statement with no columns sends `NoData` and not an empty `RowDescription`**, which is
    // what a real server does for an `insert` with no `returning` -- and what a client has to be
    // able to step over.
    if fields.length == 0
        if extended then putBytes(out, noData())
    else
        putBytes(out, describe(fields))

        for row in (said.rows ?? [])
            putBytes(out, dataRow(row))

    putBytes(out, commandComplete(said.tag))
    putBytes(out, readyFor("I"))

    out

// -- the messages, written out from the protocol ---------------------------------------------------

// A message is a tag, a four-byte length that COUNTS ITSELF, and that many bytes less four.
framed(tag: string, body: array) -> array
    var out = []

    putBytes(out, toBytes(tag))
    putInt32(out, body.length + 4)
    putBytes(out, body)

    out

authOk() -> array
    var body = []

    putInt32(body, 0)

    framed("R", body)

parameterStatus(name: string, value: string) -> array
    var body = []

    putText(body, name)
    putText(body, value)

    framed("S", body)

backendKey(pid: integer, key: integer) -> array
    var body = []

    putInt32(body, pid)
    putInt32(body, key)

    framed("K", body)

// `ReadyForQuery`, whose one byte is the transaction status: `I`, `T` or `E`.
readyFor(state: string) -> array
    var body = []

    putBytes(body, toBytes(state))

    framed("Z", body)

// `RowDescription`. Each column carries its table, its type and the format it is sent in, all of
// which a client reads -- so all of which have to be here.
describe(fields: array) -> array
    var body = []

    putInt16(body, fields.length)

    for f in fields
        putText(body, f.name)
        putInt32(body, 0)
        putInt16(body, 0)
        putInt32(body, f.oid)
        putInt16(body, -1)
        putInt32(body, -1)
        putInt16(body, 0)

    framed("T", body)

// `DataRow`. **A column with no value is a length of -1 and not an empty one**, which is the
// difference between `null` and `""` and the thing this server exists to be able to send.
dataRow(values: array) -> array
    var body = []

    putInt16(body, values.length)

    for v in values
        if v == null
            putInt32(body, -1)
        else
            val bs = toBytes(v)

            putInt32(body, bs.length)
            putBytes(body, bs)

    framed("D", body)

commandComplete(tag: string) -> array
    var body = []

    putText(body, tag)

    framed("C", body)

// `ErrorResponse` -- field letters, each with a string, and a zero byte to finish. `C` is the
// SQLSTATE, which is the one thing the application above reads.
errorResponse(fields: array) -> array
    var body = []

    for f in fields
        putBytes(body, toBytes(f.kind))
        putText(body, f.text)

    push(body, 0)

    framed("E", body)

parseComplete() -> array = framed("1", [])

bindComplete() -> array = framed("2", [])

noData() -> array = framed("n", [])

joined4(a: array, b: array, c: array, d: array) -> array
    var out = []

    putBytes(out, a)
    putBytes(out, b)
    putBytes(out, c)
    putBytes(out, d)

    out

// -- bytes -------------------------------------------------------------------------------------

putInt32(out: array, n: integer)
    push(out, (n >> 24) & 255)
    push(out, (n >> 16) & 255)
    push(out, (n >> 8) & 255)
    push(out, n & 255)

putInt16(out: array, n: integer)
    push(out, (n >> 8) & 255)
    push(out, n & 255)

putBytes(out: array, bs: array)
    for b in bs
        push(out, b)

// A string as the protocol carries one: its UTF-8, then a zero byte.
putText(out: array, s: string)
    putBytes(out, toBytes(s))
    push(out, 0)

// A length, which is never negative.
sizeAt(bs: array, at: integer) -> integer =
    (bs[at] << 24) | (bs[at + 1] << 16) | (bs[at + 2] << 8) | bs[at + 3]

// A reader over a message body.
//
// **`int32` is SIGNED**, because -1 is how the protocol says *there is no value here* -- read
// unsigned it is four billion bytes still to come and a client waits forever.
reader(bs: array) -> object
    var at = 0

    int32() -> integer
        val n = sizeAt(bs, at)

        at = at + 4

        if n >= 2147483648 then n - 4294967296 else n

    int16() -> integer
        val n = (bs[at] << 8) | bs[at + 1]

        at = at + 2

        n

    bytes(n: integer) -> array
        val out = bs[at..<(at + n)]

        at = at + n

        out

    text() -> string
        var end = at

        while end < bs.length && bs[end] != 0
            end = end + 1

        val out = fromBytes(bs[at..<end]).value

        at = end + 1

        out

    left() -> integer = bs.length - at

    { int32: int32, int16: int16, bytes: bytes, text: text, left: left }
