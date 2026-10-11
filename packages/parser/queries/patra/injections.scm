; Patra owns the document boundaries. These injections route each body to
; the existing parser for its embedded language.
(frontmatter
  content: (yaml_content) @injection.content
  (#set! injection.language "yaml"))

(server_block
  content: (odin_content) @injection.content
  (#set! injection.language "odin"))

(client_block
  content: (odin_content) @injection.content
  (#set! injection.language "odin"))

(script_block
  attributes: (tag_attributes) @script.lang
  content: (script_content) @injection.content
  (#match? @script.lang "lang.*(js|javascript)")
  (#set! injection.language "javascript"))

(script_block
  attributes: (tag_attributes) @script.lang
  content: (script_content) @injection.content
  (#match? @script.lang "lang.*(ts|typescript)")
  (#set! injection.language "typescript"))

(style_block
  content: (css_content) @injection.content
  (#set! injection.language "css"))

; Text between Patra blocks is markup with template expressions.
((document_text) @injection.content
  (#set! injection.language "html"))
