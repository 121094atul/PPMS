namespace PPMS.Application.Features.Vendors;

public interface IVendorRepository
{
    Task<long> SaveAsync(SaveVendorRequest request, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<VendorDto>> GetByPumpAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default);
    Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default);
}
