using System.Data;
using Dapper;

namespace PPMS.Infrastructure.Persistence;

/// <summary>
/// Dapper DateOnly TypeHandler — SQL date/datetime ko DateOnly mein map karta hai.
/// </summary>
public sealed class DateOnlyTypeHandler : SqlMapper.TypeHandler<DateOnly>
{
    public static readonly DateOnlyTypeHandler Instance = new();

    public override DateOnly Parse(object value)
    {
        return value switch
        {
            DateTime dt => DateOnly.FromDateTime(dt),
            DateOnly d  => d,
            string s    => DateOnly.Parse(s),
            _           => DateOnly.MinValue
        };
    }

    public override void SetValue(IDbDataParameter parameter, DateOnly value)
    {
        parameter.DbType    = DbType.Date;
        parameter.Value     = value.ToDateTime(TimeOnly.MinValue);
    }
}
