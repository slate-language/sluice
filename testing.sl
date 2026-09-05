// Building a request by hand, which is how everything here is tested and how a consumer tests a
// handler of its own.
//
// **`await api.handle(request(…))` needs no port, no server and no client.** A request is a value
// and a handler is a function of it, so a suite that binds nothing cannot flake under load, cannot
// collide with a development server on 8080, and needs no watchdog to notice a reply that never
// came.

import { encodeComponent } from slate:http

// `request(method, path, options)` -- a request value, filled in the way a server would fill it.
//
// | option | |
// |---|---|
// | `headers` | an object; the names are lowercased, which is how they arrive over a socket |
// | `body` | a string as it stands, anything else encoded as JSON |
// | `bytes` | the body as bytes, where a test means to send something that is not text |
// | `query` | an object, which also becomes `search` |
// | `search` | the raw text after the `?`, where a test means to write it itself |
// | `cookies` | an object |
// | `address` | the IP that connected; `"127.0.0.1"` by default, as a loopback client reads |
//
// **`params` is `{}` here and is filled in by `handle`**, a route's `:name` being something only a
// route knows about.
//
// **`body` AND `bytes` ARE BOTH THERE, BECAUSE `serve` PUTS BOTH THERE.** slate 0.0.30 gives a
// request the text and the bytes of what arrived, and they are two readings of one body rather than
// two bodies -- so writing one here fills the other, and a test that means to send bytes that are not
// text writes `bytes` and gets the `""` that `serve` would have given `body`.
export request(method: string, path: string, options: object = {}) -> object
    val given = if has(options, "headers") then options.headers else {}
    var headers = {}

    for [k, v] in entries(given)
        headers[lower(k)] = v

    // **Every query value is text, because that is the only thing a query string can carry.** A
    // helper that let `{ n: 3 }` through as an integer would let a shape asking for one fit here and
    // never fit over a socket, which is a suite agreeing with itself rather than with HTTP.
    val query = asText(if has(options, "query") then options.query else {})
    val search = if has(options, "search") then options.search else asSearch(query)

    var req = { method: method,
                path: path,
                search: search,
                headers: headers,
                query: query,
                cookies: if has(options, "cookies") then options.cookies else {},
                params: {},
                address: if has(options, "address") then options.address else "127.0.0.1",
                keepAlive: true,
                upgrade: false }

    if has(options, "bytes") then return req with { bytes: options.bytes, body: textOf(options.bytes) }

    if !has(options, "body") then return req

    val body = if options.body is string then options.body else toJSON(options.body)

    req with { body: body, bytes: toBytes(body) }

// Bytes as the text `serve` would have made of them. **A body that is not UTF-8 is `""` and not a
// fault**, which is exactly what the server does with one: `body` is the reading and `bytes` are what
// arrived.
textOf(bs: array) -> string
    val read = fromBytes(bs)

    if read.ok then read.value else ""

// Every value of an object rendered as the text a query string would have held.
asText(query: object) -> object
    var out = {}

    for [k, v] in entries(query)
        out[k] = string(v)

    out

// A query object as the text that would have carried it.
asSearch(query: object) -> string
    var parts = []

    for [k, v] in entries(query)
        push(parts, encodeComponent(k) + "=" + encodeComponent(string(v)))

    join(parts, "&")
