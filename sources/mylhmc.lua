-- mylhmc.lua v0.99 2026-10-24
-- LuaLaTeX syntax highlighter for l3doc macrocode environments

local require      = require
local pcall        = pcall
local ipairs       = ipairs
local pairs        = pairs
local tonumber     = tonumber
local t_unpack     = table.unpack or unpack

local s_sub        = string.sub
local s_find       = string.find
local s_match      = string.match
local s_format     = string.format
local s_gsub       = string.gsub
local s_gmatch     = string.gmatch
local s_byte       = string.byte
local s_lower      = string.lower
local s_rep        = string.rep

local u_codes      = utf8.codes

local d_new        = node.direct.new
local d_copy       = node.direct.copy
local d_copylist   = node.direct.copy_list
local d_tonode     = node.direct.tonode
local d_setlink    = node.direct.setlink
local d_getnext    = node.direct.getnext
local d_tail       = node.direct.tail or function(t)
  while d_getnext(t) do t = d_getnext(t) end
  return t
end
local d_setfield   = node.direct.setfield
local n_write      = node.write

local f_current    = font.current
local f_getfont    = font.getfont
local f_max        = font.max

local t_get_macro    = token.get_macro
local t_set_macro    = token.set_macro
local t_scan_arg     = token.scan_argument
local t_scan_int     = token.scan_int
local t_scan_dimen   = token.scan_dimen
local t_scan_glue    = token.scan_glue
local t_scan_toks    = token.scan_toks
local t_scan_word    = token.scan_word
local token_set_lua  = token.set_lua

local kpse_find      = kpse.find_file
local f_read         = fonts and fonts.constructors and fonts.constructors.readanddefine
local f_hashes       = fonts and fonts.hashes and fonts.hashes.identifiers

local mod_warning    = luatexbase.module_warning
local mod_error      = luatexbase.module_error

if not (f_read and f_hashes) then
  mod_error('mylhmc',
    'luaotfload (fontloader) is not loaded; load fontspec or luaotfload first.')
  -- Si el error se ignora, evitamos nil-index posteriores.
  f_read   = function() return nil end
  f_hashes = {}
end

-- Avisa una sola vez por clave (evita inundar el log).
local warned = {}
local function warn_once(key, msg)
  if not warned[key] then
    warned[key] = true
    mod_warning('mylhmc', msg)
  end
end

local luatexbase_new = luatexbase.new_luafunction
local lua_get_funcs  = lua.get_functions_table

local current_module_name   = ''
local current_module_prefix = ''

-- Respaldo de nombre de módulo para \myhlc/macrocode (fijado desde
-- \setmylhmc{module=...} en el .sty) -- nunca toca
-- \g__codedoc_module_name_tl (variable global de l3doc.cls).
local module_name_backup = ''

local lpeg_base  = lpeg or require('lpeg')
local P, S, V    = lpeg_base.P, lpeg_base.S, lpeg_base.V
local Cp, Cc     = lpeg_base.Cp, lpeg_base.Cc
local lpeg_match = lpeg_base.match
lpeg_base.locale(lpeg_base)
local alpha      = lpeg_base.alpha
local digit      = lpeg_base.digit

local scan_map = {
  string = t_scan_arg,
  int    = t_scan_int,
  dimen  = t_scan_dimen,
  glue   = t_scan_glue,
  toks   = t_scan_toks,
  word   = t_scan_word
}

local function register_tex_cmd(name, func, args)
  name = '__mylhmc_' .. name .. ':' .. s_rep('n', #args)
  local scanners = {}
  for i = 1, #args do
    scanners[i] = scan_map[args[i]] or t_scan_arg
  end
  local scanning_func
  if #scanners == 0 then
    scanning_func = func
  elseif #scanners == 1 then
    local s1 = scanners[1]
    scanning_func = function() func(s1()) end
  elseif #scanners == 2 then
    local s1, s2 = scanners[1], scanners[2]
    scanning_func = function() func(s1(), s2()) end
  else
    scanning_func = function()
      local values = {}
      for i = 1, #scanners do values[i] = scanners[i]() end
      func(t_unpack(values))
    end
  end
  local index = luatexbase_new(name)
  lua_get_funcs()[index] = scanning_func
  token_set_lua(name, index, 'global', 'protected')
end

register_tex_cmd('luafun_set_module_backup', function(name)
  module_name_backup = name or ''
end, {'string'})

local sig_chars  = S'NnVvoxefpTFwDcq'
local hex_chars  = S'0123456789abcdefABCDEF'
local name_chars = alpha + S'_@'
local var_prefix = P'\\' * S'lg'
local name_chars_no_at = alpha + S'_'
-- Acepta también #N (uno o más '#' + un dígito, con espacios
-- opcionales a los lados) como parte del nombre -- usada en
-- \l_.../\g_... (tipos 2/4) para documentar el patrón de una familia
-- de csnames generadas dinámicamente (p.ej. \l_@@_foo_#1_bar). El
-- '#N' se recolorea aparte en el handler correspondiente.
local name_chars_argnum = name_chars
  + (P' ' ^ 0 * P'#' ^ 1 * digit * P' ' ^ 0)

-- "Modo csname": un argumento de \myhlc que es EXACTAMENTE (de
-- principio a fin) un nombre l_.../g_.../l__.../g__... sin backslash
-- -- para referirse al "nombre" de una csname sin su forma de
-- invocación. Solo en el handler de \myhlc; en macrocode normal un
-- fragmento así sin \ sería casi seguro texto de comentario.
local bare_varname_full =
  S'lg' * (P'__' * name_chars_argnum ^ 1
           + P'_' * (alpha + S'@') * name_chars_argnum ^ 0) * P(-1)

-- Las piezas de patrón *_names/etc. de aquí en adelante solo sirven
-- para construir code_rules (debajo); el do...end evita que cuenten
-- como locales de nivel superior (límite de Lua: 200 por chunk).
local code_rules
do
local structure_names =
  P'NeedsTeXFormat' + P'ProvidesExplPackage' +
  P'ExplSyntaxOn' + P'ExplSyntaxOff' +
  P'makeatletter' + P'makeatother'

local pkgstruct_names =
  P'ProvidesPackage' + P'ProvidesFile' + P'ProvidesClass' +
  P'RequirePackageWithOptions' + P'RequirePackage' +
  P'LoadClassWithOptions' + P'LoadClass' +
  P'PassOptionsToPackage' + P'PassOptionsToClass' +
  P'DocumentMetadata' +
  P'IfFormatAtLeast'    * (P'TF' + P'T' + P'F') ^ -1 +
  P'IfPackageLoaded'    * (P'WithOptions') ^ -1 * (P'TF' + P'T' + P'F') ^ -1 +
  P'IfFileExists'       * (P'TF' + P'T' + P'F') ^ -1 +
  P'IfDocumentMetadata' * (P'TF' + P'T' + P'F') ^ -1 +
  P'NewHook' + P'NewReversedHook' + P'NewMirroredHookPair' +
  P'AddToHook' * (P'WithArguments') ^ -1 +
  P'RemoveFromHook' + P'UseHook' + P'UseOneTimeHook' +
  P'IfHookEmpty' * (P'TF' + P'T' + P'F') +
  P'DeclareHookRule' + P'ClearHookRule' + P'ClearHook' +
  P'SetDefaultHookLabel' + P'PushDefaultHookLabel' + P'PopDefaultHookLabel' +
  P'ShowHook' + P'LogHook' +
  P'NewProperty' + P'SetProperty' +
  P'RecordProperties' + P'RecordProperty' + P'RefProperty' +
  P'IfPropertyExists'   * (P'TF' + P'T' + P'F') +
  P'IfLabelExists'      * (P'TF' + P'T' + P'F') +
  P'IfPropertyRecorded' * (P'TF' + P'T' + P'F')

-- +, &&, ||, ! sueltos (aritmética/lógica de expl3, p.ej. dentro de
-- \bool_if:nTF { ... }). '-' queda fuera: colisiona con nombres de
-- clave kebab-case (read-sign). '*'/'('/')' quedan para una fase
-- aparte (necesitan distinguir contexto).
local mylhmc_arith_logic_op = P'&&' + P'||' + P'!' + P'+'

-- Familia hyperref: comandos públicos, ninguno con prefijo real de otro
-- (todos divergen justo tras "hyper" o son nombres completamente
-- distintos), así que el orden dentro de la alternancia no es crítico.
local support_names =
  P'hyperlink' + P'hypertarget' + P'hyperbaseurl' + P'hyperimage' +
  P'hyperdef' + P'hyperget' + P'hypersetup' + P'hyperref' +
  P'href' + P'nolinkurl' + P'url' +
  P'autopageref' + P'autoref' +
  P'pdfstringdef' +
  P'currentpdfbookmark' + P'subpdfbookmark' + P'belowpdfbookmark' + P'pdfbookmark' +
  P'texorpdfstring' + P'phantomsection' +
  -- fontspec: sin colisiones de prefijo entre sí (verificado con texlua).
  P'setmainfont' + P'setsansfont' + P'setmonofont' + P'fontspec' +
  P'setboldmathrm' + P'setmathrm' + P'setmathsf' + P'setmathtt' +
  P'IfFontExistsTF' + P'addfontfeature' + P'defaultfontfeatures' +
  -- unicode-math:
  P'setmathfont' + P'unimathsetup'

local mathtag_names =
  P'MathMLintent' + P'MathMLarg' +
  P'luamml_annotate:nen' + P'luamml_annotate:en' +
  P'luamml_attribute:een' + P'luamml_attribute_core:een' +
  P'luamml_begin_single_file:' + P'luamml_end_single_file:' +
  P'luamml_flag_ignore:' + P'luamml_flag_process:' +
  P'luamml_flag_save:nNn' + P'luamml_flag_save:nN' +
  P'luamml_flag_save:nn' + P'luamml_flag_save:n' +
  P'luamml_get_last_mathml_stream:e' +
  P'luamml_ignore:' + P'luamml_pdf_write:' + P'luamml_process:' +
  P'luamml_register_output_hook:N' +
  P'luamml_save:nNn' + P'luamml_save:nN' +
  P'luamml_save:nn' + P'luamml_save:n' +
  P'luamml_set_filename:n' + P'luamml_structelem:' +
  P'tag_start:n' + P'tag_start:' +
  P'tag_stop:n' + P'tag_stop:' +
  P'tag_suspend:n' + P'tag_resume:n' +
  P'tag_get:n' +
  P'tag_if_active_p:' + P'tag_if_active:' * (P'TF' + P'T' + P'F') ^ -1 +
  P'tag_if_box_tagged:N' * (P'TF' + P'T' + P'F') ^ -1 +
  P'tag_if_in:n' * (P'TF' + P'T' + P'F') ^ -1 +
  P'tag_mc_add_missing_to_stream:Nn' +
  P'tag_mc_artifact_group_begin:n' + P'tag_mc_artifact_group_end:' +
  P'tag_mc_begin_pop:n' + P'tag_mc_begin:n' +
  P'tag_mc_end_push:' + P'tag_mc_end:' +
  P'tag_mc_if_in:' * (P'TF' + P'T' + P'F') ^ -1 +
  P'tag_mc_new_stream:n' +
  P'tag_mc_reset_box:N' +
  P'tag_mc_use:n' +
  P'tag_socket_use:nnn' + P'tag_socket_use:nn' + P'tag_socket_use:n' +
  P'tag_socket_use_expandable:n' +
  P'tag_spacechar_off:' + P'tag_spacechar_on:' +
  P'tag_check_child:nn' +
  P'tag_struct_begin:n' +
  P'tag_struct_end:n' + P'tag_struct_end:' +
  P'tag_struct_use_num:n' + P'tag_struct_use:n' +
  P'tag_struct_object_ref:n' +
  P'tag_struct_insert_annot:nn' +
  P'tag_struct_parent_int:' +
  P'tag_struct_gput_ref:nnn' + P'tag_struct_gput:nnn' +
  -- latex-lab-math / latex-lab-mathintent: comandos públicos del sistema
  -- de tagging de matemáticas -- mismo color 'mathtag', sin firma expl3
  -- ni estado especial (ninguno activa in_mathml_intent/in_mathml_arg).
  P'MathCollectTrue' + P'MathCollectFalse' + P'm@th' +
  P'SuspendTagging' + P'UseMathForPositioningText' + P'UseStructureName' +
  P'invisibletimes' + P'functionapplication' +
  -- tagpdf: comandos públicos estilo LaTeX2e (sin guión bajo, no
  -- colisionan con los \tag_*:n de arriba, que sí llevan guión bajo).
  P'tagpdfsetup' + P'tagtool' + P'tag_tool:n' +
  P'tagmcifinTF' + P'tagmcuse' + P'tagmcbegin' + P'tagmcend' +
  P'tagstructbegin' + P'tagstructend' + P'tagstructuse' +
  P'ShowTagging'

local keys_names =
  P'keys_define:' * S'Ncn' * P'n' +
  P'keys_set:'    * S'Ncn' * P'n'

-- Resto de la familia \keys_...:n... (l3keys) cuyo PRIMER argumento es
-- siempre {módulo} o {módulo/path}, pero cuyo SEGUNDO argumento cambia
-- de significado según la función (lista de claves, lista de grupos,
-- nombre de clave único, etc.) -- por eso solo coloreamos el primero,
-- sin extender el tratamiento de "cuerpo de claves" como en .meta/keys_define.
-- Orden: nombres más largos antes que sus prefijos (set_known/set_groups/
-- set_exclude_groups antes de cualquier 'set' bare, que ya cubre keys_names).
local keys_module_arg_names =
  P'keys_' *
  (P'set_exclude_groups' + P'set_groups' + P'set_known' +
   P'precompile' +
   P'if_choice_exist_p' + P'if_choice_exist' +
   P'if_exist_p' + P'if_exist' +
   P'show' + P'log' +
   P'set') *   -- keys_set:nv/nV/ne... (keys_set:nn lo cubre keys_names)
  P':' * P'n' * sig_chars ^ 0

-- \file_..., \lua_load_module:n, y la familia clásica \input/\include/
-- \InputIfFileExists: primer argumento = nombre de archivo. Cada literal
-- incluye su propio ':' (los nombres expl3 no comparten prefijo real
-- una vez incluido el ':', porque divergen en la letra siguiente).
local file_arg_names =
  P'file_input_raw:'          * sig_chars ^ 1 +
  P'file_input:'              * sig_chars ^ 1 +
  P'file_if_exist_input:'     * sig_chars ^ 1 +
  P'file_if_exist_p:'         * sig_chars ^ 1 +
  P'file_if_exist:'           * sig_chars ^ 1 +
  P'file_forget:'             * sig_chars ^ 1 +
  P'file_hex_dump:'           * sig_chars ^ 1 +
  P'file_get_full_name:'      * sig_chars ^ 1 +
  P'file_get:'                * sig_chars ^ 1 +
  P'file_full_name:'          * sig_chars ^ 1 +
  P'file_parse_full_name_apply:' * sig_chars ^ 1 +
  P'file_parse_full_name:'    * sig_chars ^ 1 +
  P'lua_load_module:'         * sig_chars ^ 1 +
  -- Los clásicos solo valen como palabra completa: \inputlineno o
  -- \includegraphics NO son \input / \include.
  (P'includeonly' + P'input' + P'include' + P'InputIfFileExists') * -(alpha + P'@')

-- \hook_gput_code:nnn, \hook_gput_code_with_args:nnn, \hook_gremove_code:nn
-- (label en arg2) y \hook_gset_rule:nnnn (labels en arg2 Y arg4). El
-- argumento 'hook' (arg1) y 'code'/'relation' (arg3) NO se tocan aquí:
-- siguen su coloreado normal (código real en el caso de 'code').
local hook_label_names =
  P'hook_gput_code_with_args:' * sig_chars ^ 1 +
  P'hook_gput_code:'           * sig_chars ^ 1 +
  P'hook_gremove_code:'        * sig_chars ^ 1 +
  P'hook_gset_rule:'           * sig_chars ^ 1

-- Convención de nombres de hook predefinidos: package/NOMBRE/before,
-- class/NOMBRE/after, file/NOMBRE.ext/before, etc. Global: aparece como
-- texto plano dentro del argumento {hook} de \UseHook, \AddToHook,
-- \hook_use:n, \hook_new:n, el propio arg1 de la familia de arriba, etc.
-- Solo coloreamos el NOMBRE de en medio; el resto queda sin tocar.
local hook_name_convention =
  (P'package' + P'class' + P'file') * P'/' *
  (P(1) - P'/') ^ 1 * P'/' * (P'before' + P'after')

local msgerror_names =
  P'msg_error:nneee'

local msg_generic_names =
  P'msg_' * (P'new' + P'set' + P'error' + P'warning' + P'info' + P'note' +
             P'critical' + P'fatal' + P'expandable_error' +
             P'redirect_name' + P'redirect_class' + P'redirect_module' +
             P'log' + P'term' + P'none' + P'show' +
             P'if_exist_p' + P'if_exist' +
             P'module_name' + P'module_type') *
  P':' * sig_chars ^ 1

-- Paréntesis balanceados (con soporte de anidación, p.ej. e:infix($x,$y)
-- dentro de otro grupo): mismo idioma recursivo P{...V(1)...} que usa
-- combined_pattern más abajo en este archivo.
local balanced_parens
balanced_parens = P{ P'(' * ((P(1) - S'()') + V(1)) ^ 0 * P')' }

local intent_names =
  P':' * S' \t' ^ 0 *
  (P'prefix' + P'postfix' + P'function' + P'nofix' +
   P'silent' + P'time' + P'date' + P'infix') *
  balanced_parens ^ -1

local ltcmd_def_names =
  P'NewDocumentCommand' + P'NewDocumentEnvironment' +
  P'DeclareDocumentCommand' + P'DeclareDocumentEnvironment' +
  P'NewExpandableDocumentCommand' + P'DeclareExpandableDocumentCommand' +
  P'RenewDocumentCommand' + P'RenewDocumentEnvironment' +
  P'ProvideDocumentCommand' + P'ProvideDocumentEnvironment'

local ltcmd_use_names =
  P'BooleanTrue' + P'BooleanFalse' +
  P'IfNoValue' * (P'TF' + P'T' + P'F') +
  P'IfValue'   * (P'TF' + P'T' + P'F') +
  P'IfBoolean' * (P'TF' + P'T' + P'F') +
  P'ProcessedArgument' + P'ReverseBoolean' +
  P'SplitArgument' + P'SplitList' +
  P'ProcessList' + P'TrimSpaces'

local gen_variant_suffix =
  P'cs_generate_variant:' * S'Nc' * P'n' +
  P'prg_generate_conditional_variant:' * S'Nc' * P'nn' +
  P'prg_new_conditional:' * S'N' * P'pnn' +
  P'prg_new_conditional:' * S'N' * P'nn' +
  P'prg_new_protected_conditional:' * S'N' * P'pnn' +
  P'prg_new_protected_conditional:' * S'N' * P'nn' +
  P'prg_new_eq_conditional:' * S'N' * P'Nn'

local legacy_names =
  P'legacy_if_set_true:n'  + P'legacy_if_set_false:n'  +
  P'legacy_if_gset_true:n' + P'legacy_if_gset_false:n' +
  P'legacy_if_set:nn'      + P'legacy_if_gset:nn'      +
  P'legacy_if_p:n'         + P'legacy_if:n' * (P'TF' + P'T' + P'F')

local cs_w     = P'cs:w'
local cs_end   = P'cs_end:'
local dim_unit = P'pt' + P'pc' + P'in' + P'cm' + P'mm' + P'bp' +
                 P'dd' + P'cc' + P'sp' + P'em' + P'ex' + P'px' + P'mu'
local fill_kw  = P'filll' + P'fill' + P'fil'
local skip_kw  = P'minus' + P'plus'
-- fil/fill/plus/minus solo como palabra suelta: no dentro de un nombre
-- (label_fill_right, a_plus_b).
local glue_kw  = -lpeg_base.B(alpha + S'_@') * (fill_kw + skip_kw) * -(alpha + P'_')
local num_part = digit ^ 1 * (P'.' * digit ^ 1) ^ -1

code_rules = {
  {24, P'#' ^ 1 * digit},
  {1,  P'#' ^ 1},
  {42, intent_names},
  {21, P'$$'}, {21, P'$'},
  {21, P'\\' * S'(['}, {21, P'\\' * S')]'},
  {18, P'\x5e\x5e\x5e\x5e' * hex_chars * hex_chars * hex_chars * hex_chars},
  {18, P'\\' ^ -1 * P'\x5e\x5e' * P(1) * P(1) ^ -1},
  {18, P'~'},
  {22, P' ' * (P'<=' + P'>=' + P'!=' + P'<' + P'>' + P'=' + P'/') * P' '},
  {22, P' ' * P'=' * (P'\\' + -P(1))},
  {50, mylhmc_arith_logic_op},
  {29, P','},
  {13, P'\\' * (alpha + S'_@') ^ 1 * P':D'},
  {10, P'\\' * P's__' * (alpha + S'_') ^ 1},
  {10, P'\\' * P's_'  * (alpha + S'_') ^ 1},
  {11, P'\\' * P'q__' * (alpha + S'_') ^ 1},
  {11, P'\\' * P'q_'  * (alpha + S'_') ^ 1},
  {38, P'\\' * mathtag_names},
  {39, P'\\' * keys_names},
  {44, P'\\' * keys_module_arg_names},
  {40, P'\\' * msgerror_names},
  {41, P'\\' * msg_generic_names},
  {46, P'\\' * file_arg_names},
  {47, P'\\' * hook_label_names},
  {48, hook_name_convention},
  {37, P'\\' * pkgstruct_names},
  {49, P'\\' * support_names},
  {25, P'\\' * structure_names},
  {14, P'\\' * ltcmd_def_names},
  {33, P'\\' * ltcmd_use_names},
  {19, P'\\' * P'c__' * name_chars ^ 1},
  {20, P'\\' * P'c_'  * (alpha + S'@') * name_chars ^ 0},
  {2,  var_prefix * P'__' * name_chars_argnum ^ 1},
  {4,  var_prefix * P'_' * (alpha + S'@') * name_chars_argnum ^ 0},
  -- Contadores \c@nombre, con '_' y #N admitidos (\c@__@@_resume_#1_int).
  -- Admite espacios antes de un nombre privado (\c@ @@_x -> \c@ __mod_x).
  {52, P'\\c@' * (P' ' ^ 1 * P'__' + (alpha + P'_')) * (alpha + P'_' + P'#' ^ 1 * digit) ^ 0},
  {15, P'\\' * (alpha ^ 0 * (P'@' + P'!' + P'&' + P'*') * alpha ^ 0) ^ 1},
  {5,  P'\\' * P'__' * name_chars ^ 1 * (P':' * sig_chars ^ 0) ^ -1},
  {34, P'\\' * legacy_names},
  {26, P'\\' * gen_variant_suffix},
  {30, P'\\' * cs_w},
  {31, P'\\' * cs_end},
  {16, P'.' * (alpha + S'_') ^ 1 * P':' * (alpha + S'_') ^ 0},
  {28, P'``'},
  {17, P'`' * P'\\' * (P(1) - alpha)},
  {17, P'`' * P'\\' * alpha * -alpha},
  {17, P'`' * (P(1) - alpha - P'\\')},
  {17, P'`' * alpha * -alpha},
  {17, P'`' * -alpha},
  {28, P'`'},
  {28, P'\''},
  {28, P'\x22'},
  {23, P'\\\\'},
  {23, P'\\' * S',:;!>~|/*+-={}#$_&%\x5e'},
  {35, num_part * dim_unit},
  {36, glue_kw},
  {12, digit ^ 1},
  {6,  P'\\' * alpha * name_chars_no_at ^ 0 * P':' * sig_chars ^ 0},
  {23, P'\\' * alpha * name_chars_no_at ^ 0},
  {51, P'*'},  -- '*' suelto en cualquier contexto (color 'star')
  {8,  S'{}'},
  {3,  S'[]'},
  {9,  P'%' * (P(1) - S'\r\n') ^ 0 * (S'\r\n' + -1)},
}
end

local function mylhmc_build_combined()
  local alts = nil
  for _, rule in ipairs(code_rules) do
    local p = Cp() * rule[2] * Cp() * Cc(rule[1])
    alts = alts and (alts + p) or p
  end
  return P{ alts + P(1) * V(1) }
end

local combined_pattern = mylhmc_build_combined()
local LM_LANGLE = 0x2329
local LM_RANGLE = 0x232A
local bold_cache, lm_cache, italic_cache = {}, {}, {}

-- Controla el fallback de mylhmc_get_italic_fid (usada para comentarios):
-- true (por defecto) = siempre Latin Modern Mono Italic, como hasta
-- ahora; false = busca primero una itálica hermana de la fuente
-- actual (igual que ya hace mylhmc_get_med_bold_fid para negrita),
-- cayendo a Latin Modern solo si no encuentra ninguna. Se fija desde
-- \setmylhmc{lmmono=true|false}.
local use_lmmono_italic = true

-- Palabra clave de prioridad extra para mylhmc_get_med_bold_fid: si no
-- está vacía, cualquier fuente hermana cuyo nombre la contenga gana
-- por encima de 'medium'/'semibold'/'bold' (puntaje 4, el más alto).
-- Si no coincide con ninguna fuente cargada (o nunca se fijó), cae al
-- comportamiento actual sin cambios. Se fija desde \setmylhmc{bold=...}.
local bold_weight_override = ''

local LM_ITALIC_PATH, LM_REGULAR_PATH, LM_BOLD_PATH = nil, nil, nil

local function mylhmc_ensure_lm_paths()
  if not LM_REGULAR_PATH then
    LM_REGULAR_PATH = kpse_find('lmroman10-regular.otf', 'opentype fonts')
    LM_ITALIC_PATH  = kpse_find('lmmono10-italic.otf',   'opentype fonts')
    LM_BOLD_PATH    = kpse_find('lmmonolt10-bold.otf',   'opentype fonts')
    if not (LM_REGULAR_PATH and LM_ITALIC_PATH and LM_BOLD_PATH) then
      warn_once('lm_paths',
        'Latin Modern OpenType fonts not found (lmroman10-regular, '
        .. 'lmmono10-italic, lmmonolt10-bold); using the current font instead.')
    end
  end
end

local function mylhmc_load_font_at_size(filepath, target_size)
  if not filepath then return nil end
  local font_spec = '[' .. filepath .. ']'
  local ok, data, new_id = pcall(f_read, font_spec, target_size)
  if not ok or not data or not new_id or new_id <= 0 then
    warn_once('load:' .. filepath, 'could not load font ' .. filepath)
    return nil
  end
  f_hashes[new_id] = data
  return new_id
end

local function mylhmc_get_med_bold_fid(fid)
  if bold_cache[fid] then return bold_cache[fid] end
  local f = f_getfont(fid)
  if not f or not f.name or not f.size then
    bold_cache[fid] = fid; return fid
  end
  local base_family = s_match(f.name, '^%[?([^%-]+)') or f.name
  local target_size = f.size
  local best_id, best_score, best_path = nil, 0, nil
  local override_lower = bold_weight_override ~= '' and s_lower(bold_weight_override) or nil

  local max_f = f_max()
  for i = 1, max_f do
    local bf = f_getfont(i)
    if bf and bf.name and bf.name ~= f.name and
       s_find(bf.name, base_family, 1, true) then
      local lower_name = s_lower(bf.name)
      local score = 0
      if override_lower and s_find(lower_name, override_lower, 1, true) then score = 4
      elseif s_find(lower_name, 'medium') then score = 3
      elseif s_find(lower_name, 'semibold') or s_find(lower_name, 'semi') or
             s_find(lower_name, 'demi') then score = 2
      elseif s_find(lower_name, 'bold') then score = 1
      end
      if score > best_score then
        best_score = score
        if bf.size == target_size then
          bold_cache[fid] = i; return i
        else
          best_id = i
          best_path = bf.filename or bf.name
        end
      elseif score > 0 and score == best_score and bf.size == target_size then
        bold_cache[fid] = i; return i
      end
    end
  end
  if best_path and best_id then
    local clean_path = s_match(best_path, '^%[?(.-)%]?$') or best_path
    local new_id = mylhmc_load_font_at_size(clean_path, target_size)
    if new_id then bold_cache[fid] = new_id; return new_id end
    bold_cache[fid] = best_id; return best_id
  end
  mylhmc_ensure_lm_paths()
  local fallback_id = mylhmc_load_font_at_size(LM_BOLD_PATH, target_size)
  if fallback_id then bold_cache[fid] = fallback_id; return fallback_id end
  bold_cache[fid] = fid; return fid
end

local function mylhmc_get_italic_fid(fid)
  if italic_cache[fid] then return italic_cache[fid] end
  local f = f_getfont(fid)
  if not f or not f.size then italic_cache[fid] = fid; return fid end
  if not use_lmmono_italic and f.name then
    local base_family = s_match(f.name, '^%[?([^%-]+)') or f.name
    local target_size = f.size
    local max_f = f_max()
    for i = 1, max_f do
      local bf = f_getfont(i)
      if bf and bf.name and bf.name ~= f.name and
         s_find(bf.name, base_family, 1, true) then
        local lower_name = s_lower(bf.name)
        if s_find(lower_name, 'italic') or s_find(lower_name, 'oblique') then
          if bf.size == target_size then
            italic_cache[fid] = i; return i
          end
          local clean_path = s_match(bf.filename or bf.name, '^%[?(.-)%]?$') or (bf.filename or bf.name)
          local new_id = mylhmc_load_font_at_size(clean_path, target_size)
          if new_id then italic_cache[fid] = new_id; return new_id end
        end
      end
    end
  end
  mylhmc_ensure_lm_paths()
  local fallback_id = mylhmc_load_font_at_size(LM_ITALIC_PATH, f.size)
  if fallback_id then italic_cache[fid] = fallback_id; return fallback_id end
  italic_cache[fid] = fid; return fid
end

local function mylhmc_get_lm_fid(fid)
  fid = fid or f_current()
  if lm_cache[fid] then return lm_cache[fid] end
  local cf = f_getfont(fid)
  if not cf or not cf.size then lm_cache[fid] = fid; return fid end

  local max_f = f_max()
  for i = 1, max_f do
    local f = f_getfont(i)
    local fname = f and (f.filename or f.name) or ''
    if f and f.size == cf.size and
       s_find(s_lower(fname), 'lmroman10%-regular') then
      lm_cache[fid] = i; return i
    end
  end
  mylhmc_ensure_lm_paths()
  local new_id = mylhmc_load_font_at_size(LM_REGULAR_PATH, cf.size)
  if new_id then lm_cache[fid] = new_id; return new_id end
  lm_cache[fid] = fid; return fid
end

register_tex_cmd('luafun_set_lmmono', function(value)
  use_lmmono_italic = (value == 'true')
  italic_cache = {}
end, {'string'})

register_tex_cmd('luafun_set_bold_weight', function(value)
  bold_weight_override = value or ''
  bold_cache = {}
end, {'string'})

local color_data, push_templates, module_user_cmds = {}, {}, {}

-- Segmentos de ruta de claves del módulo (\setmylhmc{key-path=print}): segmentos de
-- ruta como `enumext / print` que se colorean como module_name aunque no
-- sean un comando de `provide`. Solo se consultan en rutas de claves.
local key_path_names = {}

-- Primitivas del motor (TeX, eTeX, LuaTeX): se leen de tex.primitives() para
-- que coincidan con el motor en uso. Solo nombres alfabéticos; \end queda
-- fuera porque en LaTeX es la macro que cierra entornos.
local primitive_names = {}
if tex and tex.primitives then
  for k, v in pairs(tex.primitives()) do
    local name = type(k) == 'number' and v or k
    if s_find(name, '^%a+$') then primitive_names[name] = true end
  end
  primitive_names['end'] = nil
end
-- Macros de plain TeX de bajo nivel que LaTeX hereda (ltplain): asignación
-- de registros, grupos, bucles, saltos y penalizaciones, cajas auxiliares.
-- Se tratan como las primitivas. Quedan fuera las que LaTeX usa como
-- comandos de usuario (fuentes, \item, \footnote, símbolos y acentos).
for w in s_gmatch([[
  bgroup egroup endgraf endline loop repeat iterate obeylines obeyspaces
  dospecials frenchspacing nonfrenchspacing newcount newdimen newskip
  newmuskip newbox newtoks newread newwrite newfam newlanguage newinsert
  newhelp newif nointerlineskip offinterlineskip smallskip medskip bigskip
  smallbreak medbreak bigbreak goodbreak nobreak allowbreak break filbreak
  eject supereject removelastskip leavevmode null empty space enskip enspace
  thinspace negthinspace hglue vglue hideskip hidewidth narrower hang
  textindent line leftline rightline centerline llap rlap smash phantom
  hphantom vphantom strut strutbox normalbaselines normalbaselineskip
  normallineskip normallineskiplimit smallskipamount medskipamount
  bigskipamount maxdimen jot raggedbottom active wlog loggingall tracingall
  showhyphens dotfill hrulefill ialign oalign ooalign
]], '%S+') do primitive_names[w] = true end

register_tex_cmd('luafun_register_key_path', function(name)
  name = s_match(name, '^%s*(.-)%s*$') or name
  if name ~= '' then key_path_names[name] = true end
end, {'string'})

register_tex_cmd('luafun_register_module_cmd', function(name)
  name = s_match(name, '^%s*(.-)%s*$') or name
  local clean = s_sub(name, 1, 1) == '\\' and s_sub(name, 2) or name
  -- quitar un '*' final (variante con asterisco, estilo \section*): el
  -- colorizer siempre separa nombre + '*' antes de consultar
  -- module_user_cmds, así que registrar "nuevo*" tal cual no serviría.
  clean = s_match(clean, '^(.-)%*$') or clean
  local bare  = s_match(clean, '^(.-):[NnVvoxefpTFwDcq]+$') or clean
  if bare and bare ~= '' then
    module_user_cmds[bare], module_user_cmds[clean] = true, true
  end
end, {'string'})

register_tex_cmd('luafun_set_color', function(name, spec)
  local r, g, b = s_match(spec, '([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)')
  if r then
    local nr, ng, nb = tonumber(r), tonumber(g), tonumber(b)
    color_data[name] = s_format(
      '%.4f %.4f %.4f rg %.4f %.4f %.4f RG', nr, ng, nb, nr, ng, nb)
  else
    warn_once('color:' .. tostring(name),
      'invalid color specification for "' .. tostring(name)
      .. '": expected three numbers, got "' .. tostring(spec) .. '"')
  end
end, {'string', 'string'})

local function mylhmc_colorstack_push(color_name)
  local tpl = push_templates[color_name]
  if not tpl then
    tpl = d_new('whatsit', 'pdf_colorstack')
    d_setfield(tpl, 'stack', 0)
    d_setfield(tpl, 'command', 1)
    d_setfield(tpl, 'data', color_data[color_name] or '')
    push_templates[color_name] = tpl
  end
  return d_copy(tpl)
end

local pop_template = d_new('whatsit', 'pdf_colorstack')
d_setfield(pop_template, 'stack', 0)
d_setfield(pop_template, 'command', 2)
d_setfield(pop_template, 'data', '')

local function mylhmc_colorstack_pop() return d_copy(pop_template) end

local function mylhmc_append(rh, rt, h, t)
  if not h then return rh, rt end
  if not t then
    t = d_tail(h)
  end
  if rt then d_setlink(rt, h) else rh = h end
  return rh, t
end

-- Bounded glyph cache
local raw_glyph_cache = {}
local CACHE_MAX_LEN = 16

local function mylhmc_str_to_nodes(str, fid, fallback_fn)
  if not str or str == '' then return nil, nil end
  fid = fid or f_current()

  -- Caché anidada [fid][str]: evita construir una clave concatenada en
  -- cada llamada.
  local cacheable = #str <= CACHE_MAX_LEN
  local fcache
  if cacheable then
    fcache = raw_glyph_cache[fid]
    if not fcache then fcache = {}; raw_glyph_cache[fid] = fcache end
    local cached = fcache[str]
    if cached then
      local h = d_copylist(cached)
      return h, d_tail(h)
    end
  end

  fallback_fn = fallback_fn or mylhmc_get_lm_fid
  local head, tail, lm_fid, fallback_fid = nil, nil, nil, nil
  local cur_font = f_getfont(fid)
  local chars = cur_font and cur_font.characters

  for _, cp in u_codes(str) do
    local current_fid = fid
    if cp == LM_LANGLE or cp == LM_RANGLE then
      if not lm_fid then lm_fid = mylhmc_get_lm_fid(fid) end
      current_fid = lm_fid
    elseif chars and not chars[cp] then
      if not fallback_fid then fallback_fid = fallback_fn(fid) end
      current_fid = fallback_fid
    end
    local g = d_new('glyph')
    d_setfield(g, 'font', current_fid)
    d_setfield(g, 'char', cp)
    if head then d_setlink(tail, g) else head = g end
    tail = g
  end

  if head and cacheable then
    fcache[str] = d_copylist(head)
  end
  return head, tail
end

-- Envuelve texto en un Span con ActualText = mismo texto: los glyphs se
-- muestran igual visualmente, pero el PDF garantiza que al copiar/pegar
-- se extraigan exactamente esos caracteres.
local function mylhmc_actual_text_wrap(text, fid)
  local begin_n = d_new('whatsit', 'pdf_literal')
  d_setfield(begin_n, 'mode', 2)
  -- Notación hex nativa del PDF (<...>): BOM UTF-16BE (FEFF) + cada
  -- carácter real como 4 dígitos hex.
  local hex_content = 'FEFF'
  for i = 1, #text do
    hex_content = hex_content .. s_format('%04X', s_byte(text, i))
  end
  d_setfield(begin_n, 'data', '/Span << /ActualText <' .. hex_content .. '> >> BDC')
  local end_n = d_new('whatsit', 'pdf_literal')
  d_setfield(end_n, 'mode', 2)
  d_setfield(end_n, 'data', 'EMC')
  local h, t = mylhmc_str_to_nodes(text, fid)
  local rh, rt = mylhmc_append(nil, nil, begin_n, begin_n)
  rh, rt = mylhmc_append(rh, rt, h, t)
  rh, rt = mylhmc_append(rh, rt, end_n, end_n)
  return rh, rt
end

-- Como mylhmc_str_to_nodes, pero envuelve en ActualText cualquier corrida de
-- 2+ espacios consecutivos (típicas de alineación de columnas en
-- código expl3/TeX bien formateado). Texto normal (sin corridas
-- largas) no paga overhead extra -- pasa directo por mylhmc_str_to_nodes.
local function mylhmc_str_to_nodes_ws_safe(str, fid)
  local rh, rt, i, len = nil, nil, 1, #str
  while i <= len do
    local ws_start, ws_end = s_find(str, '  +', i)
    if not ws_start then
      local h, t = mylhmc_str_to_nodes(s_sub(str, i), fid)
      rh, rt = mylhmc_append(rh, rt, h, t)
      break
    end
    if ws_start > i then
      local h, t = mylhmc_str_to_nodes(s_sub(str, i, ws_start - 1), fid)
      rh, rt = mylhmc_append(rh, rt, h, t)
    end
    local h, t = mylhmc_actual_text_wrap(s_sub(str, ws_start, ws_end), fid)
    rh, rt = mylhmc_append(rh, rt, h, t)
    i = ws_end + 1
  end
  return rh, rt
end

local function mylhmc_colored_str(str, color_name, fid)
  local h, t = mylhmc_str_to_nodes(str, fid)
  if not h then return nil, nil end
  if color_data[color_name] then
    local push, pop = mylhmc_colorstack_push(color_name), mylhmc_colorstack_pop()
    d_setlink(push, h)
    d_setlink(t, pop)
    return push, pop
  end
  return h, t
end

local function mylhmc_colored_str_bold(str, color_name, fid)
  return mylhmc_colored_str(str, color_name, mylhmc_get_med_bold_fid(fid))
end

local function mylhmc_colored_str_italic(str, color_name, fid)
  local italic_fid = mylhmc_get_italic_fid(fid)
  local h, t = mylhmc_str_to_nodes(str, italic_fid, mylhmc_get_italic_fid)
  if not h then return nil, nil end
  if color_data[color_name] then
    local push, pop = mylhmc_colorstack_push(color_name), mylhmc_colorstack_pop()
    d_setlink(push, h)
    d_setlink(t, pop)
    return push, pop
  end
  return h, t
end

local type_colors = {
  [1] ='argument',   [2] ='privatevar',
  [4] ='publicvar',  [5] ='privatefun', [6] ='publicfun',
  [10]='scan',       [11]='quark',      [12]='number',
  [13]='danger',     [15]='legacy_at',
  [17]='backtick',   [18]='escape',     [19]='constant',
  [20]='constant',   [21]='math',       [22]='compare',
  [23]='latex_cmd',  [25]='structure',
  [28]='quote',      [29]='brace',
  [35]='unit',       [36]='compare',
  [37]='pkgstruct',  [38]='mathtag',    [42]='intent',
  [49]='support',    [50]='operator',   [51]='star',
}

local csname_positions = {}
-- Profundidad de llaves y marcos de comandos exteriores con argumentos aún
-- pendientes: una función dentro de un grupo {…} (p.ej. \int_use:N en el 1er
-- argumento de \keys_set:nv) no debe borrar las posiciones c/v del exterior.
local csname_frames = {}
-- Pila para \keys_define:nn/\keys_set:nn anidados (p.ej. dentro de
-- .choices:nn): guarda el contexto exterior al entrar a uno interior
-- y lo restaura al cerrarlo, en vez de perderlo.
local keys_context_stack = {}

-- Notas sobre el estado (cada grupo vive en su tabla, más abajo):
--  * font_*: \setmainfont{fuente}[features] lleva la llave ANTES del
--    corchete (al revés que \RequirePackage[opts]{pkg}); font_bracket_pending
--    se limpia al final de cada línea para no contaminar un [...] posterior.
--  * pkgcls_target_arg = argumento {} que contiene el nombre (1 o 2); los
--    [] opcionales no cuentan porque solo '{' incrementa esos contadores.
--  * \includeonly recibe una lista separada por comas (file_arg_is_list).

-- Estado del analizador agrupado por función en tablas (una sola local por
-- grupo: el chunk principal está en el límite de 200 locales de Lua).
local cs = {  -- csname/variantes/llaves
  arg_counter = 0,
  brace_depth = 0,
  csname_frame_depth = 0,
  in_csname = false,
  -- csname_base_color = nil
  csname_depth = 0,
  variant_braces_remaining = 0,
  variant_depth = 0,
  in_variant_group = false,
  -- name_depth = profundidad de un grupo '{ nombre }' cuyo único contenido
  -- es un nombre de módulo/provide (ver abajo); name_color = su color.
  name_depth = 0,
}
local lt = {  -- \NewDocumentCommand y similares
  ltcmd_brace_count = 0,
  ltcmd_name_pending = false,
  ltcmd_in_args = false,
}
local ml = {  -- MathML (\MathMLintent/\MathMLarg)
  in_mathml_intent = false,
  in_mathml_arg = false,
  mathml_brace_count = 0,
  mathml_after_dollar = false,
}
local kv = {  -- claves (keys_*, .meta, single keyval)
  in_keys_context = false,
  keys_body_opened = false,
  keys_depth = 0,
  keys_in_choices = false,
  keys_meta_pending = false,
  keys_meta_arity = 0,  -- 1 = .meta:n, 2 = .meta:nn
  keys_meta_argnum = 0,  -- argumento actual (1 o 2)
  keys_meta_brace_count = 0,
  in_keys_module_arg = false,
  keys_module_arg_depth = 0,
  keys_module_arg_done = false,
  keys_module_arg_argnum = 0,
  keys_module_arg_total_n = 0,
  in_single_keyval = false,
  single_keyval_depth = 0,
}
local ms = {  -- mensajes (msg_*)
  in_msgerror = false,
  msgerror_argnum = 0,
  msgerror_depth = 0,
  msgerror_is_unknown = false,
  in_msg_simple = false,
  msg_simple_depth = 0,
  msg_simple_done = false,
}
local pk = {  -- paquetes/clases
  provides_pkg_pending = false,
  provides_pkg_brace_count = 0,
  pkgcls_pending = false,
  pkgcls_target_arg = 0,
  pkgcls_argnum = 0,
  pkgcls_brace_depth = 0,
  -- pkgcls_color = nil
  pkgcls_bracket_pending = false,
  pkgcls_bracket_active = false,
  pkgcls_bracket_depth = 0,
}
local fl = {  -- nombres de archivo
  in_file_arg = false,
  file_arg_depth = 0,
  file_arg_done = false,
  file_arg_is_list = false,
}
local hk = {  -- etiquetas de hooks
  in_hook_label = false,
  hook_label_depth = 0,
  hook_label_argnum = 0,
  hook_label_total_n = 0,
  -- hook_label_positions = nil
}
local ft = {  -- fuentes (fontspec)
  font_brace_pending = false,
  font_brace_depth = 0,
  font_bracket_pending = false,
  font_bracket_active = false,
  font_bracket_depth = 0,
}
local mylhmc_colorize_code

local function mylhmc_reset_csname_state()
  if cs.brace_depth > cs.csname_frame_depth then
    local pending = false
    for k in pairs(csname_positions) do
      if k > cs.arg_counter then pending = true; break end
    end
    if pending then
      local saved = {}
      for k, v in pairs(csname_positions) do saved[k] = v end
      csname_frames[#csname_frames + 1] = { saved, cs.arg_counter, cs.csname_frame_depth }
    end
  end
  for k in pairs(csname_positions) do csname_positions[k] = nil end
  cs.arg_counter, cs.in_csname, cs.csname_base_color, cs.csname_depth = 0, false, nil, 0
  cs.csname_frame_depth = cs.brace_depth
end

local function mylhmc_module_aware_color(chunk, base_color)
  local name = s_sub(chunk, 1, 1) == '\\' and s_sub(chunk, 2) or chunk
  local colon = s_find(name, ':', 1, true)
  local bare = colon and s_sub(name, 1, colon - 1) or name
  if module_user_cmds[bare] or module_user_cmds[name] then
    return 'module_name'
  end
  if current_module_name ~= '' and s_find(name, current_module_name, 1, true)
     and not s_find(name, '__', 1, true) then
    return 'module_name'
  end
  return base_color
end

-- Detecta \l__foo, \g__foo, \c__foo, \__foo cuyo segmento de módulo NO
-- coincide con current_module_name: acceso explícito a privados de OTRO
-- módulo (hackeo de internos ajenos) -> color de advertencia 'other_np'.
local env_name_cmds = {
  ['\\begin'] = true, ['\\end'] = true,
  ['\\newenvironment'] = true, ['\\renewenvironment'] = true,
}
local tag_label_cmds = {
  ['\\tag_suspend:n'] = true, ['\\tag_resume:n'] = true,
  ['\\tag_start:n'] = true,   ['\\tag_stop:n'] = true,
}

-- Si justo después de un comando viene {nombre} y nombre es del módulo
-- (provide o contiene el nombre del módulo), emite el grupo con el nombre
-- en module_name y devuelve la nueva posición; si no, no consume nada.
local function mylhmc_module_brace_arg(line, e, fid, rh, rt)
  local ws, name, nxt = s_match(line, '^(%s*){([^{}]-)}()', e)
  if not name then return rh, rt, e end
  -- Espacios opcionales dentro de las llaves ({ nombre } es válido en expl3).
  local lead, inner, trail = s_match(name, '^(%s*)(.-)(%s*)$')
  local core, star = s_match(inner, '^(.-)(%*?)$')
  if core == '' or inner ~= core .. star
     or mylhmc_module_aware_color(core, nil) ~= 'module_name' then
    return rh, rt, e
  end
  local h, tl
  if ws ~= '' then
    h, tl = mylhmc_str_to_nodes(ws, fid); rh, rt = mylhmc_append(rh, rt, h, tl)
  end
  h, tl = mylhmc_colored_str('{', 'brace', fid); rh, rt = mylhmc_append(rh, rt, h, tl)
  if lead ~= '' then
    h, tl = mylhmc_str_to_nodes(lead, fid); rh, rt = mylhmc_append(rh, rt, h, tl)
  end
  h, tl = mylhmc_colored_str(core, 'module_name', fid); rh, rt = mylhmc_append(rh, rt, h, tl)
  if star ~= '' then
    h, tl = mylhmc_colored_str(star, 'star', fid); rh, rt = mylhmc_append(rh, rt, h, tl)
  end
  if trail ~= '' then
    h, tl = mylhmc_str_to_nodes(trail, fid); rh, rt = mylhmc_append(rh, rt, h, tl)
  end
  h, tl = mylhmc_colored_str('}', 'brace', fid); rh, rt = mylhmc_append(rh, rt, h, tl)
  return rh, rt, nxt
end

-- Cuántos de los primeros argumentos {…} de cada comando de sockets son
-- nombres (de socket o de plug) con forma de camino a/b/c.
local socket_cmds = {
  ['\\socket_new:nn'] = 1, ['\\socket_new_plug:nnn'] = 2,
  ['\\socket_assign_plug:nn'] = 2,
  ['\\socket_use:n'] = 1, ['\\socket_use:nn'] = 1, ['\\socket_use:nnn'] = 1,
  ['\\socket_use_expandable:n'] = 1,
  ['\\socket_if_exist:nTF'] = 1, ['\\socket_if_exist:nT'] = 1,
  ['\\socket_if_exist:nF'] = 1,
  ['\\socket_show:n'] = 1, ['\\socket_log:n'] = 1,
  ['\\tag_socket_use:n'] = 1, ['\\tag_socket_use:nn'] = 1,
  ['\\tag_socket_use:nnn'] = 1, ['\\tag_socket_use_expandable:n'] = 1,
}

-- Colorea un camino a/b/c segmento a segmento: module_name solo para los
-- segmentos del módulo (provide, nombre del módulo o __módulo); el resto
-- y las '/' quedan como texto normal.
local function mylhmc_colorize_module_path(text, fid, rh, rt)
  local pos, len = 1, #text
  while pos <= len do
    local s, e2 = s_find(text, '[^/]+', pos)
    if not s then
      local h, t = mylhmc_str_to_nodes(s_sub(text, pos), fid)
      return mylhmc_append(rh, rt, h, t)
    end
    if s > pos then
      local h, t = mylhmc_str_to_nodes(s_sub(text, pos, s - 1), fid)
      rh, rt = mylhmc_append(rh, rt, h, t)
    end
    local seg = s_sub(text, s, e2)
    local lead, word, trail = s_match(seg, '^(%s*)(.-)(%s*)$')
    local core = s_match(word, '^__(.+)$') or word
    local h, t
    if core ~= '' and mylhmc_module_aware_color(core, nil) == 'module_name' then
      if lead ~= '' then h, t = mylhmc_str_to_nodes(lead, fid); rh, rt = mylhmc_append(rh, rt, h, t) end
      h, t = mylhmc_colored_str(word, 'module_name', fid); rh, rt = mylhmc_append(rh, rt, h, t)
      if trail ~= '' then h, t = mylhmc_str_to_nodes(trail, fid); rh, rt = mylhmc_append(rh, rt, h, t) end
    else
      h, t = mylhmc_str_to_nodes(seg, fid); rh, rt = mylhmc_append(rh, rt, h, t)
    end
    pos = e2 + 1
  end
  return rh, rt
end

-- Consume los primeros n grupos {…} simples tras un comando de sockets y los
-- emite con el camino coloreado por segmentos. Se detiene en el primer
-- argumento que no sea un grupo simple (sin llaves anidadas).
local function mylhmc_socket_args(line, e, fid, rh, rt, n)
  for _ = 1, n do
    local ws, body, nxt = s_match(line, '^(%s*){([^{}]*)}()', e)
    if not body then break end
    local h, t
    if ws ~= '' then h, t = mylhmc_str_to_nodes(ws, fid); rh, rt = mylhmc_append(rh, rt, h, t) end
    h, t = mylhmc_colored_str('{', 'brace', fid); rh, rt = mylhmc_append(rh, rt, h, t)
    rh, rt = mylhmc_colorize_module_path(body, fid, rh, rt)
    h, t = mylhmc_colored_str('}', 'brace', fid); rh, rt = mylhmc_append(rh, rt, h, t)
    e = nxt
  end
  return rh, rt, e
end

local function mylhmc_private_owner_color(chunk, fallback_color)
  local name = s_sub(chunk, 1, 1) == '\\' and s_sub(chunk, 2) or chunk
  local c3 = s_sub(name, 1, 3)
  local rest
  if c3 == 'l__' or c3 == 'g__' or c3 == 'c__' then
    rest = s_sub(name, 4)
  elseif s_sub(name, 1, 2) == '__' then
    rest = s_sub(name, 3)
  else
    return fallback_color
  end
  if current_module_name == '' then return fallback_color end
  if module_user_cmds[rest] then return fallback_color end
  if s_find(rest, current_module_name, 1, true) then return fallback_color end
  return 'other_np'
end

-- Colorea un nombre de variable (chunk de tipo 2/4) que puede contener
-- #N embebido -- documentación de una familia de csnames generados
-- dinámicamente, p.ej. \l_@@_foo_#1_bar. base_color ya viene decidido
-- sobre el chunk COMPLETO (module_aware_color/private_owner_color),
-- para no perder la detección de módulo propio/ajeno al partir el
-- texto; cada #N se colorea aparte como 'argument'+'argnum'.
local function mylhmc_colorize_name_with_argnum(chunk, fid, base_color)
  local rh, rt = nil, nil
  local pos, len = 1, #chunk
  while pos <= len do
    local hstart, hend, hashes, num = s_find(chunk, '(#+)(%d)', pos)
    if not hstart then
      local h, t = mylhmc_colored_str(s_sub(chunk, pos), base_color, fid)
      rh, rt = mylhmc_append(rh, rt, h, t)
      break
    end
    if hstart > pos then
      local h, t = mylhmc_colored_str(s_sub(chunk, pos, hstart - 1), base_color, fid)
      rh, rt = mylhmc_append(rh, rt, h, t)
    end
    local h, t = mylhmc_colored_str(hashes, 'argument', fid)
    rh, rt = mylhmc_append(rh, rt, h, t)
    h, t = mylhmc_colored_str(num, 'argnum', fid)
    rh, rt = mylhmc_append(rh, rt, h, t)
    pos = hend + 1
  end
  return rh, rt
end

-- Colorea el "modo csname" de \myhlc (bare_varname_full ya confirmó
-- que text es un nombre completo l_.../g_.../l__.../g__..., sin
-- backslash). El '\' antepuesto es solo para reusar la detección de
-- módulo propio/ajeno (esas funciones esperan ese formato); nunca se
-- muestra ni se pasa a colorize_name_with_argnum.
local function mylhmc_render_bare_varname(text, fid)
  local is_private = s_sub(text, 2, 3) == '__'
  local prefixed = '\\' .. text
  local base_color
  if is_private then
    base_color = mylhmc_private_owner_color(prefixed, 'privatevar')
  else
    base_color = mylhmc_module_aware_color(prefixed, 'publicvar')
  end
  return mylhmc_colorize_name_with_argnum(text, fid, base_color)
end

-- Nombres de contador: los primeros n grupos {…} tras \newcounter, \setcounter,
-- \value, \usecounter, \counterwithin… (n = valor). Se colorean como los \c@nombre: un
-- nombre privado (__mod_…) según su módulo, uno público como latex_cmd o
-- module_name si es del módulo; cada #N aparte. Una sola local (el chunk
-- principal está al límite de 200 locales): la función cuelga de la tabla.
local counter_cmds = {
  ['\\newcounter'] = 1, ['\\setcounter'] = 1, ['\\addtocounter'] = 1,
  ['\\stepcounter'] = 1, ['\\refstepcounter'] = 1, ['\\value'] = 1,
  ['\\arabic'] = 1, ['\\roman'] = 1, ['\\Roman'] = 1, ['\\alph'] = 1,
  ['\\Alph'] = 1, ['\\fnsymbol'] = 1, ['\\usecounter'] = 1,
  ['\\counterwithin'] = 2, ['\\counterwithout'] = 2,
}

function counter_cmds.apply(line, e, fid, rh, rt, n)
  for i = 1, n do
    local ws, star, body, nxt = s_match(line, '^(%s*)(%*?)%s*{([^{}]*)}()', e)
    if not body or (i > 1 and star ~= '') then break end
    local lead, name, trail = s_match(body, '^(%s*)(.-)(%s*)$')
    -- Solo nombres simples; con \comandos u otros símbolos no se toca nada.
    if name == '' or s_find(name, '[^%w_@#%s%*]') then break end
    local h, t
    if ws ~= '' then h, t = mylhmc_str_to_nodes(ws, fid); rh, rt = mylhmc_append(rh, rt, h, t) end
    if star ~= '' then h, t = mylhmc_colored_str(star, 'star', fid); rh, rt = mylhmc_append(rh, rt, h, t) end
    h, t = mylhmc_colored_str('{', 'brace', fid); rh, rt = mylhmc_append(rh, rt, h, t)
    if lead ~= '' then h, t = mylhmc_str_to_nodes(lead, fid); rh, rt = mylhmc_append(rh, rt, h, t) end
    local base
    if s_sub(name, 1, 2) == '__' then base = mylhmc_private_owner_color(name, 'privatevar')
    else base = mylhmc_module_aware_color(name, 'latex_cmd') end
    h, t = mylhmc_colorize_name_with_argnum(name, fid, base); rh, rt = mylhmc_append(rh, rt, h, t)
    if trail ~= '' then h, t = mylhmc_str_to_nodes(trail, fid); rh, rt = mylhmc_append(rh, rt, h, t) end
    h, t = mylhmc_colored_str('}', 'brace', fid); rh, rt = mylhmc_append(rh, rt, h, t)
    e = nxt
  end
  return rh, rt, e
end

local function mylhmc_emit_with_signature(chunk, base_color, fid)
  local colon = s_find(chunk, ':', 2, true)
  if not colon then
    mylhmc_reset_csname_state()
    return mylhmc_colored_str(chunk, base_color, fid)
  end
  local name, sig = s_sub(chunk, 1, colon - 1), s_sub(chunk, colon + 1)
  mylhmc_reset_csname_state()
  -- Índice por GRUPO {…}: N, V, p, w, D son un solo token (no abren llaves),
  -- así que no cuentan; 'c'/'v' marcan el grupo que contiene un csname.
  local pos = 0
  for ch in s_gmatch(sig, '.') do
    if s_match(ch, '[nvoxefTFcq]') then
      pos = pos + 1
      if ch == 'c' or ch == 'v' then csname_positions[pos] = true end
    end
  end
  local rh, rt = nil, nil
  local h, t = mylhmc_colored_str(name, base_color, fid); rh, rt = mylhmc_append(rh, rt, h, t)
  h, t = mylhmc_colored_str(':', 'signature', fid); rh, rt = mylhmc_append(rh, rt, h, t)
  if sig ~= '' then
    h, t = mylhmc_colored_str(sig, 'sigargs', fid); rh, rt = mylhmc_append(rh, rt, h, t)
  end
  return rh, rt
end

local function mylhmc_colorize_ltcmd_args(text, fid, rh, rt)
  local i, depth, text_len = 1, 0, #text
  while i <= text_len do
    local b = s_byte(text, i)
    if b == 123 then
      depth = depth + 1
      local h, t = mylhmc_colored_str('{', 'brace', fid); rh, rt = mylhmc_append(rh, rt, h, t)
      i = i + 1
    elseif b == 125 then
      depth = depth - 1
      local h, t = mylhmc_colored_str('}', 'brace', fid); rh, rt = mylhmc_append(rh, rt, h, t)
      i = i + 1
    elseif depth > 0 then
      local j, d = i, depth
      while j <= text_len do
        local bb = s_byte(text, j)
        if bb == 123 then d = d + 1
        elseif bb == 125 then d = d - 1; if d < depth then break end end
        j = j + 1
      end
      local content = s_sub(text, i, j - 1)
      if content ~= '' then
        local ch, ct = mylhmc_colorize_code(content, fid); rh, rt = mylhmc_append(rh, rt, ch, ct)
      end
      i = j
    elseif b == 32 then
      local h, t = mylhmc_str_to_nodes(' ', fid); rh, rt = mylhmc_append(rh, rt, h, t)
      i = i + 1
    else
      local h, t = mylhmc_colored_str(s_sub(text, i, i), 'ltcmd_arg', fid)
      rh, rt = mylhmc_append(rh, rt, h, t); i = i + 1
    end
  end
  return rh, rt
end

local function mylhmc_csname_color_from_prefix(text)
  text = s_gsub(text, '%s+', '')   -- en expl3 los espacios no cuentan
  local p2, p3 = s_sub(text, 1, 2), s_sub(text, 1, 3)
  local base, rest
  -- Contador c@<nombre>: si el nombre es privado (__módulo_...), el color
  -- lo decide el módulo, no el prefijo c@ (LaTeX2e).
  if p2 == 'c@' then
    local cnt = s_match(text, '^c@%s*(.*)$')
    if s_sub(cnt, 1, 2) ~= '__' then return 'latex_cmd' end
    base, rest = 'privatevar', s_sub(cnt, 3)
  elseif p3 == 'l__' or p3 == 'g__' then base, rest = 'privatevar', s_sub(text, 4)
  elseif p3 == 'c__' then base, rest = 'constant', s_sub(text, 4)
  elseif p2 == '__' then base, rest = 'privatefun', s_sub(text, 3)
  elseif p2 == 'l_' or p2 == 'g_' then return 'publicvar'
  elseif p2 == 'c_' then return 'constant'
  else return 'latex_cmd'
  end
  if current_module_name == '' then return base end
  if module_user_cmds[rest] then return base end
  if s_find(rest, current_module_name, 1, true) then return base end
  return 'other_np'
end

local function mylhmc_emit_csname_text(text, base_color, fid, rh, rt)
  local has_special, len = false, #text
  for i = 1, len do
    local b = s_byte(text, i)
    if b == 64 or b == 33 or b == 38 or b == 94 or b == 42 or b == 58 then
      has_special = true; break
    end
  end
  if not has_special then
    local h, t = mylhmc_colored_str(text, base_color, fid); return mylhmc_append(rh, rt, h, t)
  end
  local cur = 1
  for i = 1, len do
    local b = s_byte(text, i)
    if b == 64 or b == 33 or b == 38 or b == 94 or b == 42 then
      if i > cur then
        local piece = s_sub(text, cur, i-1)
        -- La 'c' de c@ es siempre LaTeX2e, aunque el nombre sea del módulo.
        local pc = (b == 64 and base_color ~= 'latex_cmd' and s_match(piece, '^%s*c$'))
                   and 'latex_cmd' or base_color
        local h, t = mylhmc_colored_str(piece, pc, fid)
        rh, rt = mylhmc_append(rh, rt, h, t)
      end
      local color_name = (b == 64 and 'arroba') or (b == 42 and 'star') or 'escape'
      local h, t = mylhmc_colored_str(s_sub(text, i, i), color_name, fid)
      rh, rt = mylhmc_append(rh, rt, h, t); cur = i + 1
    elseif b == 58 then
      if i > cur then
        local h, t = mylhmc_colored_str(s_sub(text, cur, i-1), base_color, fid)
        rh, rt = mylhmc_append(rh, rt, h, t)
      end
      local h, t = mylhmc_colored_str(':', 'signature', fid)
      rh, rt = mylhmc_append(rh, rt, h, t); local rest = s_sub(text, i+1)
      if rest ~= '' then
        h, t = mylhmc_colored_str(rest, 'sigargs', fid); rh, rt = mylhmc_append(rh, rt, h, t)
      end
      cur = len + 1; break
    end
  end
  if cur <= len then
    local h, t = mylhmc_colored_str(s_sub(text, cur), base_color, fid)
    rh, rt = mylhmc_append(rh, rt, h, t)
  end
  return rh, rt
end

local function mylhmc_colorize_mathml_intent(text, fid, rh, rt)
  local i, len = 1, #text
  while i <= len do
    local c, b = s_sub(text, i, i), s_byte(text, i)
    if c == ':' then
      local j = i + 1
      -- saltar espacios opcionales entre ':' y la palabra de intent
      while j <= len and s_byte(text, j) == 32 do j = j + 1 end
      local word_start = j
      while j <= len do
        local cb = s_byte(text, j)
        if (cb >= 65 and cb <= 90) or (cb >= 97 and cb <= 122) or
           (cb >= 48 and cb <= 57) or cb == 95 or cb == 45 then j = j + 1
        else break end
      end
      local h, t = mylhmc_colored_str(':', 'signature', fid)
      rh, rt = mylhmc_append(rh, rt, h, t)
      if word_start > i + 1 then
        h, t = mylhmc_str_to_nodes(s_sub(text, i+1, word_start-1), fid)
        rh, rt = mylhmc_append(rh, rt, h, t)
      end
      if j > word_start then
        h, t = mylhmc_colored_str(s_sub(text, word_start, j-1), 'ltcmd_arg', fid)
        rh, rt = mylhmc_append(rh, rt, h, t)
      end
      i = j
    elseif c == '$' then
      local h, t = mylhmc_colored_str('$', 'math', fid); rh, rt = mylhmc_append(rh, rt, h, t)
      local j = i + 1
      while j <= len do
        local cb = s_byte(text, j)
        if (cb >= 65 and cb <= 90) or (cb >= 97 and cb <= 122) or
           (cb >= 48 and cb <= 57) or cb == 95 then j = j + 1
        else break end
      end
      if j > i + 1 then
        h, t = mylhmc_colored_str(s_sub(text, i+1, j-1), 'mathml_var', fid)
        rh, rt = mylhmc_append(rh, rt, h, t)
      end
      i = j
    elseif c == '(' or c == ')' or c == ',' then
      local h, t = mylhmc_colored_str(c, 'brace', fid); rh, rt = mylhmc_append(rh, rt, h, t)
      i = i + 1
    elseif c == ' ' then
      local h, t = mylhmc_str_to_nodes(c, fid); rh, rt = mylhmc_append(rh, rt, h, t); i = i + 1
    else
      local j = i + 1
      while j <= len do
        local nc = s_sub(text, j, j)
        if nc == ':' or nc == '$' or nc == '(' or nc == ')' or
           nc == ',' or nc == ' ' then break end
        j = j + 1
      end
      local chunk = s_sub(text, i, j-1)
      -- También aislamos mathml_brace_count/mathml_after_dollar, no
      -- solo in_mathml_intent/in_mathml_arg: un \MathMLarg anidado aquí
      -- (p.ej. :infix(\MathMLarg{a}, \MathMLarg{b})) vuelve a pasar por
      -- el dispatcher principal y reinicia ese contador compartido;
      -- sin guardarlo/restaurarlo, la llave de cierre del \MathMLintent
      -- exterior queda sin efecto y el modo mathml no se apaga nunca.
      local saved_intent, saved_arg, saved_bc, saved_dollar =
        ml.in_mathml_intent, ml.in_mathml_arg, ml.mathml_brace_count, ml.mathml_after_dollar
      ml.in_mathml_intent, ml.in_mathml_arg, ml.mathml_brace_count, ml.mathml_after_dollar =
        false, false, 0, false
      local ch, ct = mylhmc_colorize_code(chunk, fid)
      ml.in_mathml_intent, ml.in_mathml_arg, ml.mathml_brace_count, ml.mathml_after_dollar =
        saved_intent, saved_arg, saved_bc, saved_dollar
      rh, rt = mylhmc_append(rh, rt, ch, ct); i = j
    end
  end
  return rh, rt
end

-- Nombre de archivo: divide en '.' (color 'signature', ya existente)
-- y el resto del texto (color 'filename', independiente y editable).
local function mylhmc_colorize_filename(text, fid, rh, rt)
  local i, len, start = 1, #text, 1
  while i <= len do
    if s_sub(text, i, i) == '.' then
      if i > start then
        local h, t = mylhmc_colored_str(s_sub(text, start, i - 1), 'filename', fid)
        rh, rt = mylhmc_append(rh, rt, h, t)
      end
      local h, t = mylhmc_colored_str('.', 'signature', fid)
      rh, rt = mylhmc_append(rh, rt, h, t)
      start = i + 1
    end
    i = i + 1
  end
  if start <= len then
    local h, t = mylhmc_colored_str(s_sub(text, start), 'filename', fid)
    rh, rt = mylhmc_append(rh, rt, h, t)
  end
  return rh, rt
end

-- Lista de archivos separados por comas (\includeonly{cap1,cap2,cap3}):
-- mismo tratamiento de '.' que mylhmc_colorize_filename, y además separa por
-- ',' (color 'brace', igual que el resto de comas separadoras del archivo).
local function mylhmc_colorize_filename_list(text, fid, rh, rt)
  local i, len, start = 1, #text, 1
  while i <= len do
    local c = s_sub(text, i, i)
    if c == '.' or c == ',' then
      if i > start then
        local h, t = mylhmc_colored_str(s_sub(text, start, i - 1), 'filename', fid)
        rh, rt = mylhmc_append(rh, rt, h, t)
      end
      local h, t = mylhmc_colored_str(c, c == '.' and 'signature' or 'brace', fid)
      rh, rt = mylhmc_append(rh, rt, h, t)
      start = i + 1
    end
    i = i + 1
  end
  if start <= len then
    local h, t = mylhmc_colored_str(s_sub(text, start), 'filename', fid)
    rh, rt = mylhmc_append(rh, rt, h, t)
  end
  return rh, rt
end

local function mylhmc_colorize_keys_path(text, fid, rh, rt)
  local i, len = 1, #text
  while i <= len do
    local b = s_byte(text, i)
    if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95 or b == 45 then
      local j = i + 1
      while j <= len do
        local bb = s_byte(text, j)
        if (bb >= 65 and bb <= 90) or (bb >= 97 and bb <= 122) or
           bb == 95 or bb == 45 then j = j + 1 else break end
      end
      local word = s_sub(text, i, j - 1)
      if module_user_cmds[word] or key_path_names[word] or
         (current_module_name ~= '' and word == current_module_name) then
        local h, t = mylhmc_colored_str(word, 'module_name', fid)
        rh, rt = mylhmc_append(rh, rt, h, t)
      else
        local h, t = mylhmc_str_to_nodes(word, fid)
        rh, rt = mylhmc_append(rh, rt, h, t)
      end
      i = j
    else
      local h, t = mylhmc_str_to_nodes(s_sub(text, i, i), fid)
      rh, rt = mylhmc_append(rh, rt, h, t)
      i = i + 1
    end
  end
  return rh, rt
end

local function mylhmc_colorize_trimmed_keyname(text, fid, rh, rt, color)
  local lead = s_match(text, '^(%s*)')
  local core = s_sub(text, #lead + 1)
  local trimmed = s_match(core, '^(.-)%s*$')
  local trail = s_sub(core, #trimmed + 1)
  if lead ~= '' then
    local h2, t2 = mylhmc_str_to_nodes_ws_safe(lead, fid)
    rh, rt = mylhmc_append(rh, rt, h2, t2)
  end
  if trimmed ~= '' then
    local h, t = mylhmc_colored_str(trimmed, color or 'keyname', fid)
    rh, rt = mylhmc_append(rh, rt, h, t)
  end
  if trail ~= '' then
    local h, t = mylhmc_str_to_nodes_ws_safe(trail, fid)
    rh, rt = mylhmc_append(rh, rt, h, t)
  end
  return rh, rt
end

local function mylhmc_ltcmd_name_color(text)
  text = s_match(text, '^%s*(.-)%s*$') or text
  local name = s_sub(text, 1, 1) == '\\' and s_sub(text, 2) or text
  local colon = s_find(name, ':', 1, true)
  local bare = colon and s_sub(name, 1, colon - 1) or name
  if module_user_cmds[bare] or module_user_cmds[text] then return 'module_name' end
  if current_module_name ~= '' and s_find(bare, current_module_name, 1, true) then
    return 'module_name'
  end
  return 'latex_cmd'
end

-- Regla genérica anti-falsos-positivos: un grupo cuyo ÚNICO contenido es un
-- nombre completo (no subcadena) se colorea si ese nombre es
--   (a) un nombre de `provide` o el nombre del módulo actual  -> module_name
--   (b) un nombre con `__<módulo actual>` como segmento (`__enumext_x`,
--       `g_@@_default_ #1 _ #3`) -> color de privado propio.
-- Solo se consulta con '{' y la aplicación está al final de la cadena de
-- estados de mylhmc_colorize_plain_text, así que cualquier contexto
-- especial tiene prioridad.
local function mylhmc_name_group_color(line, b)
  if current_module_name == '' and next(module_user_cmds) == nil then return nil end
  local name = s_match(line, '^{%s*([%w_%-]+)%*?%s*}', b)
  if name and (module_user_cmds[name] or name == current_module_name) then
    return 'module_name'
  end
  if current_module_name == '' then return nil end
  -- (b) nombre de variable/función del módulo, con #N y espacios (familias
  -- de csnames): `g_@@_default_ #1 _ #3`, `__enumext_x`, `l__enumext_a`.
  -- Debe contener `__<módulo>` como segmento completo, solo precedido por
  -- nada o por l/g/c (como en l__mod_…) y seguido de '_' o espacio/fin.
  local body = s_match(line, '^{([%w_#%-%s]*)}', b)
  if not body then return nil end
  body = s_gsub(body, '%s+', '')   -- en expl3 los espacios no cuentan
  local m = '__' .. current_module_name
  local p = s_find(body, m, 1, true)
  if not p then return nil end
  local pre = s_sub(body, 1, p - 1)
  if pre ~= '' and pre ~= 'l' and pre ~= 'g' and pre ~= 'c' then return nil end
  local nx = s_byte(body, p + #m)
  if nx == nil or nx == 95 or nx == 32 or nx == 35 then return 'privatevar' end
  return nil
end

local function mylhmc_colorize_plain_text(text, fid, rh, rt)
  local h, tl
  if cs.in_variant_group then h, tl = mylhmc_colored_str(text, 'sigargs', fid)
  elseif cs.in_csname then
    cs.csname_base_color = cs.csname_base_color or mylhmc_csname_color_from_prefix(text)
    rh, rt = mylhmc_emit_csname_text(text, cs.csname_base_color, fid, rh, rt)
    h, tl = nil, nil
  elseif ml.in_mathml_intent then
    if ml.mathml_after_dollar then
      ml.mathml_after_dollar = false
      local ident = s_match(text, '^%s*([%a%d_]+)')
      if ident then
        h, tl = mylhmc_colored_str(ident, 'mathml_var', fid)
        rh, rt = mylhmc_append(rh, rt, h, tl)
        local fnd = s_find(text, ident, 1, true) or 1
        local rest = s_sub(text, fnd + #ident)
        if rest ~= '' then rh, rt = mylhmc_colorize_mathml_intent(rest, fid, rh, rt) end
        h, tl = nil, nil
      else
        rh, rt = mylhmc_colorize_mathml_intent(text, fid, rh, rt); h, tl = nil, nil
      end
    else
      rh, rt = mylhmc_colorize_mathml_intent(text, fid, rh, rt); h, tl = nil, nil
    end
  elseif ml.in_mathml_arg then h, tl = mylhmc_colored_str(text, 'mathml_var', fid)
  elseif kv.keys_meta_pending and kv.keys_meta_brace_count == 1
         and kv.keys_meta_argnum == 1 and kv.keys_meta_arity == 2 then
    -- .meta:nn primer argumento: ruta módulo/clave (spintent/spnum)
    rh, rt = mylhmc_colorize_keys_path(text, fid, rh, rt); h, tl = nil, nil
  elseif kv.keys_meta_pending and kv.keys_meta_brace_count == 1 then
    -- .meta:n único argumento, o .meta:nn segundo argumento: lista de claves
    rh, rt = mylhmc_colorize_trimmed_keyname(text, fid, rh, rt); h, tl = nil, nil
  elseif kv.in_keys_context and kv.keys_body_opened and kv.keys_depth == 1 then
    rh, rt = mylhmc_colorize_trimmed_keyname(text, fid, rh, rt); h, tl = nil, nil
  elseif kv.in_keys_context and kv.keys_body_opened and kv.keys_in_choices and kv.keys_depth == 2 then
    rh, rt = mylhmc_colorize_trimmed_keyname(text, fid, rh, rt); h, tl = nil, nil
  elseif ms.in_msgerror and ms.msgerror_depth == 1 and ms.msgerror_argnum == 1 then
    h, tl = mylhmc_colored_str(text, 'module_name', fid)
  elseif ms.in_msgerror and ms.msgerror_depth == 1 and ms.msgerror_argnum == 2 then
    local trimmed = s_match(text, '^%s*(.-)%s*$')
    ms.msgerror_is_unknown = (trimmed == 'unknown-choice')
    h, tl = mylhmc_str_to_nodes(text, fid)
  elseif ms.in_msgerror and ms.msgerror_depth == 1 and ms.msgerror_is_unknown
         and (ms.msgerror_argnum == 3 or ms.msgerror_argnum == 4) then
    rh, rt = mylhmc_colorize_trimmed_keyname(text, fid, rh, rt); h, tl = nil, nil
  elseif lt.ltcmd_in_args then
    if lt.ltcmd_brace_count > 1 then h, tl = mylhmc_str_to_nodes(text, fid)
    else rh, rt = mylhmc_colorize_ltcmd_args(text, fid, rh, rt); h, tl = nil, nil end
  elseif lt.ltcmd_name_pending and lt.ltcmd_brace_count == 1 then
    rh, rt = mylhmc_emit_csname_text(text, mylhmc_ltcmd_name_color(text), fid, rh, rt)
    h, tl = nil, nil
  elseif kv.in_keys_context and not kv.keys_body_opened then
    rh, rt = mylhmc_colorize_keys_path(text, fid, rh, rt); h, tl = nil, nil
  elseif ms.in_msg_simple and not ms.msg_simple_done and ms.msg_simple_depth == 1 then
    rh, rt = mylhmc_colorize_keys_path(text, fid, rh, rt); h, tl = nil, nil
  elseif kv.in_keys_module_arg and not kv.keys_module_arg_done
         and kv.keys_module_arg_depth == 1 then
    if kv.keys_module_arg_argnum == 1 then
      rh, rt = mylhmc_colorize_keys_path(text, fid, rh, rt); h, tl = nil, nil
    else
      rh, rt = mylhmc_colorize_trimmed_keyname(text, fid, rh, rt); h, tl = nil, nil
    end
  elseif pk.provides_pkg_pending and pk.provides_pkg_brace_count == 1 then
    h, tl = mylhmc_colored_str_bold(text, 'module_name', fid)
  elseif pk.pkgcls_pending and pk.pkgcls_brace_depth == 1
         and pk.pkgcls_argnum == pk.pkgcls_target_arg then
    h, tl = mylhmc_colored_str_bold(text, pk.pkgcls_color, fid)
  elseif pk.pkgcls_pending and pk.pkgcls_brace_depth == 1
         and pk.pkgcls_target_arg == 2 and pk.pkgcls_argnum == 1 then
    -- \PassOptionsToPackage/\PassOptionsToClass: primer argumento =
    -- lista de opciones (key=value, ...), mismo tratamiento que keyname.
    rh, rt = mylhmc_colorize_trimmed_keyname(text, fid, rh, rt); h, tl = nil, nil
  elseif pk.pkgcls_bracket_active and pk.pkgcls_bracket_depth == 1 then
    -- \RequirePackage/\LoadClass [opciones]: mismo tratamiento keyname.
    rh, rt = mylhmc_colorize_trimmed_keyname(text, fid, rh, rt); h, tl = nil, nil
  elseif fl.in_file_arg and not fl.file_arg_done and fl.file_arg_depth == 1 then
    if fl.file_arg_is_list then
      rh, rt = mylhmc_colorize_filename_list(text, fid, rh, rt)
    else
      rh, rt = mylhmc_colorize_filename(text, fid, rh, rt)
    end
    h, tl = nil, nil
  elseif hk.in_hook_label and hk.hook_label_depth == 1
         and hk.hook_label_positions[hk.hook_label_argnum] then
    h, tl = mylhmc_colored_str(text, 'module_name', fid)
  elseif cs.name_depth > 0 and cs.name_depth == cs.brace_depth then
    -- Grupo '{ nombre }' (ver mylhmc_name_group_color): solo se llega aquí
    -- si ningún estado especial (keys, msg, hook, ...) reclamó el texto.
    if cs.name_color == 'module_name' then
      rh, rt = mylhmc_colorize_trimmed_keyname(text, fid, rh, rt, cs.name_color); h, tl = nil, nil
    else
      -- nombre con espacios internos (expl3): color continuo, como en csnames
      h, tl = mylhmc_colored_str(text, cs.name_color, fid)
    end
  elseif kv.in_single_keyval and kv.single_keyval_depth == 1 then
    rh, rt = mylhmc_colorize_trimmed_keyname(text, fid, rh, rt); h, tl = nil, nil
  elseif ft.font_bracket_active and ft.font_bracket_depth == 1 then
    rh, rt = mylhmc_colorize_trimmed_keyname(text, fid, rh, rt); h, tl = nil, nil
  else h, tl = mylhmc_str_to_nodes_ws_safe(text, fid) end
  return mylhmc_append(rh, rt, h, tl)
end

mylhmc_colorize_code = function(line, fid)
  local rh, rt, pos, line_len = nil, nil, 1, #line
  while pos <= line_len do
    local b, e, t = lpeg_match(combined_pattern, line, pos)
    if not b then
      local remainder = s_sub(line, pos)
      rh, rt = mylhmc_colorize_plain_text(remainder, fid, rh, rt)
      break
    end
    if b > pos then
      local prefix = s_sub(line, pos, b - 1)
      rh, rt = mylhmc_colorize_plain_text(prefix, fid, rh, rt)
    end
    local chunk = s_sub(line, b, e - 1)
    local h, tl
    if t == 8 then
      if chunk == '{' then
        -- Solo los grupos de primer nivel del comando vigente cuentan como
        -- sus argumentos; los anidados no.
        local top = (cs.brace_depth == cs.csname_frame_depth)
        if top then cs.arg_counter = cs.arg_counter + 1 end
        local is_csname = top and csname_positions[cs.arg_counter]
        cs.brace_depth = cs.brace_depth + 1
        local ngc = mylhmc_name_group_color(line, b)
        if ngc then cs.name_depth, cs.name_color = cs.brace_depth, ngc end
        if is_csname then
          cs.in_csname, cs.csname_base_color, cs.csname_depth = true, nil, 0
          cs.in_variant_group, cs.variant_braces_remaining, cs.variant_depth = false, 0, 0
        elseif cs.in_csname then cs.csname_depth = cs.csname_depth + 1 end
        if cs.in_variant_group then cs.variant_depth = cs.variant_depth + 1
        elseif cs.variant_braces_remaining > 0 then cs.in_variant_group = true end
        if lt.ltcmd_name_pending or lt.ltcmd_in_args then
          lt.ltcmd_brace_count = lt.ltcmd_brace_count + 1
        end
        if ml.in_mathml_intent or ml.in_mathml_arg then
          ml.mathml_brace_count = ml.mathml_brace_count + 1
        end
        if kv.in_keys_context then
          kv.keys_depth = kv.keys_depth + 1
        end
        if kv.keys_meta_pending then
          kv.keys_meta_brace_count = kv.keys_meta_brace_count + 1
          if kv.keys_meta_brace_count == 1 then
            kv.keys_meta_argnum = kv.keys_meta_argnum + 1
          end
        end
        if ms.in_msgerror then
          if ms.msgerror_depth == 0 then
            ms.msgerror_argnum = ms.msgerror_argnum + 1
          end
          ms.msgerror_depth = ms.msgerror_depth + 1
        end
        if ms.in_msg_simple and not ms.msg_simple_done then
          ms.msg_simple_depth = ms.msg_simple_depth + 1
        end
        if kv.in_keys_module_arg and not kv.keys_module_arg_done then
          kv.keys_module_arg_depth = kv.keys_module_arg_depth + 1
          if kv.keys_module_arg_depth == 1 then
            kv.keys_module_arg_argnum = kv.keys_module_arg_argnum + 1
          end
        end
        if pk.provides_pkg_pending then
          pk.provides_pkg_brace_count = pk.provides_pkg_brace_count + 1
        end
        if pk.pkgcls_pending then
          pk.pkgcls_brace_depth = pk.pkgcls_brace_depth + 1
          if pk.pkgcls_brace_depth == 1 then
            pk.pkgcls_argnum = pk.pkgcls_argnum + 1
          end
        end
        pk.pkgcls_bracket_pending = false
        if fl.in_file_arg and not fl.file_arg_done then
          fl.file_arg_depth = fl.file_arg_depth + 1
        end
        if hk.in_hook_label then
          hk.hook_label_depth = hk.hook_label_depth + 1
          if hk.hook_label_depth == 1 then
            hk.hook_label_argnum = hk.hook_label_argnum + 1
          end
        end
        if kv.in_single_keyval then
          kv.single_keyval_depth = kv.single_keyval_depth + 1
        end
        if ft.font_brace_pending then
          ft.font_brace_depth = ft.font_brace_depth + 1
        end
        -- Si esperábamos un '[' opcional y en cambio llega otra '{'
        -- (sin corchete de por medio), descartamos la espera.
        ft.font_bracket_pending = false
      elseif chunk == '}' then
        if cs.name_depth == cs.brace_depth then cs.name_depth = 0 end
        cs.brace_depth = cs.brace_depth - 1
        if cs.brace_depth < cs.csname_frame_depth then
          -- Se cerró el grupo que contenía al comando vigente: volvemos al
          -- marco del comando exterior (si lo hay).
          local fr = csname_frames[#csname_frames]
          for k in pairs(csname_positions) do csname_positions[k] = nil end
          if fr then
            csname_frames[#csname_frames] = nil
            for k, v in pairs(fr[1]) do csname_positions[k] = v end
            cs.arg_counter, cs.csname_frame_depth = fr[2], fr[3]
          else
            cs.csname_frame_depth = cs.brace_depth
          end
        end
        if cs.in_csname then
          if cs.csname_depth > 0 then cs.csname_depth = cs.csname_depth - 1
          else cs.in_csname, cs.csname_depth = false, 0 end
        end
        if cs.in_variant_group then
          if cs.variant_depth > 0 then cs.variant_depth = cs.variant_depth - 1
          else
            cs.in_variant_group = false
            cs.variant_braces_remaining = cs.variant_braces_remaining - 1
          end
        end
        if lt.ltcmd_in_args and lt.ltcmd_brace_count > 0 then
          lt.ltcmd_brace_count = lt.ltcmd_brace_count - 1
          if lt.ltcmd_brace_count == 0 then lt.ltcmd_in_args = false end
        elseif lt.ltcmd_name_pending and lt.ltcmd_brace_count > 0 then
          lt.ltcmd_brace_count = lt.ltcmd_brace_count - 1
          if lt.ltcmd_brace_count == 0 then
            lt.ltcmd_name_pending, lt.ltcmd_in_args = false, true
          end
        end
        if ml.mathml_brace_count > 0 then
          ml.mathml_brace_count = ml.mathml_brace_count - 1
          if ml.mathml_brace_count == 0 then
            ml.in_mathml_intent, ml.in_mathml_arg = false, false
          end
        end
        if kv.in_keys_context and kv.keys_depth > 0 then
          kv.keys_depth = kv.keys_depth - 1
          if kv.keys_in_choices and kv.keys_depth == 1 then
            kv.keys_in_choices = false
          end
          if kv.keys_depth == 0 then
            if not kv.keys_body_opened then
              kv.keys_body_opened = true
            else
              -- Restaura el contexto exterior si este venía anidado.
              local saved = keys_context_stack[#keys_context_stack]
              if saved then
                keys_context_stack[#keys_context_stack] = nil
                kv.keys_body_opened, kv.keys_depth, kv.keys_in_choices =
                  saved[1], saved[2], saved[3]
                kv.in_keys_context = true
              else
                kv.in_keys_context, kv.keys_body_opened = false, false
              end
            end
          end
        end
        if kv.keys_meta_pending and kv.keys_meta_brace_count > 0 then
          kv.keys_meta_brace_count = kv.keys_meta_brace_count - 1
          if kv.keys_meta_brace_count == 0 then
            if kv.keys_meta_arity == 1 or kv.keys_meta_argnum >= 2 then
              kv.keys_meta_pending = false
            end
          end
        end
        if ms.in_msgerror and ms.msgerror_depth > 0 then
          ms.msgerror_depth = ms.msgerror_depth - 1
          if ms.msgerror_depth == 0 and ms.msgerror_argnum >= 5 then
            ms.in_msgerror, ms.msgerror_argnum, ms.msgerror_is_unknown = false, 0, false
          end
        end
        if ms.in_msg_simple and not ms.msg_simple_done and ms.msg_simple_depth > 0 then
          ms.msg_simple_depth = ms.msg_simple_depth - 1
          if ms.msg_simple_depth == 0 then
            ms.msg_simple_done, ms.in_msg_simple = true, false
          end
        end
        if kv.in_keys_module_arg and not kv.keys_module_arg_done
           and kv.keys_module_arg_depth > 0 then
          kv.keys_module_arg_depth = kv.keys_module_arg_depth - 1
          if kv.keys_module_arg_depth == 0
             and kv.keys_module_arg_argnum >= kv.keys_module_arg_total_n then
            kv.keys_module_arg_done, kv.in_keys_module_arg = true, false
          end
        end
        if pk.provides_pkg_pending and pk.provides_pkg_brace_count > 0 then
          pk.provides_pkg_brace_count = pk.provides_pkg_brace_count - 1
          if pk.provides_pkg_brace_count == 0 then
            pk.provides_pkg_pending = false
          end
        end
        if pk.pkgcls_pending and pk.pkgcls_brace_depth > 0 then
          pk.pkgcls_brace_depth = pk.pkgcls_brace_depth - 1
          if pk.pkgcls_brace_depth == 0 and pk.pkgcls_argnum >= pk.pkgcls_target_arg then
            pk.pkgcls_pending = false
          end
        end
        if fl.in_file_arg and not fl.file_arg_done and fl.file_arg_depth > 0 then
          fl.file_arg_depth = fl.file_arg_depth - 1
          if fl.file_arg_depth == 0 then
            fl.file_arg_done, fl.in_file_arg = true, false
          end
        end
        if hk.in_hook_label and hk.hook_label_depth > 0 then
          hk.hook_label_depth = hk.hook_label_depth - 1
          if hk.hook_label_depth == 0 and hk.hook_label_argnum >= hk.hook_label_total_n then
            hk.in_hook_label = false
          end
        end
        if kv.in_single_keyval and kv.single_keyval_depth > 0 then
          kv.single_keyval_depth = kv.single_keyval_depth - 1
          if kv.single_keyval_depth == 0 then
            kv.in_single_keyval = false
          end
        end
        if ft.font_brace_pending and ft.font_brace_depth > 0 then
          ft.font_brace_depth = ft.font_brace_depth - 1
          if ft.font_brace_depth == 0 then
            ft.font_brace_pending = false
            ft.font_bracket_pending = true
          end
        end
      end
      h, tl = mylhmc_colored_str(chunk, 'brace', fid)
    elseif t == 3 then
      if chunk == '[' then
        if pk.pkgcls_bracket_pending then
          pk.pkgcls_bracket_active, pk.pkgcls_bracket_depth, pk.pkgcls_bracket_pending =
            true, 1, false
        elseif pk.pkgcls_bracket_active then
          pk.pkgcls_bracket_depth = pk.pkgcls_bracket_depth + 1
        end
        if ft.font_bracket_pending then
          ft.font_bracket_active, ft.font_bracket_depth, ft.font_bracket_pending =
            true, 1, false
        elseif ft.font_bracket_active then
          ft.font_bracket_depth = ft.font_bracket_depth + 1
        end
      elseif chunk == ']' then
        if pk.pkgcls_bracket_active and pk.pkgcls_bracket_depth > 0 then
          pk.pkgcls_bracket_depth = pk.pkgcls_bracket_depth - 1
          if pk.pkgcls_bracket_depth == 0 then
            pk.pkgcls_bracket_active = false
          end
        end
        if ft.font_bracket_active and ft.font_bracket_depth > 0 then
          ft.font_bracket_depth = ft.font_bracket_depth - 1
          if ft.font_bracket_depth == 0 then
            ft.font_bracket_active = false
          end
        end
      end
      h, tl = mylhmc_colored_str(chunk, 'bracket', fid)
    elseif t == 24 then
      local hashes = s_match(chunk, '^#+')
      local num    = s_sub(chunk, #hashes + 1)
      h, tl = mylhmc_colored_str(hashes, 'argument', fid); rh, rt = mylhmc_append(rh, rt, h, tl)
      h, tl = mylhmc_colored_str(num, 'argnum', fid)
    elseif t == 26 then
      cs.variant_depth, cs.in_variant_group = 0, false
      if s_find(chunk, 'prg_generate_conditional_variant', 1, true) then
        cs.variant_braces_remaining = 2
      else cs.variant_braces_remaining = 1 end
      h, tl = mylhmc_emit_with_signature(chunk, 'publicfun', fid)
    elseif t == 30 then
      cs.in_csname, cs.csname_base_color, cs.csname_depth = true, nil, 0
      h, tl = mylhmc_colored_str(chunk, 'publicfun', fid)
    elseif t == 31 then
      cs.in_csname = false; h, tl = mylhmc_colored_str(chunk, 'publicfun', fid)
    elseif t == 16 then
      local dot  = s_sub(chunk, 1, 1)
      local rest = s_sub(chunk, 2)
      local colon = s_find(rest, ':', 1, true)
      h, tl = mylhmc_colored_str(dot, 'signature', fid); rh, rt = mylhmc_append(rh, rt, h, tl)
      if colon then
        local kname, kargs = s_sub(rest, 1, colon - 1), s_sub(rest, colon + 1)
        if kv.in_keys_context and kv.keys_body_opened and kv.keys_depth == 1 then
          kv.keys_in_choices = (kname == 'choices')
        end
        -- .meta:nn/.meta:n es autocontenido (sus dos argumentos son ruta
        -- de módulo + lista de claves, sin depender de estar dentro de
        -- un \keys_define:nn real) -- se reconoce sin importar el
        -- contexto, para que \myhlc también lo coloree correctamente.
        if kname == 'meta' then
          kv.keys_meta_pending, kv.keys_meta_argnum, kv.keys_meta_brace_count =
            true, 0, 0
          kv.keys_meta_arity = (kargs == 'n') and 1 or 2
        else
          kv.keys_meta_pending = false
        end
        mylhmc_reset_csname_state(); local cpos = 0
        for i = 1, #kargs do
          local ch = s_sub(kargs, i, i)
          if s_match(ch, '[NnVvoxefpTFwDcq]') then
            cpos = cpos + 1
            if ch == 'c' or ch == 'v' then csname_positions[cpos] = true end
          end
        end
        h, tl = mylhmc_colored_str(kname, 'keyfun', fid); rh, rt = mylhmc_append(rh, rt, h, tl)
        h, tl = mylhmc_colored_str(':', 'signature', fid); rh, rt = mylhmc_append(rh, rt, h, tl)
        h, tl = mylhmc_colored_str(kargs, 'sigargs', fid)
      else h, tl = mylhmc_colored_str(rest, 'keyfun', fid) end
    elseif t == 9 then
      h, tl = mylhmc_colored_str(s_sub(chunk, 1, 1), 'percent', fid)
      rh, rt = mylhmc_append(rh, rt, h, tl)
      h, tl = mylhmc_colored_str_italic(s_sub(chunk, 2), 'comment', fid)
    elseif t == 14 then
      lt.ltcmd_brace_count, lt.ltcmd_name_pending, lt.ltcmd_in_args = 0, true, false
      h, tl = mylhmc_emit_with_signature(chunk, 'ltcmd', fid)
    elseif t == 39 then
      if kv.in_keys_context then
        keys_context_stack[#keys_context_stack + 1] =
          { kv.keys_body_opened, kv.keys_depth, kv.keys_in_choices }
      end
      kv.in_keys_context, kv.keys_body_opened, kv.keys_depth = true, false, 0
      kv.keys_in_choices = false
      h, tl = mylhmc_emit_with_signature(chunk, 'publicfun', fid)
    elseif t == 40 then
      ms.in_msgerror, ms.msgerror_argnum, ms.msgerror_depth, ms.msgerror_is_unknown =
        true, 0, 0, false
      h, tl = mylhmc_emit_with_signature(chunk, 'publicfun', fid)
    elseif t == 41 then
      ms.in_msg_simple, ms.msg_simple_depth, ms.msg_simple_done = true, 0, false
      h, tl = mylhmc_emit_with_signature(chunk, 'publicfun', fid)
    elseif t == 44 then
      kv.in_keys_module_arg, kv.keys_module_arg_depth, kv.keys_module_arg_done =
        true, 0, false
      kv.keys_module_arg_argnum = 0
      local colon = s_find(chunk, ':', 1, true)
      local sig = colon and s_sub(chunk, colon + 1) or ''
      local n_count = 0
      for ch in s_gmatch(sig, '.') do
        if ch == 'n' then n_count = n_count + 1 end
      end
      kv.keys_module_arg_total_n = n_count
      h, tl = mylhmc_emit_with_signature(chunk, 'publicfun', fid)
    elseif t == 46 then
      fl.in_file_arg, fl.file_arg_depth, fl.file_arg_done = true, 0, false
      -- Coincidencia de PREFIJO exacto justo tras el '\' (no substring en
      -- cualquier parte): evita que \file_input:n "contenga" 'input' y
      -- se confunda con el \input clásico.
      local name_start = s_sub(chunk, 2)
      local function starts_with(prefix)
        return s_sub(name_start, 1, #prefix) == prefix
      end
      fl.file_arg_is_list = starts_with('includeonly')
      local base
      if fl.file_arg_is_list
         or starts_with('InputIfFileExists')
         or starts_with('include')
         or starts_with('input') then
        base = 'pkgstruct'
      else
        base = mylhmc_module_aware_color(chunk, 'publicfun')
      end
      h, tl = mylhmc_emit_with_signature(chunk, base, fid)
    elseif t == 47 then
      hk.in_hook_label, hk.hook_label_depth, hk.hook_label_argnum = true, 0, 0
      local colon = s_find(chunk, ':', 1, true)
      local sig = colon and s_sub(chunk, colon + 1) or ''
      local n_count = 0
      for ch in s_gmatch(sig, '.') do
        if ch == 'n' then n_count = n_count + 1 end
      end
      hk.hook_label_total_n = n_count
      if s_find(chunk, 'hook_gset_rule', 1, true) then
        hk.hook_label_positions = { [2] = true, [4] = true }
      else
        hk.hook_label_positions = { [2] = true }
      end
      h, tl = mylhmc_emit_with_signature(chunk, mylhmc_module_aware_color(chunk, 'publicfun'), fid)
    elseif t == 48 then
      -- package/NOMBRE/before|after (también class/... y file/...):
      -- colorea solo el NOMBRE de en medio.
      local slash1 = s_find(chunk, '/', 1, true)
      local slash2 = s_find(chunk, '/', slash1 + 1, true)
      h, tl = mylhmc_str_to_nodes(s_sub(chunk, 1, slash1), fid); rh, rt = mylhmc_append(rh, rt, h, tl)
      h, tl = mylhmc_colored_str(s_sub(chunk, slash1 + 1, slash2 - 1), 'module_name', fid)
      rh, rt = mylhmc_append(rh, rt, h, tl)
      h, tl = mylhmc_str_to_nodes(s_sub(chunk, slash2), fid)
    elseif t == 34 then
      h, tl = mylhmc_emit_with_signature(chunk, 'publicfun', fid)
      csname_positions[1] = true
    elseif t == 33 then h, tl = mylhmc_emit_with_signature(chunk, 'ltcmd_arg', fid)
    elseif lt.ltcmd_name_pending and lt.ltcmd_brace_count == 1 then
      rh, rt = mylhmc_emit_csname_text(chunk, mylhmc_ltcmd_name_color(chunk), fid, rh, rt)
      h, tl = nil, nil
    elseif lt.ltcmd_name_pending and lt.ltcmd_brace_count == 0 and s_sub(chunk, 1, 1) == '\\' then
      h, tl = mylhmc_colored_str(chunk, mylhmc_ltcmd_name_color(chunk), fid)
      lt.ltcmd_name_pending, lt.ltcmd_in_args = false, true
    elseif lt.ltcmd_in_args then
      if lt.ltcmd_brace_count > 1 then h, tl = mylhmc_colored_str(chunk, type_colors[t], fid)
      else rh, rt = mylhmc_colorize_ltcmd_args(chunk, fid, rh, rt); h, tl = nil, nil end
    elseif cs.in_csname then
      cs.csname_base_color = cs.csname_base_color or mylhmc_csname_color_from_prefix(chunk)
      if s_sub(chunk, 1, 1) == '\\' then
        h, tl = mylhmc_colored_str(chunk, type_colors[t], fid)
      else rh, rt = mylhmc_emit_csname_text(chunk, cs.csname_base_color, fid, rh, rt); h, tl = nil, nil end
    elseif t == 5 or t == 6 then
      if lt.ltcmd_in_args or lt.ltcmd_name_pending then
        lt.ltcmd_in_args, lt.ltcmd_name_pending, lt.ltcmd_brace_count = false, false, 0
      end
      local eff
      if t == 6 then
        eff = mylhmc_module_aware_color(chunk, 'publicfun')
      else
        eff = mylhmc_private_owner_color(chunk, 'privatefun')
      end
      h, tl = mylhmc_emit_with_signature(chunk, eff, fid)
    elseif t == 25 then
      cs.arg_counter = 0
      if s_find(chunk, 'ProvidesExplPackage', 1, true) then
        pk.provides_pkg_pending, pk.provides_pkg_brace_count = true, 0
      end
      h, tl = mylhmc_colored_str_bold(chunk, 'structure', fid)
    elseif t == 37 then
      pk.pkgcls_bracket_pending = false
      if s_find(chunk, 'ProvidesPackage', 1, true) then
        pk.pkgcls_pending, pk.pkgcls_target_arg, pk.pkgcls_color = true, 1, 'pkgname'
      elseif s_find(chunk, 'ProvidesClass', 1, true) then
        pk.pkgcls_pending, pk.pkgcls_target_arg, pk.pkgcls_color = true, 1, 'clsname'
      elseif s_find(chunk, 'RequirePackageWithOptions', 1, true) then
        pk.pkgcls_pending, pk.pkgcls_target_arg, pk.pkgcls_color = true, 1, 'pkgname'
      elseif s_find(chunk, 'RequirePackage', 1, true) then
        pk.pkgcls_pending, pk.pkgcls_target_arg, pk.pkgcls_color = true, 1, 'pkgname'
        pk.pkgcls_bracket_pending = true
      elseif s_find(chunk, 'LoadClassWithOptions', 1, true) then
        pk.pkgcls_pending, pk.pkgcls_target_arg, pk.pkgcls_color = true, 1, 'clsname'
      elseif s_find(chunk, 'LoadClass', 1, true) then
        pk.pkgcls_pending, pk.pkgcls_target_arg, pk.pkgcls_color = true, 1, 'clsname'
        pk.pkgcls_bracket_pending = true
      elseif s_find(chunk, 'PassOptionsToPackage', 1, true) then
        pk.pkgcls_pending, pk.pkgcls_target_arg, pk.pkgcls_color = true, 2, 'pkgname'
      elseif s_find(chunk, 'PassOptionsToClass', 1, true) then
        pk.pkgcls_pending, pk.pkgcls_target_arg, pk.pkgcls_color = true, 2, 'clsname'
      elseif s_find(chunk, 'IfPackageLoaded', 1, true) then
        pk.pkgcls_pending, pk.pkgcls_target_arg, pk.pkgcls_color = true, 1, 'pkgname'
      else
        pk.pkgcls_pending = false
      end
      if pk.pkgcls_pending then pk.pkgcls_argnum, pk.pkgcls_brace_depth = 0, 0 end
      if s_find(chunk, 'IfFileExists', 1, true) then
        fl.in_file_arg, fl.file_arg_depth, fl.file_arg_done = true, 0, false
      end
      h, tl = mylhmc_emit_with_signature(chunk, 'pkgstruct', fid)
    elseif t == 49 then
      if s_find(chunk, 'hypersetup', 1, true)
         or s_find(chunk, 'unimathsetup', 1, true)
         or s_find(chunk, 'addfontfeature', 1, true)
         or s_find(chunk, 'defaultfontfeatures', 1, true) then
        kv.in_single_keyval, kv.single_keyval_depth = true, 0
      elseif s_find(chunk, 'setmainfont', 1, true)
         or s_find(chunk, 'setsansfont', 1, true)
         or s_find(chunk, 'setmonofont', 1, true)
         or s_find(chunk, 'setboldmathrm', 1, true)
         or s_find(chunk, 'setmathrm', 1, true)
         or s_find(chunk, 'setmathsf', 1, true)
         or s_find(chunk, 'setmathtt', 1, true)
         or s_find(chunk, 'setmathfont', 1, true)
         or s_find(chunk, 'fontspec', 1, true) then
        ft.font_brace_pending, ft.font_brace_depth = true, 0
      end
      h, tl = mylhmc_emit_with_signature(chunk, 'support', fid)
    elseif t == 38 then
      ml.mathml_brace_count, ml.mathml_after_dollar = 0, false
      if s_find(chunk, 'MathMLintent', 1, true) then
        ml.in_mathml_intent, ml.in_mathml_arg = true, false
      elseif s_find(chunk, 'MathMLarg', 1, true) then
        ml.in_mathml_arg, ml.in_mathml_intent = true, false
      else ml.in_mathml_intent, ml.in_mathml_arg = false, false end
      if s_find(chunk, 'tagpdfsetup', 1, true)
         or s_find(chunk, 'tagtool', 1, true)
         or s_find(chunk, 'tagmcbegin', 1, true)
         or s_find(chunk, 'tagstructbegin', 1, true)
         or s_find(chunk, 'ShowTagging', 1, true)
         or s_find(chunk, 'tag_struct_begin:n', 1, true)
         or s_find(chunk, 'tag_struct_end:n', 1, true)
         or s_find(chunk, 'tag_mc_begin:n', 1, true)
         or s_find(chunk, 'tag_mc_begin_pop:n', 1, true)
         or s_find(chunk, 'tag_tool:n', 1, true) then
        kv.in_single_keyval, kv.single_keyval_depth = true, 0
      end
      h, tl = mylhmc_emit_with_signature(chunk, 'mathtag', fid)
      -- \tag_suspend:n{label} etc.: si la etiqueta es del módulo, module_name.
      if tag_label_cmds[chunk] then
        rh, rt = mylhmc_append(rh, rt, h, tl); h, tl = nil, nil
        rh, rt, e = mylhmc_module_brace_arg(line, e, fid, rh, rt)
      end
    elseif ml.in_mathml_intent then
      if t == 21 then ml.mathml_after_dollar = true; h, tl = mylhmc_colored_str(s_sub(chunk, 1, 1), 'math', fid)
      elseif ml.mathml_after_dollar then
        ml.mathml_after_dollar = false
        rh, rt = mylhmc_colorize_mathml_intent(chunk, fid, rh, rt); h, tl = nil, nil
      else rh, rt = mylhmc_colorize_mathml_intent(chunk, fid, rh, rt); h, tl = nil, nil end
    elseif ml.in_mathml_arg then
      if t == 4 then
        h, tl = mylhmc_colorize_name_with_argnum(chunk, fid, mylhmc_module_aware_color(chunk, 'publicvar'))
      elseif t == 2 then
        h, tl = mylhmc_colorize_name_with_argnum(chunk, fid, mylhmc_private_owner_color(chunk, 'privatevar'))
      else
        h, tl = mylhmc_colored_str(chunk, 'mathml_var', fid)
      end
    elseif t == 42 then
      h, tl = mylhmc_colored_str(':', 'signature', fid); rh, rt = mylhmc_append(rh, rt, h, tl)
      local rest = s_sub(chunk, 2)
      local ws = s_match(rest, '^([ \t]*)')
      local after_ws = s_sub(rest, #ws + 1)
      if ws ~= '' then
        h, tl = mylhmc_str_to_nodes(ws, fid); rh, rt = mylhmc_append(rh, rt, h, tl)
      end
      local paren_start = s_find(after_ws, '(', 1, true)
      local word = paren_start and s_sub(after_ws, 1, paren_start - 1) or after_ws
      h, tl = mylhmc_colored_str(word, 'intent', fid); rh, rt = mylhmc_append(rh, rt, h, tl)
      if paren_start then
        local paren_content = s_sub(after_ws, paren_start)
        rh, rt = mylhmc_colorize_mathml_intent(paren_content, fid, rh, rt)
      end
      h, tl = nil, nil
    elseif t == 35 then
      local split = s_find(chunk, '%a')
      if split then
        h, tl = mylhmc_colored_str(s_sub(chunk, 1, split-1), 'number', fid)
        rh, rt = mylhmc_append(rh, rt, h, tl)
        h, tl = mylhmc_colored_str(s_sub(chunk, split), 'unit', fid)
      else h, tl = mylhmc_colored_str(chunk, 'number', fid) end
    elseif t == 18 then
      local four_caret = '\x5e\x5e\x5e\x5e'
      if s_sub(chunk, 1, 4) == four_caret then
        h, tl = mylhmc_colored_str(four_caret, 'escape', fid); rh, rt = mylhmc_append(rh, rt, h, tl)
        h, tl = mylhmc_colored_str(s_sub(chunk, 5), 'number', fid)
      else h, tl = mylhmc_colored_str(chunk, 'escape', fid) end
    elseif t == 13 then h, tl = mylhmc_emit_with_signature(chunk, 'danger', fid)
    elseif t == 15 then
      local cur, len = 2, #chunk
      for i = 2, len do
        local b = s_byte(chunk, i)
        if b == 64 or b == 33 or b == 38 or b == 94 or b == 42 then
          local part = (cur == 2 and '\\' or '') .. s_sub(chunk, cur, i - 1)
          if #part > 0 then
            local pcolor = mylhmc_module_aware_color(part, 'legacy_at')
            h, tl = mylhmc_colored_str(part, pcolor, fid)
            rh, rt = mylhmc_append(rh, rt, h, tl)
          end
          local color_name = (b == 64 and 'arroba') or (b == 42 and 'star') or 'escape'
          h, tl = mylhmc_colored_str(s_sub(chunk, i, i), color_name, fid)
          rh, rt = mylhmc_append(rh, rt, h, tl); cur = i + 1
        end
      end
      if cur <= len then
        local trailing = (cur == 2 and '\\' or '') .. s_sub(chunk, cur)
        h, tl = mylhmc_colored_str(trailing, mylhmc_module_aware_color(trailing, 'legacy_at'), fid)
      else h, tl = nil, nil end
    elseif t == 52 then
      local name = s_sub(chunk, 4)
      local sp = s_match(name, '^ *')
      name = s_sub(name, #sp + 1)
      h, tl = mylhmc_colored_str('\\c', 'latex_cmd', fid); rh, rt = mylhmc_append(rh, rt, h, tl)
      h, tl = mylhmc_colored_str('@', 'arroba', fid); rh, rt = mylhmc_append(rh, rt, h, tl)
      if sp ~= '' then
        h, tl = mylhmc_str_to_nodes(sp, fid); rh, rt = mylhmc_append(rh, rt, h, tl)
      end
      local base
      if s_sub(name, 1, 2) == '__' then base = mylhmc_private_owner_color(name, 'privatevar')
      else base = mylhmc_module_aware_color(name, 'latex_cmd') end
      h, tl = mylhmc_colorize_name_with_argnum(name, fid, base)
    elseif t == 4 then
      h, tl = mylhmc_colorize_name_with_argnum(chunk, fid, mylhmc_module_aware_color(chunk, 'publicvar'))
    elseif t == 2 then
      h, tl = mylhmc_colorize_name_with_argnum(chunk, fid, mylhmc_private_owner_color(chunk, 'privatevar'))
    elseif t == 19 then
      h, tl = mylhmc_colored_str(chunk, mylhmc_private_owner_color(chunk, 'constant'), fid)
    else
      local effective = type_colors[t]
      if effective then
        local bare = s_sub(chunk, 1, 1) == '\\' and s_sub(chunk, 2) or chunk
        if t == 23 and primitive_names[bare] then effective = 'primitive' end
        if module_user_cmds[bare] or module_user_cmds[chunk] then effective = 'module_name' end
      end
      h, tl = mylhmc_colored_str(chunk, effective, fid)
      -- \begin{env}/\end{env}/\newenvironment{env}: si env es del módulo
      -- (provide o nombre con el módulo), se colorea como module_name.
      if env_name_cmds[chunk] then
        rh, rt = mylhmc_append(rh, rt, h, tl); h, tl = nil, nil
        rh, rt, e = mylhmc_module_brace_arg(line, e, fid, rh, rt)
      end
      -- \newcounter{nombre}, \setcounter{nombre}{…}, \value{nombre}…
      local counter_n = counter_cmds[chunk]
      if counter_n then
        rh, rt = mylhmc_append(rh, rt, h, tl); h, tl = nil, nil
        rh, rt, e = counter_cmds.apply(line, e, fid, rh, rt, counter_n)
      end
    end
    local sock_n = socket_cmds[chunk]
    if sock_n then
      rh, rt = mylhmc_append(rh, rt, h, tl); h, tl = nil, nil
      rh, rt, e = mylhmc_socket_args(line, e, fid, rh, rt, sock_n)
    end
    rh, rt = mylhmc_append(rh, rt, h, tl); pos = e
  end
  return rh, rt
end

local function mylhmc_make_angle_nodes(content_head, content_tail, angle_color, fid)
  local lm_fid = mylhmc_get_lm_fid(fid)
  local cname = (color_data[angle_color] and angle_color) or 'guard_angle'
  local lg, rg = d_new('glyph'), d_new('glyph')
  d_setfield(lg, 'font', lm_fid)
  d_setfield(lg, 'char', LM_LANGLE)
  d_setfield(rg, 'font', lm_fid)
  d_setfield(rg, 'char', LM_RANGLE)
  local rh, rt = nil, nil
  if color_data[cname] then rh, rt = mylhmc_append(rh, rt, mylhmc_colorstack_push(cname)) end
  rh, rt = mylhmc_append(rh, rt, lg)
  if color_data[cname] then rh, rt = mylhmc_append(rh, rt, mylhmc_colorstack_pop()) end
  if content_head then rh, rt = mylhmc_append(rh, rt, content_head, content_tail) end
  if color_data[cname] then rh, rt = mylhmc_append(rh, rt, mylhmc_colorstack_push(cname)) end
  rh, rt = mylhmc_append(rh, rt, rg)
  if color_data[cname] then rh, rt = mylhmc_append(rh, rt, mylhmc_colorstack_pop()) end
  return rh, rt
end

-- Mapea cada símbolo de guarda a su propio color independiente y editable.
local function mylhmc_guard_symbol_color(b)
  if b == 42 then return 'guard_star'    -- *
  elseif b == 47 then return 'guard_slash'  -- /
  elseif b == 40 or b == 41 then return 'guard_paren' -- ( )
  elseif b == 38 then return 'guard_amp'    -- &
  elseif b == 124 then return 'guard_pipe'  -- |
  elseif b == 33 then return 'guard_bang'   -- !
  end
  return 'guard_star' -- inalcanzable: cubre todos los bytes que recibe
end

local function mylhmc_colorize_guard_expr(expr, fid)
  local rh, rt, name_start, len = nil, nil, 1, #expr
  for i = 1, len do
    local b = s_byte(expr, i)
    if b == 33 or b == 32 or b == 38 or b == 40 or b == 41 or b == 42 or
       b == 47 or b == 124 then
      if name_start <= i - 1 then
        local h, t = mylhmc_colored_str(s_sub(expr, name_start, i - 1), 'guard_name', fid)
        rh, rt = mylhmc_append(rh, rt, h, t)
      end
      name_start = i + 1
      if b ~= 32 then
        local h, t = mylhmc_colored_str(s_sub(expr, i, i), mylhmc_guard_symbol_color(b), fid)
        rh, rt = mylhmc_append(rh, rt, h, t)
      end
    end
  end
  if name_start <= len then
    local h, t = mylhmc_colored_str(s_sub(expr, name_start, len), 'guard_name', fid)
    rh, rt = mylhmc_append(rh, rt, h, t)
  end
  return rh, rt
end

local function mylhmc_apply_at_at(line)
  if not s_find(line, '@@', 1, true) then return line end
  if current_module_name ~= '' then
    line = s_gsub(line, '@@@@', '\0')
    line = s_gsub(line, '__@@', current_module_prefix)
    line = s_gsub(line, '_@@',  current_module_prefix)
    line = s_gsub(line, '@@',   current_module_prefix)
    line = s_gsub(line, '\0',   '@@')
  end
  return line
end

local function mylhmc_render_guard(line, fid)
  local rest = s_gsub(line, '^%s*', '')
  local close = s_find(rest, '>', 2)
  if not close then
    local h, t = mylhmc_colored_str('%', 'percent', fid)
    if h then n_write(d_tonode(h)) end
    h, t = mylhmc_colored_str_italic(line, 'comment', fid)
    if h then n_write(d_tonode(h)) end
    return
  end
  local inner = s_sub(rest, 2, close - 1)
  local after = s_sub(rest, close + 1)
  local ch, ct, h, t = nil, nil, nil, nil

  if s_sub(inner, 1, 3) == '@@=' then
    local modname = s_sub(inner, 4)
    t_set_macro('g__codedoc_module_name_tl', modname, 'global')
    current_module_name = modname
    current_module_prefix = '__' .. modname
    h, t = mylhmc_colored_str('@@', 'module_at', fid); ch, ct = mylhmc_append(ch, ct, h, t)
    h, t = mylhmc_colored_str('=', 'module_eq', fid); ch, ct = mylhmc_append(ch, ct, h, t)
    h, t = mylhmc_colored_str_bold(modname, 'module_name', fid); ch, ct = mylhmc_append(ch, ct, h, t)
  else
    local sigil, expr, first = '', inner, s_sub(inner, 1, 1)
    if first == '*' or first == '/' then sigil = first; expr = s_sub(inner, 2) end
    if sigil ~= '' then
      h, t = mylhmc_colored_str(sigil, mylhmc_guard_symbol_color(s_byte(sigil)), fid)
      ch, ct = mylhmc_append(ch, ct, h, t)
    end
    if expr ~= '' then
      h, t = mylhmc_colorize_guard_expr(expr, fid); ch, ct = mylhmc_append(ch, ct, h, t)
    end
  end

  local rh, rt = mylhmc_make_angle_nodes(ch, ct, 'guard_angle', fid)
  if rh then n_write(d_tonode(rh)) end
  if after and after ~= '' then
    after = mylhmc_apply_at_at(after)
    local ah = mylhmc_colorize_code(after, fid); if ah then n_write(d_tonode(ah)) end
  end
end

-- Sincroniza current_module_name al inicio de cada línea: prioriza
-- \g__codedoc_module_name_tl (real, de l3doc.cls); si está vacía, usa
-- el respaldo; si ambos están vacíos, no toca nada.
local function mylhmc_init_line_state()
  local m = t_get_macro('g__codedoc_module_name_tl')
  if m and m ~= '' then
    current_module_name = m
    current_module_prefix = '__' .. m
  elseif module_name_backup ~= '' then
    current_module_name = module_name_backup
    current_module_prefix = '__' .. module_name_backup
  end
end

-- Reemplazo mínimo de \BeginAccSupp{ActualText={}}/\EndAccSupp{} (accsupp)
-- vía whatsit pdf_literal directo: envuelve el número de línea en un
-- Span PDF con ActualText vacío, para que no se copie al extraer texto.
register_tex_cmd('luafun_actual_text_begin', function()
  local n = d_new('whatsit', 'pdf_literal')
  d_setfield(n, 'mode', 2)
  d_setfield(n, 'data', '/Span << /ActualText () >> BDC')
  n_write(d_tonode(n))
end, {})

register_tex_cmd('luafun_actual_text_end', function()
  local n = d_new('whatsit', 'pdf_literal')
  d_setfield(n, 'mode', 2)
  d_setfield(n, 'data', 'EMC')

  n_write(d_tonode(n))
end, {})

register_tex_cmd('luafun_inline', function()
  local text = t_get_macro('l__mylhmc_verbatim_line_tl')
  if not text or text == '' then return end
  text = s_gsub(text, '[\r\n]+$', '')
  mylhmc_init_line_state()
  text = mylhmc_apply_at_at(text)
  local fid = f_current()
  -- Modo csname: \myhlc|l_foo_tl| (sin backslash) -- se reconoce SOLO
  -- si el argumento completo tiene la forma de un nombre de variable;
  -- texto mixto ("ver l_foo_tl aqui") cae al dispatch normal.
  if bare_varname_full:match(text) then
    local h = mylhmc_render_bare_varname(text, fid)
    if h then n_write(d_tonode(h)) end
    ft.font_bracket_pending = false
    return
  end
  -- Expresión de intent suelta (\myhlc|nombre:prefix($a)|): se colorea
  -- como dentro de \MathMLintent{…} en macrocode (palabra de intent en
  -- ltcmd_arg, $var en mathml_var, etc.).
  do
    local kw = s_match(text, '^%s*[%w_%-]+%s*:%s*(%a+)')
    if kw and (kw == 'prefix' or kw == 'postfix' or kw == 'function' or
               kw == 'nofix' or kw == 'silent' or kw == 'time' or
               kw == 'date' or kw == 'infix') then
      local rh, rt = mylhmc_colorize_mathml_intent(text, fid, nil, nil)
      if rh then n_write(d_tonode(rh)) end
      ft.font_bracket_pending = false
      return
    end
  end
  local rh, rt = mylhmc_colorize_code(text, fid)
  if rh then n_write(d_tonode(rh)) end
  ft.font_bracket_pending = false
end, {})

register_tex_cmd('luafun_process_line', function()
  local line = t_get_macro('l__mylhmc_verbatim_line_tl')
  if not line or line == '' then return end
  line = s_gsub(line, '[\r\n]+$', '')
  if line == '' then return end
  mylhmc_init_line_state()
  local fid = f_current()
  -- Detecta guardas (%<...>) ANTES de aplicar @@: si no, apply_at_at
  -- consume el '@@=' y render_guard ya no reconoce %<@@=modulo>.
  if s_sub(line, 1, 1) == '%' then
    local rest = s_sub(line, 2)
    local trimmed = s_match(rest, '^%s*(.*)')
    if s_sub(trimmed, 1, 1) == '<' then
      mylhmc_render_guard(rest, fid)
      ft.font_bracket_pending = false
      return
    else
      -- comentario normal (no guarda): el shorthand @@ en comentarios
      -- explicativos sí debe sustituirse.
      line = mylhmc_apply_at_at(line)
      local h, t = mylhmc_colored_str(s_sub(line, 1, 1), 'percent', fid)
      if h then n_write(d_tonode(h)) end
      h, t = mylhmc_colored_str_italic(s_sub(line, 2), 'comment', fid)
      if h then n_write(d_tonode(h)) end
    end
  else
    line = mylhmc_apply_at_at(line)
    local indent = s_match(line, '^(%s+)')
    local rest = line
    local rh, rt
    if indent and indent ~= '' then
      rest = s_sub(line, #indent + 1)
      rh, rt = mylhmc_actual_text_wrap(indent, fid)
    end
    local ch, ct = mylhmc_colorize_code(rest, fid)
    rh, rt = mylhmc_append(rh, rt, ch, ct)
    if rh then n_write(d_tonode(rh)) end
  end
  ft.font_bracket_pending = false
end, {})
