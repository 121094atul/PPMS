namespace PPMS.Infrastructure.Persistence;

public sealed class DatabaseOptions
{
    public const string SectionName = "Database";
    public string ConnectionString { get; set; } = string.Empty;
    public long DefaultOwnerId { get; set; } = 1;
    public long DefaultPumpId { get; set; } = 1;
}
