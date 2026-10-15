using Microsoft.Extensions.DependencyInjection;
using PPMS.Application.Features.Auth;
using PPMS.Application.Features.Menus;
using PPMS.Application.Features.Nozzles;
using PPMS.Application.Features.Pumps;
using PPMS.Application.Features.Products;
using PPMS.Application.Features.Roles;
using PPMS.Application.Features.Sales;
using PPMS.Application.Features.Shifts;
using PPMS.Application.Features.Users;
using PPMS.Application.Features.Tanks;
using PPMS.Application.Features.Parties;
using PPMS.Application.Features.TankTransactions;
using PPMS.Application.Features.PartyLedger;
using PPMS.Application.Features.Vendors;
using PPMS.Application.Features.Purchases;
using PPMS.Application.Features.StockReconciliation;
using PPMS.Application.Features.ExpenseHeads;
using PPMS.Application.Features.CashTransactions;
using PPMS.Application.Features.Expenses;
using PPMS.Application.Features.DayBookReport;
using PPMS.Application.Features.ReportInsights;
using PPMS.Application.Features.FleetCoupons;
using PPMS.Application.Features.Employees;
using PPMS.Application.Features.SalaryPayments;
using PPMS.Application.Features.Owners;
using PPMS.Application.Features.Subscriptions;

namespace PPMS.Application;

public static class DependencyInjection
{
    public static IServiceCollection AddApplicationServices(this IServiceCollection services)
    {
        services.AddScoped<IProductQueryService, ProductQueryService>();
        services.AddScoped<IProductCommandService, ProductCommandService>();
        services.AddScoped<IPumpQueryService, PumpQueryService>();
        services.AddScoped<IPumpCommandService, PumpCommandService>();
        services.AddScoped<INozzleQueryService, NozzleQueryService>();
        services.AddScoped<INozzleCommandService, NozzleCommandService>();
        services.AddScoped<IAuthService, AuthService>();
        services.AddScoped<IMenuQueryService, MenuQueryService>();
        services.AddScoped<IUserService, UserService>();
        services.AddScoped<IRoleService, RoleService>();
        services.AddScoped<IShiftService, ShiftService>();
        services.AddScoped<ISalesService, SalesService>();
        services.AddScoped<ITankQueryService, TankQueryService>();
        services.AddScoped<ITankCommandService, TankCommandService>();
        services.AddScoped<IPartyQueryService, PartyQueryService>();
        services.AddScoped<IPartyCommandService, PartyCommandService>();
        services.AddScoped<ITankTransactionService, TankTransactionService>();
        services.AddScoped<IPartyLedgerService, PartyLedgerService>();
        services.AddScoped<IVendorService, VendorService>();
        services.AddScoped<IPurchaseService, PurchaseService>();
        services.AddScoped<IStockReconciliationService, StockReconciliationService>();
        services.AddScoped<IExpenseHeadService, ExpenseHeadService>();
        services.AddScoped<ICashTransactionService, CashTransactionService>();
        services.AddScoped<IExpenseService, ExpenseService>();
        services.AddScoped<IDayBookReportService, DayBookReportService>();
        services.AddScoped<IReportInsightsService, ReportInsightsService>();
        services.AddScoped<IFleetCouponService, FleetCouponService>();
        services.AddScoped<IEmployeeService, EmployeeService>();
        services.AddScoped<Features.Staff.IStaffService, Features.Staff.StaffService>();
        services.AddScoped<ISalaryPaymentService, SalaryPaymentService>();
        services.AddScoped<IOwnerService, OwnerService>();
        services.AddScoped<ISubscriptionRequestService, SubscriptionRequestService>();
        return services;
    }
}
