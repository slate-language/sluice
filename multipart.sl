// `multipart/form-data` -- the body a browser sends when a form has a file in it.
//
// **`slate:http` DOES NOT PARSE ONE AND SAYS SO**: "no multipart body, so a file upload is
// `serveStream` and the parsing is the program's". This is that parsing, written once here so that
// every program using this package does not write it again.
//
// **A MULTIPART BODY REACHES A HANDLER AS TEXT, WHICH BOUNDS WHAT THIS CAN READ.** `serve` reads a
// body whole and hands it over as a string, and a body that is not UTF-8 becomes the EMPTY string on
// the way -- so a `.png` posted to a route behind this guard arrives as nothing at all, with no
// header and no status saying so. **This guard is therefore for text uploads**: form fields, a CSV, a
// `.json`, a `.md`. A program taking arbitrary bytes wants `serveStream` and its own reader, which is
// what `slate:http` already told it.
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

// `multipart(options)` -- parse the body into `req.form`, which is `{ fields, files }`.
//
// **`fields` is an object and `files` is an array**, and the asymmetry is what the two are used for:
// a field is read by name and a repeated name keeps the last, which is the rule `slate:http` already
// applies to a repeated name in a query string; files are walked, may share one name, and each
// carries the name it was sent under.
//
// A file is `{ field, filename, type, content }`. **`type` is what the client claimed** and is worth
// exactly that -- a `.png` may say `text/plain` and a `.txt` may say anything at all.
//
// **The text of the whole body stays on `raw`**, as `body` does the same, for a handler checking a
// signature over what actually arrived.
//
// | option | |
// |---|---|
// | `limit` | the most a body may be, in bytes. `1048576` |
export multipartGuard(options: object) -> object =
    guard("multipart", (h) -> formed(options, h))

formed(options, h)
    val limit = options.limit ?? BodyBytes

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

        val raw = if has(req, "body") then req.body else ""

        // **Counted in BYTES and not characters**, a limit being about what the socket carried: a
        // string of a thousand characters may be three thousand bytes.
        val size = len(toBytes(raw))

        if size > limit
            return problemResponse(413, "Content Too Large",
                "the body is larger than this endpoint takes",
                { instance: req.path, limit: limit, size: size })

        val parsed = parseMultipart(raw, boundary)

        // **A body that will not parse is a 400 and not a fault**, which is the same division `body`
        // makes: text from a socket is a condition every server was always going to handle.
        if !parsed.ok
            return problemResponse(400, "Bad Request", "the multipart body could not be read",
                { instance: req.path, reason: parsed.error })

        await h(req with { form: parsed.value, raw: raw })

    inner

// A multipart body as `{ fields, files }`, or the reason it is not one.
//
// **A RESULT AND NOT A FAULT**, which is slate's own division and `parseJSON`'s shape exactly -- the
// caller of this is answering a client, and a malformed body is that client's mistake rather than
// this program's.
//
// **The body is split on the delimiter rather than scanned**, which is what makes this short: RFC
// 2046 requires the boundary to appear nowhere in any part's content, so the pieces between
// occurrences ARE the parts. The first piece is the preamble, every middle piece is a part, and the
// piece after the closing delimiter is an epilogue nobody reads.
export parseMultipart(raw: string, boundary: string) -> object
    val pieces = split(raw, "--" + boundary)

    if len(pieces) < 2 then return failed("the boundary does not appear in the body")

    var fields = {}
    var files = []
    var i = 1

    while i < len(pieces)
        val piece = pieces[i]

        // **`--` after the delimiter closes the body**, and everything after it is an epilogue.
        if startsWith(piece, "--") then return { ok: true, value: { fields: fields, files: files } }

        if !startsWith(piece, "\r\n") then return failed("a part does not begin with a line break")

        val part = piece[2..]

        // **The line break before the NEXT delimiter belongs to the delimiter and not to the
        // content**, which is the one place an off-by-two silently appends two characters to every
        // uploaded file.
        if !endsWith(part, "\r\n") then return failed("a part does not end with a line break")

        val whole = part[0..<(len(part) - 2)]
        val at = indexOf(whole, "\r\n\r\n")

        if at == null then return failed("a part has no blank line after its headers")

        val heads = headersOf(whole[0..<at])
        val content = whole[(at + 4)..]
        val said = parameters(heads["content-disposition"] ?? "")
        val name = said["name"] ?? null

        if name == null then return failed("a part has no name in its Content-Disposition")

        // **A filename is what makes a part a FILE**, which is RFC 7578's own rule rather than the
        // content type: a text field and a text file differ by having been chosen from a disk.
        if has(said, "filename")
            push(files, { field: name,
                          filename: said["filename"],
                          type: heads["content-type"] ?? "text/plain",
                          content: content })
        else
            fields[name] = content

        i = i + 1

    failed("the body ends without a closing boundary")

failed(why: string) -> object = { ok: false, error: why }

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

    while i <= len(value)
        // **The end of the text is a separator too**, which is what saves writing the last parameter
        // out again after the loop.
        val c = if i == len(value) then ";" else value[i..<(i + 1)]

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
