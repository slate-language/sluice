// `multipart(options)` -- the body a browser sends when a form has a file in it.
//
// **The bodies here are built by hand, byte for byte as a browser writes them**, which is the only
// honest way to test a parser: a body this file generated with the parser's own idea of the format
// would agree with it by construction and pass for every mistake either could make.

import { api, multipart, request, response } from "../sluice.sl"
import { doc, status } from "./support.sl"

val Boundary = "----sluiceFormBoundary7MA4YWxk"

// The `Content-Type` a client sends with one of these.
sending(boundary: string) -> object = { "Content-Type": "multipart/form-data; boundary=" + boundary }

// A body out of parts already written as `headers\r\n\r\ncontent`.
posted(parts: array) -> string
    var out = ""

    for part in parts
        out = out + "--" + Boundary + "\r\n" + part + "\r\n"

    out + "--" + Boundary + "--\r\n"

field(name: string, value: string) -> string =
    "Content-Disposition: form-data; name=\"" + name + "\"\r\n\r\n" + value

file(name: string, filename: string, kind: string, content: string) -> string
    val said = "Content-Disposition: form-data; name=\"" + name + "\"; filename=\"" + filename + "\""

    said + "\r\nContent-Type: " + kind + "\r\n\r\n" + content

// An api whose one route hands the form straight back.
made(options: object) -> object
    val app = api()

    app.post("/notes", multipart(options, (req) -> req.form))

    app

@test
async TWO_FIELDS_AND_A_FILE_ARRIVE_AS_A_FORM()
    val app = made({})
    val body = posted([field("title", "A note"),
                       field("pinned", "true"),
                       file("upload", "notes.txt", "text/plain", "hello\r\nworld")])

    val form = await app.handle(request("POST", "/notes", { headers: sending(Boundary), body: body }))

    assertEq(form.fields, { title: "A note", pinned: "true" })
    assertEq(len(form.files), 1)
    assertEq(form.files[0].field, "upload")
    assertEq(form.files[0].filename, "notes.txt")
    assertEq(form.files[0].type, "text/plain")
    assertEq(form.files[0].content, "hello\r\nworld", "a line break inside a file is content and not a boundary")

@test
async THE_TEXT_THAT_ARRIVED_IS_KEPT_ON_raw()
    // The same promise `body` makes, and for the same reason: a handler checking a signature wants
    // exactly the bytes that arrived and not this parser's reading of them.
    val app = api()
    val body = posted([field("title", "A note")])

    app.post("/notes", multipart({}, (req) -> req.raw))

    assertEq(await app.handle(request("POST", "/notes", { headers: sending(Boundary), body: body })), body)

@test
async A_FIELD_WITH_NO_VALUE_IS_AN_EMPTY_STRING_AND_NOT_AN_ABSENCE()
    val app = made({})
    val body = posted([field("title", "")])

    assertEq((await app.handle(request("POST", "/notes", { headers: sending(Boundary), body: body }))).fields, { title: "" })

@test
async A_REPEATED_FIELD_KEEPS_THE_LAST_AND_TWO_FILES_KEEP_BOTH()
    // **The asymmetry is what the two are used for.** A field is read by name -- and a repeated name
    // keeping the last is the rule `slate:http` already applies to a query string -- while files are
    // walked, may share one name, and each carries the name it was sent under.
    val app = made({})
    val body = posted([field("tag", "one"),
                       field("tag", "two"),
                       file("page", "a.txt", "text/plain", "A"),
                       file("page", "b.txt", "text/plain", "B")])

    val form = await app.handle(request("POST", "/notes", { headers: sending(Boundary), body: body }))

    assertEq(form.fields, { tag: "two" })
    assertEq(len(form.files), 2)
    assertEq([form.files[0].filename, form.files[1].filename], ["a.txt", "b.txt"])
    assertEq([form.files[0].field, form.files[1].field], ["page", "page"])

@test
async A_FILE_WITH_NO_CONTENT_TYPE_IS_TEXT()
    // RFC 7578's own default, and the honest one here: what arrives is text or it does not arrive.
    val app = made({})
    val body = posted(["Content-Disposition: form-data; name=\"u\"; filename=\"a.txt\"\r\n\r\nA"])

    assertEq((await app.handle(request("POST", "/notes", { headers: sending(Boundary), body: body }))).files[0].type, "text/plain")

@test
async A_FILENAME_CARRYING_A_SEMICOLON_SURVIVES_ITS_QUOTES()
    // **The whole reason the parameters are scanned rather than split.** `split` on `;` would cut
    // this filename in half and leave the part with no name at all.
    val app = made({})
    val body = posted([file("u", "a;b.txt", "text/plain", "A")])

    assertEq((await app.handle(request("POST", "/notes", { headers: sending(Boundary), body: body }))).files[0].filename, "a;b.txt")

@test
async A_PREAMBLE_AND_AN_EPILOGUE_ARE_BOTH_IGNORED()
    // RFC 2046 allows both, and a client that sends one is not sending a malformed body.
    val app = made({})
    val body = "this is not part of anything\r\n" + posted([field("title", "A note")]) + "nor is this\r\n"

    assertEq((await app.handle(request("POST", "/notes", { headers: sending(Boundary), body: body }))).fields, { title: "A note" })

@test
async A_BOUNDARY_THE_CLIENT_QUOTED_IS_THE_SAME_BOUNDARY()
    val app = made({})
    val body = posted([field("title", "A note")])
    val heads = { "Content-Type": "multipart/form-data; boundary=\"" + Boundary + "\"" }

    assertEq((await app.handle(request("POST", "/notes", { headers: heads, body: body }))).fields, { title: "A note" })

// -- and what it refuses ------------------------------------------------------------------------------

@test
async A_BODY_THAT_IS_NOT_MULTIPART_IS_A_415()
    // **415 and not 400**, which is RFC 9110's own distinction: the body may be perfectly well formed
    // and simply not be the media type this endpoint takes.
    val app = made({})
    val r = await app.handle(request("POST", "/notes",
        { headers: { "Content-Type": "application/json" }, body: "{}" }))

    assertEq(status(r), 415)
    assertEq(doc(r).title, "Unsupported Media Type")
    assertEq(doc(r).received, "application/json")

@test
async A_REQUEST_WITH_NO_CONTENT_TYPE_AT_ALL_IS_THE_SAME_415()
    val app = made({})
    val r = await app.handle(request("POST", "/notes", { body: "nothing much" }))

    assertEq(status(r), 415)
    assertEq(doc(r).received, "nothing")

@test
async A_CONTENT_TYPE_WITH_NO_BOUNDARY_IS_A_400()
    val app = made({})
    val r = await app.handle(request("POST", "/notes",
        { headers: { "Content-Type": "multipart/form-data" }, body: "anything" }))

    assertEq(status(r), 400)
    assertEq(doc(r).detail, "the Content-Type names no multipart boundary")

@test
async A_BODY_WITH_NO_CLOSING_BOUNDARY_IS_A_400_SAYING_SO()
    // The shape a cut-off upload has: everything up to where the connection went.
    val app = made({})
    val body = "--" + Boundary + "\r\n" + field("title", "A note") + "\r\n"

    val r = await app.handle(request("POST", "/notes", { headers: sending(Boundary), body: body }))

    assertEq(status(r), 400)
    assertEq(doc(r).detail, "the multipart body could not be read")
    assertEq(doc(r).reason, "the body ends without a closing boundary")

@test
async A_BODY_THE_BOUNDARY_IS_NOT_IN_AT_ALL_IS_A_400()
    val app = made({})
    val r = await app.handle(request("POST", "/notes", { headers: sending(Boundary), body: "not a form" }))

    assertEq(status(r), 400)
    assertEq(doc(r).reason, "the boundary does not appear in the body")

@test
async A_PART_WITH_NO_BLANK_LINE_AFTER_ITS_HEADERS_IS_A_400()
    val app = made({})
    val body = posted(["Content-Disposition: form-data; name=\"title\"\r\nA note"])

    assertEq(doc(await app.handle(request("POST", "/notes", { headers: sending(Boundary), body: body }))).reason,
        "a part has no blank line after its headers")

@test
async A_PART_WITH_NO_NAME_IS_A_400()
    val app = made({})
    val body = posted(["Content-Disposition: form-data\r\n\r\nA note"])

    assertEq(doc(await app.handle(request("POST", "/notes", { headers: sending(Boundary), body: body }))).reason,
        "a part has no name in its Content-Disposition")

@test
async A_BODY_WRITTEN_WITH_BARE_LINE_FEEDS_IS_REFUSED_RATHER_THAN_GUESSED_AT()
    // **CRLF is the specification's**, and a parser that quietly accepted `\n` would be deciding on a
    // client's behalf where its file ends -- a `\n` inside an uploaded file is content.
    val app = made({})
    val body = "--" + Boundary + "\nContent-Disposition: form-data; name=\"t\"\n\nA\n--" + Boundary + "--\n"

    val r = await app.handle(request("POST", "/notes", { headers: sending(Boundary), body: body }))

    assertEq(status(r), 400)
    assertEq(doc(r).reason, "a part does not begin with a line break")

@test
async A_BODY_OVER_THE_LIMIT_IS_A_413_SAYING_WHAT_THE_LIMIT_IS()
    val app = made({ limit: 64 })
    val body = posted([field("title", repeat("a", 200))])

    val r = await app.handle(request("POST", "/notes", { headers: sending(Boundary), body: body }))

    assertEq(status(r), 413)
    assertEq(doc(r).title, "Content Too Large")
    assertEq(doc(r).limit, 64)
    assert(doc(r).size > 64)

@test
async THE_LIMIT_IS_COUNTED_IN_BYTES_AND_NOT_IN_CHARACTERS()
    // **A limit is about what the socket carried.** Twenty characters of Japanese are sixty bytes,
    // and a limiter that counted characters would let three times what it promised through.
    val body = posted([field("title", repeat("日", 30))])
    val chars = len(body)
    val bytes = len(toBytes(body))

    assert(bytes > chars, "sixty bytes of Japanese are thirty characters")

    val counting = made({ limit: chars })
    val allowing = made({ limit: bytes })

    assertEq(status(await counting.handle(request("POST", "/notes", { headers: sending(Boundary), body: body }))), 413)
    assertEq(status(await allowing.handle(request("POST", "/notes", { headers: sending(Boundary), body: body }))), 200)

@test
async THE_HANDLER_DOES_NOT_RUN_FOR_A_BODY_THAT_WAS_REFUSED()
    var ran = 0
    val app = api()

    counted(req)
        ran = ran + 1

        "reached"

    app.post("/notes", multipart({}, counted))

    await app.handle(request("POST", "/notes", { headers: { "Content-Type": "text/plain" }, body: "x" }))
    await app.handle(request("POST", "/notes", { headers: sending(Boundary), body: "not a form" }))

    assertEq(ran, 0)

@test
async THE_GUARD_PRINTS_UNDER_ITS_OWN_NAME()
    val app = made({})

    assertEq(app.routes()[0].guards, ["multipart"])
