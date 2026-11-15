// `asset(body, type)` -- one fixed text at a content-hashed path, cached for a year.

import { api, asset, rateLimit, request, response } from "../sluice.sl"
import { status, header } from "./support.sl"
import { sha256 } from slate:crypto
import { base64urlEncode } from slate:url

val Css = "body { margin: 0; }\n.card { padding: 1rem; }\n"
val Path = "/assets/app.abc123.css"

served(body: string = Css) -> object =
    val app = api()

    app.get(Path, asset(body, "text/css; charset=utf-8"))

    app

get(app: object, headers: object = {}) = app.handle(request("GET", Path, { headers: headers }))

tagOf(body: string) -> string = "W/\"" + base64urlEncode(sha256(body)) + "\""

// A value whose type nobody wrote down, so a wrong argument reaches the call rather than the checker.
anything(v) = v

@test
async IT_ANSWERS_THE_BODY_WITH_ITS_TYPE()
    val r = await get(served())

    assertEq(status(r), 200)
    assertEq(response(r).body, Css)
    assertEq(header(r, "Content-Type"), "text/css; charset=utf-8")

@test
async IT_IS_CACHED_FOR_A_YEAR_AND_IMMUTABLE()
    assertEq(header(await get(served()), "Cache-Control"), "public, max-age=31536000, immutable")

@test
async THE_ETAG_IS_A_WEAK_DIGEST_OF_THE_BODY()
    // **Weak**, because `slate:http` compresses on the way out and the bytes on the wire are then not
    // one sequence.
    assertEq(header(await get(served()), "ETag"), tagOf(Css))

@test
async THE_ETAG_IS_THE_SAME_ON_EVERY_REQUEST_AND_FOR_EVERY_ROUTE_SERVING_THE_SAME_TEXT()
    val one = header(await get(served()), "ETag")

    assertEq(header(await get(served()), "ETag"), one)

    val app = served()

    assertEq(header(await get(app), "ETag"), header(await get(app), "ETag"))

@test
async A_DIFFERENT_BODY_IS_A_DIFFERENT_ETAG()
    val one = header(await get(served()), "ETag")
    val two = header(await get(served(Css + ".x { }")), "ETag")

    assert(one != two)

@test
async A_CLIENT_SENDING_THE_TAG_BACK_IS_ANSWERED_304_WITH_NO_BODY()
    val r = await get(served(), { "if-none-match": tagOf(Css) })

    assertEq(status(r), 304)
    assertEq(response(r).body, "")
    assertEq(header(r, "ETag"), tagOf(Css))
    assertEq(header(r, "Cache-Control"), "public, max-age=31536000, immutable")
    assertEq(header(r, "Content-Type"), null)

@test
async THE_COMPARISON_IS_WEAK_SO_A_STRONG_SPELLING_OF_THE_TAG_MATCHES_TOO()
    val strong = tagOf(Css)[2..]

    assertEq(status(await get(served(), { "if-none-match": strong })), 304)

@test
async A_LIST_NAMING_THE_TAG_ANYWHERE_IS_A_304()
    val said = "\"other\", " + tagOf(Css) + " , W/\"third\""

    assertEq(status(await get(served(), { "if-none-match": said })), 304)

@test
async A_STAR_IS_A_304()
    assertEq(status(await get(served(), { "if-none-match": "*" })), 304)

@test
async A_TAG_FOR_OTHER_TEXT_IS_THE_WHOLE_BODY_AGAIN()
    // What a browser holding the previous version of a sheet sends, were it ever to ask at the same
    // address: it is not this one, so it gets this one.
    val r = await get(served(), { "if-none-match": tagOf("an older sheet") })

    assertEq(status(r), 200)
    assertEq(response(r).body, Css)

@test
async AN_EMPTY_IF_NONE_MATCH_IS_NOT_A_MATCH()
    assertEq(status(await get(served(), { "if-none-match": "" })), 200)

@test
async AN_EMPTY_BODY_IS_SERVED_AS_ONE()
    // `lath`'s app sheet for a program with no bare stylesheets is `""`; serving it is harmless.
    val r = await get(served(""))

    assertEq(status(r), 200)
    assertEq(response(r).body, "")
    assertEq(header(r, "ETag"), tagOf(""))

@test
async EACH_ANSWER_HAS_HEADERS_OF_ITS_OWN()
    // A guard above writes into the response it is handed; a shared headers object would carry what
    // one request was told into the next.
    val h = asset(Css, "text/css")
    val first = h(request("GET", Path))

    first.headers["X-Written-By-A-Guard"] = "yes"

    assertEq(header(h(request("GET", Path)), "X-Written-By-A-Guard"), null)

@test
async IT_WORKS_UNDER_A_GUARD()
    val app = api()

    app.get(Path, rateLimit({ limit: 5, window: 1000, now: () -> 0, key: (req) -> "one" },
        asset(Css, "text/css")))

    val r = await get(app)

    assertEq(status(r), 200)
    assertEq(header(r, "Cache-Control"), "public, max-age=31536000, immutable")

@test
A_BODY_THAT_IS_NOT_TEXT_IS_REFUSED_WHEN_THE_ROUTE_IS_MADE()
    var said = null

    asset(anything(42), "text/css") catch e ->
        said = e.message

    assert(said != null, "a number is not an asset's body")

@test
A_TYPE_THAT_IS_NOT_TEXT_IS_REFUSED_WHEN_THE_ROUTE_IS_MADE()
    var said = null

    asset(Css, anything(null)) catch e ->
        said = e.message

    assert(said != null, "a media type is text")
