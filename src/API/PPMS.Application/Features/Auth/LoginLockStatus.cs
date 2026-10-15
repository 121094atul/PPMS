namespace PPMS.Application.Features.Auth;

public sealed record LoginLockStatus(bool IsLocked, int FailedAttempts, int UnlocksInMinutes);
