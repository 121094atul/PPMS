namespace PPMS.Application.Features.Owners;

public sealed record SaveOwnerRequest(
    string Name,
    string AdminUsername,
    string AdminPassword
);
