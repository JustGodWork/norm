--- The Orm root: binds an adapter to a promise provider, owns the model
--- registry, and turns the adapter's callback API into provider promises.
local class = class;
local utils = require("utils");
local sqlmod = require("sql");
local promise = require("promise");
local jsonmod = require("json");
local model_module = require("model");

local singularize = utils.singularize;
local default_pivot = utils.default_pivot;

--- Take `list[offset+1 .. offset+limit]` (used for per-parent limit on an included
--- collection). Returns the list unchanged when `limit` is nil.
---@param list any[]
---@param offset? number
---@param limit? number
---@return any[]
local function slice(list, offset, limit)
    if (not limit) then return list; end
    offset = offset or 0;
    local out = {};
    for i = offset + 1, math.min(#list, offset + limit) do out[#out + 1] = list[i]; end
    return out;
end

--- Flatten the records loaded under `name` across a set of parents (handles a
--- single record, nil, or an array) into one list for the next nesting level.
---@param records NormRecord[]
---@param name string
---@return NormRecord[]
local function collect_loaded(records, name)
    local out = {};
    for i = 1, #records do
        local v = records[i][name];
        if (v ~= nil) then
            if (v.__model) then
                out[#out + 1] = v;                       -- single record (belongs_to / has_one)
            else
                for j = 1, #v do out[#out + 1] = v[j]; end -- array (has_many / belongs_to_many)
            end
        end
    end
    return out;
end

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
---@field queue_until_ready? boolean Hold data operations in a queue until the first successful `sync()`/`migrate()`, then flush them (default false: run immediately).

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

    -- Readiness gate. When queueing is requested, data ops are held until the
    -- first sync()/migrate() flips this ready and flushes them.
    self._ready = (options.queue_until_ready ~= true);
    self._queue = {};

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

--- The single gate every data operation goes through. Runs against the adapter
--- when ready; otherwise holds the call until `sync()`/`migrate()` flushes it.
--- (sync/migrate themselves bypass this — they're what makes the ORM ready.)
---@private
function NormOrm:_raw_query(query, params, callback)
    if (self._ready) then return self.adapter:raw_query(query, params, callback); end
    if (#self._queue == 0) then
        self._logger("DB", "queue_until_ready: holding operations until sync()/migrate()");
    end
    self._queue[#self._queue + 1] = { kind = "query", query = query, params = params, callback = callback };
end

---@private
function NormOrm:_raw_execute(query, params, callback)
    if (self._ready) then return self.adapter:raw_execute(query, params, callback); end
    if (#self._queue == 0) then
        self._logger("DB", "queue_until_ready: holding operations until sync()/migrate()");
    end
    self._queue[#self._queue + 1] = { kind = "execute", query = query, params = params, callback = callback };
end

--- Mark the ORM ready and replay any queued operations in FIFO order. No-op if
--- already ready. Called by `sync()`/`migrate()` on success.
---@private
function NormOrm:_flush_ready()
    if (self._ready) then return; end
    self._ready = true;
    local queue = self._queue;
    self._queue = {};
    if (#queue > 0) then
        self._logger("DB", ("ready: flushing %d queued operation(s)"):format(#queue));
    end
    for i = 1, #queue do
        local op = queue[i];
        if (op.kind == "query") then
            self.adapter:raw_query(op.query, op.params, op.callback);
        else
            self.adapter:raw_execute(op.query, op.params, op.callback);
        end
    end
end

--- Whether operations run immediately. With `queue_until_ready`, false until the
--- first successful `sync()`/`migrate()`; otherwise always true.
---@return boolean
function NormOrm:is_ready() return self._ready == true; end

--- Run a SELECT and transform the rows inside the promise.
---@param query string
---@param params? any[]
---@param transform fun(rows: table[]): any
---@return NormPromise promise resolving to the transform result
function NormOrm:_query_map(query, params, transform)
    self:_trace(query, params);
    return self.provider.new(function(resolve, reject)
        self:_raw_query(query, params or {}, function(err, rows)
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
        self:_raw_execute(query, params or {}, function(err, result)
            if (err ~= nil) then return reject(err); end
            local ok, mapped = pcall(transform, result or {});
            if (not ok) then return reject(mapped); end
            resolve(mapped);
        end);
    end);
end

--- Internal: fetch many-to-many target records for a set of parent keys, in two
--- batched queries (pivot then targets) — no N+1 regardless of cardinality. The
--- target-dependent defaults (`through`, `otherKey`, `otherLocalKey`) are resolved
--- here, since the target model may have been defined after this one.
---@private
---@param model NormModel
---@param rel NormRelation
---@param keys any[] Unique parent local-key values.
---@param spec? table Include spec (`wheres`/`orders`/`limit`/`offset`) applied to the target.
---@param cb fun(err: any, by_main?: table<any, NormRecord[]>) `by_main[parentKey]` = linked target records.
function NormOrm:_m2m_fetch(model, rel, keys, spec, cb)
    local target = self:model(rel.target);
    if (not target) then
        return cb(("relation '%s': target model '%s' is not defined"):format(rel.name or "?", rel.target));
    end
    if (#keys == 0) then return cb(nil, {}); end

    local d = self.adapter:get_dialect();
    local through = rel.through or default_pivot(model.table, target.table);
    local pivot_main = rel.key;                                          -- pivot col -> this model
    local pivot_other = rel.otherKey or (singularize(target.table) .. "_id"); -- pivot col -> target
    local other_local = rel.otherLocalKey or target.primary_key;         -- target's local key

    -- 1) pivot rows: parent key + related key.
    local pstate = { table = through, columns = { pivot_main, pivot_other },
        wheres = { { column = pivot_main, op = "IN", value = keys } } };
    local pstmt, pparams = sqlmod.select(pstate, d);
    self:_trace(pstmt, pparams);
    self:_raw_query(pstmt, pparams, function(perr, prows)
        if (perr ~= nil) then return cb(perr); end
        prows = prows or {};
        local main_to_related, related_ids, seen = {}, {}, {};
        for i = 1, #prows do
            local mk, rk = prows[i][pivot_main], prows[i][pivot_other];
            if (mk ~= nil and rk ~= nil) then
                local lst = main_to_related[mk];
                if (not lst) then lst = {}; main_to_related[mk] = lst; end
                lst[#lst + 1] = rk;
                if (not seen[rk]) then seen[rk] = true; related_ids[#related_ids + 1] = rk; end
            end
        end
        if (#related_ids == 0) then return cb(nil, {}); end

        -- 2) target rows, fetched once by their local key (+ any include filters/order).
        local tstate = { table = target.table,
            wheres = { { column = other_local, op = "IN", value = related_ids } } };
        if (spec and spec.wheres) then for i = 1, #spec.wheres do tstate.wheres[#tstate.wheres + 1] = spec.wheres[i]; end end
        if (spec and spec.orders and #spec.orders > 0) then tstate.orders = spec.orders; end
        local tstmt, tparams = sqlmod.select(tstate, d);
        self:_trace(tstmt, tparams);
        -- invert pivot mapping: related key -> the parent keys linked to it.
        local related_to_mains = {};
        for mk, rks in pairs(main_to_related) do
            for j = 1, #rks do
                local rk = rks[j];
                local l = related_to_mains[rk];
                if (not l) then l = {}; related_to_mains[rk] = l; end
                l[#l + 1] = mk;
            end
        end
        self:_raw_query(tstmt, tparams, function(terr, trows)
            if (terr ~= nil) then return cb(terr); end
            trows = trows or {};
            local by_main = {};
            for mk in pairs(main_to_related) do by_main[mk] = {}; end
            -- iterate target rows in SQL order so any include `order` is honoured.
            for i = 1, #trows do
                local rec = target:wrap(trows[i]);
                local owners = related_to_mains[trows[i][other_local]];
                if (owners) then
                    for j = 1, #owners do
                        local g = by_main[owners[j]];
                        g[#g + 1] = rec;
                    end
                end
            end
            if (spec and spec.limit) then
                for mk, list in pairs(by_main) do by_main[mk] = slice(list, spec.offset, spec.limit); end
            end
            cb(nil, by_main);
        end);
    end);
end

--- Internal: eager-load a map of include specs onto a set of records. Each
--- relation is loaded once via `_load_include_batch` (batched, no N+1) with its
--- spec (per-relation `wheres`/`orders`/`limit`); a spec with `children` then
--- recurses onto the flattened loaded records. Siblings load sequentially.
---@private
---@param model NormModel
---@param records NormRecord[]
---@param includes table<string, table> name -> spec { wheres, orders, limit, offset, children }
---@param cb fun(err: any)
function NormOrm:_load_includes(model, records, includes, cb)
    local names = {};
    for name in pairs(includes) do names[#names + 1] = name; end
    table.sort(names); -- deterministic order

    local i = 0;
    local function step()
        i = i + 1;
        local name = names[i];
        if (not name) then return cb(); end
        local spec = includes[name];
        self:_load_include_batch(model, records, name, spec, function(err)
            if (err ~= nil) then return cb(err); end
            local children = spec.children;
            if (not children or next(children) == nil) then return step(); end -- leaf
            local rel = model.relations[name];
            local target = self:model(rel.target);
            local kids = collect_loaded(records, name);
            if (#kids == 0) then return step(); end
            self:_load_includes(target, kids, children, function(e)
                if (e ~= nil) then return cb(e); end
                step();
            end);
        end);
    end
    step();
end

--- Internal: batched eager-load of one relation onto a set of parent records.
--- Runs a single `... IN (...)` query and attaches results. Calls `cb(err?)`.
---@private
---@param model NormModel
---@param mains NormRecord[]
---@param name string
---@param spec? table Include spec (`wheres`/`orders`/`limit`/`offset`).
---@param cb fun(err: any)
function NormOrm:_load_include_batch(model, mains, name, spec, cb)
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

    local empty = (rel.kind == "has_many" or rel.kind == "belongs_to_many") and {} or nil;
    if (#keys == 0) then
        for i = 1, #mains do mains[i][name] = empty; end
        return cb();
    end

    if (rel.kind == "belongs_to_many") then
        self:_m2m_fetch(model, rel, keys, spec, function(err, by_main)
            if (err ~= nil) then return cb(err); end
            for i = 1, #mains do mains[i][name] = (by_main and by_main[mains[i][source_key]]) or {}; end
            cb();
        end);
        return;
    end

    if (rel.kind == "belongs_to") then
        local other_key = rel.otherKey or target.primary_key;
        local state = { table = target.table, wheres = { { column = other_key, op = "IN", value = keys } } };
        if (spec and spec.wheres) then for i = 1, #spec.wheres do state.wheres[#state.wheres + 1] = spec.wheres[i]; end end
        local statement, params = sqlmod.select(state, d);
        self:_trace(statement, params);
        self:_raw_query(statement, params, function(err, rows)
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
    if (spec and spec.wheres) then for i = 1, #spec.wheres do state.wheres[#state.wheres + 1] = spec.wheres[i]; end end
    if (spec and spec.orders and #spec.orders > 0) then state.orders = spec.orders; end
    local statement, params = sqlmod.select(state, d);
    self:_trace(statement, params);
    self:_raw_query(statement, params, function(err, rows)
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
            if (spec and spec.limit and rel.kind == "has_many") then g = slice(g, spec.offset, spec.limit); end
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
---@param includes table<string, table> include spec map (name -> { wheres, orders, limit, offset, children })
---@param single boolean
---@return NormPromise
function NormOrm:_query_with_includes(model, state, includes, single)
    local d = self.adapter:get_dialect();
    local statement, params = sqlmod.select(state, d);
    self:_trace(statement, params);
    return self.provider.new(function(resolve, reject)
        self:_raw_query(statement, params or {}, function(err, rows)
            if (err ~= nil) then return reject(err); end
            rows = rows or {};
            local records = {};
            for i = 1, #rows do records[i] = model:wrap(rows[i]); end
            if (#records == 0) then
                return resolve(single and nil or records);
            end
            local ok, perr = pcall(function()
                self:_load_includes(model, records, includes, function(e)
                    if (e ~= nil) then return reject(e); end
                    resolve(single and records[1] or records);
                end);
            end);
            if (not ok) then reject(perr); end
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
---@param options? NormDefineOptions
---@return NormModel
function NormOrm:define(table_name, schema, options)
    utils.assert(not self.models[table_name],
        ("Norm: model '%s' is already defined"):format(table_name));
    local model = model_module.define(self, table_name, schema, options);
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
            if (index > #statements) then
                self:_flush_ready(); -- schema prepared: release any queued data ops
                return resolve(true);
            end
            self:_trace(statements[index], {});
            self.adapter:raw_execute(statements[index], {}, function(err)
                if (err ~= nil) then return reject(err); end
                step();
            end);
        end
        step();
    end);
end

--- Schema-change builder handed to a migration's `up(m)`. Each call appends a DDL
--- statement (dialect-aware) to be run in order. Chainable.
---@param d NormDialect
---@return table
local function make_migration_builder(d)
    local b = { _statements = {} };
    local function push(stmt) b._statements[#b._statements + 1] = stmt; end
    --- Add a column. `descriptor` is a `Norm.types.*` value.
    function b:add_column(table_name, name, descriptor)
        local col = utils.copy(descriptor); col.name = name;
        push(sqlmod.add_column(table_name, col, d)); return self;
    end
    function b:drop_column(table_name, name) push(sqlmod.drop_column(table_name, name, d)); return self; end
    function b:rename_column(table_name, from, to) push(sqlmod.rename_column(table_name, from, to, d)); return self; end
    --- `opts.unique` for a UNIQUE index.
    function b:add_index(table_name, index_name, columns, opts)
        opts = opts or {};
        push(sqlmod.add_index(table_name, index_name, columns, opts.unique == true, d)); return self;
    end
    function b:drop_index(index_name, table_name) push(sqlmod.drop_index(index_name, table_name, d)); return self; end
    function b:drop_table(table_name) push(sqlmod.drop_table(table_name, d)); return self; end
    --- Raw DDL escape hatch (run verbatim).
    function b:raw(statement) push(statement); return self; end
    return b;
end

---@class NormMigration
---@field id string Unique, stable identifier (applied once). Order them by sorting-friendly ids.
---@field up fun(m: table) Receives the schema builder; record changes via m:add_column(...) etc.

--- Run pending schema migrations in order, recording applied ones in a
--- `norm_migrations` table so each runs exactly once. Idempotent: re-running
--- applies only what's new. Resolves with the list of ids applied this run.
--- ```lua
---     db:migrate({
---         { id = "2026_06_25_add_last_seen", up = function(m)
---             m:add_column("players", "last_seen", Norm.types.datetime())
---             m:add_index("players", "idx_players_account", { "account_id" }, { unique = true })
---         end },
---     }):await()
--- ```
---@param migrations NormMigration[]
---@return NormPromise promise resolving to string[] (applied ids)
function NormOrm:migrate(migrations)
    utils.assert(type(migrations) == "table", "Norm: migrate() needs a list of migrations");
    for i = 1, #migrations do
        utils.assert(type(migrations[i].id) == "string", "Norm: each migration needs a string `id`");
        utils.assert(type(migrations[i].up) == "function", "Norm: each migration needs an `up` function");
    end

    local d = self.adapter:get_dialect();
    local create = sqlmod.create_table("norm_migrations", {
        { name = "id", kind = "string", length = 191, primary = true, nullable = false },
        { name = "applied_at", kind = "datetime", nullable = true },
    }, d);
    local now;
    if (type(os) == "table" and type(os.date) == "function") then
        local ok, s = pcall(os.date, "!%Y-%m-%d %H:%M:%S");
        if (ok) then now = s; end
    end

    return self.provider.new(function(resolve, reject)
        self:_trace(create, {});
        self.adapter:raw_execute(create, {}, function(cerr)
            if (cerr ~= nil) then return reject(cerr); end
            local list_sql = ("SELECT %s FROM %s"):format(d.quote("id"), d.quote("norm_migrations"));
            self:_trace(list_sql, {});
            self.adapter:raw_query(list_sql, {}, function(qerr, rows)
                if (qerr ~= nil) then return reject(qerr); end
                rows = rows or {};
                local done = {};
                for i = 1, #rows do done[rows[i].id] = true; end

                local applied, index = {}, 0;
                local function next_migration()
                    index = index + 1;
                    local mig = migrations[index];
                    -- NOTE: migrate() does NOT mark the ORM ready. It evolves an
                    -- existing schema (ALTERs) and does not create the model tables
                    -- — only sync() does, so only sync() flips readiness. Run sync()
                    -- before migrate().
                    if (not mig) then return resolve(applied); end
                    if (done[mig.id]) then return next_migration(); end

                    local builder = make_migration_builder(d);
                    local ok, err = pcall(mig.up, builder);
                    if (not ok) then return reject(err); end
                    local statements = builder._statements;

                    local si = 0;
                    local function run_next()
                        si = si + 1;
                        if (si > #statements) then
                            -- record this migration as applied.
                            local ins, iparams = sqlmod.insert("norm_migrations",
                                { id = mig.id, applied_at = now }, d);
                            self:_trace(ins, iparams);
                            self.adapter:raw_execute(ins, iparams, function(ierr)
                                if (ierr ~= nil) then return reject(ierr); end
                                applied[#applied + 1] = mig.id;
                                next_migration();
                            end);
                            return;
                        end
                        self:_trace(statements[si], {});
                        self.adapter:raw_execute(statements[si], {}, function(serr)
                            if (serr ~= nil) then return reject(serr); end
                            run_next();
                        end);
                    end
                    run_next();
                end
                next_migration();
            end);
        end);
    end);
end

return NormOrm;
