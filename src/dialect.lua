--- SQL dialects: the small syntactic differences between database engines.
--- Adapters expose a dialect so the SQL builder stays engine agnostic.
---@class NormDialects
---@field mysql NormDialect
---@field sqlite NormDialect
local dialect = {};

---@param id string|number
---@return string
local function quote_backtick(id)
    return "`" .. tostring(id):gsub("`", "``") .. "`";
end

---@class NormDialect
---@field name string
---@field quote fun(id: string): string
---@field placeholder fun(index: number): string
---@field autoincrement string
---@field table_suffix string
---@field types table<string, string>
---@field index_if_not_exists boolean Whether `CREATE INDEX IF NOT EXISTS` is valid syntax.
---@field defaults_on_text boolean Whether TEXT/BLOB/JSON columns accept a literal DEFAULT.

---@type NormDialect
dialect.mysql = {
    name = "mysql",
    quote = quote_backtick,
    placeholder = function() return "?"; end,
    autoincrement = "AUTO_INCREMENT",
    table_suffix = " ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci",
    -- Stock MySQL 8 supports neither; MariaDB does support the index form, but the
    -- adapter cannot tell them apart at DDL time, so assume the stricter engine.
    index_if_not_exists = false,
    defaults_on_text = false,
    types = {
        id = "INT", integer = "INT", bigint = "BIGINT", string = "VARCHAR(255)",
        text = "TEXT", float = "FLOAT", double = "DOUBLE", boolean = "TINYINT(1)",
        datetime = "DATETIME", date = "DATE", json = "JSON",
    },
};

---@type NormDialect
dialect.sqlite = {
    name = "sqlite",
    quote = quote_backtick,
    placeholder = function() return "?"; end,
    autoincrement = "AUTOINCREMENT",
    table_suffix = "",
    index_if_not_exists = true,
    defaults_on_text = true,
    types = {
        id = "INTEGER", integer = "INTEGER", bigint = "INTEGER", string = "TEXT",
        text = "TEXT", float = "REAL", double = "REAL", boolean = "INTEGER",
        datetime = "TEXT", date = "TEXT", json = "TEXT",
    },
};

---@param name string
---@return NormDialect
function dialect.get(name)
    local d = dialect[name];
    if (not d) then
        error(("[norm] unknown dialect '%s'"):format(tostring(name)));
    end
    return d;
end

return dialect;
