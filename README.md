# Norm

A small, **dependency-free** Lua ORM with **pluggable database adapters** and
**pluggable promise providers**. It is built to run anywhere — [nanos world](https://nanos.world),
[FiveM](https://fivem.net), or plain Lua — by keeping framework specifics out of
the core.

- **Zero dependencies, one file.** Ships as a single self-contained bundle;
  [light-class](https://github.com/JustGodWork/light-class) is embedded at build time.
- **No runtime `require`.** The whole ORM is a single built file with an internal
  module resolver — so it works on FiveM, which has no native `require`.
- **No cross-package import.** Nothing relies on `require`/`exports`, so it
  works everywhere.
- **Promises everywhere, your way.** Every async operation returns a promise of
  *your* framework (nanos, FiveM, or the bundled one) through a small provider
  seam, with a uniform `promise:await()`.
- **Typed.** Full LuaCATS annotations; `:await()` is narrowed to the resolved
  type (`User:find(1):await()` → `NormRecord?`).

```lua
local db = Norm.new({
    adapter = Norm.adapters.nanos.new({ engine = DatabaseEngine.SQLite, connection = "./game.db" }),
    log = true,
})

local User = db:define("users", {
    id    = Norm.types.id(),
    name  = Norm.types.string({ length = 64, nullable = false }),
    email = Norm.types.string({ length = 128, unique = true }),
    coins = Norm.types.integer({ default = 0 }),
})

coroutine.wrap(function()
    db:sync():await() -- CREATE TABLE for every model

    local user = User:create({ name = "John", email = "john@x.io" }):await()
    user.coins = 250
    user:save():await()

    local rich = User:where("coins", ">", 100):order("coins", "DESC"):all():await()
end)()
```

## Install

Norm is distributed as **one self-contained file**: `dist/norm.lua` (or the
minified `dist/norm.min.lua`). Loading it embeds light-class (sets the global
`class`), sets the global `Norm`, and returns it.

```lua
-- plain Lua
local Norm = dofile("dist/norm.lua")
```

```lua
-- nanos (server-side — see the companion package `norm-nanos`):
local Norm = require "dist/norm.lua"
```

```lua
-- FiveM (fxmanifest.lua) — the ORM is server-only:
server_script 'dist/norm.lua' -- exposes the global `Norm`
```

> An ORM talks to a database, so load it **server-side only** (nanos `Server/`,
> FiveM `server_script`), never as a shared/client script.

## Why two abstractions?

Different frameworks ship **different promise implementations** (FiveM has its own
[promise](https://github.com/citizenfx/fivem/blob/master/data/shared/citizen/scripting/lua/deferred.lua), nanos uses [nanos-promise](https://github.com/JustGodWork/nanos-promise)).
Norm separates two concerns:

| Concept | Answers | Built-ins |
|---|---|---|
| **Adapter** | *How do I talk to the database?* | `nanos`, `oxmysql`, or your own |
| **Promise provider** | *Which promise type does this framework use?* | `builtin`, `nanos`, `cfx`, or your own |

The ORM **never builds a promise itself** — it asks the provider, and resolves it
with the *already-transformed* value. That means providers need no chaining
support, which is why even a minimal promise library works.

## API

### `Norm.new({ adapter, promise?, log?, logger? })` → ORM
`promise` defaults to the adapter's `default_provider()`, then to the built-in
provider. Passing a raw promise *class* (e.g. `promise = Promise`) auto-wraps it.

### Column types — `Norm.types`
`id, integer, bigint, string, text, float, double, boolean, datetime, date, json`,
plus `raw(sql)` for raw SQL defaults (e.g. `default = Norm.types.raw("CURRENT_TIMESTAMP")`).
Options: `{ length, nullable, unique, primary, autoincrement, default }`.

### Model (class-level) — from `db:define(name, schema)`
`:sync()`, `:create(data)`, `:build(data)`, `:find(pk)`, `:find_by({...})`,
`:all()`, `:count()`, `:query()`, and the shortcuts `:where/:order/:limit/:select`.

### Query builder (chainable)
`select`, `where`, `or_where`, `where_in`, `where_null`, `where_not_null`,
`order`, `limit`, `offset` → terminals `all`, `first`, `count`, `update(data)`,
`delete` (each returns a promise).

### Record (row-level)
`:save()` (INSERT or UPDATE), `:delete()`, `:reload()`, `:to_table()`. Columns are
plain fields: `record.id`, `record.name`, …

### Raw
`db:query(sql, params?)` → rows, `db:execute(sql, params?)` → `{ affectedRows, insertId }`.

> All data values are bound as `?` parameters — Norm never interpolates your data
> into SQL, so there is no injection from values you pass.

## Promises & `await`

Norm returns the provider's **native** promise, so the chaining methods depend on
it — but **every provider exposes a uniform `promise:await()`** (the bundled
promise has it natively; the nanos/cfx providers add it on top of `:Await` /
`Citizen.Await`). `:await()` must be called inside a coroutine / async block.

| Provider | Chain | Await |
|---|---|---|
| `Norm.promise.builtin()` | `:next`, `:catch` | `p:await()` |
| `Norm.promise.nanos(Promise)` | `:Then`, `:Catch` | `p:await()` (or native `:Await()`) |
| `Norm.promise.cfx(promise?)` | `:next` | `p:await()` (or `Citizen.Await(p)`) |

## Custom adapter

Extend `Norm.Adapter`, or pass any **duck-typed table** implementing the same
methods (the class system is optional):

```lua
local MyAdapter = Norm.class.extend("MyAdapter", Norm.Adapter)
function MyAdapter:__init(o) Norm.Adapter.__init(self, o); self.conn = o.connection end
function MyAdapter:get_dialect_name() return "mysql" end            -- or "sqlite"
function MyAdapter:default_provider() return Norm.promise.cfx() end -- or nil
function MyAdapter:raw_query(q, params, cb)   self.conn:select(q, params, function(rows) cb(nil, rows) end) end
function MyAdapter:raw_execute(q, params, cb) self.conn:exec(q, params, function(r) cb(nil, { affectedRows = r.n, insertId = r.id }) end) end
```

## Custom promise provider

```lua
local provider = Norm.promise.define({
    name    = "myframework",
    new     = function(executor) ... end,  -- executor(resolve, reject) -> promise
    resolve = function(value) ... end,
    reject  = function(reason) ... end,
})
-- or, for any class whose constructor is `Class(executor)`:
local provider = Norm.promise.from_class(MyPromise)
```

## Project layout

```
norm/
  class/light-class.lua  the class system (git submodule, build-time source)
  build.lua              bundles light-class + src/ -> dist/norm[.min].lua
  dist/norm.lua          generated self-contained bundle (commit it)
  dist/norm.min.lua      minified build of the same bundle
  src/                   modular sources (orm, model, query, sql, dialect,
                         types, promise, adapter, adapters/{nanos,oxmysql})
  tests/                 self-test + nanos simulation (Lua 5.4 via lupa)
  LICENSE
```

## Build & test

```bash
lua build.lua                 # any Lua 5.4 -> regenerates dist/norm.lua + dist/norm.min.lua

pip install lupa              # tests run real Lua 5.4 through lupa
python tests/run.py           # SQL, promises, records, await, portability, duck-typed adapter
python tests/run_nanos.py     # the nanos adapter end-to-end with async/await
```

## Notes

- The **nanos adapter** uses `Database(engine, connection_string, pool_size)` and
  passes query parameters as varargs; `insertId` is read via `last_insert_rowid()`
  (SQLite) / `LAST_INSERT_ID()` (MySQL) after an INSERT.
- The **oxmysql adapter** waits for the resource to be `started` and for
  `:awaitConnection()` before reporting ready.
- The SQL builder targets MySQL and SQLite. Add a dialect in `src/dialect.lua`
  for other engines.

## Roadmap

- Relations (`belongs_to` / `has_many`, joins, eager-loading) — not implemented yet.

## License

[MIT](LICENSE) © 2026 JustGodWork.
