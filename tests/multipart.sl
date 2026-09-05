// `multipart(options)` -- the body a browser sends when a form has a file in it.
//
// **The bodies here are built by hand, byte for byte as a browser writes them**, which is the only
// honest way to test a parser: a body this file generated with the parser's own idea of the format
// would agree with it by construction and pass for every mistake either could make.
//
// **AND THEY ARE BUILT AS BYTES, WHICH IS WHAT THIS PARSER READS.** A multipart body carrying a file
// is not text and never was; `posted` therefore answers an array of bytes and every request here
// sends it as `bytes`, which is what `serve` puts on a request beside the `body` it could make of it.

import { api, multipart, request, response } from "../sluice.sl"
import { doc, status } from "./support.sl"

val Boundary = "----sluiceFormBoundary7MA4YWxk"

// The `Content-Type` a client sends with one of these.
sending(boundary: string) -> object = { "Content-Type": "multipart/form-data; boundary=" + boundary }

// Pieces -- each a string or an array of bytes -- as the one array of bytes they are.
joined(pieces: array) -> array
    var out = []

    for piece in pieces
        out = concat(out, if piece is string then toBytes(piece) else piece)

    out

// A body out of parts already written as `headers\r\n\r\ncontent`.
posted(parts: array) -> array
    var out = []

    for part in parts
        out = joined([out, "--" + Boundary + "\r\n", part, "\r\n"])

    joined([out, "--" + Boundary + "--\r\n"])

field(name: string, value) -> array =
    joined(["Content-Disposition: form-data; name=\"" + name + "\"\r\n\r\n", value])

file(name: string, filename: string, kind: string, content) -> array
    val said = "Content-Disposition: form-data; name=\"" + name + "\"; filename=\"" + filename + "\""

    joined([said, "\r\nContent-Type: " + kind + "\r\n\r\n", content])

// A request carrying one of these bodies.
sent(body: array) -> object = request("POST", "/notes", { headers: sending(Boundary), bytes: body })

// An api whose one route hands the form straight back.
made(options: object) -> object
    val app = api()

    app.post("/notes", multipart(options, (req) -> req.form))

    app

// Bytes no decoder will read as text: a NUL, a 0xFF, and a lone continuation byte.
val Binary = [0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0xFE, 0x80, 0x0D, 0x0A, 0x2D, 0x2D, 0x00]

@test
async TWO_FIELDS_AND_A_FILE_ARRIVE_AS_A_FORM()
    val app = made({})
    val body = posted([field("title", "A note"),
                       field("pinned", "true"),
                       file("upload", "notes.txt", "text/plain", "hello\r\nworld")])

    val form = await app.handle(sent(body))

    assertEq(form.fields, { title: "A note", pinned: "true" })
    assertEq(len(form.files), 1)
    assertEq(form.files[0].field, "upload")
    assertEq(form.files[0].filename, "notes.txt")
    assertEq(form.files[0].type, "text/plain")
    assertEq(form.files[0].bytes, toBytes("hello\r\nworld"))
    assertEq(form.files[0].text(), "hello\r\nworld", "a line break inside a file is content and not a boundary")

@test
async A_BINARY_FILE_ARRIVES_AS_THE_BYTES_THAT_WERE_SENT()
    // **THE WHOLE REASON THE FLOOR IS slate 0.0.30.** Until `req.bytes` a body that was not UTF-8
    // decoded to the empty string on the way to the handler, so this upload arrived as nothing at
    // all -- no header, no status, no fault -- and this guard was for text uploads and said so.
    val app = made({})
    val body = posted([field("title", "A screenshot"),
                       file("upload", "shot.png", "image/png", Binary)])

    val form = await app.handle(sent(body))

    assertEq(form.fields, { title: "A screenshot" })
    assertEq(form.files[0].bytes, Binary)
    assertEq(form.files[0].type, "image/png")

@test
async A_FILE_THAT_IS_NOT_TEXT_ANSWERS_null_FOR_ITS_TEXT()
    // **`bytes` is one shape and `text()` is a question**, which is the same decision `slate:http`
    // made about a repeated query name: a member whose TYPE depends on what a client sent is a
    // program that works until somebody uploads a PNG.
    val app = made({})
    val form = await app.handle(sent(posted([file("a", "a.png", "image/png", Binary),
                                             file("b", "b.txt", "text/plain", "plain")])))

    assertEq(form.files[0].text(), null)
    assertEq(form.files[1].text(), "plain")

@test
async A_FIELD_WHOSE_BYTES_ARE_NOT_TEXT_IS_A_400_AND_NOT_A_SILENCE()
    // **A form field comes from a control a person typed into**, so it is text by construction and
    // bytes that are not text there are a malformed body -- said, rather than swallowed into an
    // empty string the way the whole body used to be.
    val app = made({})
    val r = await app.handle(sent(posted([field("title", Binary)])))

    assertEq(status(r), 400)
    assertEq(doc(r).reason, "a field is not text: title")

@test
async A_PART_WHOSE_HEADERS_ARE_NOT_TEXT_IS_A_400()
    val app = made({})
    val r = await app.handle(sent(posted([joined([Binary, "\r\n\r\nA"])])))

    assertEq(status(r), 400)
    assertEq(doc(r).reason, "a part's headers are not text")

@test
async CONTENT_THAT_LOOKS_LIKE_A_DELIMITER_AND_IS_NOT_IS_CONTENT()
    // **The search skips by the delimiter's width and drops back to comparing where it lands on a
    // byte the delimiter contains**, so the near-misses are what say the skip table is right rather
    // than merely fast. `--` and the first half of the boundary are exactly that.
    val near = "--" + "\r\n----sluiceFormBoundary7MA4YW\r\n--x--\r\n"
    val app = made({})
    val form = await app.handle(sent(posted([file("u", "a.txt", "text/plain", near)])))

    assertEq(len(form.files), 1)
    assertEq(form.files[0].text(), near)

@test
async THE_REQUESTS_OWN_BYTES_ARE_LEFT_ALONE()
    // **`raw` is gone and `req.bytes` is what it was for.** The server puts the body on every request
    // as text and as bytes, so a handler checking a signature over what actually arrived reads the
    // request rather than something this guard copied onto it.
    val app = api()
    val body = posted([field("title", "A note")])

    app.post("/notes", multipart({}, (req) -> req.bytes))

    assertEq(await app.handle(sent(body)), body)

@test
async A_FILE_THAT_WAS_EMPTY_IS_A_FILE_AND_NOT_AN_ABSENCE()
    // The file input a browser leaves as `filename=""` with no content, and the zero-byte file
    // somebody really chose. Both are parts, and a parser that took a length of nothing for a
    // malformed part would refuse an upload the client sent perfectly correctly.
    val app = made({})
    val form = await app.handle(sent(posted([file("u", "empty.txt", "text/plain", "")])))

    assertEq(len(form.files), 1)
    assertEq(form.files[0].bytes, [])
    assertEq(form.files[0].text(), "")

@test
async A_MEGABYTE_OF_BYTES_COMES_BACK_AS_THE_BYTES_IT_WENT_IN_AS()
    // **The default ceiling is a megabyte, so a body of that order has to be affordable and exact.**
    // What makes it affordable is the skipping search -- a comparison per byte would be seconds here
    // and this test's own timing is where that would show. What makes it exact is nothing clever:
    // the content is a slice of what arrived and no decoding happens on the way.
    var content = Binary
    var i = 0

    while i < 14
        content = concat(content, content)

        i = i + 1

    val app = made({})
    val form = await app.handle(sent(posted([field("title", "A big one"),
                                             file("u", "big.png", "image/png", content)])))

    assert(len(content) > 200000, "the body is of the order the ceiling is about")
    assertEq(len(form.files[0].bytes), len(content))
    assertEq(form.files[0].bytes, content)
    assertEq(form.fields, { title: "A big one" })

@test
async A_REQUEST_WITH_NO_BODY_AT_ALL_IS_A_400_AND_NOT_A_FAULT()
    // A `POST` with the header and nothing after it -- a client that gave up, or a proxy that cut it
    // off. There is no boundary in no bytes, which is what it is told.
    val app = made({})
    val r = await app.handle(request("POST", "/notes", { headers: sending(Boundary) }))

    assertEq(status(r), 400)
    assertEq(doc(r).reason, "the boundary does not appear in the body")

@test
async A_FIELD_WITH_NO_VALUE_IS_AN_EMPTY_STRING_AND_NOT_AN_ABSENCE()
    val app = made({})

    assertEq((await app.handle(sent(posted([field("title", "")])))).fields, { title: "" })

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

    val form = await app.handle(sent(body))

    assertEq(form.fields, { tag: "two" })
    assertEq(len(form.files), 2)
    assertEq([form.files[0].filename, form.files[1].filename], ["a.txt", "b.txt"])
    assertEq([form.files[0].field, form.files[1].field], ["page", "page"])

@test
async A_FILE_WITH_NO_CONTENT_TYPE_IS_TEXT()
    // RFC 7578's own default. **What that means is what the client CLAIMED and not what arrived** --
    // the bytes are the bytes either way, and `text()` is what answers whether they are readable.
    val app = made({})
    val body = posted([joined(["Content-Disposition: form-data; name=\"u\"; filename=\"a.txt\"\r\n\r\nA"])])

    assertEq((await app.handle(sent(body))).files[0].type, "text/plain")

@test
async A_FILENAME_CARRYING_A_SEMICOLON_SURVIVES_ITS_QUOTES()
    // **The whole reason the parameters are scanned rather than split.** `split` on `;` would cut
    // this filename in half and leave the part with no name at all.
    val app = made({})
    val body = posted([file("u", "a;b.txt", "text/plain", "A")])

    assertEq((await app.handle(sent(body))).files[0].filename, "a;b.txt")

@test
async A_PREAMBLE_AND_AN_EPILOGUE_ARE_BOTH_IGNORED()
    // RFC 2046 allows both, and a client that sends one is not sending a malformed body.
    val app = made({})
    val body = joined(["this is not part of anything\r\n",
                       posted([field("title", "A note")]),
                       "nor is this\r\n"])

    assertEq((await app.handle(sent(body))).fields, { title: "A note" })

@test
async A_BOUNDARY_THE_CLIENT_QUOTED_IS_THE_SAME_BOUNDARY()
    val app = made({})
    val body = posted([field("title", "A note")])
    val heads = { "Content-Type": "multipart/form-data; boundary=\"" + Boundary + "\"" }

    val r = await app.handle(request("POST", "/notes", { headers: heads, bytes: body }))

    assertEq(r.fields, { title: "A note" })

// -- what the endpoint will take ---------------------------------------------------------------------

@test
async A_FILE_accept_REFUSES_IS_A_415_NAMING_IT()
    // **An image-only endpoint is the application's rule and not this package's**, which is why the
    // option is a predicate rather than a list of media types: what a part CLAIMS is worth nothing,
    // and the predicate is given the bytes so that it can look at them instead.
    png(f) -> boolean = f.bytes[0] == 0x89 && f.bytes[1] == 0x50

    val app = made({ accept: png })
    val r = await app.handle(sent(posted([file("u", "notes.txt", "image/png", "not a png at all")])))

    assertEq(status(r), 415)
    assertEq(doc(r).title, "Unsupported Media Type")
    assertEq(doc(r).detail, "this endpoint does not take this upload")
    assertEq(doc(r).field, "u")
    assertEq(doc(r).filename, "notes.txt")
    assertEq(doc(r).mediaType, "image/png")

@test
async THE_REFUSED_FILES_MEDIA_TYPE_IS_NOT_THE_DOCUMENTS_OWN_type()
    // **RFC 9457's `type` is a URI naming the KIND OF PROBLEM**, and `about:blank` where there is
    // none. The media type the client claimed for the part is an extension member, so it goes under
    // a name of its own -- this said `"type": "image/png"`, which is not a problem type, is not a
    // URI, and replaced the one member of the document that says what went wrong.
    //
    // **The whole document is asserted rather than a member of it**, because what went wrong here
    // was a member that should not have been there at all: an assertion naming only the members it
    // expects cannot see one it did not expect.
    png(f) -> boolean = f.bytes[0] == 0x89 && f.bytes[1] == 0x50

    val app = made({ accept: png })
    val r = await app.handle(sent(posted([file("u", "notes.txt", "image/png", "not a png at all")])))

    assertEq(doc(r), { type: "about:blank",
                       title: "Unsupported Media Type",
                       status: 415,
                       detail: "this endpoint does not take this upload",
                       instance: "/notes",
                       field: "u",
                       filename: "notes.txt",
                       mediaType: "image/png" })

@test
async A_FILE_accept_TAKES_REACHES_THE_HANDLER_AND_FIELDS_ARE_NOT_ASKED_ABOUT()
    // The control, and the other half of the rule: `accept` is asked about files and a field is not
    // an upload.
    png(f) -> boolean = f.bytes[0] == 0x89

    val app = made({ accept: png })
    val form = await app.handle(sent(posted([field("title", "A screenshot"),
                                             file("u", "shot.png", "image/png", Binary)])))

    assertEq(form.fields, { title: "A screenshot" })
    assertEq(len(form.files), 1)

@test
async accept_IS_ASKED_ABOUT_FILES_AND_A_BODY_OF_ONLY_FIELDS_HAS_NONE()
    // The other edge of the same rule, and the one a form without an upload takes: a predicate that
    // refuses everything refuses nothing here, there being no file to ask it about.
    val app = made({ accept: (f) -> false })
    val form = await app.handle(sent(posted([field("title", "A note"), field("pinned", "true")])))

    assertEq(form.fields, { title: "A note", pinned: "true" })
    assertEq(len(form.files), 0)

@test
async THE_HANDLER_DOES_NOT_RUN_FOR_A_FILE_THAT_WAS_REFUSED()
    var ran = 0
    val app = api()

    counted(req)
        ran = ran + 1

        "reached"

    app.post("/notes", multipart({ accept: (f) -> false }, counted))

    await app.handle(sent(posted([file("u", "a.txt", "text/plain", "A")])))

    assertEq(ran, 0)

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
    val body = joined(["--" + Boundary + "\r\n", field("title", "A note"), "\r\n"])

    val r = await app.handle(sent(body))

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
    val body = posted([joined(["Content-Disposition: form-data; name=\"title\"\r\nA note"])])

    assertEq(doc(await app.handle(sent(body))).reason, "a part has no blank line after its headers")

@test
async A_PART_WITH_NO_NAME_IS_A_400()
    val app = made({})
    val body = posted([joined(["Content-Disposition: form-data\r\n\r\nA note"])])

    assertEq(doc(await app.handle(sent(body))).reason, "a part has no name in its Content-Disposition")

@test
async A_BODY_WRITTEN_WITH_BARE_LINE_FEEDS_IS_REFUSED_RATHER_THAN_GUESSED_AT()
    // **CRLF is the specification's**, and a parser that quietly accepted `\n` would be deciding on a
    // client's behalf where its file ends -- a `\n` inside an uploaded file is content.
    val app = made({})
    val body = "--" + Boundary + "\nContent-Disposition: form-data; name=\"t\"\n\nA\n--" + Boundary + "--\n"

    val r = await app.handle(request("POST", "/notes", { headers: sending(Boundary), body: body }))

    assertEq(status(r), 400)
    assertEq(doc(r).reason, "a part does not begin with a line break")

// -- and how much of it it will read -------------------------------------------------------------------

@test
async A_BODY_OVER_maxBytes_IS_A_413_SAYING_WHAT_THE_LIMIT_IS()
    val app = made({ maxBytes: 64 })
    val body = posted([field("title", repeat("a", 200))])

    val r = await app.handle(sent(body))

    assertEq(status(r), 413)
    assertEq(doc(r).title, "Content Too Large")
    assertEq(doc(r).limit, 64)
    assert(doc(r).size > 64)

@test
async THE_CEILING_IS_COUNTED_OVER_THE_BYTES_THAT_ARRIVED()
    // **THE HOLE THE TEXT READING LEFT, AND IT WAS IN THE LIMIT AND NOT ONLY IN THE PARSE.** The
    // count was `len(toBytes(req.body))`, and a body that is not UTF-8 has `body == ""` -- so a
    // binary upload of any size at all measured `0` and no ceiling ever refused one.
    val app = made({ maxBytes: 64 })
    var big = []
    var i = 0

    while i < 300
        big = concat(big, Binary)

        i = i + 1

    val r = await app.handle(sent(posted([file("u", "a.png", "image/png", big)])))

    assertEq(status(r), 413)
    assert(doc(r).size > 3000, "the size is the body's own and not the empty string's")

@test
async THE_LIMIT_IS_COUNTED_IN_BYTES_AND_NOT_IN_CHARACTERS()
    // **A limit is about what the socket carried.** Thirty characters of Japanese are ninety bytes,
    // and a limiter that counted characters would let three times what it promised through.
    val body = posted([field("title", repeat("日", 30))])
    val chars = len(fromBytes(body).value)
    val bytes = len(body)

    assert(bytes > chars, "ninety bytes of Japanese are thirty characters")

    val counting = made({ maxBytes: chars })
    val allowing = made({ maxBytes: bytes })

    assertEq(status(await counting.handle(sent(body))), 413)
    assertEq(status(await allowing.handle(sent(body))), 200)

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
