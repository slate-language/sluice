// Every problem document this package can emit, read as an RFC 9457 document rather than as the
// answer of the guard that wrote it.
//
// **THE DEFECT THIS FILE EXISTS FOR IS AN EXTENSION MEMBER WEARING A STANDARD MEMBER'S NAME.**
// `problemResponse` merges `extra` at the top level, which is where the specification puts an
// extension member -- so an extra called `type` does not sit beside the document's own `type`, it
// REPLACES it. `multipart`'s refusal of a file put the media type the client claimed under exactly
// that name, and the document that came back said `"type": "image/png"`: a problem type of
// `image/png` to anything reading the document by the specification, which is not a URI and is not
// what the refusal was about. `title`, `status` and `detail` were already refused outright, having
// arguments of their own; `type` and `instance` cannot be, because `extra` is the only way to say
// either -- so the check on them is this sweep.
//
// **IT IS A SWEEP AND NOT A TEST OF THE ONE SITE**, because what went wrong is a mistake any
// refusal can make and none of them announces: a document with a wrong `type` is a perfectly good
// answer with a perfectly good status and reads correctly to anything that does not follow the
// specification. So every place this package builds a problem is driven here and every answer is
// read the same way. A new refusal added with no case here is one this file cannot see, which is why
// each case names its site.

import { api, body, query, bearer, csrf, multipart, timeout, rateLimit, request } from "../sluice.sl"
import { doc, status, header } from "./support.sl"

type Paging = { page: string }

// The five members RFC 9457 gives a problem document. Nothing else in one is standard, and an
// extension member is anything that is not one of these.
val Standard = ["type", "title", "status", "detail", "instance"]

// Every answer that is a problem document reads this way, whatever built it.
//
// **`type` IS THE ASSERTION THIS FILE IS FOR.** Nothing in this package names a problem type of its
// own -- an application with a URI for a kind of failure passes it to `problem` itself -- so every
// document built here says `about:blank`, and anything else is an extension member that has landed
// on top of it.
sound(r, where: string)
    val d = doc(r)

    assertEq(header(r, "content-type"), "application/problem+json", where + ": the registered media type")
    assertEq(d.type, "about:blank", where + ": `type` is the PROBLEM's type and not an extension member")
    assertEq(d.status, status(r), where + ": `status` is the response's own status")
    assert(d.title is string && d.title != "", where + ": `title` is a short summary")

    if has(d, "detail") then assert(d.detail is string, where + ": `detail` is human-readable text")

    // **`instance` is a URI reference identifying THIS occurrence**, which is the path that was
    // asked for. A member of that name carrying anything else is the same mistake `type` made.
    if has(d, "instance") then assert(d.instance is string && startsWith(d.instance, "/"),
        where + ": `instance` is a reference to the occurrence")

    d

// The members of a document that are not the specification's own.
extensions(d: object) -> array
    var out = []

    for [k, v] in entries(d)
        if !contains(Standard, k) then push(out, k)

    out

// -- the bodies `multipart` is driven with ------------------------------------------------------------

val Boundary = "----sluiceFormBoundary7MA4YWxk"

sending(boundary: string) -> object = { "Content-Type": "multipart/form-data; boundary=" + boundary }

joined(pieces: array) -> array
    var out = []

    for piece in pieces
        out = concat(out, if piece is string then toBytes(piece) else piece)

    out

posted(parts: array) -> array
    var out = []

    for part in parts
        out = joined([out, "--" + Boundary + "\r\n", part, "\r\n"])

    joined([out, "--" + Boundary + "--\r\n"])

file(name: string, filename: string, kind: string, content) -> array
    val said = "Content-Disposition: form-data; name=\"" + name + "\"; filename=\"" + filename + "\""

    joined([said, "\r\nContent-Type: " + kind + "\r\n\r\n", content])

field(name: string, value) -> array =
    joined(["Content-Disposition: form-data; name=\"" + name + "\"\r\n\r\n", value])

uploading(options: object) -> object
    val app = api()

    app.post("/notes", multipart(options, (req) -> req.form))

    app

// -- one producer per place this package builds a problem ------------------------------------------

// `api.handle`: no route matched.
async noRoute()
    val app = api()

    app.get("/notes", (req) -> "the notes")

    await app.handle(request("GET", "/nothing"))

// `api.handle`: the path is there and the method is not.
async noMethod()
    val app = api()

    app.get("/notes", (req) -> "the notes")

    await app.handle(request("POST", "/notes"))

// `api.handle`: a handler that faults. **`onFault` is passed** -- without it the fault goes back on
// the loop, which would end this suite.
async aFault()
    breaking(req)
        throw "the note store is not there"

    val app = api({ onFault: (e) -> null })

    app.get("/notes", breaking)

    await app.handle(request("GET", "/notes"))

// `api.handle`: the server is draining.
async draining()
    val app = api()

    app.get("/notes", (req) -> "the notes")
    app.stop()

    await app.handle(request("GET", "/notes"))

// `body`: the text is not JSON.
async notJSON()
    val app = api()

    app.post("/notes", body(Paging, (req) -> "kept"))

    await app.handle(request("POST", "/notes", { body: "{ not json" }))

// `body`: the JSON does not fit the shape.
async bodyMisfits()
    val app = api()

    app.post("/notes", body(Paging, (req) -> "kept"))

    await app.handle(request("POST", "/notes", { body: { page: 2 } }))

// `query`: the query string does not fit the shape.
async queryMisfits()
    val app = api()

    app.get("/notes", query(Paging, (req) -> "listed"))

    await app.handle(request("GET", "/notes"))

// `bearer`: no token at all.
async noToken()
    val app = api()

    app.get("/me", bearer((t) -> { ok: true, value: {} }, (req) -> "ada"))

    await app.handle(request("GET", "/me"))

// `bearer`: a token the application's verifier turned down.
async badToken()
    val app = api()

    app.get("/me", bearer((t) -> { ok: false, error: "that token has expired" }, (req) -> "ada"))

    await app.handle(request("GET", "/me", { headers: { Authorization: "Bearer old" } }))

// `csrf`: an unsafe request carrying the cookie and no header.
async noCsrfHeader()
    val app = api()

    app.post("/write", csrf({}, (req) -> "written"))

    await app.handle(request("POST", "/write", { cookies: { csrf: "abc" } }))

// `csrf`: the header and the cookie disagree.
async csrfMismatch()
    val app = api()

    app.post("/write", csrf({}, (req) -> "written"))

    await app.handle(request("POST", "/write",
        { cookies: { csrf: "abc" }, headers: { "x-csrf-token": "abd" } }))

// `multipart`: the body is not multipart at all.
async notMultipart() =
    await uploading({}).handle(request("POST", "/notes",
        { headers: { "Content-Type": "application/json" }, body: "{}" }))

// `multipart`: a multipart Content-Type naming no boundary.
async noBoundary() =
    await uploading({}).handle(request("POST", "/notes",
        { headers: { "Content-Type": "multipart/form-data" }, body: "anything" }))

// `multipart`: a body over `maxBytes`.
async tooLarge() =
    await uploading({ maxBytes: 64 }).handle(request("POST", "/notes",
        { headers: sending(Boundary), bytes: posted([field("title", repeat("a", 200))]) }))

// `multipart`: a body that will not parse.
async unreadable() =
    await uploading({}).handle(request("POST", "/notes",
        { headers: sending(Boundary), body: "not a form at all" }))

// `multipart`: a file the endpoint's own predicate turned down. **The site the defect was at.**
async refusedFile() =
    await uploading({ accept: (f) -> false }).handle(request("POST", "/notes",
        { headers: sending(Boundary),
          bytes: posted([file("u", "notes.txt", "image/png", "not a png at all")]) }))

// `timeout`: a handler that never answers.
async tooSlow()
    stuck(req) = pending()

    val app = api()

    app.get("/notes", timeout(5, {}, stuck))

    await app.handle(request("GET", "/notes"))

// `rateLimit`: a client over its allowance.
async overTheLimit()
    val app = api()

    app.get("/notes", rateLimit({ limit: 1, window: 1000, now: () -> 0 }, (req) -> "the notes"))

    await app.handle(request("GET", "/notes"))

    await app.handle(request("GET", "/notes"))

// `health`: a check with something to report.
async unwell()
    val app = api()

    app.health("/health", () -> ["the note store is not answering"])

    await app.handle(request("GET", "/health"))

// Every one of them, each named by the site that builds it.
cases() -> array =
    [{ where: "api: no route", make: noRoute, status: 404 },
     { where: "api: no such method", make: noMethod, status: 405 },
     { where: "api: a handler that faulted", make: aFault, status: 500 },
     { where: "api: draining", make: draining, status: 503 },
     { where: "body: not JSON", make: notJSON, status: 400 },
     { where: "body: does not fit", make: bodyMisfits, status: 400 },
     { where: "query: does not fit", make: queryMisfits, status: 400 },
     { where: "bearer: no token", make: noToken, status: 401 },
     { where: "bearer: a token that did not verify", make: badToken, status: 401 },
     { where: "csrf: no header", make: noCsrfHeader, status: 403 },
     { where: "csrf: header and cookie disagree", make: csrfMismatch, status: 403 },
     { where: "multipart: not multipart", make: notMultipart, status: 415 },
     { where: "multipart: no boundary", make: noBoundary, status: 400 },
     { where: "multipart: over maxBytes", make: tooLarge, status: 413 },
     { where: "multipart: will not parse", make: unreadable, status: 400 },
     { where: "multipart: accept refused a file", make: refusedFile, status: 415 },
     { where: "timeout: no answer in time", make: tooSlow, status: 503 },
     { where: "rateLimit: over the allowance", make: overTheLimit, status: 429 },
     { where: "health: a check with reasons", make: unwell, status: 503 }]

@test
async NO_PROBLEM_DOCUMENT_THIS_PACKAGE_EMITS_CARRIES_A_STANDARD_MEMBERS_NAME_AS_AN_EXTENSION()
    // **The whole point of the sweep**: every refusal is read as an RFC 9457 document, and an
    // extension member that has taken a standard member's name shows up as a `type` that is not
    // `about:blank`, a `status` that is not the status, or an `instance` that is not a path.
    for one in cases()
        val r = await one.make()

        assertEq(status(r), one.status, one.where + ": the status this site answers")

        sound(r, one.where)

@test
async EVERY_EXTENSION_MEMBER_IS_NAMED_AND_NONE_OF_THEM_IS_A_STANDARD_ONE()
    // The same sweep read the other way round: the members that are NOT the specification's are
    // listed here, so a refusal that grows one arrives at this assertion rather than at a consumer.
    // `extensions` cannot answer a standard name by construction; what this pins is which extension
    // members this package promises, and a rename is a change to this list.
    var found = {}

    for one in cases()
        found[one.where] = extensions(sound(await one.make(), one.where))

    assertEq(found, { "api: no route": [],
                      "api: no such method": [],
                      "api: a handler that faulted": [],
                      "api: draining": [],
                      "body: not JSON": ["parse"],
                      "body: does not fit": ["mismatch"],
                      "query: does not fit": ["mismatch"],
                      "bearer: no token": [],
                      "bearer: a token that did not verify": [],
                      "csrf: no header": [],
                      "csrf: header and cookie disagree": [],
                      "multipart: not multipart": ["received"],
                      "multipart: no boundary": [],
                      "multipart: over maxBytes": ["limit", "size"],
                      "multipart: will not parse": ["reason"],
                      "multipart: accept refused a file": ["field", "filename", "mediaType"],
                      "timeout: no answer in time": [],
                      "rateLimit: over the allowance": [],
                      "health: a check with reasons": ["reasons"] })

@test
async AN_EXTENSION_MEMBER_CALLED_type_REALLY_DOES_REPLACE_THE_DOCUMENTS_OWN()
    // **The control, and the reason the sweep above is worth running.** This is not a hypothetical
    // hazard: `extra` is merged at the top level, so a member of a standard name wins. `type` and
    // `instance` are deliberately left open, an application with a URI of its own having no other
    // way to say one -- so nothing refuses this, and only the sweep can see it.
    val d = doc(await refusedFile())

    assertEq(d.type, "about:blank")
    assertEq(d.mediaType, "image/png", "the media type the client claimed, under a name of its own")
    assert(!has(d, "type") || d.type != "image/png", "and not under the document's own `type`")
