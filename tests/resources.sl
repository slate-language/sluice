// `resource` -- a controller's actions at their conventional methods and paths, and nothing it lacks.

import { api, stack, json, guardOf, request } from "../sluice.sl"
import { status, doc } from "./support.sl"

// Each action answers its own name and the id it was given, so a test can say which one ran.
said(action: string) -> function = (req) -> json({ action: action, id: req.params.id ?? null })

val Everything = { index: said("index"),
                   create: said("create"),
                   store: said("store"),
                   show: said("show"),
                   edit: said("edit"),
                   update: said("update"),
                   destroy: said("destroy") }

// A guard that writes its own name onto the answer's body, so a test can see it ran.
marking(label: string) -> object = guardOf(label, (h) -> (req) -> json({ marked: label }))

async ran(app: object, method: string, path: string) -> string | null
    val r = await app.handle(request(method, path))

    if status(r) != 200 then null else doc(r).action

rowsOf(app: object) -> array = map(app.routes(), (r) -> r.method + " " + r.path + " " + string(r.name))

@test
async EVERY_ACTION_IS_AT_ITS_CONVENTIONAL_METHOD_AND_PATH()
    val app = api()

    app.resource("/notes", Everything)

    assertEq(await ran(app, "GET", "/notes"), "index")
    assertEq(await ran(app, "GET", "/notes/create"), "create")
    assertEq(await ran(app, "POST", "/notes"), "store")
    assertEq(await ran(app, "GET", "/notes/7"), "show")
    assertEq(await ran(app, "GET", "/notes/7/edit"), "edit")
    assertEq(await ran(app, "PUT", "/notes/7"), "update")
    assertEq(await ran(app, "PATCH", "/notes/7"), "update")
    assertEq(await ran(app, "DELETE", "/notes/7"), "destroy")
    assertEq(doc(await app.handle(request("GET", "/notes/7"))).id, "7")

@test
EVERY_ACTION_IS_NAMED_AND_PATCH_SHARES_PUT_S_NAME_BY_HAVING_NONE()
    val app = api()

    app.resource("/notes", Everything)

    assertEq(rowsOf(app), ["GET /notes notes.index",
                           "GET /notes/create notes.create",
                           "POST /notes notes.store",
                           "GET /notes/:id notes.show",
                           "GET /notes/:id/edit notes.edit",
                           "PUT /notes/:id notes.update",
                           "PATCH /notes/:id null",
                           "DELETE /notes/:id notes.destroy"])

@test
async ONLY_THE_ACTIONS_THE_CONTROLLER_HAS_ARE_ADDED()
    val app = api()

    app.resource("/notes", { index: said("index"), show: said("show") })

    assertEq(app.routes().length, 2)
    assertEq(await ran(app, "GET", "/notes/7"), "show")
    // A path that is there under another method is a 405, which is what a missing action should be.
    assertEq(status(await app.handle(request("DELETE", "/notes/7"))), 405)

@test
ONLY_AND_EXCEPT_PICK_THE_ACTIONS()
    val one = api()
    val other = api()

    one.resource("/notes", Everything, { only: ["index", "show"] })
    other.resource("/notes", Everything, { except: ["create", "edit", "destroy"] })

    assertEq(map(one.routes(), (r) -> r.name), ["notes.index", "notes.show"])
    assertEq(map(other.routes(), (r) -> r.name), ["notes.index", "notes.store", "notes.show", "notes.update", null])

@test
API_ONLY_LEAVES_OUT_THE_TWO_FORM_ACTIONS()
    val app = api()

    app.resource("/notes", Everything, { apiOnly: true })

    assertEq(contains(map(app.routes(), (r) -> r.name), "notes.create"), false)
    assertEq(contains(map(app.routes(), (r) -> r.name), "notes.edit"), false)
    assertEq(app.routes().length, 6)

@test
async THE_PARAMETER_AND_THE_NAME_MAY_BE_CHANGED()
    val app = api()

    app.resource("/notes", { show: (req) -> json({ slug: req.params.slug }) }, { param: "slug", name: "posts" })

    assertEq(app.routes()[0].path, "/notes/:slug")
    assertEq(app.routes()[0].name, "posts.show")
    assertEq(doc(await app.handle(request("GET", "/notes/hello"))).slug, "hello")

@test
async GUARDS_FOR_ALL_AND_PER_ACTION_GO_OUTSIDE_THE_ACTION_S_OWN()
    val app = api()
    val own = stack([guardOf("own", (h) -> h)])(said("store"))

    app.resource("/notes", { index: said("index"), store: own, destroy: said("destroy") },
        { guards: { "*": [guardOf("all", (h) -> h)], destroy: [marking("refuse")] } })

    assertEq(map(app.routes(), (r) -> r.guards), [["all"], ["all", "own"], ["all", "refuse"]])
    assertEq(doc(await app.handle(request("DELETE", "/notes/7"))).marked, "refuse")
    assertEq(await ran(app, "GET", "/notes"), "index")

@test
A_GUARD_LIST_FOR_A_RESOURCE_GOES_ON_EVERY_ACTION()
    val app = api()

    app.resource("/notes", { index: said("index"), show: said("show") }, { guards: [guardOf("all", (h) -> h)] })

    assertEq(map(app.routes(), (r) -> r.guards), [["all"], ["all"]])

@test
async A_RESOURCE_IN_A_GROUP_TAKES_THE_PREFIX_AND_THE_NAME_PREFIX()
    val app = api()

    app.group("/api", [], (r) -> r.resource("/notes", { show: said("show") }), { name: "api" })

    assertEq(app.routes()[0].name, "api.notes.show")
    assertEq(app.url("api.notes.show", { id: 3 }), "/api/notes/3")
    assertEq(await ran(app, "GET", "/api/notes/3"), "show")

@test
A_RESOURCE_THAT_ADDS_NOTHING_IS_A_FAULT()
    // A controller with none of the seven names would otherwise be a quiet 404 everywhere.
    assertFaults(() -> api().resource("/notes", { list: said("index") }), "added no routes")

// -- a class instance as the controller ------------------------------------------------------------

// Every method reads and writes `self`, so a method value captured at registration -- which has lost
// its receiver -- would fault or answer the wrong thing.
class Notes
    var served = 0
    var label = "notes"

    index(self, req)
        self.served += 1
        json({ action: "index", id: null, label: self.label, served: self.served })

    show(self, req)
        self.served += 1
        json({ action: "show", id: req.params.id, label: self.label, served: self.served })

// Only two of the seven actions.
class ReadOnly
    var label = "read-only"

    index(self, req) = json({ action: "index", id: null, label: self.label })
    destroy(self, req) = json({ action: "destroy", id: req.params.id, label: self.label })

// Inherits `index` and `show` from `Notes`, adds `destroy`, and overrides `show`.
class Archive from Notes
    destroy(self, req) = json({ action: "destroy", id: req.params.id, label: self.label })

    show(self, req) = json({ action: "show", id: req.params.id, label: "archive " + self.label })

async said_by(app: object, method: string, path: string) -> object
    doc(await app.handle(request(method, path)))

@test
async A_CLASS_CONTROLLER_S_METHODS_RUN_WITH_THE_INSTANCE_AS_THEIR_RECEIVER()
    val app = api()
    val notes = Notes()

    app.resource("/notes", notes)

    assertEq(map(app.routes(), (r) -> r.method + " " + r.path), ["GET /notes", "GET /notes/:id"])

    val first = await said_by(app, "GET", "/notes")
    val second = await said_by(app, "GET", "/notes/7")

    assertEq(first.action, "index")
    assertEq(first.label, "notes")
    assertEq(first.served, 1)
    assertEq(second.id, "7")
    // The state the first request changed is the state the second one reads.
    assertEq(second.served, 2)
    assertEq(notes.served, 2)

@test
async A_CLASS_CONTROLLER_IS_LOOKED_UP_WHEN_THE_REQUEST_ARRIVES()
    val app = api()
    val notes = Notes()

    app.resource("/notes", notes)
    notes.label = "renamed"

    assertEq((await said_by(app, "GET", "/notes")).label, "renamed")

@test
async A_CLASS_WITH_ONLY_SOME_ACTIONS_GETS_ROUTES_FOR_THOSE()
    val app = api()

    app.resource("/notes", ReadOnly())

    assertEq(map(app.routes(), (r) -> r.name), ["notes.index", "notes.destroy"])
    assertEq((await said_by(app, "DELETE", "/notes/3")).label, "read-only")
    assertEq(status(await app.handle(request("GET", "/notes/3"))), 405)
    assertEq(status(await app.handle(request("POST", "/notes"))), 405)

@test
async A_SUBCLASS_INHERITS_AN_ACTION_AND_MAY_OVERRIDE_ONE()
    val app = api()

    val archive = Archive()

    // Construction is inherited plainly: an Archive, which is also a Notes, with the base state set.
    assertEq(archive is Archive, true)
    assertEq(archive is Notes, true)
    assertEq(archive.served, 0)
    assertEq(archive.label, "notes")

    app.resource("/notes", archive)

    assertEq(map(app.routes(), (r) -> r.name), ["notes.index", "notes.show", "notes.destroy"])
    // Inherited, and reading the instance's own state through the base class's method.
    assertEq((await said_by(app, "GET", "/notes")).served, 1)
    // Overridden.
    assertEq((await said_by(app, "GET", "/notes/4")).label, "archive notes")
    assertEq((await said_by(app, "DELETE", "/notes/4")).action, "destroy")

@test
async ONLY_AND_EXCEPT_NARROW_A_CLASS_CONTROLLER_TOO()
    val app = api()

    app.resource("/notes", Archive(), { except: ["destroy"] })

    assertEq(map(app.routes(), (r) -> r.name), ["notes.index", "notes.show"])

@test
A_CLASS_CONTROLLER_THAT_LACKS_AN_ONLY_ACTION_IS_A_FAULT()
    assertFaults(() -> api().resource("/notes", ReadOnly(), { only: ["show"] }), "has no `show`")

@test
A_CLASS_WITH_NONE_OF_THE_SEVEN_NAMES_ADDS_NOTHING_AND_IS_A_FAULT()
    assertFaults(() -> api().resource("/notes", Gadget()), "added no routes")

class Gadget
    var size = 1

    spin(self, req) = json({})

@test
async A_PLAIN_OBJECT_CONTROLLER_STILL_WORKS_WITHOUT_A_RECEIVER()
    val app = api()

    app.resource("/notes", { show: said("show") })

    assertEq(await ran(app, "GET", "/notes/7"), "show")

@test
MISTAKES_IN_THE_OPTIONS_ARE_FAULTS()
    val app = api()

    assertFaults(() -> app.resource("/notes", Everything, { only: ["index"], except: ["show"] }), "or `except`")
    assertFaults(() -> app.resource("/notes", Everything, { only: ["list"] }), "`list`, which is not one of")
    assertFaults(() -> app.resource("/notes", { index: said("index") }, { only: ["show"] }), "has no `show`")
    assertFaults(() -> app.resource("/notes", Everything, { guards: { remove: [] } }), "`remove`")
    assertFaults(() -> app.resource("/:id", Everything), "needs a `name`")
