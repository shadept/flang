using FLang.Lsp.Handlers;

namespace FLang.Tests;

public class WorkspaceSymbolsTests
{
    [Theory]
    [InlineData("string_builder", "", true)]                 // empty query matches anything
    [InlineData("string_builder", "string_builder", true)]   // exact
    [InlineData("string_builder", "STRING", true)]           // case insensitive
    [InlineData("string_builder", "sb", true)]               // subsequence
    [InlineData("string_builder", "sbld", true)]             // subsequence across word boundary
    [InlineData("string_builder", "stRGB", true)]            // mixed case, scattered
    [InlineData("string_builder", "xyz", false)]             // missing chars
    [InlineData("string_builder", "redniubgnirts", false)]   // right chars wrong order
    [InlineData("foo", "fooo", false)]                       // query longer than match-able sequence
    public void Subsequence_query_matches(string name, string query, bool expected)
    {
        Assert.Equal(expected, WorkspaceSymbolsHandler.MatchesQuery(name, query));
    }
}
