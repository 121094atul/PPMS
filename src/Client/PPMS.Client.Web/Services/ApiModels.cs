namespace PPMS.Client.Web.Services;

public sealed record ApiLoginRequest(string Username, string Password);

public sealed record ApiLoginResponse(
    long UserId,
    long OwnerId,
    string FullName,
    string Username,
    long RoleId,
    string RoleName,
    string Token,
    DateTime AccessTokenExpiresOnUtc,
    string RefreshToken,
    DateTime RefreshTokenExpiresOnUtc,
    bool IsSuperAdmin
);

public sealed record ApiLoginAttemptResult(
    bool IsSuccess,
    ApiLoginResponse? Data,
    string? ErrorMessage,
    /// <summary>API ka `error` code — TRIAL_EXPIRED / OWNER_SUSPENDED / ACCOUNT_LOCKED.
    /// Sandesh isi se banta hai, API ke English text se nahi.</summary>
    string? ErrorCode = null,
    int? LockMinutes = null
);

public sealed record ApiRefreshTokenRequest(string RefreshToken);
public sealed record ApiLogoutRequest(string RefreshToken);

public sealed record ApiMenuItem(
    long Id,
    long? ParentId,
    string MenuName,
    string Route,
    string? Icon,
    int Sequence,
    bool CanView,
    bool CanCreate,
    bool CanEdit,
    bool CanDelete
);

public sealed record MenuGroup(string GroupName, IReadOnlyList<ApiMenuItem> Items);

/// <summary>Munafa report ki line (Section AO1): SALE / EXPENSE / SALARY. CostSource: PERIOD / LAST / NONE.</summary>
public sealed record ApiProfitLossLineDto(
    string Section,
    int SortOrder,
    long? ItemId,
    string Name,
    string? Unit,
    decimal Qty,
    decimal Amount,
    decimal? CostRate,
    decimal? CostAmount,
    string CostSource
);

/// <summary>Financials ki line (Section AP): POSITION / FLOW (Name = code), STOCK, RECEIVABLE_TOP.</summary>
public sealed record ApiFinancialLineDto(
    string Section,
    int SortOrder,
    string Name,
    decimal? Qty,
    decimal? Rate,
    decimal Amount,
    string? Note
);

/// <summary>Activity Log ki line (Section AO2).</summary>
public sealed record ApiAuditLogEntryDto(
    long Id,
    DateTime CreatedOn,
    long? PumpId,
    string? UserName,
    string EntityName,
    long? EntityId,
    string Action,
    string? Reason,
    string? OldValues,
    string? NewValues,
    string? Detail,
    string Area,
    int TotalCount
);

public sealed record ApiPagedResponse<T>(
    IReadOnlyList<T> Items,
    int TotalCount,
    int PageNumber,
    int PageSize
)
{
    public int TotalPages => PageSize <= 0 ? 0 : (int)Math.Ceiling((double)TotalCount / PageSize);
    public bool HasPreviousPage => PageNumber > 1;
    public bool HasNextPage => PageNumber < TotalPages;
}

public sealed record ApiShiftDto(
    long Id,
    long OwnerId,
    long PumpId,
    long? OperatorUserId,
    // Shift ka in-charge — ab Employees se (Section K).
    long? OperatorEmployeeId,
    string? OperatorName,
    DateOnly ShiftDate,
    string ShiftCode,
    decimal OpeningCash,
    decimal? ClosingCash,
    decimal TotalSoldQty,
    decimal TotalSoldAmount,
    string? Notes,
    DateTime OpenedOn,
    DateTime? ClosedOn,
    string Status,
    // Pump + din ke hisaab se shift ka number (1, 2, 3). Screen par yahi dikhta hai.
    int ShiftNo,
    // Section AN: asli short / excess aur shift band par apne aap malik ko gaya nakad. Purani API se null.
    decimal? CashShortExcess = null,
    decimal? CashToOwner = null
);

public sealed record ApiShiftCollectionSummaryDto(
    decimal TotalCreditSales,
    decimal TotalDigitalSales,
    decimal TotalUpiSales,
    decimal TotalCardSales,
    decimal TotalCashExpenses,
    decimal TotalBankDeposits,
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
    string CashStatus,
    decimal ToleranceRs,
    bool? DenominationMatch
);

public sealed record ApiCashDenominationLine(int Denomination, int Pieces);

public sealed record ApiSaveCashDenominationRequest(
    long OwnerId,
    long PumpId,
    IReadOnlyList<ApiCashDenominationLine> Lines
);

public sealed record ApiShiftNozzleOpenReading(
    long NozzleId,
    long ProductId,
    decimal OpeningReading,
    // Shift shuru hote waqt hi: kaun aadmi hai aur kitna chhutta diya.
    long? EmployeeId = null,
    decimal? FloatGiven = null
);

public sealed record ApiShiftNozzleCloseReading(
    long NozzleId,
    decimal ClosingReading,
    decimal TestingLoss
);

public sealed record ApiShiftNozzleReadingDto(
    long NozzleId,
    string NozzleCode,
    string ProductName,
    decimal OpeningReading,
    decimal? ClosingReading,
    decimal TestingLoss,
    decimal Rate,
    decimal SoldQty,
    decimal SoldAmount
);

public sealed record ApiOpenShiftRequest(
    long OwnerId,
    long PumpId,
    // ShiftHeaders.OperatorUserId DB me nullable hai. Naye pump par koi employee
    // hota hi nahi, isliye 0 bhejne par FK toot jaati thi (500) aur pehli shift
    // khulti hi nahi thi. Ab NULL bhejte hain.
    long? OperatorUserId,
    DateOnly ShiftDate,
    string ShiftCode,
    decimal OpeningCash,
    string? Notes,
    IReadOnlyList<ApiShiftNozzleOpenReading> NozzleReadings,
    // In-charge employee. Sabse aakhir me hai kyunki iska default hai.
    long? OperatorEmployeeId = null,
    // Meter ki kadi na jude to API rok deti hai (Section R). User ne "meter badla
    // hai" tick kiya ho to ye true jaata hai aur rok hat jaati hai.
    bool AllowMeterGap = false
);

/// <summary>
/// Meter ki tooti hui kadi — ek shift ka opening pichli shift ke closing se
/// nahi milta (Section R2).
/// </summary>
public sealed record ApiMeterChainGap(
    long NozzleId,
    string NozzleCode,
    long PumpId,
    long PrevShiftId,
    DateOnly PrevDate,
    decimal PrevClosing,
    long ShiftId,
    DateOnly ShiftDate,
    string ShiftCode,
    decimal OpeningReading,
    decimal GapQty
);

public sealed record ApiCloseShiftRequest(
    long Id,
    decimal ClosingCash,
    string? Notes,
    IReadOnlyList<ApiShiftNozzleCloseReading> NozzleReadings
);

public sealed record ApiPumpDto(
    long Id,
    string Name,
    string? City,
    string? Address,
    string? ContactNo,
    string? GSTIN
);

public sealed record ApiSavePumpRequest(
    long? Id,
    long OwnerId,
    string Name,
    string? City,
    string? Address,
    string? ContactNo,
    string? GSTIN
);

public sealed record ApiProductDto(
    long Id,
    long PumpId,
    string Name,
    string Category,
    string Unit,
    decimal CurrentRate,
    string? HSNCode,
    decimal CGSTRate,
    decimal SGSTRate
);

public sealed record ApiDailyRateDto(
    long Id,
    long PumpId,
    string PumpName,
    string Name,
    string Category,
    string Unit,
    decimal CurrentRate,
    decimal? PreviousRate,
    DateTime? LastChangedOn
);

public sealed record ApiProductRateLine(long ProductId, decimal NewRate);

public sealed record ApiUpdateDailyRatesRequest(
    long OwnerId,
    IReadOnlyList<ApiProductRateLine> Rates
);

public sealed record ApiProductRateHistoryDto(
    long Id,
    long ProductId,
    decimal OldRate,
    decimal NewRate,
    DateTime ChangedAt,
    long? ChangedBy
);

public sealed record ApiNozzleDto(
    long Id,
    long OwnerId,
    long PumpId,
    long ProductId,
    string ProductName,
    string NozzleCode,
    long? TankId,
    bool IsActive
);

public sealed record ApiTankDto(
    long Id,
    long PumpId,
    string Name,
    long ProductId,
    string ProductName,
    string Unit,
    decimal Capacity,
    decimal SafeFillLevel,
    decimal CurrentStock,
    bool IsActive
);

public sealed record ApiSaveTankRequest(
    long Id,
    long OwnerId,
    long PumpId,
    string Name,
    long ProductId,
    decimal Capacity,
    decimal SafeFillLevel,
    decimal CurrentStock,
    bool IsActive
);

public sealed record ApiPartyDto(
    long Id,
    long PumpId,
    string PartyName,
    string PartyType,
    string Address,
    string Mobile,
    string Email,
    string GSTIN,
    decimal CreditLimit,
    decimal CurrentBalance,
    bool IsActive
);

public sealed record ApiSavePartyRequest(
    long Id,
    long OwnerId,
    long PumpId,
    string PartyName,
    string PartyType,
    string Address,
    string Mobile,
    string Email,
    string GSTIN,
    decimal CreditLimit,
    decimal CurrentBalance,
    bool IsActive,
    // Edit me baki ka khaana chhua nahi gaya -> true; server baki ko haath nahi lagata.
    bool KeepBalance = false
);

// /api/party-ledger/statement — ek party ka khaata, purane baki ke saath.
//   OpeningBalance + TotalDebit - TotalCredit = LedgerBalance  (= CurrentBalance hona chahiye)
// OpeningBalance = jo baki OpeningAsOf ko haath se bhara gaya tha. Us se pehle ki
// EarlierCount line usi me shaamil hain (list me nahi aati, dobara nahi judti).
public sealed record ApiPartyStatementHeaderDto(
    long PartyId,
    string PartyName,
    decimal OpeningBalance,
    decimal TotalDebit,
    decimal TotalCredit,
    decimal CurrentBalance,
    decimal LedgerBalance,
    int TotalCount,
    DateTime? OpeningAsOf = null,
    int EarlierCount = 0,
    decimal EarlierNet = 0
);

// SignedAmount: + = baki badha (udhaar), - = baki ghata (jama).
// RunningBalance: is line ke BAAD ka baki.
public sealed record ApiPartyStatementLineDto(
    long Id,
    DateTime EntryDateTime,
    string EntryType,
    decimal Amount,
    string? ReferenceNo,
    string? Notes,
    string? PaymentMode,
    decimal SignedAmount,
    decimal RunningBalance,
    // Haath se bani entry (Party Ledger form) — sirf isi par "badlein / hatayein".
    bool CanEdit = false
);

// PUT /api/party-ledger/{id} — haath se bani entry sudharna. Reason zaroori (AuditLog).
public sealed record ApiUpdatePartyLedgerEntryRequest(
    long PumpId,
    string EntryType,
    decimal Amount,
    DateTime? EntryDateTime,
    string? ReferenceNo,
    string? Notes,
    string? Reason
);

public sealed record ApiPartyStatementDto(
    ApiPartyStatementHeaderDto Header,
    IReadOnlyList<ApiPartyStatementLineDto> Lines,
    int PageNumber,
    int PageSize
)
{
    public int TotalPages => PageSize <= 0 ? 1 : Math.Max(1, (int)Math.Ceiling(Header.TotalCount / (double)PageSize));
}

public sealed record ApiTankTransactionDto(
    long Id,
    long OwnerId,
    long PumpId,
    long TankId,
    string TankName,
    string TxnType,
    decimal Quantity,
    DateTime TxnDateTime,
    string? ReferenceNo,
    string? Notes
);

public sealed record ApiSaveTankTransactionRequest(
    long OwnerId,
    long PumpId,
    long TankId,
    string TxnType,
    decimal Quantity,
    string? ReferenceNo,
    string? Notes,
    DateTime? TxnDateTime = null
);

public sealed record ApiPartyLedgerEntryDto(
    long Id,
    long OwnerId,
    long PumpId,
    long PartyId,
    string PartyName,
    string EntryType,
    decimal Amount,
    DateTime EntryDateTime,
    string? ReferenceNo,
    string? Notes
);

public sealed record ApiVendorDto(
    long Id,
    long OwnerId,
    long PumpId,
    string VendorName,
    string? ContactNo,
    string? GSTIN,
    string? Address,
    bool IsActive
);

public sealed record ApiSaveVendorRequest(
    long? Id,
    long OwnerId,
    long PumpId,
    string VendorName,
    string? ContactNo,
    string? GSTIN,
    string? Address,
    bool IsActive
);

/// <summary>Amount = is product ki BILL wali rakam (VAT/recovery mila kar) - Section AE.</summary>
public sealed record ApiPurchaseItemRequest(
    long ProductId,
    long? TankId,
    decimal Quantity,
    decimal Rate,
    decimal? Amount = null
);

public sealed record ApiSavePurchaseRequest(
    long? Id,
    long OwnerId,
    long PumpId,
    long VendorId,
    string InvoiceNo,
    DateOnly InvoiceDate,
    string? VehicleNo,
    string? DriverName,
    string? Notes,
    List<ApiPurchaseItemRequest> Items
);

public sealed record ApiPurchaseDetailDto(
    long Id,
    long OwnerId,
    long PumpId,
    long VendorId,
    string InvoiceNo,
    DateOnly InvoiceDate,
    string? VehicleNo,
    string? DriverName,
    string? Notes,
    List<ApiPurchaseDetailItemDto> Items
);

public sealed record ApiPurchaseDetailItemDto(
    long ProductId,
    long? TankId,
    decimal Quantity,
    decimal Rate,
    // Purani API ye nahi bhejti - tab 0 aata hai aur form Quantity x Rate dikhata hai.
    decimal Amount = 0
);

public sealed record ApiPurchaseDto(
    long Id,
    long OwnerId,
    long PumpId,
    long VendorId,
    string VendorName,
    string InvoiceNo,
    DateTime InvoiceDate,
    string? VehicleNo,
    string? DriverName,
    decimal TotalAmount,
    string? Notes,
    DateTime CreatedOn,
    decimal TotalQty,
    string? ProductSummary
);

public sealed record ApiStockReconciliationDto(
    long Id,
    long OwnerId,
    long PumpId,
    long TankId,
    string TankName,
    DateTime ReconciliationDate,
    decimal BookStock,
    decimal PhysicalStock,
    decimal VarianceQty,
    decimal? VarianceAmount,
    string? Reason,
    DateTime CreatedOn
);

public sealed record ApiSaveStockReconciliationRequest(
    long OwnerId,
    long PumpId,
    long TankId,
    DateOnly ReconciliationDate,
    decimal BookStock,
    decimal PhysicalStock,
    string? Reason
);

public sealed record ApiExpenseHeadDto(
    long Id,
    long OwnerId,
    long PumpId,
    string HeadName,
    bool IsActive
);

public sealed record ApiSaveExpenseHeadRequest(
    long? Id,
    long OwnerId,
    long PumpId,
    string HeadName,
    bool IsActive
);

public sealed record ApiCashTransactionDto(
    long Id,
    long OwnerId,
    long PumpId,
    long? ShiftId,
    string TxnType,
    decimal Amount,
    string? ReferenceNo,
    string? Narration,
    DateTime TxnDateTime
);

public sealed record ApiSaveCashTransactionRequest(
    long OwnerId,
    long PumpId,
    long? ShiftId,
    string TxnType,
    decimal Amount,
    string? ReferenceNo,
    string? Narration,
    DateTime? TxnDateTime
);

public sealed record ApiExpenseDto(
    long Id,
    long OwnerId,
    long PumpId,
    long? ShiftId,
    long ExpenseHeadId,
    string ExpenseHeadName,
    decimal Amount,
    string PaymentMode,
    string? ReferenceNo,
    string? Narration,
    DateTime TxnDateTime
);

public sealed record ApiDipReadingDto(
    long Id,
    long OwnerId,
    long PumpId,
    long TankId,
    string TankName,
    DateTime ReadingDate,
    long? ShiftId,
    decimal DipCm,
    decimal? WaterDipCm,
    decimal? Density,
    decimal? Temperature,
    decimal ExpectedStock,
    decimal ActualStock,
    decimal Variance,
    decimal? VarianceAmount,
    DateTime CreatedOn,
    bool IsActive
);

public sealed record ApiSaveDipReadingRequest(
    long OwnerId,
    long PumpId,
    long TankId,
    DateTime ReadingDate,
    long? ShiftId,
    decimal DipCm,
    decimal? WaterDipCm,
    decimal? Density,
    decimal? Temperature,
    decimal ExpectedStock,
    decimal ActualStock
);

public sealed record ApiUpdateDipReadingRequest(
    long OwnerId,
    long PumpId,
    long TankId,
    DateTime ReadingDate,
    long? ShiftId,
    decimal DipCm,
    decimal? WaterDipCm,
    decimal? Density,
    decimal? Temperature,
    decimal ExpectedStock,
    decimal ActualStock
);

public sealed record ApiTestingLossDto(
    long Id,
    long OwnerId,
    long PumpId,
    long ProductId,
    string ProductName,
    long TankId,
    string TankName,
    DateTime LossDate,
    long? ShiftId,
    string LossType,
    decimal Quantity,
    string? Notes,
    DateTime CreatedOn,
    bool IsActive
);

public sealed record ApiSaveTestingLossRequest(
    long OwnerId,
    long PumpId,
    long TankId,
    DateTime LossDate,
    long? ShiftId,
    string LossType,
    decimal Quantity,
    string? Notes
);

public sealed record ApiUpdateTestingLossRequest(
    long OwnerId,
    long PumpId,
    long TankId,
    DateTime LossDate,
    long? ShiftId,
    string LossType,
    decimal Quantity,
    string? Notes
);

public sealed record ApiSaveExpenseRequest(
    long OwnerId,
    long PumpId,
    long? ShiftId,
    long ExpenseHeadId,
    decimal Amount,
    string PaymentMode,
    string? ReferenceNo,
    string? Narration,
    DateTime? TxnDateTime
);

public sealed record ApiDayBookEntryDto(
    DateTime EntryDateTime,
    string EntryType,
    string? ReferenceNo,
    string Description,
    decimal Debit,
    decimal Credit
);

public sealed record ApiOutstandingPartyDto(
    long PartyId,
    string PartyName,
    string PartyType,
    decimal CreditLimit,
    decimal CurrentBalance,
    DateTime? LastSaleDate
);

public sealed record ApiPumpComparisonDto(
    long PumpId,
    string PumpName,
    string? City,
    decimal SalesAmount,
    decimal PurchaseAmount,
    decimal ExpenseAmount,
    decimal NetAmount
);

public sealed record ApiDailyStockRegisterDto(
    int DayOfMonth,
    DateTime Date,
    decimal OpeningStock,
    decimal Receipt,
    decimal TotalStock,
    decimal SalesByMeter,
    decimal PumpTest,
    decimal NetSalesByMeter,
    decimal CumulativeSales,
    decimal SalesByDip,
    // Kitaabi closing aur asli napa hua stock - dono alag (CA ke liye).
    decimal BookClosingStock,
    decimal? PhysicalClosingStock,
    bool StockChecked,
    decimal ClosingStock,
    decimal VariationDaily,
    decimal VariationValue,
    decimal VariationCumulative,
    decimal RateApplied,
    decimal SalesValue,
    decimal CumulativeSalesValue,
    string? Remarks
);


public sealed record ApiFleetContractDto(
    long Id,
    long OwnerId,
    long PumpId,
    long PartyId,
    string PartyName,
    long ProductId,
    string ProductName,
    decimal ContractRate,
    DateTime ValidFrom,
    DateTime? ValidTo,
    bool IsActive,
    string? Notes
);

public sealed record ApiSaveFleetContractRequest(
    long? Id,
    long OwnerId,
    long PumpId,
    long PartyId,
    long ProductId,
    decimal ContractRate,
    DateOnly ValidFrom,
    DateOnly? ValidTo,
    bool IsActive,
    string? Notes
);

public sealed record ApiCouponBookDto(
    long Id,
    long OwnerId,
    long PumpId,
    string BookCode,
    decimal Denomination,
    int TotalCoupons,
    long? IssuedToPartyId,
    string? IssuedToPartyName,
    int StartSerial,
    int EndSerial,
    bool IsActive,
    DateTime CreatedOn
);

public sealed record ApiSaveCouponBookRequest(
    long? Id,
    long OwnerId,
    long PumpId,
    string BookCode,
    decimal Denomination,
    int TotalCoupons,
    long? IssuedToPartyId,
    int StartSerial,
    int EndSerial,
    bool IsActive
);

public sealed record ApiCouponTransactionDto(
    long Id,
    long OwnerId,
    long PumpId,
    long CouponBookId,
    string BookCode,
    long? PartyId,
    string? PartyName,
    long? SalesHeaderId,
    int CouponSerialNo,
    decimal Amount,
    DateTime TxnDateTime,
    string? Notes
);

public sealed record ApiSaveCouponTransactionRequest(
    long OwnerId,
    long PumpId,
    long CouponBookId,
    long? PartyId,
    long? SalesHeaderId,
    int CouponSerialNo,
    decimal Amount,
    string? Notes,
    DateTime? TxnDateTime = null
);

public sealed record ApiSavePartyLedgerEntryRequest(
    long OwnerId,
    long PumpId,
    long PartyId,
    string EntryType,
    decimal Amount,
    DateTime? EntryDateTime,
    string? ReferenceNo,
    string? Notes
);

public sealed record ApiSaveNozzleRequest(
    long? Id,
    long OwnerId,
    long PumpId,
    long ProductId,
    string NozzleCode,
    long? TankId
);

public sealed record ApiSaveProductRequest(
    long? Id,
    long OwnerId,
    long PumpId,
    string Name,
    string Category,
    string Unit,
    decimal CurrentRate,
    string? HSNCode,
    decimal CGSTRate,
    decimal SGSTRate
);

public sealed record ApiSaleItemRequest(
    long ProductId,
    string? NozzleNo,
    decimal Quantity,
    decimal Rate,
    decimal BaseAmount,
    decimal CGSTAmount,
    decimal SGSTAmount
);

public sealed record ApiSaveSaleRequest(
    long OwnerId,
    long PumpId,
    long ShiftId,
    string PaymentMode,
    long? PartyId,
    string? VehicleNo,
    string? CustomerName,
    string? AttendantName,
    List<ApiSaleItemRequest> Items,
    // Chhoot gayi entries poori karne ke liye — NULL bhejein to abhi ka waqt lagta hai.
    DateTime? BillDateTime = null
);

public sealed record ApiSaleDto(
    long Id,
    long OwnerId,
    long PumpId,
    long ShiftId,
    long? PartyId,
    string BillNo,
    DateTime BillDateTime,
    string PaymentMode,
    string? VehicleNo,
    string? CustomerName,
    string? AttendantName,
    decimal TotalAmount,
    // Void kiya hua bill mitta nahi — list me nishaan ke saath dikhta hai,
    // lekin kisi total/report me nahi ginta.
    bool IsVoid,
    DateTime? VoidedOn,
    string? VoidReason
);

public sealed record ApiReceiptDto(
    long Id,
    long SalesHeaderId,
    string ReceiptNo,
    DateTime ReceiptDateTime,
    string BillNo,
    DateTime BillDateTime,
    string PaymentMode,
    string? VehicleNo,
    string? CustomerName,
    string? AttendantName,
    decimal TotalAmount,
    decimal TotalQuantity,
    decimal BaseAmount,
    decimal TotalCGST,
    decimal TotalSGST,
    string? PumpGSTIN,
    string? PumpAddress,
    // "kg" / "L" - mili-juli ikai ho to null.
    string? QuantityUnit = null
);

public sealed record ApiUserDto(
    long Id,
    long OwnerId,
    string FullName,
    string Username,
    string? Mobile,
    bool IsActive,
    long? RoleId,
    string? RoleName
);

public sealed record ApiEmployeeDto(
    long Id,
    long OwnerId,
    long PumpId,
    long? UserId,
    string EmployeeCode,
    string FullName,
    string? Mobile,
    DateOnly JoinDate,
    string? Designation,
    decimal MonthlySalary,
    bool IsActive,
    string? UserName
);

public sealed record ApiSaveEmployeeRequest(
    long? Id,
    long OwnerId,
    long PumpId,
    long? UserId,
    string EmployeeCode,
    string FullName,
    string? Mobile,
    DateOnly JoinDate,
    string? Designation,
    decimal MonthlySalary,
    bool IsActive
);

public sealed record ApiSalaryPaymentDto(
    long Id,
    long OwnerId,
    long PumpId,
    long EmployeeId,
    string EmployeeCode,
    string EmployeeName,
    int SalaryYear,
    int SalaryMonth,
    decimal Amount,
    DateOnly PaidOn,
    string PaymentMode,
    string? ReferenceNo,
    string? Notes,
    DateTime CreatedOn
);

public sealed record ApiSaveSalaryPaymentRequest(
    long? Id,
    long OwnerId,
    long PumpId,
    long EmployeeId,
    int SalaryYear,
    int SalaryMonth,
    decimal Amount,
    DateOnly PaidOn,
    string PaymentMode,
    string? ReferenceNo,
    string? Notes,
    // Section AQ: salary me se kitna advance kata (null = advance ko mat chhedo).
    decimal? AdvanceCut = null
);

public sealed record ApiSaveUserRequest(
    long? Id,
    long OwnerId,
    string FullName,
    string Username,
    string Password,
    string? Mobile,
    long RoleId
);

public sealed record ApiRoleDto(
    long Id,
    long OwnerId,
    string Name,
    bool IsSystem,
    bool IsActive
);

public sealed record ApiSaveRoleRequest(
    long? Id,
    long OwnerId,
    string Name,
    bool IsSystem
);

public sealed record ApiOwnerDto(
    long Id,
    string Name,
    bool IsActive,
    DateTime CreatedOn,
    DateTime? ValidUpto,
    string? ContactName = null,
    string? ContactNo = null,
    string? Email = null,
    string? City = null,
    string? StateCode = null,
    string? GSTIN = null,
    string? PlanCode = null,
    bool IsTrial = false,
    int PumpCount = 0,
    int UserCount = 0,
    int? DaysLeft = null,
    DateTime? LastLoginOn = null,
    DateTime? LastActivityOn = null,
    decimal SalesThisMonth = 0
);

/// <summary>Superadmin ko kisi tenant ke users chahiye - password reset ke liye.</summary>
/// <summary>
/// Pump par har nozzle par alag aadmi hota hai. Ye us aadmi ke cash ki ek line:
/// chhutta + meter sale - parchi = jitna milna chahiye.
/// </summary>
public sealed record ApiNozzleCashDto(
    long ShiftId,
    long NozzleId,
    string NozzleCode,
    string ProductName,
    long? EmployeeId,
    string EmployeeName,
    decimal OpeningReading,
    decimal? ClosingReading,
    decimal SoldQty,
    decimal Rate,
    decimal MeterSale,
    decimal FloatGiven,
    decimal SlipsAmount,
    decimal ExpectedCash,
    decimal? CashReturned,
    decimal? ShortExcess,
    DateTime? CashCollectedOn,
    string? CashNotes,
    bool IsCollected
);

public sealed record ApiPendingCashDto(
    long ShiftId,
    DateOnly ShiftDate,
    string ShiftCode,
    string Status,
    long NozzleId,
    string NozzleCode,
    string ProductName,
    long? EmployeeId,
    string EmployeeName,
    string? EmployeeMobile,
    decimal MeterSale,
    decimal FloatGiven,
    decimal SlipsAmount,
    decimal ExpectedCash,
    int DaysPending
);

public sealed record ApiAttendantCashDto(
    long? EmployeeId,
    string EmployeeName,
    int Shifts,
    decimal TotalMeterSale,
    decimal TotalFloat,
    decimal TotalSlips,
    decimal TotalExpected,
    decimal TotalReturned,
    decimal TotalShortExcess,
    int PendingCount,
    decimal PendingAmount
);

public sealed record ApiTenantUserDto(
    long Id,
    string FullName,
    string Username,
    string? Mobile,
    bool IsActive,
    bool IsOwner,
    string RoleName,
    DateTime? LastLoginOn
);

public sealed record ApiSaveOwnerRequest(
    string Name,
    string AdminUsername,
    string AdminPassword
);

public sealed record ApiRoleMenuDto(
    long Id,
    long RoleId,
    long MenuId,
    bool CanView,
    bool CanCreate,
    bool CanEdit,
    bool CanDelete
);

public sealed record ApiSaveRoleMenusRequest(
    long RoleId,
    List<ApiRoleMenuRequestDto> Menus
);

public sealed record ApiRoleMenuRequestDto(
    long MenuId,
    bool CanView,
    bool CanCreate,
    bool CanEdit,
    bool CanDelete
);

public sealed record ApiSubscriptionRequestDto(
    long Id,
    string ContactName,
    string ContactNo,
    string PlanType,
    long? OwnerId,
    string Status,
    DateTime RequestedOn,
    string? Notes,
    string? PumpName,
    string? City = null,
    string? StateCode = null,
    string? StateName = null,
    DateTime? DoneOn = null
);

public sealed record ApiSaveSubscriptionRequest(
    string ContactName,
    string ContactNo,
    string PlanType,
    long? OwnerId = null,
    string? PumpName = null
);

/// <summary>
/// Staff page ka ek row: HR record + uska login (agar hai to).
/// UserName/RoleId NULL hona normal hai — bahut log bina login ke hote hain.
/// </summary>
public sealed record ApiStaffDto(
    long Id,
    long OwnerId,
    long PumpId,
    long? UserId,
    string EmployeeCode,
    string FullName,
    string? Mobile,
    DateOnly JoinDate,
    string? Designation,
    decimal MonthlySalary,
    bool IsActive,
    string? UserName,
    long? RoleId,
    string? RoleName,
    bool LoginActive
);

public sealed record ApiSaveStaffRequest(
    long? Id,
    long OwnerId,
    long PumpId,
    string EmployeeCode,
    string FullName,
    string? Mobile,
    DateOnly JoinDate,
    string? Designation,
    decimal MonthlySalary,
    bool IsActive,
    bool WantsLogin,
    string? Username,
    string? Password,
    long? RoleId
);

public sealed record ApiSaveStaffResult(long EmployeeId, long? UserId);

/// <summary>Settings > Alerts ki ek line.</summary>
public sealed record ApiOwnerAlertDto(string AlertKey, string Title, string Description, bool IsEnabled);

/// <summary>/api/owner-alerts ka poora jawab — number aur list ek saath.</summary>
public sealed record ApiOwnerAlertsResponse(string? Mobile, IReadOnlyList<ApiOwnerAlertDto> Alerts);

public sealed record ApiSaveOwnerAlertRequest(string AlertKey, bool IsEnabled);

public sealed record ApiSaveOwnerAlertMobileRequest(string? Mobile);

// ================= Message credits =================
public sealed record ApiPlatformCreditSummary(
    int CreditsBought, decimal AmountPaid, int CreditsAllocated,
    int CreditsAvailable, int CreditsPending, int CreditsSpent, int TenantCount);

public sealed record ApiAddPlatformCreditRequest(
    decimal AmountPaid, int CreditsBought, string? Provider, string? ReferenceNo, string? Notes);

public sealed record ApiCreditSettings(string UpiId, string UpiName, decimal? PricePerCredit);

public sealed record ApiSaveCreditSettingsRequest(string? UpiId, string? UpiName, decimal? PricePerCredit);

public sealed record ApiWalletDto(
    int Balance, int LifetimeAdded, int LifetimeUsed, int PendingCredits,
    string UpiId, string UpiName, decimal? PricePerCredit);

public sealed record ApiRechargeRequestDto(
    long Id, long OwnerId, string OwnerName, DateTime RequestedOn, decimal Amount,
    int Credits, string? UpiReference, string Status, DateTime? DecidedOn, string? DecisionNote);

public sealed record ApiCreditLedgerDto(
    long Id, DateTime EntryOn, string EntryType, int Credits, int BalanceAfter,
    string? AlertKey, string? ReferenceNo, string? Notes);

public sealed record ApiRequestRechargeInput(decimal Amount, string? UpiReference);

public sealed record ApiDecideRechargeRequest(string? Note);


// ── Din ka collection — Online / Card / udhaar (Section W) ──────────────
public sealed record ApiShiftCollectionCreditLine(
    long PartyId,
    string? PartyName,
    decimal Amount,
    // Har parchi alag (Section AK) — kaunsi gaadi, aur chhota note (parchi no. / litre).
    string? VehicleNo = null,
    string? SlipNote = null,
    // Section AQ: kaunsa tel aur kitna. ProductName / Unit sirf dikhane ke liye (API Get se).
    long? ProductId = null,
    decimal? Quantity = null,
    string? ProductName = null,
    string? Unit = null);

/// <summary>Ek jaisi udhaar ki jaanch (Section AQ4).</summary>
public sealed record ApiCreditDuplicateLine(long PartyId, decimal Amount);
public sealed record ApiCreditDuplicateCheckRequest(long? ShiftId, DateOnly? EntryDate, IReadOnlyList<ApiCreditDuplicateLine> Lines);
public sealed record ApiCreditDuplicateDto(long PartyId, string PartyName, decimal Amount, DateTime EntryDate, string? ReferenceNo, string? Notes);

/// <summary>Karmchari ka advance (Section AQ5). EntryType: GIVEN / RETURNED / SALARY_CUT.</summary>
public sealed record ApiEmployeeAdvanceDto(long Id, long EmployeeId, string EmployeeName, string EntryType, decimal Amount,
    DateTime EntryDate, string? PaymentMode, string? Notes, long? SalaryPaymentId);
public sealed record ApiSaveEmployeeAdvanceRequest(long PumpId, long EmployeeId, string EntryType, decimal Amount,
    DateOnly EntryDate, string? PaymentMode, string? Notes);

/// <summary>Mahine ka salary hisaab (Section AQ6).</summary>
public sealed record ApiSalarySummaryDto(long EmployeeId, string? EmployeeCode, string FullName, decimal MonthlySalary,
    decimal Paid, decimal AdvanceCut, decimal Pending, decimal AdvanceOutstanding, long? SalaryPaymentId);

public sealed record ApiShiftCollection(
    decimal UpiAmount,
    decimal CardAmount,
    IReadOnlyList<ApiShiftCollectionCreditLine> Credits);

public sealed record ApiSaveShiftCollectionRequest(
    long ShiftId,
    decimal UpiAmount,
    decimal CardAmount,
    IReadOnlyList<ApiShiftCollectionCreditLine> Credits);

/// <summary>
/// Support console ki ek line (Section Z). Param theek `sp_Support_ShiftList`
/// ke column ke kram me hain — API bhi yahi bhejta hai.
/// </summary>
public sealed record ApiSupportShiftDto(
    long Id,
    long PumpId,
    string? PumpName,
    DateOnly ShiftDate,
    string ShiftCode,
    string Status,
    DateTime OpenedOn,
    DateTime? ClosedOn,
    decimal TotalMeterSale,
    decimal OpeningCash,
    decimal? ClosingCash,
    int NozzleCount,
    int ReadingsFilled,
    int SalesCount,
    int CashTxnCount,
    int ExpenseCount,
    int DipCount,
    int TankTxnCount,
    bool CanReopen,
    bool CanDelete
);

/// <summary>Close Shift form ki dip wali line (Section AB) — API ke ShiftClosingDipRow jaisa.</summary>
/// <summary>Maahwar bikri-khareed register ki ek line (Section AD).</summary>
public sealed record ApiMonthlySaleRegisterRow(
    int DayOfMonth,
    DateTime Date,
    decimal SaleQty,
    decimal Rate,
    decimal SaleAmount,
    decimal PurchaseQty,
    decimal PurchaseAmount);

public sealed record ApiShiftClosingDipRow(
    long TankId,
    string TankName,
    string ProductName,
    decimal BookExcludingShift,
    string NozzleIds,
    long? DipId,
    decimal? DipCm,
    decimal? ActualStock);

public sealed record ApiShiftClosingDipInput(long TankId, decimal? DipCm, decimal ActualStock);

public sealed record ApiSaveShiftClosingDipsRequest(IReadOnlyList<ApiShiftClosingDipInput> Dips);

public sealed record ApiShiftClosingDipSaved(
    long TankId,
    string TankName,
    decimal ExpectedStock,
    decimal ActualStock,
    decimal Variance);
