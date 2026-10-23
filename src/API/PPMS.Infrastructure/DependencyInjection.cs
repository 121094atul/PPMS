using Dapper;
using Microsoft.Extensions.Configuration;
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
using PPMS.Infrastructure.Persistence;
using PPMS.Infrastructure.Security;
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
using PPMS.Application.Features.DipTesting;
using PPMS.Application.Features.Owners;
using PPMS.Application.Features.Subscriptions;
using PPMS.Application.Interfaces;
using PPMS.Infrastructure.Services;

namespace PPMS.Infrastructure;

public static class DependencyInjection
{
    public static IServiceCollection AddInfrastructureServices(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        // Dapper: DateOnly type handler register karo (SQL date <-> DateOnly mapping)
        SqlMapper.AddTypeHandler(DateOnlyTypeHandler.Instance);

        services.Configure<DatabaseOptions>(configuration.GetSection(DatabaseOptions.SectionName));

        services.Configure<JwtOptions>(configuration.GetSection(JwtOptions.SectionName));
        services.Configure<PPMS.Infrastructure.Services.BackupOptions>(
            configuration.GetSection(PPMS.Infrastructure.Services.BackupOptions.SectionName));

        // Roz apne aap DB backup. SQL Express/LocalDB me SQL Agent hota hi nahi,
        // isliye app ke andar se chalate hain. Backup:Enabled se on/off hota hai.
        services.AddHostedService<PPMS.Infrastructure.Services.DatabaseBackupService>();
        services.PostConfigure<DatabaseOptions>(options =>
        {
            if (!string.IsNullOrWhiteSpace(options.ConnectionString))
            {
                return;
            }

            options.ConnectionString = configuration.GetConnectionString("DefaultConnection") ?? string.Empty;
        });

        services.AddScoped<IProductReadRepository, ProductReadRepository>();
        services.AddScoped<IProductCommandRepository, ProductCommandRepository>();
        services.AddScoped<IPumpRepository, PumpRepository>();
        services.AddScoped<INozzleRepository, NozzleRepository>();
        services.AddScoped<IAuthRepository, AuthRepository>();
        services.AddScoped<IPasswordResetRepository, PasswordResetRepository>();
        services.AddScoped<PPMS.Application.Features.Shifts.IAttendantCashRepository, AttendantCashRepository>();
        services.AddScoped<PPMS.Application.Features.Owners.ISelfSignupRepository, SelfSignupRepository>();
        services.AddScoped<IMenuRepository, MenuRepository>();
        services.AddScoped<IUserRepository, UserRepository>();
        services.AddScoped<IRoleRepository, RoleRepository>();
        services.AddScoped<IShiftRepository, ShiftRepository>();
        services.AddScoped<ISalesRepository, SalesRepository>();
        services.AddScoped<ITankReadRepository, TankReadRepository>();
        services.AddScoped<ITankCommandRepository, TankCommandRepository>();
        services.AddScoped<IPartyReadRepository, PartyReadRepository>();
        services.AddScoped<IPartyCommandRepository, PartyCommandRepository>();
        services.AddScoped<ITankTransactionRepository, TankTransactionRepository>();
        services.AddScoped<IPartyLedgerRepository, PartyLedgerRepository>();
        services.AddScoped<IVendorRepository, VendorRepository>();
        services.AddScoped<IPurchaseRepository, PurchaseRepository>();
        services.AddScoped<IStockReconciliationRepository, StockReconciliationRepository>();
        services.AddScoped<IExpenseHeadRepository, ExpenseHeadRepository>();
        services.AddScoped<ICashTransactionRepository, CashTransactionRepository>();
        services.AddScoped<IExpenseRepository, ExpenseRepository>();
        services.AddScoped<IDayBookReportRepository, DayBookReportRepository>();
        services.AddScoped<IReportInsightsRepository, ReportInsightsRepository>();
        services.AddScoped<IFleetCouponRepository, FleetCouponRepository>();
        services.AddScoped<IEmployeeRepository, EmployeeRepository>();
        services.AddScoped<PPMS.Application.Features.Staff.IStaffRepository, StaffRepository>();
        services.AddScoped<PPMS.Application.Interfaces.IOwnerAlertRepository, OwnerAlertRepository>();
        services.AddScoped<PPMS.Application.Interfaces.ICreditRepository, CreditRepository>();
        services.AddScoped<PPMS.Application.Interfaces.ISupportContactRepository, SupportContactRepository>();
        services.AddScoped<ISalaryPaymentRepository, SalaryPaymentRepository>();
        services.AddScoped<IDipTestingService, DipTestingService>();
        services.AddScoped<IPasswordHasher, Pbkdf2PasswordHasher>();
        services.AddScoped<IPasswordResetService, PasswordResetService>();
        services.AddScoped<PPMS.Application.Features.Shifts.IAttendantCashService, PPMS.Application.Features.Shifts.AttendantCashService>();
        services.AddScoped<PPMS.Application.Features.Owners.ISelfSignupService, PPMS.Application.Features.Owners.SelfSignupService>();
        services.AddScoped<ITokenService, JwtTokenService>();
        services.AddScoped<IOwnerRepository, OwnerRepository>();
        services.AddScoped<ISubscriptionRequestRepository, SubscriptionRequestRepository>();

        // Tenant ownership check (ITenantGuard) — cache ke liye IMemoryCache chahiye.
        services.AddMemoryCache();
        services.AddScoped<ITenantGuard, TenantGuard>();
        services.AddHttpClient<IWhatsAppNotificationService, WhatsAppNotificationService>();
        return services;
    }
}
