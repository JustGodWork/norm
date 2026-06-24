--- Model (table manager, class-level ops) and Record (one row, instance ops).
--- `Orm:define` builds a Model + a dedicated Record subclass per table.
local class = class;
local utils = require("utils");
local sqlmod = require("sql");
local NormQueryBuilder = require("query");

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
        for i = 1, #model.columns do
            local col = model.columns[i];
            local value = row[col.name];
            if (value ~= nil) then
                self[col.name] = model:parse(col, value);
            end
        end
    end
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

--- Persist the record: INSERT if new, UPDATE if it was loaded from the database.
--- Resolves with the record itself.
--- ```lua
---     local user = User:find(1):await()
---     user.coins = user.coins + 50
---     user:save():await()
--- ```
---@return NormRecordPromise promise resolving to NormRecord (self)
function NormRecord:save()
    local model = self.__model;
    local orm = model.orm;
    local d = orm.adapter:get_dialect();
    local data = self:_persistable();

    if (self.__persisted) then
        utils.assert(model.primary_key, ("model '%s' has no primary key; cannot update"):format(model.table));
        local pk = model.primary_key;
        data[pk] = nil;
        local state = { table = model.table, wheres = { { column = pk, op = "=", value = self[pk] } } };
        local statement, params = sqlmod.update(state, data, d);
        return orm:_execute_map(statement, params, function() return self; end);
    end

    if (model.autoincrement_pk) then data[model.primary_key] = nil; end
    local statement, params = sqlmod.insert(model.table, data, d);
    return orm:_execute_map(statement, params, function(res)
        self.__persisted = true;
        if (model.autoincrement_pk and res and res.insertId ~= nil) then
            self[model.primary_key] = res.insertId;
        end
        return self;
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
        return self;
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
---@field primary_key? string
---@field autoincrement_pk boolean
---@field record_class NormRecord
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

--- Convert a raw driver value into a Lua value for the given column.
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
    return value;
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

--- Create this model's table (CREATE TABLE IF NOT EXISTS). Prefer `orm:sync()`
--- to create every model at once. Resolves with true.
--- ```lua
---     User:sync():await()
--- ```
---@return NormBooleanPromise promise resolving to true
function NormModel:sync()
    local d = self.orm.adapter:get_dialect();
    local statement = sqlmod.create_table(self.table, self.columns, d);
    return self.orm:_execute_map(statement, {}, function() return true; end);
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

--- Build a Model (+ dedicated Record subclass) from a schema definition.
---@param orm NormOrm
---@param table_name string
---@param schema table<string, NormColumn>
---@return NormModel
function module.define(orm, table_name, schema)
    utils.assert(type(table_name) == "string", "define: table name must be a string");
    utils.assert(type(schema) == "table", "define: schema must be a table");

    local columns = {};
    for _, name in ipairs(utils.sorted_keys(schema)) do
        local def = schema[name];
        utils.assert(type(def) == "table" and def.kind,
            ("define: column '%s' is not a valid Norm.types descriptor"):format(name));
        local col = utils.copy(def);
        col.name = name;
        columns[#columns + 1] = col;
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

    return NormModel(orm, table_name, columns, record_class);
end

return module;
