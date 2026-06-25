--- Base Adapter class. An adapter is *how the ORM talks to a database*.
--- It only has to expose a small raw, callback-based API; the ORM wraps those
--- callbacks into promises via the configured provider.
---
--- Subclasses (or any duck-typed table) must implement:
---   raw_query(query, params, callback)    -- SELECT; callback(err, rows)
---   raw_execute(query, params, callback)  -- writes; callback(err, { affectedRows, insertId })
--- and may override get_dialect_name() and default_provider().
local class = class;
local dialect = require("dialect");

---@class NormExecResult Result of a write statement.
---@field affectedRows? number
---@field insertId? any

---@alias NormQueryCallback fun(err: any, rows: table[])
---@alias NormExecuteCallback fun(err: any, result: NormExecResult)

---@class NormAdapterOptions
---@field dialect? "mysql"|"sqlite" Overrides the adapter's default dialect.
---@field [string] any Adapter-specific options.

---@class NormAdapter: LightClass
---@field options NormAdapterOptions
---@field protected _dialect_name string
---@overload fun(options?: NormAdapterOptions): NormAdapter
local NormAdapter = class.new("NormAdapter");

---@private
---@param options? NormAdapterOptions
function NormAdapter:__init(options)
    self.options = options or {};
    self._dialect_name = self.options.dialect or self:get_dialect_name();
end

--- The dialect name this adapter speaks. Override per engine.
---@return "mysql"|"sqlite"
function NormAdapter:get_dialect_name()
    return "mysql";
end

--- Resolved dialect object.
---@return NormDialect
function NormAdapter:get_dialect()
    return dialect.get(self._dialect_name);
end

--- Optional: the promise provider native to this adapter's framework.
---@return NormPromiseProvider|nil
function NormAdapter:default_provider()
    return nil;
end

--- Optional: the JSON provider native to this adapter's framework, used to
--- (de)serialise `json` columns. Returning nil lets the ORM auto-detect one.
---@return NormJsonProvider|nil
function NormAdapter:default_json_provider()
    return nil;
end

--- Optional: whether this adapter can run an interactive transaction on a pinned
--- connection. Defaults to false → `db:transaction(...)` throws on this adapter.
--- An adapter that returns true MUST implement `transaction(body, finish)`:
---   * the adapter opens the transaction, then calls `body(tx_query, tx_execute)`
---     where `tx_query(q, p, cb)` / `tx_execute(q, p, cb)` run on the transaction;
---   * `body` returns `true` to COMMIT, `false` to ROLL BACK;
---   * the adapter commits/rolls back, then calls `finish(err)` (err nil on commit).
---@return boolean
function NormAdapter:supports_transactions()
    return false;
end

--- Optional: whether this adapter's engine supports `INSERT ... RETURNING <col>`
--- (SQLite >= 3.35, PostgreSQL). When true, the ORM reads a new row's
--- auto-increment id atomically from the INSERT itself, instead of a separate
--- `LAST_INSERT_ID()` / `last_insert_rowid()` query — which is connection-scoped
--- and therefore unreliable across a connection pool. Defaults to false.
---@return boolean
function NormAdapter:supports_returning()
    return false;
end

--- Run a SELECT. Must be overridden.
---@param query string
---@param params any[]
---@param callback NormQueryCallback
function NormAdapter:raw_query(query, params, callback)
    error(("[norm] adapter '%s' does not implement raw_query"):format(class.name(self)));
end

--- Run a write statement. Must be overridden.
---@param query string
---@param params any[]
---@param callback NormExecuteCallback
function NormAdapter:raw_execute(query, params, callback)
    error(("[norm] adapter '%s' does not implement raw_execute"):format(class.name(self)));
end

return NormAdapter;
