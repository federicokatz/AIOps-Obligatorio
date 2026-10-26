using Instrumentation;
using Microsoft.Extensions.DependencyInjection;

namespace PharmaGo.PharmacyService.Factory
{
    public static class OpenTelemetryExtensions
    {
        public static IServiceCollection AddPharmaGoOpenTelemetryMetrics(this IServiceCollection services, string serviceName = "PharmaGo.PharmacyService")
            => services.AddPharmaGoTelemetry(serviceName);
    }
}
