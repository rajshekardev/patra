/**
 * @file Patra treesitter
 * @author Raj Shekar S
 * @license MIT
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

export default grammar({
  name: "patra",

  extras: $ => [],

  rules: {
    source_file: $ => repeat(choice(
      $.frontmatter,
      $.server_block,
      $.client_block,
      $.script_block,
      $.style_block,
      $.document_text
    )),

    frontmatter: $ => seq(
      choice("---\n", "---\r\n"),
      field("content", $.yaml_content),
      choice("\n---", "\r\n---")
    ),

    yaml_content: $ => repeat1($._content_character),

    server_block: $ => seq(
      "<odin server>",
      field("content", $.odin_content),
      "</odin>"
    ),

    client_block: $ => seq(
      "<odin client>",
      field("content", $.odin_content),
      "</odin>"
    ),

    odin_content: $ => repeat1($._content_character),

    script_block: $ => seq(
      "<script",
      optional(field("attributes", $.tag_attributes)),
      ">",
      field("content", $.script_content),
      "</script>"
    ),

    // Keep the complete attribute text as one node so injection queries can
    // choose JavaScript or TypeScript from `lang` without parsing the tag here.
    tag_attributes: _ => token(prec(1, /[^>]+/)),

    script_content: $ => repeat1($._content_character),

    style_block: $ => seq(
      "<style",
      optional(field("attributes", $.tag_attributes)),
      ">",
      field("content", $.css_content),
      "</style>"
    ),

    css_content: $ => repeat1($._content_character),

    document_text: $ => prec.right(repeat1($._content_character)),

    // A single character keeps the outer grammar lossless and lets closing
    // delimiters take precedence over the body text that surrounds them.
    _content_character: _ => /[\s\S]/,
  }
});
