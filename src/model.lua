--- Model (table manager, class-level ops) and Record (one row, instance ops).
--- `Orm:define` builds a Model + a dedicated Record subclass per table.
local class = class;
local utils = require("utils");
local sqlmod = require("sql");
local NormQueryBuilder = require("query");

--- Current UTC timestamp as `YYYY-MM-DD HH:MM:SS` (portable across MySQL DATETIME
--- and SQLite TEXT). Returns nil if `os.date` is unavailable (timestamps skipped).
---@return string|nil
local function now_utc()
    if (type(os) ~= "table" or type(os.date) ~= "function") then return nil; end
    local ok, s = pcall(os.date, "!%Y-%m-%d %H:%M:%S");
    return ok and s or nil;
end

--- Merge two attribute tables (`b` overrides `a`), both optional.
---@param a? table<string, any>
---@param b? table<string, any>
---@return table<string, any>
local function merge_attrs(a, b)
    local out = {};
    if (a) then for k, v in pairs(a) do out[k] = v; end end
    if (b) then for k, v in pairs(b) do out[k] = v; end end
    return out;
end

--- Normalise an id argument into a flat array of key values. Accepts a single
--- value, an array of values, a single record, or an array of records (records
--- are reduced to their primary key).
---@param ids any
---@return any[]
local function to_id_list(ids)
    if (ids == nil) then return {}; end
    if (type(ids) ~= "table") then return { ids }; end
    if (ids.__model) then return { ids[ids.__model.primary_key] }; end -- a single record
    local out = {};
    for i = 1, #ids do
        local v = ids[i];
        if (type(v) == "table" and v.__model) then out[#out + 1] = v[v.__model.primary_key];
        else out[#out + 1] = v; end
    end
    return out;
end

---@class NormModelModule
---@field Record NormRecord
---@field Model NormModel
---@field define fun(orm: NormOrm, table_name: string, schema: table<string, NormColumn>): NormModel
local module = {};

-- ==========================================================================
-- Record: one database row.
-- ==========================================================================

--- A single row. Column values are plain fields (e.g. `record.name`).
---@class NormRecord: LightClass
---@field package __model NormModel
---@field package __persisted boolean
---@field [string] any Column values.
local NormRecord = class.new("NormRecord");

---@param model NormModel
---@param row? table<string, any>
---@param persisted? boolean
function NormRecord:__init(model, row, persisted)
    self.__model = model;
    self.__persisted = persisted == true;
    if (type(row) == "table") then
        -- `parse` decodes DB representations (boolean 1/0, json strings). It only
        -- applies to rows loaded from the database; a user-built record already
        -- holds Lua values, so they are stored verbatim.
        for i = 1, #model.columns do
            local col = model.columns[i];
            local value = row[col.name];
            if (value ~= nil) then
                self[col.name] = self.__persisted and model:parse(col, value) or value;
            end
        end
    end
    -- Snapshot persisted records so :save() can diff (dirty tracking).
    if (self.__persisted) then self:_snapshot(); end
end

--- Capture the current column values as the "clean" baseline for dirty tracking.
---@private
function NormRecord:_snapshot()
    local snap = {};
    local cols = self.__model.columns;
    for i = 1, #cols do
        local name = cols[i].name;
        snap[name] = self[name];
    end
    self.__original = snap;
end

--- Columns whose value differs from the snapshot (the write-set for an UPDATE).
--- Only non-nil values are returned (clearing to NULL via save() is unsupported,
--- as before). `json` columns holding a table are always considered changed —
--- their contents may have been mutated in place, which a reference check misses.
---@private
---@return table<string, any>
function NormRecord:_changed_columns()
    local model = self.__model;
    local original = self.__original or {};
    local out = {};
    for i = 1, #model.columns do
        local col = model.columns[i];
        local name = col.name;
        local cur = self[name];
        if (cur ~= nil) then
            if (col.kind == "json" and type(cur) == "table") then
                out[name] = cur;
            elseif (cur ~= original[name]) then
                out[name] = cur;
            end
        end
    end
    return out;
end

--- Plain `{ column = value }` table for this record (e.g. to serialise it).
--- ```lua
---     local data = user:to_table() --> { id = 1, name = "John", ... }
--- ```
---@return table<string, any>
function NormRecord:to_table()
    local out = {};
    local cols = self.__model.columns;
    for i = 1, #cols do
        local name = cols[i].name;
        if (self[name] ~= nil) then out[name] = self[name]; end
    end
    return out;
end

---@private
---@return table<string, any>
function NormRecord:_persistable()
    local out = {};
    local cols = self.__model.columns;
    for i = 1, #cols do
        local name = cols[i].name;
        if (self[name] ~= nil) then out[name] = self[name]; end
    end
    return out;
end

--- Callback-based INSERT primitive (stamps timestamps, encodes, reads the new id
--- via RETURNING when supported, snapshots). Shared by `:save()` and the
--- `*OrCreate` helpers so they compose without relying on promise chaining.
---@private
---@param cb fun(err: any)
function NormRecord:_do_insert(cb)
    local model = self.__model;
    local orm = model.orm;
    local d = orm.adapter:get_dialect();
    local ts = model.timestamps;

    -- stamp created_at / updated_at unless the caller set them explicitly.
    if (ts) then
        local nowv = now_utc();
        if (nowv ~= nil) then
            if (ts.created and self[ts.created] == nil) then self[ts.created] = nowv; end
            if (ts.updated and self[ts.updated] == nil) then self[ts.updated] = nowv; end
        end
    end

    local data = self:_persistable();
    if (model.autoincrement_pk) then data[model.primary_key] = nil; end

    -- INSERT ... RETURNING (SQLite >= 3.35 / PostgreSQL / MariaDB) reads the new id
    -- atomically (pool-safe) — routed as a query, since it returns a row.
    local can_return = model.autoincrement_pk
        and type(orm.adapter.supports_returning) == "function"
        and orm.adapter:supports_returning();

    if (can_return) then
        local statement, params = sqlmod.insert(model.table, model:_encode_write(data), d, model.primary_key);
        orm:_trace(statement, params);
        orm:_raw_query(statement, params, function(err, rows)
            if (err ~= nil) then return cb(err); end
            rows = rows or {};
            self.__persisted = true;
            local row = rows[1];
            if (row and row[model.primary_key] ~= nil) then
                self[model.primary_key] = row[model.primary_key];
            end
            self:_snapshot();
            cb(nil);
        end);
        return;
    end

    local statement, params = sqlmod.insert(model.table, model:_encode_write(data), d);
    orm:_trace(statement, params);
    orm:_raw_execute(statement, params, function(err, res)
        if (err ~= nil) then return cb(err); end
        self.__persisted = true;
        if (model.autoincrement_pk and res and res.insertId ~= nil) then
            self[model.primary_key] = res.insertId;
        end
        self:_snapshot();
        cb(nil);
    end);
end

--- Callback-based UPDATE primitive (dirty tracking + updated_at bump). Calls
--- `cb(nil)` with NO query when nothing changed. Shared by `:save()` /
--- `updateOrCreate`.
---@private
---@param cb fun(err: any)
function NormRecord:_do_update(cb)
    local model = self.__model;
    local orm = model.orm;
    local d = orm.adapter:get_dialect();
    local ts = model.timestamps;
    local pk = model.primary_key;
    utils.assert(pk, ("model '%s' has no primary key; cannot update"):format(model.table));

    local changed = self:_changed_columns();
    changed[pk] = nil; -- never update the primary key
    if (next(changed) == nil) then return cb(nil); end -- nothing changed: no query
    if (ts and ts.updated) then
        local nowv = now_utc();
        if (nowv ~= nil) then self[ts.updated] = nowv; changed[ts.updated] = nowv; end
    end

    local state = { table = model.table, wheres = { { column = pk, op = "=", value = self[pk] } } };
    local statement, params = sqlmod.update(state, model:_encode_write(changed), d);
    orm:_trace(statement, params);
    orm:_raw_execute(statement, params, function(err)
        if (err ~= nil) then return cb(err); end
        self:_snapshot();
        cb(nil);
    end);
end

--- Persist the record: INSERT if new, UPDATE (only changed columns) if it was
--- loaded from the database. Resolves with the record itself.
--- ```lua
---     local user = User:find(1):await()
---     user.coins = user.coins + 50
---     user:save():await()
--- ```
---@return NormRecordPromise promise resolving to NormRecord (self)
function NormRecord:save()
    local model = self.__model;
    local orm = model.orm;
    if (self.__persisted) then
        return orm.provider.new(function(resolve, reject)
            self:_do_update(function(err)
                if (err ~= nil) then return reject(err); end
                resolve(self);
            end);
        end);
    end
    return orm.provider.new(function(resolve, reject)
        self:_do_insert(function(err)
            if (err ~= nil) then return reject(err); end
            resolve(self);
        end);
    end);
end

--- DELETE this record from the database by its primary key. Resolves with the
--- record (now flagged as not persisted, so a later `:save()` re-inserts it).
--- ```lua
---     local user = User:find(1):await()
---     user:delete():await()
--- ```
---@return NormRecordPromise promise resolving to NormRecord (self)
function NormRecord:delete()
    local model = self.__model;
    utils.assert(model.primary_key, ("model '%s' has no primary key; cannot delete"):format(model.table));
    local d = model.orm.adapter:get_dialect();
    local pk = model.primary_key;
    local state = { table = model.table, wheres = { { column = pk, op = "=", value = self[pk] } } };
    local statement, params = sqlmod.delete(state, d);
    return model.orm:_execute_map(statement, params, function()
        self.__persisted = false;
        return self;
    end);
end

--- Resolve a `belongs_to_many` relation into its pivot coordinates (asserts the
--- relation exists and is many-to-many).
---@private
---@param name string
---@return table info
function NormRecord:_pivot_info(name)
    local model = self.__model;
    local orm = model.orm;
    local rel = model.relations[name];
    utils.assert(rel and rel.kind == "belongs_to_many",
        ("model '%s' has no belongs_to_many relation '%s'"):format(model.table, name));
    local target = orm:model(rel.target);
    utils.assert(target, ("relation '%s': target model '%s' is not defined"):format(name, rel.target));
    return {
        orm = orm,
        d = orm.adapter:get_dialect(),
        through = rel.through or utils.default_pivot(model.table, target.table),
        main = rel.key,                                              -- pivot FK -> this model
        other = rel.otherKey or (utils.singularize(target.table) .. "_id"), -- pivot FK -> target
        local_value = self[rel.localKey or model.primary_key],
    };
end

--- Link this record to one or more `target` rows of a `belongs_to_many` relation
--- by inserting pivot rows. `ids` is a key value, an array of them, or record(s).
--- `pivot` adds extra columns to each pivot row. Resolves with the number attached.
--- ```lua
---     user:attach("roles", { 1, 2 }):await()
---     user:attach("roles", role, { granted_by = adminId }):await()
--- ```
---@param name string Relation name.
---@param ids any Key value(s) or record(s) on the target side.
---@param pivot? table<string, any> Extra pivot-row columns.
---@return NormNumberPromise promise resolving to the number of rows inserted
function NormRecord:attach(name, ids, pivot)
    local info = self:_pivot_info(name);
    local list = to_id_list(ids);
    local orm = info.orm;
    return orm.provider.new(function(resolve, reject)
        if (info.local_value == nil) then
            return reject("[norm] attach: this record has no key value yet (save it first)");
        end
        if (#list == 0) then return resolve(0); end
        local i = 0;
        local function step()
            i = i + 1;
            if (i > #list) then return resolve(#list); end
            local row = { [info.main] = info.local_value, [info.other] = list[i] };
            if (pivot) then for k, v in pairs(pivot) do row[k] = v; end end
            local statement, params = sqlmod.insert(info.through, row, info.d);
            orm:_trace(statement, params);
            orm:_raw_execute(statement, params, function(err)
                if (err ~= nil) then return reject(err); end
                step();
            end);
        end
        step();
    end);
end

--- Unlink this record from `target` rows of a `belongs_to_many` relation by
--- deleting pivot rows. With `ids` -> only those; without -> ALL links. Resolves
--- with the affected row count.
--- ```lua
---     user:detach("roles", { 1 }):await()  -- remove one link
---     user:detach("roles"):await()          -- remove every link
--- ```
---@param name string Relation name.
---@param ids? any Key value(s) or record(s); omit to detach everything.
---@return NormNumberPromise promise resolving to the number of rows deleted
function NormRecord:detach(name, ids)
    local info = self:_pivot_info(name);
    local orm = info.orm;
    local list = (ids ~= nil) and to_id_list(ids) or nil;
    return orm.provider.new(function(resolve, reject)
        if (info.local_value == nil) then return resolve(0); end
        if (list and #list == 0) then return resolve(0); end -- explicit empty set: no-op
        local wheres = { { column = info.main, op = "=", value = info.local_value } };
        if (list) then wheres[#wheres + 1] = { column = info.other, op = "IN", value = list }; end
        local statement, params = sqlmod.delete({ table = info.through, wheres = wheres }, info.d);
        orm:_trace(statement, params);
        orm:_raw_execute(statement, params, function(err, res)
            if (err ~= nil) then return reject(err); end
            resolve((res and res.affectedRows) or 0);
        end);
    end);
end

--- Make this record's pivot links for a `belongs_to_many` relation exactly match
--- `ids`: attach the missing, detach the extra, leave the rest. Resolves with
--- `{ attached = n, detached = m }`.
--- ```lua
---     user:sync_pivot("roles", { 1, 2, 3 }):await()
--- ```
---@param name string Relation name.
---@param ids any Key value(s) or record(s) that should remain linked.
---@return NormPromise promise resolving to { attached: number, detached: number }
function NormRecord:sync_pivot(name, ids)
    local info = self:_pivot_info(name);
    local orm = info.orm;
    local desired = to_id_list(ids);
    return orm.provider.new(function(resolve, reject)
        if (info.local_value == nil) then
            return reject("[norm] sync_pivot: this record has no key value yet (save it first)");
        end
        local sel, sparams = sqlmod.select({
            table = info.through, columns = { info.other },
            wheres = { { column = info.main, op = "=", value = info.local_value } },
        }, info.d);
        orm:_trace(sel, sparams);
        orm:_raw_query(sel, sparams, function(err, rows)
            if (err ~= nil) then return reject(err); end
            rows = rows or {};
            local current, desired_set = {}, {};
            for i = 1, #rows do current[rows[i][info.other]] = true; end
            for i = 1, #desired do desired_set[desired[i]] = true; end
            local to_attach, to_detach = {}, {};
            for i = 1, #desired do if (not current[desired[i]]) then to_attach[#to_attach + 1] = desired[i]; end end
            for id in pairs(current) do if (not desired_set[id]) then to_detach[#to_detach + 1] = id; end end

            local function do_attach()
                local i = 0;
                local function step()
                    i = i + 1;
                    if (i > #to_attach) then return resolve({ attached = #to_attach, detached = #to_detach }); end
                    local statement, params = sqlmod.insert(info.through,
                        { [info.main] = info.local_value, [info.other] = to_attach[i] }, info.d);
                    orm:_trace(statement, params);
                    orm:_raw_execute(statement, params, function(ierr)
                        if (ierr ~= nil) then return reject(ierr); end
                        step();
                    end);
                end
                step();
            end

            if (#to_detach == 0) then return do_attach(); end
            local statement, params = sqlmod.delete({
                table = info.through,
                wheres = {
                    { column = info.main, op = "=", value = info.local_value },
                    { column = info.other, op = "IN", value = to_detach },
                },
            }, info.d);
            orm:_trace(statement, params);
            orm:_raw_execute(statement, params, function(derr)
                if (derr ~= nil) then return reject(derr); end
                do_attach();
            end);
        end);
    end);
end

--- Re-read this record's columns from the database (discarding local changes).
--- Resolves with the record.
--- ```lua
---     user:reload():await()
--- ```
---@return NormRecordPromise promise resolving to NormRecord (self)
function NormRecord:reload()
    local model = self.__model;
    utils.assert(model.primary_key, ("model '%s' has no primary key; cannot reload"):format(model.table));
    local d = model.orm.adapter:get_dialect();
    local pk = model.primary_key;
    local state = { table = model.table, limit = 1, wheres = { { column = pk, op = "=", value = self[pk] } } };
    local statement, params = sqlmod.select(state, d);
    return model.orm:_query_map(statement, params, function(rows)
        local row = rows[1];
        if (row) then
            for i = 1, #model.columns do
                local col = model.columns[i];
                if (row[col.name] ~= nil) then
                    self[col.name] = model:parse(col, row[col.name]);
                end
            end
        end
        self:_snapshot(); -- reloaded values are the new clean baseline
        return self;
    end);
end

--- Lazily load a declared relation, cache it on `self[name]`, and resolve with
--- it. Returns a single record (belongs_to / has_one), nil, or an array (has_many).
--- ```lua
---     local author = post:load("author"):await()  -- also sets post.author
---     local posts  = user:load("posts"):await()   -- also sets user.posts (array)
--- ```
---@param name string
---@return NormPromise promise resolving to NormRecord | NormRecord[] | nil
function NormRecord:load(name)
    local model = self.__model;
    local orm = model.orm;
    local rel = model.relations[name];
    utils.assert(rel, ("model '%s' has no relation '%s'"):format(model.table, name));
    local target = orm:model(rel.target);
    utils.assert(target, ("relation '%s': target model '%s' is not defined"):format(name, rel.target));
    local d = orm.adapter:get_dialect();

    if (rel.kind == "belongs_to_many") then
        -- Two-step batched fetch (pivot -> targets); cache the array on self[name].
        local local_key = rel.localKey or model.primary_key;
        local local_value = self[local_key];
        if (local_value == nil) then
            self[name] = {};
            return orm.provider.resolve({});
        end
        return orm.provider.new(function(resolve, reject)
            orm:_m2m_fetch(model, rel, { local_value }, function(err, by_main)
                if (err ~= nil) then return reject(err); end
                local list = (by_main and by_main[local_value]) or {};
                self[name] = list;
                resolve(list);
            end);
        end);
    end

    if (rel.kind == "belongs_to") then
        local other_key = rel.otherKey or target.primary_key;
        local fk = self[rel.key];
        if (fk == nil) then
            self[name] = nil;
            return orm.provider.resolve(nil);
        end
        local state = { table = target.table, limit = 1, wheres = { { column = other_key, op = "=", value = fk } } };
        local statement, params = sqlmod.select(state, d);
        return orm:_query_map(statement, params, function(rows)
            local rec = rows[1] and target:wrap(rows[1]) or nil;
            self[name] = rec;
            return rec;
        end);
    end

    -- has_one / has_many
    local local_key = rel.localKey or model.primary_key;
    local local_value = self[local_key];
    if (local_value == nil) then
        self[name] = (rel.kind == "has_many") and {} or nil;
        return orm.provider.resolve(self[name]);
    end
    local state = { table = target.table, wheres = { { column = rel.key, op = "=", value = local_value } } };
    if (rel.kind == "has_one") then state.limit = 1; end
    local statement, params = sqlmod.select(state, d);
    return orm:_query_map(statement, params, function(rows)
        if (rel.kind == "has_one") then
            local rec = rows[1] and target:wrap(rows[1]) or nil;
            self[name] = rec;
            return rec;
        end
        local list = {};
        for i = 1, #rows do list[i] = target:wrap(rows[i]); end
        self[name] = list;
        return list;
    end);
end

module.Record = NormRecord;

-- ==========================================================================
-- Model: one table.
-- ==========================================================================

---@class NormModel: LightClass
---@field orm NormOrm
---@field table string
---@field columns NormColumn[]
---@field columns_by_name table<string, NormColumn>
---@field relations table<string, NormRelation>
---@field primary_key? string
---@field autoincrement_pk boolean
---@field record_class NormRecord
---@field timestamps? {created: string, updated: string} Auto-managed timestamp columns (nil if disabled).
---@overload fun(orm: NormOrm, table_name: string, columns: NormColumn[], record_class: NormRecord): NormModel
local NormModel = class.new("NormModel");

---@param orm NormOrm
---@param table_name string
---@param columns NormColumn[]
---@param record_class NormRecord
function NormModel:__init(orm, table_name, columns, record_class)
    self.orm = orm;
    self.table = table_name;
    self.columns = columns;
    self.columns_by_name = {};
    self.relations = {};
    self.primary_key = nil;
    self.autoincrement_pk = false;
    self.record_class = record_class;
    for i = 1, #columns do
        local c = columns[i];
        self.columns_by_name[c.name] = c;
        if (c.primary) then
            self.primary_key = c.name;
            self.autoincrement_pk = c.autoincrement == true;
        end
    end
end

--- Convert a raw driver value into a Lua value for the given column (decode).
---@param column NormColumn
---@param value any
---@return any
function NormModel:parse(column, value)
    if (value == nil) then return nil; end
    if (column.kind == "boolean") then
        if (type(value) == "number") then return value ~= 0; end
        if (type(value) == "boolean") then return value; end
        return value == "1" or value == "true";
    end
    if (column.kind == "json") then
        -- Some drivers (e.g. mysql2 for JSON columns) already return a table; only
        -- decode raw strings. On failure keep the raw value rather than throwing.
        if (type(value) == "string") then
            local ok, decoded = pcall(self.orm.json.decode, value);
            if (ok) then return decoded; end
        end
        return value;
    end
    return value;
end

--- Convert a Lua value into something storable for the given column (encode).
--- Only `json` tables are transformed; a value already a string is passed
--- through (so a pre-encoded string is never double-encoded).
---@param column NormColumn
---@param value any
---@return any
function NormModel:serialize(column, value)
    if (column.kind == "json" and type(value) == "table") then
        return self.orm.json.encode(value);
    end
    return value;
end

--- Encode a `{ column = value }` write payload (INSERT/UPDATE) column by column.
---@private
---@param data table<string, any>
---@return table<string, any>
function NormModel:_encode_write(data)
    local out = {};
    for k, v in pairs(data) do
        local col = self.columns_by_name[k];
        out[k] = col and self:serialize(col, v) or v;
    end
    return out;
end

--- Wrap a DB row into a persisted record.
---@param row table<string, any>
---@return NormRecord
function NormModel:wrap(row) return self.record_class(self, row, true); end

--- Build an *unsaved* record from a data table (nothing hits the database until
--- you call `:save()`). Useful to prepare a record then persist it later.
--- ```lua
---     local user = User:build({ name = "John" })
---     user.email = "john@x.io"
---     user:save():await()
--- ```
---@param data table<string, any>
---@return NormRecord
function NormModel:build(data) return self.record_class(self, data, false); end

--- Build and immediately INSERT a record. Resolves with the saved record, whose
--- auto-increment primary key is populated.
--- ```lua
---     local user = User:create({ name = "John", email = "john@x.io" }):await()
---     print(user.id) --> 1
--- ```
---@param data table<string, any>
---@return NormRecordPromise promise resolving to NormRecord
function NormModel:create(data) return self:build(data):save(); end

--- Start a chainable query against this model's table.
--- ```lua
---     local admins = User:query():where("admin", true):order("name"):all():await()
--- ```
---@return NormQueryBuilder
function NormModel:query() return NormQueryBuilder(self); end

--- Shortcut for `:query():where(...)`. Accepts `(col, value)`, `(col, op, value)`
--- or a `{ col = value }` table.
--- ```lua
---     local rich = User:where("coins", ">", 100):all():await()
---     local john = User:where({ name = "John" }):first():await()
--- ```
---@param column string|table<string, any>
---@param op? string
---@param value? any
---@return NormQueryBuilder
function NormModel:where(...) return self:query():where(...); end

---@param column string
---@param dir? "ASC"|"DESC"
---@return NormQueryBuilder
function NormModel:order(...) return self:query():order(...); end

---@param n number
---@return NormQueryBuilder
function NormModel:limit(...) return self:query():limit(...); end

---@param ... string|string[]
---@return NormQueryBuilder
function NormModel:select(...) return self:query():select(...); end

---@param expr string
---@return NormQueryBuilder
function NormModel:select_raw(expr) return self:query():select_raw(expr); end

---@param table_name string
---@param first string
---@param op string
---@param second? string
---@return NormQueryBuilder
function NormModel:join(...) return self:query():join(...); end

---@param table_name string
---@param first string
---@param op string
---@param second? string
---@return NormQueryBuilder
function NormModel:left_join(...) return self:query():left_join(...); end

---@param ... string
---@return NormQueryBuilder
function NormModel:group_by(...) return self:query():group_by(...); end

---@param expr string
---@param op? string
---@param value? any
---@return NormQueryBuilder
function NormModel:having(...) return self:query():having(...); end

--- Resolves with every record in the table.
--- ```lua
---     local users = User:all():await()
---     for _, u in ipairs(users) do print(u.name) end
--- ```
---@return NormRecordListPromise promise resolving to NormRecord[]
function NormModel:all() return self:query():all(); end

--- Resolves with the total row count of the table.
--- ```lua
---     local total = User:count():await()
--- ```
---@return NormNumberPromise promise resolving to number
function NormModel:count() return self:query():count(); end

--- SUM of a column across the whole table.
--- ```lua
---     local total = User:sum("coins"):await()
--- ```
---@param column string
---@return NormNumberPromise promise resolving to number
function NormModel:sum(column) return self:query():sum(column); end

--- AVG of a column across the whole table.
---@param column string
---@return NormNumberPromise promise resolving to number
function NormModel:avg(column) return self:query():avg(column); end

--- MIN of a column across the whole table.
---@param column string
---@return NormNumberPromise promise resolving to the column's value type
function NormModel:min(column) return self:query():min(column); end

--- MAX of a column across the whole table.
---@param column string
---@return NormNumberPromise promise resolving to the column's value type
function NormModel:max(column) return self:query():max(column); end

--- Find a single record by its primary key. Resolves with the record or nil.
--- ```lua
---     local user = User:find(1):await()
---     if (user) then print(user.name) end
--- ```
---@param pk any
---@return NormRecordOrNilPromise promise resolving to NormRecord|nil
function NormModel:find(pk)
    utils.assert(self.primary_key, ("model '%s' has no primary key; cannot find by id"):format(self.table));
    return self:query():where(self.primary_key, pk):first();
end

--- Find the first record matching a `{ column = value }` filter (ANDed).
--- ```lua
---     local user = User:find_by({ email = "john@x.io" }):await()
--- ```
---@param filter table<string, any>
---@return NormRecordOrNilPromise promise resolving to NormRecord|nil
function NormModel:find_by(filter)
    return self:query():where(filter):first();
end

--- Callback-based "first row matching an ANDed `{ col = value }` filter". Used by
--- the `*OrCreate` helpers (which must compose without promise chaining).
---@private
---@param attributes table<string, any>
---@param cb fun(err: any, record?: NormRecord|nil)
function NormModel:_find_by_attrs(attributes, cb)
    local orm = self.orm;
    local d = orm.adapter:get_dialect();
    local state = { table = self.table, limit = 1, wheres = {} };
    for _, k in ipairs(utils.sorted_keys(attributes)) do
        state.wheres[#state.wheres + 1] = { column = k, op = "=", value = attributes[k] };
    end
    local statement, params = sqlmod.select(state, d);
    orm:_trace(statement, params);
    orm:_raw_query(statement, params, function(err, rows)
        if (err ~= nil) then return cb(err); end
        rows = rows or {};
        cb(nil, rows[1] and self:wrap(rows[1]) or nil);
    end);
end

--- Find the first record matching `attributes`; if none exists, return an
--- **unsaved** record built from `attributes` merged with `values` (nothing is
--- written until you `:save()` it). Resolves with the record.
--- ```lua
---     local u = User:find_or_new({ email = "a@b.c" }, { name = "Anon" }):await()
---     if (not u.__persisted) then u:save():await() end
--- ```
---@param attributes table<string, any> Columns to match on.
---@param values? table<string, any> Extra columns for a freshly built record.
---@return NormRecordOrNilPromise promise resolving to NormRecord
function NormModel:find_or_new(attributes, values)
    local model = self;
    return self.orm.provider.new(function(resolve, reject)
        model:_find_by_attrs(attributes, function(err, record)
            if (err ~= nil) then return reject(err); end
            resolve(record or model:build(merge_attrs(attributes, values)));
        end);
    end);
end

--- Find the first record matching `attributes`; if none exists, INSERT one built
--- from `attributes` merged with `values`. Resolves with the (existing or newly
--- created) record. Not atomic: a unique constraint is the only true guard
--- against a concurrent double-insert.
--- ```lua
---     local player = Player:find_or_create({ account_id = id }, { name = "Guest" }):await()
--- ```
---@param attributes table<string, any> Columns to match on (and seed a new record).
---@param values? table<string, any> Extra columns applied only when creating.
---@return NormRecordPromise promise resolving to NormRecord
function NormModel:find_or_create(attributes, values)
    local model = self;
    return self.orm.provider.new(function(resolve, reject)
        model:_find_by_attrs(attributes, function(err, record)
            if (err ~= nil) then return reject(err); end
            if (record) then return resolve(record); end
            local fresh = model:build(merge_attrs(attributes, values));
            fresh:_do_insert(function(ierr)
                if (ierr ~= nil) then return reject(ierr); end
                resolve(fresh);
            end);
        end);
    end);
end

--- Find the first record matching `attributes` and UPDATE it with `values`; if
--- none exists, INSERT one from `attributes` merged with `values`. Resolves with
--- the record. (Application-level upsert; not atomic.)
--- ```lua
---     local p = Player:update_or_create({ account_id = id }, { last_seen = now, name = nick }):await()
--- ```
---@param attributes table<string, any> Columns to match on (and seed a new record).
---@param values? table<string, any> Columns to write (on both update and create).
---@return NormRecordPromise promise resolving to NormRecord
function NormModel:update_or_create(attributes, values)
    local model = self;
    return self.orm.provider.new(function(resolve, reject)
        model:_find_by_attrs(attributes, function(err, record)
            if (err ~= nil) then return reject(err); end
            if (record) then
                if (values) then for k, v in pairs(values) do record[k] = v; end end
                record:_do_update(function(uerr)
                    if (uerr ~= nil) then return reject(uerr); end
                    resolve(record);
                end);
                return;
            end
            local fresh = model:build(merge_attrs(attributes, values));
            fresh:_do_insert(function(ierr)
                if (ierr ~= nil) then return reject(ierr); end
                resolve(fresh);
            end);
        end);
    end);
end

--- **Atomic** upsert: a single `INSERT ... ON CONFLICT/ON DUPLICATE KEY UPDATE`
--- statement (race-safe, unlike `find_or_create`). `data` is inserted; if a row
--- with the same `opts.conflict` columns exists it is updated instead. The write
--- is one statement; the canonical row is then read back and resolved as a record.
---
--- The conflict columns MUST carry a UNIQUE (or PRIMARY KEY) constraint — that is
--- what the database matches on. `opts.conflict` defaults to the primary key;
--- `opts.update` defaults to every written column except the conflict columns (and
--- `created_at`, preserved on an existing row).
--- ```lua
---     -- create the player, or update name/last_seen if account_id already exists
---     local p = Player:upsert(
---         { account_id = id, name = nick, last_seen = ts },
---         { conflict = { "account_id" } }
---     ):await()
--- ```
---@param data table<string, any> Columns to insert (and update on conflict).
---@param opts? {conflict?: string[], update?: string[]}
---@return NormRecordOrNilPromise promise resolving to NormRecord
function NormModel:upsert(data, opts)
    opts = opts or {};
    local model = self;
    local orm = self.orm;
    local d = orm.adapter:get_dialect();
    local ts = model.timestamps;

    local conflict = opts.conflict;
    if (conflict == nil and model.primary_key) then conflict = { model.primary_key }; end
    utils.assert(type(conflict) == "table" and #conflict > 0,
        ("upsert on '%s' needs conflict columns (opts.conflict) or a primary key"):format(model.table));

    -- write payload (+ timestamps for the INSERT branch).
    local write = {};
    for k, v in pairs(data) do write[k] = v; end
    if (ts) then
        local nowv = now_utc();
        if (nowv ~= nil) then
            if (ts.created and write[ts.created] == nil) then write[ts.created] = nowv; end
            if (ts.updated and write[ts.updated] == nil) then write[ts.updated] = nowv; end
        end
    end

    -- update-set: all written columns except the conflict target and created_at
    -- (so an existing row keeps its original created_at).
    local conflict_set = {};
    for _, c in ipairs(conflict) do conflict_set[c] = true; end
    local update_cols = opts.update;
    if (update_cols == nil) then
        update_cols = {};
        for _, name in ipairs(utils.sorted_keys(write)) do
            if (not conflict_set[name] and not (ts and name == ts.created)) then
                update_cols[#update_cols + 1] = name;
            end
        end
    end

    local statement, params = sqlmod.upsert(model.table, model:_encode_write(write), conflict, update_cols, d);

    return orm.provider.new(function(resolve, reject)
        orm:_trace(statement, params);
        orm:_raw_execute(statement, params, function(err)
            if (err ~= nil) then return reject(err); end
            -- the write is atomic; read the canonical row back by the conflict key.
            local state = { table = model.table, limit = 1, wheres = {} };
            for _, c in ipairs(conflict) do
                state.wheres[#state.wheres + 1] = { column = c, op = "=", value = write[c] };
            end
            local sel, sparams = sqlmod.select(state, d);
            orm:_trace(sel, sparams);
            orm:_raw_query(sel, sparams, function(serr, rows)
                if (serr ~= nil) then return reject(serr); end
                rows = rows or {};
                resolve(rows[1] and model:wrap(rows[1]) or nil);
            end);
        end);
    end);
end

--- Create this model's table (CREATE TABLE IF NOT EXISTS). Prefer `orm:sync()`
--- to create every model at once (it also orders tables by their foreign-key
--- dependencies). Emits this model's `belongsTo` foreign keys when enabled.
--- Resolves with true.
--- ```lua
---     User:sync():await()
--- ```
---@return NormBooleanPromise promise resolving to true
function NormModel:sync()
    local orm = self.orm;
    local d = orm.adapter:get_dialect();
    local fks = orm:_should_emit_fk(d) and orm:_collect_foreign_keys(self) or nil;
    local statement = sqlmod.create_table(self.table, self.columns, d, fks);
    orm:_trace(statement, {});
    -- Schema prep: bypass the readiness queue (like orm:sync) and flush on success.
    return orm.provider.new(function(resolve, reject)
        orm.adapter:raw_execute(statement, {}, function(err)
            if (err ~= nil) then return reject(err); end
            orm:_flush_ready();
            resolve(true);
        end);
    end);
end

module.Model = NormModel;

-- ==========================================================================
-- define()
-- ==========================================================================

local record_counter = 0;
---@param table_name string
---@return string
local function unique_record_name(table_name)
    record_counter = record_counter + 1;
    return ("NormRecord_%s_%d"):format(table_name, record_counter);
end

--- Options controlling how a model behaves (3rd arg of `define`).
---@class NormDefineOptions
---@field timestamps? boolean|{created?: string, updated?: string} Auto-manage created_at/updated_at (Norm-side, UTC; portable across SQLite/MySQL). `true` uses the default names; pass a table to rename.

--- Build a Model (+ dedicated Record subclass) from a schema definition.
---@param orm NormOrm
---@param table_name string
---@param schema table<string, NormColumn>
---@param options? NormDefineOptions
---@return NormModel
function module.define(orm, table_name, schema, options)
    options = options or {};
    utils.assert(type(table_name) == "string", "define: table name must be a string");
    utils.assert(type(schema) == "table", "define: schema must be a table");

    -- Split the schema into columns and relations.
    local columns, relations = {}, {};
    for _, name in ipairs(utils.sorted_keys(schema)) do
        local def = schema[name];
        if (type(def) == "table" and def.__relation) then
            local rel = utils.copy(def);
            rel.name = name;
            relations[name] = rel;
        else
            utils.assert(type(def) == "table" and def.kind,
                ("define: column '%s' is not a valid Norm.types descriptor"):format(name));
            local col = utils.copy(def);
            col.name = name;
            columns[#columns + 1] = col;
        end
    end

    -- Timestamps: add managed `datetime` columns (unless already declared).
    local timestamps = nil;
    if (options.timestamps) then
        local conf = (type(options.timestamps) == "table") and options.timestamps or {};
        timestamps = { created = conf.created or "created_at", updated = conf.updated or "updated_at" };
        local function ensure_ts_column(name)
            for i = 1, #columns do if (columns[i].name == name) then return; end end
            columns[#columns + 1] = { kind = "datetime", nullable = true, name = name };
        end
        ensure_ts_column(timestamps.created);
        ensure_ts_column(timestamps.updated);
    end

    -- Stable order: primary key(s) first, then alphabetical.
    table.sort(columns, function(a, b)
        if (a.primary and not b.primary) then return true; end
        if (b.primary and not a.primary) then return false; end
        return a.name < b.name;
    end);

    -- light-class resolves a constructor with rawget(cls, "__init") (no inheritance
    -- walk), so a Record subclass must define its own __init forwarding to the base.
    -- This also lets users attach custom methods to a model's records.
    local record_class = class.extend(unique_record_name(table_name), NormRecord);
    function record_class:__init(model, row, persisted)
        NormRecord.__init(self, model, row, persisted);
    end

    local model = NormModel(orm, table_name, columns, record_class);
    model.timestamps = timestamps;

    -- Resolve relation key defaults now that the model (and its primary key) exists.
    local singular = (table_name:gsub("s$", ""));
    for name, rel in pairs(relations) do
        if (rel.kind == "belongs_to") then
            rel.key = rel.key or (name .. "_id");
        elseif (rel.kind == "belongs_to_many") then
            -- key = pivot FK to THIS model; otherKey/through/otherLocalKey depend
            -- on the target and are resolved lazily (the target may not exist yet).
            rel.key = rel.key or (singular .. "_id");
            rel.localKey = rel.localKey or model.primary_key;
        else
            rel.key = rel.key or (singular .. "_id");
            rel.localKey = rel.localKey or model.primary_key;
        end
    end
    model.relations = relations;

    return model;
end

return module;
