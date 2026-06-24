--- Adapter for the Nanos World `Database` object.
--- https://docs.nanos.world/docs/scripting-reference/classes/database
local class = class;
local utils = require("utils");
local NormAdapter = require("adapter");
local promise = require("promise");

---@class NormNanosAdapterOptions: NormAdapterOptions
---@field engine? integer A `DatabaseEngine` enum value (required unless `database` is given).
---@field connection? string Connection string / file path.
---@field pool_size? integer Number of pooled connections (nanos default if omitted).
---@field database? table An already-built nanos `Database` instance to reuse.

---@class NormNanosAdapter: NormAdapter
---@field database table The underlying nanos `Database`.
---@field private _resolved_dialect "mysql"|"sqlite"
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

---@param options? NormNanosAdapterOptions
function NormNanosAdapter:__init(options)
    options = options or {};
    self._resolved_dialect = options.dialect
        or (options.engine ~= nil and engine_to_dialect(options.engine))
        or "sqlite";

    NormAdapter.__init(self, options); -- light-class: explicit super constructor call

    if (options.database) then
        self.database = options.database;
    else
        local Database = _ENV.Database;
        assert(Database, "[norm] Nanos `Database` global is not available");
        assert(options.engine ~= nil, "[norm] nanos adapter requires `engine` or a `database` instance");
        options.engine = options.engine or _ENV.DatabaseEngine.SQLite;
        options.connection = options.connection or "./database.db";
        options.pool_size = options.pool_size or 4;
        -- nanos Database(database_engine, connection_string, pool_size)
        local ok, db = pcall(Database, options.engine, options.connection, options.pool_size);
        if (not ok) then
            utils.log("DB", "nanos connection FAILED ('%s'): %s", tostring(options.connection), tostring(db));
            error(("[norm] failed to open nanos database '%s': %s"):format(tostring(options.connection), tostring(db)));
        end
        self.database = db;
        utils.log("DB", "connected to nanos database '%s' (pool=%d)", tostring(options.connection), options.pool_size);
    end
end

---@return "mysql"|"sqlite"
function NormNanosAdapter:get_dialect_name()
    return self._resolved_dialect or "sqlite";
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

--- Nanos binds parameters with NUMBERED placeholders (`:0`, `:1`, ... 0-indexed),
--- not `?`. Norm's SQL builder emits `?`, so the adapter rewrites them in order.
--- Safe because the builder only ever emits `?` as a placeholder (never inside a
--- string literal; identifiers are backtick-quoted).
---@param query string
---@return string
local function to_nanos_placeholders(query)
    local i = -1;
    return (query:gsub("%?", function() i = i + 1; return ":" .. i; end));
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
