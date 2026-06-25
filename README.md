# Norm

A small, **dependency-free** Lua ORM with **pluggable database adapters** and
**pluggable promise providers**. It runs anywhere — [nanos world](https://nanos.world),
[FiveM](https://fivem.net), or plain Lua — by keeping framework specifics out of the core.

> **Full documentation:** https://justgodwork.github.io/norm-docs/

- **Zero dependencies, one file.** Ships as a single self-contained bundle;
  [light-class](https://github.com/JustGodWork/light-class) is embedded at build time.
- **No runtime `require`, no cross-package import.** An internal module resolver makes
  it work even on FiveM (which has no native `require`).
- **Promises your way.** Every async operation returns a promise of *your* framework
  (nanos, FiveM, or the bundled one) through a small provider seam, with a uniform
  `promise:await()`.
- **Fully typed.** LuaCATS annotations throughout; `:await()` is narrowed to the
  resolved type (`User:find(1):await()` → `NormRecord?`).

```lua
local db = Norm.new({
    adapter = Norm.adapters.nanos.new({ engine = DatabaseEngine.SQLite, connection = "./game.db" }),
})

local User = db:define("users", {
    id    = Norm.types.id(),
    name  = Norm.types.string({ length = 64, nullable = false }),
    email = Norm.types.string({ length = 128, unique = true }),
    coins = Norm.types.integer({ default = 0 }),
}, { timestamps = true })

coroutine.wrap(function()
    db:sync():await()                                   -- create tables once at boot

    local user = User:create({ name = "John", email = "john@x.io" }):await()
    user:increment("coins", 250):await()

    local rich = User:where("coins", ">", 100):order("coins", "DESC"):all():await()
end)()
```

> An ORM talks to a database, so load Norm **server-side only** (nanos `Server/`,
> FiveM `server_script`) — never as a shared/client script.

## Install

Norm is one self-contained file: `dist/norm.lua` (or minified `dist/norm.min.lua`).
Loading it embeds light-class (global `class`), sets the global `Norm`, and returns it.

```lua
local Norm = dofile("dist/norm.lua")    -- plain Lua
local Norm = require "dist/norm.lua"    -- nanos (see the companion package `norm-nanos`)
```
```lua
server_script 'dist/norm.lua'           -- FiveM (fxmanifest.lua) — server only
```

## Two abstractions: adapter + promise provider

Frameworks ship different promise implementations and database APIs, so Norm splits
two concerns. The ORM **never builds a promise itself** — it asks the provider and
resolves it with the *already-transformed* value, so providers need no chaining.

| Concept | Answers | Built-ins |
|---|---|---|
| **Adapter** | *How do I talk to the database?* | `nanos`, `oxmysql`, or your own |
| **Promise provider** | *Which promise type does this framework use?* | `builtin`, `nanos`, `cfx`, or your own |

```lua
local db = Norm.new({
    adapter            = Norm.adapters.oxmysql.new(),   -- or .nanos.new{...}, or a custom adapter
    -- promise         = Norm.promise.cfx(),            -- optional; defaults to the adapter's, else builtin
    -- log             = true,                          -- log every executed statement
    -- foreignKeys     = "auto",                        -- "auto" | true | false
    -- json            = "auto",                        -- "auto" | a provider | false
    -- queue_until_ready = false,                       -- hold ops until the first sync()/migrate()
})
```

## Defining models

`db:define(name, schema, options?)` returns a model — your handle for everything.

```lua
local User = db:define("users", {
    id         = Norm.types.id(),                                 -- INT PK AUTO_INCREMENT
    name       = Norm.types.string({ length = 64, nullable = false }),
    email      = Norm.types.string({ length = 128, unique = true }),
    coins      = Norm.types.integer({ default = 0 }),
    bio        = Norm.types.text(),
    settings   = Norm.types.json(),                               -- Lua table <-> JSON string
    created_at = Norm.types.datetime({ default = Norm.types.raw("CURRENT_TIMESTAMP") }),
}, {
    timestamps   = true,          -- manage created_at / updated_at (Norm-side, UTC)
    soft_deletes = true,          -- add deleted_at; queries exclude trashed by default
    indexes      = { { columns = { "name" }, unique = false } },
})
```

**Types** (`Norm.types`): `id, integer, bigint, string, text, float, double, boolean,
datetime, date, json`, plus `raw(sql)` for raw SQL defaults. Common options:
`{ length, nullable, unique, index, primary, autoincrement, default }`.

**Define options**: `timestamps`, `soft_deletes`, `hooks`, `scopes`, `indexes`
(see the matching sections below).

## CRUD

```lua
local u = User:create({ name = "Zoe" }):await()       -- build + INSERT, id populated
local u = User:build({ name = "Zoe" })                -- unsaved; persist later with :save()
u.coins = u.coins + 10; u:save():await()              -- INSERT if new, UPDATE if loaded (dirty-tracked)
u:reload():await()                                    -- re-read columns from the DB
u:delete():await()                                    -- DELETE (soft delete if enabled)

local one  = User:find(1):await()                     -- by primary key -> record | nil
local byEm = User:find_by({ email = "a@b.c" }):await()
local all  = User:all():await()
local n    = User:count():await()

-- find-or-create family
User:find_or_create({ account_id = id }, { name = "Guest" }):await()
User:update_or_create({ account_id = id }, { last_seen = ts }):await()
User:find_or_new({ email = e }, { name = "Anon" }):await()        -- unsaved if missing

-- atomic upsert (race-safe; needs a UNIQUE/PK on the conflict columns)
User:upsert({ account_id = id, name = nick }, { conflict = { "account_id" } }):await()

-- bulk insert (one statement). { records = true } returns records with ids (RETURNING).
User:insert_many({ { name = "a" }, { name = "b" } }):await()

-- atomic counters (no read-modify-write)
User:where("id", id):increment("coins", 50):await()
u:decrement("lives"):await()                          -- on a record; updates u.lives too

-- raw escape hatch (values are always bound, never interpolated)
db:query("SELECT * FROM `users` WHERE `coins` > ?", { 100 }):await()
db:execute("DELETE FROM `users` WHERE `id` = ?", { 1 }):await()
```

## Query builder

Start with `User:query()` (or a shortcut like `User:where(...)`); terminals return a
promise.

```lua
local users = User:query()
    :where("coins", ">", 100):or_where("admin", true)
    :where_between("level", 10, 20)         -- + where_not_between
    :where_like("name", "John%")            -- + where_not_like, or_where_like
    :where_in("faction", { "red", "blue" }) -- + where_not_in, or_where_in
    :where_not("banned", true)
    :where_not_null("email")                -- + where_null, or_where_*
    :order("coins", "DESC"):limit(10):offset(20)
    :select("id", "name")                   -- or :omit("password"), or :select_raw("...")
    :all():await()
```

Terminals: `:all()`, `:first()`, `:count()`, `:sum/:avg/:min/:max(col)`, `:rows()`
(raw rows), `:update(data)`, `:delete()` / `:force_delete()`, `:increment/:decrement`,
`:paginate(page, per_page)`.

**Aggregations**: scalar (`:sum("coins")`) or grouped with
`:select_raw(...):group_by(...):having(expr, op, value):rows()`.

**Pagination**: `User:where(...):paginate(2, 20):await()` resolves
`{ data, total, page, per_page, last_page, from, to }`.

**Joins** (to filter/sort by a related column — for *loading* relations use `include`):

```lua
Post:join("users", "users.id", "posts.user_id")
    :where("users.admin", true):select_raw("`posts`.*"):all():await()
```

## Scopes

Reusable, named query fragments — usable as a starter (`User:active()`) and chainable
(`query:scope("active")`).

```lua
User:scope("active", function(q) q:where("active", true) end)
User:scope("older_than", function(q, age) q:where("age", ">", age) end)
User:active():scope("older_than", 18):all():await()
-- or declare them at define time: define(name, schema, { scopes = { active = fn } })
```

## Relations

Declared in the schema (they create no SQL column — they describe how to load related rows).

```lua
local User = db:define("users", {
    id      = Norm.types.id(),
    posts   = Norm.types.hasMany("posts", { key = "user_id" }),
    profile = Norm.types.hasOne("profiles", { key = "user_id" }),
    roles   = Norm.types.belongsToMany("roles"),          -- through pivot `role_user`
})
local Post = db:define("posts", {
    id      = Norm.types.id(),
    user_id = Norm.types.integer(),
    author  = Norm.types.belongsTo("users", { key = "user_id", onDelete = "CASCADE" }),
})
```

- **Lazy**: `record:load(name)` — one query, cached on `record[name]`.
- **Eager**: `query:include(...)` — one batched query per relation level, no N+1.
  Nest with a dotted path and pass per-relation options:
  ```lua
  User:query():include("posts.comments"):all():await()           -- nested
  User:query():include("posts", function(q)                      -- with options
      q:where("published", true):order("created_at", "DESC"):limit(5)
       :include("comments", function(c) c:order("created_at") end)
  end):all():await()
  ```
- **Filter / count by relation** (correlated subqueries, no join):
  ```lua
  User:where_has("posts", function(q) q:where("published", true) end):all():await()
  User:where_doesnt_have("posts"):all():await()
  User:with_count("posts"):all():await()                         -- users[i].posts_count
  ```
- **Many-to-many mutation**: `record:attach(name, ids, pivot?)`,
  `record:detach(name, ids?)`, `record:sync_pivot(name, ids)`.

### Foreign keys

`sync()` emits real `FOREIGN KEY` constraints from `belongsTo` relations (with
`onDelete`/`onUpdate`), creating tables in dependency order. Controlled by the
`foreignKeys` option: `"auto"` (default — emits on MySQL, skips on SQLite with a
one-time warning), `true`, or `false`. SQLite only enforces FKs with `PRAGMA
foreign_keys = ON` (per-connection), which Norm can't guarantee across a pool.

## JSON columns

A `json` column is (de)serialised automatically — assign a Lua table, read one back.
The provider is resolved from the `json` option → the adapter's default →
auto-detection (Nanos `JSON`, then a Lua/FiveM `json`), else a raw passthrough.

```lua
local Char = db:define("characters", { id = Norm.types.id(), pos = Norm.types.json() })
local c = Char:create({ pos = { x = 1, y = 2 } }):await()   -- stored as '{"x":1,"y":2}'
print(Char:find(c.id):await().pos.x)                        -- 1 (decoded to a table)
```

Providers (`Norm.json`): `nanos(JSON)`, `rapidjson(json)`, `raw()`, `define{ encode,
decode }`. Pass one as the `json` option, or `json = false` to keep raw strings.

## Timestamps & dirty tracking

`{ timestamps = true }` adds `created_at` / `updated_at`, set **by Norm** in UTC (so
they behave identically on SQLite and MySQL). Every loaded record is snapshotted, so
`:save()` writes only the columns you changed — and a no-op save issues no query.

## Soft deletes

`{ soft_deletes = true }` adds a nullable `deleted_at`; queries (and eager/lazy
relations) exclude soft-deleted rows by default.

```lua
post:delete():await()        -- sets deleted_at instead of removing the row
post:restore():await()       -- clears it; post:trashed() reports the state
post:force_delete():await()  -- real DELETE
Post:with_trashed():all():await()   -- include them   (Post:only_trashed() for just them)
```

## Lifecycle hooks

Per-model, **synchronous**. A `before_*` handler that raises cancels the operation
(the promise rejects, nothing is written); a `before_save` mutation is persisted.

```lua
User:before_save(function(u) assert(u.email, "email required") end)
User:after_create(function(u) print("welcome #" .. u.id) end)
```

Events: `before/after_create`, `before/after_update`, `before/after_save`,
`before/after_delete`, `after_find`. Also via `define(name, schema, { hooks = {...} })`.

## Transactions

`db:transaction(fn)` runs `fn` atomically (COMMIT on return, ROLLBACK on raise);
operations inside are transactional automatically. It **throws** if the adapter can't
run transactions — check `db:supports_transactions()` to branch.

```lua
db:transaction(function()
    from:save():await()
    to:save():await()
end):await()
```

## Migrations

`sync()` only creates missing tables; `migrate` evolves an existing schema. Each
migration runs once (tracked in `norm_migrations`), in order.

```lua
db:migrate({
    { id = "2026_06_25_add_last_seen", up = function(m)
        m:add_column("players", "last_seen", Norm.types.datetime())
        m:add_index("players", "idx_players_account", { "account_id" }, { unique = true })
    end },
}):await()
```

Builder: `add_column`, `drop_column`, `rename_column`, `add_index`, `drop_index`,
`drop_table`, `raw(sql)`. Run `sync()` (creates tables, marks the ORM ready) *before*
`migrate()` — only `sync()` flips readiness.

## Queueing until ready

With `queue_until_ready = true`, data operations are held until the first successful
`sync()` (which creates your tables), then replayed. `db:is_ready()` reports the state.
Handy when boot code may run queries before `sync()` (or before oxmysql has connected).

## Promises & `await`

Norm returns the provider's **native** promise, but every provider exposes a uniform
`promise:await()` (call it inside a coroutine / async block).

| Provider | Chain | Await |
|---|---|---|
| `Norm.promise.builtin()` | `:next`, `:catch` | `p:await()` |
| `Norm.promise.nanos(Promise)` | `:Then`, `:Catch` | `p:await()` (or `:Await()`) |
| `Norm.promise.cfx(promise?)` | `:next` | `p:await()` (or `Citizen.Await(p)`) |

## Custom adapter

Extend `Norm.Adapter`, or pass any **duck-typed table** with the same methods:

```lua
local MyAdapter = Norm.class.extend("MyAdapter", Norm.Adapter)
function MyAdapter:__init(o) Norm.Adapter.__init(self, o); self.conn = o.connection end
function MyAdapter:get_dialect_name() return "mysql" end            -- or "sqlite"
function MyAdapter:default_provider() return Norm.promise.cfx() end -- or nil
function MyAdapter:raw_query(q, params, cb)   self.conn:select(q, params, function(rows) cb(nil, rows) end) end
function MyAdapter:raw_execute(q, params, cb) self.conn:exec(q, params, function(r) cb(nil, { affectedRows = r.n, insertId = r.id }) end) end
-- optional: supports_returning(), supports_transactions() + transaction(body, finish)
```

## Custom promise provider

```lua
local provider = Norm.promise.define({
    name = "myframework",
    new = function(executor) ... end,  -- executor(resolve, reject) -> promise
    resolve = function(value) ... end,
    reject = function(reason) ... end,
})
-- or, for any class whose constructor is `Class(executor)`:
local provider = Norm.promise.from_class(MyPromise)
```

## Build & test

```bash
lua build.lua                 # any Lua 5.4 -> regenerates dist/norm.lua + dist/norm.min.lua
pip install lupa              # tests run real Lua 5.4 through lupa
python tests/run.py           # the self-test suite
python tests/run_nanos.py     # the nanos adapter end-to-end with async/await
```

## Project layout

```
norm/
  class/light-class.lua   the class system (git submodule, build-time source)
  build.lua               bundles light-class + src/ -> dist/norm[.min].lua
  dist/norm.lua           generated self-contained bundle (commit it)
  src/                    modular sources (orm, model, query, sql, dialect, types,
                          promise, json, adapter, adapters/{nanos,oxmysql}, init)
  tests/                  self-test + nanos simulation (Lua 5.4 via lupa)
```

## License

[MIT](LICENSE) © 2026 JustGodWork.
