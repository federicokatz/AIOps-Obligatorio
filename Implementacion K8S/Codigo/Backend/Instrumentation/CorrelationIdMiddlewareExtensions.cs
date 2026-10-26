using System.Diagnostics;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Instrumentation;

public static class CorrelationIdMiddlewareExtensions
{
    public const string HttpContextItemKey = "YarpCorrelationId";

    public static IApplicationBuilder UseGatewayCorrelationId(this IApplicationBuilder app)
        => UseRequestCorrelation(app, gateway: true);

    public static IApplicationBuilder UseServiceCorrelationScope(this IApplicationBuilder app)
        => UseRequestCorrelation(app, gateway: false);

    private static IApplicationBuilder UseRequestCorrelation(IApplicationBuilder app, bool gateway)
    {
        return app.Use(async (context, next) =>
        {
            var header = context.Request.Headers["X-Correlation-ID"].FirstOrDefault();
            var correlationId = string.IsNullOrWhiteSpace(header)
                ? (gateway ? Guid.NewGuid().ToString("D") : context.TraceIdentifier)
                : header.Trim();
            context.Items[HttpContextItemKey] = correlationId;
            if (gateway)
                context.Response.Headers["X-Correlation-ID"] = correlationId;

            var scope = new Dictionary<string, object>
            {
                ["correlation_id"] = correlationId,
                ["service"] = context.RequestServices.GetService<IHostEnvironment>()?.ApplicationName ?? "unknown"
            };
            if (Activity.Current is { IdFormat: ActivityIdFormat.W3C } activity)
            {
                scope["trace_id"] = activity.TraceId.ToHexString();
                scope["span_id"] = activity.SpanId.ToHexString();
            }

            var log = context.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("Request");
            using (log.BeginScope(scope))
            {
                var watch = Stopwatch.StartNew();
                var failed = true;
                try
                {
                    await next();
                    failed = false;
                }
                finally
                {
                    // Evidencia para lecturas sin modificar sus controladores.
                    // No registrar query strings, cuerpos ni cabeceras de autenticacion.
                    if (context.Request.Path != "/health" && context.Request.Path != "/metrics")
                        log.LogInformation("HTTP {method} {path} completed {status_code} in {duration_ms} ms",
                            context.Request.Method, context.Request.Path.Value,
                            failed ? 500 : context.Response.StatusCode, watch.Elapsed.TotalMilliseconds);
                }
            }
        });
    }
}
