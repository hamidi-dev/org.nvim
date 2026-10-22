---@mod org.export.html.link HTML links and images
---
--- Inline images (org-html-inline-image-p, org-html--format-image) and
--- the link transcoder.
---
--- Part of org.export.html, which loads it.

local ox = require("org.export.ox")
local element = require("org.export.element")
local shared = require("org.export.html.shared")

local M = require("org.export.html")

local nw = ox.nw
local trim = ox.trim
local fmt = string.format

local T = shared.T
local attribute_string = shared.attribute_string
local close_tag = shared.close_tag
local encode = shared.encode
local html5_fancy_p = shared.html5_fancy_p
local set_attr = shared.set_attr

--- Inline image rules (org-html-inline-image-rules).
local IMG = { "jpeg", "jpg", "png", "gif", "svg", "webp", "avif" }
M.inline_image_rules = { file = IMG, http = IMG, https = IMG }

function M.inline_image_p(link, info)
  if #link.contents == 0 then
    return ox.inline_image_p(link, info.html_inline_image_rules, true)
  end
  local count = 0
  local ok = true
  for _, obj in ipairs(link.contents) do
    if obj.type == "plain-text" then
      if nw(obj.value) then
        ok = false
      end
    elseif obj.type == "link" then
      count = count + 1
      if count > 1 or not ox.inline_image_p(obj, info.html_inline_image_rules, true) then
        ok = false
      end
    else
      ok = false
    end
  end
  return ok and count == 1
end

function M.standalone_image_p(el, info, predicate)
  local paragraph = el.type == "paragraph" and el or (el.type == "link" and el.parent) or nil
  if not paragraph or paragraph.type ~= "paragraph" then
    return false
  end
  if predicate and not predicate(paragraph) then
    return false
  end
  local count = 0
  for _, obj in ipairs(paragraph.contents) do
    if not info.ignore[obj] then
      if obj.type == "plain-text" then
        if nw(obj.value) then
          return false
        end
      elseif obj.type == "link" then
        count = count + 1
        if count > 1 or not M.inline_image_p(obj, info) then
          return false
        end
      else
        return false
      end
    end
  end
  return count == 1
end

function M.format_image(source, attrs, info, alt)
  local a = { _keys = { "src", "alt" }, src = source, alt = alt or vim.fn.fnamemodify(source, ":t") }
  if source:match("%.svg$") then
    set_attr(a, "class", "org-svg")
  end
  for _, k in ipairs((attrs or {})._keys or {}) do
    if not (source:match("%.svg$") and k == "fallback") then
      set_attr(a, k, attrs[k])
    end
  end
  return close_tag("img", attribute_string(a), info)
end

local function wrap_image(contents, info, caption, label)
  local fancy = html5_fancy_p(info)
  return fmt(
    fancy and "\n<figure%s>\n%s%s\n</figure>" or '\n<div%s class="figure">\n%s%s\n</div>',
    nw(label) and fmt(' id="%s"', label) or "",
    fancy and contents or fmt("<p>%s</p>", contents),
    nw(caption) and fmt(fancy and "\n<figcaption>%s</figcaption>" or "\n<p>%s</p>", caption) or ""
  )
end

local function link_org_as_html(raw, info)
  if info.html_link_org_files_as_html then
    local base = raw:match("^(.+)%.[Oo][Rr][Gg]$") or raw:match("^(.+)%.[Oo][Rr][Gg]%.gpg$")
    if base then
      local ext = info.html_extension
      return base .. (ext ~= "" and "." or "") .. ext
    end
  end
  return raw
end

local function url_encode(s)
  return (s:gsub("[^%w%-%._~:/%?#%[%]@!%$&'%(%)%*%+,;=%%]", function(c)
    return fmt("%%%02X", c:byte())
  end))
end
M.url_encode = url_encode

--- Resolve a search option of a file link to an anchor
--- (org-publish-resolve-external-link).
function M.resolve_external(option, path, info)
  if path:lower():match("%.pdf$") then
    -- Emacs searches a PDF's raw bytes as text, so `doc.pdf::5` aborts the
    -- export or becomes #MissingReference; a page number becomes the
    -- #page=N open parameter, any other option the anchor (org-differences)
    if option:match("^%d+$") then
      return "page=" .. option
    end
    return (option:gsub("^#", ""))
  end
  local pub = require("org.export.publish")
  local r = pub.resolve_external_link(option, path, info)
  if r then
    return r
  end
  return option:gsub("^#", ""):gsub("^%*", "")
end

T.link = function(el, desc, info)
  local ltype = el.link_type
  local raw = el.path
  desc = nw(desc)
  local path
  if ltype == "file" then
    local rel = require("org.export.publish").file_relative_name(raw, info)
    raw = ox.file_uri(rel)
    local home = info.html_link_home and trim(info.html_link_home)
    if nw(home) and info.html_link_use_abs_url and not (raw:match("^/") or raw:match("^file:")) then
      raw = home:gsub("/?$", "/") .. raw
    end
    raw = link_org_as_html(raw, info)
    if el.search_option then
      path = raw .. "#" .. M.resolve_external(el.search_option, el.path, info)
    else
      path = raw
    end
  elseif ltype ~= "coderef" and ltype ~= "custom-id" and ltype ~= "fuzzy" and ltype ~= "radio" and ltype ~= "id" then
    path = url_encode(ltype .. ":" .. raw)
  end
  -- attributes of the parent paragraph (first link only)
  local attrs = { _keys = {} }
  local parent = element.parent_element(el)
  local target_link = el
  if el.parent and el.parent.type == "link" and M.inline_image_p(el, info) then
    target_link = el.parent
  end
  if parent then
    local first = element.map(parent.contents, "link", function(x)
      return x
    end, { first_match = true })
    if first == target_link then
      attrs = ox.read_attribute("attr_html", parent)
    end
  end
  local attributes = attribute_string(attrs)
  attributes = nw(attributes) and (" " .. attributes) or ""
  local custom = ox.custom_protocol_maybe(el, desc, "html", info)
  if custom then
    return custom
  end
  if info.html_inline_images and ox.inline_image_p(el, info.html_inline_image_rules, true) then
    return M.format_image(path or raw, attrs, info)
  end
  if ltype == "radio" then
    local dest = ox.resolve_radio_link(el, info)
    if not dest then
      return desc
    end
    return fmt('<a href="#%s"%s>%s</a>', M.reference(dest, info), attributes, desc or "")
  end
  if ltype == "custom-id" or ltype == "fuzzy" or ltype == "id" then
    local dest = ltype == "fuzzy" and ox.resolve_fuzzy_link(el, info) or ox.resolve_id_link(el, info)
    if dest.type == "plain-text" then
      local frag = "ID-" .. el.path
      local p = link_org_as_html(dest.value, info)
      return fmt('<a href="%s#%s"%s>%s</a>', p, frag, attributes, desc or dest.value)
    elseif dest.type == "headline" then
      local href = M.reference(dest, info)
      local d
      if ox.numbered_headline_p(dest, info) and not desc then
        local parts = {}
        for i, x in ipairs(ox.get_headline_number(dest, info) or {}) do
          parts[i] = tostring(x)
        end
        d = table.concat(parts, ".")
      else
        d = desc or ox.data(dest.title, info)
      end
      return fmt('<a href="#%s"%s>%s</a>', href, attributes, d)
    else
      local wl = info.with_latex
      if (wl == "mathjax" or wl == true) and dest.type == "latex-environment" and M.math_environment_p(dest) then
        return fmt(info.html_equation_reference_format, M.reference(dest, info))
      end
      local ref = M.reference(dest, info)
      local number
      if not desc then
        local pred = function(x)
          return x.caption ~= nil
        end
        if M.standalone_image_p(dest, info, pred) then
          local img = element.map(dest, "link", function(x)
            return x
          end, { first_match = true })
          number = ox.get_ordinal(img, info, { "link" }, function(x)
            return M.standalone_image_p(x, info, pred)
          end)
        else
          number = ox.get_ordinal(dest, info, nil, dest.type == "latex-environment" and function(x)
            return M.math_environment_p(x)
          end or function(x)
            return x.caption ~= nil
          end)
        end
      end
      local d = desc
      if not d then
        if number == nil then
          d = "No description for this link"
        elseif type(number) == "number" then
          d = tostring(number)
        else
          local parts = {}
          for i, x in ipairs(number) do
            parts[i] = tostring(x)
          end
          d = table.concat(parts, ".")
        end
      end
      return fmt('<a href="#%s"%s>%s</a>', ref, attributes, d)
    end
  end
  if ltype == "coderef" then
    local frag = "coderef-" .. encode(raw)
    local r = ox.resolve_coderef(raw, info)
    local f = ox.get_coderef_format(raw, desc)
    return fmt(
      '<a href="#%s" %s%s>%s</a>',
      frag,
      fmt(
        'class="coderef" onmouseover="CodeHighlightOn(this, \'%s\');" onmouseout="CodeHighlightOff(this, \'%s\');"',
        frag,
        frag
      ),
      attributes,
      (f:gsub("%%s", function()
        return tostring(r)
      end))
    )
  end
  if path and desc then
    return fmt('<a href="%s"%s>%s</a>', encode(path), attributes, desc)
  end
  if path then
    local p = encode(path)
    return fmt('<a href="%s"%s>%s</a>', p, attributes, p)
  end
  return fmt("<i>%s</i>", desc or "")
end

-- Locals the later parts share
shared.wrap_image = wrap_image
