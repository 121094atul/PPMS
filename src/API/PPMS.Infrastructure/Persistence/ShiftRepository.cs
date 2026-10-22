using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.Shifts;
using System.Text.Json;

namespace PPMS.Infrastructure.Persistence;

public sealed class ShiftRepository(IOptions<DatabaseOptions> options) : IShiftRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<long> OpenAsync(OpenShiftRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.ExecuteScalarAsync<long>(
            sql: "PUMP.sp_Shift_Open",
            param: new
            {
                request.OwnerId,
                request.PumpId,
                request.OperatorUserId,
                request.OperatorEmployeeId,
                ShiftDate = request.ShiftDate.ToDateTime(TimeOnly.MinValue),
                request.ShiftCode,
                request.OpeningCash,
                request.Notes,
                NozzleReadingsJson = JsonSerializer.Serialize(request.NozzleReadings ?? Array.Empty<ShiftNozzleOpenReadingRequest>()),
                request.AllowMeterGap
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    /// <summary>
    /// Meter ki tooti hui kadi — jahan kisi shift ka opening pichli shift ke
    /// closing se nahi milta. Rokta kuch nahi, sirf batata hai (Section R2).
    /// </summary>
    public async Task<IReadOnlyList<MeterChainGapDto>> GetMeterChainGapsAsync(long ownerId, long? pumpId, int days, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<MeterChainGapDto>(
            sql: "PUMP.sp_Shift_MeterChainCheck",
            param: new { OwnerId = ownerId, PumpId = pumpId, Days = days },
            commandType: System.Data.CommandType.StoredProcedure);
        return rows.AsList();
    }

    /// <summary>
    /// Ek shift ka collection padho — Online, Card aur udhaar ki list (Section W).
    /// SP do result-set deta hai, isliye QueryMultiple.
    /// </summary>
    public async Task<ShiftCollectionDto> GetCollectionAsync(long shiftId, long ownerId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        using var multi = await connection.QueryMultipleAsync(
            sql: "PUMP.sp_ShiftCollection_Get",
            param: new { ShiftId = shiftId, OwnerId = ownerId },
            commandType: System.Data.CommandType.StoredProcedure);

        var totals = await multi.ReadFirstOrDefaultAsync<ShiftCollectionTotalsRow>();

        // Udhaar ki line naam se padhte hain, record se nahi. Section AK ne SP me
        // VehicleNo / SlipNote jode — record (CLAUDE.md niyam 5) purane 3-column SP
        // par toot jaata. Ab ye API naye aur purane dono SP ke saath chalti hai, to
        // live par pehle build daalo, phir SQL — beech me Collection page band nahi hota.
        var credits = (await multi.ReadAsync())
            .Cast<IDictionary<string, object?>>()
            .Select(r => new ShiftCollectionCreditLine(
                Convert.ToInt64(r["PartyId"]),
                r["PartyName"] as string,
                Convert.ToDecimal(r["Amount"]),
                r.TryGetValue("VehicleNo", out var vehicle) ? vehicle as string : null,
                r.TryGetValue("SlipNote", out var note) ? note as string : null))
            .ToList();

        return new ShiftCollectionDto(
            totals?.UpiAmount ?? 0,
            totals?.CardAmount ?? 0,
            credits);
    }

    public async Task SaveCollectionAsync(SaveShiftCollectionRequest request, long ownerId, long? userId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_ShiftCollection_Save",
            param: new
            {
                request.ShiftId,
                OwnerId = ownerId,
                request.UpiAmount,
                request.CardAmount,
                // SP OPENJSON se padhta hai. Kram wahi rehta hai jo user ne likha —
                // parchi ka BillNo usi kram se banta hai (Section AK).
                CreditJson = JsonSerializer.Serialize(
                    (request.Credits ?? Array.Empty<ShiftCollectionCreditLine>())
                        .Where(c => c.PartyId > 0 && c.Amount > 0)
                        .Select(c => new { c.PartyId, c.Amount, c.VehicleNo, c.SlipNote })),
                UserId = userId
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<long> CloseAsync(CloseShiftRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.ExecuteScalarAsync<long>(
            sql: "PUMP.sp_Shift_Close",
            param: new
            {
                request.Id,
                request.ClosingCash,
                request.Notes,
                NozzleReadingsJson = JsonSerializer.Serialize(request.NozzleReadings ?? Array.Empty<ShiftNozzleCloseReadingRequest>())
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<IReadOnlyList<ShiftNozzleReadingDto>> GetNozzleReadingsAsync(long shiftId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<ShiftNozzleReadingDto>(
            sql: "PUMP.sp_Shift_NozzleReadings",
            param: new { ShiftId = shiftId },
            commandType: System.Data.CommandType.StoredProcedure);
        return rows.AsList();
    }

    public async Task<IReadOnlyList<ShiftDto>> GetAllAsync(long ownerId, long? pumpId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<ShiftRow>(
            sql: "PUMP.sp_Shift_List",
            param: new
            {
                OwnerId = ownerId,
                PumpId = pumpId
            },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.Select(x => new ShiftDto(
                x.Id,
                x.OwnerId,
                x.PumpId,
                x.OperatorUserId,
                x.OperatorEmployeeId,
                x.OperatorName,
                DateOnly.FromDateTime(x.ShiftDate),
                x.ShiftCode,
                x.OpeningCash,
                x.ClosingCash,
                x.TotalSoldQty,
                x.TotalSoldAmount,
                x.Notes,
                x.OpenedOn,
                x.ClosedOn,
                x.Status,
                x.ShiftNo))
            .ToList();
    }

    public async Task<PPMS.Shared.Models.PagedResponse<ShiftDto>> GetPagedListAsync(long ownerId, long? pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);

        using var multi = await connection.QueryMultipleAsync(
            sql: "PUMP.sp_Shift_List",
            param: new
            {
                OwnerId = ownerId,
                PumpId = pumpId,
                FromDate = fromDate,
                ToDate = toDate,
                SearchTerm = searchTerm,
                PageNumber = pageNumber,
                PageSize = pageSize
            },
            commandType: System.Data.CommandType.StoredProcedure);

        var rows = await multi.ReadAsync<ShiftRow>();
        var totalCount = await multi.ReadSingleAsync<int>();

        var items = rows.Select(x => new ShiftDto(
                x.Id,
                x.OwnerId,
                x.PumpId,
                x.OperatorUserId,
                x.OperatorEmployeeId,
                x.OperatorName,
                DateOnly.FromDateTime(x.ShiftDate),
                x.ShiftCode,
                x.OpeningCash,
                x.ClosingCash,
                x.TotalSoldQty,
                x.TotalSoldAmount,
                x.Notes,
                x.OpenedOn,
                x.ClosedOn,
                x.Status,
                x.ShiftNo))
            .ToList();

        return new PPMS.Shared.Models.PagedResponse<ShiftDto>(items, totalCount, pageNumber, pageSize);
    }

    private sealed record ShiftRow(
        long Id,
        long OwnerId,
        long PumpId,
        long? OperatorUserId,
        long? OperatorEmployeeId,
        string? OperatorName,
        DateTime ShiftDate,
        string ShiftCode,
        decimal OpeningCash,
        decimal? ClosingCash,
        decimal TotalSoldQty,
        decimal TotalSoldAmount,
        string? Notes,
        DateTime OpenedOn,
        DateTime? ClosedOn,
        string Status,
        // Section X: pump + din ke hisaab se shift ka number. SP isse aakhir me
        // deti hai, isliye yahan bhi aakhir me.
        int ShiftNo);
    public async Task<ShiftCollectionSummaryDto> GetCollectionSummaryAsync(long shiftId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var result = await connection.QueryFirstOrDefaultAsync<ShiftCollectionSummaryDto>(
            sql: "PUMP.sp_Shift_Collection_Summary",
            param: new { ShiftId = shiftId },
            commandType: System.Data.CommandType.StoredProcedure);

        // Shift na mile to khaali summary — sab zero, status PENDING.
        return result ?? new ShiftCollectionSummaryDto(
            TotalCreditSales: 0, TotalDigitalSales: 0, TotalUpiSales: 0,
            TotalCardSales: 0, TotalCashExpenses: 0, TotalBankDeposits: 0,
            ShiftId: shiftId, OpeningCash: 0, TotalMeterSale: 0, TotalMeterQty: 0,
            CashSales: 0, PartyReceiptsCash: 0, CashIn: 0, CashOut: 0,
            ExpectedCash: 0, ActualClosingCash: null, CountedByDenomination: 0,
            ShortExcess: 0, CashStatus: "PENDING", ToleranceRs: 0, DenominationMatch: null);
    }

    /// <summary>Returns the last closed shift's closing reading per nozzle for a pump — used to pre-fill Open Shift form.</summary>
    public async Task<IReadOnlyList<ShiftNozzleReadingDto>> GetLastNozzleReadingsAsync(long pumpId, DateOnly? beforeDate = null, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        const string sql = """
            SELECT
                snr.NozzleId,
                n.NozzleCode,
                p.Name      AS ProductName,
                snr.OpeningReading,
                snr.ClosingReading,
                ISNULL(snr.TestingLoss, 0) AS TestingLoss,
                snr.Rate,
                snr.SoldQty,
                snr.SoldAmount
            FROM PUMP.ShiftNozzleReadings snr
            INNER JOIN PUMP.ShiftHeaders sh
                ON sh.Id = snr.ShiftId
               AND sh.PumpId = @PumpId
               AND sh.Status = 'CLOSED'
            INNER JOIN PUMP.Nozzles n   ON n.Id = snr.NozzleId
            INNER JOIN PUMP.Products p  ON p.Id = snr.ProductId
            WHERE sh.Id =
            (
                -- Pehle yahan `ORDER BY ClosedOn DESC` tha, yaani jo shift GHADI ke
                -- hisaab se sabse baad me band hui. Kram se din bharo to wo theek
                -- tha, par beech ka chhoota din baad me bharne par galat shift utha
                -- laata tha: 09 aur 10 bhar chuke ho aur ab 08 bhar rahe ho, to
                -- opening reading 10 waali aa jaati thi. Ab TAREEKH se chunte hain.
                SELECT TOP 1 Id
                FROM PUMP.ShiftHeaders
                WHERE PumpId = @PumpId AND Status = 'CLOSED'
                  AND (@BeforeDate IS NULL OR ShiftDate <= @BeforeDate)
                ORDER BY ShiftDate DESC, ClosedOn DESC, Id DESC
            )
            ORDER BY n.NozzleCode;
            """;
        var rows = await connection.QueryAsync<ShiftNozzleReadingDto>(
            sql,
            new { PumpId = pumpId, BeforeDate = beforeDate?.ToDateTime(TimeOnly.MinValue) });
        return rows.AsList();
    }

    // ── Support console (Section Z) — sirf Super Admin ke liye ──────────────
    //
    // Ye teen cheezein ab tak SIRF SQL se ho paati thi. Har baar developer ko
    // database me ghusna padta tha, isliye ab SP ke roop me hain.

    public async Task<IReadOnlyList<SupportShiftDto>> GetSupportShiftsAsync(long ownerId, long? pumpId, int days, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<SupportShiftDto>(
            sql: "PUMP.sp_Support_ShiftList",
            param: new { OwnerId = ownerId, PumpId = pumpId, Days = days },
            commandType: System.Data.CommandType.StoredProcedure);
        return rows.AsList();
    }

    public async Task<bool> ReopenShiftAsync(long shiftId, long ownerId, long? userId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.ExecuteScalarAsync<bool>(
            sql: "PUMP.sp_Shift_Reopen",
            param: new { ShiftId = shiftId, OwnerId = ownerId, UserId = userId },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<bool> DeleteShiftAsync(long shiftId, long ownerId, long? userId, string? reason, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.ExecuteScalarAsync<bool>(
            sql: "PUMP.sp_Shift_Delete",
            param: new { ShiftId = shiftId, OwnerId = ownerId, UserId = userId, Reason = reason },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<IReadOnlyList<ShiftClosingDipRow>> GetClosingDipsAsync(long shiftId, long ownerId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<ShiftClosingDipRow>(
            sql: "PUMP.sp_Shift_ClosingDipList",
            param: new { ShiftId = shiftId, OwnerId = ownerId },
            commandType: System.Data.CommandType.StoredProcedure);
        return rows.AsList();
    }

    public async Task<IReadOnlyList<ShiftClosingDipSaved>> SaveClosingDipsAsync(long shiftId, long ownerId, long? userId, IReadOnlyList<ShiftClosingDipInput> dips, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<ShiftClosingDipSaved>(
            sql: "PUMP.sp_Shift_SaveClosingDips",
            param: new { ShiftId = shiftId, OwnerId = ownerId, UserId = userId, DipsJson = JsonSerializer.Serialize(dips) },
            commandType: System.Data.CommandType.StoredProcedure);
        return rows.AsList();
    }

    public async Task<decimal> SaveCashDenominationAsync(long shiftId, SaveShiftCashDenominationRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.ExecuteScalarAsync<decimal>(
            sql: "PUMP.sp_ShiftCashDenomination_Save",
            param: new
            {
                request.OwnerId,
                request.PumpId,
                ShiftId = shiftId,
                Json = JsonSerializer.Serialize(request.Lines)
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }
}

