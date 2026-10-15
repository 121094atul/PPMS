namespace PPMS.Application.Features.Staff;

public interface IStaffRepository
{
    Task<IReadOnlyList<StaffDto>> GetByPumpAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default);

    Task<SaveStaffResult> SaveAsync(SaveStaffRequest request, CancellationToken cancellationToken = default);
}
