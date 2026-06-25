--- The Orm root: binds an adapter to a promise provider, owns the model
--- registry, and turns the adapter's callback API into provider promises.
local class = class;
local utils = require("utils");
local sqlmod = require("sql");
local promise = require("promise");
local jsonmod = require("json");
local model_module = require("model");

---@class NormOrm: LightClass
---@field adapter NormAdapter
---@field provider NormPromiseProvider
---@field models table<string, NormModel>
---@field log boolean
---@field foreign_keys boolean|"auto" Whether `sync()` emits SQL FOREIGN KEY constraints.
---@field json NormJsonProvider Provider used to (de)serialise `json` columns.
---@field private _logger fun(level: string, message: string)
---@field private _warned_sqlite_fk boolean
---@overload fun(options: NormOptions): NormOrm
local NormOrm = class.new("NormOrm");

---@class NormOptions
---@field adapter NormAdapter Required. An adapter instance (or duck-typed table).
---@field promise? NormPromiseProvider Promise provider. Defaults to the adapter's, else built-in.
---@field log? boolean Log every executed statement.
---@field logger? fun(level: string, message: string)
---@field foreignKeys? boolean|"auto" Emit SQL FOREIGN KEY constraints from `belongsTo` relations. `"auto"` (default) emits on MySQL, skips on SQLite (with a one-time warning); `true` always emits; `false` never emits (no warning).
---@field json? NormJsonProvider|"auto"|false JSON provider for `json` columns. `"auto"` (default) uses the adapter's, else auto-detects (Nanos `JSON` / Lua `json`), else raw passthrough; `false` disables (de)serialisation.

---@param options NormOptions
function NormOrm:__init(options)
    utils.assert(type(options) == "table", "Norm: options table is required");
    utils.assert(options.adapter and type(options.adapter.raw_query) == "function",
        "Norm: a valid `adapter` is required");

    self.adapter = options.adapter;

    local prov = options.promise;
    if (prov == nil) then
        prov = self.adapter:default_provider() or promise.builtin();
    elseif (type(prov.new) ~= "function"
        or type(prov.resolve) ~= "function"
        or type(prov.reject) ~= "function") then
        -- Not a provider table; assume it's a promise CLASS (callable as Class(executor))
        -- and wrap it. This makes `promise = Promise` (a raw promise class) just work.
        prov = promise.from_class(prov);
    end
    self.provider = promise.define(prov);

    self.models = {};
    self.log = options.log == true;
    self._logger = options.logger or utils.logger;
    self.foreign_keys = (options.foreignKeys == nil) and "auto" or options.foreignKeys;
    self._warned_sqlite_fk = false;

    -- JSON provider for `json` columns: explicit > adapter default > auto-detect.
    -- `false` disables it (raw string passthrough).
    local json_opt = options.json;
    if (json_opt == false) then
        self.json = jsonmod.raw();
    elseif (json_opt ~= nil and json_opt ~= "auto") then
        self.json = jsonmod.define(json_opt);
    else
        local from_adapter;
        if (type(self.adapter.default_json_provider) == "function") then
            from_adapter = self.adapter:default_json_provider();
        end
        self.json = from_adapter or jsonmod.detect();
    end
end

---@private
---@param query string
---@param params? any[]
function NormOrm:_trace(query, params)
    if (not self.log) then return; end
    local suffix = "";
    if (params and #params > 0) then
        local printed = {};
        for i = 1, #params do printed[i] = tostring(params[i]); end
        suffix = " -- [" .. table.concat(printed, ", ") .. "]";
    end
    self._logger("SQL", query .. suffix);
end

--- Run a SELECT and transform the rows inside the promise.
---@param query string
---@param params? any[]
---@param transform fun(rows: table[]): any
---@return NormPromise promise resolving to the transform result
function NormOrm:_query_map(query, params, transform)
    self:_trace(query, params);
    return self.provider.new(function(resolve, reject)
        self.adapter:raw_query(query, params or {}, function(err, rows)
            if (err ~= nil) then return reject(err); end
            local ok, mapped = pcall(transform, rows or {});
            if (not ok) then return reject(mapped); end
            resolve(mapped);
        end);
    end);
end

--- Run a write statement and transform the result inside the promise.
---@param query string
---@param params? any[]
---@param transform fun(result: NormExecResult): any
---@return NormPromise promise resolving to the transform result
function NormOrm:_execute_map(query, params, transform)
    self:_trace(query, params);
    return self.provider.new(function(resolve, reject)
        self.adapter:raw_execute(query, params or {}, function(err, result)
            if (err ~= nil) then return reject(err); end
            local ok, mapped = pcall(transform, result or {});
            if (not ok) then return reject(mapped); end
            resolve(mapped);
        end);
    end);
end

--- Internal: batched eager-load of one relation onto a set of parent records.
--- Runs a single `... IN (...)` query and attaches results. Calls `cb(err?)`.
---@private
---@param model NormModel
---@param mains NormRecord[]
---@param name string
---@param cb fun(err: any)
function NormOrm:_load_include_batch(model, mains, name, cb)
    local rel = model.relations[name];
    if (not rel) then
        return cb(("model '%s' has no relation '%s'"):format(model.table, name));
    end
    local target = self:model(rel.target);
    if (not target) then
        return cb(("relation '%s': target model '%s' is not defined"):format(name, rel.target));
    end
    local d = self.adapter:get_dialect();

    -- Collect the unique, non-nil join keys from the parent records.
    local source_key = (rel.kind == "belongs_to") and rel.key or (rel.localKey or model.primary_key);
    local keys, seen = {}, {};
    for i = 1, #mains do
        local v = mains[i][source_key];
        if (v ~= nil and not seen[v]) then seen[v] = true; keys[#keys + 1] = v; end
    end

    local empty = (rel.kind == "has_many") and {} or nil;
    if (#keys == 0) then
        for i = 1, #mains do mains[i][name] = empty; end
        return cb();
    end

    if (rel.kind == "belongs_to") then
        local other_key = rel.otherKey or target.primary_key;
        local state = { table = target.table, wheres = { { column = other_key, op = "IN", value = keys } } };
        local statement, params = sqlmod.select(state, d);
        self:_trace(statement, params);
        self.adapter:raw_query(statement, params, function(err, rows)
            if (err ~= nil) then return cb(err); end
            rows = rows or {};
            local by_key = {};
            for i = 1, #rows do by_key[rows[i][other_key]] = target:wrap(rows[i]); end
            for i = 1, #mains do mains[i][name] = by_key[mains[i][rel.key]]; end
            cb();
        end);
        return;
    end

    -- has_one / has_many: group target rows by their foreign key.
    local state = { table = target.table, wheres = { { column = rel.key, op = "IN", value = keys } } };
    local statement, params = sqlmod.select(state, d);
    self:_trace(statement, params);
    self.adapter:raw_query(statement, params, function(err, rows)
        if (err ~= nil) then return cb(err); end
        rows = rows or {};
        local groups = {};
        for i = 1, #rows do
            local k = rows[i][rel.key];
            local g = groups[k];
            if (not g) then g = {}; groups[k] = g; end
            g[#g + 1] = target:wrap(rows[i]);
        end
        for i = 1, #mains do
            local g = groups[mains[i][source_key]] or {};
            mains[i][name] = (rel.kind == "has_one") and (g[1] or nil) or g;
        end
        cb();
    end);
end

--- Internal: run a SELECT then eager-load `includes` (sequentially) before
--- resolving. Returns a single record when `single` is true, else an array.
---@private
---@param model NormModel
---@param state NormQueryState
---@param includes string[]
---@param single boolean
---@return NormPromise
function NormOrm:_query_with_includes(model, state, includes, single)
    local d = self.adapter:get_dialect();
    local statement, params = sqlmod.select(state, d);
    self:_trace(statement, params);
    return self.provider.new(function(resolve, reject)
        self.adapter:raw_query(statement, params or {}, function(err, rows)
            if (err ~= nil) then return reject(err); end
            rows = rows or {};
            local records = {};
            for i = 1, #rows do records[i] = model:wrap(rows[i]); end
            if (#records == 0) then
                return resolve(single and nil or records);
            end
            local index = 0;
            local function step()
                index = index + 1;
                local name = includes[index];
                if (not name) then
                    return resolve(single and records[1] or records);
                end
                local ok, err2 = pcall(function()
                    self:_load_include_batch(model, records, name, function(e)
                        if (e ~= nil) then return reject(e); end
                        step();
                    end);
                end);
                if (not ok) then reject(err2); end
            end
            step();
        end);
    end);
end

--- Run a raw parameterised SELECT (bypassing the query builder). Resolves with
--- the raw rows. Bind values with `?` placeholders, never interpolate.
--- ```lua
---     local rows = db:query("SELECT * FROM `users` WHERE `coins` > ?", { 100 }):await()
--- ```
---@param query string
---@param params? any[]
---@return NormRowsPromise promise resolving to table[]
function NormOrm:query(query, params)
    return self:_query_map(query, params, function(rows) return rows; end);
end

--- Run a raw parameterised write (INSERT/UPDATE/DELETE/DDL). Resolves with a
--- `{ affectedRows, insertId }` table.
--- ```lua
---     local res = db:execute("DELETE FROM `users` WHERE `id` = ?", { 1 }):await()
---     print(res.affectedRows)
--- ```
---@param query string
---@param params? any[]
---@return NormExecResultPromise promise resolving to NormExecResult
function NormOrm:execute(query, params)
    return self:_execute_map(query, params, function(result) return result; end);
end

--- Define and register a model from a schema (a `{ column = Norm.types.* }` map).
--- The returned model is your handle for all CRUD/query operations.
--- ```lua
---     local User = db:define("users", {
---         id    = Norm.types.id(),
---         name  = Norm.types.string({ length = 64, nullable = false }),
---         email = Norm.types.string({ length = 128, unique = true }),
---         coins = Norm.types.integer({ default = 0 }),
---     })
--- ```
---@param table_name string
---@param schema table<string, NormColumn>
---@return NormModel
function NormOrm:define(table_name, schema)
    utils.assert(not self.models[table_name],
        ("Norm: model '%s' is already defined"):format(table_name));
    local model = model_module.define(self, table_name, schema);
    self.models[table_name] = model;
    return model;
end

--- Get a previously defined model.
---@param table_name string
---@return NormModel|nil
function NormOrm:model(table_name)
    return self.models[table_name];
end

--- Internal: the FOREIGN KEY constraints to emit for a model, derived from its
--- `belongs_to` relations (the side that physically holds the FK column). The
--- referenced column defaults to the target's primary key, resolved here because
--- the target may have been defined after this model.
---@private
---@param model NormModel
---@return NormForeignKey[]
function NormOrm:_collect_foreign_keys(model)
    local fks = {};
    for _, rel in pairs(model.relations) do
        if (rel.kind == "belongs_to" and rel.key) then
            local target = self.models[rel.target];
            -- Skip relations whose target table isn't registered: we can't emit a
            -- REFERENCES clause to a table Norm doesn't know how to create.
            if (target) then
                fks[#fks + 1] = {
                    column = rel.key,
                    ref_table = rel.target,
                    ref_column = rel.otherKey or target.primary_key or "id",
                    on_delete = rel.onDelete,
                    on_update = rel.onUpdate,
                };
            end
        end
    end
    table.sort(fks, function(a, b) return a.column < b.column; end); -- stable output
    return fks;
end

---@private
---@return boolean
function NormOrm:_has_any_foreign_key()
    for _, m in pairs(self.models) do
        if (#self:_collect_foreign_keys(m) > 0) then return true; end
    end
    return false;
end

--- Internal: decide whether `sync()` should emit FOREIGN KEY constraints for the
--- given dialect, honouring the `foreignKeys` option and warning once on SQLite.
---@private
---@param d NormDialect
---@return boolean
function NormOrm:_should_emit_fk(d)
    local mode = self.foreign_keys;
    if (mode == false) then return false; end

    if (mode == true) then
        if (d.name == "sqlite" and not self._warned_sqlite_fk) then
            self._warned_sqlite_fk = true;
            self._logger("WARN", "[norm] foreignKeys=true on sqlite: constraints are emitted, but enforcement "
                .. "needs `PRAGMA foreign_keys = ON` per connection, which Norm cannot guarantee.");
        end
        return true;
    end

    -- "auto": emit on engines that enforce FKs out of the box (MySQL), skip on
    -- SQLite (per-connection PRAGMA can't be guaranteed). Warn only if relations
    -- actually declare FKs, so FK-less SQLite schemas stay silent.
    if (d.name == "sqlite") then
        if (not self._warned_sqlite_fk and self:_has_any_foreign_key()) then
            self._warned_sqlite_fk = true;
            self._logger("WARN", "[norm] foreign keys are not emitted on sqlite (set foreignKeys=true to force "
                .. "them, or foreignKeys=false to silence this warning).");
        end
        return false;
    end
    return true;
end

--- Internal: order models so a table is created after the tables it references
--- via `belongs_to` (required for inline FKs on MySQL/InnoDB). Returns the table
--- names in creation order plus whether a dependency cycle was detected.
---@private
---@return string[] order, boolean has_cycle
function NormOrm:_sync_order()
    local names = {};
    for name in pairs(self.models) do names[#names + 1] = name; end
    table.sort(names); -- deterministic starting point

    -- deps[name] = sorted list of referenced tables that are also registered models.
    local deps = {};
    for _, name in ipairs(names) do
        local set = {};
        for _, rel in pairs(self.models[name].relations) do
            if (rel.kind == "belongs_to" and rel.target ~= name and self.models[rel.target]) then
                set[rel.target] = true;
            end
        end
        local list = {};
        for t in pairs(set) do list[#list + 1] = t; end
        table.sort(list);
        deps[name] = list;
    end

    local order, visited, on_stack, has_cycle = {}, {}, {}, false;
    local function visit(name)
        if (visited[name]) then return; end
        if (on_stack[name]) then has_cycle = true; return; end
        on_stack[name] = true;
        for _, dep in ipairs(deps[name]) do visit(dep); end
        on_stack[name] = nil;
        visited[name] = true;
        order[#order + 1] = name;
    end
    for _, name in ipairs(names) do visit(name); end
    return order, has_cycle;
end

--- Create the table of every registered model (CREATE TABLE IF NOT EXISTS),
--- in dependency order so foreign keys resolve. When foreign keys are enabled
--- (see the `foreignKeys` option), `belongsTo` relations emit `FOREIGN KEY`
--- constraints. Resolves true.
--- ```lua
---     db:sync():await() -- run once at startup, after defining your models
--- ```
---@return NormBooleanPromise promise resolving to true
function NormOrm:sync()
    local d = self.adapter:get_dialect();
    local emit_fk = self:_should_emit_fk(d);
    local order, has_cycle = self:_sync_order();

    -- Inline FKs need referenced tables first; a cycle can't satisfy that on
    -- engines that check at CREATE time (MySQL). SQLite allows forward refs.
    if (emit_fk and has_cycle and d.name ~= "sqlite") then
        self._logger("WARN", "[norm] cyclic foreign-key dependency detected; CREATE TABLE order cannot satisfy "
            .. "every reference on '" .. d.name .. "'. Consider foreignKeys=false or breaking the cycle.");
    end

    local statements = {};
    for _, name in ipairs(order) do
        local m = self.models[name];
        local fks = emit_fk and self:_collect_foreign_keys(m) or nil;
        statements[#statements + 1] = sqlmod.create_table(m.table, m.columns, d, fks);
    end

    return self.provider.new(function(resolve, reject)
        local index = 0;
        local function step()
            index = index + 1;
            if (index > #statements) then return resolve(true); end
            self:_trace(statements[index], {});
            self.adapter:raw_execute(statements[index], {}, function(err)
                if (err ~= nil) then return reject(err); end
                step();
            end);
        end
        step();
    end);
end

return NormOrm;
