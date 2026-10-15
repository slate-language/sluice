// `flash` -- one-request messages over the session -- and `back`, which never leaves this host.

import { percentDecode } from slate:http

import { api, stack, session, flash, back, login, logout, json, memoryStore, request, response } from "../sluice.sl"
import { status, doc, header } from "./support.sl"

val Secret = "a secret nobody else has"

// The session cookie a browser would send back after this answer, given the one it had.
//
// **A cleared cookie is an empty value**, which is what a browser keeps nothing for.
jarAfter(reply, had: string | null) -> string | null
    var out = had

    for [k, v] in entries(response(reply).headers)
        if lower(k) == "set-cookie"
            for line in (if v is array then v else [v])
                if startsWith(line, "session=")
                    val one = line[0..<(indexOf(line, ";") ?? line.length)]
                    val value = percentDecode(one[8..<one.length], false)

                    out = if value == "" then null else value

    out

carrying(jar: string | null, options: object = {}) -> object =
    if jar == null then options else options with { cookies: { session: jar } }

// A form that refuses an empty title by flashing the reasons and what was typed and going back, and a
// page that shows whatever was flashed.
saved(req: object) -> object
    val form = parseJSON(req.body).value

    if form.title == ""
        req.flash.set("errors", ["a note wants a title"])
        req.flash.set("old", form)

        return back(req, "/notes/new")

    req.flash.set("notice", "saved")

    back(req, "/notes")

shown(req: object) -> object = json({ flash: req.flash.messages, session: req.session.value })

made(options: object = {}) -> object
    val app = api()
    val guards = stack([session(Secret, options), flash()])

    app.post("/notes", guards(saved))
    app.get("/notes/new", guards(shown))
    app.get("/notes", guards(shown))
    app.post("/in", guards((req) -> signedInWithNotice(req)))
    app.post("/out", guards((req) -> signedOutWithNotice(req)))

    app

signedInWithNotice(req: object) -> object
    login(req, { id: 7 })
    req.flash.set("notice", "welcome")

    json({ ok: true })

signedOutWithNotice(req: object) -> object
    logout(req)
    req.flash.set("notice", "bye")

    json({ ok: true })

@test
async A_MESSAGE_LASTS_EXACTLY_ONE_REQUEST()
    val app = made()
    val posted = await app.handle(request("POST", "/notes", { body: { title: "x" } }))
    var jar = jarAfter(posted, null)

    assertEq(status(posted), 303)
    assertEq(jar != null, true)

    // The next request sees it ...
    val first = await app.handle(request("GET", "/notes", carrying(jar)))

    assertEq(doc(first).flash, { notice: "saved" })
    jar = jarAfter(first, jar)

    // ... and the one after does not, though nothing read it out explicitly.
    val second = await app.handle(request("GET", "/notes", carrying(jar)))

    assertEq(doc(second).flash, {})

@test
async THE_REQUEST_THAT_SETS_A_MESSAGE_DOES_NOT_SEE_IT()
    val r = await made().handle(request("GET", "/notes"))

    assertEq(doc(r).flash, {})
    // And a request that set nothing and carried nothing writes no cookie at all.
    assertEq(header(r, "Set-Cookie"), null)

@test
async A_REFUSED_FORM_GOES_BACK_WITH_ITS_ERRORS_AND_WHAT_WAS_TYPED()
    val app = made()
    val headers = { Referer: "http://notes.example/notes/new?draft=1", Host: "notes.example" }
    val posted = await app.handle(request("POST", "/notes", { body: { title: "" }, headers: headers }))

    assertEq(status(posted), 303)
    assertEq(header(posted, "Location"), "/notes/new?draft=1")

    val shownAgain = await app.handle(request("GET", "/notes/new", carrying(jarAfter(posted, null))))

    assertEq(doc(shownAgain).flash, { errors: ["a note wants a title"], old: { title: "" } })

@test
async THE_HANDLER_SEES_THE_SESSION_WITHOUT_THE_MESSAGES()
    val app = made()
    val jar = jarAfter(await app.handle(request("POST", "/in")), null)
    val r = await app.handle(request("GET", "/notes", carrying(jar)))

    assertEq(doc(r).session, { user: 7 })
    assertEq(doc(r).flash, { notice: "welcome" })

@test
async A_MESSAGE_SET_WITH_A_LOGIN_OR_A_LOGOUT_STILL_ARRIVES()
    val app = made()
    var jar = jarAfter(await app.handle(request("POST", "/in")), null)

    jar = jarAfter(await app.handle(request("GET", "/notes", carrying(jar))), jar)

    val out = await app.handle(request("POST", "/out", carrying(jar)))

    jar = jarAfter(out, jar)

    val r = await app.handle(request("GET", "/notes", carrying(jar)))

    assertEq(doc(r).flash, { notice: "bye" })
    // Signed out: the session holds nothing but the message, and once that is read it holds nothing.
    assertEq(doc(r).session, null)
    assertEq(jarAfter(r, jar), null)

@test
async FLASH_WORKS_OVER_A_STORE_TOO()
    val app = made({ store: memoryStore() })
    var jar = jarAfter(await app.handle(request("POST", "/notes", { body: { title: "x" } })), null)
    val first = await app.handle(request("GET", "/notes", carrying(jar)))

    assertEq(doc(first).flash, { notice: "saved" })
    jar = jarAfter(first, jar)
    assertEq(doc(await app.handle(request("GET", "/notes", carrying(jar)))).flash, {})

@test
async FLASH_WITH_NO_SESSION_ABOVE_IT_IS_A_FAULT_AND_NOT_A_REFUSAL()
    var caught = []
    val app = api({ onFault: (e) -> push(caught, e) })

    app.get("/x", flash((req) -> json({})))

    assertEq(status(await app.handle(request("GET", "/x"))), 500)
    assertEq(caught.length, 1)

@test
async A_MESSAGE_ON_A_SESSION_THAT_IS_NOT_AN_OBJECT_IS_A_FAULT()
    var caught = []
    val app = api({ onFault: (e) -> push(caught, e) })

    app.get("/x", session(Secret, {}, flash((req) -> flashOverText(req))))

    assertEq(status(await app.handle(request("GET", "/x"))), 500)
    assertEq(caught.length, 1)

flashOverText(req: object) -> object
    req.session.set("just text")
    req.flash.set("notice", "x")

    json({})

// -- back ------------------------------------------------------------------------------------------

backFrom(headers: object) -> string | null = header(back(request("POST", "/notes", { headers: headers }), "/home"), "Location")

@test
BACK_IS_A_303_TO_THE_SAME_ORIGIN_REFERER_PATH_AND_QUERY()
    val r = back(request("POST", "/notes", { headers: { Referer: "https://Notes.Example:8443/a/b?c=1#top", Host: "notes.example:8443" } }), "/home")

    assertEq(status(r), 303)
    assertEq(header(r, "Location"), "/a/b?c=1")
    assertEq(backFrom({ Referer: "http://notes.example", Host: "notes.example" }), "/")

@test
BACK_NEVER_FOLLOWS_A_FOREIGN_REFERER()
    val host = "notes.example"

    assertEq(backFrom({ Referer: "https://evil.example/notes/new", Host: host }), "/home")
    assertEq(backFrom({ Referer: "https://notes.example.evil.example/x", Host: host }), "/home")
    assertEq(backFrom({ Referer: "https://notes.example@evil.example/x", Host: host }), "/home")
    assertEq(backFrom({ Referer: "https://notes.example:8443/x", Host: host }), "/home")
    assertEq(backFrom({ Referer: "//evil.example/x", Host: host }), "/home")
    assertEq(backFrom({ Referer: "javascript:alert(1)", Host: host }), "/home")

@test
BACK_REFUSES_A_PATH_A_BROWSER_WOULD_READ_AS_ANOTHER_HOST()
    assertEq(backFrom({ Referer: "http://notes.example//evil.example/x", Host: "notes.example" }), "/home")
    assertEq(backFrom({ Referer: "http://notes.example/\\evil.example/x", Host: "notes.example" }), "/home")

@test
BACK_WITH_NO_REFERER_OR_NO_HOST_GOES_TO_THE_FALLBACK()
    assertEq(backFrom({}), "/home")
    assertEq(backFrom({ Host: "notes.example" }), "/home")
    assertEq(backFrom({ Referer: "http://notes.example/a" }), "/home")
