using System;

namespace ClipboardSyncInputService;

internal static class Program
{
    private static int Main(string[] args)
    {
        if (args.Length == 1 && string.Equals(args[0], "--service", StringComparison.Ordinal))
        {
            ServiceLog.Initialize("input-service.log");
            return WindowsServiceHost.Run();
        }

        if (args.Length > 0 && string.Equals(args[0], "--agent", StringComparison.Ordinal))
        {
            var options = InputAgentOptions.Parse(args.AsSpan(1));
            ServiceLog.Initialize($"input-agent-session-{options.SessionId}.log");
            return InputAgent.Run(options);
        }

        ServiceLog.Initialize("input-service-launch-errors.log");
        ServiceLog.Write("invalid launch: expected --service or --agent with service-supplied options");
        return 2;
    }
}
