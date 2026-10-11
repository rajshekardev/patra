extern fn tree_sitter_patra() callconv(.c) *const anyopaque;

pub fn language() *const anyopaque {
    return tree_sitter_patra();
}
