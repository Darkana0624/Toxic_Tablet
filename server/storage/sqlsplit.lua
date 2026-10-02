---Splits a migration file into single statements. oxmysql connections do not
---enable multi-statement queries by default, so the runner executes one
---statement per query. Comments are removed; quoted strings and backtick
---identifiers are respected so a ';' inside them never splits a statement.
---Pure module: loads in the offline unit-test runner.

---@param sql string
---@return string[] statements trimmed, without the trailing ';'
return function(sql)
    local statements = {}
    local current = {}
    local i, n = 1, #sql
    local quote -- the active quote character: ', " or `

    local function flush()
        local statement = table.concat(current):match('^%s*(.-)%s*$')
        if statement ~= '' then statements[#statements + 1] = statement end
        current = {}
    end

    while i <= n do
        local char = sql:sub(i, i)
        local nextChar = sql:sub(i + 1, i + 1)

        if quote then
            current[#current + 1] = char
            if char == '\\' and quote ~= '`' and i < n then
                current[#current + 1] = nextChar
                i = i + 1
            elseif char == quote then
                if nextChar == quote then -- doubled quote is an escaped quote
                    current[#current + 1] = nextChar
                    i = i + 1
                else
                    quote = nil
                end
            end
        elseif char == '-' and nextChar == '-' and (i + 2 > n or sql:sub(i + 2, i + 2):match('%s')) then
            local lineEnd = sql:find('\n', i, true) or n + 1
            i = lineEnd - 1
        elseif char == '#' then
            local lineEnd = sql:find('\n', i, true) or n + 1
            i = lineEnd - 1
        elseif char == '/' and nextChar == '*' then
            local commentEnd = sql:find('*/', i + 2, true)
            if not commentEnd then
                error('unterminated /* comment in migration', 0)
            end
            i = commentEnd + 1
            current[#current + 1] = ' '
        elseif char == "'" or char == '"' or char == '`' then
            quote = char
            current[#current + 1] = char
        elseif char == ';' then
            flush()
        else
            current[#current + 1] = char
        end

        i = i + 1
    end

    if quote then
        error(('unterminated %s quote in migration'):format(quote), 0)
    end

    flush()
    return statements
end
