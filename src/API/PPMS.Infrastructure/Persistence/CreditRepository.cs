using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Interfaces;

namespace PPMS.Infrastructure.Persistence;

public sealed class CreditRepository(IOptions<DatabaseOptions> options) : ICreditRepository
{
    private readonly DatabaseOptions _options = options.Value;

    private SqlConnection Open() => new(_options.ConnectionString);

    // ---- platform ----

    public async Task<PlatformCreditSummary?> GetPlatformSummaryAsync(CancellationToken cancellationToken = default)
    {
        await using var c = Open();
        return await c.QueryFirstOrDefaultAsync<PlatformCreditSummary>(
            "PUMP.sp_PlatformCredit_Summary", commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<PlatformCreditSummary?> AddPlatformCreditAsync(AddPlatformCreditRequest request, long? userId, CancellationToken cancellationToken = default)
    {
        await using var c = Open();
        return await c.QueryFirstOrDefaultAsync<PlatformCreditSummary>(
            "PUMP.sp_PlatformCredit_Add",
            new
            {
                request.AmountPaid,
                request.CreditsBought,
                Provider = string.IsNullOrWhiteSpace(request.Provider) ? "Twilio" : request.Provider,
                request.ReferenceNo,
                request.Notes,
                UserId = userId
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<CreditSettings?> SaveSettingsAsync(string? upiId, string? upiName, decimal? pricePerCredit, CancellationToken cancellationToken = default)
    {
        await using var c = Open();
        return await c.QueryFirstOrDefaultAsync<CreditSettings>(
            "PUMP.sp_PlatformCredit_SaveSettings",
            new { UpiId = upiId, UpiName = upiName, PricePerCredit = pricePerCredit },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<IReadOnlyList<RechargeRequestDto>> ListRechargesAsync(long? ownerId, string? status, CancellationToken cancellationToken = default)
    {
        await using var c = Open();
        var rows = await c.QueryAsync<RechargeRequestDto>(
            "PUMP.sp_Wallet_RechargeList",
            new { OwnerId = ownerId, Status = status },
            commandType: System.Data.CommandType.StoredProcedure);
        return rows.AsList();
    }

    public async Task<ApproveRechargeResult?> ApproveRechargeAsync(long requestId, long? userId, string? note, CancellationToken cancellationToken = default)
    {
        await using var c = Open();
        return await c.QueryFirstOrDefaultAsync<ApproveRechargeResult>(
            "PUMP.sp_Wallet_ApproveRecharge",
            new { RequestId = requestId, UserId = userId, Note = note },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task RejectRechargeAsync(long requestId, long? userId, string? note, CancellationToken cancellationToken = default)
    {
        await using var c = Open();
        await c.ExecuteAsync(
            "PUMP.sp_Wallet_RejectRecharge",
            new { RequestId = requestId, UserId = userId, Note = note },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    // ---- owner ka wallet ----

    public async Task<WalletDto?> GetWalletAsync(long ownerId, CancellationToken cancellationToken = default)
    {
        await using var c = Open();
        return await c.QueryFirstOrDefaultAsync<WalletDto>(
            "PUMP.sp_Wallet_Get", new { OwnerId = ownerId },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<RequestRechargeResult?> RequestRechargeAsync(long ownerId, decimal amount, string? upiReference, CancellationToken cancellationToken = default)
    {
        await using var c = Open();
        return await c.QueryFirstOrDefaultAsync<RequestRechargeResult>(
            "PUMP.sp_Wallet_RequestRecharge",
            new { OwnerId = ownerId, Amount = amount, UpiReference = upiReference },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<IReadOnlyList<CreditLedgerDto>> GetLedgerAsync(long ownerId, int topCount, CancellationToken cancellationToken = default)
    {
        await using var c = Open();
        var rows = await c.QueryAsync<CreditLedgerDto>(
            "PUMP.sp_Wallet_Ledger", new { OwnerId = ownerId, TopCount = topCount },
            commandType: System.Data.CommandType.StoredProcedure);
        return rows.AsList();
    }

    public async Task<ConsumeResult?> ConsumeAsync(long ownerId, string? alertKey, CancellationToken cancellationToken = default)
    {
        await using var c = Open();
        return await c.QueryFirstOrDefaultAsync<ConsumeResult>(
            "PUMP.sp_Wallet_Consume", new { OwnerId = ownerId, AlertKey = alertKey },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<ConsumeResult?> RefundAsync(long ownerId, string? alertKey, CancellationToken cancellationToken = default)
    {
        await using var c = Open();
        return await c.QueryFirstOrDefaultAsync<ConsumeResult>(
            "PUMP.sp_Wallet_Refund", new { OwnerId = ownerId, AlertKey = alertKey },
            commandType: System.Data.CommandType.StoredProcedure);
    }
}
