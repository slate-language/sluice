// A failure the application can produce and has no HTTP answer for.
//
// **Run by hand — see `check/README.md`. It must NOT compile**, and the complaint must name `Taken`.

import { api } from "../sluice.sl"

data Failure
    NoSuchNote(id)
    Taken(title)

// The arm for `Taken` is missing, and that is the whole of this file.
answer(f: Failure) = f match
    NoSuchNote(id) -> { status: 404, body: "no note " + id }

val app = api()

app.failures(Failure, answer)

app.post("/notes", (req) -> Taken("first"))

print("this line is never reached")
