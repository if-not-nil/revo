" Vim syntax file
" Language:          revo
" Maintainer:        Cheri Dawn (https://woem.net/)
" Last Change:       2026 Sep 20

" Quit when a (custom) syntax file was already loaded
if exists("b:current_syntax")
  finish
endif

setlocal iskeyword=48-57,A-Z,a-z,_,?,!

syn keyword revoKeyword const let macro test suite skip fn if unless else match when do end loop for while global break continue return import spawn yield comp proc pub declare
syn keyword revoOperator in is and or not band bor bxor shl shr orelse
syn keyword revoType number string bool any table function atom never
syn keyword revoTypedef type
syn keyword revoBuiltin print inspect input assert

syn match revoMethod ":\<[a-zA-Z_][a-zA-Z_0-9\?]*\>\ze\s*[({"']"

syn match revoNumber "\<0x_\=\x\+\%(_\x\+\)*\>"
syn match revoNumber "\<\%([1-9]\d*\%(_\d\+\)*\|0\+\%(_0\+\)*\)\>"
syn match revoNumber "\<\%(\d*\%(_\d\+\)*\.\d*\%(_\d\+\)*\)\>"

syn match revoAtom ":\<[a-zA-Z_][a-zA-Z0-9_]*\%((\)\@!\>"
syn match revoSpecialAtom ":\<\%(true\|false\|yes\|no\|ok\|err\|nil\)\>"

syn match revoStringSpecial display contained "\\\%(x\x\x\|.\)"
syn region revoStringField
    \ matchgroup=revoStringDelimiter
    \ start=/#{/
    \ end=/\%(:[^{}]*\)\=}/
    \ contained
    \ contains=ALLBUT,revoStringField,@Spell

syn region revoString start=+"+ skip=+\\\\\|\\"+ end=+"+ contains=revoStringSpecial,revoStringField,@Spell extend
syn region revoRawString start=+'+ end=+'+ contains=@Spell extend
syn region revoMacroString start=+`+ end=+`+ extend

syn keyword revoTodo contained TODO FIXME XXX
syn match   revoComment "#.*$" contains=revoTodo,@Spell
syn region  revoCommentRegion start='#\z([#*!]\)' end='\z1#' contains=revoTodo


hi def link revoKeyword Keyword
hi def link revoOperator Operator
hi def link revoType Type
hi def link revoTypedef Typedef
hi def link revoBuiltin Function

hi def link revoMethod Function

hi def link revoNumber Number

hi def link revoAtom Special
hi def link revoSpecialAtom Boolean

hi def link revoString String
hi def link revoRawString String
hi def link revoMacroString String
hi def link revoStringSpecial Special
hi def link revoStringDelimiter Special

hi def link revoTodo Todo
hi def link revoComment Comment
hi def link revoCommentRegion Comment
