using Microsoft.Extensions.DependencyInjection;
using OpenTelemetry.Exporter;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

namespace Instrumentation;

public static class TelemetryServiceCollectionExtensions
{
    // Una configuracion comun para que gateway y backends exporten las mismas senales.
    public static IServiceCollection AddPharmaGoTelemetry(this IServiceCollection services, string serviceName)
    {
        var endpoint = new Uri(Environment.GetEnvironmentVariable("OTEL_EXPORTER_OTLP_ENDPOINT")
            ?? "http://otlp-collector:4317");
        var resource = ResourceBuilder.CreateDefault()
            .AddService(serviceName, serviceInstanceId: Environment.MachineName);

        services.AddHttpContextAccessor();
        services.AddTransient<CorrelationIdDelegatingHandler>();
        services.AddOpenTelemetry()
            .WithMetrics(metrics => metrics
                .SetResourceBuilder(resource)
                .AddAspNetCoreInstrumentation()
                .AddHttpClientInstrumentation()
                .AddMeter("PharmaGo.CustomMetrics")
                .AddPrometheusExporter()
                .AddOtlpExporter((options, reader) =>
                {
                    options.Endpoint = endpoint;
                    options.Protocol = OtlpExportProtocol.Grpc;
                    reader.PeriodicExportingMetricReaderOptions.ExportIntervalMilliseconds = 5000;
                }))
            .WithTracing(traces => traces
                .SetResourceBuilder(resource)
                .AddAspNetCoreInstrumentation(options => options.Filter = context =>
                    context.Request.Path != "/health" && context.Request.Path != "/metrics")
                .AddHttpClientInstrumentation()
                .AddOtlpExporter(options =>
                {
                    options.Endpoint = endpoint;
                    options.Protocol = OtlpExportProtocol.Grpc;
                }));

        return services;
    }
}
