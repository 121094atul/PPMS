namespace PPMS.Application.Features.Auth;

/// <summary>Superadmin kisi user ka password set kare — support call ke liye.</summary>
public sealed record ResetUserPasswordRequest(string NewPassword);
