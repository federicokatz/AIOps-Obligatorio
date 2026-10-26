using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using Instrumentation;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace PharmaGo.Test.Instrumentation.Test;

[TestClass]
public class TelemetryCorrelationTests
{
    [TestMethod]
    public async Task Gateway_PreservesCorrelationAndLogsW3cContext()
    {
        using var provider = new CaptureProvider();
        using var services = new ServiceCollection().AddLogging(b => b.AddProvider(provider)).BuildServiceProvider();
        var app = new ApplicationBuilder(services);
        app.UseGatewayCorrelationId();
        app.Run(c => { c.Response.StatusCode = 204; return Task.CompletedTask; });
        var context = new DefaultHttpContext { RequestServices = services };
        context.Request.Path = "/test";
        context.Request.Headers["X-Correlation-ID"] = "existing-id";
        using var activity = new Activity("request").SetIdFormat(ActivityIdFormat.W3C)
            .SetParentId("00-11111111111111111111111111111111-2222222222222222-01").Start();

        await app.Build()(context);

        Assert.AreEqual("existing-id", context.Response.Headers["X-Correlation-ID"].ToString());
        var entry = provider.Entries.Single();
        Assert.AreEqual("existing-id", entry["correlation_id"]);
        Assert.AreEqual(activity.TraceId.ToHexString(), entry["trace_id"]);
        Assert.AreEqual(activity.SpanId.ToHexString(), entry["span_id"]);
        Assert.AreEqual(204, entry["status_code"]);
    }

    [TestMethod]
    public async Task Gateway_GeneratesIdWhenMissing()
    {
        using var services = new ServiceCollection().AddLogging().BuildServiceProvider();
        var app = new ApplicationBuilder(services);
        app.UseGatewayCorrelationId();
        app.Run(_ => Task.CompletedTask);
        var context = new DefaultHttpContext { RequestServices = services };

        await app.Build()(context);

        var id = context.Response.Headers["X-Correlation-ID"].ToString();
        Assert.IsTrue(Guid.TryParse(id, out _));
        Assert.AreEqual(id, context.Items[CorrelationIdMiddlewareExtensions.HttpContextItemKey]);
    }

    [TestMethod]
    public async Task Service_LogsFailureWithoutSwallowingException()
    {
        using var provider = new CaptureProvider();
        using var services = new ServiceCollection().AddLogging(b => b.AddProvider(provider)).BuildServiceProvider();
        var app = new ApplicationBuilder(services);
        app.UseServiceCorrelationScope();
        app.Run(_ => throw new InvalidOperationException("test failure"));
        var context = new DefaultHttpContext { RequestServices = services };
        context.Request.Path = "/test";
        context.Request.Headers["X-Correlation-ID"] = "failed-request";

        await Assert.ThrowsExceptionAsync<InvalidOperationException>(() => app.Build()(context));

        var entry = provider.Entries.Single();
        Assert.AreEqual("failed-request", entry["correlation_id"]);
        Assert.AreEqual(500, entry["status_code"]);
        Assert.AreEqual(200, context.Response.StatusCode); // El middleware no modifica la respuesta del negocio.
    }

    [TestMethod]
    public async Task OutgoingRequests_DoNotShareCorrelationBetweenConcurrentCalls()
    {
        var accessor = new HttpContextAccessor();
        using var client = new HttpClient(new CorrelationIdDelegatingHandler(accessor) { InnerHandler = new EchoHandler() });
        async Task<string> Send(string id)
        {
            accessor.HttpContext = new DefaultHttpContext();
            accessor.HttpContext.Items[CorrelationIdMiddlewareExtensions.HttpContextItemKey] = id;
            try
            {
                using var response = await client.GetAsync("http://test/");
                return response.Headers.GetValues("Observed-Correlation").Single();
            }
            finally { accessor.HttpContext = null; }
        }

        var results = await Task.WhenAll(Task.Run(() => Send("first")), Task.Run(() => Send("second")));

        CollectionAssert.AreEqual(new[] { "first", "second" }, results);
        Assert.IsFalse(client.DefaultRequestHeaders.Contains("X-Correlation-ID"));
    }

    [TestMethod]
    public async Task OutgoingRequest_WithoutHttpContextDoesNotInventId()
    {
        using var client = new HttpClient(new CorrelationIdDelegatingHandler(new HttpContextAccessor()) { InnerHandler = new EchoHandler() });
        using var response = await client.GetAsync("http://test/");
        Assert.AreEqual("none", response.Headers.GetValues("Observed-Correlation").Single());
    }

    private sealed class EchoHandler : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            await Task.Yield();
            var response = new HttpResponseMessage(HttpStatusCode.OK);
            response.Headers.Add("Observed-Correlation", request.Headers.TryGetValues("X-Correlation-ID", out var values) ? values.Single() : "none");
            return response;
        }
    }

    private sealed class CaptureProvider : ILoggerProvider, ISupportExternalScope
    {
        public readonly ConcurrentQueue<Dictionary<string, object?>> Entries = new();
        private IExternalScopeProvider _scopes = new LoggerExternalScopeProvider();
        public void SetScopeProvider(IExternalScopeProvider scopeProvider) => _scopes = scopeProvider;
        public ILogger CreateLogger(string categoryName) => new CaptureLogger(this);
        public void Dispose() { }

        private sealed class CaptureLogger : ILogger
        {
            private readonly CaptureProvider _owner;
            public CaptureLogger(CaptureProvider owner) => _owner = owner;
            public IDisposable BeginScope<TState>(TState state) => null!;
            public bool IsEnabled(LogLevel logLevel) => true;
            public void Log<TState>(LogLevel level, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
            {
                var fields = new Dictionary<string, object?>();
                _owner._scopes.ForEachScope((scope, output) =>
                {
                    if (scope is IEnumerable<KeyValuePair<string, object?>> pairs)
                        foreach (var pair in pairs) output[pair.Key] = pair.Value;
                }, fields);
                if (state is IEnumerable<KeyValuePair<string, object?>> values)
                    foreach (var pair in values) fields[pair.Key] = pair.Value;
                _owner.Entries.Enqueue(fields);
            }
        }
    }
}
