pub const ast = @import("ast.zig");
pub const pipeline = @import("lang_pipeline.zig");
pub const expander = @import("expander.zig");
pub const proc = @import("proc.zig");
pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const diagnostic = @import("diagnostic.zig");
pub const testing = @import("testing.zig");
pub const tests = @import("tests.zig");

pub const default_macro_source = pipeline.default_macro_source;
pub const parse = pipeline.parse;
pub const expand = pipeline.expand;
pub const lower = pipeline.lower;
pub const build = pipeline.build;

pub const compiler = @import("compiler/root.zig");

pub const LowerErrorKind = compiler.LowerErrorKind;
pub const LowerFailure = compiler.LowerFailure;
pub const LowerResult = compiler.LowerResult;
pub const Artifact = compiler.Artifact;
pub const ArtifactResult = compiler.ArtifactResult;
pub const LowerError = compiler.LowerError;
pub const Compiler = compiler.Compiler;
pub const lowerExprArtifactReport = compiler.lowerExprArtifactReport;
pub const types = compiler.types;
pub const ir = compiler.ir;

pub const renderError = pipeline.renderError;
pub const deinitError = pipeline.deinitError;
pub const expandExpr = expander.expandExpr;
pub const lex = lexer.lex;
pub const lexReport = lexer.lexReport;
pub const parseSource = pipeline.parseSource;
pub const parseSourceReport = pipeline.parseSourceReport;
pub const Node = ast.Node;
pub const Span = ast.Span;
pub const Expr = ast.Expr;
pub const isDiscardName = ast.isDiscardName;
pub const spanFromNodes = ast.spanFromNodes;
pub const Source = pipeline.Source;
pub const Parsed = pipeline.Parsed;
pub const Expanded = pipeline.Expanded;
pub const Error = pipeline.Error;
pub const ParseOptions = pipeline.ParseOptions;
pub const LowerOptions = pipeline.LowerOptions;
pub const BuildOptions = pipeline.BuildOptions;
pub const ParseResult = pipeline.ParseResult;
pub const ExpandResult = pipeline.ExpandResult;
pub const BuildResult = pipeline.BuildResult;
pub const ParseFailure = pipeline.ParseFailure;
pub const Diagnostic = diagnostic.Diagnostic;
pub const Label = diagnostic.Label;
pub const Note = diagnostic.Note;
pub const Severity = diagnostic.Severity;
pub const docs = @import("docs.zig");
pub const Token = lexer.Token;
pub const TokenType = lexer.TokenType;
pub const LexError = lexer.LexError;
pub const LexResult = lexer.LexResult;

test {
    _ = @import("ast.zig");
    _ = @import("docs.zig");
    _ = @import("expander.zig");
    _ = @import("proc.zig");
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("testing.zig");
    _ = @import("tests.zig");
    _ = @import("lang_pipeline.zig");
}
