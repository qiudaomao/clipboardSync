using System;

namespace ClipboardSyncWin;

/// <summary>
/// Hardcoded beta window: this build works for <see cref="DurationDays"/> days after
/// <see cref="ReleaseDateUtc"/>. Bump <see cref="ReleaseDateUtc"/> to today whenever a new build
/// is cut for release.
/// </summary>
internal static class BetaLicense
{
    private static readonly DateTime ReleaseDateUtc = new(2026, 7, 6, 0, 0, 0, DateTimeKind.Utc);
    private const int DurationDays = 30;

    public static DateTime ExpiryDateUtc => ReleaseDateUtc.AddDays(DurationDays);

    public static bool IsExpired => DateTime.UtcNow >= ExpiryDateUtc;
}
