namespace PPMS.Application.Features.DayBookReport;

public sealed record DayBookEntryDto(
    DateTime EntryDateTime,
    string EntryType,
    string? ReferenceNo,
    string Description,
    decimal Debit,
    decimal Credit
);

public interface IDayBookReportRepository
{
    Task<IReadOnlyList<DayBookEntryDto>> GetAsync(long ownerId, long pumpId, DateOnly dateFrom, DateOnly dateTo, CancellationToken cancellationToken = default);
}

public interface IDayBookReportService
{
    Task<IReadOnlyList<DayBookEntryDto>> GetAsync(long ownerId, long pumpId, DateOnly dateFrom, DateOnly dateTo, CancellationToken cancellationToken = default);
}

public sealed class DayBookReportService(IDayBookReportRepository repository) : IDayBookReportService
{
    public Task<IReadOnlyList<DayBookEntryDto>> GetAsync(long ownerId, long pumpId, DateOnly dateFrom, DateOnly dateTo, CancellationToken cancellationToken = default)
        => repository.GetAsync(ownerId, pumpId, dateFrom, dateTo, cancellationToken);
}
