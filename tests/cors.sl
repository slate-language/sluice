// `cors(options)` -- the headers a browser needs, and the preflight the handler never sees.

import { api, cors, request } from "../sluice.sl"
import { status, header } from "./support.sl"

made(options: object) -> object
    val app = api()

    app.any("/notes", cors(options, (req) -> "the notes"))

    app

from(origin: string) -> object = request("GET", "/notes", { headers: { Origin: origin } })

preflight(origin: string, method: string) -> object =
    request("OPTIONS", "/notes", { headers: { Origin: origin,
                                              "Access-Control-Request-Method": method,
                                              "Access-Control-Request-Headers": "content-type" } })

@test
async A_STAR_ORIGIN_IS_ALLOWED_OUTRIGHT_AND_NEEDS_NO_Vary()
    val r = await made({}).handle(from("https://example.com"))

    assertEq(header(r, "Access-Control-Allow-Origin"), "*")
    assertEq(header(r, "Vary"), null)

@test
async AN_ALLOWED_ORIGIN_IS_ECHOED_AND_THE_ANSWER_VARIES_BY_IT()
    // Without `Vary: Origin` a cache hands one site's answer to another.
    val app = made({ origin: ["https://a.example", "https://b.example"] })
    val r = await app.handle(from("https://b.example"))

    assertEq(header(r, "Access-Control-Allow-Origin"), "https://b.example")
    assertEq(header(r, "Vary"), "Origin")

@test
async AN_ORIGIN_THAT_IS_NOT_ALLOWED_IS_SIMPLY_NOT_TOLD_SO()
    // The request is still answered -- CORS is the browser's rule and not the server's. What is
    // withheld is the header that would let the page read the answer.
    val app = made({ origin: "https://a.example" })
    val r = await app.handle(from("https://evil.example"))

    assertEq(header(r, "Access-Control-Allow-Origin"), null)
    assertEq(header(r, "Vary"), "Origin")
    assertEq(status(r), 200)

@test
async THE_HANDLERS_OWN_ANSWER_IS_KEPT_UNDER_THE_HEADERS_ADDED_TO_IT()
    val app = api()

    app.get("/notes", cors({}, (req) -> { status: 201, headers: { "X-Kind": "note" }, body: "made" }))

    val r = await app.handle(from("https://example.com"))

    assertEq(status(r), 201)
    assertEq(header(r, "X-Kind"), "note")
    assertEq(header(r, "Access-Control-Allow-Origin"), "*")

@test
async A_PREFLIGHT_IS_ANSWERED_HERE_AND_THE_HANDLER_NEVER_RUNS()
    var ran = false

    watching(req)
        ran = true

        "the notes"

    val app = api()

    app.any("/notes", cors({ maxAge: 600 }, watching))

    val r = await app.handle(preflight("https://example.com", "POST"))

    assertEq(status(r), 204)
    assertEq(header(r, "Access-Control-Max-Age"), "600")
    assertEq(header(r, "Access-Control-Allow-Methods"), "GET, HEAD, PUT, PATCH, POST, DELETE, OPTIONS")
    assert(!ran, "a preflight is a question about the endpoint, not a request of it")

@test
async A_PREFLIGHT_ECHOES_THE_HEADERS_ASKED_ABOUT_WHERE_NONE_WERE_CONFIGURED()
    val plain = await made({}).handle(preflight("https://example.com", "POST"))
    val app = made({ headers: ["content-type", "x-token"], methods: ["GET", "POST"] })
    val said = await app.handle(preflight("https://example.com", "POST"))

    assertEq(header(plain, "Access-Control-Allow-Headers"), "content-type")
    assertEq(header(said, "Access-Control-Allow-Headers"), "content-type, x-token")
    assertEq(header(said, "Access-Control-Allow-Methods"), "GET, POST")

@test
async credentials_AND_expose_ARE_WRITTEN_WHERE_THEY_WERE_ASKED_FOR()
    val app = made({ origin: "https://a.example", credentials: true, expose: ["X-Total"] })
    val r = await app.handle(from("https://a.example"))

    assertEq(header(r, "Access-Control-Allow-Credentials"), "true")
    assertEq(header(r, "Access-Control-Expose-Headers"), "X-Total")

@test
async AN_OPTIONS_REQUEST_THAT_IS_NOT_A_PREFLIGHT_REACHES_THE_HANDLER()
    // `OPTIONS` without `Access-Control-Request-Method` is an ordinary request about the resource.
    //
    // **The answer is an envelope because a guard added a header to it**, which is what a guard
    // that reads or writes the response necessarily does to a bare string.
    val app = made({})
    val r = await app.handle(request("OPTIONS", "/notes"))

    assertEq(status(r), 200)
    assertEq(r.body, "the notes")
