--- The Orm root: binds an adapter to a promise provider, owns the model
--- registry, and turns the adapter's callback API into provider promises.
local class = class;
local utils = require("utils");
local sqlmod = require("sql");
local promise = require("promise");
local model_module = require("model");

---@class NormOrm: LightClass
---@field adapter NormAdapter
---@field provider NormPromiseProvider
---@field models table<string, NormModel>
---@field log boolean
---@field private _logger fun(level: string, message: string)
---@overload fun(options: NormOptions): NormOrm
local NormOrm = class.new("NormOrm");

---@class NormOptions
---@field adapter NormAdapter Required. An adapter instance (or duck-typed table).
---@field promise? NormPromiseProvider Promise provider. Defaults to the adapter's, else built-in.
---@field log? boolean Log every executed statement.
---@field logger? fun(level: string, message: string)

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

--- Create the table of every registered model (CREATE TABLE IF NOT EXISTS),
--- sequentially so foreign-key dependencies resolve in order. Resolves true.
--- ```lua
---     db:sync():await() -- run once at startup, after defining your models
--- ```
---@return NormBooleanPromise promise resolving to true
function NormOrm:sync()
    local d = self.adapter:get_dialect();
    local statements = {};
    for _, m in pairs(self.models) do
        statements[#statements + 1] = sqlmod.create_table(m.table, m.columns, d);
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
