--[[
   Configuration script for l3build from the enumext package.
   At the moment the possible targets that can be passed are:
   * tag        : Update the version and date
   * doc        : Generate the documentation [-q]
   * unpack     : Unpacks the source files [-q]
   * install    : Install the package locally, you can use
                  it in conjunction with [--full] [--dry-run]
   * uninstall  : Uninstall the package locally
   * clean      : Clean the directory tree and repo
   * ctan       : Generate the compressed package (.zip)
   * upload     : Upload the package to ctan, you must add
                  -F ctan.ann in conjunction with [--debug]
   * tagcheck   : Check version and date in files
   * testpkg    : Compile all example files included in /test-pkg
   * examples   : Compile all example files included in .dtx file
   * release    : It performs the checks before generating a public
                  release (on git and ctan).
--]]

-- General package identification
module     = "enumext"
pkgversion = "2.3"
pkgdate    = "2026-09-23"
ltxrelease = "2026-11-01"

-- Configuration of files for build and installation
maindir       = "."
sourcefiledir = "./sources"
textfiledir   = "./sources"
sourcefiles   = {"**/*.dtx", "**/*.ins"}
installfiles  = {"**/*.sty"}
tdslocations  = {
  "tex/latex/enumext/enumext.sty",
  "doc/latex/enumext/enumext.pdf",
  "doc/latex/enumext/README.md",
  "source/latex/enumext/enumext.dtx",
  "source/latex/enumext/enumext.ins"
}

-- Unpacking files from enumext.ins
unpackfiles = { "enumext.ins" }
unpackopts  = "--interaction=batchmode"
unpackexe   = "luatex"

-- Typesetting enumext documentation step by step :)

function docinit_hook()
  local errorlevel = (cp("*mylhmc.lua", sourcefiledir, typesetdir) + cp("*mylhmc.sty", sourcefiledir, typesetdir))
  if errorlevel ~= 0 then
    error("** Error!!: Can't copy mylhmc.lua and mylhmc.lua files from "..sourcefiledir.." to "..typesetdir)
    return errorlevel
  end
  return 0
end

function typeset(file)
  print("** Running: arara -v "..file..".dtx")
  local file = jobname(sourcefiledir.."/enumext.dtx")
  local errorlevel = runcmd("arara "..file..".dtx", typesetdir, {"TEXINPUTS","LUAINPUTS"})
  if errorlevel ~= 0 then
    error("Error!!: Typesetting "..file..".dtx")
    return errorlevel
  end
  return 0
end

-- Configuration for ctan
ctanreadme = "CTANREADME.md"
ctanpkg    = "enumext"
ctanzip    = ctanpkg.."-"..pkgversion
packtdszip = false

--  Configuration for package distribution in ctan
uploadconfig = {
  author       = "Pablo González L",
  uploader     = "Pablo González L",
  email        = "pablgonz@yahoo.com",
  pkg          = ctanpkg,
  version      = pkgversion,
  license      = "lppl1.3c",
  summary      = "Enumerate exercise sheets",
  description  =[[This package provides enumerated list environments compatible with tagging PDF for creating
                  “simple exercise sheets” along with “multiple choice questions”, storing the “answers” to these in memory using
                   multicol package.]],
  topic        = { "exercise", "list-enum", "list", "tagged-pdf" },
  ctanPath     = "/macros/latex/contrib/" .. ctanpkg,
  repository   = "https://github.com/pablgonz/" .. module,
  bugtracker   = "https://github.com/pablgonz/" .. module .. "/issues",
  support      = "https://github.com/pablgonz/" .. module .. "/issues",
  note         = [[Uploaded automatically by l3build...]],
  announcement_file="ctan.ann",
  update       = true
}

-- Clean files
cleanfiles = {module..".pdf", ctanzip..".curlopt", ctanzip..".zip"}

-- Update package date and version
tagfiles = {
  "sources/enumext.dtx",
  "sources/enumext.sty",
  "sources/CTANREADME.md",
  "ctan.ann"
}

-- Line length helper (80 chars layout)
local function os_message(text)
  local mymax = 77 - string.len(text) - string.len("done")
  if mymax < 1 then mymax = 1 end
  print(text .. " " .. string.rep(".", mymax) .. " done")
end

-- Helper to safely read file content
local function read_file(filepath)
  local f = io.open(filepath, "r")
  if not f then return nil end
  local content = f:read("*all")
  f:close()
  return content
end

-- Update function with smart check (avoids redundant rewrites) --
-- checks FIRST whether the file already has the right tag/date before
-- touching the content; if it matches, no gsub runs at all.
function update_tag(file, content, tagname, tagdate)
  tagname = pkgversion
  tagdate = pkgdate

  -- Is this file already up to date?
  local already_ok = nil

  if string.match(file, "enumext%.dtx$") then
    local pkgd, pkgv = string.match(content, "\\ProvidesExplPackage%s*{enumext}%s*{(.-)}%s*{(.-)}")
    local ltxr = string.match(content, "\\NeedsTeXFormat%s*{LaTeX2e}%s*%[(%d%d%d%d%-%d%d%-%d%d)%]")
    already_ok = (pkgv == tagname and pkgd == tagdate and ltxr == ltxrelease)

  elseif string.match(file, "enumext%.sty$") then
    local pkgd, pkgv = string.match(content, "\\ProvidesExplPackage%s*{enumext}%s*{(.-)}%s*{(.-)}")
    local ltxr = string.match(content, "\\NeedsTeXFormat%s*{LaTeX2e}%s*%[(%d%d%d%d%-%d%d%-%d%d)%]")
    already_ok = (pkgv == tagname and pkgd == tagdate and ltxr == ltxrelease)

  elseif string.match(file, "CTANREADME%.md$") then
    local m_readmev, m_readmed = string.match(content, "Release%s+(v%d+%.%d+%a*)%s+\\%[(%d%d%d%d%-%d%d%-%d%d)\\%]")
    already_ok = (m_readmev == "v" .. tagname and m_readmed == tagdate)

  elseif string.match(file, "ctan%.ann$") then
    local annv = string.match(content, "v%d+%.%d+%a*")
    already_ok = (annv == "v" .. tagname)
  end

  if already_ok then
    print("** " .. file .. " is already up to date")
    return content
  end

  local original_content = content

  -- Substitutions in enumext.dtx
  if string.match(file, "enumext%.dtx$") then
    content = string.gsub(content, "(\\ProvidesExplPackage%s*{enumext}%s*){[^}]+}%s*{[^}]+}", "%1{" .. tagdate .. "} {" .. tagname .. "}")
    content = string.gsub(content, "(\\NeedsTeXFormat{LaTeX2e})%[%d%d%d%d%-%d%d%-%d%d%]", "%1[" .. ltxrelease .. "]")
  end

  -- Substitutions in enumext.sty
  if string.match(file, "enumext%.sty$") then
    content = string.gsub(content, "(\\ProvidesExplPackage%s*{enumext}%s*){[^}]+}%s*{[^}]+}", "%1{" .. tagdate .. "} {" .. tagname .. "}")
    content = string.gsub(content, "(\\NeedsTeXFormat{LaTeX2e})%[%d%d%d%d%-%d%d%-%d%d%]", "%1[" .. ltxrelease .. "]")
  end

  -- Substitutions in CTANREADME.md
  if string.match(file, "CTANREADME%.md$") then
    content = string.gsub(content, "Release v%d+%.%d+%a*%s*\\%[%d%d%d%d%-%d%d%-%d%d\\%]", "Release v" .. tagname .. " \\[" .. tagdate .. "\\]")
  end

  -- Substitutions in ctan.ann
  if string.match(file, "ctan%.ann$") then
    content = string.gsub(content, "v%d+%.%d+%a*", "v" .. tagname)
  end

  print("** " .. file .. " has been tagged with version " .. tagname .. " and date " .. tagdate)

  return content
end

-- Individual verification functions
local function check_dtx_tags()
  local content = read_file("sources/enumext.dtx")
  if not content then return false end

  local pkgd, pkgv = string.match(content, "\\ProvidesExplPackage%s*{enumext}%s*{(.-)}%s*{(.-)}")
  local ltxr = string.match(content, "\\NeedsTeXFormat%s*{LaTeX2e}%s*%[(%d%d%d%d%-%d%d%-%d%d)%]")

  if pkgv ~= pkgversion or pkgd ~= pkgdate or ltxr ~= ltxrelease then
    print("** Warning: Mismatches found in sources/enumext.dtx")
    return false
  end
  os_message("Checking version, date, and LaTeX release in enumext.dtx")
  return true
end

local function check_sty_tags()
  local content = read_file("sources/enumext.sty")
  if not content then return true end

  local pkgd, pkgv = string.match(content, "\\ProvidesExplPackage%s*{enumext}%s*{(.-)}%s*{(.-)}")
  local ltxr = string.match(content, "\\NeedsTeXFormat%s*{LaTeX2e}%s*%[(%d%d%d%d%-%d%d%-%d%d)%]")

  if pkgv ~= pkgversion or pkgd ~= pkgdate or ltxr ~= ltxrelease then
    print("** Warning: Mismatches found in sources/enumext.sty")
    return false
  end
  os_message("Checking version, date, and LaTeX release in enumext.sty")
  return true
end

local function check_readme_tags()
  local content = read_file("sources/CTANREADME.md")
  if not content then return false end

  local target_version = "v" .. pkgversion
  local m_readmev, m_readmed = string.match(content, "Release%s+(v%d+%.%d+%a*)%s+\\%[(%d%d%d%d%-%d%d%-%d%d)\\%]")

  if target_version ~= m_readmev or pkgdate ~= m_readmed then
    print("** Warning: Mismatches found in sources/CTANREADME.md")
    return false
  end
  os_message("Checking version and date in README.md")
  return true
end

-- Unified verification runner
local function check_all_tags()
  local ok_dtx = check_dtx_tags()
  local ok_sty = check_sty_tags()
  local ok_readme = check_readme_tags()
  return ok_dtx and ok_sty and ok_readme
end

-- Leave tag_hook empty so 'l3build tag' doesn't execute redundant checks after writing
function tag_hook(tagname)
end

-- Standalone audit target: l3build tagcheck
if options["target"] == "tagcheck" then
  if check_all_tags() then
    os.exit(0)
  else
    os.exit(1)
  end
end

-- Helper function to generate an isolated build environment --
local function system_temp_dir()
  local is_windows = package.config:sub(1, 1) == "\\"
  if is_windows then
    return os.getenv("TEMP") or os.getenv("TMP") or "C:\\Windows\\Temp"
  else
    return os.getenv("TMPDIR") or "/tmp"
  end
end

local function make_tmp_dir()
  -- Unified tag verification before unpacking
  if not check_all_tags() then
    error("** Error!!: Tag verification failed before preparing environment")
  end

  local sep = package.config:sub(1, 1)
  local base = system_temp_dir()
  local tmpname = os.tmpname()
  local unique = tmpname:match("([^/\\]+)$") or tostring(os.time())
  os.remove(tmpname) -- os.tmpname() sometimes creates an empty file; not needed

  tmpdir = base .. sep .. "enumext-build-" .. unique -- Global variable consumed by custom targets

  -- Create temporary directory
  local errorlevel = mkdir(tmpdir)
  if errorlevel ~= 0 then
    error("** Error!!: Could not create temporary directory " .. tmpdir)
  else
    os_message("Creating temporary directory " .. tmpdir)
  end

  -- Copy source files (.dtx and .ins)
  errorlevel = cp("*.dtx", sourcefiledir, tmpdir) + cp("*.ins", sourcefiledir, tmpdir)
  if errorlevel ~= 0 then
    error("** Error!!: Failed to copy source files to " .. tmpdir)
  else
    os_message("Copying enumext.dtx and enumext.ins to " .. tmpdir)
  end

  -- Unpack source files
  os_message("Unpacking source files in " .. tmpdir)
  local file = jobname("enumext.ins")
  errorlevel = run(tmpdir, "luatex -interaction=batchmode " .. file .. ".ins > " .. os_null)
  if errorlevel ~= 0 then
    local f = io.open(tmpdir .. "/" .. file .. ".log", "r")
    if f then
      print(f:read("*all"))
      f:close()
    end
    cp(file .. ".log", tmpdir, maindir)
    cp(file .. ".ins", tmpdir, maindir)
    error("** Error!!: Unpacking failed with luatex")
  else
    os_message("Successfully unpacked " .. file .. ".ins")
    rm(tmpdir, file .. ".log")
  end
  return 0
end

-- Custom target: l3build testpkg
if options["target"] == "testpkg" then
  make_tmp_dir()

  local errorlevel = cp("*.*", "sources/test-pkg", tmpdir)
  if errorlevel ~= 0 then
    error("** Error!!: Failed to copy test files from sources/test-pkg to " .. tmpdir)
  else
    os_message("Copied test files from sources/test-pkg to " .. tmpdir)
  end

  os_message("Compiling test files with arara")
  local samples = {"enumext-02", "enumext-03", "enumext-04", "enumext-05", "enumext-06", "enumext-07"}
  for _, sample in ipairs(samples) do
    errorlevel = run(tmpdir, "arara -v " .. sample .. ".tex")
    if errorlevel ~= 0 then
      local f = io.open(tmpdir .. "/" .. sample .. ".log", "r")
      if f then
        print(f:read("*all"))
        f:close()
      end
      error("** Error!!: arara compilation failed for " .. sample .. ".tex")
    end
  end

  errorlevel = cp("enumext-*.pdf", tmpdir, maindir)
  if errorlevel ~= 0 then
    error("** Error!!: Failed to copy generated PDF files to main directory")
  else
    os_message("Copied generated PDF files to main directory")
  end

  cleandir(tmpdir)
  lfs.rmdir(tmpdir)
  os_message("Removed temporary directory " .. tmpdir)
  os.exit(0)
end

-- Custom target: l3build examples
if options["target"] == "examples" then
  make_tmp_dir()

  local file = jobname("enumext.dtx")
  os_message("Extracting examples from " .. file .. ".dtx")

  local errorlevel = run(tmpdir, "lualatex-dev " .. file .. ".dtx > " .. os_null)
  if errorlevel ~= 0 then
    error("** Error!!: Example extraction failed on " .. file .. ".dtx")
  else
    os_message("Extracted examples from " .. file .. ".dtx")
  end

  os_message("Compiling example files with arara")
  local samples = {"enumext-exa-1", "enumext-exa-2", "enumext-exa-3", "enumext-exa-4", "enumext-exa-5", "enumext-exa-6"}
  for _, sample in ipairs(samples) do
    errorlevel = run(tmpdir, "arara " .. sample .. ".tex > " .. os_null)
    if errorlevel ~= 0 then
      local f = io.open(tmpdir .. "/" .. sample .. ".log", "r")
      if f then
        print(f:read("*all"))
        f:close()
      end
      cp(sample .. ".tex", tmpdir, maindir)
      cp(sample .. ".log", tmpdir, maindir)
      error("** Error!!: arara compilation failed for " .. sample .. ".tex")
    else
      os_message("Compiled " .. sample .. ".tex")
    end
  end

  errorlevel = cp("enumext-*.pdf", tmpdir, maindir)
  if errorlevel ~= 0 then
    error("** Error!!: Failed to copy generated PDF files to main directory")
  else
    os_message("Copied generated PDF files to main directory")
  end

  cleandir(tmpdir)
  lfs.rmdir(tmpdir)
  os_message("Removed temporary directory " .. tmpdir)
  os.exit(0)
end

-- Clean repo with Git
if options["target"] == "clean" then
  os_message("Cleaning untracked repository files with Git")
  os.execute("git clean -xdfq")
end

-- Capture shell output safely (e.g. for Git queries)
local function os_capture(cmd, raw)
  local f = io.popen(cmd, "r")
  if not f then return "" end

  local s = f:read("*a") or ""
  f:close()

  if raw then return s end

  s = string.gsub(s, "^%s+", "")
  s = string.gsub(s, "%s+$", "")
  s = string.gsub(s, "[\n\r]+", " ")
  return s
end

-- Target "release": performs pre-release checks for Git and CTAN
if options["target"] == "release" then
  -- 1. Verify working branch is 'main'
  local gitbranch = os_capture("git symbolic-ref --short HEAD")
  if gitbranch == "main" then
    os_message("Checking git branch 'main'")
  else
    error("** Error!!: You must be on the 'main' branch (currently on '" .. gitbranch .. "')")
  end

  -- 2. Verify clean working directory (before generating any build files)
  local gitstatus = os_capture("git status --porcelain")
  if gitstatus == "" then
    os_message("Checking working directory status")
  else
    error("** Error!!: Uncommitted changes detected. Please commit all changes before release.")
  end

  -- 3. Verify local commits are pushed
  local gitpush = os_capture("git log --branches --not --remotes")
  if gitpush == "" then
    os_message("Checking pending commits")
  else
    error("** Error!!: There are unpushed local commits. Run 'git push' first.")
  end

  -- 4. Audit version/date consistency across all files
  if not check_all_tags() then
    error("** Error!!: Tag verification failed. Update build.lua or run 'l3build tag'")
  end

  -- 5. Test source extraction via luatex
  local file = jobname(sourcefiledir .. "/enumext.ins")
  local errorlevel = run(sourcefiledir, "luatex --interaction=batchmode " .. file .. ".ins > " .. os_null)
  if errorlevel ~= 0 then
    error("** Error!!: Failed to process " .. file .. ".ins with luatex")
  else
    os_message("Unpacking " .. file .. ".ins with luatex")
  end

  -- 6. Tag commit in Git
  local tag_version = "v" .. pkgversion
  local tagongit = os_capture('git for-each-ref refs/tags --sort=-taggerdate --format="%(refname:short)" --count=1')
  os_message("Checking latest Git tag (latest: " .. (tagongit ~= "" and tagongit or "none") .. ")")

  local tag_cmd = string.format('git tag -a %s -m "Release %s %s"', tag_version, tag_version, pkgdate)
  local res = os.execute(tag_cmd)
  if res ~= 0 and res ~= true then
    error("** Error!!: Could not create Git tag " .. tag_version .. ". Verify if it already exists.")
  else
    os_message("Creating Git tag " .. tag_version)
  end

  os_message("Pushing Git tags to remote")
  os.execute("git push --tags --quiet")

  -- 7. Build CTAN package archive if absent
  if fileexists(ctanzip .. ".zip") then
    os_message("Checking CTAN package " .. ctanzip .. ".zip")
  else
    os_message("Building CTAN package " .. ctanzip .. ".zip")
    os.execute("l3build ctan > " .. os_null)
  end

  -- 8. Perform CTAN upload dry run
  os_message("Running dry-run upload check")
  os.execute("l3build upload -F ctan.ann --debug > " .. os_null)

  print("-----------------------------------------------------------------")
  print("** Pre-release checks completed successfully!")
  print("** Review '" .. ctanzip .. ".curlopt' and verify 'ctan.ann'")
  print("** To publish to CTAN, run manually: l3build upload")
  print("-----------------------------------------------------------------")
  os.exit(0)
end
