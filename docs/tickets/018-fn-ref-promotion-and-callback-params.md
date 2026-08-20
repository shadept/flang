# 018 — `fn(T)` → `fn(&T)` promotion, and `&T` callback parameters in the stdlib

Status: design note (user-raised, 2026-08-20) — to be taken up next session
together with a general stdlib improvements pass.

## Observation

References in FLang indicate **mutability intent, not efficiency**: aggregates
already cross call boundaries by pointer under the hood (callee copies for
value semantics), so `fn(T)` and `fn(&T)` compile to nearly the same ABI —
modulo the callee-side copy that gives `T` its value semantics.

Two consequences worth designing for:

1. **Promotion rule.** It should be safe to promote a `fn(T)` value into a
   `fn(&T)` slot (the wrapper reads through the reference and passes a copy —
   or, ABI-wise, is often the identity), but never the other way around
   (`fn(&T)` in a `fn(T)` slot could observe/mutate the caller's value where a
   copy was promised). This also softens the sharp edge found today: `deinit`
   overloads take `&T`, so combinators typed `fn(T)` can't accept them (see
   known-issues "Overloaded Functions Can't Be Used As First-Class Values" —
   the `self.__cwd.map(deinit)` ICE).

2. **Stdlib callback parameters should be `&T` where a copy is not wanted.**
   `List.map` / `filter` / `find` / `any` / `all`, the iterator combinators,
   `sort`'s comparator, etc. currently type their callbacks `fn(T) ...`,
   which *reads* like it copies every element into the lambda — and does copy
   at the semantic level. Where C++ would take `const T&`, FLang should take
   `&T`: whenever a copy is not warranted or should be avoided, the parameter
   is explicitly `&T`.

## Scope for the follow-up session

- Decide the promotion rule (`fn(T)` usable where `fn(&T)` is expected) and
  its interaction with overload resolution for first-class function names
  (context-directed pick by expected type).
- Sweep stdlib combinator signatures toward `&T` callbacks (`List`, `iter`,
  `sort`, `Option.map`?) and measure the fallout on the corpus.
- Fold in the deferred stdlib additions/improvements queue.
