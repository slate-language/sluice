{
    name: "sluice",
    version: "0.5.1",

    // The whole package is one door. `route.sl`, `problem.sl`, `guards.sl` and `testing.sl` are
    // reached from here and are deliberately not listed under `modules` -- what a consumer imports
    // is the framework, and how a path is matched is this package's own business.
    //
    // slate's `export` is a prefix on a declaration and there is no re-export form, so everything
    // public is DECLARED in `sluice.sl` and the files behind it hold the working parts. The
    // declaration is what carries the annotation, and an annotation is the only check a consumer's
    // call gets.
    main: "sluice.sl",
    // **Both dependencies are DEV dependencies**, resolved only while sluice is the project being
    // built: a consumer of `sluice` installs neither, so nothing it puts on a machine carries a
    // logger or a database client it did not ask for.
    //
    // `logger` is what `tests/logging.sl` and `examples/notes.sl` use -- the guard hands a sink a
    // record and that package takes one, and the test is the only thing that says the two really
    // fit. `pg` is what `examples/tasks/` is written over, and `tests/tasks.sl` and
    // `tests/postgres.sl` are what keep it honest.
    devDependencies: {
        logger: { git: "github.com/slate-language/logger", version: "0.2.0" },
        pg: { git: "github.com/slate-language/pg", version: "0.5.0" },
    },
}
