--- Column type factories, exposed as `Norm.types`. Each returns a column
--- descriptor consumed by `orm:define`. Available: `id, integer, bigint, string,
--- text, float, double, boolean, datetime, date, json` plus `raw` for raw SQL
--- defaults. Common options: `{ length, nullable, unique, primary, autoincrement, default }`.
--- ```lua
---     db:define("users", {
---         id         = Norm.types.id(),                              -- INT PK AUTO_INCREMENT
---         name       = Norm.types.string({ length = 64, nullable = false }),
---         email      = Norm.types.string({ length = 128, unique = true }),
---         coins      = Norm.types.integer({ default = 0 }),
---         admin      = Norm.types.boolean({ default = false }),
---         created_at = Norm.types.datetime({ default = Norm.types.raw("CURRENT_TIMESTAMP") }),
---     })
--- ```
---@class NormTypes
local types = {};

---@alias NormColumnKind
---| "id" | "integer" | "bigint" | "string" | "text" | "float"
---| "double" | "boolean" | "datetime" | "date" | "json"

---@class NormColumnOptions
---@field length? number Length for VARCHAR columns.
---@field nullable? boolean Defaults to true (false for primary keys).
---@field unique? boolean
---@field primary? boolean
---@field autoincrement? boolean
---@field default? any Literal value, or `Norm.types.raw(...)` for raw SQL.

---@class NormColumn: NormColumnOptions
---@field kind NormColumnKind
---@field name? string Set by `define()` from the schema key.

---@class NormRawDefault
---@field __raw string

---@param kind NormColumnKind
---@param options? NormColumnOptions
---@return NormColumn
local function make(kind, options)
    options = options or {};
    return {
        kind = kind,
        length = options.length,
        nullable = options.nullable ~= false and not options.primary,
        unique = options.unique == true,
        primary = options.primary == true,
        autoincrement = options.autoincrement == true,
        default = options.default,
    };
end

--- Mark a default value as raw SQL (not quoted), e.g. CURRENT_TIMESTAMP.
---@param sql string
---@return NormRawDefault
function types.raw(sql)
    return { __raw = sql };
end

--- Auto-increment integer primary key.
---@param options? NormColumnOptions
---@return NormColumn
function types.id(options)
    options = options or {};
    options.primary = true;
    options.autoincrement = options.autoincrement ~= false;
    options.nullable = false;
    return make("id", options);
end

--- Integer column (`INT` / SQLite `INTEGER`). Often a foreign-key column.
--- ```lua
---     coins   = Norm.types.integer({ default = 0 }),
---     user_id = Norm.types.integer({ nullable = false }), -- FK column
--- ```
---@param options? NormColumnOptions
---@return NormColumn
function types.integer(options) return make("integer", options); end

--- 64-bit integer (`BIGINT` / SQLite `INTEGER`). For values beyond 32 bits, e.g.
--- Discord/Steam IDs or epoch milliseconds.
--- ```lua
---     steam_id = Norm.types.bigint({ unique = true }),
--- ```
---@param options? NormColumnOptions
---@return NormColumn
function types.bigint(options) return make("bigint", options); end

--- Variable-length string (`VARCHAR(length)` / SQLite `TEXT`). Pass `length` for
--- the VARCHAR size on MySQL (ignored by SQLite, which is typeless).
--- ```lua
---     name  = Norm.types.string({ length = 64, nullable = false }),
---     email = Norm.types.string({ length = 128, unique = true }),
--- ```
---@param options? NormColumnOptions
---@return NormColumn
function types.string(options) return make("string", options); end

--- Unbounded text (`TEXT`). Use for large free-form content where `string`'s
--- length cap is impractical.
--- ```lua
---     bio = Norm.types.text(),
--- ```
---@param options? NormColumnOptions
---@return NormColumn
function types.text(options) return make("text", options); end

--- Single-precision floating point (`FLOAT` / SQLite `REAL`).
--- ```lua
---     ratio = Norm.types.float({ default = 1.0 }),
--- ```
---@param options? NormColumnOptions
---@return NormColumn
function types.float(options) return make("float", options); end

--- Double-precision floating point (`DOUBLE` / SQLite `REAL`). Prefer over
--- `float` when you need more precision (coordinates, money-as-float, etc.).
--- ```lua
---     pos_x = Norm.types.double({ default = 0 }),
--- ```
---@param options? NormColumnOptions
---@return NormColumn
function types.double(options) return make("double", options); end

--- Boolean, stored as `TINYINT(1)` on MySQL / `INTEGER` on SQLite. Norm converts
--- to/from a real Lua boolean automatically (true/false in, true/false out).
--- ```lua
---     admin = Norm.types.boolean({ default = false }),
--- ```
---@param options? NormColumnOptions
---@return NormColumn
function types.boolean(options) return make("boolean", options); end

--- Date + time (`DATETIME` / SQLite `TEXT`). Pair with `Norm.types.raw` to get a
--- DB-side default timestamp.
--- ```lua
---     created_at = Norm.types.datetime({ default = Norm.types.raw("CURRENT_TIMESTAMP") }),
--- ```
---@param options? NormColumnOptions
---@return NormColumn
function types.datetime(options) return make("datetime", options); end

--- Date only (`DATE` / SQLite `TEXT`).
--- ```lua
---     birthday = Norm.types.date(),
--- ```
---@param options? NormColumnOptions
---@return NormColumn
function types.date(options) return make("date", options); end

--- JSON column (`JSON` on MySQL / `TEXT` on SQLite). Norm stores/returns the raw
--- string; encode and decode it yourself. A raw default must be a valid literal.
--- ```lua
---     coordinates = Norm.types.json({ default = '{"x":0,"y":0,"z":0}' }),
--- ```
---@param options? NormColumnOptions
---@return NormColumn
function types.json(options) return make("json", options); end

-- ==========================================================================
-- Relations. Declared inside a schema alongside columns; `define` separates
-- them out. They create no SQL column, they describe how to load related rows.
-- ==========================================================================

---@class NormRelation
---@field __relation true
---@field kind "belongs_to"|"has_one"|"has_many"
---@field target string The related table name.
---@field key? string FK column (on this model for belongs_to, on the target otherwise).
---@field otherKey? string Referenced column (defaults to the relevant primary key).
---@field name? string Set by define() from the schema key.

---@class NormRelationOptions
---@field key? string
---@field otherKey? string

---@param kind string
---@param target string
---@param options? NormRelationOptions
---@return NormRelation
local function relation(kind, target, options)
    options = options or {};
    return {
        __relation = true,
        kind = kind,
        target = target,
        key = options.key,
        otherKey = options.otherKey,
    };
end

--- This record holds a foreign key pointing to one `target` row.
--- `key` defaults to `<relationName>_id`, `otherKey` to the target's primary key.
--- ```lua
---     db:define("posts", {
---         id      = Norm.types.id(),
---         user_id = Norm.types.integer(),
---         author  = Norm.types.belongsTo("users", { key = "user_id" }),
---     })
---     -- post:load("author"):await()  /  Post:query():include("author"):all():await()
--- ```
---@param target string
---@param options? NormRelationOptions
---@return NormRelation
function types.belongsTo(target, options) return relation("belongs_to", target, options); end

--- The `target` holds a foreign key pointing back to one of this model's rows.
--- `key` defaults to `<thisTableSingular>_id`, `otherKey` to this primary key.
---@param target string
---@param options? NormRelationOptions
---@return NormRelation
function types.hasOne(target, options) return relation("has_one", target, options); end

--- The `target` holds a foreign key pointing back to this model's rows (one-to-many).
--- `key` defaults to `<thisTableSingular>_id`, `otherKey` to this primary key.
--- ```lua
---     db:define("users", {
---         id    = Norm.types.id(),
---         posts = Norm.types.hasMany("posts", { key = "user_id" }),
---     })
---     -- user:load("posts"):await()  /  User:query():include("posts"):all():await()
--- ```
---@param target string
---@param options? NormRelationOptions
---@return NormRelation
function types.hasMany(target, options) return relation("has_many", target, options); end

return types;
