namespace PPMS.Domain.Entities;

public abstract class BaseEntity
{
    public long Id { get; set; }
    public long OwnerId { get; set; }
    public long PumpId { get; set; }
    public bool IsActive { get; set; } = true;
    public bool IsDeleted { get; set; }
    public DateTime CreatedOn { get; set; } = DateTime.Now;
    public long? CreatedBy { get; set; }
    public DateTime? UpdatedOn { get; set; }
    public long? UpdatedBy { get; set; }
}
