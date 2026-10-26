using Instrumentation;
using Microsoft.Extensions.DependencyInjection;

namespace PharmaGo.UsersService.Factory
{
    public static class OpenTelemetryExtensions
    {
        public static IServiceCollection AddPharmaGoOpenTelemetryMetrics(this IServiceCollection services, string serviceName = "PharmaGo.UsersService")
            => services.AddPharmaGoTelemetry(serviceName);
    }
}
