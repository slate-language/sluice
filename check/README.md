# The hand-run checks

Two claims this package makes cannot be a `@test`, because **a test that passed would have ended the
run**. They live here instead, they are run by hand, and each one says what it should do.

**They are not under `tests/` because `slate test tests` walks every `.sl` file below it** and would
run these as part of the suite — which is the very thing they cannot be.

## `faults.sl` — a defect stops the program

```
slate check/faults.sl
```

**It must print the 500 the client was given and then die with `the note store is not there`,
exiting 1.** That is the default `handle` takes when no `onFault` was configured: the client is told,
and the fault is put back on the loop where nothing awaits it — which is what `slate:http` does for a
handler of its own, and what makes a defect a defect rather than a log line.

`tests/faults.sl` covers everything else about it, and every test there passes `onFault` for exactly
this reason.

## `exhaustive.sl` — a failure with no HTTP answer is refused before the program runs

```
slate check/exhaustive.sl
```

**It must NOT run.** The expected output is:

```
error: this match does not cover every Failure -- `Taken` is unmatched. Add an arm for it, or `_` for whatever is left
```

That refusal is the central claim of `api.failures`: the mapping is annotated `(f: Failure) -> …`,
slate checks a `match` over an annotated subject against the whole of the data type, and so every
failure an application can produce provably has an answer. Nothing in express or axum can check it,
and a suite cannot check it either — a program that will not compile has no tests to run.
