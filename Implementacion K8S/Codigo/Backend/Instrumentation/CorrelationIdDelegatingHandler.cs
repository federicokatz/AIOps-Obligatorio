using Microsoft.AspNetCore.Http;

namespace Instrumentation;

public sealed class CorrelationIdDelegatingHandler : DelegatingHandler
{
    private readonly IHttpContextAccessor _accessor;

    public CorrelationIdDelegatingHandler(IHttpContextAccessor accessor) => _accessor = accessor;

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var context = _accessor.HttpContext;
        if (context?.Items[CorrelationIdMiddlewareExtensions.HttpContextItemKey] is string id && !string.IsNullOrWhiteSpace(id))
        {
            // El encabezado pertenece a esta solicitud, no a un HttpClient compartido.
            request.Headers.Remove("X-Correlation-ID");
            request.Headers.TryAddWithoutValidation("X-Correlation-ID", id);
        }
        return base.SendAsync(request, cancellationToken);
    }
}
