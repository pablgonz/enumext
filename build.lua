--[[
   Configuration script for l3build from the enumext package.
   At the moment the possible targets that can be passed are:
   * tag        : Update the version and date and regenerate the
                  enumext.sty copy in sources/
   * doc        : Generate the documentation [-q]
   * unpack     : Unpacks the source files [-q]
   * install    : Install the package locally, you can use
                  it in conjunction with [--full] [--dry-run]
   * uninstall  : Uninstall the package locally
   * clean      : Clean the directory tree and the files ignored by git
                  (only lists them with --dry-run; never removes files
                  that git does not ignore)
   * ctan       : Generate the compressed package (.zip); it first checks that
                  the PDFs of /test-pkg and /samples are up to date
   * upload     : Upload the package to ctan, you must add
                  -F ctan.ann in conjunction with [--debug]
   * tagcheck   : Check version and date in files
   * check      : Run the regression tests in /testfiles (LuaTeX, latex-dev,
                  two runs); l3build check test-001 runs only that test
   * save       : Save the reference (.tlg) of a test after reviewing its
                  output: l3build save test-001
   * testSE     : Compile (two runs) and validate the files in /test-pkg,
                  PDFs copied there
   * example    : Compile (one run) the files in /samples, PDFs copied there
   The targets testSE and example accept file names (with or without .tex)
   to run only those files: l3build example enumext-exa-2
   * release    : It performs the checks before generating a public
                  release (on git and ctan), commits the PDFs that
                  example, testSE and ctan regenerate and creates the
                  git tag.
--]]

-- General package identification
module     = "enumext"
pkgversion = "2.4"
pkgdate    = "2026-11-01"
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

-- Regression tests (l3build check / save): the .lvt files in ./testfiles.
-- ltxrelease needs the development format, so the tests run with latex-dev.
-- Tests without tagging (test-001...) compare the boxes written to the log;
-- tests with tagging (test-010...) compare the tag tree (\SHOWPDFTAGS).
testfiledir  = "./testfiles"
checkengines = { "luatex" }
stdengine    = "luatex"
checkformat  = "latex-dev"

-- test-100 writes a file with anskey* (key write-env); it is removed before
-- each run so that the messages (writing / not writing / overwriting) repeat.
dynamicfiles = { "test-100-*.txt" }

-- Two runs per test: the references (\ref, \getkeyans) are resolved in the
-- second one, as in the documents of l3build testSE.
checkruns = 2

-- The structure elements of the tagged tests carry sequential ids
-- (ID.00012, ...): one node more or less would shift all the following ones
-- and flood the diff, so the ids are not compared.
function normalize_log_hook(line)
  return (string.gsub(line, 'id="ID%.%d+"', 'id="ID.NN"'))
end

-- Typesetting enumext documentation step by step :)

function docinit_hook()
  local errorlevel = (cp("*mylhmc.lua", sourcefiledir, typesetdir) + cp("*mylhmc.sty", sourcefiledir, typesetdir))
  if errorlevel ~= 0 then
    error("** Error!!: Can't copy mylhmc.lua and mylhmc.sty files from "..sourcefiledir.." to "..typesetdir)
  end
  -- Examples attached to the manual: what is in sources/test-pkg and in
  -- sources/samples is copied as it is. Nothing is checked here
  local testdir = sourcefiledir.."/test-pkg"
  if direxists(testdir) then
    cp("*.tex", testdir, typesetdir)
    cp("*.pdf", testdir, typesetdir)
  end
  local smpdir = sourcefiledir.."/samples"
  if direxists(smpdir) then
    cp("*.tex", smpdir, typesetdir)
  end
  return 0
end

function typeset(file)
  local file = jobname(sourcefiledir.."/enumext.dtx")
  print("** Running: arara "..file..".dtx")
  local errorlevel = runcmd("arara "..file..".dtx", typesetdir, {"TEXINPUTS","LUAINPUTS"})
  if errorlevel ~= 0 then
    error("Error!!: Typesetting "..file..".dtx")
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
  version      = pkgversion .. " " .. pkgdate,
  license      = "lppl1.3c",
  summary      = "Enumerate exercise sheets",
  description  = "This package provides enumerated list environments compatible with tagging PDF for creating "
    .. "“simple exercise sheets” along with “multiple choice questions”, storing the “answers” to these in memory "
    .. "using multicol package.",
  topic        = { "exercise", "list-enum", "list", "tagged-pdf" },
  ctanPath     = "/macros/latex/contrib/" .. ctanpkg,
  repository   = "https://github.com/pablgonz/" .. module,
  bugtracker   = "https://github.com/pablgonz/" .. module .. "/issues",
  support      = "https://github.com/pablgonz/" .. module .. "/issues",
  note         = [[Uploaded automatically by l3build...]],
  announcement_file="ctan.ann",
  update       = true
}

-- Clean files (enumext.pdf is versioned in git, so clean must not remove it)
cleanfiles = {ctanzip..".curlopt", ctanzip..".zip"}

-- Update package date and version
tagfiles = {
  "sources/enumext.dtx",
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

  -- Substitutions in enumext.dtx
  if string.match(file, "enumext%.dtx$") then
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
  os_message("Checking version and date in CTANREADME.md")
  return true
end

-- Unified verification runner
local function check_all_tags()
  local ok_dtx = check_dtx_tags()
  local ok_sty = check_sty_tags()
  local ok_readme = check_readme_tags()
  return ok_dtx and ok_sty and ok_readme
end

-- Regenerates the copy of enumext.sty in sources/ from the .dtx and the .ins,
-- so that it carries what 'l3build tag' just wrote in the .dtx.
local function unpack_copies()
  local file = jobname(sourcefiledir .. "/enumext.ins")
  local errorlevel = run(sourcefiledir, "luatex --interaction=batchmode " .. file .. ".ins > " .. os_null)
  if errorlevel ~= 0 then
    error("** Error!!: Failed to process " .. file .. ".ins with luatex")
  end
  rm(sourcefiledir, file .. ".log")
  os_message("Regenerated the .sty copy from " .. file .. ".ins")
end

-- 'l3build tag' does not run redundant checks after writing; it only
-- regenerates the .sty copy in sources/ (commit it afterwards)
function tag_hook(tagname)
  unpack_copies()
  return 0
end

-- Standalone audit target: l3build tagcheck
target_list.tagcheck = {
  desc = "Check version and date in files",
  help = "Reports every file whose version or date differs from build.lua.",
  func = function()
    if check_all_tags() then return 0 end
    return 1
  end,
}

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

  -- Copy source files (only enumext.dtx and enumext.ins)
  errorlevel = cp(module .. ".dtx", sourcefiledir, tmpdir) + cp(module .. ".ins", sourcefiledir, tmpdir)
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

-- Names (without extension) of the .tex files in srcdir. Only plain file
-- names are accepted because they end up in shell commands.
local function list_samples(srcdir, skip)
  if not direxists(srcdir) then
    error("** Error!!: Directory " .. srcdir .. " not found")
  end
  local samples = {}
  for file in lfs.dir(srcdir) do
    local name = file:match("^([%w%-_]+)%.tex$")
    if name then
      table.insert(samples, name)
    elseif file:match("%.tex$") then
      print("** Warning: skipping " .. file .. " (unsafe file name)")
    end
  end
  table.sort(samples)
  if #samples == 0 then
    error("** Error!!: No .tex files found in " .. srcdir)
  end
  -- Keeps only the names given on the command line (l3build example name ...);
  -- with no names all the files are kept, except those in 'skip'. A name given
  -- explicitly is always run. A name can be written with or without the .tex
  -- extension.
  local wanted = options["names"]
  if not wanted or #wanted == 0 then
    if not skip then return samples end
    local kept = {}
    for _, name in ipairs(samples) do
      if skip[name] then
        print("** Warning: skipping " .. name .. ".tex (temporarily excluded)")
      else
        table.insert(kept, name)
      end
    end
    return kept
  end
  local exists = {}
  for _, name in ipairs(samples) do exists[name] = true end
  local selected = {}
  for _, arg_name in ipairs(wanted) do
    local name = (arg_name:gsub("%.tex$", ""))
    if not exists[name] then
      error("** Error!!: " .. name .. ".tex not found in " .. srcdir)
    end
    table.insert(selected, name)
  end
  return selected
end

-- On errors the temporary directory is kept, so the logs can be inspected
local function fail(msg)
  print("** Temporary directory kept for inspection: " .. tmpdir)
  error(msg)
end

-- Extensions of the files that a compilation leaves behind
local generated_ext = {
  aux = true, log = true, out = true, toc = true, lof = true, lot = true,
  nav = true, snm = true, vrb = true, bbl = true, blg = true, fls = true,
  tuc = true, xdv = true, gz = true, fdb_latexmk = true,
}

-- Copies to the temporary directory what the examples in srcdir need: every
-- file except the leftovers of a compilation and the PDF of each .tex (the PDF
-- is the result, not an input). Returns the number of files copied or, on
-- failure, nil and the name of the file.
local function copy_inputs(srcdir)
  local tex = {}
  for file in lfs.dir(srcdir) do
    local name = file:match("^(.+)%.tex$")
    if name then tex[name] = true end
  end
  local count = 0
  for file in lfs.dir(srcdir) do
    local name, ext = file:match("^(.+)%.([^.]+)$")
    if name and lfs.attributes(srcdir .. "/" .. file, "mode") == "file"
       and not generated_ext[ext] and not (ext == "pdf" and tex[name]) then
      if cp(file, srcdir, tmpdir) ~= 0 then return nil, file end
      count = count + 1
    end
  end
  return count
end

-- Helper to detect whether an executable is in the PATH (Windows and Linux)
local function has_cmd(cmd)
  local is_windows = package.config:sub(1, 1) == "\\"
  local null_dev = os_null or (is_windows and "NUL" or "/dev/null")
  local check = is_windows and ("where " .. cmd .. " > " .. null_dev .. " 2>&1")
                           or ("command -v " .. cmd .. " > " .. null_dev .. " 2>&1")
  local res = os.execute(check)
  return (res == true or res == 0)
end

local function show_log(dir, name)
  local f = io.open(dir .. "/" .. name .. ".log", "r")
  if f then
    print(f:read("*all"))
    f:close()
  end
end

-- PDF validators (the ones that are installed)
local run_rnv, run_verapdf

local function announce_validators()
  run_rnv = has_cmd("rnv-wrapp") and has_cmd("show-pdf-tags")
  run_verapdf = has_cmd("verapdf")
  if run_rnv and run_verapdf then
    os_message("Validators detected: show-pdf-tags, rnv-wrapp & veraPDF")
  elseif run_rnv then
    os_message("Validators detected: show-pdf-tags & rnv-wrapp")
  elseif run_verapdf then
    os_message("Validator detected: veraPDF")
  end
end

local function validate_pdf(dir, pdf_file)
  if run_rnv then
    local cmd_rnv = "show-pdf-tags --xml " .. pdf_file .. " | rnv-wrapp"
    if run(dir, cmd_rnv .. " > " .. os_null) ~= 0 then
      print("\n[RNC Validation Error Output]:")
      run(dir, cmd_rnv)
      fail("** Error!!: Tag structure validation (rnv-wrapp) failed for " .. pdf_file)
    end
  end
  if run_verapdf then
    local cmd_vera = "verapdf --flavour ua2 --format text " .. pdf_file
    if run(dir, cmd_vera .. " > " .. os_null) ~= 0 then
      print("\n[PDF/UA-2 Validation Error Output]:")
      run(dir, cmd_vera)
      fail("** Error!!: veraPDF (PDF/UA-2) validation failed for " .. pdf_file)
    end
  end
  if run_rnv or run_verapdf then
    print("PASS")
  end
end

-- Compile every .tex in srcdir with lualatex-dev inside the temporary
-- directory and copy each PDF back to srcdir (they are versioned there).
-- opts.passes : number of lualatex-dev runs per file
-- opts.validate : validate the PDF after the last run
-- opts.skip : table of names (without extension) that are not run
local function compile_samples(srcdir, label, opts)
  local samples = list_samples(srcdir, opts.skip)
  make_tmp_dir()

  local copied, bad = copy_inputs(srcdir)
  if not copied then
    fail("** Error!!: Failed to copy " .. bad .. " from " .. srcdir .. " to " .. tmpdir)
  end
  os_message("Copied " .. copied .. " " .. label .. " files from " .. srcdir .. " to " .. tmpdir)

  if opts.validate then
    announce_validators()
  end

  for _, sample in ipairs(samples) do
    for pass = 1, opts.passes do
      os_message("Compiling " .. sample .. ".tex (run " .. pass .. " of " .. opts.passes .. ")")
      if run(tmpdir, "lualatex-dev -interaction=nonstopmode " .. sample .. ".tex > " .. os_null) ~= 0 then
        show_log(tmpdir, sample)
        fail("** Error!!: lualatex-dev compilation failed for " .. sample .. ".tex (run " .. pass .. ")")
      end
    end
    if opts.validate then
      validate_pdf(tmpdir, sample .. ".pdf")
    end
    if cp(sample .. ".pdf", tmpdir, srcdir) ~= 0 then
      fail("** Error!!: Failed to copy " .. sample .. ".pdf to " .. srcdir)
    end
    os_message("OK: " .. sample .. ".tex, copied " .. sample .. ".pdf to " .. srcdir)
  end

  os_message("All " .. #samples .. " " .. label .. " files compiled")
  cleandir(tmpdir)
  lfs.rmdir(tmpdir)
  os_message("Removed temporary directory " .. tmpdir)
end

-- Custom target: l3build testSE
-- Compiles twice and validates the files in sources/test-pkg; the PDFs are
-- left there.
target_list.testSE = {
  desc = "Compile (two runs) and validate the files in /test-pkg",
  help = "Accepts file names, with or without .tex: l3build testSE enumext-02",
  func = function()
    compile_samples(sourcefiledir .. "/test-pkg", "test", {
      passes = 2,
      validate = true,
    })
    return 0
  end,
}

-- Custom target: l3build example
-- Compiles once the files in sources/samples; the PDFs are left there
target_list.example = {
  desc = "Compile (one run) the files in /samples",
  help = "Accepts file names, with or without .tex: l3build example enumext-exa-2",
  func = function()
    compile_samples(sourcefiledir .. "/samples", "example", { passes = 1, validate = false })
    return 0
  end,
}

-- The PDFs attached to the manual are the ones that 'l3build testSE' and
-- 'l3build example' leave in sources/test-pkg and sources/samples. Before
-- packaging, check that all of them exist and are not older than their .tex
-- (target ctan and release only; doc copies what is there without checking).
local function check_example_pdfs()
  local stale = {}
  local dirs = {
    { dir = sourcefiledir .. "/test-pkg" },
    { dir = sourcefiledir .. "/samples" },
  }
  for _, entry in ipairs(dirs) do
    for _, sample in ipairs(list_samples(entry.dir, entry.skip)) do
      local tex = lfs.attributes(entry.dir .. "/" .. sample .. ".tex", "modification")
      local pdf = sample .. ".pdf"
      local mod = lfs.attributes(entry.dir .. "/" .. pdf, "modification")
      if not mod then
        table.insert(stale, entry.dir .. "/" .. pdf .. " (missing)")
      elseif mod < tex then
        table.insert(stale, entry.dir .. "/" .. pdf .. " (older than " .. sample .. ".tex)")
      end
    end
  end
  if #stale > 0 then
    error("** Error!!: PDFs of the examples out of date, run 'l3build example' and 'l3build testSE' first:\n   "
      .. table.concat(stale, "\n   "))
  end
  os_message("Checking PDFs of sources/test-pkg and sources/samples")
end

if options["target"] == "ctan" then
  check_example_pdfs()
end

-- Clean repo with Git
-- 'git clean -X' removes only the files ignored by .gitignore (build/, logs,
-- ...), so it needs no confirmation. Untracked files that are not ignored
-- (new files not yet added) are never removed: they are only listed.
-- With --dry-run it only lists. The lists come from 'git ls-files' (plain
-- paths): the messages of 'git clean' are translated and show badly here.
if options["target"] == "clean" then
  local function git_out(cmd)
    local f = io.popen(cmd .. " 2>&1", "r")
    if not f then return nil end
    local out = f:read("*a") or ""
    f:close()
    return out
  end

  local inside = git_out("git rev-parse --is-inside-work-tree")
  if not inside or not inside:match("^true") then
    os_message("Not a Git work tree: skipping git clean")
  else
    local preview = git_out("git ls-files --others --ignored --exclude-standard --directory")
    if not preview or preview:match("^%s*$") then
      os_message("Nothing to clean with Git")
    else
      print("** Ignored files and directories removed by git clean:")
      io.write(preview)
      if options["dry-run"] then
        os_message("Dry run: nothing removed")
      else
        os_message("Cleaning ignored repository files with Git")
        local res = os.execute("git clean -Xdfq")
        if res ~= 0 and res ~= true then
          error("** Error!!: git clean failed")
        end
      end
    end
    local kept = git_out("git ls-files --others --exclude-standard --directory")
    if kept and not kept:match("^%s*$") then
      print("** Untracked files NOT removed (add them or delete them by hand):")
      io.write(kept)
    end
  end
  -- No os.exit() here so that l3build goes on cleaning the build/ directory
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

-- Run another l3build target quietly; its failure stops the release
local function run_l3build(tgt, extra)
  os_message("Running 'l3build " .. tgt .. "'" .. (extra or ""))
  local res = os.execute("l3build " .. tgt .. " > " .. os_null)
  if res ~= 0 and res ~= true then
    error("** Error!!: 'l3build " .. tgt .. "' failed (run it alone to see why); nothing was tagged or pushed")
  end
end

-- Run a git command; its failure stops the release with the given message
local function run_git(cmd, msg)
  local res = os.execute(cmd)
  if res ~= 0 and res ~= true then
    error(msg)
  end
end

-- Target "release": performs pre-release checks for Git and CTAN
local function release_target()
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

  -- 6. Build CTAN package archive if absent
  if fileexists(ctanzip .. ".zip") then
    os_message("Checking CTAN package " .. ctanzip .. ".zip")
  else
    -- The PDFs attached to the manual are regenerated first: the ctan
    -- target refuses to run if they are missing or older than their .tex
    run_l3build("example", " (PDFs of sources/samples)")
    run_l3build("testSE", " (PDFs of sources/test-pkg)")
    run_l3build("ctan", " (" .. ctanzip .. ".zip)")
  end

  -- 7. Perform CTAN upload dry run. With --debug l3build prints the fields of
  -- the form and then posts it to httpbin.org, which can refuse the zip (body
  -- too large) or be down; l3build exits with status 1 in any case. So the
  -- check looks at the fields that l3build prints (package and version), not
  -- at the answer of the server.
  os_message("Running dry-run upload check")
  local dryrun = os_capture("l3build upload -F ctan.ann --debug 2>&1", true)
  local okpkg = string.find(dryrun, "ctan-upload | pkg: " .. ctanpkg .. "\n", 1, true)
  local okver = string.find(dryrun, "ctan-upload | version: " .. uploadconfig.version .. "\n", 1, true)
  if not (okpkg and okver) then
    error("** Error!!: dry-run upload check failed; nothing was tagged or pushed")
  end

  -- 8. Commit what the steps above regenerated (enumext.pdf, enumext.sty and
  -- the PDFs versioned in git), so that the tag points to the commit that
  -- matches the zip. The working directory was clean in step 2: only
  -- regenerated files can have changed.
  local regenerated = os_capture("git status --porcelain --untracked-files=no")
  if regenerated == "" then
    os_message("No regenerated files to commit")
  else
    local commit_msg = "Release v" .. pkgversion .. " [" .. pkgdate .. "]"
    run_git("git add -u", "** Error!!: 'git add -u' failed; nothing was tagged or pushed")
    run_git('git commit --quiet -m "' .. commit_msg .. '"', "** Error!!: 'git commit' failed; nothing was tagged or pushed")
    os_message("Committing regenerated files: " .. commit_msg)
    run_git("git push --quiet", "** Error!!: 'git push' failed. The commit exists locally; push it manually.")
    os_message("Pushing the commit to remote")
  end

  -- 9. Tag commit in Git (only after everything above succeeded)
  local tag_version = "v" .. pkgversion
  local tagongit = os_capture('git for-each-ref refs/tags --sort=-taggerdate --format="%(refname:short)" --count=1')
  os_message("Checking latest Git tag (latest: " .. (tagongit ~= "" and tagongit or "none") .. ")")

  local tag_cmd = string.format('git tag -a %s -m "Release %s %s"', tag_version, tag_version, pkgdate)
  run_git(tag_cmd, "** Error!!: Could not create Git tag " .. tag_version .. ". Verify if it already exists.")
  os_message("Creating Git tag " .. tag_version)

  os_message("Pushing Git tags to remote")
  run_git("git push --tags --quiet", "** Error!!: 'git push --tags' failed. The tag " .. tag_version .. " exists locally; push it manually.")

  print("-----------------------------------------------------------------")
  print("** Pre-release checks completed successfully!")
  print("** Review '" .. ctanzip .. ".curlopt' and verify 'ctan.ann'")
  print("** To publish to CTAN, run manually: l3build upload")
  print("-----------------------------------------------------------------")
  return 0
end

target_list.release = {
  desc = "Checks before a public release (git and ctan), then tags and pushes",
  help = "Runs the checks, creates the git tag and pushes it; then run l3build upload by hand.",
  func = release_target,
}
