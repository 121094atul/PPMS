using PPMS.Application.Features.Auth;

namespace PPMS.Application.Features.Staff;

public sealed class StaffService(IStaffRepository repository, IPasswordHasher passwordHasher) : IStaffService
{
    /// <summary>Client edit ke waqt password khaali chhode to ye placeholder bhejta hai.</summary>
    private const string UnchangedPassword = "***UNCHANGED***";

    public Task<IReadOnlyList<StaffDto>> GetByPumpAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default)
        => repository.GetByPumpAsync(ownerId, pumpId, cancellationToken);

    public Task<SaveStaffResult> SaveAsync(SaveStaffRequest request, CancellationToken cancellationToken = default)
    {
        // Hashing yahin hoti hai — plaintext password kabhi DB tak nahi jaata.
        // Placeholder ko chhedte nahi; sp_User_Save use dekh kar purana hash
        // waisa hi rehne deta hai (Section L1).
        if (!request.WantsLogin || string.IsNullOrEmpty(request.Password) || request.Password == UnchangedPassword)
        {
            return repository.SaveAsync(request, cancellationToken);
        }

        var hashed = request with { Password = passwordHasher.HashPassword(request.Password) };
        return repository.SaveAsync(hashed, cancellationToken);
    }
}
