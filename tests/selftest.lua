-- Norm self-test. Run against the built bundle: light-class.lua + dist/norm.lua
-- must already be loaded (global `class` and global `Norm`).
local orm = Norm;
local class = orm.class;

local passed, failed = 0, 0;
local function check(name, cond, extra)
    if (cond) then
        passed = passed + 1;
        print(("  [PASS] %s"):format(name));
    else
        failed = failed + 1;
        print(("  [FAIL] %s %s"):format(name, extra and ("-> " .. tostring(extra)) or ""));
    end
end

-- Mock adapter: records SQL, returns canned results.
local Mock = class.extend("MockAdapter", orm.Adapter);
function Mock:__init(opts)
    orm.Adapter.__init(self, opts);
    self.calls = {};
    self.next_id = 0;
    self.query_result = {};
end
function Mock:raw_query(q, p, cb)
    self.calls[#self.calls + 1] = { kind = "query", sql = q, params = p };
    cb(nil, self.query_result);
end
function Mock:raw_execute(q, p, cb)
    self.calls[#self.calls + 1] = { kind = "execute", sql = q, params = p };
    if (q:match("^%s*[Ii][Nn][Ss][Ee][Rr][Tt]")) then
        self.next_id = self.next_id + 1;
        cb(nil, { affectedRows = 1, insertId = self.next_id });
    else
        cb(nil, { affectedRows = 1 });
    end
end
local function last_sql(mock) return mock.calls[#mock.calls].sql; end

print("== Test group 1: builtin provider (mysql dialect) ==");
local mock = Mock({ dialect = "mysql" });
local db = orm.new({ adapter = mock, promise = orm.promise.builtin() });

local User = db:define("users", {
    id    = orm.types.id(),
    name  = orm.types.string({ length = 64, nullable = false }),
    email = orm.types.string({ length = 128, unique = true }),
    admin = orm.types.boolean({ default = false }),
    age   = orm.types.integer({ default = 0 }),
});

db:sync();
local create = last_sql(mock);
print("  CREATE: " .. create);
check("create table name", create:find("CREATE TABLE IF NOT EXISTS `users`", 1, true) ~= nil);
check("id is PK auto_increment", create:find("`id` INT PRIMARY KEY AUTO_INCREMENT", 1, true) ~= nil);
check("name VARCHAR(64) NOT NULL", create:find("`name` VARCHAR(64) NOT NULL", 1, true) ~= nil);
check("email UNIQUE", create:find("`email` VARCHAR(128) UNIQUE", 1, true) ~= nil);
check("engine suffix", create:find("ENGINE=InnoDB", 1, true) ~= nil);

local created;
User:create({ name = "John", email = "john@x.io", admin = true }):next(function(u) created = u; end);
print("  INSERT: " .. last_sql(mock));
check("insert omits autoincrement id", last_sql(mock):find("`id`", 1, true) == nil);
check("insert resolved record", created ~= nil);
check("insert assigned insertId", created and created.id == 1, created and created.id);
check("record persisted", created and created.__persisted == true);
check("boolean stored as 1", (function()
    for _, v in ipairs(mock.calls[#mock.calls].params) do if (v == 1) then return true; end end
    return false;
end)());

mock.query_result = { { id = 1, name = "John", email = "john@x.io", admin = 1, age = 0 } };
local found;
User:find(1):next(function(u) found = u; end);
print("  SELECT find: " .. last_sql(mock));
check("find select where pk", last_sql(mock):find("WHERE `id` = ?", 1, true) ~= nil);
check("find select limit 1", last_sql(mock):find("LIMIT 1", 1, true) ~= nil);
check("found record name", found and found.name == "John");
check("boolean parsed to true", found and found.admin == true, found and tostring(found.admin));

mock.query_result = {};
User:where("age", ">", 18):order("name", "DESC"):limit(10):offset(5):all();
local sel = last_sql(mock);
print("  SELECT query: " .. sel);
check("where op >", sel:find("WHERE `age` > ?", 1, true) ~= nil);
check("order by desc", sel:find("ORDER BY `name` DESC", 1, true) ~= nil);
check("limit/offset", sel:find("LIMIT 10 OFFSET 5", 1, true) ~= nil);

mock.query_result = {};
User:query():where({ name = "John" }):where_in("id", { 1, 2, 3 }):all();
local sel2 = last_sql(mock);
print("  SELECT in: " .. sel2);
check("where_in placeholders", sel2:find("`id` IN (?, ?, ?)", 1, true) ~= nil);

found.age = 42;
local saved;
found:save():next(function(u) saved = u; end);
print("  UPDATE: " .. last_sql(mock));
check("update statement", last_sql(mock):find("UPDATE `users` SET", 1, true) ~= nil);
check("update where pk", last_sql(mock):find("WHERE `id` = ?", 1, true) ~= nil);
check("update never sets pk", (function()
    local setpart = last_sql(mock):match("SET (.-) WHERE");
    return setpart ~= nil and setpart:find("`id`", 1, true) == nil;
end)());
check("save resolved record", saved == found);

found:delete();
print("  DELETE: " .. last_sql(mock));
check("delete statement", last_sql(mock):find("DELETE FROM `users` WHERE `id` = ?", 1, true) ~= nil);

mock.query_result = { { count = 7 } };
local n;
User:count():next(function(c) n = c; end);
check("count value", n == 7, n);

print("== Test group 2: sqlite dialect DDL ==");
local mock2 = Mock({ dialect = "sqlite" });
local db2 = orm.new({ adapter = mock2, promise = orm.promise.builtin() });
local Item = db2:define("items", {
    id   = orm.types.id(),
    name = orm.types.string({ length = 32 }),
});
db2:sync();
local createS = last_sql(mock2);
print("  CREATE (sqlite): " .. createS);
check("sqlite integer pk autoincrement", createS:find("`id` INTEGER PRIMARY KEY AUTOINCREMENT", 1, true) ~= nil);
check("sqlite string -> TEXT", createS:find("`name` TEXT", 1, true) ~= nil);
check("sqlite no engine suffix", createS:find("ENGINE", 1, true) == nil);

print("== Test group 3: portability (nanos-style provider with :Then, no :next) ==");
local FakeP = {};
FakeP.__index = FakeP;
local function fake_new(executor)
    local self = setmetatable({ state = "pending", cbs = {} }, FakeP);
    executor(function(v)
        self.value = v; self.state = "ful";
        for i = 1, #self.cbs do self.cbs[i](v); end
    end, function(e) self.err = e; self.state = "rej"; end);
    return self;
end
function FakeP:Then(f)
    if (self.state == "ful") then f(self.value); else self.cbs[#self.cbs + 1] = f; end
    return self;
end
local fakeProvider = {
    name = "fake-nanos",
    new = fake_new,
    resolve = function(v) return fake_new(function(r) r(v); end); end,
    reject = function(e) return fake_new(function(_, j) j(e); end); end,
};

local mock3 = Mock({ dialect = "mysql" });
local db3 = orm.new({ adapter = mock3, promise = fakeProvider });
local Post = db3:define("posts", { id = orm.types.id(), title = orm.types.string({ length = 80 }) });

local ok_sync = false;
db3:sync():Then(function() ok_sync = true; end);
check("sync works with :Then-only provider", ok_sync);

local post;
Post:create({ title = "Hello" }):Then(function(p) post = p; end);
check("create works with :Then-only provider", post ~= nil and post.id == 1, post and post.id);

mock3.query_result = { { id = 1, title = "Hello" } };
local got;
Post:find(1):Then(function(p) got = p; end);
check("find works with :Then-only provider", got ~= nil and got.title == "Hello");

print("== Test group 4: builtin promise chaining (:next / :catch) ==");
local p1ok, caught;
orm.promise.builtin().resolve(10)
    :next(function(v) return v + 5; end)
    :next(function(v) p1ok = (v == 15); end);
check("builtin :next chains transforms", p1ok);

orm.promise.builtin().new(function(_, reject) reject("boom"); end)
    :catch(function(e) caught = e; end);
check("builtin :catch catches", caught == "boom");

print("== Test group 5: duck-typed adapter (no class system) ==");
local plain = {
    _calls = {},
    get_dialect = function(self) return orm.dialect.mysql; end,
    default_provider = function(self) return nil; end,
    raw_query = function(self, q, p, cb) cb(nil, {}); end,
    raw_execute = function(self, q, p, cb) self._calls[#self._calls + 1] = q; cb(nil, { affectedRows = 1, insertId = 9 }); end,
};
local db5 = orm.new({ adapter = plain, promise = orm.promise.builtin() });
local Plain = db5:define("plain", { id = orm.types.id(), v = orm.types.integer() });
local pid;
Plain:create({ v = 1 }):next(function(r) pid = r.id; end);
check("duck-typed adapter works", pid == 9, pid);

print("== Test group 6: builtin promise :await() ==");
-- already-resolved: returns immediately inside a coroutine
coroutine.wrap(function()
    local v = orm.promise.builtin().resolve(42):await();
    check("await on resolved promise", v == 42, v);
end)();

-- pending then settled: await yields, settle resumes the coroutine
local deferred;
local p_pending = orm.promise.builtin().new(function(resolve) deferred = resolve; end);
local awaited;
local co = coroutine.create(function() awaited = p_pending:await(); end);
coroutine.resume(co);          -- blocks at :await()
check("await suspends while pending", awaited == nil);
deferred(99);                  -- settles -> resumes the coroutine
check("await resumes with value", awaited == 99, awaited);

-- rejection: :await() raises
coroutine.wrap(function()
    local ok, err = pcall(function() return orm.promise.builtin().reject("nope"):await(); end);
    check("await raises on rejection", (not ok) and tostring(err):find("nope", 1, true) ~= nil);
end)();

-- end-to-end: await an ORM operation through the builtin provider
coroutine.wrap(function()
    mock.query_result = { { id = 1, name = "John", email = "john@x.io", admin = 1, age = 0 } };
    local u = User:find(1):await();
    check("await an ORM query result", u and u.name == "John", u and u.name);
end)();

print("== Test group 7: custom promise class (auto-wrapped via from_class) ==");
-- A framework promise with a `Class(executor)` constructor and its OWN :await()
-- (like no-more-rp's). Passing the CLASS directly should auto-wrap it.
local Custom = {};
Custom.__index = Custom;
setmetatable(Custom, { __call = function(cls, executor)
    local p = setmetatable({ state = "pending" }, cls);
    if (type(executor) == "function") then
        executor(
            function(v) if (p.state == "pending") then p.state, p.value = "fulfilled", v; if p.co then coroutine.resume(p.co) end end end,
            function(e) if (p.state == "pending") then p.state, p.value = "rejected", e; if p.co then coroutine.resume(p.co) end end end
        );
    end
    return p;
end });
function Custom:await()
    if (self.state == "pending") then self.co = coroutine.running(); coroutine.yield(); end
    if (self.state == "rejected") then error(self.value); end
    return self.value;
end

local mock7 = Mock({ dialect = "mysql" });
local db7 = orm.new({ adapter = mock7, promise = Custom }); -- pass the CLASS, not a provider
check("auto-wrapped class -> provider name 'class'", db7.provider.name == "class", db7.provider.name);
local U7 = db7:define("u7", { id = orm.types.id(), name = orm.types.string({ length = 32 }) });
coroutine.wrap(function()
    local r = U7:create({ name = "Z" }):await();   -- uses the class's own :await()
    check("await on auto-wrapped custom promise", r and r.name == "Z", r and r.name);
end)();

print("== Test group 8: relations (belongs_to / has_many, lazy + eager) ==");
-- A mock that routes SELECTs by table name (returns all rows for that table;
-- the relation attach logic filters by key, so this exercises it faithfully).
local Routed = class.extend("RoutedAdapter", orm.Adapter);
function Routed:__init(opts)
    orm.Adapter.__init(self, opts);
    self.rows = {};       -- table -> rows
    self.queries = {};    -- recorded SELECTs
end
function Routed:raw_query(q, p, cb)
    self.queries[#self.queries + 1] = q;
    local tbl = q:match("FROM `([%w_]+)`");
    local rows = self.rows[tbl] or {};
    -- Honor a simple single-column WHERE (`= ?` or `IN (?, ...)`) via the params,
    -- so lazy loads (which rely on the DB's WHERE) behave realistically.
    local col = q:match("WHERE `([%w_]+)`");
    if (col and #p > 0) then
        local set = {};
        for i = 1, #p do set[p[i]] = true; end
        local filtered = {};
        for i = 1, #rows do if (set[rows[i][col]]) then filtered[#filtered + 1] = rows[i]; end end
        rows = filtered;
    end
    cb(nil, rows);
end
function Routed:raw_execute(q, p, cb)
    self.queries[#self.queries + 1] = q;
    cb(nil, { affectedRows = 1, insertId = 1 });
end

local rmock = Routed({ dialect = "mysql" });
rmock.rows.users = { { id = 1, name = "Alice" }, { id = 2, name = "Bob" } };
rmock.rows.posts = {
    { id = 10, user_id = 1, title = "A1" },
    { id = 11, user_id = 1, title = "A2" },
    { id = 12, user_id = 2, title = "B1" },
};

local rdb = orm.new({ adapter = rmock, promise = orm.promise.builtin() });
local Users = rdb:define("users", {
    id    = orm.types.id(),
    name  = orm.types.string({ length = 32 }),
    posts = orm.types.hasMany("posts", { key = "user_id" }),
});
local Posts = rdb:define("posts", {
    id      = orm.types.id(),
    title   = orm.types.string({ length = 120 }),
    user_id = orm.types.integer(),
    author  = orm.types.belongsTo("users", { key = "user_id" }),
});

-- relations are separated from columns
check("relation is not a column", Users.columns_by_name.posts == nil and Users.relations.posts ~= nil);
check("create table omits relations", (function()
    rdb:sync();
    for _, q in ipairs(rmock.queries) do
        if (q:find("CREATE TABLE", 1, true) and q:find("users", 1, true)) then
            return q:find("posts", 1, true) == nil;
        end
    end
    return false;
end)());

-- eager belongs_to: posts -> author, batched (1 main + 1 author query)
rmock.queries = {};
local posts;
Posts:query():include("author"):all():next(function(r) posts = r; end);
check("eager belongs_to count", posts and #posts == 3, posts and #posts);
check("eager belongs_to attaches author", posts and posts[1].author and posts[1].author.name == "Alice",
    posts and posts[1].author and posts[1].author.name);
check("eager belongs_to second user", posts and posts[3].author and posts[3].author.name == "Bob");
check("eager belongs_to has no N+1 (2 queries)", #rmock.queries == 2, #rmock.queries);

-- eager has_many: users -> posts, batched (1 main + 1 posts query)
rmock.queries = {};
local users;
Users:query():include("posts"):all():next(function(r) users = r; end);
check("eager has_many groups children", users and #users[1].posts == 2 and #users[2].posts == 1,
    users and (#users[1].posts .. "/" .. #users[2].posts));
check("eager has_many has no N+1 (2 queries)", #rmock.queries == 2, #rmock.queries);

-- lazy belongs_to
local post = Posts:wrap({ id = 10, user_id = 1, title = "A1" });
local author;
post:load("author"):next(function(a) author = a; end);
check("lazy belongs_to loads + caches", author and author.name == "Alice" and post.author == author);

-- lazy has_many
local user = Users:wrap({ id = 1, name = "Alice" });
local ulist;
user:load("posts"):next(function(l) ulist = l; end);
check("lazy has_many loads + caches", ulist and #ulist == 2 and user.posts == ulist, ulist and #ulist);

print("== Test group 9: foreign keys (DDL emission, ordering, options) ==");
-- Collect the latest CREATE TABLE statement per table from a mock's call log.
local function creates_by_table(mock)
    local out = {};
    for _, c in ipairs(mock.calls) do
        local t = c.sql:match("CREATE TABLE IF NOT EXISTS `([%w_]+)`");
        if (t) then out[t] = c.sql; end
    end
    return out;
end
local function define_players_characters(db, action)
    db:define("players", { id = orm.types.id(), name = orm.types.string({ length = 32 }) });
    db:define("characters", {
        id        = orm.types.id(),
        player_id = orm.types.integer({ nullable = false }),
        player    = orm.types.belongsTo("players", { key = "player_id", onDelete = action }),
    });
end

-- 9a) mysql + default ("auto"): belongs_to emits a FOREIGN KEY with ON DELETE.
local mfk = Mock({ dialect = "mysql" });
local fdb = orm.new({ adapter = mfk, promise = orm.promise.builtin() });
define_players_characters(fdb, "CASCADE");
fdb:sync();
local mc = creates_by_table(mfk);
check("mysql auto emits FK on belongs_to", mc.characters and mc.characters:find(
    "FOREIGN KEY (`player_id`) REFERENCES `players` (`id`) ON DELETE CASCADE", 1, true) ~= nil, mc.characters);
check("referenced table carries no FK", mc.players and mc.players:find("FOREIGN KEY", 1, true) == nil);

-- 9b) referenced table is created before the referencing table (dependency order).
check("FK dependency order: players before characters", (function()
    local pi, ci;
    for i, c in ipairs(mfk.calls) do
        if (c.sql:find("CREATE TABLE IF NOT EXISTS `players`", 1, true)) then pi = i; end
        if (c.sql:find("CREATE TABLE IF NOT EXISTS `characters`", 1, true)) then ci = i; end
    end
    return pi and ci and pi < ci;
end)());

-- 9c) sqlite + default ("auto"): FK skipped, one-time warning through the logger.
local warns = {};
local sfk = Mock({ dialect = "sqlite" });
local sdb = orm.new({
    adapter = sfk, promise = orm.promise.builtin(),
    logger = function(level, msg) warns[#warns + 1] = tostring(level) .. " " .. tostring(msg); end,
});
define_players_characters(sdb, "CASCADE");
sdb:sync();
sdb:sync(); -- second sync must NOT warn again
local sc = creates_by_table(sfk);
check("sqlite auto skips FK", sc.characters and sc.characters:find("FOREIGN KEY", 1, true) == nil, sc.characters);
check("sqlite auto warns exactly once", (function()
    local n = 0;
    for _, w in ipairs(warns) do if (w:find("foreign keys are not emitted", 1, true)) then n = n + 1; end end
    return n == 1;
end)(), #warns);

-- 9d) foreignKeys=false: never emit, even on mysql.
local nfk = Mock({ dialect = "mysql" });
local ndb = orm.new({ adapter = nfk, promise = orm.promise.builtin(), foreignKeys = false });
define_players_characters(ndb, "CASCADE");
ndb:sync();
local nc = creates_by_table(nfk);
check("foreignKeys=false emits no FK", nc.characters and nc.characters:find("FOREIGN KEY", 1, true) == nil);

-- 9e) foreignKeys=true on sqlite: force inline FK (action normalised to upper-case).
local tfk = Mock({ dialect = "sqlite" });
local tdb = orm.new({ adapter = tfk, promise = orm.promise.builtin(), foreignKeys = true });
tdb:define("players", { id = orm.types.id() });
tdb:define("characters", {
    id = orm.types.id(), player_id = orm.types.integer(),
    player = orm.types.belongsTo("players", { key = "player_id", onDelete = "set null" }),
});
tdb:sync();
local tc = creates_by_table(tfk);
check("foreignKeys=true forces FK on sqlite", tc.characters and tc.characters:find(
    "FOREIGN KEY (`player_id`) REFERENCES `players` (`id`) ON DELETE SET NULL", 1, true) ~= nil, tc.characters);

print("== Test group 10: json provider ((de)serialisation of json columns) ==");
local function params_have(mock, value)
    local params = mock.calls[#mock.calls].params;
    for _, p in ipairs(params) do if (p == value) then return true; end end
    return false;
end
-- A deterministic test provider: encode tags the value, decode wraps the string.
local jp = {
    name = "test",
    encode = function(v) return "ENC:" .. tostring(v.x); end,
    decode = function(s) return { decoded = s }; end,
};

local jmock = Mock({ dialect = "mysql" });
local jdb = orm.new({ adapter = jmock, promise = orm.promise.builtin(), json = jp });
local Doc = jdb:define("docs", { id = orm.types.id(), meta = orm.types.json() });

-- 10a) a Lua table in a json column is encoded on INSERT.
Doc:create({ meta = { x = 7 } });
check("json table encoded on insert", params_have(jmock, "ENC:7"));

-- 10b) a raw string from the driver is decoded on read.
jmock.query_result = { { id = 1, meta = "stored-json" } };
local got;
Doc:find(1):next(function(r) got = r; end);
check("json decoded on read", got and type(got.meta) == "table" and got.meta.decoded == "stored-json",
    got and type(got.meta));

-- 10c) a value already a string is passed through (never double-encoded).
Doc:create({ meta = "already-a-string" });
check("string json value passes through encode", params_have(jmock, "already-a-string"));

-- 10d) bulk update also encodes json columns.
Doc:query():where("id", 1):update({ meta = { x = 9 } });
check("json encoded on bulk update", params_have(jmock, "ENC:9"));

-- 10e) json = false disables (de)serialisation (raw string passthrough).
local rmock2 = Mock({ dialect = "mysql" });
local rdb2 = orm.new({ adapter = rmock2, promise = orm.promise.builtin(), json = false });
local Doc2 = rdb2:define("docs2", { id = orm.types.id(), meta = orm.types.json() });
check("json=false resolves to raw provider", rdb2.json.name == "raw", rdb2.json.name);
rmock2.query_result = { { id = 1, meta = '{"x":1}' } };
local got2;
Doc2:find(1):next(function(r) got2 = r; end);
check("json=false leaves raw string on read", got2 and got2.meta == '{"x":1}', got2 and tostring(got2.meta));

-- 10f) with no host JSON library, auto-detection falls back to the raw provider.
local amock = Mock({ dialect = "mysql" });
local adb = orm.new({ adapter = amock, promise = orm.promise.builtin() });
check("json auto-detect falls back to raw", adb.json.name == "raw", adb.json.name);

-- 10g) the built-in nanos / lua builders wrap their library uniformly.
local fakeJSON = { stringify = function(v) return "S(" .. tostring(v.x) .. ")"; end, parse = function(s) return { p = s }; end };
local np = orm.json.nanos(fakeJSON);
check("json.nanos wraps stringify/parse", np.encode({ x = 3 }) == "S(3)" and np.decode("z").p == "z");
local fakejson = { encode = function(_) return "E"; end, decode = function(_) return "D"; end };
local lp = orm.json.rapidjson(fakejson);
check("json.rapidjson wraps encode/decode", lp.encode({}) == "E" and lp.decode("x") == "D");

-- ===============================================================
print("== Test group 11: INSERT ... RETURNING (returning-capable adapter) ==");
-- An adapter that advertises RETURNING support must have its inserts routed
-- through raw_query (the statement returns a row), with the id read from that
-- row — never from raw_execute's insertId (which we deliberately leave nil here).
local RMock = class.extend("ReturningMock", orm.Adapter);
function RMock:__init(opts)
    orm.Adapter.__init(self, opts);
    self.calls = {};
end
function RMock:supports_returning() return true; end
function RMock:raw_query(q, p, cb)
    self.calls[#self.calls + 1] = { kind = "query", sql = q, params = p };
    if (q:find("RETURNING", 1, true)) then cb(nil, { { id = 99 } }); else cb(nil, {}); end
end
function RMock:raw_execute(q, p, cb)
    self.calls[#self.calls + 1] = { kind = "execute", sql = q, params = p };
    cb(nil, { affectedRows = 1 }); -- NO insertId on purpose: id must come from RETURNING
end

local rmock = RMock({ dialect = "sqlite" });
local rdb = orm.new({ adapter = rmock, promise = orm.promise.builtin() });
local RUser = rdb:define("players", { id = orm.types.id(), name = orm.types.string() });

local rcreated;
RUser:create({ name = "Zoe" }):next(function(u) rcreated = u; end);
local rlast = rmock.calls[#rmock.calls];
check("returning: insert routed through raw_query", rlast.kind == "query", rlast.kind);
check("returning: INSERT ... RETURNING `id` emitted", rlast.sql:find("RETURNING `id`", 1, true) ~= nil, rlast.sql);
check("returning: insert omits autoincrement id", rlast.sql:find("(`id`", 1, true) == nil);
check("returning: id read from RETURNING row", rcreated and rcreated.id == 99, rcreated and rcreated.id);
check("returning: record persisted", rcreated and rcreated.__persisted == true);

print(("\n== RESULT: %d passed, %d failed =="):format(passed, failed));
if (failed > 0) then error("self-test failed"); end
