//! Standalone entry point for the docs-mode modules' unit tests.
//!
//! Both reach into the context module for the template value types, so a
//! module rooted at `src/docs/` cannot resolve them. Rooting the test at
//! `src/` puts the whole tree in scope while leaving the production module
//! boundaries where they are.

test {
    _ = @import("docs/frontmatter.zig");
    _ = @import("docs/GitDates.zig");
}