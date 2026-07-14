using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Threading;

namespace ClipboardSyncInputService;

internal static class WindowsServiceHost
{
    internal const string ServiceName = "ClipboardSyncInputService";

    private static readonly object StatusGate = new();
    private static readonly NativeMethods.ServiceMainFunction ServiceMainDelegate = ServiceMain;
    private static readonly NativeMethods.ServiceControlHandler ControlHandlerDelegate = HandleControl;
    private static readonly CancellationTokenSource Stopping = new();
    private static InputAgentSupervisor? supervisor;
    private static IntPtr statusHandle;
    private static uint checkPoint;
    private static int serviceExitCode;

    internal static int Run()
    {
        var table = new[]
        {
            new NativeMethods.ServiceTableEntry
            {
                ServiceName = ServiceName,
                ServiceMain = Marshal.GetFunctionPointerForDelegate(ServiceMainDelegate)
            },
            new NativeMethods.ServiceTableEntry()
        };

        if (!NativeMethods.StartServiceCtrlDispatcher(table))
        {
            var error = Marshal.GetLastWin32Error();
            ServiceLog.Write($"StartServiceCtrlDispatcher failed; win32={error}");
            return error;
        }
        return serviceExitCode;
    }

    private static void ServiceMain(int argumentCount, IntPtr arguments)
    {
        statusHandle = NativeMethods.RegisterServiceCtrlHandlerEx(
            ServiceName,
            ControlHandlerDelegate,
            IntPtr.Zero);
        if (statusHandle == IntPtr.Zero)
        {
            serviceExitCode = Marshal.GetLastWin32Error();
            ServiceLog.Write($"RegisterServiceCtrlHandlerEx failed; win32={serviceExitCode}");
            return;
        }

        try
        {
            ReportStatus(NativeMethods.ServiceStartPending, waitHint: 10_000);
            using var identity = WindowsIdentity.GetCurrent();
            if (!identity.IsSystem)
            {
                throw new InvalidOperationException(
                    $"Input service must run as LocalSystem; current identity is {identity.Name}.");
            }

            supervisor = new InputAgentSupervisor();
            ReportStatus(NativeMethods.ServiceRunning);
            ServiceLog.Write("service running as LocalSystem");
            supervisor.Run(Stopping.Token);
            ReportStatus(NativeMethods.ServiceStopped);
            ServiceLog.Write("service stopped cleanly");
        }
        catch (Exception ex)
        {
            serviceExitCode = 1;
            ServiceLog.Write($"fatal service error: {ex}");
            ReportStatus(
                NativeMethods.ServiceStopped,
                NativeMethods.ErrorServiceSpecificError,
                serviceSpecificExitCode: 1);
        }
    }

    private static uint HandleControl(uint control, uint eventType, IntPtr eventData, IntPtr context)
    {
        switch (control)
        {
            case NativeMethods.ServiceControlStop:
            case NativeMethods.ServiceControlShutdown:
                ServiceLog.Write($"service stop requested; control={control}");
                ReportStatus(NativeMethods.ServiceStopPending, waitHint: 10_000);
                Stopping.Cancel();
                supervisor?.Pulse();
                break;
            case NativeMethods.ServiceControlSessionChange:
                ServiceLog.Write($"session change received; eventType={eventType}");
                supervisor?.Pulse();
                break;
        }
        return 0;
    }

    private static void ReportStatus(
        uint state,
        uint win32ExitCode = 0,
        uint waitHint = 0,
        uint serviceSpecificExitCode = 0)
    {
        lock (StatusGate)
        {
            var pending = state == NativeMethods.ServiceStartPending || state == NativeMethods.ServiceStopPending;
            var status = new NativeMethods.ServiceStatus
            {
                ServiceType = NativeMethods.ServiceWin32OwnProcess,
                CurrentState = state,
                ControlsAccepted = state == NativeMethods.ServiceRunning
                    ? NativeMethods.ServiceAcceptStop |
                      NativeMethods.ServiceAcceptShutdown |
                      NativeMethods.ServiceAcceptSessionChange
                    : 0,
                Win32ExitCode = win32ExitCode,
                ServiceSpecificExitCode = serviceSpecificExitCode,
                CheckPoint = pending ? ++checkPoint : 0,
                WaitHint = waitHint
            };
            if (!NativeMethods.SetServiceStatus(statusHandle, ref status))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetServiceStatus failed.");
            }
        }
    }
}
