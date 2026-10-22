---@mod org.links.schemes The built-in link types

--- The link types org.nvim knows (`org.links.URL_SCHEMES`), name -> true.
local URL_SCHEMES = {
  http = true,
  https = true,
  ftp = true,
  mailto = true,
  news = true,
  doi = true,
  file = true,
  id = true,
  shell = true,
  elisp = true,
  help = true,
  man = true,
  attachment = true,
  info = true,
  irc = true,
  docview = true,
  -- ol-eww and ol-w3m: Emacs browses the URL in eww / emacs-w3m; here
  -- the system opener opens it like http:
  eww = true,
  w3m = true,
  bibtex = true,
  ["file+sys"] = true,
  ["file+emacs"] = true,
}

return URL_SCHEMES
