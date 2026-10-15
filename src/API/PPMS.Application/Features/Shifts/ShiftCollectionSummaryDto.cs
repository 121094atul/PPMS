namespace PPMS.Application.Features.Shifts;

/// <summary>
/// Shift ka cash hisaab.
///
/// NOTE: ye DTO purane 6 fields (TotalCreditSales ... TotalBankDeposits) ke saath
/// hi shuru hota hai taaki client ka purana code na toote. Uske baad wale fields
/// naye cash reconciliation ke hain.
///
/// Dapper record ko constructor se banata hai aur SP ke saare columns ka match
/// maangta hai — isliye ye list PUMP.sp_Shift_Collection_Summary ke SELECT se
/// bilkul milni chahiye. (Pehle nahi milti thi: SP 3 column deta tha, DTO 6
/// maangta tha, aur ye endpoint hamesha 500 deta tha.)
/// </summary>
public sealed record ShiftCollectionSummaryDto(
    decimal TotalCreditSales,
    decimal TotalDigitalSales,
    decimal TotalUpiSales,
    decimal TotalCardSales,
    decimal TotalCashExpenses,
    decimal TotalBankDeposits,

    // ---- cash reconciliation ----
    long ShiftId,
    decimal OpeningCash,
    decimal TotalMeterSale,
    decimal TotalMeterQty,
    decimal CashSales,
    decimal PartyReceiptsCash,
    decimal CashIn,
    decimal CashOut,
    decimal ExpectedCash,
    decimal? ActualClosingCash,
    decimal CountedByDenomination,
    decimal ShortExcess,
    /// <summary>PENDING | OK | SHORT | EXCESS</summary>
    string CashStatus,
    decimal ToleranceRs,
    bool? DenominationMatch
);
