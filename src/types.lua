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

---@param options? NormColumnOptions
---@return NormColumn
function types.integer(options) return make("integer", options); end
---@param options? NormColumnOptions
---@return NormColumn
function types.bigint(options) return make("bigint", options); end
---@param options? NormColumnOptions
---@return NormColumn
function types.string(options) return make("string", options); end
---@param options? NormColumnOptions
---@return NormColumn
function types.text(options) return make("text", options); end
---@param options? NormColumnOptions
---@return NormColumn
function types.float(options) return make("float", options); end
---@param options? NormColumnOptions
---@return NormColumn
function types.double(options) return make("double", options); end
---@param options? NormColumnOptions
---@return NormColumn
function types.boolean(options) return make("boolean", options); end
---@param options? NormColumnOptions
---@return NormColumn
function types.datetime(options) return make("datetime", options); end
---@param options? NormColumnOptions
---@return NormColumn
function types.date(options) return make("date", options); end
---@param options? NormColumnOptions
---@return NormColumn
function types.json(options) return make("json", options); end

return types;
