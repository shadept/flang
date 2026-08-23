using MediatR;
using OmniSharp.Extensions.JsonRpc;

namespace FLang.Lsp.Handlers;

[Method("flang/generatedContent", Direction.ClientToServer)]
public record GeneratedContentParams(string Uri) : IRequest<GeneratedContentResult>;

public record GeneratedContentResult(string? Content);

/// <summary>
/// Serves the text behind a <c>flang-generated://</c> URI so the editor can open
/// template-expansion output as a read-only virtual document (RFC-021 §4).
/// </summary>
public class GeneratedContentHandler(FLangWorkspace workspace)
    : IJsonRpcRequestHandler<GeneratedContentParams, GeneratedContentResult>
{
    public Task<GeneratedContentResult> Handle(GeneratedContentParams request, CancellationToken cancellationToken)
    {
        var uri = new Uri(request.Uri);
        var path = Uri.UnescapeDataString(uri.AbsolutePath);
        return Task.FromResult(new GeneratedContentResult(workspace.GetGeneratedContent(path)));
    }
}
