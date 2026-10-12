//! Standalone entry point for the frontmatter reader's unit tests.
//!
//! The reader reaches into the context module for the template value types, so
//! a module rooted at `src/docs/` cannot resolve them. Rooting the test at
//! `src/` puts the whole tree in scope while leaving the production module
//! boundary where it is.

test {
    _ = @import("docs/frontmatter.zig");
}