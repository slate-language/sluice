// `multipart/form-data` -- the body a browser sends when a form has a file in it.
//
// **`slate:http` DOES NOT PARSE ONE AND SAYS SO**: "no multipart body, so a file upload is
// `serveStream` and the parsing is the program's". This is that parsing, written once here so that
// every program using this package does not write it again.
//
// **IT IS PARSED OVER `req.bytes`, WHICH IS WHY IT TAKES A `.png`.** A multipart body is not text: a
// part's headers are ASCII and its content is whatever was chosen from a disk. `req.body` is the
// UTF-8 reading of the whole thing, and slate 0.0.29 and earlier had only that -- so a body carrying
// one binary part decoded to nothing at all and arrived here as the empty string, with no header, no
// status and no fault saying so. slate 0.0.30 puts the bytes on the request beside the text, and this
// parser reads those; the floor moved for it.
//
// **A LARGE UPLOAD STILL WANTS `serveStream`**, which is `slate:http`'s own advice and this parser's
// too: `serve` holds the whole body in memory before a handler sees any of it, and finding the
// delimiters is a scan of every byte of it. `maxBytes` is where that stops.
//
// **RFC 7578 is the specification and RFC 2046 s5.1 is the grammar.** What is implemented is what a
// browser and `curl` actually send: a boundary, parts with headers and a blank line, `Content-
// Disposition: form-data` naming each one, and a closing delimiter. What is deliberately not is
// `filename*` (RFC 5987 encoding), nested `multipart/mixed` parts, and `Content-Transfer-Encoding` --
// none of which a browser has sent this century.

import { guard, headerOf } from "./guards.sl"
import { problemResponse } from "./response.sl"

// The most a body may be before this refuses to read it. **A megabyte, which is `slate:http`'s own
// ceiling on a body it reads whole**, so the default here refuses nothing the server would have
// delivered.
val BodyBytes = 1048576

// The three byte sequences this parser is written against: `--`, CRLF, and the blank line that ends
// a part's headers.
val Dashes = [45, 45]
val Break = [13, 10]
val Blank = [13, 10, 13, 10]

// `multipart(options)` -- parse the body into `req.form`, which is `{ fields, files }`.
//
// **`fields` is an object and `files` is an array**, and the asymmetry is what the two are used for:
// a field is read by name and a repeated name keeps the last, which is the rule `slate:http` already
// applies to a repeated name in a query string; files are walked, may share one name, and each
// carries the name it was sent under.
//
// **A FIELD IS TEXT AND A FILE IS BYTES, AND NEITHER IS SOMETIMES THE OTHER.** A form field comes
// from a control a person typed into, so `fields` is name to string and a field whose bytes are not
// text is a `400` rather than a silence. A file is `{ field, filename, type, bytes, text }`: `bytes`
// is exactly what arrived and `text()` answers it decoded, or `null` where it is not text.
//
// **`text` IS A FUNCTION AND `bytes` IS NOT SOMETIMES A STRING**, which is the same decision
// `slate:http` made about a repeated query name: a member whose TYPE depends on what a client sent is
// a program that works until somebody uploads a PNG. So the shape is one shape, the decode is asked
// for rather than done to every upload, and a handler that wants the text of a `.csv` writes
// `f.text()`.
//
// **`type` is what the client claimed** and is worth exactly that -- a `.png` may say `text/plain`
// and a `.txt` may say anything at all. `accept` is where a program says what it will take.
//
// **The raw body is `req.bytes`, which the server put there.** This guard used to copy it onto
// `req.raw`; it no longer does, that being a copy of something every request already carries.
//
// | option | |
// |---|---|
// | `maxBytes` | the most a body may be, in bytes. `1048576`; over it is a `413` |
// | `accept` | a predicate on a file, answering whether this endpoint takes it; a `415` where not |
export multipartGuard(options: object) -> object =
    guard("multipart", (h) -> formed(options, h))

formed(options, h)
    val ceiling = options.maxBytes ?? BodyBytes
    val accept = options.accept ?? null

    async inner(req)
        val kind = headerOf(req, "content-type") ?? ""

        // **415 and not 400**, which is the distinction RFC 9110 draws: the body may be perfectly
        // well formed and simply not be the media type this endpoint takes.
        if !startsWith(lower(kind), "multipart/form-data")
            return problemResponse(415, "Unsupported Media Type",
                "this endpoint takes a multipart/form-data body",
                { instance: req.path, received: if kind == "" then "nothing" else kind })

        val boundary = parameters(kind)["boundary"] ?? null

        if boundary == null || boundary == ""
            return problemResponse(400, "Bad Request",
                "the Content-Type names no multipart boundary", { instance: req.path })

        val raw = bytesOf(req)

        // **The count is the byte array's own length**, which is what the socket carried. It was
        // `toBytes(req.body).length` while this read text, and that answered `0` for exactly the
        // bodies a limit is there for: a binary upload decoded to nothing, so nothing was over the
        // limit and the ceiling held only for text.
        val size = raw.length

        if size > ceiling
            return problemResponse(413, "Content Too Large",
                "the body is larger than this endpoint takes",
                { instance: req.path, limit: ceiling, size: size })

        val parsed = parseMultipart(raw, boundary)

        // **A body that will not parse is a 400 and not a fault**, which is the same division `body`
        // makes: text from a socket is a condition every server was always going to handle.
        if !parsed.ok
            return problemResponse(400, "Bad Request", "the multipart body could not be read",
                { instance: req.path, reason: parsed.error })

        val refused = if accept == null then null else firstRefused(accept, parsed.value.files)

        // **415 for a part the endpoint does not take**, for the reason the whole-body 415 above is
        // one: the upload is a perfectly good upload and simply not what this endpoint accepts.
        // **The whole body is parsed before this is asked**, the predicate being given the bytes so
        // that it can look at them rather than at what the client claimed.
        //
        // **THE FILE'S MEDIA TYPE IS `mediaType` AND NOT `type`, BECAUSE `type` IS THE DOCUMENT'S
        // OWN.** RFC 9457's `type` is a URI naming the KIND OF PROBLEM -- `about:blank` where there
        // is none -- so an extension member of that name does not sit beside it, it REPLACES it, and
        // a refusal of a `.png` went out saying `"type": "image/png"`. Anything reading the document
        // by the specification then has a problem type of `image/png`, which is not a URI it can
        // look up and not what this refusal is about. The file's own members keep the names the file
        // has them under everywhere else -- `field` and `filename` -- and only the one that
        // collides is renamed.
        if refused != null
            return problemResponse(415, "Unsupported Media Type",
                "this endpoint does not take this upload",
                { instance: req.path, field: refused.field, filename: refused.filename,
                  mediaType: refused.type })

        await h(req with { form: parsed.value })

    inner

// The first file the predicate refuses, or `null` where it takes all of them.
//
// **The predicate is not awaited.** It is given the bytes and the names, which is everything there is
// to decide on, and a check that had to go and ask something else is a guard of the program's own
// rather than an option on this one.
firstRefused(accept, files: array)
    for f in files
        if !accept(f) then return f

    null

// The body as bytes. **`req.bytes` is what the server read**, and the two fallbacks are for a request
// built by hand -- `testing.sl`'s `request` fills both, and a handler called with an object naming
// only `body` still gets the text it meant.
bytesOf(req) -> array
    if has(req, "bytes") then return req.bytes
    if has(req, "body") then return toBytes(req.body)

    []

// A multipart body as `{ fields, files }`, or the reason it is not one.
//
// **A RESULT AND NOT A FAULT**, which is slate's own division and `parseJSON`'s shape exactly -- the
// caller of this is answering a client, and a malformed body is that client's mistake rather than
// this program's.
//
// **The body is CUT AT THE DELIMITERS rather than scanned for a grammar**, which is what makes this
// short: RFC 2046 requires the boundary to appear nowhere in any part's content, so the pieces
// between occurrences ARE the parts. The first piece is the preamble, every middle piece is a part,
// and the piece after the closing delimiter is an epilogue nobody reads.
export parseMultipart(raw: array, boundary: string) -> object
    val delimiter = toBytes("--" + boundary)
    val skips = skipTable(delimiter)
    val blanks = skipTable(Blank)
    val width = delimiter.length

    var at = findBytes(raw, delimiter, skips, 0)

    if at == null then return failed("the boundary does not appear in the body")

    var fields = {}
    var files = []

    while at != null
        val next = findBytes(raw, delimiter, skips, at + width)
        val piece = slice(raw, at + width, next ?? raw.length)

        // **`--` after the delimiter closes the body**, and everything after it is an epilogue.
        if opens(piece, Dashes) then return { ok: true, value: { fields: fields, files: files } }

        if !opens(piece, Break) then return failed("a part does not begin with a line break")

        val part = slice(piece, 2)

        // **The line break before the NEXT delimiter belongs to the delimiter and not to the
        // content**, which is the one place an off-by-two silently appends two characters to every
        // uploaded file.
        if !closes(part, Break) then return failed("a part does not end with a line break")

        val whole = slice(part, 0, part.length - 2)
        val blank = findBytes(whole, Blank, blanks, 0)

        if blank == null then return failed("a part has no blank line after its headers")

        val read = textOf(slice(whole, 0, blank))

        // **A part's headers are ASCII or the part is not a part**, so bytes that will not decode
        // there are a malformed body rather than an upload of anything.
        if read == null then return failed("a part's headers are not text")

        val heads = headersOf(read)
        val content = slice(whole, blank + 4)
        val said = parameters(heads["content-disposition"] ?? "")
        val name = said["name"] ?? null

        if name == null then return failed("a part has no name in its Content-Disposition")

        // **A filename is what makes a part a FILE**, which is RFC 7578's own rule rather than the
        // content type: a text field and a text file differ by having been chosen from a disk.
        if has(said, "filename")
            push(files, fileOf(name, said["filename"], heads["content-type"] ?? "text/plain", content))
        else
            val value = textOf(content)

            // **A field is text, and one that is not is said rather than swallowed.** A control a
            // person typed into carries the form's charset, which RFC 7578 leaves as the document's
            // and every browser writes as UTF-8; bytes that are not that are not a field.
            if value == null then return failed("a field is not text: " + name)

            fields[name] = value

        at = next

    failed("the body ends without a closing boundary")

// One file of a form. **`text` closes over the bytes rather than decoding them now**, so an endpoint
// taking a hundred images does not decode a hundred images to find out that none of them is text.
fileOf(field: string, filename: string, kind: string, content: array) -> object
    text() -> string | null = textOf(content)

    { field: field, filename: filename, type: kind, bytes: content, text: text }

// Bytes as the text they are, or `null` where they are not text.
textOf(bs: array) -> string | null
    val read = fromBytes(bs)

    if read.ok then read.value else null

failed(why: string) -> object = { ok: false, error: why }

opens(bs: array, prefix: array) -> boolean
    if bs.length < prefix.length then return false

    var i = 0

    while i < prefix.length
        if bs[i] != prefix[i] then return false

        i = i + 1

    true

closes(bs: array, suffix: array) -> boolean
    if bs.length < suffix.length then return false

    var i = 0

    while i < suffix.length
        if bs[bs.length - suffix.length + i] != suffix[i] then return false

        i = i + 1

    true

// -- finding a delimiter ---------------------------------------------------------------------------

// **THE SEARCH SKIPS, AND A MEGABYTE IS WHY.** slate reaches bytes one at a time -- `indexOf` over an
// array takes no position to start from, so a search that used it would have to `slice` what is left
// on every miss, which is a copy of the rest of the body per occurrence of a single byte -- and a
// comparison written per byte costs about two microseconds under the interpreter, which is two
// seconds for the megabyte this guard will read. Boyer-Moore-Horspool compares the LAST byte of the
// delimiter first and, where that byte is nowhere in the delimiter, moves the whole delimiter's width
// on: a delimiter is `--` and a boundary a browser wrote, so that is forty-odd bytes a step through
// content that is not a delimiter, and the megabyte is tens of thousands of comparisons rather than a
// million.

// How far the search may move on having landed on each byte. **The last byte of the delimiter is left
// out of the table on purpose**: it is the one being compared, and giving it a skip of its own would
// stop the search advancing at all where it matches and the rest does not.
skipTable(needle: array) -> array
    val width = needle.length
    var table = []
    var i = 0

    while i < 256
        push(table, width)

        i = i + 1

    var j = 0

    while j < width - 1
        table[needle[j]] = width - 1 - j

        j = j + 1

    table

// Where `needle` next appears in `hay` at or after `from`, or `null`.
findBytes(hay: array, needle: array, skips: array, from: integer) -> integer | null
    val width = needle.length
    val end = hay.length - width

    if width == 0 then return null

    var i = from

    while i <= end
        var j = width - 1

        while j >= 0 && hay[i + j] == needle[j]
            j = j - 1

        if j < 0 then return i

        i = i + skips[hay[i + width - 1]]

    null

// -- headers and their parameters ------------------------------------------------------------------

// A part's headers, by lower-cased name. **A header this parser does not know about is kept**, a part
// being allowed to carry any of them.
headersOf(text: string) -> object
    var out = {}

    if text == "" then return out

    for line in split(text, "\r\n")
        val at = indexOf(line, ":")

        if at != null then out[lower(trim(line[0..<at]))] = trim(line[(at + 1)..])

    out

// The parameters of a header value -- everything after the first `;`, by lower-cased name.
//
// **Quotes are tracked rather than stripped afterwards**, because a filename is allowed to contain a
// semicolon and splitting on `;` first would cut `filename="a;b.txt"` in half. That is the whole
// reason this is a scanner and not two `split`s.
export parameters(value: string) -> object
    var out = {}
    var name = ""
    var got = ""
    var quoted = false
    var closed = false
    var seen = false
    var i = 0

    while i <= value.length
        // **The end of the text is a separator too**, which is what saves writing the last parameter
        // out again after the loop.
        val c = if i == value.length then ";" else value[i..<(i + 1)]

        if quoted
            if c == "\""
                quoted = false
                closed = true
            else
                got = got + c
        elif c == ";"
            // **A word with no `=` is not a parameter**, which is what leaves `multipart/form-data`
            // and `form-data` -- the media type and the disposition themselves -- out of the answer.
            if seen && trim(name) != "" then out[lower(trim(name))] = got

            name = ""
            got = ""
            seen = false
            closed = false
        elif c == "=" && !seen
            seen = true
        elif !seen
            name = name + c
        elif c == "\"" && got == "" && !closed
            quoted = true
        elif !closed && (c != " " || got != "")
            // The space between `=` and the value is the syntax's; one inside the value is not.
            got = got + c

        i = i + 1

    out
