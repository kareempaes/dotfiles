; extends

; nvim-treesitter-textobjects marks Go statements with (block (_) @statement.outer), but
; tree-sitter-go now wraps a block's body in one statement_list node, so that capture is
; the whole body and "next statement" (Option+Down in keymaps.lua) only stopped at the
; first statement of each block. Mark each statement in the list instead.
(statement_list
  (_) @statement.outer)

; Top-level declarations are not statements, so the jump skipped them. @declaration.outer
; (our own capture, jumped to by keymaps.lua) marks each one, each entry of a grouped
; ( ... ) block, struct fields and interface methods. Only a grouped var block has a
; var_spec_list; const and type blocks hold their entries after the "(".
(source_file
  [
    (const_declaration)
    (var_declaration)
    (type_declaration)
  ] @declaration.outer)

[
  (field_declaration)
  (method_elem)
] @declaration.outer

(var_spec_list
  (var_spec) @declaration.outer)

(const_declaration
  "("
  (const_spec) @declaration.outer)

(type_declaration
  "("
  (type_spec) @declaration.outer)
