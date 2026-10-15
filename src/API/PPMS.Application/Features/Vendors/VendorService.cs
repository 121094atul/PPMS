namespace PPMS.Application.Features.Vendors;

public sealed class VendorService(IVendorRepository repository) : IVendorService
{
    public Task<long> SaveAsync(SaveVendorRequest request, CancellationToken cancellationToken = default)
        => repository.SaveAsync(request, cancellationToken);

    public Task<IReadOnlyList<VendorDto>> GetByPumpAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default)
        => repository.GetByPumpAsync(ownerId, pumpId, cancellationToken);

    public Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default)
        => repository.DeleteAsync(id, ownerId, cancellationToken);
}
