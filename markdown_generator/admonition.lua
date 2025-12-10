-- ...existing code...
local pandoc = require('pandoc')




function BlockQuote(el)
    local f = el.content and el.content[1]
    if not f or not (f.t == "Para" or f.t == "Plain") then return nil end
    local s = pandoc.utils.stringify(f)
    local k = s:match("^%s*%[!([%w%-]+)%]")
    if not k then return nil end
    s = s:gsub("^%s*%[!([%w%-]+)%]%s*", "", 1)
    local pb = pandoc.read(s, 'markdown').blocks or {}
    local nc = {}
    for _, b in ipairs(pb) do nc[#nc + 1] = b end
    for i = 2, #el.content do nc[#nc + 1] = el.content[i] end
    return pandoc.Div(nc, pandoc.Attr("", { "admonition", k:lower() }))
end

-- ...existing code...
