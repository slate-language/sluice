// `stack` -- the order guards run in, when they are composed, and what `api.routes()` says they are.

import { api, stack, body, bearer, logger, guardOf, request } from "../sluice.sl"
import { status } from "./support.sl"

type NewNote = { title: string }

// A guard that writes its name down on the way in and on the way out. **This is what makes the
// order observable**: `a(b(h))` enters `a` first and leaves it last.
recorder(name: string, into: array) -> object
    wrap(h)
        inner(req)
            push(into, "enter " + name)

            val reply = h(req)

            push(into, "leave " + name)

            reply

        inner

    guardOf(name, wrap)

@test
async stack_a_b_IS_a_OF_b_OF_THE_HANDLER()
    var seen = []
    val app = api()

    app.get("/x", stack([recorder("a", seen), recorder("b", seen)])((req) -> "done"))

    assertEq(await app.handle(request("GET", "/x")), "done")
    assertEq(seen, ["enter a", "enter b", "leave b", "leave a"])

@test
async THE_GUARDS_ARE_COMPOSED_ONCE_AND_NOT_WALKED_PER_REQUEST()
    // The composition happens where the stack is built. Two requests through one route run the
    // guards twice and compose them no more times than the route was declared.
    var built = 0
    var seen = []

    counting(h)
        built = built + 1

        h

    val app = api()
    val once = stack([guardOf("counting", counting), recorder("a", seen)])

    app.get("/x", once((req) -> "done"))

    assertEq(built, 1)

    await app.handle(request("GET", "/x"))
    await app.handle(request("GET", "/x"))

    assertEq(built, 1)
    assertEq(len(seen), 4)

@test
async A_GUARD_THAT_REFUSES_STOPS_THE_ONES_UNDER_IT()
    // There is no `next` to decline to call. Not calling the handler is the refusal, and everything
    // the refusing guard wraps simply never runs.
    var seen = []
    val app = api()

    app.post("/notes", stack([body(NewNote), recorder("inner", seen)])((req) -> "made"))

    assertEq(status(await app.handle(request("POST", "/notes", { body: { title: 4 } }))), 400)
    assertEq(seen, [])

    assertEq(await app.handle(request("POST", "/notes", { body: { title: "a" } })), "made")
    assertEq(seen, ["enter inner", "leave inner"])

@test
async routes_SAYS_THE_METHOD_THE_PATH_AND_WHAT_EACH_ONE_RUNS()
    val app = api()

    handler(req) = "the notes"

    app.get("/notes/:id", handler)
    app.post("/notes", stack([logger(print), bearer((t) -> { ok: true, value: t }), body(NewNote)])(handler))
    app.any("/health", handler)

    val listed = app.routes()

    assertEq(len(listed), 3)
    assertEq(listed[0], { method: "GET", path: "/notes/:id", guards: [], handler: handler })
    assertEq(listed[1].method, "POST")
    assertEq(listed[1].path, "/notes")
    assertEq(listed[1].guards, ["logger", "bearer", "body(NewNote)"])
    assertEq(listed[1].handler, handler)
    assertEq(listed[2].method, "ANY")

@test
async A_GUARD_WRITTEN_THE_SHORT_WAY_IS_LISTED_THE_SAME_AS_A_STACK_OF_ONE()
    // `body(NewNote, h)` and `stack([body(NewNote)])(h)` differ in how they read and in nothing else.
    handler(req) = "the notes"

    val short = api()
    val long = api()

    short.post("/notes", body(NewNote, handler))
    long.post("/notes", stack([body(NewNote)])(handler))

    assertEq(short.routes()[0], long.routes()[0])

@test
async GUARDS_NESTED_THE_SHORT_WAY_KEEP_THEIR_WHOLE_LIST()
    handler(req) = "the notes"

    val app = api()

    app.post("/notes", logger(print, bearer((t) -> { ok: true, value: t }, body(NewNote, handler))))

    assertEq(app.routes()[0].guards, ["logger", "bearer", "body(NewNote)"])
    assertEq(app.routes()[0].handler, handler)

@test
async A_STACK_OF_NOTHING_IS_THE_HANDLER()
    val app = api()

    app.get("/x", stack([])((req) -> "done"))

    assertEq(await app.handle(request("GET", "/x")), "done")
    assertEq(app.routes()[0].guards, [])
