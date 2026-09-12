# Ability Workshop

A static, browser-only creator for Mary ability packages (`.mary`), deployed to
**https://rao-studios.github.io/MaryOS/**.

Teach it an application, or open any of the seventeen packages Mary ships with,
edit it, and download a file the Swift client accepts as-is. No backend, no
accounts, nothing uploaded.

## Why this can work at all

`.mary` is a single JSON document, and Swift's encoder is reproducible in the
browser. Both halves are verified in CI against every shipped package:

| Check | Result |
|---|---|
| Re-serialize `Abilities/*.mary` byte-for-byte | 17/17 |
| Reproduce each `integrity.digest` (SHA-256) | 17/17 |

The quirks that matter are 2-space indent, `" : "` between key and value,
recursively sorted keys, an empty array as `[\n\n<indent>]`, unescaped slashes,
and a trailing newline. `crypto.subtle` covers the hashing.

## The one bet the code makes

**The in-memory document is the parsed JSON tree, never a hydrated typed
model.** Several Swift encoders deliberately omit a field when it is false or
empty — `requirements.resolvesApplication`, `modelParameter.spokenSpan`,
`execution.realizationPolicy`, `semantics.targetParameters` — precisely so that
adding a field did not invalidate every sealed digest at once. Any code that
parsed into typed objects and re-emitted them would materialize those defaults
and break all seventeen digests in one commit.

So edits are path writes over the raw tree (`src/model/path.ts`), untouched
subtrees keep their identity, and `test/path.test.ts` writes every scalar in
every shipped package back over itself and asserts the bytes never move.

## Layout

```
src/model/     codec, validator, factory, paths   — pure, no DOM
src/state/     document, history, origin
src/ui/        start screen, steps, review, issue drawer
src/styles/    vendored Liquid Platinum tokens
scripts/       sync Abilities/*.mary into public/templates/
test/          round-trip, digest, validator, anti-hydration
```

`src/model/validate.ts` mirrors the Swift validator's `{severity, code, path,
message}` shape, so an error read here reads identically in the app. It
deliberately stops short of graph-level rules (cross-package uniqueness,
dependency cycles), which need the whole installed set; Mary re-validates on
import.

## Working on it

```sh
npm install
npm run dev      # syncs templates, then serves
npm test         # round-trip + digest + validator + anti-hydration
npm run build    # typecheck + production build into dist/
```

To check a file this tool produced against the real client:

```sh
cp ~/Downloads/<id>.mary ../Abilities/
swift build --product mary-package-probe && .build/debug/mary-package-probe check
rm ../Abilities/<id>.mary
```

## Re-vendoring the design tokens

`src/styles/tokens.css` is a snapshot of MaryUI's Liquid Platinum tokens
(Apache-2.0), vendored because CI cannot see that sibling checkout:

```sh
node ../../MaryUI/web/scripts/build-tokens.mjs --out "$(pwd)/src/styles"
```

Keep only `tokens.css` afterwards and re-apply its attribution header.
