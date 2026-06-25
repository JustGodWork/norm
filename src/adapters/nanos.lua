--- Adapter for the Nanos World `Database` object.
--- https://docs.nanos.world/docs/scripting-reference/classes/database
local class = class;
local utils = require("utils");
local NormAdapter = require("adapter");
local promise = require("promise");
local jsonlib = require("json");

---@class NormNanosAdapterOptions: NormAdapterOptions
---@field engine? integer A `DatabaseEngine` enum value (required unless `database` is given).
---@field connection? string Connection string / file path.
---@field pool_size? integer Number of pooled connections (nanos default if omitted).
---@field database? table An already-built nanos `Database` instance to reuse.
---@field returning? boolean Force `INSERT ... RETURNING` on/off. Default: auto — on for SQLite/PostgreSQL, auto-detected for MariaDB >= 10.5 (off for real MySQL).

---@class NormNanosAdapter: NormAdapter
---@field database table The underlying nanos `Database`.
---@field private _resolved_dialect "mysql"|"sqlite"
---@field private _supports_returning boolean
---@overload fun(options?: NormNanosAdapterOptions): NormNanosAdapter
local NormNanosAdapter = class.extend("NormNanosAdapter", NormAdapter);

--- Map a Nanos DatabaseEngine to a dialect name.
---@param engine integer
---@return "mysql"|"sqlite"
local function engine_to_dialect(engine)
    local E = _ENV.DatabaseEngine;
    if (E) then
        if (engine == E.SQLite) then return "sqlite"; end
        if (engine == E.PostgreSQL) then return "mysql"; end -- close enough for our SQL
    end
    return "mysql";
end

--- Whether a DatabaseEngine supports `INSERT ... RETURNING` (SQLite >= 3.35,
--- PostgreSQL — both bundled by nanos satisfy this; MySQL does not). Returns nil
--- when the engine is unknown (e.g. a pre-built `database` instance was passed).
---@param engine integer|nil
---@return boolean|nil
local function engine_supports_returning(engine)
    local E = _ENV.DatabaseEngine;
    if (not E or engine == nil) then return nil; end
    return engine == E.SQLite or engine == E.PostgreSQL;
end

--- MariaDB >= 10.5 supports `INSERT ... RETURNING`; real MySQL does not. The
--- nanos `MySQL` engine can point at either, so probe the server banner once
--- (`SELECT VERSION()` -> e.g. "11.6.2-MariaDB"). Best-effort: any failure or an
--- unrecognised banner yields false (falls back to the LAST_INSERT_ID path).
---@param db table
---@return boolean
local function detect_mariadb_returning(db)
    if (type(db) ~= "table" or type(db.Select) ~= "function") then return false; end
    local ok, rows = pcall(function() return db:Select("SELECT VERSION() AS v"); end);
    if (not ok or type(rows) ~= "table" or type(rows[1]) ~= "table") then return false; end
    local v = tostring(rows[1].v or "");
    if (not v:find("MariaDB", 1, true)) then return false; end
    local major, minor = v:match("^(%d+)%.(%d+)");
    major, minor = tonumber(major), tonumber(minor);
    if (not major or not minor) then return false; end
    return (major > 10) or (major == 10 and minor >= 5);
end

---@param options? NormNanosAdapterOptions
function NormNanosAdapter:__init(options)
    options = options or {};
    self._resolved_dialect = options.dialect
        or (options.engine ~= nil and engine_to_dialect(options.engine))
        or "sqlite";

    -- RETURNING support is engine-driven (PostgreSQL maps to the "mysql" dialect,
    -- so the dialect name alone can't tell it apart). When the engine is unknown,
    -- only assume support for SQLite.
    local sr = engine_supports_returning(options.engine);
    if (sr == nil) then sr = (self._resolved_dialect == "sqlite"); end
    self._supports_returning = sr;

    NormAdapter.__init(self, options); -- light-class: explicit super constructor call

    if (options.database) then
        self.database = options.database;
    else
        local Database = _ENV.Database;
        assert(Database, "[norm] Nanos `Database` global is not available");
        assert(options.engine ~= nil, "[norm] nanos adapter requires `engine` or a `database` instance");
        options.engine = options.engine or _ENV.DatabaseEngine.SQLite;
        options.connection = options.connection or "./database.db";
        options.pool_size = options.pool_size or 10;
        -- nanos Database(database_engine, connection_string, pool_size)
        local ok, db = pcall(Database, options.engine, options.connection, options.pool_size);
        if (not ok) then
            utils.log("DB", "nanos connection FAILED ('%s'): %s", tostring(options.connection), tostring(db));
            error(("[norm] failed to open nanos database '%s': %s"):format(tostring(options.connection), tostring(db)));
        end
        self.database = db;
        utils.log("DB", "connected to nanos database '%s' (pool=%d)", tostring(options.connection), options.pool_size);
    end

    -- RETURNING availability on the mysql dialect isn't known from the engine
    -- alone: nanos `MySQL` may be real MySQL (no RETURNING) OR MariaDB (>= 10.5,
    -- which supports it). Honour an explicit override, else probe the server once.
    if (options.returning ~= nil) then
        self._supports_returning = options.returning == true;
    elseif (not self._supports_returning and self._resolved_dialect == "mysql") then
        if (detect_mariadb_returning(self.database)) then
            self._supports_returning = true;
            utils.log("DB", "MariaDB >= 10.5 detected: using INSERT ... RETURNING for atomic insertId");
        end
    end
end

---@return "mysql"|"sqlite"
function NormNanosAdapter:get_dialect_name()
    return self._resolved_dialect or "sqlite";
end

--- SQLite, PostgreSQL and MariaDB (>= 10.5, auto-detected at init) support
--- `INSERT ... RETURNING`, letting the ORM fetch a new id atomically (pool-safe).
--- Real MySQL does not, and falls back to a best-effort `LAST_INSERT_ID()` query
--- (see `raw_execute`).
---@return boolean
function NormNanosAdapter:supports_returning()
    return self._supports_returning == true;
end

--- If nanos-promise is loaded in this package (global `Promise`), use it.
--- No cross-package import: the nanos package is expected to bundle nanos-promise.
---@return NormPromiseProvider|nil
function NormNanosAdapter:default_provider()
    local P = _ENV.Promise;
    if (type(P) ~= "nil") then
        local ok, provider = pcall(promise.nanos, P);
        if (ok) then return provider; end
    end
    return nil; -- fall back to the built-in provider
end

--- Nanos exposes a global `JSON` class (`stringify`/`parse`); use it to
--- (de)serialise `json` columns automatically.
---@return NormJsonProvider|nil
function NormNanosAdapter:default_json_provider()
    if (type(_ENV.JSON) == "table") then
        local ok, provider = pcall(jsonlib.nanos, _ENV.JSON);
        if (ok) then return provider; end
    end
    return nil; -- fall back to auto-detection / raw passthrough
end

--- Nanos binds parameters with NUMBERED placeholders (`:0`, `:1`, ... 0-indexed),
--- not `?`. Norm's SQL builder emits `?`, so the adapter rewrites them in order.
--- Only `?` outside string literals (`'...'`) and quoted identifiers (`` `...` ``)
--- are treated as placeholders, so a literal `?` in a value/DEFAULT is preserved
--- (`''` and ``` `` ``` are handled as in-literal escaped quotes).
---@param query string
---@return string
local function to_nanos_placeholders(query)
    local out, i, n, idx = {}, 1, #query, -1;
    local in_str, in_id = false, false;
    while (i <= n) do
        local c = query:sub(i, i);
        if (in_str) then
            out[#out + 1] = c;
            if (c == "'") then
                if (query:sub(i + 1, i + 1) == "'") then out[#out + 1] = "'"; i = i + 1; -- escaped ''
                else in_str = false; end
            end
        elseif (in_id) then
            out[#out + 1] = c;
            if (c == "`") then
                if (query:sub(i + 1, i + 1) == "`") then out[#out + 1] = "`"; i = i + 1; -- escaped ``
                else in_id = false; end
            end
        elseif (c == "'") then out[#out + 1] = c; in_str = true;
        elseif (c == "`") then out[#out + 1] = c; in_id = true;
        elseif (c == "?") then idx = idx + 1; out[#out + 1] = ":" .. idx;
        else out[#out + 1] = c; end
        i = i + 1;
    end
    return table.concat(out);
end

--- Internal: run a SELECT (async if available, else synchronous).
---@param db table
---@param query string
---@param params any[]
---@param callback NormQueryCallback
local function do_select(db, query, params, callback)
    params = params or {};
    query = to_nanos_placeholders(query);
    if (type(db.SelectAsync) == "function") then
        -- Nanos signature: SelectAsync(query, callback?, parameters...) -- params are VARARGS.
        db:SelectAsync(query, function(rows) callback(nil, rows or {}); end, table.unpack(params));
    else
        local ok, rows = pcall(function() return db:Select(query, table.unpack(params)); end);
        if (ok) then callback(nil, rows or {}); else callback(rows); end
    end
end

--- Internal: run a write (async if available, else synchronous).
---@param db table
---@param query string
---@param params any[]
---@param callback fun(err: any, affected?: number)
local function do_execute(db, query, params, callback)
    params = params or {};
    query = to_nanos_placeholders(query);
    if (type(db.ExecuteAsync) == "function") then
        -- Nanos signature: ExecuteAsync(query, callback?, parameters...) -- params are VARARGS.
        db:ExecuteAsync(query, function(affected) callback(nil, affected); end, table.unpack(params));
    else
        local ok, affected = pcall(function() return db:Execute(query, table.unpack(params)); end);
        if (ok) then callback(nil, affected); else callback(affected); end
    end
end

---@param query string
---@param params any[]
---@param callback NormQueryCallback
function NormNanosAdapter:raw_query(query, params, callback)
    do_select(self.database, query, params, callback);
end

--- Run a write. For models on SQLite/PostgreSQL the id is fetched via `INSERT ...
--- RETURNING` (see the model layer), so this path is only used for those engines
--- by raw `execute()` calls. On MySQL (no RETURNING) inserts fall back to a
--- separate `LAST_INSERT_ID()` query: this is best-effort, because that function
--- is connection-scoped and the pool may run it on another connection. Prefer a
--- client-generated id (or `pool_size = 1`) if a correct insertId is critical on
--- MySQL + nanos.
---@param query string
---@param params any[]
---@param callback NormExecuteCallback
function NormNanosAdapter:raw_execute(query, params, callback)
    local db = self.database;
    local is_insert = query:match("^%s*[Ii][Nn][Ss][Ee][Rr][Tt]") ~= nil;
    local last_id_sql = (self:get_dialect_name() == "sqlite")
        and "SELECT last_insert_rowid() AS id"
        or "SELECT LAST_INSERT_ID() AS id";

    do_execute(db, query, params, function(err, affected)
        if (err ~= nil) then return callback(err); end
        if (not is_insert) then
            return callback(nil, { affectedRows = affected });
        end
        do_select(db, last_id_sql, {}, function(select_err, rows)
            local id = (not select_err) and rows[1] and rows[1].id or nil;
            callback(nil, { affectedRows = affected, insertId = id });
        end);
    end);
end

---@class NormNanosAdapterModule
---@field class NormNanosAdapter
local M = {};

--- Create a Nanos adapter instance (opens/pools a `Database` and logs the
--- connection). Pass it to `Norm.new`.
--- ```lua
---     local adapter = Norm.adapters.nanos.new({
---         engine = DatabaseEngine.SQLite,
---         connection = "./game.db",
---         pool_size = 4, -- optional
---     })
---     local db = Norm.new({ adapter = adapter })
--- ```
---@param options? NormNanosAdapterOptions
---@return NormNanosAdapter
function M.new(options) return NormNanosAdapter(options); end
M.class = NormNanosAdapter;

return M;
