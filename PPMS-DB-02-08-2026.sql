/* ==========================================================================================
   PPMS — PETROL PUMP MANAGEMENT SYSTEM
   COMPLETE DATABASE BUILD SCRIPT
   ------------------------------------------------------------------------------------------
   Ye ek hi file poora database bana deti hai. Aur kuch chalane ki zaroorat nahi.

   KAISE CHALAYEN
   --------------
       sqlcmd -S <server> -U <user> -P <password> -I -i "PPMS-DB-02-08-2026.sql" -o build-log.txt

       ya SSMS me file kholein aur F5 dabayein (SQLCMD Mode ki zaroorat nahi).

   Chalane ke baad build-log.txt kholein — sabse neeche HEALTH CHECK report hai jo
   batati hai kya theek hua aur kya kaam manually karna baaki hai.

   YE FILE DO HISSON ME HAI
   ------------------------
     PART 1  (neeche se shuru)  — base schema: 36 tables, data, foreign keys, 95 procedures
     PART 2  (file ke ant me)   — UPGRADE PACK v2.0: jo missing tha wo sab

   DOBARA CHALANA SAFE HAI — har cheez guarded hai, duplicate nahi banega,
   koi data delete nahi hota.

   PART 2 ME KYA HAI
   -----------------
     * 46 missing DEFAULT constraints — inke bina fresh DB par app kuch SAVE hi nahi
       kar sakta tha ("Cannot insert the value NULL into column 'CreatedOn'")
     * Owners.ValidUpto column + sp_Auth_Login me uska SELECT
       — iske bina superadmin ke alawa koi LOGIN nahi kar pata tha
     * SubscriptionRequests table + 4 missing stored procedures jo code call karta hai
     * sp_Shift_Close poora dobara likha — 6 bugs fix (tank double-deduction,
       meter rollover, closed-shift edit, back-date, testing loss, transaction)
     * Cash reconciliation — expected cash ka formula, short/excess detection,
       note denomination counting, bank deposit tracking
     * 47 performance indexes — original me ek bhi non-clustered index nahi tha
     * Soft delete — "delete button kaam nahi karta" wali problem ka fix
     * Payment gateway ka poora dhancha (integration baad me, tables abhi ready)
     * Audit log, login lockout, GST/VAT state-wise tax master, 36 Indian states
     * (2026-09-03) PART 1 ke SAARE `SET QUOTED_IDENTIFIER OFF` ko `ON` kar diya —
       SSMS jab procedure script karta hai to yahi default likhta hai, lekin jo bhi
       procedure `Tanks`/`Products`/`Parties`/`Vendors`/`Nozzles`/`ExpenseHeads`/
       `BankAccounts` (filtered unique index waale) ko INSERT/UPDATE/DELETE karta
       tha, wo hamesha "Msg 1934" se fail hota tha — session ka QUOTED_IDENTIFIER
       matter nahi karta, jo procedure CREATE hote waqt tha wahi baked-in reh jaata
       hai. `sp_TankTxn_Save` isi wajah se kabhi kaam nahi karta tha (Tank Stock
       page se koi transaction save hi nahi hoti thi) — real DB par bhi yehi hoga.
       Procedures `CREATE OR ALTER` hain (guard nahi), isliye script dobara chalate
       hi sab fix ho jaayenge — koi alag migration nahi chahiye.

   ========================================================================================== */
GO

SET NOCOUNT ON;
GO

/* ------------------------------------------------------------------------------------------
   BOOTSTRAP — database, login aur user na ho to bana do
   ------------------------------------------------------------------------------------------
   NOTE: SQL login ka password yahan JAANBUJH KE nahi likha hai. Purane appsettings.json
         me DB password plaintext me pada tha (aur wo repo me commit bhi ho chuka hai),
         isliye wo password ab surakshit nahi hai.

         Agar login pehle se nahi hai to neeche wala block ek random password se banata
         hai aur usko log me print kar deta hai — use turant apne env variable /
         Key Vault me daal dein, kahin file me mat likhein.
   ------------------------------------------------------------------------------------------ */

IF DB_ID(N'PPMSDB') IS NULL
BEGIN
    PRINT 'Creating database PPMSDB...';
    EXEC (N'CREATE DATABASE [PPMSDB]');
END
ELSE
    PRINT 'Database PPMSDB already exists — continuing.';
GO

/* Recovery model FULL rakho — point-in-time restore ke liye zaroori hai.
   (Backup schedule alag se set karna padega — DB script ye nahi kar sakti.) */
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'PPMSDB' AND recovery_model_desc <> 'FULL')
BEGIN
    BEGIN TRY
        EXEC (N'ALTER DATABASE [PPMSDB] SET RECOVERY FULL');
        PRINT 'Recovery model set to FULL.';
    END TRY
    BEGIN CATCH
        PRINT 'Could not set recovery model (managed instance?) — skipping.';
    END CATCH
END
GO

/* READ_COMMITTED_SNAPSHOT — 5000 users ke liye zaroori.
   Iske bina ek lambi report poore pump ki writes block kar deti hai. */
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'PPMSDB' AND is_read_committed_snapshot_on = 0)
BEGIN
    BEGIN TRY
        EXEC (N'ALTER DATABASE [PPMSDB] SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE');
        PRINT 'READ_COMMITTED_SNAPSHOT enabled (readers ab writers ko block nahi karenge).';
    END TRY
    BEGIN CATCH
        PRINT 'Could not enable RCSI — skipping. Baad me manually karein.';
    END CATCH
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'PPMSUser')
BEGIN
    DECLARE @pwd NVARCHAR(64) = CONCAT('Ppms#', REPLACE(CAST(NEWID() AS NVARCHAR(36)), '-', ''), '!7');
    EXEC (N'CREATE LOGIN [PPMSUser] WITH PASSWORD = ''' + @pwd + N''', CHECK_POLICY = ON');
    PRINT '';
    PRINT '**********************************************************';
    PRINT ' NAYA SQL LOGIN BANAYA GAYA — ye password abhi note kar lein:';
    PRINT '   Login    : PPMSUser';
    PRINT '   Password : ' + @pwd;
    PRINT ' Ise environment variable me daalein, appsettings.json me NAHI.';
    PRINT '**********************************************************';
    PRINT '';
END
ELSE
    PRINT 'Login PPMSUser already exists — password unchanged.';
GO

USE [PPMSDB];
GO

/* Database user + schemas — sab guarded */
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'PPMSUser')
BEGIN
    IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'PPMSUser')
        EXEC (N'CREATE USER [PPMSUser] FOR LOGIN [PPMSUser] WITH DEFAULT_SCHEMA=[PPMSUser]');
    ELSE
        EXEC (N'CREATE USER [PPMSUser] WITHOUT LOGIN WITH DEFAULT_SCHEMA=[PPMSUser]');
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'PPMSUser')
    EXEC (N'CREATE SCHEMA [PPMSUser]');
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'PUMP')
    EXEC (N'CREATE SCHEMA [PUMP]');
GO

/* Least privilege: app ko db_ddladmin ki zaroorat nahi hai.
   Read + write + procedures execute — bas itna kaafi hai. */
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'PPMSUser')
BEGIN
    IF IS_ROLEMEMBER('db_datareader', 'PPMSUser') = 0 EXEC (N'ALTER ROLE [db_datareader] ADD MEMBER [PPMSUser]');
    IF IS_ROLEMEMBER('db_datawriter', 'PPMSUser') = 0 EXEC (N'ALTER ROLE [db_datawriter] ADD MEMBER [PPMSUser]');
    EXEC (N'GRANT EXECUTE ON SCHEMA::[PUMP] TO [PPMSUser]');

    /* db_ddladmin hata rahe hain — app ko schema badalne ki zaroorat nahi.
       Agar aapki deployment isse maangti hai to ye line comment kar dein.

       TRY/CATCH isliye: fixed database role ki membership badalne ke liye
       sysadmin ya db_owner chahiye. Jis server par aap sirf dbcreator hain
       (ya DB kisi aur ke naam par hai) wahan ye Msg 15151 deta tha —
       "Cannot alter the role 'db_ddladmin'". Wo sirf ek hardening step hai,
       DB build ka hissa nahi, isliye ab fail hone par script rukti nahi,
       bas bata deti hai. */
    IF IS_ROLEMEMBER('db_ddladmin', 'PPMSUser') = 1
    BEGIN
        BEGIN TRY
            EXEC (N'ALTER ROLE [db_ddladmin] DROP MEMBER [PPMSUser]');
            PRINT 'PPMSUser se db_ddladmin hata diya gaya (least privilege).';
        END TRY
        BEGIN CATCH
            PRINT 'NOTE: PPMSUser se db_ddladmin nahi hata paye (permission nahi hai).';
            PRINT '      Ye sirf ek extra suraksha thi — DB poora ban chuka hai, app chalegi.';
            PRINT '      Chahein to DBA se ye ek line chalwa lein:';
            PRINT '        ALTER ROLE [db_ddladmin] DROP MEMBER [PPMSUser];';
        END CATCH
    END
END
GO

/* ------------------------------------------------------------------------------------------
   USER-DEFINED TABLE TYPE — ye original dump me MISSING tha
   ------------------------------------------------------------------------------------------
   sp_RoleMenu_Save ka parameter hai `@RoleMenus PUMP.udt_RoleMenuType READONLY`, par poore
   dump me ek bhi CREATE TYPE nahi tha. Iska matlab fresh DB par wo procedure banti hi nahi
   thi — yaani role ko menu permission dena kaam hi nahi karta.

   Type ko procedure se PEHLE banana zaroori hai, isliye ye yahan upar hai.
   ------------------------------------------------------------------------------------------ */
IF NOT EXISTS (SELECT 1 FROM sys.types t
               JOIN sys.schemas s ON s.schema_id = t.schema_id
               WHERE s.name = N'PUMP' AND t.name = N'udt_RoleMenuType')
BEGIN
    CREATE TYPE PUMP.udt_RoleMenuType AS TABLE
    (
        MenuId    BIGINT NOT NULL,
        CanView   BIT    NOT NULL DEFAULT (1),
        CanCreate BIT    NOT NULL DEFAULT (0),
        CanEdit   BIT    NOT NULL DEFAULT (0),
        CanDelete BIT    NOT NULL DEFAULT (0),
        PRIMARY KEY CLUSTERED (MenuId)
    );
    PRINT 'Created missing type PUMP.udt_RoleMenuType.';
END
GO

IF EXISTS (SELECT 1 FROM sys.types t JOIN sys.schemas s ON s.schema_id = t.schema_id
           WHERE s.name = N'PUMP' AND t.name = N'udt_RoleMenuType')
    GRANT EXECUTE ON TYPE::PUMP.udt_RoleMenuType TO PUBLIC;
GO

PRINT '=== PART 1: base schema ===';
GO

/****** Object:  Table [PUMP].[CashTransactions]    Script Date: 02-08-2026 10:56:35 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[CashTransactions]','U') IS NULL
CREATE TABLE [PUMP].[CashTransactions](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[OwnerId] [bigint] NOT NULL,
	[PumpId] [bigint] NOT NULL,
	[ShiftId] [bigint] NULL,
	[TxnType] [nvarchar](20) NOT NULL,
	[Amount] [decimal](18, 2) NOT NULL,
	[ReferenceNo] [nvarchar](50) NULL,
	[Narration] [nvarchar](250) NULL,
	[TxnDateTime] [datetime2](7) NOT NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[CouponBooks]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[CouponBooks]','U') IS NULL
CREATE TABLE [PUMP].[CouponBooks](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[OwnerId] [bigint] NOT NULL,
	[PumpId] [bigint] NOT NULL,
	[BookCode] [nvarchar](50) NOT NULL,
	[Denomination] [decimal](18, 2) NOT NULL,
	[TotalCoupons] [int] NOT NULL,
	[IssuedToPartyId] [bigint] NULL,
	[StartSerial] [int] NOT NULL,
	[EndSerial] [int] NOT NULL,
	[IsActive] [bit] NOT NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[CouponTransactions]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[CouponTransactions]','U') IS NULL
CREATE TABLE [PUMP].[CouponTransactions](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[OwnerId] [bigint] NOT NULL,
	[PumpId] [bigint] NOT NULL,
	[CouponBookId] [bigint] NOT NULL,
	[PartyId] [bigint] NULL,
	[SalesHeaderId] [bigint] NULL,
	[CouponSerialNo] [int] NOT NULL,
	[Amount] [decimal](18, 2) NOT NULL,
	[TxnDateTime] [datetime2](7) NOT NULL,
	[Notes] [nvarchar](250) NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[DipReadings]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[DipReadings]','U') IS NULL
CREATE TABLE [PUMP].[DipReadings](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[OwnerId] [bigint] NOT NULL,
	[PumpId] [bigint] NOT NULL,
	[TankId] [bigint] NOT NULL,
	[ReadingDate] [date] NOT NULL,
	[ShiftId] [bigint] NULL,
	[DipCm] [decimal](10, 2) NOT NULL,
	[WaterDipCm] [decimal](10, 2) NULL,
	[Density] [decimal](10, 4) NULL,
	[Temperature] [decimal](10, 2) NULL,
	[ExpectedStock] [decimal](18, 2) NOT NULL,
	[ActualStock] [decimal](18, 2) NOT NULL,
	[Variance] [decimal](18, 2) NOT NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
	[UpdatedOn] [datetime2](7) NULL,
	[IsActive] [bit] NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[Employees]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[Employees]','U') IS NULL
CREATE TABLE [PUMP].[Employees](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[OwnerId] [bigint] NOT NULL,
	[PumpId] [bigint] NOT NULL,
	[UserId] [bigint] NULL,
	[EmployeeCode] [nvarchar](30) NOT NULL,
	[FullName] [nvarchar](150) NOT NULL,
	[Mobile] [nvarchar](20) NULL,
	[JoinDate] [date] NOT NULL,
	[Designation] [nvarchar](80) NULL,
	[MonthlySalary] [decimal](18, 2) NOT NULL,
	[IsActive] [bit] NOT NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
	[UpdatedOn] [datetime2](7) NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[ExpenseHeads]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[ExpenseHeads]','U') IS NULL
CREATE TABLE [PUMP].[ExpenseHeads](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[OwnerId] [bigint] NOT NULL,
	[PumpId] [bigint] NOT NULL,
	[HeadName] [nvarchar](150) NOT NULL,
	[IsActive] [bit] NOT NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
	[UpdatedOn] [datetime2](7) NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[ExpenseTransactions]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[ExpenseTransactions]','U') IS NULL
CREATE TABLE [PUMP].[ExpenseTransactions](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[OwnerId] [bigint] NOT NULL,
	[PumpId] [bigint] NOT NULL,
	[ShiftId] [bigint] NULL,
	[ExpenseHeadId] [bigint] NOT NULL,
	[Amount] [decimal](18, 2) NOT NULL,
	[PaymentMode] [nvarchar](30) NOT NULL,
	[ReferenceNo] [nvarchar](50) NULL,
	[Narration] [nvarchar](250) NULL,
	[TxnDateTime] [datetime2](7) NOT NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[FleetContracts]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[FleetContracts]','U') IS NULL
CREATE TABLE [PUMP].[FleetContracts](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[OwnerId] [bigint] NOT NULL,
	[PumpId] [bigint] NOT NULL,
	[PartyId] [bigint] NOT NULL,
	[ProductId] [bigint] NOT NULL,
	[ContractRate] [decimal](18, 2) NOT NULL,
	[ValidFrom] [date] NOT NULL,
	[ValidTo] [date] NULL,
	[IsActive] [bit] NOT NULL,
	[Notes] [nvarchar](250) NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
	[UpdatedOn] [datetime2](7) NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[Menus]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[Menus]','U') IS NULL
CREATE TABLE [PUMP].[Menus](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[ParentId] [bigint] NULL,
	[MenuName] [nvarchar](120) NOT NULL,
	[Route] [nvarchar](200) NOT NULL,
	[Icon] [nvarchar](100) NULL,
	[Sequence] [int] NOT NULL,
	[IsVisible] [bit] NOT NULL,
	[IsActive] [bit] NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[Nozzles]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[Nozzles]','U') IS NULL
CREATE TABLE [PUMP].[Nozzles](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[OwnerId] [bigint] NOT NULL,
	[PumpId] [bigint] NOT NULL,
	[ProductId] [bigint] NOT NULL,
	[NozzleCode] [nvarchar](30) NOT NULL,
	[IsActive] [bit] NOT NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
	[TankId] [bigint] NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[NumberSeries]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[NumberSeries]','U') IS NULL
CREATE TABLE [PUMP].[NumberSeries](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[OwnerId] [bigint] NOT NULL,
	[PumpId] [bigint] NOT NULL,
	[SeriesKey] [nvarchar](50) NOT NULL,
	[FinancialYear] [nvarchar](9) NOT NULL,
	[Prefix] [nvarchar](20) NOT NULL,
	[LastNumber] [bigint] NOT NULL,
	[PaddingLength] [int] NOT NULL,
	[IsActive] [bit] NOT NULL,
	[UpdatedOn] [datetime2](7) NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[Owners]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[Owners]','U') IS NULL
CREATE TABLE [PUMP].[Owners](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[Name] [nvarchar](200) NOT NULL,
	[IsActive] [bit] NOT NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[Parties]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[Parties]','U') IS NULL
CREATE TABLE [PUMP].[Parties](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[OwnerId] [bigint] NOT NULL,
	[PumpId] [bigint] NOT NULL,
	[PartyName] [nvarchar](150) NOT NULL,
	[PartyType] [nvarchar](50) NOT NULL,
	[Address] [nvarchar](250) NULL,
	[Mobile] [nvarchar](20) NULL,
	[Email] [nvarchar](100) NULL,
	[GSTIN] [nvarchar](20) NULL,
	[CreditLimit] [decimal](18, 2) NOT NULL,
	[CurrentBalance] [decimal](18, 2) NOT NULL,
	[IsActive] [bit] NOT NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
	[UpdatedOn] [datetime2](7) NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[PartyLedger]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[PartyLedger]','U') IS NULL
CREATE TABLE [PUMP].[PartyLedger](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[OwnerId] [bigint] NOT NULL,
	[PumpId] [bigint] NOT NULL,
	[PartyId] [bigint] NOT NULL,
	[EntryType] [nvarchar](30) NOT NULL,
	[Amount] [decimal](18, 2) NOT NULL,
	[EntryDateTime] [datetime2](7) NOT NULL,
	[ReferenceNo] [nvarchar](50) NULL,
	[Notes] [nvarchar](250) NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[Permissions]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[Permissions]','U') IS NULL
CREATE TABLE [PUMP].[Permissions](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[PermissionCode] [nvarchar](100) NOT NULL,
	[Name] [nvarchar](200) NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[ProductRateHistory]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[ProductRateHistory]','U') IS NULL
CREATE TABLE [PUMP].[ProductRateHistory](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[ProductId] [bigint] NOT NULL,
	[OldRate] [decimal](18, 2) NOT NULL,
	[NewRate] [decimal](18, 2) NOT NULL,
	[ChangedAt] [datetime] NOT NULL,
	[ChangedBy] [bigint] NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[Products]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[Products]','U') IS NULL
CREATE TABLE [PUMP].[Products](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[OwnerId] [bigint] NOT NULL,
	[PumpId] [bigint] NOT NULL,
	[Name] [nvarchar](200) NOT NULL,
	[Category] [nvarchar](50) NOT NULL,
	[Unit] [nvarchar](20) NOT NULL,
	[CurrentRate] [decimal](18, 2) NOT NULL,
	[IsActive] [bit] NOT NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
	[UpdatedOn] [datetime2](7) NULL,
	[HSNCode] [nvarchar](20) NULL,
	[CGSTRate] [decimal](5, 2) NOT NULL,
	[SGSTRate] [decimal](5, 2) NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[Pumps]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[Pumps]','U') IS NULL
CREATE TABLE [PUMP].[Pumps](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[OwnerId] [bigint] NOT NULL,
	[Name] [nvarchar](200) NOT NULL,
	[City] [nvarchar](100) NULL,
	[IsActive] [bit] NOT NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
	[Address] [nvarchar](300) NULL,
	[ContactNo] [nvarchar](20) NULL,
	[GSTIN] [nvarchar](20) NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[PurchaseDetails]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[PurchaseDetails]','U') IS NULL
CREATE TABLE [PUMP].[PurchaseDetails](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[PurchaseHeaderId] [bigint] NOT NULL,
	[ProductId] [bigint] NOT NULL,
	[TankId] [bigint] NULL,
	[Quantity] [decimal](18, 3) NOT NULL,
	[Rate] [decimal](18, 4) NULL,
	[Amount] [decimal](18, 2) NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[PurchaseHeaders]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[PurchaseHeaders]','U') IS NULL
CREATE TABLE [PUMP].[PurchaseHeaders](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[OwnerId] [bigint] NOT NULL,
	[PumpId] [bigint] NOT NULL,
	[VendorId] [bigint] NOT NULL,
	[InvoiceNo] [nvarchar](50) NOT NULL,
	[InvoiceDate] [date] NOT NULL,
	[VehicleNo] [nvarchar](30) NULL,
	[DriverName] [nvarchar](120) NULL,
	[TotalAmount] [decimal](18, 2) NOT NULL,
	[Notes] [nvarchar](250) NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[Receipts]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[Receipts]','U') IS NULL
CREATE TABLE [PUMP].[Receipts](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[SalesHeaderId] [bigint] NOT NULL,
	[ReceiptNo] [nvarchar](50) NOT NULL,
	[ReceiptDateTime] [datetime2](7) NOT NULL,
	[PrintCount] [int] NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[RoleMenus]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[RoleMenus]','U') IS NULL
CREATE TABLE [PUMP].[RoleMenus](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[RoleId] [bigint] NOT NULL,
	[MenuId] [bigint] NOT NULL,
	[CanView] [bit] NOT NULL,
	[CanCreate] [bit] NOT NULL,
	[CanEdit] [bit] NOT NULL,
	[CanDelete] [bit] NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[Roles]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[Roles]','U') IS NULL
CREATE TABLE [PUMP].[Roles](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[OwnerId] [bigint] NOT NULL,
	[Name] [nvarchar](100) NOT NULL,
	[IsSystem] [bit] NOT NULL,
	[IsActive] [bit] NOT NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[SalaryPayments]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[SalaryPayments]','U') IS NULL
CREATE TABLE [PUMP].[SalaryPayments](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[OwnerId] [bigint] NOT NULL,
	[PumpId] [bigint] NOT NULL,
	[EmployeeId] [bigint] NOT NULL,
	[SalaryYear] [int] NOT NULL,
	[SalaryMonth] [int] NOT NULL,
	[Amount] [decimal](18, 2) NOT NULL,
	[PaidOn] [date] NOT NULL,
	[PaymentMode] [nvarchar](20) NOT NULL,
	[ReferenceNo] [nvarchar](60) NULL,
	[Notes] [nvarchar](250) NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
	[UpdatedOn] [datetime2](7) NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[SalesDetails]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[SalesDetails]','U') IS NULL
CREATE TABLE [PUMP].[SalesDetails](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[SalesHeaderId] [bigint] NOT NULL,
	[ProductId] [bigint] NOT NULL,
	[NozzleNo] [nvarchar](30) NULL,
	[Quantity] [decimal](18, 3) NOT NULL,
	[Rate] [decimal](18, 2) NOT NULL,
	[Amount] [decimal](18, 2) NOT NULL,
	[BaseAmount] [decimal](18, 2) NOT NULL,
	[CGSTAmount] [decimal](18, 2) NOT NULL,
	[SGSTAmount] [decimal](18, 2) NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[SalesHeaders]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[SalesHeaders]','U') IS NULL
CREATE TABLE [PUMP].[SalesHeaders](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[OwnerId] [bigint] NOT NULL,
	[PumpId] [bigint] NOT NULL,
	[ShiftId] [bigint] NOT NULL,
	[PartyId] [bigint] NULL,
	[BillNo] [nvarchar](50) NOT NULL,
	[BillDateTime] [datetime2](7) NOT NULL,
	[PaymentMode] [nvarchar](30) NOT NULL,
	[VehicleNo] [nvarchar](30) NULL,
	[CustomerName] [nvarchar](120) NULL,
	[AttendantName] [nvarchar](120) NULL,
	[TotalAmount] [decimal](18, 2) NOT NULL,
	[InvoiceNo] [nvarchar](50) NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[ShiftHeaders]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[ShiftHeaders]','U') IS NULL
CREATE TABLE [PUMP].[ShiftHeaders](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[OwnerId] [bigint] NOT NULL,
	[PumpId] [bigint] NOT NULL,
	[ShiftDate] [date] NOT NULL,
	[ShiftCode] [nvarchar](30) NOT NULL,
	[OpeningCash] [decimal](18, 2) NOT NULL,
	[ClosingCash] [decimal](18, 2) NULL,
	[Notes] [nvarchar](500) NULL,
	[OpenedOn] [datetime2](7) NOT NULL,
	[ClosedOn] [datetime2](7) NULL,
	[Status] [nvarchar](30) NOT NULL,
	[OperatorUserId] [bigint] NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[ShiftNozzleReadings]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[ShiftNozzleReadings]','U') IS NULL
CREATE TABLE [PUMP].[ShiftNozzleReadings](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[OwnerId] [bigint] NOT NULL,
	[PumpId] [bigint] NOT NULL,
	[ShiftId] [bigint] NOT NULL,
	[NozzleId] [bigint] NOT NULL,
	[ProductId] [bigint] NOT NULL,
	[OpeningReading] [decimal](18, 3) NOT NULL,
	[ClosingReading] [decimal](18, 3) NULL,
	[Rate] [decimal](18, 2) NOT NULL,
	[SoldQty] [decimal](18, 3) NOT NULL,
	[SoldAmount] [decimal](18, 2) NOT NULL,
	[VarianceQty] [decimal](18, 3) NOT NULL,
	[Notes] [nvarchar](250) NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
	[UpdatedOn] [datetime2](7) NULL,
	[TestingLoss] [decimal](18, 3) NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[StockReconciliations]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[StockReconciliations]','U') IS NULL
CREATE TABLE [PUMP].[StockReconciliations](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[OwnerId] [bigint] NOT NULL,
	[PumpId] [bigint] NOT NULL,
	[TankId] [bigint] NOT NULL,
	[ReconciliationDate] [date] NOT NULL,
	[BookStock] [decimal](18, 3) NOT NULL,
	[PhysicalStock] [decimal](18, 3) NOT NULL,
	[VarianceQty] [decimal](18, 3) NOT NULL,
	[Reason] [nvarchar](250) NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[Tanks]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[Tanks]','U') IS NULL
CREATE TABLE [PUMP].[Tanks](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[OwnerId] [bigint] NOT NULL,
	[PumpId] [bigint] NOT NULL,
	[Name] [nvarchar](120) NOT NULL,
	[ProductId] [bigint] NOT NULL,
	[Capacity] [decimal](18, 2) NOT NULL,
	[SafeFillLevel] [decimal](18, 2) NOT NULL,
	[CurrentStock] [decimal](18, 2) NOT NULL,
	[IsActive] [bit] NOT NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
	[UpdatedOn] [datetime2](7) NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[TankTransactions]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[TankTransactions]','U') IS NULL
CREATE TABLE [PUMP].[TankTransactions](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[OwnerId] [bigint] NOT NULL,
	[PumpId] [bigint] NOT NULL,
	[TankId] [bigint] NOT NULL,
	[TxnType] [nvarchar](30) NOT NULL,
	[Quantity] [decimal](18, 2) NOT NULL,
	[TxnDateTime] [datetime2](7) NOT NULL,
	[ReferenceNo] [nvarchar](50) NULL,
	[Notes] [nvarchar](250) NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[TestingLosses]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[TestingLosses]','U') IS NULL
CREATE TABLE [PUMP].[TestingLosses](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[OwnerId] [bigint] NOT NULL,
	[PumpId] [bigint] NOT NULL,
	[ProductId] [bigint] NOT NULL,
	[TankId] [bigint] NOT NULL,
	[LossDate] [date] NOT NULL,
	[ShiftId] [bigint] NULL,
	[LossType] [nvarchar](50) NOT NULL,
	[Quantity] [decimal](18, 2) NOT NULL,
	[Notes] [nvarchar](250) NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
	[IsActive] [bit] NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[UserRefreshTokens]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[UserRefreshTokens]','U') IS NULL
CREATE TABLE [PUMP].[UserRefreshTokens](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[UserId] [bigint] NOT NULL,
	[TokenHash] [nvarchar](128) NOT NULL,
	[ExpiresOnUtc] [datetime2](7) NOT NULL,
	[CreatedOnUtc] [datetime2](7) NOT NULL,
	[RevokedOnUtc] [datetime2](7) NULL,
	[ReplacedByTokenHash] [nvarchar](128) NULL,
	[RevokeReason] [nvarchar](200) NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[UserRoles]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[UserRoles]','U') IS NULL
CREATE TABLE [PUMP].[UserRoles](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[UserId] [bigint] NOT NULL,
	[RoleId] [bigint] NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[Users]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[Users]','U') IS NULL
CREATE TABLE [PUMP].[Users](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[OwnerId] [bigint] NOT NULL,
	[FullName] [nvarchar](200) NOT NULL,
	[Username] [nvarchar](100) NOT NULL,
	[PasswordHash] [nvarchar](500) NOT NULL,
	[Mobile] [nvarchar](20) NULL,
	[IsActive] [bit] NOT NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
	[IsSuperAdmin] [bit] NOT NULL,
	[IsOwner] [bit] NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [PUMP].[Vendors]    Script Date: 02-08-2026 10:56:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('PUMP.[Vendors]','U') IS NULL
CREATE TABLE [PUMP].[Vendors](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[OwnerId] [bigint] NOT NULL,
	[PumpId] [bigint] NOT NULL,
	[VendorName] [nvarchar](200) NOT NULL,
	[ContactNo] [nvarchar](20) NULL,
	[GSTIN] [nvarchar](20) NULL,
	[Address] [nvarchar](300) NULL,
	[IsActive] [bit] NOT NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
	[UpdatedOn] [datetime2](7) NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
GO
GO
GO
GO
GO
GO
GO
GO
/* ==========================================================================================
   BOOTSTRAP DATA — sirf itna hi, aur kuch nahi
   ------------------------------------------------------------------------------------------
   (2026-09-05) Pehle yahan poora demo pump pada tha: "Vikash Filling Center", uske
   products, tanks, nozzles, employees, parties, vendors, purani shift/sale/cash ki
   entries, aur 124 purane refresh token. Naye customer ke DB me wo sab bekaar tha
   (aur uljhan bhi — log demo data ko apna samajh lete the).

   AB SIRF DO CHEEZEIN BANTI HAIN:

     1. MENUS — ye data nahi, app ka dhaancha hai. sp_Owner_Create naya tenant
        banate waqt inhi menus se uske Admin role ki permission banata hai. Menus
        na hon to naye tenant ko koi screen dikhegi hi nahi.

     2. SYSTEM OWNER + SUPERADMIN LOGIN — DB me ghusne ka ekmatra rasta. Users.OwnerId
        par Owners ki FK hai, isliye superadmin ke liye ek Owner row rakhni hi padti
        hai. Wo row koi pump nahi hai — uska koi pump, product ya data nahi hota.

   BAAKI SAB KHAALI HAI. Pehla asli tenant do me se kisi bhi tarah se banega:
     - superadmin se login -> Super Admin -> Create Tenant, ya
     - login page par "7 din free trial" wala self signup
   Dono `sp_Owner_Create` chalate hain, jo owner + Admin role + admin user +
   RoleMenus + pehla pump — sab ek saath bana deta hai.
   ========================================================================================== */
GO

PRINT '';
PRINT '--- Bootstrap data (menus + superadmin) ---';
GO

SET IDENTITY_INSERT [PUMP].[Menus] ON 
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 1) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (1, NULL, N'Dashboard', N'/dashboard', N'dashboard', 1, 1, 1)
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 2) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (2, NULL, N'Pumps', N'/pump', N'local_gas_station', 2, 1, 1)
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 3) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (3, NULL, N'Nozzles', N'/nozzle', N'tune', 4, 1, 1)
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 4) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (4, NULL, N'Products', N'/products', N'inventory', 2, 1, 1)
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 5) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (5, NULL, N'Tanks', N'/tank', N'water_drop', 3, 1, 1)
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 6) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (6, NULL, N'Parties', N'/party', N'business', 5, 1, 1)
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 7) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (7, NULL, N'Sales', N'/sales', N'point_of_sale', 6, 1, 1)
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 8) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (8, NULL, N'Shift', N'/shift', N'schedule', 7, 1, 1)
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 9) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (9, NULL, N'Tank Stock', N'/tank-stock', N'inventory_2', 8, 1, 1)
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 10) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (10, NULL, N'Party Ledger', N'/party-ledger', N'receipt_long', 9, 1, 1)
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 11) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (11, NULL, N'Reports', N'/reports', N'bar_chart', 10, 1, 1)
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 12) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (12, NULL, N'Users', N'/users', N'group', 11, 1, 1)
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 13) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (13, NULL, N'Roles', N'/roles', N'admin_panel_settings', 12, 1, 1)
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 14) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (14, NULL, N'Purchase', N'/purchase', N'local_shipping', 10, 1, 1)
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 15) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (15, NULL, N'Stock Reconcile', N'/stock-reconcile', N'rule', 11, 1, 1)
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 16) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (16, NULL, N'Cashbook', N'/cashbook', N'payments', 12, 1, 1)
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 17) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (17, NULL, N'Expenses', N'/expenses', N'money_off', 13, 1, 1)
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 18) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (18, NULL, N'Day Book', N'/day-book', N'menu_book', 14, 1, 1)
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 19) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (19, NULL, N'Fleet Contracts', N'/fleet-contracts', N'commute', 15, 1, 1)
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 20) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (20, NULL, N'Coupon Books', N'/coupon-books', N'confirmation_number', 16, 1, 1)
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 21) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (21, NULL, N'Outstanding', N'/outstanding', N'account_balance', 20, 1, 1)
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 22) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (22, NULL, N'Pump Comparison', N'/pump-comparison', N'compare_arrows', 21, 1, 1)
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 23) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (23, NULL, N'Employees', N'/employees', N'badge', 20, 1, 1)
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 24) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (24, NULL, N'Salary Register', N'/salary', N'payments', 21, 1, 1)
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 25) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (25, NULL, N'Dip & Testing', N'/dip-testing', N'science', 22, 1, 1)
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 26) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (26, NULL, N'Daily Stock Register', N'/daily-stock-register', N'assignment', 22, 1, 1)
GO
IF NOT EXISTS (SELECT 1 FROM [PUMP].[Menus] WHERE [Id] = 27) INSERT [PUMP].[Menus] ([Id], [ParentId], [MenuName], [Route], [Icon], [Sequence], [IsVisible], [IsActive]) VALUES (27, NULL, N'Vendors', N'/vendors', N'storefront', 10, 1, 1)
GO
SET IDENTITY_INSERT [PUMP].[Menus] OFF
GO

/* System owner + superadmin FILE KE ANT me bante hain (Section N).

   Yahan nahi ban sakte: Owners.ValidUpto column PART 2 me add hota hai, aur uske
   bina naya owner login hi nahi kar paata. Yahan likhne par CREATE ke waqt hi
   "Invalid column name 'ValidUpto'" aa jaata tha — bilkul wahi galti jo
   fn_ProductRateOnDate ke saath hui thi. Isliye jo bhi cheez PART 2 me bane
   column/table ko chhuti hai, wo file ke ANT me hi likhni hai. */
GO

GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [UQ_PUMP_NumberSeries]    Script Date: 02-08-2026 10:56:38 ******/
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'UQ_PUMP_NumberSeries' AND parent_object_id = OBJECT_ID('PUMP.[NumberSeries]'))
ALTER TABLE [PUMP].[NumberSeries] ADD  CONSTRAINT [UQ_PUMP_NumberSeries] UNIQUE NONCLUSTERED 
(
	[OwnerId] ASC,
	[PumpId] ASC,
	[SeriesKey] ASC,
	[FinancialYear] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [UQ__Permissi__91FE575036035882]    Script Date: 02-08-2026 10:56:38 ******/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('PUMP.[Permissions]') AND is_unique = 1 AND is_primary_key = 0)
ALTER TABLE [PUMP].[Permissions] ADD UNIQUE NONCLUSTERED 
(
	[PermissionCode] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
/****** Object:  Index [UQ__Receipts__E911B86165BD9EDE]    Script Date: 02-08-2026 10:56:38 ******/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('PUMP.[Receipts]') AND is_unique = 1 AND is_primary_key = 0)
ALTER TABLE [PUMP].[Receipts] ADD UNIQUE NONCLUSTERED 
(
	[SalesHeaderId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [UQ__Users__536C85E455E9B32A]    Script Date: 02-08-2026 10:56:38 ******/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('PUMP.[Users]') AND is_unique = 1 AND is_primary_key = 0)
ALTER TABLE [PUMP].[Users] ADD UNIQUE NONCLUSTERED 
(
	[Username] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_CashTransactions_TxnDateTime_IST' AND parent_object_id = OBJECT_ID('PUMP.[CashTransactions]'))
ALTER TABLE [PUMP].[CashTransactions] ADD  CONSTRAINT [DF_CashTransactions_TxnDateTime_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [TxnDateTime]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_CashTransactions_CreatedOn_IST' AND parent_object_id = OBJECT_ID('PUMP.[CashTransactions]'))
ALTER TABLE [PUMP].[CashTransactions] ADD  CONSTRAINT [DF_CashTransactions_CreatedOn_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [CreatedOn]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_PUMP_CouponBooks_IsActive' AND parent_object_id = OBJECT_ID('PUMP.[CouponBooks]'))
ALTER TABLE [PUMP].[CouponBooks] ADD  CONSTRAINT [DF_PUMP_CouponBooks_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_CouponBooks_CreatedOn_IST' AND parent_object_id = OBJECT_ID('PUMP.[CouponBooks]'))
ALTER TABLE [PUMP].[CouponBooks] ADD  CONSTRAINT [DF_CouponBooks_CreatedOn_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [CreatedOn]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_CouponTransactions_TxnDateTime_IST' AND parent_object_id = OBJECT_ID('PUMP.[CouponTransactions]'))
ALTER TABLE [PUMP].[CouponTransactions] ADD  CONSTRAINT [DF_CouponTransactions_TxnDateTime_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [TxnDateTime]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[DipReadings]') AND c.name = 'ExpectedStock')
ALTER TABLE [PUMP].[DipReadings] ADD  DEFAULT ((0)) FOR [ExpectedStock]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[DipReadings]') AND c.name = 'ActualStock')
ALTER TABLE [PUMP].[DipReadings] ADD  DEFAULT ((0)) FOR [ActualStock]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[DipReadings]') AND c.name = 'Variance')
ALTER TABLE [PUMP].[DipReadings] ADD  DEFAULT ((0)) FOR [Variance]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_DipReadings_CreatedOn_IST' AND parent_object_id = OBJECT_ID('PUMP.[DipReadings]'))
ALTER TABLE [PUMP].[DipReadings] ADD  CONSTRAINT [DF_DipReadings_CreatedOn_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [CreatedOn]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[DipReadings]') AND c.name = 'IsActive')
ALTER TABLE [PUMP].[DipReadings] ADD  DEFAULT ((1)) FOR [IsActive]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_PUMP_Employees_MonthlySalary' AND parent_object_id = OBJECT_ID('PUMP.[Employees]'))
ALTER TABLE [PUMP].[Employees] ADD  CONSTRAINT [DF_PUMP_Employees_MonthlySalary]  DEFAULT ((0)) FOR [MonthlySalary]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_PUMP_Employees_IsActive' AND parent_object_id = OBJECT_ID('PUMP.[Employees]'))
ALTER TABLE [PUMP].[Employees] ADD  CONSTRAINT [DF_PUMP_Employees_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_Employees_CreatedOn_IST' AND parent_object_id = OBJECT_ID('PUMP.[Employees]'))
ALTER TABLE [PUMP].[Employees] ADD  CONSTRAINT [DF_Employees_CreatedOn_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [CreatedOn]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_PUMP_ExpenseHeads_IsActive' AND parent_object_id = OBJECT_ID('PUMP.[ExpenseHeads]'))
ALTER TABLE [PUMP].[ExpenseHeads] ADD  CONSTRAINT [DF_PUMP_ExpenseHeads_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_ExpenseHeads_CreatedOn_IST' AND parent_object_id = OBJECT_ID('PUMP.[ExpenseHeads]'))
ALTER TABLE [PUMP].[ExpenseHeads] ADD  CONSTRAINT [DF_ExpenseHeads_CreatedOn_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [CreatedOn]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_ExpenseTransactions_TxnDateTime_IST' AND parent_object_id = OBJECT_ID('PUMP.[ExpenseTransactions]'))
ALTER TABLE [PUMP].[ExpenseTransactions] ADD  CONSTRAINT [DF_ExpenseTransactions_TxnDateTime_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [TxnDateTime]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_ExpenseTransactions_CreatedOn_IST' AND parent_object_id = OBJECT_ID('PUMP.[ExpenseTransactions]'))
ALTER TABLE [PUMP].[ExpenseTransactions] ADD  CONSTRAINT [DF_ExpenseTransactions_CreatedOn_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [CreatedOn]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_PUMP_FleetContracts_IsActive' AND parent_object_id = OBJECT_ID('PUMP.[FleetContracts]'))
ALTER TABLE [PUMP].[FleetContracts] ADD  CONSTRAINT [DF_PUMP_FleetContracts_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_FleetContracts_CreatedOn_IST' AND parent_object_id = OBJECT_ID('PUMP.[FleetContracts]'))
ALTER TABLE [PUMP].[FleetContracts] ADD  CONSTRAINT [DF_FleetContracts_CreatedOn_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [CreatedOn]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[Menus]') AND c.name = 'Sequence')
ALTER TABLE [PUMP].[Menus] ADD  DEFAULT ((1)) FOR [Sequence]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[Menus]') AND c.name = 'IsVisible')
ALTER TABLE [PUMP].[Menus] ADD  DEFAULT ((1)) FOR [IsVisible]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[Menus]') AND c.name = 'IsActive')
ALTER TABLE [PUMP].[Menus] ADD  DEFAULT ((1)) FOR [IsActive]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[Nozzles]') AND c.name = 'IsActive')
ALTER TABLE [PUMP].[Nozzles] ADD  DEFAULT ((1)) FOR [IsActive]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_Nozzles_CreatedOn_IST' AND parent_object_id = OBJECT_ID('PUMP.[Nozzles]'))
ALTER TABLE [PUMP].[Nozzles] ADD  CONSTRAINT [DF_Nozzles_CreatedOn_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [CreatedOn]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_PUMP_NumberSeries_LastNumber' AND parent_object_id = OBJECT_ID('PUMP.[NumberSeries]'))
ALTER TABLE [PUMP].[NumberSeries] ADD  CONSTRAINT [DF_PUMP_NumberSeries_LastNumber]  DEFAULT ((0)) FOR [LastNumber]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_PUMP_NumberSeries_PaddingLength' AND parent_object_id = OBJECT_ID('PUMP.[NumberSeries]'))
ALTER TABLE [PUMP].[NumberSeries] ADD  CONSTRAINT [DF_PUMP_NumberSeries_PaddingLength]  DEFAULT ((6)) FOR [PaddingLength]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_PUMP_NumberSeries_IsActive' AND parent_object_id = OBJECT_ID('PUMP.[NumberSeries]'))
ALTER TABLE [PUMP].[NumberSeries] ADD  CONSTRAINT [DF_PUMP_NumberSeries_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_NumberSeries_UpdatedOn_IST' AND parent_object_id = OBJECT_ID('PUMP.[NumberSeries]'))
ALTER TABLE [PUMP].[NumberSeries] ADD  CONSTRAINT [DF_NumberSeries_UpdatedOn_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [UpdatedOn]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[Owners]') AND c.name = 'IsActive')
ALTER TABLE [PUMP].[Owners] ADD  DEFAULT ((1)) FOR [IsActive]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_Owners_CreatedOn_IST' AND parent_object_id = OBJECT_ID('PUMP.[Owners]'))
ALTER TABLE [PUMP].[Owners] ADD  CONSTRAINT [DF_Owners_CreatedOn_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [CreatedOn]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_PUMP_Parties_CreditLimit' AND parent_object_id = OBJECT_ID('PUMP.[Parties]'))
ALTER TABLE [PUMP].[Parties] ADD  CONSTRAINT [DF_PUMP_Parties_CreditLimit]  DEFAULT ((0)) FOR [CreditLimit]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_PUMP_Parties_CurrentBalance' AND parent_object_id = OBJECT_ID('PUMP.[Parties]'))
ALTER TABLE [PUMP].[Parties] ADD  CONSTRAINT [DF_PUMP_Parties_CurrentBalance]  DEFAULT ((0)) FOR [CurrentBalance]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_PUMP_Parties_IsActive' AND parent_object_id = OBJECT_ID('PUMP.[Parties]'))
ALTER TABLE [PUMP].[Parties] ADD  CONSTRAINT [DF_PUMP_Parties_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_Parties_CreatedOn_IST' AND parent_object_id = OBJECT_ID('PUMP.[Parties]'))
ALTER TABLE [PUMP].[Parties] ADD  CONSTRAINT [DF_Parties_CreatedOn_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [CreatedOn]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_PartyLedger_EntryDateTime_IST' AND parent_object_id = OBJECT_ID('PUMP.[PartyLedger]'))
ALTER TABLE [PUMP].[PartyLedger] ADD  CONSTRAINT [DF_PartyLedger_EntryDateTime_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [EntryDateTime]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_PartyLedger_CreatedOn_IST' AND parent_object_id = OBJECT_ID('PUMP.[PartyLedger]'))
ALTER TABLE [PUMP].[PartyLedger] ADD  CONSTRAINT [DF_PartyLedger_CreatedOn_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [CreatedOn]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[ProductRateHistory]') AND c.name = 'ChangedAt')
ALTER TABLE [PUMP].[ProductRateHistory] ADD  DEFAULT (getdate()) FOR [ChangedAt]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[Products]') AND c.name = 'IsActive')
ALTER TABLE [PUMP].[Products] ADD  DEFAULT ((1)) FOR [IsActive]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_Products_CreatedOn_IST' AND parent_object_id = OBJECT_ID('PUMP.[Products]'))
ALTER TABLE [PUMP].[Products] ADD  CONSTRAINT [DF_Products_CreatedOn_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [CreatedOn]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[Products]') AND c.name = 'CGSTRate')
ALTER TABLE [PUMP].[Products] ADD  DEFAULT ((0)) FOR [CGSTRate]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[Products]') AND c.name = 'SGSTRate')
ALTER TABLE [PUMP].[Products] ADD  DEFAULT ((0)) FOR [SGSTRate]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[Pumps]') AND c.name = 'IsActive')
ALTER TABLE [PUMP].[Pumps] ADD  DEFAULT ((1)) FOR [IsActive]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_Pumps_CreatedOn_IST' AND parent_object_id = OBJECT_ID('PUMP.[Pumps]'))
ALTER TABLE [PUMP].[Pumps] ADD  CONSTRAINT [DF_Pumps_CreatedOn_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [CreatedOn]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_PurchaseHeaders_CreatedOn_IST' AND parent_object_id = OBJECT_ID('PUMP.[PurchaseHeaders]'))
ALTER TABLE [PUMP].[PurchaseHeaders] ADD  CONSTRAINT [DF_PurchaseHeaders_CreatedOn_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [CreatedOn]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_Receipts_ReceiptDateTime_IST' AND parent_object_id = OBJECT_ID('PUMP.[Receipts]'))
ALTER TABLE [PUMP].[Receipts] ADD  CONSTRAINT [DF_Receipts_ReceiptDateTime_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [ReceiptDateTime]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[Receipts]') AND c.name = 'PrintCount')
ALTER TABLE [PUMP].[Receipts] ADD  DEFAULT ((0)) FOR [PrintCount]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[RoleMenus]') AND c.name = 'CanView')
ALTER TABLE [PUMP].[RoleMenus] ADD  DEFAULT ((1)) FOR [CanView]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[RoleMenus]') AND c.name = 'CanCreate')
ALTER TABLE [PUMP].[RoleMenus] ADD  DEFAULT ((0)) FOR [CanCreate]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[RoleMenus]') AND c.name = 'CanEdit')
ALTER TABLE [PUMP].[RoleMenus] ADD  DEFAULT ((0)) FOR [CanEdit]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[RoleMenus]') AND c.name = 'CanDelete')
ALTER TABLE [PUMP].[RoleMenus] ADD  DEFAULT ((0)) FOR [CanDelete]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[Roles]') AND c.name = 'IsSystem')
ALTER TABLE [PUMP].[Roles] ADD  DEFAULT ((0)) FOR [IsSystem]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[Roles]') AND c.name = 'IsActive')
ALTER TABLE [PUMP].[Roles] ADD  DEFAULT ((1)) FOR [IsActive]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_Roles_CreatedOn_IST' AND parent_object_id = OBJECT_ID('PUMP.[Roles]'))
ALTER TABLE [PUMP].[Roles] ADD  CONSTRAINT [DF_Roles_CreatedOn_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [CreatedOn]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_PUMP_SalaryPayments_PaymentMode' AND parent_object_id = OBJECT_ID('PUMP.[SalaryPayments]'))
ALTER TABLE [PUMP].[SalaryPayments] ADD  CONSTRAINT [DF_PUMP_SalaryPayments_PaymentMode]  DEFAULT ('Cash') FOR [PaymentMode]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_SalaryPayments_CreatedOn_IST' AND parent_object_id = OBJECT_ID('PUMP.[SalaryPayments]'))
ALTER TABLE [PUMP].[SalaryPayments] ADD  CONSTRAINT [DF_SalaryPayments_CreatedOn_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [CreatedOn]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[SalesDetails]') AND c.name = 'BaseAmount')
ALTER TABLE [PUMP].[SalesDetails] ADD  DEFAULT ((0)) FOR [BaseAmount]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[SalesDetails]') AND c.name = 'CGSTAmount')
ALTER TABLE [PUMP].[SalesDetails] ADD  DEFAULT ((0)) FOR [CGSTAmount]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[SalesDetails]') AND c.name = 'SGSTAmount')
ALTER TABLE [PUMP].[SalesDetails] ADD  DEFAULT ((0)) FOR [SGSTAmount]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[ShiftHeaders]') AND c.name = 'OpeningCash')
ALTER TABLE [PUMP].[ShiftHeaders] ADD  DEFAULT ((0)) FOR [OpeningCash]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_ShiftHeaders_OpenedOn_IST' AND parent_object_id = OBJECT_ID('PUMP.[ShiftHeaders]'))
ALTER TABLE [PUMP].[ShiftHeaders] ADD  CONSTRAINT [DF_ShiftHeaders_OpenedOn_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [OpenedOn]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[ShiftHeaders]') AND c.name = 'Status')
ALTER TABLE [PUMP].[ShiftHeaders] ADD  DEFAULT ('OPEN') FOR [Status]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_PUMP_ShiftNozzleReadings_Rate' AND parent_object_id = OBJECT_ID('PUMP.[ShiftNozzleReadings]'))
ALTER TABLE [PUMP].[ShiftNozzleReadings] ADD  CONSTRAINT [DF_PUMP_ShiftNozzleReadings_Rate]  DEFAULT ((0)) FOR [Rate]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_PUMP_ShiftNozzleReadings_SoldQty' AND parent_object_id = OBJECT_ID('PUMP.[ShiftNozzleReadings]'))
ALTER TABLE [PUMP].[ShiftNozzleReadings] ADD  CONSTRAINT [DF_PUMP_ShiftNozzleReadings_SoldQty]  DEFAULT ((0)) FOR [SoldQty]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_PUMP_ShiftNozzleReadings_SoldAmount' AND parent_object_id = OBJECT_ID('PUMP.[ShiftNozzleReadings]'))
ALTER TABLE [PUMP].[ShiftNozzleReadings] ADD  CONSTRAINT [DF_PUMP_ShiftNozzleReadings_SoldAmount]  DEFAULT ((0)) FOR [SoldAmount]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_PUMP_ShiftNozzleReadings_VarianceQty' AND parent_object_id = OBJECT_ID('PUMP.[ShiftNozzleReadings]'))
ALTER TABLE [PUMP].[ShiftNozzleReadings] ADD  CONSTRAINT [DF_PUMP_ShiftNozzleReadings_VarianceQty]  DEFAULT ((0)) FOR [VarianceQty]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_ShiftNozzleReadings_CreatedOn_IST' AND parent_object_id = OBJECT_ID('PUMP.[ShiftNozzleReadings]'))
ALTER TABLE [PUMP].[ShiftNozzleReadings] ADD  CONSTRAINT [DF_ShiftNozzleReadings_CreatedOn_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [CreatedOn]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[ShiftNozzleReadings]') AND c.name = 'TestingLoss')
ALTER TABLE [PUMP].[ShiftNozzleReadings] ADD  DEFAULT ((0)) FOR [TestingLoss]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_StockReconciliations_CreatedOn_IST' AND parent_object_id = OBJECT_ID('PUMP.[StockReconciliations]'))
ALTER TABLE [PUMP].[StockReconciliations] ADD  CONSTRAINT [DF_StockReconciliations_CreatedOn_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [CreatedOn]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_PUMP_Tanks_CurrentStock' AND parent_object_id = OBJECT_ID('PUMP.[Tanks]'))
ALTER TABLE [PUMP].[Tanks] ADD  CONSTRAINT [DF_PUMP_Tanks_CurrentStock]  DEFAULT ((0)) FOR [CurrentStock]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_PUMP_Tanks_IsActive' AND parent_object_id = OBJECT_ID('PUMP.[Tanks]'))
ALTER TABLE [PUMP].[Tanks] ADD  CONSTRAINT [DF_PUMP_Tanks_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_Tanks_CreatedOn_IST' AND parent_object_id = OBJECT_ID('PUMP.[Tanks]'))
ALTER TABLE [PUMP].[Tanks] ADD  CONSTRAINT [DF_Tanks_CreatedOn_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [CreatedOn]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_TankTransactions_TxnDateTime_IST' AND parent_object_id = OBJECT_ID('PUMP.[TankTransactions]'))
ALTER TABLE [PUMP].[TankTransactions] ADD  CONSTRAINT [DF_TankTransactions_TxnDateTime_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [TxnDateTime]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_TankTransactions_CreatedOn_IST' AND parent_object_id = OBJECT_ID('PUMP.[TankTransactions]'))
ALTER TABLE [PUMP].[TankTransactions] ADD  CONSTRAINT [DF_TankTransactions_CreatedOn_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [CreatedOn]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_TestingLosses_CreatedOn_IST' AND parent_object_id = OBJECT_ID('PUMP.[TestingLosses]'))
ALTER TABLE [PUMP].[TestingLosses] ADD  CONSTRAINT [DF_TestingLosses_CreatedOn_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [CreatedOn]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[TestingLosses]') AND c.name = 'IsActive')
ALTER TABLE [PUMP].[TestingLosses] ADD  DEFAULT ((1)) FOR [IsActive]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_UserRefreshTokens_CreatedOnUtc_IST' AND parent_object_id = OBJECT_ID('PUMP.[UserRefreshTokens]'))
ALTER TABLE [PUMP].[UserRefreshTokens] ADD  CONSTRAINT [DF_UserRefreshTokens_CreatedOnUtc_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [CreatedOnUtc]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[Users]') AND c.name = 'IsActive')
ALTER TABLE [PUMP].[Users] ADD  DEFAULT ((1)) FOR [IsActive]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_Users_CreatedOn_IST' AND parent_object_id = OBJECT_ID('PUMP.[Users]'))
ALTER TABLE [PUMP].[Users] ADD  CONSTRAINT [DF_Users_CreatedOn_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [CreatedOn]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[Users]') AND c.name = 'IsSuperAdmin')
ALTER TABLE [PUMP].[Users] ADD  DEFAULT ((0)) FOR [IsSuperAdmin]
GO
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id WHERE dc.parent_object_id = OBJECT_ID('PUMP.[Users]') AND c.name = 'IsOwner')
ALTER TABLE [PUMP].[Users] ADD  DEFAULT ((0)) FOR [IsOwner]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_PUMP_Vendors_IsActive' AND parent_object_id = OBJECT_ID('PUMP.[Vendors]'))
ALTER TABLE [PUMP].[Vendors] ADD  CONSTRAINT [DF_PUMP_Vendors_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'DF_Vendors_CreatedOn_IST' AND parent_object_id = OBJECT_ID('PUMP.[Vendors]'))
ALTER TABLE [PUMP].[Vendors] ADD  CONSTRAINT [DF_Vendors_CreatedOn_IST]  DEFAULT (dateadd(minute,(330),getutcdate())) FOR [CreatedOn]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_CashTransactions_Owner' AND parent_object_id = OBJECT_ID('PUMP.[CashTransactions]'))
ALTER TABLE [PUMP].[CashTransactions]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_CashTransactions_Owner] FOREIGN KEY([OwnerId])
REFERENCES [PUMP].[Owners] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_CashTransactions_Owner' AND parent_object_id = OBJECT_ID('PUMP.[CashTransactions]'))
ALTER TABLE [PUMP].[CashTransactions] CHECK CONSTRAINT [FK_PUMP_CashTransactions_Owner]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_CashTransactions_Pump' AND parent_object_id = OBJECT_ID('PUMP.[CashTransactions]'))
ALTER TABLE [PUMP].[CashTransactions]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_CashTransactions_Pump] FOREIGN KEY([PumpId])
REFERENCES [PUMP].[Pumps] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_CashTransactions_Pump' AND parent_object_id = OBJECT_ID('PUMP.[CashTransactions]'))
ALTER TABLE [PUMP].[CashTransactions] CHECK CONSTRAINT [FK_PUMP_CashTransactions_Pump]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_CouponBooks_Owner' AND parent_object_id = OBJECT_ID('PUMP.[CouponBooks]'))
ALTER TABLE [PUMP].[CouponBooks]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_CouponBooks_Owner] FOREIGN KEY([OwnerId])
REFERENCES [PUMP].[Owners] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_CouponBooks_Owner' AND parent_object_id = OBJECT_ID('PUMP.[CouponBooks]'))
ALTER TABLE [PUMP].[CouponBooks] CHECK CONSTRAINT [FK_PUMP_CouponBooks_Owner]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_CouponBooks_Party' AND parent_object_id = OBJECT_ID('PUMP.[CouponBooks]'))
ALTER TABLE [PUMP].[CouponBooks]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_CouponBooks_Party] FOREIGN KEY([IssuedToPartyId])
REFERENCES [PUMP].[Parties] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_CouponBooks_Party' AND parent_object_id = OBJECT_ID('PUMP.[CouponBooks]'))
ALTER TABLE [PUMP].[CouponBooks] CHECK CONSTRAINT [FK_PUMP_CouponBooks_Party]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_CouponBooks_Pump' AND parent_object_id = OBJECT_ID('PUMP.[CouponBooks]'))
ALTER TABLE [PUMP].[CouponBooks]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_CouponBooks_Pump] FOREIGN KEY([PumpId])
REFERENCES [PUMP].[Pumps] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_CouponBooks_Pump' AND parent_object_id = OBJECT_ID('PUMP.[CouponBooks]'))
ALTER TABLE [PUMP].[CouponBooks] CHECK CONSTRAINT [FK_PUMP_CouponBooks_Pump]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_CouponTransactions_Book' AND parent_object_id = OBJECT_ID('PUMP.[CouponTransactions]'))
ALTER TABLE [PUMP].[CouponTransactions]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_CouponTransactions_Book] FOREIGN KEY([CouponBookId])
REFERENCES [PUMP].[CouponBooks] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_CouponTransactions_Book' AND parent_object_id = OBJECT_ID('PUMP.[CouponTransactions]'))
ALTER TABLE [PUMP].[CouponTransactions] CHECK CONSTRAINT [FK_PUMP_CouponTransactions_Book]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_CouponTransactions_Owner' AND parent_object_id = OBJECT_ID('PUMP.[CouponTransactions]'))
ALTER TABLE [PUMP].[CouponTransactions]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_CouponTransactions_Owner] FOREIGN KEY([OwnerId])
REFERENCES [PUMP].[Owners] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_CouponTransactions_Owner' AND parent_object_id = OBJECT_ID('PUMP.[CouponTransactions]'))
ALTER TABLE [PUMP].[CouponTransactions] CHECK CONSTRAINT [FK_PUMP_CouponTransactions_Owner]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_CouponTransactions_Party' AND parent_object_id = OBJECT_ID('PUMP.[CouponTransactions]'))
ALTER TABLE [PUMP].[CouponTransactions]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_CouponTransactions_Party] FOREIGN KEY([PartyId])
REFERENCES [PUMP].[Parties] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_CouponTransactions_Party' AND parent_object_id = OBJECT_ID('PUMP.[CouponTransactions]'))
ALTER TABLE [PUMP].[CouponTransactions] CHECK CONSTRAINT [FK_PUMP_CouponTransactions_Party]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_CouponTransactions_Pump' AND parent_object_id = OBJECT_ID('PUMP.[CouponTransactions]'))
ALTER TABLE [PUMP].[CouponTransactions]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_CouponTransactions_Pump] FOREIGN KEY([PumpId])
REFERENCES [PUMP].[Pumps] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_CouponTransactions_Pump' AND parent_object_id = OBJECT_ID('PUMP.[CouponTransactions]'))
ALTER TABLE [PUMP].[CouponTransactions] CHECK CONSTRAINT [FK_PUMP_CouponTransactions_Pump]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_CouponTransactions_Sales' AND parent_object_id = OBJECT_ID('PUMP.[CouponTransactions]'))
ALTER TABLE [PUMP].[CouponTransactions]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_CouponTransactions_Sales] FOREIGN KEY([SalesHeaderId])
REFERENCES [PUMP].[SalesHeaders] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_CouponTransactions_Sales' AND parent_object_id = OBJECT_ID('PUMP.[CouponTransactions]'))
ALTER TABLE [PUMP].[CouponTransactions] CHECK CONSTRAINT [FK_PUMP_CouponTransactions_Sales]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_DipReadings_Pump' AND parent_object_id = OBJECT_ID('PUMP.[DipReadings]'))
ALTER TABLE [PUMP].[DipReadings]  WITH CHECK ADD  CONSTRAINT [FK_DipReadings_Pump] FOREIGN KEY([PumpId])
REFERENCES [PUMP].[Pumps] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_DipReadings_Pump' AND parent_object_id = OBJECT_ID('PUMP.[DipReadings]'))
ALTER TABLE [PUMP].[DipReadings] CHECK CONSTRAINT [FK_DipReadings_Pump]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_DipReadings_Shift' AND parent_object_id = OBJECT_ID('PUMP.[DipReadings]'))
ALTER TABLE [PUMP].[DipReadings]  WITH CHECK ADD  CONSTRAINT [FK_DipReadings_Shift] FOREIGN KEY([ShiftId])
REFERENCES [PUMP].[ShiftHeaders] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_DipReadings_Shift' AND parent_object_id = OBJECT_ID('PUMP.[DipReadings]'))
ALTER TABLE [PUMP].[DipReadings] CHECK CONSTRAINT [FK_DipReadings_Shift]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_DipReadings_Tank' AND parent_object_id = OBJECT_ID('PUMP.[DipReadings]'))
ALTER TABLE [PUMP].[DipReadings]  WITH CHECK ADD  CONSTRAINT [FK_DipReadings_Tank] FOREIGN KEY([TankId])
REFERENCES [PUMP].[Tanks] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_DipReadings_Tank' AND parent_object_id = OBJECT_ID('PUMP.[DipReadings]'))
ALTER TABLE [PUMP].[DipReadings] CHECK CONSTRAINT [FK_DipReadings_Tank]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Employees_Owner' AND parent_object_id = OBJECT_ID('PUMP.[Employees]'))
ALTER TABLE [PUMP].[Employees]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_Employees_Owner] FOREIGN KEY([OwnerId])
REFERENCES [PUMP].[Owners] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Employees_Owner' AND parent_object_id = OBJECT_ID('PUMP.[Employees]'))
ALTER TABLE [PUMP].[Employees] CHECK CONSTRAINT [FK_PUMP_Employees_Owner]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Employees_Pump' AND parent_object_id = OBJECT_ID('PUMP.[Employees]'))
ALTER TABLE [PUMP].[Employees]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_Employees_Pump] FOREIGN KEY([PumpId])
REFERENCES [PUMP].[Pumps] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Employees_Pump' AND parent_object_id = OBJECT_ID('PUMP.[Employees]'))
ALTER TABLE [PUMP].[Employees] CHECK CONSTRAINT [FK_PUMP_Employees_Pump]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Employees_User' AND parent_object_id = OBJECT_ID('PUMP.[Employees]'))
ALTER TABLE [PUMP].[Employees]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_Employees_User] FOREIGN KEY([UserId])
REFERENCES [PUMP].[Users] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Employees_User' AND parent_object_id = OBJECT_ID('PUMP.[Employees]'))
ALTER TABLE [PUMP].[Employees] CHECK CONSTRAINT [FK_PUMP_Employees_User]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_ExpenseHeads_Owner' AND parent_object_id = OBJECT_ID('PUMP.[ExpenseHeads]'))
ALTER TABLE [PUMP].[ExpenseHeads]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_ExpenseHeads_Owner] FOREIGN KEY([OwnerId])
REFERENCES [PUMP].[Owners] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_ExpenseHeads_Owner' AND parent_object_id = OBJECT_ID('PUMP.[ExpenseHeads]'))
ALTER TABLE [PUMP].[ExpenseHeads] CHECK CONSTRAINT [FK_PUMP_ExpenseHeads_Owner]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_ExpenseHeads_Pump' AND parent_object_id = OBJECT_ID('PUMP.[ExpenseHeads]'))
ALTER TABLE [PUMP].[ExpenseHeads]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_ExpenseHeads_Pump] FOREIGN KEY([PumpId])
REFERENCES [PUMP].[Pumps] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_ExpenseHeads_Pump' AND parent_object_id = OBJECT_ID('PUMP.[ExpenseHeads]'))
ALTER TABLE [PUMP].[ExpenseHeads] CHECK CONSTRAINT [FK_PUMP_ExpenseHeads_Pump]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_ExpenseTransactions_Head' AND parent_object_id = OBJECT_ID('PUMP.[ExpenseTransactions]'))
ALTER TABLE [PUMP].[ExpenseTransactions]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_ExpenseTransactions_Head] FOREIGN KEY([ExpenseHeadId])
REFERENCES [PUMP].[ExpenseHeads] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_ExpenseTransactions_Head' AND parent_object_id = OBJECT_ID('PUMP.[ExpenseTransactions]'))
ALTER TABLE [PUMP].[ExpenseTransactions] CHECK CONSTRAINT [FK_PUMP_ExpenseTransactions_Head]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_ExpenseTransactions_Owner' AND parent_object_id = OBJECT_ID('PUMP.[ExpenseTransactions]'))
ALTER TABLE [PUMP].[ExpenseTransactions]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_ExpenseTransactions_Owner] FOREIGN KEY([OwnerId])
REFERENCES [PUMP].[Owners] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_ExpenseTransactions_Owner' AND parent_object_id = OBJECT_ID('PUMP.[ExpenseTransactions]'))
ALTER TABLE [PUMP].[ExpenseTransactions] CHECK CONSTRAINT [FK_PUMP_ExpenseTransactions_Owner]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_ExpenseTransactions_Pump' AND parent_object_id = OBJECT_ID('PUMP.[ExpenseTransactions]'))
ALTER TABLE [PUMP].[ExpenseTransactions]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_ExpenseTransactions_Pump] FOREIGN KEY([PumpId])
REFERENCES [PUMP].[Pumps] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_ExpenseTransactions_Pump' AND parent_object_id = OBJECT_ID('PUMP.[ExpenseTransactions]'))
ALTER TABLE [PUMP].[ExpenseTransactions] CHECK CONSTRAINT [FK_PUMP_ExpenseTransactions_Pump]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_FleetContracts_Owner' AND parent_object_id = OBJECT_ID('PUMP.[FleetContracts]'))
ALTER TABLE [PUMP].[FleetContracts]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_FleetContracts_Owner] FOREIGN KEY([OwnerId])
REFERENCES [PUMP].[Owners] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_FleetContracts_Owner' AND parent_object_id = OBJECT_ID('PUMP.[FleetContracts]'))
ALTER TABLE [PUMP].[FleetContracts] CHECK CONSTRAINT [FK_PUMP_FleetContracts_Owner]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_FleetContracts_Party' AND parent_object_id = OBJECT_ID('PUMP.[FleetContracts]'))
ALTER TABLE [PUMP].[FleetContracts]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_FleetContracts_Party] FOREIGN KEY([PartyId])
REFERENCES [PUMP].[Parties] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_FleetContracts_Party' AND parent_object_id = OBJECT_ID('PUMP.[FleetContracts]'))
ALTER TABLE [PUMP].[FleetContracts] CHECK CONSTRAINT [FK_PUMP_FleetContracts_Party]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_FleetContracts_Product' AND parent_object_id = OBJECT_ID('PUMP.[FleetContracts]'))
ALTER TABLE [PUMP].[FleetContracts]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_FleetContracts_Product] FOREIGN KEY([ProductId])
REFERENCES [PUMP].[Products] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_FleetContracts_Product' AND parent_object_id = OBJECT_ID('PUMP.[FleetContracts]'))
ALTER TABLE [PUMP].[FleetContracts] CHECK CONSTRAINT [FK_PUMP_FleetContracts_Product]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_FleetContracts_Pump' AND parent_object_id = OBJECT_ID('PUMP.[FleetContracts]'))
ALTER TABLE [PUMP].[FleetContracts]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_FleetContracts_Pump] FOREIGN KEY([PumpId])
REFERENCES [PUMP].[Pumps] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_FleetContracts_Pump' AND parent_object_id = OBJECT_ID('PUMP.[FleetContracts]'))
ALTER TABLE [PUMP].[FleetContracts] CHECK CONSTRAINT [FK_PUMP_FleetContracts_Pump]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Menus_Parent' AND parent_object_id = OBJECT_ID('PUMP.[Menus]'))
ALTER TABLE [PUMP].[Menus]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_Menus_Parent] FOREIGN KEY([ParentId])
REFERENCES [PUMP].[Menus] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Menus_Parent' AND parent_object_id = OBJECT_ID('PUMP.[Menus]'))
ALTER TABLE [PUMP].[Menus] CHECK CONSTRAINT [FK_PUMP_Menus_Parent]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_Nozzles_Tank' AND parent_object_id = OBJECT_ID('PUMP.[Nozzles]'))
ALTER TABLE [PUMP].[Nozzles]  WITH CHECK ADD  CONSTRAINT [FK_Nozzles_Tank] FOREIGN KEY([TankId])
REFERENCES [PUMP].[Tanks] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_Nozzles_Tank' AND parent_object_id = OBJECT_ID('PUMP.[Nozzles]'))
ALTER TABLE [PUMP].[Nozzles] CHECK CONSTRAINT [FK_Nozzles_Tank]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Nozzles_Owners' AND parent_object_id = OBJECT_ID('PUMP.[Nozzles]'))
ALTER TABLE [PUMP].[Nozzles]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_Nozzles_Owners] FOREIGN KEY([OwnerId])
REFERENCES [PUMP].[Owners] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Nozzles_Owners' AND parent_object_id = OBJECT_ID('PUMP.[Nozzles]'))
ALTER TABLE [PUMP].[Nozzles] CHECK CONSTRAINT [FK_PUMP_Nozzles_Owners]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Nozzles_Products' AND parent_object_id = OBJECT_ID('PUMP.[Nozzles]'))
ALTER TABLE [PUMP].[Nozzles]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_Nozzles_Products] FOREIGN KEY([ProductId])
REFERENCES [PUMP].[Products] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Nozzles_Products' AND parent_object_id = OBJECT_ID('PUMP.[Nozzles]'))
ALTER TABLE [PUMP].[Nozzles] CHECK CONSTRAINT [FK_PUMP_Nozzles_Products]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Nozzles_Pumps' AND parent_object_id = OBJECT_ID('PUMP.[Nozzles]'))
ALTER TABLE [PUMP].[Nozzles]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_Nozzles_Pumps] FOREIGN KEY([PumpId])
REFERENCES [PUMP].[Pumps] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Nozzles_Pumps' AND parent_object_id = OBJECT_ID('PUMP.[Nozzles]'))
ALTER TABLE [PUMP].[Nozzles] CHECK CONSTRAINT [FK_PUMP_Nozzles_Pumps]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_NumberSeries_Owner' AND parent_object_id = OBJECT_ID('PUMP.[NumberSeries]'))
ALTER TABLE [PUMP].[NumberSeries]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_NumberSeries_Owner] FOREIGN KEY([OwnerId])
REFERENCES [PUMP].[Owners] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_NumberSeries_Owner' AND parent_object_id = OBJECT_ID('PUMP.[NumberSeries]'))
ALTER TABLE [PUMP].[NumberSeries] CHECK CONSTRAINT [FK_PUMP_NumberSeries_Owner]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_NumberSeries_Pump' AND parent_object_id = OBJECT_ID('PUMP.[NumberSeries]'))
ALTER TABLE [PUMP].[NumberSeries]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_NumberSeries_Pump] FOREIGN KEY([PumpId])
REFERENCES [PUMP].[Pumps] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_NumberSeries_Pump' AND parent_object_id = OBJECT_ID('PUMP.[NumberSeries]'))
ALTER TABLE [PUMP].[NumberSeries] CHECK CONSTRAINT [FK_PUMP_NumberSeries_Pump]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Parties_Pump' AND parent_object_id = OBJECT_ID('PUMP.[Parties]'))
ALTER TABLE [PUMP].[Parties]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_Parties_Pump] FOREIGN KEY([PumpId])
REFERENCES [PUMP].[Pumps] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Parties_Pump' AND parent_object_id = OBJECT_ID('PUMP.[Parties]'))
ALTER TABLE [PUMP].[Parties] CHECK CONSTRAINT [FK_PUMP_Parties_Pump]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_PartyLedger_Party' AND parent_object_id = OBJECT_ID('PUMP.[PartyLedger]'))
ALTER TABLE [PUMP].[PartyLedger]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_PartyLedger_Party] FOREIGN KEY([PartyId])
REFERENCES [PUMP].[Parties] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_PartyLedger_Party' AND parent_object_id = OBJECT_ID('PUMP.[PartyLedger]'))
ALTER TABLE [PUMP].[PartyLedger] CHECK CONSTRAINT [FK_PUMP_PartyLedger_Party]
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_key_columns fkc JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id WHERE fkc.parent_object_id = OBJECT_ID('PUMP.[ProductRateHistory]') AND c.name = 'ProductId')
ALTER TABLE [PUMP].[ProductRateHistory]  WITH CHECK ADD FOREIGN KEY([ProductId])
REFERENCES [PUMP].[Products] ([Id])
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Products_Owners' AND parent_object_id = OBJECT_ID('PUMP.[Products]'))
ALTER TABLE [PUMP].[Products]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_Products_Owners] FOREIGN KEY([OwnerId])
REFERENCES [PUMP].[Owners] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Products_Owners' AND parent_object_id = OBJECT_ID('PUMP.[Products]'))
ALTER TABLE [PUMP].[Products] CHECK CONSTRAINT [FK_PUMP_Products_Owners]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Products_Pumps' AND parent_object_id = OBJECT_ID('PUMP.[Products]'))
ALTER TABLE [PUMP].[Products]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_Products_Pumps] FOREIGN KEY([PumpId])
REFERENCES [PUMP].[Pumps] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Products_Pumps' AND parent_object_id = OBJECT_ID('PUMP.[Products]'))
ALTER TABLE [PUMP].[Products] CHECK CONSTRAINT [FK_PUMP_Products_Pumps]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Pumps_Owners' AND parent_object_id = OBJECT_ID('PUMP.[Pumps]'))
ALTER TABLE [PUMP].[Pumps]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_Pumps_Owners] FOREIGN KEY([OwnerId])
REFERENCES [PUMP].[Owners] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Pumps_Owners' AND parent_object_id = OBJECT_ID('PUMP.[Pumps]'))
ALTER TABLE [PUMP].[Pumps] CHECK CONSTRAINT [FK_PUMP_Pumps_Owners]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_PurchaseDetails_Header' AND parent_object_id = OBJECT_ID('PUMP.[PurchaseDetails]'))
ALTER TABLE [PUMP].[PurchaseDetails]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_PurchaseDetails_Header] FOREIGN KEY([PurchaseHeaderId])
REFERENCES [PUMP].[PurchaseHeaders] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_PurchaseDetails_Header' AND parent_object_id = OBJECT_ID('PUMP.[PurchaseDetails]'))
ALTER TABLE [PUMP].[PurchaseDetails] CHECK CONSTRAINT [FK_PUMP_PurchaseDetails_Header]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_PurchaseDetails_Product' AND parent_object_id = OBJECT_ID('PUMP.[PurchaseDetails]'))
ALTER TABLE [PUMP].[PurchaseDetails]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_PurchaseDetails_Product] FOREIGN KEY([ProductId])
REFERENCES [PUMP].[Products] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_PurchaseDetails_Product' AND parent_object_id = OBJECT_ID('PUMP.[PurchaseDetails]'))
ALTER TABLE [PUMP].[PurchaseDetails] CHECK CONSTRAINT [FK_PUMP_PurchaseDetails_Product]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_PurchaseHeaders_Owner' AND parent_object_id = OBJECT_ID('PUMP.[PurchaseHeaders]'))
ALTER TABLE [PUMP].[PurchaseHeaders]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_PurchaseHeaders_Owner] FOREIGN KEY([OwnerId])
REFERENCES [PUMP].[Owners] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_PurchaseHeaders_Owner' AND parent_object_id = OBJECT_ID('PUMP.[PurchaseHeaders]'))
ALTER TABLE [PUMP].[PurchaseHeaders] CHECK CONSTRAINT [FK_PUMP_PurchaseHeaders_Owner]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_PurchaseHeaders_Pump' AND parent_object_id = OBJECT_ID('PUMP.[PurchaseHeaders]'))
ALTER TABLE [PUMP].[PurchaseHeaders]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_PurchaseHeaders_Pump] FOREIGN KEY([PumpId])
REFERENCES [PUMP].[Pumps] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_PurchaseHeaders_Pump' AND parent_object_id = OBJECT_ID('PUMP.[PurchaseHeaders]'))
ALTER TABLE [PUMP].[PurchaseHeaders] CHECK CONSTRAINT [FK_PUMP_PurchaseHeaders_Pump]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_PurchaseHeaders_Vendor' AND parent_object_id = OBJECT_ID('PUMP.[PurchaseHeaders]'))
ALTER TABLE [PUMP].[PurchaseHeaders]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_PurchaseHeaders_Vendor] FOREIGN KEY([VendorId])
REFERENCES [PUMP].[Vendors] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_PurchaseHeaders_Vendor' AND parent_object_id = OBJECT_ID('PUMP.[PurchaseHeaders]'))
ALTER TABLE [PUMP].[PurchaseHeaders] CHECK CONSTRAINT [FK_PUMP_PurchaseHeaders_Vendor]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Receipts_SalesHeaders' AND parent_object_id = OBJECT_ID('PUMP.[Receipts]'))
ALTER TABLE [PUMP].[Receipts]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_Receipts_SalesHeaders] FOREIGN KEY([SalesHeaderId])
REFERENCES [PUMP].[SalesHeaders] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Receipts_SalesHeaders' AND parent_object_id = OBJECT_ID('PUMP.[Receipts]'))
ALTER TABLE [PUMP].[Receipts] CHECK CONSTRAINT [FK_PUMP_Receipts_SalesHeaders]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_RoleMenus_Menus' AND parent_object_id = OBJECT_ID('PUMP.[RoleMenus]'))
ALTER TABLE [PUMP].[RoleMenus]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_RoleMenus_Menus] FOREIGN KEY([MenuId])
REFERENCES [PUMP].[Menus] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_RoleMenus_Menus' AND parent_object_id = OBJECT_ID('PUMP.[RoleMenus]'))
ALTER TABLE [PUMP].[RoleMenus] CHECK CONSTRAINT [FK_PUMP_RoleMenus_Menus]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_RoleMenus_Roles' AND parent_object_id = OBJECT_ID('PUMP.[RoleMenus]'))
ALTER TABLE [PUMP].[RoleMenus]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_RoleMenus_Roles] FOREIGN KEY([RoleId])
REFERENCES [PUMP].[Roles] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_RoleMenus_Roles' AND parent_object_id = OBJECT_ID('PUMP.[RoleMenus]'))
ALTER TABLE [PUMP].[RoleMenus] CHECK CONSTRAINT [FK_PUMP_RoleMenus_Roles]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Roles_Owners' AND parent_object_id = OBJECT_ID('PUMP.[Roles]'))
ALTER TABLE [PUMP].[Roles]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_Roles_Owners] FOREIGN KEY([OwnerId])
REFERENCES [PUMP].[Owners] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Roles_Owners' AND parent_object_id = OBJECT_ID('PUMP.[Roles]'))
ALTER TABLE [PUMP].[Roles] CHECK CONSTRAINT [FK_PUMP_Roles_Owners]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_SalaryPayments_Employee' AND parent_object_id = OBJECT_ID('PUMP.[SalaryPayments]'))
ALTER TABLE [PUMP].[SalaryPayments]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_SalaryPayments_Employee] FOREIGN KEY([EmployeeId])
REFERENCES [PUMP].[Employees] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_SalaryPayments_Employee' AND parent_object_id = OBJECT_ID('PUMP.[SalaryPayments]'))
ALTER TABLE [PUMP].[SalaryPayments] CHECK CONSTRAINT [FK_PUMP_SalaryPayments_Employee]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_SalaryPayments_Owner' AND parent_object_id = OBJECT_ID('PUMP.[SalaryPayments]'))
ALTER TABLE [PUMP].[SalaryPayments]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_SalaryPayments_Owner] FOREIGN KEY([OwnerId])
REFERENCES [PUMP].[Owners] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_SalaryPayments_Owner' AND parent_object_id = OBJECT_ID('PUMP.[SalaryPayments]'))
ALTER TABLE [PUMP].[SalaryPayments] CHECK CONSTRAINT [FK_PUMP_SalaryPayments_Owner]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_SalaryPayments_Pump' AND parent_object_id = OBJECT_ID('PUMP.[SalaryPayments]'))
ALTER TABLE [PUMP].[SalaryPayments]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_SalaryPayments_Pump] FOREIGN KEY([PumpId])
REFERENCES [PUMP].[Pumps] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_SalaryPayments_Pump' AND parent_object_id = OBJECT_ID('PUMP.[SalaryPayments]'))
ALTER TABLE [PUMP].[SalaryPayments] CHECK CONSTRAINT [FK_PUMP_SalaryPayments_Pump]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_SalesDetails_Products' AND parent_object_id = OBJECT_ID('PUMP.[SalesDetails]'))
ALTER TABLE [PUMP].[SalesDetails]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_SalesDetails_Products] FOREIGN KEY([ProductId])
REFERENCES [PUMP].[Products] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_SalesDetails_Products' AND parent_object_id = OBJECT_ID('PUMP.[SalesDetails]'))
ALTER TABLE [PUMP].[SalesDetails] CHECK CONSTRAINT [FK_PUMP_SalesDetails_Products]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_SalesDetails_SalesHeaders' AND parent_object_id = OBJECT_ID('PUMP.[SalesDetails]'))
ALTER TABLE [PUMP].[SalesDetails]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_SalesDetails_SalesHeaders] FOREIGN KEY([SalesHeaderId])
REFERENCES [PUMP].[SalesHeaders] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_SalesDetails_SalesHeaders' AND parent_object_id = OBJECT_ID('PUMP.[SalesDetails]'))
ALTER TABLE [PUMP].[SalesDetails] CHECK CONSTRAINT [FK_PUMP_SalesDetails_SalesHeaders]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_SalesHeaders_Parties' AND parent_object_id = OBJECT_ID('PUMP.[SalesHeaders]'))
ALTER TABLE [PUMP].[SalesHeaders]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_SalesHeaders_Parties] FOREIGN KEY([PartyId])
REFERENCES [PUMP].[Parties] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_SalesHeaders_Parties' AND parent_object_id = OBJECT_ID('PUMP.[SalesHeaders]'))
ALTER TABLE [PUMP].[SalesHeaders] CHECK CONSTRAINT [FK_PUMP_SalesHeaders_Parties]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_SalesHeaders_ShiftHeaders' AND parent_object_id = OBJECT_ID('PUMP.[SalesHeaders]'))
ALTER TABLE [PUMP].[SalesHeaders]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_SalesHeaders_ShiftHeaders] FOREIGN KEY([ShiftId])
REFERENCES [PUMP].[ShiftHeaders] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_SalesHeaders_ShiftHeaders' AND parent_object_id = OBJECT_ID('PUMP.[SalesHeaders]'))
ALTER TABLE [PUMP].[SalesHeaders] CHECK CONSTRAINT [FK_PUMP_SalesHeaders_ShiftHeaders]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_ShiftHeaders_Owners' AND parent_object_id = OBJECT_ID('PUMP.[ShiftHeaders]'))
ALTER TABLE [PUMP].[ShiftHeaders]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_ShiftHeaders_Owners] FOREIGN KEY([OwnerId])
REFERENCES [PUMP].[Owners] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_ShiftHeaders_Owners' AND parent_object_id = OBJECT_ID('PUMP.[ShiftHeaders]'))
ALTER TABLE [PUMP].[ShiftHeaders] CHECK CONSTRAINT [FK_PUMP_ShiftHeaders_Owners]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_ShiftHeaders_Pumps' AND parent_object_id = OBJECT_ID('PUMP.[ShiftHeaders]'))
ALTER TABLE [PUMP].[ShiftHeaders]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_ShiftHeaders_Pumps] FOREIGN KEY([PumpId])
REFERENCES [PUMP].[Pumps] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_ShiftHeaders_Pumps' AND parent_object_id = OBJECT_ID('PUMP.[ShiftHeaders]'))
ALTER TABLE [PUMP].[ShiftHeaders] CHECK CONSTRAINT [FK_PUMP_ShiftHeaders_Pumps]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_ShiftHeaders_Users' AND parent_object_id = OBJECT_ID('PUMP.[ShiftHeaders]'))
ALTER TABLE [PUMP].[ShiftHeaders]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_ShiftHeaders_Users] FOREIGN KEY([OperatorUserId])
REFERENCES [PUMP].[Users] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_ShiftHeaders_Users' AND parent_object_id = OBJECT_ID('PUMP.[ShiftHeaders]'))
ALTER TABLE [PUMP].[ShiftHeaders] CHECK CONSTRAINT [FK_PUMP_ShiftHeaders_Users]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_ShiftNozzleReadings_Nozzle' AND parent_object_id = OBJECT_ID('PUMP.[ShiftNozzleReadings]'))
ALTER TABLE [PUMP].[ShiftNozzleReadings]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_ShiftNozzleReadings_Nozzle] FOREIGN KEY([NozzleId])
REFERENCES [PUMP].[Nozzles] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_ShiftNozzleReadings_Nozzle' AND parent_object_id = OBJECT_ID('PUMP.[ShiftNozzleReadings]'))
ALTER TABLE [PUMP].[ShiftNozzleReadings] CHECK CONSTRAINT [FK_PUMP_ShiftNozzleReadings_Nozzle]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_ShiftNozzleReadings_Product' AND parent_object_id = OBJECT_ID('PUMP.[ShiftNozzleReadings]'))
ALTER TABLE [PUMP].[ShiftNozzleReadings]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_ShiftNozzleReadings_Product] FOREIGN KEY([ProductId])
REFERENCES [PUMP].[Products] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_ShiftNozzleReadings_Product' AND parent_object_id = OBJECT_ID('PUMP.[ShiftNozzleReadings]'))
ALTER TABLE [PUMP].[ShiftNozzleReadings] CHECK CONSTRAINT [FK_PUMP_ShiftNozzleReadings_Product]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_ShiftNozzleReadings_Shift' AND parent_object_id = OBJECT_ID('PUMP.[ShiftNozzleReadings]'))
ALTER TABLE [PUMP].[ShiftNozzleReadings]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_ShiftNozzleReadings_Shift] FOREIGN KEY([ShiftId])
REFERENCES [PUMP].[ShiftHeaders] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_ShiftNozzleReadings_Shift' AND parent_object_id = OBJECT_ID('PUMP.[ShiftNozzleReadings]'))
ALTER TABLE [PUMP].[ShiftNozzleReadings] CHECK CONSTRAINT [FK_PUMP_ShiftNozzleReadings_Shift]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_StockReconciliations_Owner' AND parent_object_id = OBJECT_ID('PUMP.[StockReconciliations]'))
ALTER TABLE [PUMP].[StockReconciliations]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_StockReconciliations_Owner] FOREIGN KEY([OwnerId])
REFERENCES [PUMP].[Owners] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_StockReconciliations_Owner' AND parent_object_id = OBJECT_ID('PUMP.[StockReconciliations]'))
ALTER TABLE [PUMP].[StockReconciliations] CHECK CONSTRAINT [FK_PUMP_StockReconciliations_Owner]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_StockReconciliations_Pump' AND parent_object_id = OBJECT_ID('PUMP.[StockReconciliations]'))
ALTER TABLE [PUMP].[StockReconciliations]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_StockReconciliations_Pump] FOREIGN KEY([PumpId])
REFERENCES [PUMP].[Pumps] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_StockReconciliations_Pump' AND parent_object_id = OBJECT_ID('PUMP.[StockReconciliations]'))
ALTER TABLE [PUMP].[StockReconciliations] CHECK CONSTRAINT [FK_PUMP_StockReconciliations_Pump]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_StockReconciliations_Tank' AND parent_object_id = OBJECT_ID('PUMP.[StockReconciliations]'))
ALTER TABLE [PUMP].[StockReconciliations]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_StockReconciliations_Tank] FOREIGN KEY([TankId])
REFERENCES [PUMP].[Tanks] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_StockReconciliations_Tank' AND parent_object_id = OBJECT_ID('PUMP.[StockReconciliations]'))
ALTER TABLE [PUMP].[StockReconciliations] CHECK CONSTRAINT [FK_PUMP_StockReconciliations_Tank]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Tanks_Product' AND parent_object_id = OBJECT_ID('PUMP.[Tanks]'))
ALTER TABLE [PUMP].[Tanks]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_Tanks_Product] FOREIGN KEY([ProductId])
REFERENCES [PUMP].[Products] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Tanks_Product' AND parent_object_id = OBJECT_ID('PUMP.[Tanks]'))
ALTER TABLE [PUMP].[Tanks] CHECK CONSTRAINT [FK_PUMP_Tanks_Product]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Tanks_Pump' AND parent_object_id = OBJECT_ID('PUMP.[Tanks]'))
ALTER TABLE [PUMP].[Tanks]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_Tanks_Pump] FOREIGN KEY([PumpId])
REFERENCES [PUMP].[Pumps] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Tanks_Pump' AND parent_object_id = OBJECT_ID('PUMP.[Tanks]'))
ALTER TABLE [PUMP].[Tanks] CHECK CONSTRAINT [FK_PUMP_Tanks_Pump]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_TankTransactions_Tank' AND parent_object_id = OBJECT_ID('PUMP.[TankTransactions]'))
ALTER TABLE [PUMP].[TankTransactions]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_TankTransactions_Tank] FOREIGN KEY([TankId])
REFERENCES [PUMP].[Tanks] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_TankTransactions_Tank' AND parent_object_id = OBJECT_ID('PUMP.[TankTransactions]'))
ALTER TABLE [PUMP].[TankTransactions] CHECK CONSTRAINT [FK_PUMP_TankTransactions_Tank]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_TestingLosses_Pump' AND parent_object_id = OBJECT_ID('PUMP.[TestingLosses]'))
ALTER TABLE [PUMP].[TestingLosses]  WITH CHECK ADD  CONSTRAINT [FK_TestingLosses_Pump] FOREIGN KEY([PumpId])
REFERENCES [PUMP].[Pumps] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_TestingLosses_Pump' AND parent_object_id = OBJECT_ID('PUMP.[TestingLosses]'))
ALTER TABLE [PUMP].[TestingLosses] CHECK CONSTRAINT [FK_TestingLosses_Pump]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_TestingLosses_Shift' AND parent_object_id = OBJECT_ID('PUMP.[TestingLosses]'))
ALTER TABLE [PUMP].[TestingLosses]  WITH CHECK ADD  CONSTRAINT [FK_TestingLosses_Shift] FOREIGN KEY([ShiftId])
REFERENCES [PUMP].[ShiftHeaders] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_TestingLosses_Shift' AND parent_object_id = OBJECT_ID('PUMP.[TestingLosses]'))
ALTER TABLE [PUMP].[TestingLosses] CHECK CONSTRAINT [FK_TestingLosses_Shift]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_TestingLosses_Tank' AND parent_object_id = OBJECT_ID('PUMP.[TestingLosses]'))
ALTER TABLE [PUMP].[TestingLosses]  WITH CHECK ADD  CONSTRAINT [FK_TestingLosses_Tank] FOREIGN KEY([TankId])
REFERENCES [PUMP].[Tanks] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_TestingLosses_Tank' AND parent_object_id = OBJECT_ID('PUMP.[TestingLosses]'))
ALTER TABLE [PUMP].[TestingLosses] CHECK CONSTRAINT [FK_TestingLosses_Tank]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_UserRefreshTokens_User' AND parent_object_id = OBJECT_ID('PUMP.[UserRefreshTokens]'))
ALTER TABLE [PUMP].[UserRefreshTokens]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_UserRefreshTokens_User] FOREIGN KEY([UserId])
REFERENCES [PUMP].[Users] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_UserRefreshTokens_User' AND parent_object_id = OBJECT_ID('PUMP.[UserRefreshTokens]'))
ALTER TABLE [PUMP].[UserRefreshTokens] CHECK CONSTRAINT [FK_PUMP_UserRefreshTokens_User]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_UserRoles_Roles' AND parent_object_id = OBJECT_ID('PUMP.[UserRoles]'))
ALTER TABLE [PUMP].[UserRoles]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_UserRoles_Roles] FOREIGN KEY([RoleId])
REFERENCES [PUMP].[Roles] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_UserRoles_Roles' AND parent_object_id = OBJECT_ID('PUMP.[UserRoles]'))
ALTER TABLE [PUMP].[UserRoles] CHECK CONSTRAINT [FK_PUMP_UserRoles_Roles]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_UserRoles_Users' AND parent_object_id = OBJECT_ID('PUMP.[UserRoles]'))
ALTER TABLE [PUMP].[UserRoles]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_UserRoles_Users] FOREIGN KEY([UserId])
REFERENCES [PUMP].[Users] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_UserRoles_Users' AND parent_object_id = OBJECT_ID('PUMP.[UserRoles]'))
ALTER TABLE [PUMP].[UserRoles] CHECK CONSTRAINT [FK_PUMP_UserRoles_Users]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Users_Owners' AND parent_object_id = OBJECT_ID('PUMP.[Users]'))
ALTER TABLE [PUMP].[Users]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_Users_Owners] FOREIGN KEY([OwnerId])
REFERENCES [PUMP].[Owners] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Users_Owners' AND parent_object_id = OBJECT_ID('PUMP.[Users]'))
ALTER TABLE [PUMP].[Users] CHECK CONSTRAINT [FK_PUMP_Users_Owners]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Vendors_Owner' AND parent_object_id = OBJECT_ID('PUMP.[Vendors]'))
ALTER TABLE [PUMP].[Vendors]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_Vendors_Owner] FOREIGN KEY([OwnerId])
REFERENCES [PUMP].[Owners] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Vendors_Owner' AND parent_object_id = OBJECT_ID('PUMP.[Vendors]'))
ALTER TABLE [PUMP].[Vendors] CHECK CONSTRAINT [FK_PUMP_Vendors_Owner]
GO
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Vendors_Pump' AND parent_object_id = OBJECT_ID('PUMP.[Vendors]'))
ALTER TABLE [PUMP].[Vendors]  WITH CHECK ADD  CONSTRAINT [FK_PUMP_Vendors_Pump] FOREIGN KEY([PumpId])
REFERENCES [PUMP].[Pumps] ([Id])
GO
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'FK_PUMP_Vendors_Pump' AND parent_object_id = OBJECT_ID('PUMP.[Vendors]'))
ALTER TABLE [PUMP].[Vendors] CHECK CONSTRAINT [FK_PUMP_Vendors_Pump]
GO
/* ==========================================================================================
   NOZZLE-WISE AADMI AUR USKA CASH - naye column
   ------------------------------------------------------------------------------------------
   Asli tareeka (user ne bataya): pump par HAR NOZZLE PAR ALAG AADMI hota hai. Shift shuru
   hote waqt accountant har aadmi ko chhutta (float) deta hai, aur shift khatam hone par
   har aadmi se alag-alag cash leta hai.

   Ab tak software ka poora cash hisaab SIRF SHIFT ke level par tha - ek OpeningCash, ek
   ClosingCash. Isse ye kabhi pata nahi chalta tha ki KIS AADMI ka cash kam pada. Do aadmi
   me se ek 500 kam de, doosra 500 zyada, to shift level par sab theek dikhta tha.

   Doosri zaroorat: kabhi-kabhi poore din ka cash SAARI shift band hone ke BAAD ek saath
   liya jaata hai. Isliye cash lena shift band karne se ALAG rakha hai - CashReturned NULL
   ka matlab "abhi tak nahi liya", chahe shift kab ki bhi ho.

   Procedures se PEHLE add karna zaroori hai (column ka naam CREATE PROCEDURE ke waqt hi
   check hota hai).
   ========================================================================================== */
IF COL_LENGTH('PUMP.ShiftNozzleReadings', 'EmployeeId') IS NULL
    ALTER TABLE PUMP.ShiftNozzleReadings ADD EmployeeId BIGINT NULL;
GO

/* Shift shuru me is aadmi ko diya gaya chhutta. */
IF COL_LENGTH('PUMP.ShiftNozzleReadings', 'FloatGiven') IS NULL
    ALTER TABLE PUMP.ShiftNozzleReadings ADD FloatGiven DECIMAL(18,2) NOT NULL
        CONSTRAINT DF_SNR_FloatGiven DEFAULT(0);
GO

/* Is aadmi ne jo udhaar/UPI/card ki parchi banayi - uska cash uske paas nahi aata,
   isliye usse maangna bhi nahi hai. */
IF COL_LENGTH('PUMP.ShiftNozzleReadings', 'SlipsAmount') IS NULL
    ALTER TABLE PUMP.ShiftNozzleReadings ADD SlipsAmount DECIMAL(18,2) NOT NULL
        CONSTRAINT DF_SNR_Slips DEFAULT(0);
GO

/* NULL = abhi tak cash liya hi nahi. Yahi "pending collection" ki pehchan hai. */
IF COL_LENGTH('PUMP.ShiftNozzleReadings', 'CashReturned') IS NULL
    ALTER TABLE PUMP.ShiftNozzleReadings ADD CashReturned DECIMAL(18,2) NULL;
GO

IF COL_LENGTH('PUMP.ShiftNozzleReadings', 'CashCollectedOn') IS NULL
    ALTER TABLE PUMP.ShiftNozzleReadings ADD CashCollectedOn DATETIME2(7) NULL;
GO

IF COL_LENGTH('PUMP.ShiftNozzleReadings', 'CollectedByUserId') IS NULL
    ALTER TABLE PUMP.ShiftNozzleReadings ADD CollectedByUserId BIGINT NULL;
GO

IF COL_LENGTH('PUMP.ShiftNozzleReadings', 'CashNotes') IS NULL
    ALTER TABLE PUMP.ShiftNozzleReadings ADD CashNotes NVARCHAR(250) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_SNR_PendingCash')
    CREATE INDEX IX_SNR_PendingCash ON PUMP.ShiftNozzleReadings (OwnerId, PumpId, CashReturned)
        INCLUDE (ShiftId, NozzleId, EmployeeId);
GO

/* ==========================================================================================
   VOID KI GAYI BIKRI KA NISHAAN - naye column
   ------------------------------------------------------------------------------------------
   Pehle sp_Sale_Void bill ko SEEDHA DELETE kar deta tha (SalesDetails + Receipts +
   SalesHeaders). Credit sale par PartyLedger me ek VOID entry bach jaati thi, lekin
   CASH bikri void karne par koi nishaan hi nahi bachta tha - na bill, na kitna tha,
   na kisne kiya. Pump par paisa nikalne ka sabse aasan tareeka yahi hai.

   Ab bill mitta nahi, VOID ka nishaan lag jaata hai. Report aur total me nahi ginta,
   par Sales list me dikhta hai - malik ko pata rehta hai ki kaun sa bill kaata gaya.

   Procedures se PEHLE add karna zaroori hai (column ka naam CREATE PROCEDURE ke waqt
   hi check hota hai).
   ========================================================================================== */
IF COL_LENGTH('PUMP.SalesHeaders', 'IsVoid') IS NULL
    ALTER TABLE PUMP.SalesHeaders ADD IsVoid BIT NOT NULL CONSTRAINT DF_SalesHeaders_IsVoid DEFAULT(0);
GO

IF COL_LENGTH('PUMP.SalesHeaders', 'VoidedOn') IS NULL
    ALTER TABLE PUMP.SalesHeaders ADD VoidedOn DATETIME2(7) NULL;
GO

IF COL_LENGTH('PUMP.SalesHeaders', 'VoidedBy') IS NULL
    ALTER TABLE PUMP.SalesHeaders ADD VoidedBy BIGINT NULL;
GO

IF COL_LENGTH('PUMP.SalesHeaders', 'VoidReason') IS NULL
    ALTER TABLE PUMP.SalesHeaders ADD VoidReason NVARCHAR(250) NULL;
GO

/* ==========================================================================================
   VARIANCE KI RUPEE VALUE — naye column
   ------------------------------------------------------------------------------------------
   Procedures se PEHLE add karna zaroori hai: SQL Server column ka naam CREATE PROCEDURE
   ke waqt hi check kar leta hai (table maujood ho to deferred resolution nahi hoti).
   Ye G13 ka hissa hai, sirf jagah upar rakhni padi. Purani entries ki value G13.2 me
   bharti hai (tab tak fn_ProductRateOnDate ban chuka hota hai).
   ========================================================================================== */
IF COL_LENGTH('PUMP.StockReconciliations', 'VarianceAmount') IS NULL
    ALTER TABLE PUMP.StockReconciliations ADD VarianceAmount DECIMAL(18,2) NULL;
GO

IF COL_LENGTH('PUMP.DipReadings', 'VarianceAmount') IS NULL
    ALTER TABLE PUMP.DipReadings ADD VarianceAmount DECIMAL(18,2) NULL;
GO

/* ------------------------------------------------------------------------------------------
   ProductRateHistory.EffectiveFrom — YAHIN banana zaroori hai.

   Ye column PART 2 ke "missing columns" loop me bhi hai (Section B6), lekin wo bahut
   baad me chalta hai. Neeche wala function isi column ko padhta hai, aur SQL Server
   scalar function ke body ke column CREATE ke waqt hi resolve karta hai — table ki
   tarah baad me nahi.

   Isliye FRESH database par ye ho raha tha:
     1. CREATE FUNCTION fail  -> Msg 207 "Invalid column name 'EffectiveFrom'"
     2. fn_ProductRateOnDate bana hi nahi
     3. sp_Shift_Open / sp_StockReconcile jo use call karte hain, wo bhi fail
        -> Msg 4121 "Cannot find ... PUMP.fn_ProductRateOnDate"
     4. Nateeja: naye DB par SHIFT KHULTI HI NAHI THI. Script dobara chalane par
        theek ho jaata tha (kyunki tab tak column ban chuka hota), isliye ye bug
        aksar chhup jaata tha.

   Column pehle bana dene se dono baar (fresh aur re-run) sahi chalta hai. Neeche
   wala B6 loop dekhega ki column pehle se hai aur chhod dega.
   ------------------------------------------------------------------------------------------ */
IF OBJECT_ID('PUMP.ProductRateHistory', 'U') IS NOT NULL
   AND COL_LENGTH('PUMP.ProductRateHistory', 'EffectiveFrom') IS NULL
BEGIN
    ALTER TABLE PUMP.ProductRateHistory ADD EffectiveFrom DATETIME2(7) NULL;
    PRINT '  + column   PUMP.ProductRateHistory.EffectiveFrom (fn_ProductRateOnDate se pehle)';
END
GO

/* ==========================================================================================
   PUMP.fn_ProductRateOnDate — kisi bhi tareekh ka rate
   ------------------------------------------------------------------------------------------
   Sabhi procedures se pehle bana rahe hain kyunki SQL Server scalar function ka naam
   CREATE PROCEDURE ke waqt hi resolve karta hai (table ki tarah baad me nahi).
   Back-dated entry aur variance ki rupee-value dono ismein se rate lete hain.
   ========================================================================================== */
IF OBJECT_ID('PUMP.fn_ProductRateOnDate', 'FN') IS NOT NULL
    DROP FUNCTION PUMP.fn_ProductRateOnDate;
GO

CREATE FUNCTION PUMP.fn_ProductRateOnDate
(
    @ProductId BIGINT,
    @OnDate    DATETIME2(7)
)
RETURNS DECIMAL(18,3)
AS
BEGIN
    DECLARE @Rate DECIMAL(18,3);

    SELECT TOP 1 @Rate = h.NewRate
    FROM PUMP.ProductRateHistory h
    WHERE h.ProductId = @ProductId
      AND ISNULL(h.EffectiveFrom, h.ChangedAt) <= @OnDate
    ORDER BY ISNULL(h.EffectiveFrom, h.ChangedAt) DESC;

    /* History na ho (purana product) to aaj ka rate hi sahi anumaan hai. */
    IF @Rate IS NULL
        SELECT @Rate = CurrentRate FROM PUMP.Products WHERE Id = @ProductId;

    RETURN ISNULL(@Rate, 0);
END
GO

/****** Object:  StoredProcedure [PUMP].[sp_Auth_GetByUserId]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Auth_GetByUserId]
(
    @UserId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 1
        u.Id AS UserId,
        u.OwnerId,
        u.FullName,
        u.Username,
        r.Id AS RoleId,
        r.Name AS RoleName,
        u.PasswordHash,
        u.IsSuperAdmin
    FROM PUMP.Users u
    INNER JOIN PUMP.UserRoles ur ON ur.UserId = u.Id
    INNER JOIN PUMP.Roles r ON r.Id = ur.RoleId
    WHERE u.Id = @UserId
      AND u.IsActive = 1
      AND r.IsActive = 1;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Auth_Login]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Auth_Login]
(
    @Username NVARCHAR(100)
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 1
        u.Id AS UserId,
        u.OwnerId,
        u.FullName,
        u.Username,
        r.Id AS RoleId,
        r.Name AS RoleName,
        u.PasswordHash,
        u.IsSuperAdmin
    FROM PUMP.Users u
    INNER JOIN PUMP.UserRoles ur ON ur.UserId = u.Id
    INNER JOIN PUMP.Roles r ON r.Id = ur.RoleId
    WHERE u.Username = @Username
      AND u.IsActive = 1
      AND r.IsActive = 1;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_CashTxn_Delete]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_CashTxn_Delete]
(
    @Id      BIGINT,
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.CashTransactions WHERE Id = @Id AND OwnerId = @OwnerId)
    BEGIN
        THROW 50013, 'Cash transaction not found or access denied.', 1;
    END

    DELETE FROM PUMP.CashTransactions WHERE Id = @Id AND OwnerId = @OwnerId;

    SELECT @Id AS Id;
END
GO
/****** Object:  StoredProcedure [PUMP].[sp_CashTxn_List]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_CashTxn_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 300
        Id,
        OwnerId,
        PumpId,
        ShiftId,
        TxnType,
        Amount,
        ReferenceNo,
        Narration,
        TxnDateTime
    FROM PUMP.CashTransactions
    WHERE OwnerId = @OwnerId
      AND PumpId = @PumpId
    ORDER BY Id DESC;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_CashTxn_Save]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_CashTxn_Save]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @ShiftId BIGINT = NULL,
    @TxnType NVARCHAR(20),
    @Amount DECIMAL(18,2),
    @ReferenceNo NVARCHAR(50) = NULL,
    @Narration NVARCHAR(250) = NULL,
    @TxnDateTime DATETIME2 = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO PUMP.CashTransactions
    (
        OwnerId,
        PumpId,
        ShiftId,
        TxnType,
        Amount,
        ReferenceNo,
        Narration,
        TxnDateTime
    )
    VALUES
    (
        @OwnerId,
        @PumpId,
        @ShiftId,
        @TxnType,
        @Amount,
        @ReferenceNo,
        @Narration,
        ISNULL(@TxnDateTime, SYSDATETIME())
    );

    SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_CouponBook_List]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_CouponBook_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        cb.Id,
        cb.OwnerId,
        cb.PumpId,
        cb.BookCode,
        cb.Denomination,
        cb.TotalCoupons,
        cb.IssuedToPartyId,
        IssuedToPartyName = p.PartyName,
        cb.StartSerial,
        cb.EndSerial,
        cb.IsActive,
        cb.CreatedOn
    FROM PUMP.CouponBooks cb
    LEFT JOIN PUMP.Parties p ON p.Id = cb.IssuedToPartyId
    WHERE cb.OwnerId = @OwnerId
      AND cb.PumpId = @PumpId
    ORDER BY cb.Id DESC;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_CouponBook_Save]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_CouponBook_Save]
(
    @Id BIGINT = NULL,
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @BookCode NVARCHAR(50),
    @Denomination DECIMAL(18,2),
    @TotalCoupons INT,
    @IssuedToPartyId BIGINT = NULL,
    @StartSerial INT,
    @EndSerial INT,
    @IsActive BIT = 1
)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISNULL(@Id, 0) = 0
    BEGIN
        INSERT INTO PUMP.CouponBooks
        (
            OwnerId,
            PumpId,
            BookCode,
            Denomination,
            TotalCoupons,
            IssuedToPartyId,
            StartSerial,
            EndSerial,
            IsActive
        )
        VALUES
        (
            @OwnerId,
            @PumpId,
            @BookCode,
            @Denomination,
            @TotalCoupons,
            @IssuedToPartyId,
            @StartSerial,
            @EndSerial,
            @IsActive
        );

        SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS Id;
        RETURN;
    END

    UPDATE PUMP.CouponBooks
    SET BookCode = @BookCode,
        Denomination = @Denomination,
        TotalCoupons = @TotalCoupons,
        IssuedToPartyId = @IssuedToPartyId,
        StartSerial = @StartSerial,
        EndSerial = @EndSerial,
        IsActive = @IsActive
    WHERE Id = @Id
      AND OwnerId = @OwnerId
      AND PumpId = @PumpId;

    SELECT @Id AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_CouponTxn_List]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_CouponTxn_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @CouponBookId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 300
        ct.Id,
        ct.OwnerId,
        ct.PumpId,
        ct.CouponBookId,
        cb.BookCode,
        ct.PartyId,
        p.PartyName,
        ct.SalesHeaderId,
        ct.CouponSerialNo,
        ct.Amount,
        ct.TxnDateTime,
        ct.Notes
    FROM PUMP.CouponTransactions ct
    INNER JOIN PUMP.CouponBooks cb ON cb.Id = ct.CouponBookId
    LEFT JOIN PUMP.Parties p ON p.Id = ct.PartyId
    WHERE ct.OwnerId = @OwnerId
      AND ct.PumpId = @PumpId
      AND (@CouponBookId IS NULL OR ct.CouponBookId = @CouponBookId)
    ORDER BY ct.Id DESC;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_CouponTxn_Save]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_CouponTxn_Save]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @CouponBookId BIGINT,
    @PartyId BIGINT = NULL,
    @SalesHeaderId BIGINT = NULL,
    @CouponSerialNo INT,
    @Amount DECIMAL(18,2),
    @Notes NVARCHAR(250) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO PUMP.CouponTransactions
    (
        OwnerId,
        PumpId,
        CouponBookId,
        PartyId,
        SalesHeaderId,
        CouponSerialNo,
        Amount,
        Notes
    )
    VALUES
    (
        @OwnerId,
        @PumpId,
        @CouponBookId,
        @PartyId,
        @SalesHeaderId,
        @CouponSerialNo,
        @Amount,
        @Notes
    );

    IF @PartyId IS NOT NULL
    BEGIN
        UPDATE PUMP.Parties
        SET CurrentBalance = CurrentBalance - @Amount,
            UpdatedOn = SYSDATETIME()
        WHERE Id = @PartyId
          AND OwnerId = @OwnerId
          AND PumpId = @PumpId;
    END

    SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_DipReading_List]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_DipReading_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 20
)
AS
BEGIN
    SET NOCOUNT ON;
    
    SELECT 
        dr.Id,
        dr.OwnerId,
        dr.PumpId,
        dr.TankId,
        t.Name + ' (' + p.Name + ')' AS TankName,
        dr.ReadingDate,
        dr.ShiftId,
        dr.DipCm,
        dr.WaterDipCm,
        dr.Density,
        dr.Temperature,
        dr.ExpectedStock,
        dr.ActualStock,
        dr.Variance,
        dr.VarianceAmount,
        dr.CreatedOn,
        dr.IsActive
    FROM PUMP.DipReadings dr
    INNER JOIN PUMP.Tanks t ON t.Id = dr.TankId
    INNER JOIN PUMP.Products p ON p.Id = t.ProductId
    WHERE dr.OwnerId = @OwnerId 
      AND dr.PumpId = @PumpId
      AND (@FromDate IS NULL OR dr.ReadingDate >= @FromDate)
      AND (@ToDate IS NULL OR dr.ReadingDate <= @ToDate)
    ORDER BY dr.ReadingDate DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(1)
    FROM PUMP.DipReadings dr
    WHERE dr.OwnerId = @OwnerId 
      AND dr.PumpId = @PumpId
      AND (@FromDate IS NULL OR dr.ReadingDate >= @FromDate)
      AND (@ToDate IS NULL OR dr.ReadingDate <= @ToDate);
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_DipReading_Save]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_DipReading_Save]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @TankId BIGINT,
    @ReadingDate DATE,
    @ShiftId BIGINT = NULL,
    @DipCm DECIMAL(10,2),
    @WaterDipCm DECIMAL(10,2) = NULL,
    @Density DECIMAL(10,4) = NULL,
    @Temperature DECIMAL(10,2) = NULL,
    @ExpectedStock DECIMAL(18,2) = 0,
    @ActualStock DECIMAL(18,2) = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Variance DECIMAL(18,2) = @ActualStock - @ExpectedStock;

    INSERT INTO PUMP.DipReadings
    (
        OwnerId, PumpId, TankId, ReadingDate, ShiftId, DipCm, WaterDipCm, Density, Temperature, ExpectedStock, ActualStock, Variance
    )
    VALUES
    (
        @OwnerId, @PumpId, @TankId, @ReadingDate, @ShiftId, @DipCm, @WaterDipCm, @Density, @Temperature, @ExpectedStock, @ActualStock, @Variance
    );

    SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_DipReading_ToggleActive]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- 2. DipReading ToggleActive
CREATE OR ALTER PROCEDURE [PUMP].[sp_DipReading_ToggleActive]
(
    @Id BIGINT,
    @OwnerId BIGINT,
    @PumpId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE PUMP.DipReadings
    SET IsActive = CASE WHEN IsActive = 1 THEN 0 ELSE 1 END
    WHERE Id = @Id AND OwnerId = @OwnerId AND PumpId = @PumpId;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_DipReading_Update]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- 1. DipReading Update
CREATE OR ALTER PROCEDURE [PUMP].[sp_DipReading_Update]
(
    @Id BIGINT,
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @TankId BIGINT,
    @ReadingDate DATE,
    @ShiftId BIGINT = NULL,
    @DipCm DECIMAL(10,2),
    @WaterDipCm DECIMAL(10,2) = NULL,
    @Density DECIMAL(10,4) = NULL,
    @Temperature DECIMAL(10,2) = NULL,
    @ExpectedStock DECIMAL(18,2) = 0,
    @ActualStock DECIMAL(18,2) = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Variance DECIMAL(18,2) = @ActualStock - @ExpectedStock;

    UPDATE PUMP.DipReadings
    SET 
        TankId = @TankId,
        ReadingDate = @ReadingDate,
        ShiftId = @ShiftId,
        DipCm = @DipCm,
        WaterDipCm = @WaterDipCm,
        Density = @Density,
        Temperature = @Temperature,
        ExpectedStock = @ExpectedStock,
        ActualStock = @ActualStock,
        Variance = @Variance
    WHERE Id = @Id AND OwnerId = @OwnerId AND PumpId = @PumpId;

END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Employee_Delete]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ============================================================
-- 8. sp_Employee_Delete
-- Checks: SalaryPayments
-- ============================================================
CREATE OR ALTER PROCEDURE [PUMP].[sp_Employee_Delete]
(
    @Id      BIGINT,
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.Employees WHERE Id = @Id AND OwnerId = @OwnerId)
    BEGIN
        THROW 50090, 'Employee not found or access denied.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.SalaryPayments WHERE EmployeeId = @Id)
    BEGIN
        THROW 50091, 'Cannot delete: Employee has salary payment records linked to them.', 1;
    END

    DELETE FROM PUMP.Employees WHERE Id = @Id AND OwnerId = @OwnerId;

    SELECT @Id AS Id;
END
GO
/****** Object:  StoredProcedure [PUMP].[sp_Employee_List]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Employee_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        e.Id,
        e.OwnerId,
        e.PumpId,
        e.UserId,
        e.EmployeeCode,
        e.FullName,
        e.Mobile,
        e.JoinDate,
        e.Designation,
        e.MonthlySalary,
        e.IsActive,
        u.Username AS UserName
    FROM PUMP.Employees e
    LEFT JOIN PUMP.Users u ON u.Id = e.UserId
    WHERE e.OwnerId = @OwnerId
      AND e.PumpId = @PumpId
    ORDER BY e.FullName;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Employee_Save]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Employee_Save]
(
    @Id BIGINT = NULL,
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @UserId BIGINT = NULL,
    @EmployeeCode NVARCHAR(30),
    @FullName NVARCHAR(150),
    @Mobile NVARCHAR(20) = NULL,
    @JoinDate DATE,
    @Designation NVARCHAR(80) = NULL,
    @MonthlySalary DECIMAL(18,2) = 0,
    @IsActive BIT = 1
)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISNULL(@Id, 0) = 0
    BEGIN
        INSERT INTO PUMP.Employees
        (
            OwnerId, PumpId, UserId, EmployeeCode, FullName, Mobile, JoinDate, Designation, MonthlySalary, IsActive
        )
        VALUES
        (
            @OwnerId, @PumpId, @UserId, @EmployeeCode, @FullName, @Mobile, @JoinDate, @Designation, @MonthlySalary, @IsActive
        );

        SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS Id;
        RETURN;
    END

    UPDATE PUMP.Employees
    SET UserId = @UserId,
        EmployeeCode = @EmployeeCode,
        FullName = @FullName,
        Mobile = @Mobile,
        JoinDate = @JoinDate,
        Designation = @Designation,
        MonthlySalary = @MonthlySalary,
        IsActive = @IsActive,
        UpdatedOn = SYSDATETIME()
    WHERE Id = @Id
      AND OwnerId = @OwnerId
      AND PumpId = @PumpId;

    SELECT @Id AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Expense_Delete]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- 2. Delete Expense
CREATE OR ALTER PROCEDURE [PUMP].[sp_Expense_Delete]
(
    @Id      BIGINT,
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.ExpenseTransactions WHERE Id = @Id AND OwnerId = @OwnerId)
    BEGIN
        THROW 50011, 'Expense not found or access denied.', 1;
    END

    DELETE FROM PUMP.ExpenseTransactions WHERE Id = @Id AND OwnerId = @OwnerId;

    SELECT @Id AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Expense_List]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Expense_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT = NULL,
    @FromDate DATETIME2 = NULL,
    @ToDate DATETIME2 = NULL,
    @SearchTerm NVARCHAR(100) = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 50
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Offset INT = (@PageNumber - 1) * @PageSize;

    SELECT
        e.Id,
        e.OwnerId,
        e.PumpId,
        e.ShiftId,
        e.ExpenseHeadId,
        h.HeadName AS ExpenseHeadName,
        e.Amount,
        e.PaymentMode,
        e.ReferenceNo,
        e.Narration,
        e.TxnDateTime
    FROM PUMP.ExpenseTransactions e
    INNER JOIN PUMP.ExpenseHeads h ON h.Id = e.ExpenseHeadId
    WHERE e.OwnerId = @OwnerId
      AND (@PumpId IS NULL OR @PumpId <= 0 OR e.PumpId = @PumpId)
      AND (@FromDate IS NULL OR e.TxnDateTime >= @FromDate)
      AND (@ToDate IS NULL OR e.TxnDateTime <= @ToDate)
      AND (@SearchTerm IS NULL OR @SearchTerm = '' OR e.ReferenceNo LIKE '%' + @SearchTerm + '%' OR e.Narration LIKE '%' + @SearchTerm + '%' OR h.HeadName LIKE '%' + @SearchTerm + '%')
    ORDER BY e.Id DESC
    OFFSET @Offset ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(1)
    FROM PUMP.ExpenseTransactions e
    INNER JOIN PUMP.ExpenseHeads h ON h.Id = e.ExpenseHeadId
    WHERE e.OwnerId = @OwnerId
      AND (@PumpId IS NULL OR @PumpId <= 0 OR e.PumpId = @PumpId)
      AND (@FromDate IS NULL OR e.TxnDateTime >= @FromDate)
      AND (@ToDate IS NULL OR e.TxnDateTime <= @ToDate)
      AND (@SearchTerm IS NULL OR @SearchTerm = '' OR e.ReferenceNo LIKE '%' + @SearchTerm + '%' OR e.Narration LIKE '%' + @SearchTerm + '%' OR h.HeadName LIKE '%' + @SearchTerm + '%');
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Expense_Save]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Expense_Save]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @ShiftId BIGINT = NULL,
    @ExpenseHeadId BIGINT,
    @Amount DECIMAL(18,2),
    @PaymentMode NVARCHAR(30),
    @ReferenceNo NVARCHAR(50) = NULL,
    @Narration NVARCHAR(250) = NULL,
    @TxnDateTime DATETIME2 = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO PUMP.ExpenseTransactions
    (
        OwnerId,
        PumpId,
        ShiftId,
        ExpenseHeadId,
        Amount,
        PaymentMode,
        ReferenceNo,
        Narration,
        TxnDateTime
    )
    VALUES
    (
        @OwnerId,
        @PumpId,
        @ShiftId,
        @ExpenseHeadId,
        @Amount,
        @PaymentMode,
        @ReferenceNo,
        @Narration,
        ISNULL(@TxnDateTime, SYSDATETIME())
    );

    SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_ExpenseHead_Delete]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ============================================================
-- 7. sp_ExpenseHead_Delete
-- Checks: ExpenseTransactions
-- ============================================================
CREATE OR ALTER PROCEDURE [PUMP].[sp_ExpenseHead_Delete]
(
    @Id      BIGINT,
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.ExpenseHeads WHERE Id = @Id AND OwnerId = @OwnerId)
    BEGIN
        THROW 50080, 'Expense head not found or access denied.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.ExpenseTransactions WHERE ExpenseHeadId = @Id)
    BEGIN
        THROW 50081, 'Cannot delete: Expense head has transactions linked to it.', 1;
    END

    DELETE FROM PUMP.ExpenseHeads WHERE Id = @Id AND OwnerId = @OwnerId;

    SELECT @Id AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_ExpenseHead_List]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_ExpenseHead_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id, OwnerId, PumpId, HeadName, IsActive
    FROM PUMP.ExpenseHeads
    WHERE OwnerId = @OwnerId
      AND PumpId = @PumpId
    ORDER BY HeadName;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_ExpenseHead_Save]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_ExpenseHead_Save]
(
    @Id BIGINT = NULL,
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @HeadName NVARCHAR(150),
    @IsActive BIT = 1
)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISNULL(@Id, 0) = 0
    BEGIN
        INSERT INTO PUMP.ExpenseHeads (OwnerId, PumpId, HeadName, IsActive)
        VALUES (@OwnerId, @PumpId, @HeadName, @IsActive);

        SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS Id;
        RETURN;
    END

    UPDATE PUMP.ExpenseHeads
    SET HeadName = @HeadName,
        IsActive = @IsActive,
        UpdatedOn = SYSDATETIME()
    WHERE Id = @Id
      AND OwnerId = @OwnerId
      AND PumpId = @PumpId;

    SELECT @Id AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_FleetContract_List]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_FleetContract_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        fc.Id,
        fc.OwnerId,
        fc.PumpId,
        fc.PartyId,
        p.PartyName,
        fc.ProductId,
        pr.Name AS ProductName,
        fc.ContractRate,
        fc.ValidFrom,
        fc.ValidTo,
        fc.IsActive,
        fc.Notes
    FROM PUMP.FleetContracts fc
    INNER JOIN PUMP.Parties p ON p.Id = fc.PartyId
    INNER JOIN PUMP.Products pr ON pr.Id = fc.ProductId
    WHERE fc.OwnerId = @OwnerId
      AND fc.PumpId = @PumpId
    ORDER BY fc.Id DESC;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_FleetContract_Save]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_FleetContract_Save]
(
    @Id BIGINT = NULL,
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @PartyId BIGINT,
    @ProductId BIGINT,
    @ContractRate DECIMAL(18,2),
    @ValidFrom DATE,
    @ValidTo DATE = NULL,
    @IsActive BIT = 1,
    @Notes NVARCHAR(250) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISNULL(@Id, 0) = 0
    BEGIN
        INSERT INTO PUMP.FleetContracts
        (
            OwnerId,
            PumpId,
            PartyId,
            ProductId,
            ContractRate,
            ValidFrom,
            ValidTo,
            IsActive,
            Notes
        )
        VALUES
        (
            @OwnerId,
            @PumpId,
            @PartyId,
            @ProductId,
            @ContractRate,
            @ValidFrom,
            @ValidTo,
            @IsActive,
            @Notes
        );

        SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS Id;
        RETURN;
    END

    UPDATE PUMP.FleetContracts
    SET PartyId = @PartyId,
        ProductId = @ProductId,
        ContractRate = @ContractRate,
        ValidFrom = @ValidFrom,
        ValidTo = @ValidTo,
        IsActive = @IsActive,
        Notes = @Notes,
        UpdatedOn = SYSDATETIME()
    WHERE Id = @Id
      AND OwnerId = @OwnerId
      AND PumpId = @PumpId;

    SELECT @Id AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Menu_GetAll]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Menu_GetAll]
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        Id,
        ParentId,
        MenuName,
        Route,
        Icon,
        Sequence
    FROM PUMP.Menus
    WHERE IsActive = 1
    ORDER BY Sequence, MenuName;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Menu_GetByRole]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Menu_GetByRole]
(
    @RoleId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        m.Id,
        m.ParentId,
        m.MenuName,
        m.Route,
        m.Icon,
        m.Sequence,
        rm.CanView,
        rm.CanCreate,
        rm.CanEdit,
        rm.CanDelete
    FROM PUMP.RoleMenus rm
    INNER JOIN PUMP.Menus m ON m.Id = rm.MenuId
    WHERE rm.RoleId = @RoleId
      AND m.IsActive = 1
      AND m.IsVisible = 1
      AND rm.CanView = 1
    ORDER BY m.Sequence, m.MenuName;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Nozzle_Delete]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ============================================================
-- 017: Safe Delete SPs for all master & transactional tables
-- Logic: Check if linked data exists. If yes => error. If no => delete.
-- ============================================================

-- ============================================================
-- 1. sp_Nozzle_Delete
-- Checks: ShiftNozzleReadings
-- ============================================================
CREATE OR ALTER PROCEDURE [PUMP].[sp_Nozzle_Delete]
(
    @Id      BIGINT,
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.Nozzles WHERE Id = @Id AND OwnerId = @OwnerId)
    BEGIN
        THROW 50020, 'Nozzle not found or access denied.', 1;
    END

    -- Check ShiftNozzleReadings
    IF EXISTS (SELECT 1 FROM PUMP.ShiftNozzleReadings WHERE NozzleId = @Id)
    BEGIN
        THROW 50021, 'Cannot delete: Nozzle has shift readings linked to it. Remove those first.', 1;
    END

    DELETE FROM PUMP.Nozzles WHERE Id = @Id AND OwnerId = @OwnerId;

    SELECT @Id AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Nozzle_List]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Nozzle_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        n.Id,
        n.OwnerId,
        n.PumpId,
        n.ProductId,
        p.Name AS ProductName,
        n.NozzleCode,
        n.IsActive
    FROM PUMP.Nozzles n
    INNER JOIN PUMP.Products p ON p.Id = n.ProductId
    WHERE n.OwnerId = @OwnerId
      AND (@PumpId IS NULL OR n.PumpId = @PumpId)
      AND n.IsActive = 1
    ORDER BY n.NozzleCode;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Nozzle_Save]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Nozzle_Save]
(
    @Id BIGINT = NULL,
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @ProductId BIGINT,
    @NozzleCode NVARCHAR(30)
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @Id IS NULL OR @Id = 0
    BEGIN
        INSERT INTO PUMP.Nozzles (OwnerId, PumpId, ProductId, NozzleCode)
        VALUES (@OwnerId, @PumpId, @ProductId, @NozzleCode);
    END
    ELSE
    BEGIN
        UPDATE PUMP.Nozzles
        SET ProductId = @ProductId,
            NozzleCode = @NozzleCode
        WHERE Id = @Id
          AND OwnerId = @OwnerId
          AND PumpId = @PumpId;
    END

    SELECT COALESCE(@Id, CAST(SCOPE_IDENTITY() AS BIGINT)) AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_NumberSeries_Next]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_NumberSeries_Next]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @SeriesKey NVARCHAR(50),
    @FinancialYear NVARCHAR(9),
    @Prefix NVARCHAR(20),
    @PaddingLength INT = 6
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @CurrentNumber BIGINT;

    BEGIN TRANSACTION;

    IF NOT EXISTS
    (
        SELECT 1
        FROM PUMP.NumberSeries WITH (UPDLOCK, HOLDLOCK)
        WHERE OwnerId = @OwnerId
          AND PumpId = @PumpId
          AND SeriesKey = @SeriesKey
          AND FinancialYear = @FinancialYear
    )
    BEGIN
        INSERT INTO PUMP.NumberSeries
        (
            OwnerId,
            PumpId,
            SeriesKey,
            FinancialYear,
            Prefix,
            LastNumber,
            PaddingLength
        )
        VALUES
        (
            @OwnerId,
            @PumpId,
            @SeriesKey,
            @FinancialYear,
            @Prefix,
            0,
            @PaddingLength
        );
    END

    UPDATE PUMP.NumberSeries
    SET LastNumber = LastNumber + 1,
        Prefix = @Prefix,
        PaddingLength = @PaddingLength,
        UpdatedOn = SYSDATETIME()
    WHERE OwnerId = @OwnerId
      AND PumpId = @PumpId
      AND SeriesKey = @SeriesKey
      AND FinancialYear = @FinancialYear;

    SELECT @CurrentNumber = LastNumber
    FROM PUMP.NumberSeries
    WHERE OwnerId = @OwnerId
      AND PumpId = @PumpId
      AND SeriesKey = @SeriesKey
      AND FinancialYear = @FinancialYear;

    COMMIT TRANSACTION;

    SELECT CONCAT(@Prefix, RIGHT(REPLICATE('0', @PaddingLength) + CAST(@CurrentNumber AS NVARCHAR(20)), @PaddingLength)) AS NextNumber;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Owner_Create]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Owner_Create]
(
    @Name NVARCHAR(200),
    @AdminUsername NVARCHAR(100),
    @AdminPasswordHash NVARCHAR(500)
)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;
        
        DECLARE @OwnerId BIGINT;
        INSERT INTO PUMP.Owners (Name, IsActive)
        VALUES (@Name, 1);
        
        SET @OwnerId = SCOPE_IDENTITY();
        
        DECLARE @RoleId BIGINT;
        INSERT INTO PUMP.Roles (OwnerId, Name, IsSystem, IsActive)
        VALUES (@OwnerId, 'Admin', 1, 1);
        
        SET @RoleId = SCOPE_IDENTITY();
        
        DECLARE @UserId BIGINT;
        INSERT INTO PUMP.Users (OwnerId, FullName, Username, PasswordHash, IsSuperAdmin, IsActive)
        VALUES (@OwnerId, 'System Admin', @AdminUsername, @AdminPasswordHash, 0, 1);
        
        SET @UserId = SCOPE_IDENTITY();
        
        INSERT INTO PUMP.UserRoles (UserId, RoleId)
        VALUES (@UserId, @RoleId);
        
        -- Give all menu permissions to this system admin role
        INSERT INTO PUMP.RoleMenus (RoleId, MenuId, CanView, CanCreate, CanEdit, CanDelete)
        SELECT @RoleId, Id, 1, 1, 1, 1
        FROM PUMP.Menus
        WHERE IsActive = 1;
        
        COMMIT TRANSACTION;
        SELECT @OwnerId AS Id;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Owner_GetList]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Owner_GetList]
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        Id,
        Name,
        IsActive,
        CreatedOn
    FROM PUMP.Owners
    ORDER BY Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Owner_ToggleStatus]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Owner_ToggleStatus]
(
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE PUMP.Owners
    SET IsActive = CASE WHEN IsActive = 1 THEN 0 ELSE 1 END
    WHERE Id = @OwnerId;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Party_Delete]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ============================================================
-- 4. sp_Party_Delete
-- Checks: PartyLedger, SalesHeaders, FleetContracts, CouponBooks, CouponTransactions
-- ============================================================
CREATE OR ALTER PROCEDURE [PUMP].[sp_Party_Delete]
(
    @Id      BIGINT,
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.Parties WHERE Id = @Id AND OwnerId = @OwnerId)
    BEGIN
        THROW 50050, 'Party not found or access denied.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.PartyLedger WHERE PartyId = @Id)
    BEGIN
        THROW 50051, 'Cannot delete: Party has ledger entries. Clear the ledger first.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.SalesHeaders WHERE PartyId = @Id)
    BEGIN
        THROW 50052, 'Cannot delete: Party has sales transactions linked to it.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.FleetContracts WHERE PartyId = @Id)
    BEGIN
        THROW 50053, 'Cannot delete: Party has fleet contracts. Delete contracts first.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.CouponBooks WHERE IssuedToPartyId = @Id)
    BEGIN
        THROW 50054, 'Cannot delete: Party has coupon books issued to it.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.CouponTransactions WHERE PartyId = @Id)
    BEGIN
        THROW 50055, 'Cannot delete: Party has coupon transactions linked to it.', 1;
    END

    DELETE FROM PUMP.Parties WHERE Id = @Id AND OwnerId = @OwnerId;

    SELECT @Id AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Party_GetById]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Party_GetById]
(
    @Id BIGINT,
    @OwnerId BIGINT,
    @PumpId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        Id,
        PumpId,
        PartyName,
        PartyType,
        ISNULL(Address, '') AS Address,
        ISNULL(Mobile, '') AS Mobile,
        ISNULL(Email, '') AS Email,
        ISNULL(GSTIN, '') AS GSTIN,
        CreditLimit,
        CurrentBalance,
        IsActive
    FROM PUMP.Parties
    WHERE Id = @Id
      AND OwnerId = @OwnerId
      AND PumpId = @PumpId;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Party_List]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Party_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @SearchTerm NVARCHAR(255) = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 20
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        Id,
        PumpId,
        PartyName,
        PartyType,
        ISNULL(Address, '') AS Address,
        ISNULL(Mobile, '') AS Mobile,
        ISNULL(Email, '') AS Email,
        ISNULL(GSTIN, '') AS GSTIN,
        CreditLimit,
        CurrentBalance,
        IsActive
    FROM PUMP.Parties
    WHERE OwnerId = @OwnerId
      AND PumpId = @PumpId
      AND (@SearchTerm IS NULL OR PartyName LIKE '%' + @SearchTerm + '%' OR Mobile LIKE '%' + @SearchTerm + '%')
    ORDER BY PartyName
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(1)
    FROM PUMP.Parties
    WHERE OwnerId = @OwnerId
      AND PumpId = @PumpId
      AND (@SearchTerm IS NULL OR PartyName LIKE '%' + @SearchTerm + '%' OR Mobile LIKE '%' + @SearchTerm + '%');
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Party_Save]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Party_Save]
(
    @Id BIGINT,
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @PartyName NVARCHAR(150),
    @PartyType NVARCHAR(50),
    @Address NVARCHAR(250),
    @Mobile NVARCHAR(20),
    @Email NVARCHAR(100),
    @GSTIN NVARCHAR(20),
    @CreditLimit DECIMAL(18,2),
    @CurrentBalance DECIMAL(18,2),
    @IsActive BIT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @Id = 0
    BEGIN
        INSERT INTO PUMP.Parties (OwnerId, PumpId, PartyName, PartyType, Address, Mobile, Email, GSTIN, CreditLimit, CurrentBalance, IsActive)
        VALUES (@OwnerId, @PumpId, @PartyName, @PartyType, @Address, @Mobile, @Email, @GSTIN, @CreditLimit, @CurrentBalance, @IsActive);
    END
    ELSE
    BEGIN
        UPDATE PUMP.Parties
        SET PartyName = @PartyName,
            PartyType = @PartyType,
            Address = @Address,
            Mobile = @Mobile,
            Email = @Email,
            GSTIN = @GSTIN,
            CreditLimit = @CreditLimit,
            CurrentBalance = @CurrentBalance,
            IsActive = @IsActive,
            UpdatedOn = SYSDATETIME()
        WHERE Id = @Id
          AND OwnerId = @OwnerId
          AND PumpId = @PumpId;
    END
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_PartyLedger_List]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_PartyLedger_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @PartyId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 300
        pl.Id,
        pl.OwnerId,
        pl.PumpId,
        pl.PartyId,
        p.PartyName,
        pl.EntryType,
        pl.Amount,
        pl.EntryDateTime,
        pl.ReferenceNo,
        pl.Notes
    FROM PUMP.PartyLedger pl
    INNER JOIN PUMP.Parties p ON p.Id = pl.PartyId
    WHERE pl.OwnerId = @OwnerId
      AND pl.PumpId = @PumpId
      AND (@PartyId IS NULL OR pl.PartyId = @PartyId)
    ORDER BY pl.Id DESC;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_PartyLedger_ListPaged]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE OR ALTER PROCEDURE [PUMP].[sp_PartyLedger_ListPaged]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @PartyId BIGINT = NULL,
    @SearchTerm NVARCHAR(100) = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 50
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Offset INT = (@PageNumber - 1) * @PageSize;

    SELECT 
        pl.Id,
        pl.OwnerId,
        pl.PumpId,
        pl.PartyId,
        p.PartyName,
        pl.EntryType,
        pl.Amount,
        pl.EntryDateTime,
        pl.ReferenceNo,
        pl.Notes
    FROM PUMP.PartyLedger pl
    INNER JOIN PUMP.Parties p ON p.Id = pl.PartyId
    WHERE pl.OwnerId = @OwnerId
      AND pl.PumpId = @PumpId
      AND (@PartyId IS NULL OR pl.PartyId = @PartyId)
      AND (@SearchTerm IS NULL 
           OR p.PartyName LIKE '%' + @SearchTerm + '%'
           OR pl.ReferenceNo LIKE '%' + @SearchTerm + '%'
           OR pl.Notes LIKE '%' + @SearchTerm + '%'
           OR pl.EntryType LIKE '%' + @SearchTerm + '%')
    ORDER BY pl.EntryDateTime DESC, pl.Id DESC
    OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(1)
    FROM PUMP.PartyLedger pl
    INNER JOIN PUMP.Parties p ON p.Id = pl.PartyId
    WHERE pl.OwnerId = @OwnerId
      AND pl.PumpId = @PumpId
      AND (@PartyId IS NULL OR pl.PartyId = @PartyId)
      AND (@SearchTerm IS NULL 
           OR p.PartyName LIKE '%' + @SearchTerm + '%'
           OR pl.ReferenceNo LIKE '%' + @SearchTerm + '%'
           OR pl.Notes LIKE '%' + @SearchTerm + '%'
           OR pl.EntryType LIKE '%' + @SearchTerm + '%');
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_PartyLedger_Save]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_PartyLedger_Save]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @PartyId BIGINT,
    @EntryType NVARCHAR(30),
    @Amount DECIMAL(18,2),
    @ReferenceNo NVARCHAR(50) = NULL,
    @Notes NVARCHAR(250) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO PUMP.PartyLedger (OwnerId, PumpId, PartyId, EntryType, Amount, ReferenceNo, Notes)
    VALUES (@OwnerId, @PumpId, @PartyId, @EntryType, @Amount, @ReferenceNo, @Notes);

    UPDATE PUMP.Parties
    SET CurrentBalance = CASE
        WHEN UPPER(@EntryType) IN ('SALE', 'DEBIT', 'CHARGE') THEN CurrentBalance + @Amount
        ELSE CurrentBalance - @Amount
    END,
        UpdatedOn = SYSDATETIME()
    WHERE Id = @PartyId
      AND OwnerId = @OwnerId
      AND PumpId = @PumpId;

    SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Product_Delete]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ============================================================
-- 3. sp_Product_Delete
-- Checks: Nozzles, Tanks, SalesDetails, PurchaseDetails, ShiftNozzleReadings, FleetContracts, ProductRateHistory
-- ============================================================
CREATE OR ALTER PROCEDURE [PUMP].[sp_Product_Delete]
(
    @Id      BIGINT,
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.Products WHERE Id = @Id AND OwnerId = @OwnerId)
    BEGIN
        THROW 50040, 'Product not found or access denied.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.Nozzles WHERE ProductId = @Id)
    BEGIN
        THROW 50041, 'Cannot delete: Product is linked to one or more nozzles. Delete nozzles first.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.Tanks WHERE ProductId = @Id)
    BEGIN
        THROW 50042, 'Cannot delete: Product is linked to one or more tanks. Delete tanks first.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.SalesDetails WHERE ProductId = @Id)
    BEGIN
        THROW 50043, 'Cannot delete: Product has sales transactions. Cannot delete a product with sales.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.PurchaseDetails WHERE ProductId = @Id)
    BEGIN
        THROW 50044, 'Cannot delete: Product has purchase records linked to it.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.FleetContracts WHERE ProductId = @Id)
    BEGIN
        THROW 50045, 'Cannot delete: Product has fleet contracts linked to it.', 1;
    END

    -- Safe to delete rate history first, then product
    DELETE FROM PUMP.ProductRateHistory WHERE ProductId = @Id;
    DELETE FROM PUMP.Products WHERE Id = @Id AND OwnerId = @OwnerId;

    SELECT @Id AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Product_List]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- 2. Alter Product SPs
CREATE OR ALTER PROCEDURE [PUMP].[sp_Product_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        Id,
        PumpId,
        Name,
        Category,
        Unit,
        CurrentRate,
        HSNCode,
        CGSTRate,
        SGSTRate
    FROM PUMP.Products
    WHERE OwnerId = @OwnerId
      AND (@PumpId IS NULL OR PumpId = @PumpId)
      AND IsActive = 1
    ORDER BY Name;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Product_Save]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Product_Save]
(
    @Id BIGINT = NULL,
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @Name NVARCHAR(200),
    @Category NVARCHAR(50),
    @Unit NVARCHAR(20),
    @CurrentRate DECIMAL(18,2),
    @HSNCode NVARCHAR(20) = NULL,
    @CGSTRate DECIMAL(5,2) = 0,
    @SGSTRate DECIMAL(5,2) = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @Id IS NULL OR @Id = 0
    BEGIN
        INSERT INTO PUMP.Products (OwnerId, PumpId, Name, Category, Unit, CurrentRate, HSNCode, CGSTRate, SGSTRate)
        VALUES (@OwnerId, @PumpId, @Name, @Category, @Unit, @CurrentRate, @HSNCode, @CGSTRate, @SGSTRate);
    END
    ELSE
    BEGIN
        UPDATE PUMP.Products
        SET Name = @Name,
            Category = @Category,
            Unit = @Unit,
            CurrentRate = @CurrentRate,
            HSNCode = @HSNCode,
            CGSTRate = @CGSTRate,
            SGSTRate = @SGSTRate,
            UpdatedOn = SYSUTCDATETIME()
        WHERE Id = @Id
          AND OwnerId = @OwnerId
          AND PumpId = @PumpId;
    END
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_ProductRateHistory_List]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_ProductRateHistory_List]
(
    @ProductId BIGINT
,
    @OwnerId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    -- TENANT GUARD
    IF @OwnerId IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM PUMP.Products WHERE Id = @ProductId AND OwnerId = @OwnerId)
        RETURN;

    
    SELECT 
        Id,
        ProductId,
        OldRate,
        NewRate,
        ChangedAt,
        ChangedBy
    FROM PUMP.ProductRateHistory
    WHERE ProductId = @ProductId
    ORDER BY ChangedAt DESC;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Pump_Delete]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ============================================================
-- 9. sp_Pump_Delete
-- Checks: ALL child tables (Tanks, Nozzles, Products, ShiftHeaders, etc.)
-- ============================================================
CREATE OR ALTER PROCEDURE [PUMP].[sp_Pump_Delete]
(
    @Id      BIGINT,
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.Pumps WHERE Id = @Id AND OwnerId = @OwnerId)
    BEGIN
        THROW 50100, 'Pump not found or access denied.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.ShiftHeaders WHERE PumpId = @Id)
    BEGIN
        THROW 50101, 'Cannot delete: Pump has shifts. Close and delete all shifts first.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.Tanks WHERE PumpId = @Id)
    BEGIN
        THROW 50102, 'Cannot delete: Pump has tanks. Delete all tanks first.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.Nozzles WHERE PumpId = @Id)
    BEGIN
        THROW 50103, 'Cannot delete: Pump has nozzles. Delete all nozzles first.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.Products WHERE PumpId = @Id)
    BEGIN
        THROW 50104, 'Cannot delete: Pump has products. Delete all products first.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.Parties WHERE PumpId = @Id)
    BEGIN
        THROW 50105, 'Cannot delete: Pump has parties. Delete all parties first.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.Vendors WHERE PumpId = @Id)
    BEGIN
        THROW 50106, 'Cannot delete: Pump has vendors. Delete all vendors first.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.Employees WHERE PumpId = @Id)
    BEGIN
        THROW 50107, 'Cannot delete: Pump has employees. Delete all employees first.', 1;
    END

    DELETE FROM PUMP.Pumps WHERE Id = @Id AND OwnerId = @OwnerId;

    SELECT @Id AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Pump_List]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- 1. Alter Pump SPs
CREATE OR ALTER PROCEDURE [PUMP].[sp_Pump_List]
(
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        Id,
        Name,
        City,
        Address,
        ContactNo,
        GSTIN
    FROM PUMP.Pumps
    WHERE OwnerId = @OwnerId
      AND IsActive = 1
    ORDER BY Name;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Pump_Save]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Pump_Save]
(
    @Id BIGINT = NULL,
    @OwnerId BIGINT,
    @Name NVARCHAR(200),
    @City NVARCHAR(100) = NULL,
    @Address NVARCHAR(300) = NULL,
    @ContactNo NVARCHAR(20) = NULL,
    @GSTIN NVARCHAR(20) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @Id IS NULL OR @Id = 0
    BEGIN
        INSERT INTO PUMP.Pumps (OwnerId, Name, City, Address, ContactNo, GSTIN)
        VALUES (@OwnerId, @Name, @City, @Address, @ContactNo, @GSTIN);
    END
    ELSE
    BEGIN
        UPDATE PUMP.Pumps
        SET Name = @Name,
            City = @City,
            Address = @Address,
            ContactNo = @ContactNo,
            GSTIN = @GSTIN
        WHERE Id = @Id
          AND OwnerId = @OwnerId;
    END

    SELECT COALESCE(@Id, CAST(SCOPE_IDENTITY() AS BIGINT)) AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Purchase_Delete]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- 3. Delete Purchase (reverses tank stock)
CREATE OR ALTER PROCEDURE [PUMP].[sp_Purchase_Delete]
(
    @Id      BIGINT,
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.PurchaseHeaders WHERE Id = @Id AND OwnerId = @OwnerId)
    BEGIN
        THROW 50012, 'Purchase not found or access denied.', 1;
    END

    DECLARE @PumpId BIGINT;
    SELECT @PumpId = PumpId FROM PUMP.PurchaseHeaders WHERE Id = @Id AND OwnerId = @OwnerId;

    -- Reverse tank stock (deduct what was added)
    UPDATE t
    SET t.CurrentStock = t.CurrentStock - pd.Quantity
    FROM PUMP.Tanks t
    INNER JOIN PUMP.PurchaseDetails pd ON pd.TankId = t.Id
    WHERE pd.PurchaseHeaderId = @Id
      AND t.OwnerId = @OwnerId;

    -- Delete tank transaction records for this purchase
    DELETE FROM PUMP.TankTransactions
    WHERE (ReferenceNo = CONCAT('PURCHASE-', CAST(@Id AS NVARCHAR(20))) OR ReferenceNo = CONCAT('PUR-', CAST(@Id AS NVARCHAR(20))))
      AND OwnerId = @OwnerId;

    -- Delete purchase details then header
    DELETE FROM PUMP.PurchaseDetails WHERE PurchaseHeaderId = @Id;
    DELETE FROM PUMP.PurchaseHeaders WHERE Id = @Id AND OwnerId = @OwnerId;

    SELECT @Id AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Purchase_List]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Purchase_List]
(
    @OwnerId    BIGINT,
    @PumpId     BIGINT,
    @FromDate   DATE        = NULL,
    @ToDate     DATE        = NULL,
    @PageNumber INT         = 1,
    @PageSize   INT         = 20
)
AS
BEGIN
    SET NOCOUNT ON;

    -- Page 1: data rows with total qty per purchase
    SELECT
        ph.Id,
        ph.OwnerId,
        ph.PumpId,
        ph.VendorId,
        ISNULL(v.VendorName, 'Unknown')    AS VendorName,
        ph.InvoiceNo,
        ph.InvoiceDate,
        ph.VehicleNo,
        ph.DriverName,
        ph.TotalAmount,
        ph.Notes,
        ph.CreatedOn,
        -- Sum of all detail lines so UI can show total litres purchased
        ISNULL((
            SELECT SUM(pd.Quantity)
            FROM PUMP.PurchaseDetails pd
            WHERE pd.PurchaseHeaderId = ph.Id
        ), 0) AS TotalQty,
        -- Comma-separated product summary e.g. "Diesel: 1000L @ 95.60"
        ISNULL((
            SELECT STRING_AGG(
                pr.Name + ': ' + CAST(CAST(pd.Quantity AS INT) AS NVARCHAR) + 'L @ ' + NCHAR(8377) + CAST(pd.Rate AS NVARCHAR),
                ' | ')
            FROM PUMP.PurchaseDetails pd
            INNER JOIN PUMP.Products pr ON pr.Id = pd.ProductId
            WHERE pd.PurchaseHeaderId = ph.Id
        ), '') AS ProductSummary
    FROM PUMP.PurchaseHeaders ph
    LEFT JOIN PUMP.Vendors v ON v.Id = ph.VendorId
    WHERE ph.OwnerId = @OwnerId
      AND ph.PumpId  = @PumpId
      AND (@FromDate IS NULL OR CAST(ph.InvoiceDate AS DATE) >= @FromDate)
      AND (@ToDate   IS NULL OR CAST(ph.InvoiceDate AS DATE) <= @ToDate)
    ORDER BY ph.InvoiceDate DESC, ph.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    -- Page 2: total count
    SELECT COUNT(1)
    FROM PUMP.PurchaseHeaders ph
    WHERE ph.OwnerId = @OwnerId
      AND ph.PumpId  = @PumpId
      AND (@FromDate IS NULL OR CAST(ph.InvoiceDate AS DATE) >= @FromDate)
      AND (@ToDate   IS NULL OR CAST(ph.InvoiceDate AS DATE) <= @ToDate);
END
GO
/****** Object:  StoredProcedure [PUMP].[sp_Purchase_PrepareUpdate]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- 2. Create sp_Purchase_PrepareUpdate to revert stock additions and clear details prior to updating
CREATE OR ALTER PROCEDURE [PUMP].[sp_Purchase_PrepareUpdate]
(
    @Id      BIGINT,
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Reverse tank stock (deduct what was added by previous details)
    UPDATE t
    SET t.CurrentStock = t.CurrentStock - pd.Quantity,
        t.UpdatedOn    = SYSDATETIME()
    FROM PUMP.Tanks t
    INNER JOIN PUMP.PurchaseDetails pd ON pd.TankId = t.Id
    WHERE pd.PurchaseHeaderId = @Id
      AND t.OwnerId = @OwnerId;

    -- Delete tank transactions corresponding to this purchase
    DELETE FROM PUMP.TankTransactions
    WHERE (ReferenceNo = CONCAT('PURCHASE-', CAST(@Id AS NVARCHAR(20))) OR ReferenceNo = CONCAT('PUR-', CAST(@Id AS NVARCHAR(20))))
      AND OwnerId = @OwnerId;

    -- Delete old purchase details lines
    DELETE FROM PUMP.PurchaseDetails WHERE PurchaseHeaderId = @Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Purchase_SaveDetail]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Purchase_SaveDetail]
(
    @PurchaseHeaderId BIGINT,
    @ProductId BIGINT,
    @TankId BIGINT = NULL,
    @Quantity DECIMAL(18,3),
    @Rate DECIMAL(18,4),
    @Amount DECIMAL(18,2)
)
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO PUMP.PurchaseDetails (PurchaseHeaderId, ProductId, TankId, Quantity, Rate, Amount)
    VALUES (@PurchaseHeaderId, @ProductId, @TankId, @Quantity, @Rate, @Amount);

    -- Increase Tank Stock if TankId is provided
    IF @TankId IS NOT NULL AND @TankId > 0
    BEGIN
        UPDATE PUMP.Tanks
        SET CurrentStock = CurrentStock + @Quantity,
            UpdatedOn = SYSDATETIME()
        WHERE Id = @TankId;
    END
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Purchase_SaveHeader]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Purchase_SaveHeader]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @VendorId BIGINT,
    @InvoiceNo NVARCHAR(50),
    @InvoiceDate DATE,
    @VehicleNo NVARCHAR(30) = NULL,
    @DriverName NVARCHAR(120) = NULL,
    @TotalAmount DECIMAL(18,2),
    @Notes NVARCHAR(250) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO PUMP.PurchaseHeaders
    (
        OwnerId,
        PumpId,
        VendorId,
        InvoiceNo,
        InvoiceDate,
        VehicleNo,
        DriverName,
        TotalAmount,
        Notes
    )
    VALUES
    (
        @OwnerId,
        @PumpId,
        @VendorId,
        @InvoiceNo,
        @InvoiceDate,
        @VehicleNo,
        @DriverName,
        @TotalAmount,
        @Notes
    );

    SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Purchase_UpdateHeader]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- 3. Create sp_Purchase_UpdateHeader to edit general details of a purchase header
CREATE OR ALTER PROCEDURE [PUMP].[sp_Purchase_UpdateHeader]
(
    @Id          BIGINT,
    @OwnerId     BIGINT,
    @PumpId      BIGINT,
    @VendorId    BIGINT,
    @InvoiceNo   NVARCHAR(50),
    @InvoiceDate DATE,
    @VehicleNo   NVARCHAR(30) = NULL,
    @DriverName  NVARCHAR(120) = NULL,
    @TotalAmount DECIMAL(18,2),
    @Notes       NVARCHAR(250) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE PUMP.PurchaseHeaders
    SET VendorId    = @VendorId,
        InvoiceNo   = @InvoiceNo,
        InvoiceDate = @InvoiceDate,
        VehicleNo   = @VehicleNo,
        DriverName  = @DriverName,
        TotalAmount = @TotalAmount,
        Notes       = @Notes
    WHERE Id = @Id
      AND OwnerId = @OwnerId
      AND PumpId = @PumpId;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Receipt_Generate]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- 4. Alter Receipt Generate SP to include new fields
CREATE OR ALTER PROCEDURE [PUMP].[sp_Receipt_Generate]
(
    @SalesHeaderId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.Receipts WHERE SalesHeaderId = @SalesHeaderId)
    BEGIN
        DECLARE @OwnerId BIGINT;
        DECLARE @PumpId BIGINT;
        DECLARE @BillDateTime DATETIME2;
        DECLARE @FinancialYear NVARCHAR(9);
        DECLARE @Prefix NVARCHAR(20);
        DECLARE @ReceiptNo NVARCHAR(50);

        SELECT
            @OwnerId = OwnerId,
            @PumpId = PumpId,
            @BillDateTime = BillDateTime
        FROM PUMP.SalesHeaders
        WHERE Id = @SalesHeaderId;

        IF @OwnerId IS NULL OR @PumpId IS NULL
        BEGIN
            RAISERROR('Invalid SalesHeaderId for receipt generation.', 16, 1);
            RETURN;
        END

        DECLARE @FYStartYear INT = CASE WHEN MONTH(@BillDateTime) >= 4 THEN YEAR(@BillDateTime) ELSE YEAR(@BillDateTime) - 1 END;
        SET @FinancialYear = CONCAT(@FYStartYear, '-', RIGHT(CAST(@FYStartYear + 1 AS NVARCHAR(4)), 2));
        SET @Prefix = CONCAT('RCP', REPLACE(@FinancialYear, '-', ''), '/');

        DECLARE @Series TABLE (NextNumber NVARCHAR(50));
        INSERT INTO @Series (NextNumber)
        EXEC PUMP.sp_NumberSeries_Next
            @OwnerId = @OwnerId,
            @PumpId = @PumpId,
            @SeriesKey = 'RECEIPT',
            @FinancialYear = @FinancialYear,
            @Prefix = @Prefix,
            @PaddingLength = 6;

        SELECT TOP 1 @ReceiptNo = NextNumber FROM @Series;

        INSERT INTO PUMP.Receipts (SalesHeaderId, ReceiptNo)
        VALUES (@SalesHeaderId, @ReceiptNo);
    END

    -- Get aggregated GST amounts and Pump Details
    SELECT
        r.Id,
        r.SalesHeaderId,
        r.ReceiptNo,
        r.ReceiptDateTime,
        h.BillNo,
        h.BillDateTime,
        h.PaymentMode,
        h.VehicleNo,
        h.CustomerName,
        h.AttendantName,
        h.TotalAmount,
        -- BLOCKER FIX (2026-09-03): TotalQuantity ReceiptDto me tha par SP isse deta hi
        -- nahi tha — isliye har sale ke baad "Sale saved, but receipt generation failed."
        -- aata tha aur customer ko receipt/bill kabhi print nahi hoti thi.
        COALESCE((SELECT SUM(Quantity)   FROM PUMP.SalesDetails WHERE SalesHeaderId = h.Id), 0) AS TotalQuantity,
        COALESCE((SELECT SUM(BaseAmount) FROM PUMP.SalesDetails WHERE SalesHeaderId = h.Id), h.TotalAmount) AS BaseAmount,
        COALESCE((SELECT SUM(CGSTAmount) FROM PUMP.SalesDetails WHERE SalesHeaderId = h.Id), 0) AS TotalCGST,
        COALESCE((SELECT SUM(SGSTAmount) FROM PUMP.SalesDetails WHERE SalesHeaderId = h.Id), 0) AS TotalSGST,
        p.GSTIN AS PumpGSTIN,
        p.Address AS PumpAddress
    FROM PUMP.Receipts r
    INNER JOIN PUMP.SalesHeaders h ON h.Id = r.SalesHeaderId
    INNER JOIN PUMP.Pumps p ON p.Id = h.PumpId
    WHERE r.SalesHeaderId = @SalesHeaderId;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_RefreshToken_GetValid]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_RefreshToken_GetValid]
(
    @TokenHash NVARCHAR(128)
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 1
        Id,
        UserId,
        TokenHash,
        ExpiresOnUtc,
        RevokedOnUtc
    FROM PUMP.UserRefreshTokens
    WHERE TokenHash = @TokenHash
      AND RevokedOnUtc IS NULL
      AND ExpiresOnUtc > SYSDATETIME();
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_RefreshToken_Revoke]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_RefreshToken_Revoke]
(
    @TokenHash NVARCHAR(128),
    @ReplacedByTokenHash NVARCHAR(128) = NULL,
    @Reason NVARCHAR(200) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE PUMP.UserRefreshTokens
    SET RevokedOnUtc = COALESCE(RevokedOnUtc, SYSDATETIME()),
        ReplacedByTokenHash = @ReplacedByTokenHash,
        RevokeReason = @Reason
    WHERE TokenHash = @TokenHash
      AND RevokedOnUtc IS NULL;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_RefreshToken_Save]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_RefreshToken_Save]
(
    @UserId BIGINT,
    @TokenHash NVARCHAR(128),
    @ExpiresOnUtc DATETIME2
)
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO PUMP.UserRefreshTokens
    (
        UserId,
        TokenHash,
        ExpiresOnUtc
    )
    VALUES
    (
        @UserId,
        @TokenHash,
        @ExpiresOnUtc
    );
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Report_DailyStockRegister]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE OR ALTER PROCEDURE [PUMP].[sp_Report_DailyStockRegister]

(

    @PumpId    BIGINT,

    @ProductId BIGINT,

    @Month     INT,

    @Year      INT

,
    @OwnerId BIGINT = NULL
)

AS

BEGIN

    SET NOCOUNT ON;

    -- TENANT GUARD: pump usi owner ka hona chahiye. Pehle is report me OwnerId
    -- tha hi nahi — sirf pumpId guess karke doosre owner ki poore mahine ki
    -- stock report nikaali ja sakti thi.
    IF @OwnerId IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM PUMP.Pumps WHERE Id = @PumpId AND OwnerId = @OwnerId)
        RETURN;




    DECLARE @StartDate DATE = DATEFROMPARTS(@Year, @Month, 1);

    DECLARE @EndDate   DATE = EOMONTH(@StartDate);



    -- 1. Calculate Initial Opening Stock at the start of the month

    DECLARE @InitialOpening DECIMAL(18,3) = 0;

    SELECT @InitialOpening = ISNULL(SUM(CurrentStock), 0)

    FROM PUMP.Tanks

    WHERE PumpId = @PumpId AND ProductId = @ProductId AND IsActive = 1;



    DECLARE @NetChangeSinceStart DECIMAL(18,3) = 0;

    -- Stock badhane wale TxnType wahi hone chahiye jo sp_TankTxn_Save maanta hai:
    -- IN, RECEIPT, PURCHASE, OPENING. Pehle yahan sirf 'IN' likha tha, isliye har
    -- PURCHASE row ko ghatav (-) maan liya jaata tha aur mahine ka opening stock
    -- purchase ki maatra jitna ZYADA dikhta tha. Purchase se ab automatic
    -- TxnType='PURCHASE' row banti hai (dekho sp_Purchase_SaveDetail), isliye ye
    -- galti har delivery par register bigaad rahi thi.
    SELECT @NetChangeSinceStart = ISNULL(

        SUM(CASE WHEN UPPER(TxnType) IN ('IN', 'RECEIPT', 'PURCHASE', 'OPENING')
                 THEN Quantity ELSE -Quantity END), 0)

    FROM PUMP.TankTransactions

    WHERE PumpId = @PumpId

      AND TankId IN (SELECT Id FROM PUMP.Tanks WHERE ProductId = @ProductId AND PumpId = @PumpId)

      AND CAST(TxnDateTime AS DATE) >= @StartDate;



    SET @InitialOpening = @InitialOpening - @NetChangeSinceStart;



    -- 2. Generate Calendar for the Month

    CREATE TABLE #Calendar ( DateValue DATE PRIMARY KEY );

    DECLARE @CurDate DATE = @StartDate;

    WHILE @CurDate <= @EndDate

    BEGIN

        INSERT INTO #Calendar (DateValue) VALUES (@CurDate);

        SET @CurDate = DATEADD(day, 1, @CurDate);

    END



    -- 3. Daily Base Data

    CREATE TABLE #DailyReport

    (

        RowId INT IDENTITY(1,1) PRIMARY KEY,

        [Date] DATE,

        OpeningStock DECIMAL(18,3),

        Receipt DECIMAL(18,3),

        TotalStock DECIMAL(18,3),

        SalesByMeter DECIMAL(18,3),

        PumpTest DECIMAL(18,3),

        NetSalesByMeter DECIMAL(18,3),

        ClosingDipStock DECIMAL(18,3),

        SalesByDip DECIMAL(18,3),

        VariationDaily DECIMAL(18,3),
        -- CA ke liye zaroori: kitaabi closing aur asli (dip) closing ALAG-ALAG
        -- dikhne chahiye. Pehle sirf ek "ClosingStock" tha jo chupke se dip par
        -- switch ho jaata tha - dekhne wale ko pata hi nahi chalta tha ki
        -- variance kis aadhaar par nikla.
        BookClosingStock DECIMAL(18,3),
        PhysicalClosingStock DECIMAL(18,3),
        -- Us din stock physically napa gaya tha ya nahi. Bina iske "variance 0"
        -- ke do matlab ho jaate hain: sab theek, ya napa hi nahi gaya.
        StockChecked BIT,
        -- Us din ka rate aur us hisaab se bikri ki rupee value. CA isi se
        -- register ko bikri khaate aur GST return se milata hai.
        RateApplied DECIMAL(18,3),
        SalesValue DECIMAL(18,2),

        -- Din ke aakhir ka bacha hua stock. Register me ye column tha hi nahi,
        -- jabki DSR ka matlab hi yahi hota hai — aur agle din ka opening isi se
        -- banta hai, to dono ka milna user ko dikhna chahiye.
        ClosingStock DECIMAL(18,3),

        -- Nuksaan/faayde ke PAISE. "45 litre kam hai" se zyada matlab
        -- "Rs 4,302 ka nuksaan" rakhta hai — pump wale ko yahi dekhna hota hai.
        VariationValue DECIMAL(18,2),

        Remarks NVARCHAR(255)

    );



    INSERT INTO #DailyReport ([Date], Receipt, SalesByMeter, PumpTest, NetSalesByMeter, ClosingDipStock)

    SELECT

        c.DateValue,

        -- Receipts (excluding internal adjustments and reconciliations)

        ISNULL((

            SELECT SUM(Quantity)

            FROM PUMP.TankTransactions

            WHERE PumpId   = @PumpId

              -- Sirf 'IN' dekhne se tanker delivery (TxnType='PURCHASE') Receipt me
              -- 0 dikhti thi. Ab wahi chaar type jo stock badhate hain.
              AND UPPER(TxnType) IN ('IN', 'RECEIPT', 'PURCHASE', 'OPENING')

              AND TankId IN (SELECT Id FROM PUMP.Tanks WHERE ProductId = @ProductId AND PumpId = @PumpId)

              AND CAST(TxnDateTime AS DATE) = c.DateValue

              -- ISNULL zaroori hai: SQL me "NULL NOT LIKE '...'" ka jawab NULL hota
              -- hai, TRUE nahi — yaani jis entry me ReferenceNo khaali chhoda gaya
              -- (manual tank stock entry) wo chupchaap Receipt se gayab ho jaati thi.
              AND ISNULL(ReferenceNo, N'') NOT LIKE 'LOSS-DEL-%'

              AND ISNULL(ReferenceNo, N'') NOT LIKE 'VOID-SALE-%'

              AND ISNULL(ReferenceNo, N'') NOT LIKE 'SHIFT-EDIT-%'

              AND ISNULL(ReferenceNo, N'') NOT LIKE 'RECON-%'

        ), 0) AS Receipt,

        -- Gross Sales grouped by ShiftDate

        ISNULL((

            SELECT SUM(snr.SoldQty + snr.TestingLoss)

            FROM PUMP.ShiftNozzleReadings snr

            INNER JOIN PUMP.ShiftHeaders sh ON sh.Id = snr.ShiftId

            WHERE snr.ProductId = @ProductId AND sh.PumpId = @PumpId

              AND sh.Status = 'CLOSED'

              AND sh.ShiftDate = c.DateValue

        ), 0) AS SalesByMeter,

        -- Pump Test grouped by ShiftDate

        ISNULL((

            SELECT SUM(snr.TestingLoss)

            FROM PUMP.ShiftNozzleReadings snr

            INNER JOIN PUMP.ShiftHeaders sh ON sh.Id = snr.ShiftId

            WHERE snr.ProductId = @ProductId AND sh.PumpId = @PumpId

              AND sh.Status = 'CLOSED'

              AND sh.ShiftDate = c.DateValue

        ), 0) AS PumpTest,

        -- Net Sales grouped by ShiftDate

        ISNULL((

            SELECT SUM(snr.SoldQty)

            FROM PUMP.ShiftNozzleReadings snr

            INNER JOIN PUMP.ShiftHeaders sh ON sh.Id = snr.ShiftId

            WHERE snr.ProductId = @ProductId AND sh.PumpId = @PumpId

              AND sh.Status = 'CLOSED'

              AND sh.ShiftDate = c.DateValue

        ), 0) AS NetSalesByMeter,

        -- Closing physical dip stock

        ISNULL(

            (

                SELECT SUM(ActualStock) FROM (

                    SELECT dr.ActualStock,

                           ROW_NUMBER() OVER (PARTITION BY dr.TankId ORDER BY dr.Id DESC) as rn

                    FROM PUMP.DipReadings dr

                    INNER JOIN PUMP.Tanks tk ON tk.Id = dr.TankId

                    WHERE tk.PumpId = @PumpId AND tk.ProductId = @ProductId

                      AND dr.ReadingDate = c.DateValue

                      /* Dip list me switch band karne par row par laal "Deleted" ka
                         nishaan aa jaata hai, par ye query use phir bhi ginti thi -
                         yaani hataayi hui dip chupchaap poore din ka closing banti
                         rehti thi, aur wahi agle din ka opening bhi ban jaata tha. */
                      AND dr.IsActive = 1

                ) x WHERE x.rn = 1

            ),

            ISNULL(

                (

                    SELECT SUM(PhysicalStock) FROM (

                        SELECT sr.PhysicalStock,

                               ROW_NUMBER() OVER (PARTITION BY sr.TankId ORDER BY sr.Id DESC) as rn

                        FROM PUMP.StockReconciliations sr

                        INNER JOIN PUMP.Tanks tk ON tk.Id = sr.TankId

                        WHERE tk.PumpId = @PumpId AND tk.ProductId = @ProductId

                          AND CAST(sr.ReconciliationDate AS DATE) = c.DateValue

                    ) y WHERE y.rn = 1

                ), 0

            )

        ) AS ClosingDipStock

    FROM #Calendar c

    ORDER BY c.DateValue;



    -- 4. Iterative Calculation for Running Totals

    DECLARE @i INT = 1;

    DECLARE @MaxI INT;

    SELECT @MaxI = MAX(RowId) FROM #DailyReport;



    DECLARE @CurrentOpening DECIMAL(18,3) = @InitialOpening;

    DECLARE @Receipt DECIMAL(18,3), @NetSales DECIMAL(18,3), @Dip DECIMAL(18,3);




    WHILE @i <= @MaxI

    BEGIN

        SELECT

            @Receipt = Receipt,

            @NetSales = NetSalesByMeter,

            @Dip = ClosingDipStock

        FROM #DailyReport WHERE RowId = @i;



        DECLARE @ReportDate DATE = (SELECT [Date] FROM #DailyReport WHERE RowId = @i);

        /* "Aaj stock physically napa gaya tha ya nahi" — ye dip AUR reconciliation
           dono se aa sakta hai. Pehle sirf DipReadings ginti thi, isliye jis din
           sirf reconciliation hui thi us din variance zabardasti 0 dikhta tha,
           jabki ClosingDipStock me reconciliation ka physical stock pehle se
           aa raha tha. Nateeja: nuksaan sirf Remarks ke text me dikhta tha,
           Variation column aur mahine ke cumulative variance me nahi. */
        DECLARE @HasDip INT =
        (
            SELECT COUNT(1) FROM PUMP.DipReadings
            WHERE TankId IN (SELECT Id FROM PUMP.Tanks WHERE ProductId = @ProductId AND PumpId = @PumpId)
              AND ReadingDate = @ReportDate
              /* Upar wali query se milna zaroori hai: wahan dip chhut jaye aur
                 yahan gin li jaye to "Stock Checked = Yes" dikhega jabki variance
                 kisi aur hi aadhaar par nikla hoga. */
              AND IsActive = 1
        )
        +
        (
            SELECT COUNT(1) FROM PUMP.StockReconciliations
            WHERE TankId IN (SELECT Id FROM PUMP.Tanks WHERE ProductId = @ProductId AND PumpId = @PumpId)
              AND CAST(ReconciliationDate AS DATE) = @ReportDate
        );

        /* @Dip aage badal jaata hai (jis din napa nahi gaya us din use kitaabi
           stock se bhar dete hain), isliye asli napa hua stock yahin alag rakh
           lete hain - register me wahi dikhana hai. */
        DECLARE @MeasuredDip DECIMAL(18,3) = CASE WHEN @HasDip > 0 THEN @Dip ELSE NULL END;

        DECLARE @Total DECIMAL(18,3) = @CurrentOpening + @Receipt;
        DECLARE @SalesDip DECIMAL(18,3);
        DECLARE @VarDaily DECIMAL(18,3);

        /* Us din ka rate — mahine ke beech rate badla ho to har din apne rate par
           gina jaye, warna nuksaan ki value galat banegi. */
        DECLARE @DayRate DECIMAL(18,3) =
            PUMP.fn_ProductRateOnDate(@ProductId, DATEADD(HOUR, 23, CAST(@ReportDate AS DATETIME2(7))));

        /* Kitaabi (book) closing — jitna stock hona chahiye tha. Net se ghatao:
           test ka tel wapas tank me chala jaata hai, isliye wo tank se gaya hi nahi. */
        DECLARE @BookClosing DECIMAL(18,3) = @Total - @NetSales;

        IF @HasDip = 0
        BEGIN
            /* Aaj stock napa hi nahi gaya — variance ka koi sawaal nahi. */
            SET @SalesDip = @NetSales;
            SET @Dip = CASE WHEN @NetSales > 0 THEN @BookClosing ELSE @Dip END;
            SET @VarDaily = 0;
        END
        ELSE
        BEGIN
            /* Variance = physical - book. Minus = nuksaan (laal), plus = zyada
               nikla (hara). Pehle ulta tha (@SalesDip - @NetSales), isliye ek hi
               row me Remarks "-45" bolti thi aur Variation column "+45".
               StockReconciliations.VarianceQty aur DipReadings.Variance dono
               physical-book hi rakhte hain, ab register bhi wahi bolta hai. */
            SET @VarDaily = CASE WHEN @Dip > 0 THEN @Dip - @BookClosing ELSE 0 END;

            /* Dip se nikli sale = jitna stock ghata. Agar dip kitaabi stock se
               ZYADA nikle (bina entry wali delivery, ya galat purani entry) to ye
               rinaatmak ho jaata tha — "-7,916 litre bika" jaisi bekaar line.
               Sale kabhi minus nahi hoti; aisi soorat me 0 dikhao aur poori kahani
               Variation column me aa jaati hai. */
            SET @SalesDip =
                CASE WHEN @Dip > 0 AND @Total > @Dip THEN @Total - @Dip ELSE 0 END;
        END



        -- Fetch saved manual reconciliation variance

        DECLARE @ManualVar DECIMAL(18,3) = 0;

        DECLARE @ReconCount INT = 0;

        SELECT

            @ManualVar = ISNULL(SUM(VarianceQty), 0),

            @ReconCount = COUNT(Id)

        FROM PUMP.StockReconciliations

        WHERE TankId IN (SELECT Id FROM PUMP.Tanks WHERE ProductId = @ProductId AND PumpId = @PumpId)

          AND CAST(ReconciliationDate AS DATE) = (SELECT [Date] FROM #DailyReport WHERE RowId = @i);



        DECLARE @RemarksStr NVARCHAR(255) = NULL;

        /* Remarks me pehle bas 'Variance' likha aata tha. CA ko usse kuch pata
           nahi chalta tha: kitna, kis taraf, aur us din tank napa bhi gaya tha
           ya nahi. Khaali variance column ka matlab log "sab theek" samajh lete
           the, jabki asal me us din dip li hi nahi gayi hoti thi.
           Ab poori baat likhi jaati hai. */
        IF @ReconCount > 0
        BEGIN
            SET @RemarksStr = CONCAT('Reconciled by hand. Difference ',
                CASE WHEN @ManualVar < 0 THEN 'short ' ELSE 'excess ' END,
                CAST(CAST(ABS(@ManualVar) AS DECIMAL(18,1)) AS NVARCHAR(20)), ' L.');
        END
        ELSE IF @HasDip = 0
        BEGIN
            SET @RemarksStr = CASE WHEN @NetSales > 0 THEN N'Stock not measured' ELSE NULL END;
        END
        ELSE IF @VarDaily = 0
        BEGIN
            SET @RemarksStr = N'Dip matches book';
        END
        ELSE
        BEGIN
            SET @RemarksStr = CONCAT(
                CASE WHEN @VarDaily < 0 THEN 'Short ' ELSE 'Excess ' END,
                CAST(CAST(ABS(@VarDaily) AS DECIMAL(18,1)) AS NVARCHAR(20)), ' L',
                /* Seedha NVARCHAR me daalne par 'Rs 371.000000' chhapta tha -
                   pehle DECIMAL(18,0) me le aate hain, tabhi 'Rs 371' aata hai. */
                ' (Rs ', CAST(CAST(ABS(ROUND(@VarDaily * @DayRate, 0)) AS DECIMAL(18,0)) AS NVARCHAR(20)), ')');
        END



        -- Aaj ka closing = physical dip (agar liya gaya ho) warna kitaabi stock.
        -- Yahi agle din ka opening banega, isliye ek hi jagah nikaal kar dono me
        -- daal rahe hain — warna register ki do lines aapas me nahi milengi.
        DECLARE @ClosingStk DECIMAL(18,3) =
            CASE WHEN @Dip > 0 THEN @Dip ELSE @BookClosing END;

        UPDATE #DailyReport

        SET

            OpeningStock = @CurrentOpening,

            TotalStock = @Total,

            SalesByDip = @SalesDip,

            VariationDaily = @VarDaily,

            ClosingStock = @ClosingStk,

            BookClosingStock = @BookClosing,

            PhysicalClosingStock = @MeasuredDip,

            StockChecked = CASE WHEN @HasDip > 0 THEN 1 ELSE 0 END,

            RateApplied = @DayRate,

            SalesValue = ROUND(@NetSales * @DayRate, 2),

            VariationValue = ROUND(@VarDaily * @DayRate, 2),

            Remarks = @RemarksStr

        WHERE RowId = @i;



        SET @CurrentOpening = @ClosingStk;



        SET @i = @i + 1;

    END



    -- 5. Final Output

    SELECT

        DAY([Date])                                   AS DayOfMonth,

        [Date],

        CAST(OpeningStock    AS DECIMAL(18,0))        AS OpeningStock,

        CAST(Receipt         AS DECIMAL(18,0))        AS Receipt,

        CAST(TotalStock      AS DECIMAL(18,0))        AS TotalStock,

        CAST(SalesByMeter    AS DECIMAL(18,0))        AS SalesByMeter,

        CAST(PumpTest        AS DECIMAL(18,0))        AS PumpTest,

        CAST(NetSalesByMeter AS DECIMAL(18,0))        AS NetSalesByMeter,

        CAST(SUM(NetSalesByMeter) OVER (ORDER BY [Date]) AS DECIMAL(18,0)) AS CumulativeSales,

        CAST(SalesByDip      AS DECIMAL(18,0))        AS SalesByDip,

        /* Kitaabi closing = opening + receipt - net sale. Jitna hona chahiye tha. */

        CAST(BookClosingStock AS DECIMAL(18,0))       AS BookClosingStock,

        /* Asli napa hua stock. Jis din napa nahi gaya us din NULL - register me

           "-" dikhta hai, 0 nahi (0 ka matlab "tank khaali tha" hota hai). */

        CAST(PhysicalClosingStock AS DECIMAL(18,0))   AS PhysicalClosingStock,

        ISNULL(StockChecked, 0)                       AS StockChecked,

        CAST(ClosingStock    AS DECIMAL(18,0))        AS ClosingStock,

        /* Ye do column jaanbujh ke 2 decimal me hain (baaki poore litre me).
           Variance me chhote fraction bhi maayne rakhte hain: 0.46 L roz ka
           nuksaan poore litre me round hokar "0" dikhta tha, jabki mahine bhar
           me 14 litre ban jaata hai — aur uski rupee value column me dikhti bhi
           thi, to row aapas me ulat lagti thi (Variation 0, Value -Rs 43.98). */
        CAST(VariationDaily  AS DECIMAL(18,2))        AS VariationDaily,

        ISNULL(VariationValue, 0)                     AS VariationValue,

   CAST(SUM(VariationDaily) OVER (ORDER BY [Date]) AS DECIMAL(18,2)) AS VariationCumulative,

        /* Rate aur rupee value - CA register ko bikri khaate se yahin milata hai. */

        ISNULL(RateApplied, 0)                        AS RateApplied,

        ISNULL(SalesValue, 0)                         AS SalesValue,

        CAST(SUM(ISNULL(SalesValue, 0)) OVER (ORDER BY [Date]) AS DECIMAL(18,2)) AS CumulativeSalesValue,

        Remarks

    FROM #DailyReport

    ORDER BY [Date];



    DROP TABLE #Calendar;

    DROP TABLE #DailyReport;

END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Report_DayBook]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Report_DayBook]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @DateFrom DATE,
    @DateTo DATE
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        x.EntryDateTime,
        x.EntryType,
        x.ReferenceNo,
        x.Description,
        x.Debit,
        x.Credit
    FROM
    (
        SELECT
            sh.BillDateTime AS EntryDateTime,
            CAST('SALE' AS NVARCHAR(30)) AS EntryType,
            sh.BillNo AS ReferenceNo,
            CONCAT('Sale - ', ISNULL(sh.CustomerName, 'Walk-In')) AS Description,
            CAST(0 AS DECIMAL(18,2)) AS Debit,
            sh.TotalAmount AS Credit
        FROM PUMP.SalesHeaders sh
        WHERE sh.OwnerId = @OwnerId
          AND sh.PumpId = @PumpId
          AND CAST(sh.BillDateTime AS DATE) BETWEEN @DateFrom AND @DateTo
          AND sh.IsVoid = 0

        UNION ALL

        SELECT
            ph.CreatedOn,
            CAST('PURCHASE' AS NVARCHAR(30)),
            ph.InvoiceNo,
            CONCAT('Purchase - ', v.VendorName),
            ph.TotalAmount,
            CAST(0 AS DECIMAL(18,2))
        FROM PUMP.PurchaseHeaders ph
        INNER JOIN PUMP.Vendors v ON v.Id = ph.VendorId
        WHERE ph.OwnerId = @OwnerId
          AND ph.PumpId = @PumpId
          AND CAST(ph.CreatedOn AS DATE) BETWEEN @DateFrom AND @DateTo

        UNION ALL

        SELECT
            et.TxnDateTime,
            CAST('EXPENSE' AS NVARCHAR(30)),
            et.ReferenceNo,
            CONCAT('Expense - ', eh.HeadName),
            et.Amount,
            CAST(0 AS DECIMAL(18,2))
        FROM PUMP.ExpenseTransactions et
        INNER JOIN PUMP.ExpenseHeads eh ON eh.Id = et.ExpenseHeadId
        WHERE et.OwnerId = @OwnerId
          AND et.PumpId = @PumpId
          AND CAST(et.TxnDateTime AS DATE) BETWEEN @DateFrom AND @DateTo

        UNION ALL

        SELECT
            ct.TxnDateTime,
            CAST('CASH' AS NVARCHAR(30)),
            ct.ReferenceNo,
            CONCAT('Cash ', UPPER(ct.TxnType), ' - ', ISNULL(ct.Narration, 'Manual')),
            CASE WHEN UPPER(ct.TxnType) = 'OUT' THEN ct.Amount ELSE CAST(0 AS DECIMAL(18,2)) END,
            CASE WHEN UPPER(ct.TxnType) = 'IN' THEN ct.Amount ELSE CAST(0 AS DECIMAL(18,2)) END
        FROM PUMP.CashTransactions ct
        WHERE ct.OwnerId = @OwnerId
          AND ct.PumpId = @PumpId
          AND CAST(ct.TxnDateTime AS DATE) BETWEEN @DateFrom AND @DateTo
    ) x
    ORDER BY x.EntryDateTime DESC;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Report_Outstanding]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Report_Outstanding]
(
    @OwnerId BIGINT,
    @PumpId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        p.Id AS PartyId,
        p.PartyName,
        p.PartyType,
        p.CreditLimit,
        p.CurrentBalance,
        LastSaleDate = MAX(CASE WHEN UPPER(sh.PaymentMode) = 'CREDIT' THEN sh.BillDateTime END)
    FROM PUMP.Parties p
    LEFT JOIN PUMP.SalesHeaders sh
        ON sh.OwnerId = p.OwnerId
       AND sh.PumpId = p.PumpId
       AND sh.PartyId = p.Id
       AND sh.IsVoid = 0
    WHERE p.OwnerId = @OwnerId
      AND p.PumpId = @PumpId
      AND p.IsActive = 1
    GROUP BY p.Id, p.PartyName, p.PartyType, p.CreditLimit, p.CurrentBalance
    ORDER BY p.CurrentBalance DESC, p.PartyName;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Report_PumpComparison]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Report_PumpComparison]
(
    @OwnerId BIGINT,
    @DateFrom DATE,
    @DateTo DATE
)
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH SalesCTE AS
    (
        SELECT
            sh.PumpId,
            SUM(sh.TotalAmount) AS SalesAmount
        FROM PUMP.SalesHeaders sh
        WHERE sh.OwnerId = @OwnerId
          AND CAST(sh.BillDateTime AS DATE) BETWEEN @DateFrom AND @DateTo
          AND sh.IsVoid = 0
        GROUP BY sh.PumpId
    ),
    PurchaseCTE AS
    (
        SELECT
            ph.PumpId,
            SUM(ph.TotalAmount) AS PurchaseAmount
        FROM PUMP.PurchaseHeaders ph
        WHERE ph.OwnerId = @OwnerId
          AND CAST(ph.CreatedOn AS DATE) BETWEEN @DateFrom AND @DateTo
        GROUP BY ph.PumpId
    ),
    ExpenseCTE AS
    (
        SELECT
            e.PumpId,
            SUM(e.Amount) AS ExpenseAmount
        FROM PUMP.ExpenseTransactions e
        WHERE e.OwnerId = @OwnerId
          AND CAST(e.TxnDateTime AS DATE) BETWEEN @DateFrom AND @DateTo
        GROUP BY e.PumpId
    )
    SELECT
        p.Id AS PumpId,
        p.Name AS PumpName,
        p.City,
        SalesAmount = ISNULL(s.SalesAmount, 0),
        PurchaseAmount = ISNULL(pr.PurchaseAmount, 0),
        ExpenseAmount = ISNULL(e.ExpenseAmount, 0),
        NetAmount = ISNULL(s.SalesAmount, 0) - ISNULL(pr.PurchaseAmount, 0) - ISNULL(e.ExpenseAmount, 0)
    FROM PUMP.Pumps p
    LEFT JOIN SalesCTE s ON s.PumpId = p.Id
    LEFT JOIN PurchaseCTE pr ON pr.PumpId = p.Id
    LEFT JOIN ExpenseCTE e ON e.PumpId = p.Id
    WHERE p.OwnerId = @OwnerId
      AND p.IsActive = 1
    ORDER BY NetAmount DESC, p.Name;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Role_List]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Role_List]
(
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        Id,
        OwnerId,
        Name,
        IsSystem,
        IsActive
    FROM PUMP.Roles
    WHERE IsActive = 1
      AND OwnerId = @OwnerId
    ORDER BY Name;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Role_Save]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Role_Save]
(
    @Id BIGINT = NULL,
    @OwnerId BIGINT,
    @Name NVARCHAR(100),
    @IsSystem BIT = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @Id IS NULL OR @Id = 0
    BEGIN
        INSERT INTO PUMP.Roles (OwnerId, Name, IsSystem)
        VALUES (@OwnerId, @Name, @IsSystem);

        SET @Id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE PUMP.Roles
        SET Name = @Name,
            IsSystem = @IsSystem
        WHERE Id = @Id;
    END

    SELECT @Id AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_RoleMenu_GetByRole]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_RoleMenu_GetByRole]
(
    @RoleId BIGINT
,
    @OwnerId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    -- TENANT GUARD
    IF @OwnerId IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM PUMP.Roles WHERE Id = @RoleId AND OwnerId = @OwnerId)
        RETURN;

    SELECT 
        Id,
        RoleId,
        MenuId,
        CanView,
        CanCreate,
        CanEdit,
        CanDelete
    FROM PUMP.RoleMenus
    WHERE RoleId = @RoleId;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_RoleMenu_Save]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_RoleMenu_Save]
(
    @RoleId BIGINT,
    @RoleMenus PUMP.udt_RoleMenuType READONLY
)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;
        
        -- Delete existing mappings for the role
        DELETE FROM PUMP.RoleMenus WHERE RoleId = @RoleId;
        
        -- Insert new mappings
        INSERT INTO PUMP.RoleMenus (RoleId, MenuId, CanView, CanCreate, CanEdit, CanDelete)
        SELECT @RoleId, MenuId, CanView, CanCreate, CanEdit, CanDelete
        FROM @RoleMenus;
        
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_SalaryPayment_List]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_SalaryPayment_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @SalaryYear INT = NULL,
    @SalaryMonth INT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        s.Id,
        s.OwnerId,
        s.PumpId,
        s.EmployeeId,
        e.EmployeeCode,
        e.FullName AS EmployeeName,
        s.SalaryYear,
        s.SalaryMonth,
        s.Amount,
        s.PaidOn,
        s.PaymentMode,
        s.ReferenceNo,
        s.Notes,
        s.CreatedOn
    FROM PUMP.SalaryPayments s
    INNER JOIN PUMP.Employees e ON e.Id = s.EmployeeId
    WHERE s.OwnerId = @OwnerId
      AND s.PumpId = @PumpId
      AND (@SalaryYear IS NULL OR s.SalaryYear = @SalaryYear)
      AND (@SalaryMonth IS NULL OR s.SalaryMonth = @SalaryMonth)
    ORDER BY s.SalaryYear DESC, s.SalaryMonth DESC, e.FullName;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_SalaryPayment_Save]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_SalaryPayment_Save]
(
    @Id BIGINT = NULL,
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @EmployeeId BIGINT,
    @SalaryYear INT,
    @SalaryMonth INT,
    @Amount DECIMAL(18,2),
    @PaidOn DATE,
    @PaymentMode NVARCHAR(20) = 'Cash',
    @ReferenceNo NVARCHAR(60) = NULL,
    @Notes NVARCHAR(250) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ExistingId BIGINT;
    IF ISNULL(@Id, 0) = 0
    BEGIN
        SELECT TOP 1 @ExistingId = Id
        FROM PUMP.SalaryPayments
        WHERE OwnerId = @OwnerId
          AND PumpId = @PumpId
          AND EmployeeId = @EmployeeId
          AND SalaryYear = @SalaryYear
          AND SalaryMonth = @SalaryMonth;

        IF @ExistingId IS NOT NULL
        BEGIN
            SET @Id = @ExistingId;
        END
    END

    IF ISNULL(@Id, 0) = 0
    BEGIN
        INSERT INTO PUMP.SalaryPayments
        (
            OwnerId, PumpId, EmployeeId, SalaryYear, SalaryMonth, Amount, PaidOn, PaymentMode, ReferenceNo, Notes
        )
        VALUES
        (
            @OwnerId, @PumpId, @EmployeeId, @SalaryYear, @SalaryMonth, @Amount, @PaidOn, @PaymentMode, @ReferenceNo, @Notes
        );

        SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS Id;
        RETURN;
    END

    UPDATE PUMP.SalaryPayments
    SET EmployeeId = @EmployeeId,
        SalaryYear = @SalaryYear,
        SalaryMonth = @SalaryMonth,
        Amount = @Amount,
        PaidOn = @PaidOn,
        PaymentMode = @PaymentMode,
        ReferenceNo = @ReferenceNo,
        Notes = @Notes,
        UpdatedOn = SYSDATETIME()
    WHERE Id = @Id
      AND OwnerId = @OwnerId
      AND PumpId = @PumpId;

    SELECT @Id AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Sale_Void]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ============================================================
-- 016: Void Sale, Delete Expense, Delete Purchase
-- ============================================================

-- 1. Sale Void/Cancel
CREATE OR ALTER PROCEDURE [PUMP].[sp_Sale_Void]
(
    @Id     BIGINT,
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.SalesHeaders WHERE Id = @Id AND OwnerId = @OwnerId)
    BEGIN
        THROW 50010, 'Sale not found, or you do not have access to it.', 1;
    END

    DECLARE @PartyId     BIGINT;
    DECLARE @TotalAmount DECIMAL(18,2);
    DECLARE @PaymentMode NVARCHAR(30);

    SELECT
        @PartyId     = PartyId,
        @TotalAmount = TotalAmount,
        @PaymentMode = PaymentMode
    FROM PUMP.SalesHeaders
    WHERE Id = @Id AND OwnerId = @OwnerId;

    -- Reverse party ledger entry if credit sale
    IF UPPER(ISNULL(@PaymentMode,'')) = 'CREDIT' AND @PartyId IS NOT NULL
    BEGIN
        UPDATE PUMP.Parties
        SET CurrentBalance = CurrentBalance - @TotalAmount,
            UpdatedOn      = SYSDATETIME()
        WHERE Id = @PartyId AND OwnerId = @OwnerId;

        INSERT INTO PUMP.PartyLedger (OwnerId, PumpId, PartyId, EntryType, Amount, ReferenceNo, Notes)
        SELECT OwnerId, PumpId, @PartyId, 'VOID', -@TotalAmount,
               CONCAT('VOID-SALE-', @Id), CONCAT('Void of sale #', @Id)
        FROM PUMP.SalesHeaders WHERE Id = @Id;
    END

    -- Delete sale details then header
    DELETE FROM PUMP.SalesDetails WHERE SalesHeaderId = @Id;
    DELETE FROM PUMP.Receipts      WHERE SalesHeaderId = @Id;
    DELETE FROM PUMP.SalesHeaders  WHERE Id = @Id AND OwnerId = @OwnerId;

    SELECT @Id AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Sales_List]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Sales_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT = NULL,
    @FromDate DATETIME2 = NULL,
    @ToDate DATETIME2 = NULL,
    @SearchTerm NVARCHAR(100) = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 50
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Offset INT = (@PageNumber - 1) * @PageSize;

    SELECT
        h.Id,
        h.OwnerId,
        h.PumpId,
        h.ShiftId,
        h.PartyId,
        h.BillNo,
        h.BillDateTime,
        h.PaymentMode,
        h.VehicleNo,
        h.CustomerName,
        h.AttendantName,
        h.TotalAmount
    FROM PUMP.SalesHeaders h
    WHERE h.OwnerId = @OwnerId
      AND (@PumpId IS NULL OR @PumpId <= 0 OR h.PumpId = @PumpId)
      AND (@FromDate IS NULL OR h.BillDateTime >= @FromDate)
      AND (@ToDate IS NULL OR h.BillDateTime <= @ToDate)
      AND (@SearchTerm IS NULL OR @SearchTerm = '' OR h.BillNo LIKE '%' + @SearchTerm + '%' OR h.VehicleNo LIKE '%' + @SearchTerm + '%' OR h.CustomerName LIKE '%' + @SearchTerm + '%')
    ORDER BY h.Id DESC
    OFFSET @Offset ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(1)
    FROM PUMP.SalesHeaders h
    WHERE h.OwnerId = @OwnerId
      AND (@PumpId IS NULL OR @PumpId <= 0 OR h.PumpId = @PumpId)
      AND (@FromDate IS NULL OR h.BillDateTime >= @FromDate)
      AND (@ToDate IS NULL OR h.BillDateTime <= @ToDate)
      AND (@SearchTerm IS NULL OR @SearchTerm = '' OR h.BillNo LIKE '%' + @SearchTerm + '%' OR h.VehicleNo LIKE '%' + @SearchTerm + '%' OR h.CustomerName LIKE '%' + @SearchTerm + '%');
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Sales_SaveDetail]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- 3. Alter Sales Detail Save SP
CREATE OR ALTER PROCEDURE [PUMP].[sp_Sales_SaveDetail]
(
    @SalesHeaderId BIGINT,
    @ProductId BIGINT,
    @NozzleNo NVARCHAR(30) = NULL,
    @Quantity DECIMAL(18,3),
    @Rate DECIMAL(18,2),
    @Amount DECIMAL(18,2),
    @BaseAmount DECIMAL(18,2) = 0,
    @CGSTAmount DECIMAL(18,2) = 0,
    @SGSTAmount DECIMAL(18,2) = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO PUMP.SalesDetails
    (
        SalesHeaderId,
        ProductId,
        NozzleNo,
        Quantity,
        Rate,
        Amount,
        BaseAmount,
        CGSTAmount,
        SGSTAmount
    )
    VALUES
    (
        @SalesHeaderId,
        @ProductId,
        @NozzleNo,
        @Quantity,
        @Rate,
        @Amount,
        @BaseAmount,
        @CGSTAmount,
        @SGSTAmount
    );
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Sales_SaveHeader]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Sales_SaveHeader]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @ShiftId BIGINT,
    @PartyId BIGINT = NULL,
    @BillNo NVARCHAR(50),
    @BillDateTime DATETIME2,
    @PaymentMode NVARCHAR(30),
    @VehicleNo NVARCHAR(30) = NULL,
    @CustomerName NVARCHAR(120) = NULL,
    @AttendantName NVARCHAR(120) = NULL,
    @TotalAmount DECIMAL(18,2)
)
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO PUMP.SalesHeaders
    (
        OwnerId,
        PumpId,
        ShiftId,
        PartyId,
        BillNo,
        BillDateTime,
        PaymentMode,
        VehicleNo,
        CustomerName,
        AttendantName,
        TotalAmount
    )
    VALUES
    (
        @OwnerId,
        @PumpId,
        @ShiftId,
        @PartyId,
        @BillNo,
        @BillDateTime,
        @PaymentMode,
        @VehicleNo,
        @CustomerName,
        @AttendantName,
        @TotalAmount
    );

    SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS Id;

    DECLARE @NewSalesHeaderId BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);
    IF UPPER(@PaymentMode) = 'CREDIT' AND @PartyId IS NOT NULL
    BEGIN
        INSERT INTO PUMP.PartyLedger (OwnerId, PumpId, PartyId, EntryType, Amount, ReferenceNo, Notes)
        VALUES (@OwnerId, @PumpId, @PartyId, 'SALE', @TotalAmount, @BillNo, CONCAT('Auto from sale #', @NewSalesHeaderId));

        UPDATE PUMP.Parties
        SET CurrentBalance = CurrentBalance + @TotalAmount,
            UpdatedOn = SYSDATETIME()
        WHERE Id = @PartyId
          AND OwnerId = @OwnerId
          AND PumpId = @PumpId;
    END
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Shift_Close]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- Fix 3: sp_Shift_Close â€” allow re-editing a CLOSED shift
CREATE OR ALTER PROCEDURE [PUMP].[sp_Shift_Close]
(
    @Id         BIGINT,
    @ClosingCash DECIMAL(18,2) = NULL,
    @Notes       NVARCHAR(500) = NULL,
    @NozzleReadingsJson NVARCHAR(MAX) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @OwnerId BIGINT;
    DECLARE @PumpId  BIGINT;
    DECLARE @Status  NVARCHAR(20);

    SELECT TOP 1
        @OwnerId = OwnerId,
        @PumpId  = PumpId,
        @Status  = Status
    FROM PUMP.ShiftHeaders
    WHERE Id = @Id;

    IF @Id IS NULL OR @OwnerId IS NULL OR @PumpId IS NULL
    BEGIN
        SELECT CAST(-1 AS BIGINT) AS Id;
        RETURN;
    END

    -- FIX: Allow OPEN and CLOSED statuses (CLOSED = editing a mistake)
    -- Block only truly invalid statuses (NULL, VOID, etc.)
    IF ISNULL(@Status, '') NOT IN ('OPEN', 'CLOSED')
    BEGIN
        SELECT CAST(-2 AS BIGINT) AS Id;
        RETURN;
    END

    IF OBJECT_ID('PUMP.ShiftNozzleReadings', 'U') IS NOT NULL
       AND @NozzleReadingsJson IS NOT NULL
       AND ISJSON(@NozzleReadingsJson) = 1
    BEGIN
        ;WITH cte AS
        (
            SELECT
                x.NozzleId,
                x.ClosingReading,
                ISNULL(x.TestingLoss, 0) AS TestingLoss
            FROM OPENJSON(@NozzleReadingsJson)
            WITH
            (
                NozzleId       BIGINT        '$.NozzleId',
                ClosingReading DECIMAL(18,3) '$.ClosingReading',
                TestingLoss    DECIMAL(18,3) '$.TestingLoss'
            ) x
            WHERE ISNULL(x.NozzleId, 0) > 0
        )
        UPDATE snr
        SET
            snr.ClosingReading = cte.ClosingReading,
            snr.TestingLoss    = cte.TestingLoss,
            snr.SoldQty        = CASE
                                    WHEN cte.ClosingReading >= snr.OpeningReading THEN
                                        CASE
                                            WHEN (cte.ClosingReading - snr.OpeningReading - cte.TestingLoss) > 0
                                            THEN (cte.ClosingReading - snr.OpeningReading - cte.TestingLoss)
                                            ELSE 0
                                        END
                                    ELSE 0
                                 END,
            snr.SoldAmount     = CASE
                                    WHEN cte.ClosingReading >= snr.OpeningReading THEN
                                        CASE
                                            WHEN (cte.ClosingReading - snr.OpeningReading - cte.TestingLoss) > 0
                                            THEN (cte.ClosingReading - snr.OpeningReading - cte.TestingLoss) * snr.Rate
                                            ELSE 0
                                        END
                                    ELSE 0
                                 END,
            snr.UpdatedOn      = SYSDATETIME()
        FROM PUMP.ShiftNozzleReadings snr
        INNER JOIN cte ON cte.NozzleId = snr.NozzleId
        WHERE snr.ShiftId = @Id;

        -- Validation
        IF EXISTS (SELECT 1 FROM PUMP.ShiftNozzleReadings WHERE ShiftId = @Id AND ClosingReading < OpeningReading)
        BEGIN
            THROW 50001, 'Closing reading cannot be less than opening reading.', 1;
        END

        IF EXISTS (SELECT 1 FROM PUMP.ShiftNozzleReadings WHERE ShiftId = @Id AND ClosingReading IS NULL)
        BEGIN
            THROW 50002, 'All nozzles must have closing reading before shift close.', 1;
        END

        IF EXISTS
        (
            SELECT 1
            FROM PUMP.ShiftNozzleReadings snr
            WHERE snr.ShiftId = @Id
              AND snr.SoldQty > 0
              AND NOT EXISTS
              (
                  SELECT 1
                  FROM PUMP.Tanks t
                  WHERE t.PumpId = @PumpId
                    AND t.ProductId = snr.ProductId
                    AND t.IsActive = 1
              )
        )
        BEGIN
            THROW 50003, 'Active tank mapping missing for one or more sold products.', 1;
        END

        -- Tank deduction only for OPEN shifts (first close)
        -- Skip re-deduction for already-CLOSED shifts (editing only updates readings, not tank stock again)
        IF @Status = 'OPEN'
        BEGIN
            INSERT INTO PUMP.TankTransactions
            (
                 OwnerId, PumpId, TankId, TxnType, Quantity, TxnDateTime, ReferenceNo, Notes
            )
            SELECT
                 @OwnerId,
                 @PumpId,
                 t.Id,
                 'OUT',
                 SUM(snr.SoldQty),
                 SYSDATETIME(),
                 'SHIFT-' + CAST(@Id AS NVARCHAR(20)),
                 'Shift meter sale auto-deduction'
            FROM PUMP.ShiftNozzleReadings snr
            INNER JOIN PUMP.Tanks t
                ON t.PumpId = @PumpId
               AND t.ProductId = snr.ProductId
               AND t.IsActive = 1
            WHERE snr.ShiftId = @Id
              AND snr.SoldQty > 0
            GROUP BY t.Id;

            UPDATE t
            SET t.CurrentStock = t.CurrentStock - x.TotalSold
            FROM PUMP.Tanks t
            INNER JOIN
            (
                SELECT
                    tk.Id AS TankId,
                    SUM(s.SoldQty) AS TotalSold
                FROM PUMP.ShiftNozzleReadings s
                INNER JOIN PUMP.Tanks tk
                   ON tk.PumpId = @PumpId
                   AND tk.ProductId = s.ProductId
                   AND tk.IsActive = 1
                WHERE s.ShiftId = @Id AND s.SoldQty > 0
                GROUP BY tk.Id
            ) x ON x.TankId = t.Id;
        END
    END

    -- Update ShiftHeaders (sets Status = CLOSED regardless â€” idempotent)
    UPDATE PUMP.ShiftHeaders
    SET ClosedOn    = COALESCE(ClosedOn, SYSDATETIME()),
        ClosingCash = COALESCE(@ClosingCash, ClosingCash),
        Notes       = COALESCE(@Notes, Notes),
        Status      = 'CLOSED'
    WHERE Id = @Id;

    SELECT @Id AS Id;
END
GO
/****** Object:  StoredProcedure [PUMP].[sp_Shift_Collection_Summary]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Shift_Collection_Summary]
(
    @ShiftId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        TotalCreditSales = ISNULL(SUM(CASE WHEN UPPER(ISNULL(sh.PaymentMode, '')) = 'CREDIT' THEN sh.TotalAmount ELSE 0 END), 0),
        TotalDigitalSales = ISNULL(SUM(CASE WHEN UPPER(ISNULL(sh.PaymentMode, '')) IN ('UPI', 'CARD', 'DIGITAL', 'ONLINE', 'BANK') THEN sh.TotalAmount ELSE 0 END), 0),
        TotalCashExpenses =
            ISNULL(
                (
                    SELECT SUM(e.Amount)
                    FROM PUMP.ExpenseTransactions e
                    WHERE e.ShiftId = @ShiftId
                      AND UPPER(ISNULL(e.PaymentMode, '')) = 'CASH'
                ), 0
            )
            +
            ISNULL(
                (
                    SELECT SUM(c.Amount)
                    FROM PUMP.CashTransactions c
                    WHERE c.ShiftId = @ShiftId
                      AND UPPER(ISNULL(c.TxnType, '')) = 'OUT'
                ), 0
            )
    FROM PUMP.SalesHeaders sh
    WHERE sh.ShiftId = @ShiftId
      AND sh.IsVoid = 0;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Shift_List]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Shift_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT = NULL,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @SearchTerm NVARCHAR(100) = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 50
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Offset INT = (@PageNumber - 1) * @PageSize;

    ;WITH ShiftBase AS
    (
        SELECT
            sh.Id,
            sh.OwnerId,
            sh.PumpId,
            sh.OperatorUserId,
            u.FullName AS OperatorName,
            sh.ShiftDate,
            sh.ShiftCode,
            sh.OpeningCash,
            sh.ClosingCash,
            sh.Notes,
            sh.OpenedOn,
            sh.ClosedOn,
            sh.Status
        FROM PUMP.ShiftHeaders sh
        LEFT JOIN PUMP.Users u ON u.Id = sh.OperatorUserId
        WHERE sh.OwnerId = @OwnerId
          AND (@PumpId IS NULL OR @PumpId <= 0 OR sh.PumpId = @PumpId)
          AND (@FromDate IS NULL OR sh.ShiftDate >= @FromDate)
          AND (@ToDate IS NULL OR sh.ShiftDate <= @ToDate)
          AND (@SearchTerm IS NULL OR @SearchTerm = '' OR sh.ShiftCode LIKE '%' + @SearchTerm + '%' OR sh.Notes LIKE '%' + @SearchTerm + '%')
    )
    SELECT
        b.Id,
        b.OwnerId,
        b.PumpId,
        b.OperatorUserId,
        b.OperatorName,
        b.ShiftDate,
        b.ShiftCode,
        b.OpeningCash,
        b.ClosingCash,
        TotalSoldQty = ISNULL(snr.TotalSoldQty, 0),
        TotalSoldAmount = ISNULL(snr.TotalSoldAmount, 0),
        b.Notes,
        b.OpenedOn,
        b.ClosedOn,
        b.Status
    FROM ShiftBase b
    OUTER APPLY
    (
        SELECT
            SUM(ISNULL(x.SoldQty, 0)) AS TotalSoldQty,
            SUM(ISNULL(x.SoldAmount, 0)) AS TotalSoldAmount
        FROM PUMP.ShiftNozzleReadings x
        WHERE x.ShiftId = b.Id
    ) snr
    ORDER BY b.Id DESC
    OFFSET @Offset ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(1)
    FROM PUMP.ShiftHeaders sh
    WHERE sh.OwnerId = @OwnerId
      AND (@PumpId IS NULL OR @PumpId <= 0 OR sh.PumpId = @PumpId)
      AND (@FromDate IS NULL OR sh.ShiftDate >= @FromDate)
      AND (@ToDate IS NULL OR sh.ShiftDate <= @ToDate)
      AND (@SearchTerm IS NULL OR @SearchTerm = '' OR sh.ShiftCode LIKE '%' + @SearchTerm + '%' OR sh.Notes LIKE '%' + @SearchTerm + '%');
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Shift_NozzleReadings]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- Fix 2: sp_Shift_NozzleReadings â€” add TestingLoss to SELECT
CREATE OR ALTER PROCEDURE [PUMP].[sp_Shift_NozzleReadings]
(
    @ShiftId BIGINT
,
    @OwnerId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    -- TENANT GUARD: shift usi owner ki honi chahiye. @OwnerId na aaye to purana
    -- behaviour (API layer ka ITenantGuard pehle hi rok chuka hota hai).
    IF @OwnerId IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM PUMP.ShiftHeaders WHERE Id = @ShiftId AND OwnerId = @OwnerId)
        RETURN;


    SELECT
        snr.NozzleId,
        n.NozzleCode,
        p.Name                          AS ProductName,
        snr.OpeningReading,
        snr.ClosingReading,
        ISNULL(snr.TestingLoss, 0)      AS TestingLoss,   -- FIX: was missing
        snr.Rate,
        snr.SoldQty,
        snr.SoldAmount
    FROM PUMP.ShiftNozzleReadings snr
    INNER JOIN PUMP.Nozzles  n ON n.Id = snr.NozzleId
    INNER JOIN PUMP.Products p ON p.Id = snr.ProductId
    WHERE snr.ShiftId = @ShiftId
    ORDER BY n.NozzleCode;
END
GO
/****** Object:  StoredProcedure [PUMP].[sp_Shift_Open]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Shift_Open]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @OperatorUserId BIGINT = NULL,
    @ShiftDate DATE,
    @ShiftCode NVARCHAR(30),
    @OpeningCash DECIMAL(18,2) = 0,
    @Notes NVARCHAR(500) = NULL,
    @NozzleReadingsJson NVARCHAR(MAX) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS
    (
        SELECT 1
        FROM PUMP.ShiftHeaders
        WHERE OwnerId = @OwnerId
          AND PumpId = @PumpId
          AND Status = 'OPEN'
    )
    BEGIN
        SELECT CAST(-1 AS BIGINT) AS Id;
        RETURN;
    END

    INSERT INTO PUMP.ShiftHeaders (OwnerId, PumpId, OperatorUserId, ShiftDate, ShiftCode, OpeningCash, Notes, OpenedOn, Status)
    VALUES (@OwnerId, @PumpId, @OperatorUserId, @ShiftDate, @ShiftCode, @OpeningCash, @Notes, SYSDATETIME(), 'OPEN');

    DECLARE @ShiftId BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);

    IF OBJECT_ID('PUMP.ShiftNozzleReadings', 'U') IS NOT NULL
       AND @NozzleReadingsJson IS NOT NULL
       AND ISJSON(@NozzleReadingsJson) = 1
    BEGIN
        INSERT INTO PUMP.ShiftNozzleReadings
        (
            OwnerId, PumpId, ShiftId, NozzleId, ProductId, OpeningReading, Rate
        )
        SELECT
            @OwnerId,
            @PumpId,
            @ShiftId,
            x.NozzleId,
            x.ProductId,
            ISNULL(x.OpeningReading, 0),
            ISNULL(p.CurrentRate, 0)
        FROM OPENJSON(@NozzleReadingsJson)
        WITH
        (
            NozzleId BIGINT '$.NozzleId',
            ProductId BIGINT '$.ProductId',
            OpeningReading DECIMAL(18,3) '$.OpeningReading'
        ) x
        INNER JOIN PUMP.Products p ON p.Id = x.ProductId
        WHERE ISNULL(x.NozzleId, 0) > 0
          AND ISNULL(x.ProductId, 0) > 0;
    END

    SELECT @ShiftId AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_StockReconcile_List]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_StockReconcile_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @TankId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 200
        sr.Id,
        sr.OwnerId,
        sr.PumpId,
        sr.TankId,
        t.Name AS TankName,
        sr.ReconciliationDate,
        sr.BookStock,
        sr.PhysicalStock,
        sr.VarianceQty,
        sr.Reason,
        sr.CreatedOn
    FROM PUMP.StockReconciliations sr
    INNER JOIN PUMP.Tanks t ON t.Id = sr.TankId
    WHERE sr.OwnerId = @OwnerId
      AND sr.PumpId = @PumpId
      AND (@TankId IS NULL OR sr.TankId = @TankId)
    ORDER BY sr.Id DESC;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_StockReconcile_Save]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_StockReconcile_Save]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @TankId BIGINT,
    @ReconciliationDate DATE,
    @BookStock DECIMAL(18,3),
    @PhysicalStock DECIMAL(18,3),
    @Reason NVARCHAR(250) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @VarianceQty DECIMAL(18,3) = @PhysicalStock - @BookStock;

    INSERT INTO PUMP.StockReconciliations
    (
        OwnerId,
        PumpId,
        TankId,
        ReconciliationDate,
        BookStock,
        PhysicalStock,
        VarianceQty,
        Reason
    )
    VALUES
    (
        @OwnerId,
        @PumpId,
        @TankId,
        @ReconciliationDate,
        @BookStock,
        @PhysicalStock,
        @VarianceQty,
        @Reason
    );

    UPDATE PUMP.Tanks
    SET CurrentStock = @PhysicalStock,
        UpdatedOn = SYSDATETIME()
    WHERE Id = @TankId
      AND OwnerId = @OwnerId
      AND PumpId = @PumpId;

    SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_StockReconciliation_List]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_StockReconciliation_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 20
)
AS
BEGIN
    SET NOCOUNT ON;
    
    SELECT 
        s.Id,
        s.OwnerId,
        s.PumpId,
        s.TankId,
        t.Name + ' (' + p.Name + ')' AS TankName,
        s.ReconciliationDate,
        s.BookStock,
        s.PhysicalStock,
        s.VarianceQty,
        s.Reason,
        s.CreatedOn
    FROM PUMP.StockReconciliations s
    INNER JOIN PUMP.Tanks t ON t.Id = s.TankId
    INNER JOIN PUMP.Products p ON p.Id = t.ProductId
    WHERE s.OwnerId = @OwnerId 
      AND s.PumpId = @PumpId
      AND (@FromDate IS NULL OR s.ReconciliationDate >= @FromDate)
      AND (@ToDate IS NULL OR s.ReconciliationDate <= @ToDate)
    ORDER BY s.ReconciliationDate DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(1)
    FROM PUMP.StockReconciliations s
    WHERE s.OwnerId = @OwnerId 
      AND s.PumpId = @PumpId
      AND (@FromDate IS NULL OR s.ReconciliationDate >= @FromDate)
      AND (@ToDate IS NULL OR s.ReconciliationDate <= @ToDate);
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Tank_Delete]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ============================================================
-- 2. sp_Tank_Delete
-- Checks: TankTransactions, DipReadings, StockReconciliations, TestingLosses, Nozzles
-- ============================================================
CREATE OR ALTER PROCEDURE [PUMP].[sp_Tank_Delete]
(
    @Id      BIGINT,
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.Tanks WHERE Id = @Id AND OwnerId = @OwnerId)
    BEGIN
        THROW 50030, 'Tank not found or access denied.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.TankTransactions WHERE TankId = @Id)
    BEGIN
        THROW 50031, 'Cannot delete: Tank has stock transactions linked to it.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.DipReadings WHERE TankId = @Id)
    BEGIN
        THROW 50032, 'Cannot delete: Tank has dip readings linked to it.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.StockReconciliations WHERE TankId = @Id)
    BEGIN
        THROW 50033, 'Cannot delete: Tank has stock reconciliation records linked to it.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.TestingLosses WHERE TankId = @Id)
    BEGIN
        THROW 50034, 'Cannot delete: Tank has testing loss records linked to it.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.Nozzles WHERE TankId = @Id)
    BEGIN
        THROW 50035, 'Cannot delete: Tank has nozzles linked to it. Delete nozzles first.', 1;
    END

    DELETE FROM PUMP.Tanks WHERE Id = @Id AND OwnerId = @OwnerId;

    SELECT @Id AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Tank_GetStockAsOfDate]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ============================================================
-- Script 042: Historical Tank Book Stock Calculator
-- ============================================================

CREATE OR ALTER PROCEDURE [PUMP].[sp_Tank_GetStockAsOfDate]
(
    @OwnerId  BIGINT,
    @TankId   BIGINT,
    @AsOfDate DATE
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @CurrentStock DECIMAL(18,3) = 0;
    SELECT @CurrentStock = ISNULL(CurrentStock, 0)
    FROM PUMP.Tanks
    WHERE Id = @TankId AND OwnerId = @OwnerId;

    DECLARE @Adjustments DECIMAL(18,3) = 0;
    SELECT @Adjustments = ISNULL(
        SUM(CASE WHEN t.TxnType = 'IN' THEN t.Quantity ELSE -t.Quantity END), 0)
    FROM PUMP.TankTransactions t
    LEFT JOIN PUMP.ShiftHeaders s 
        ON t.ReferenceNo LIKE 'SHIFT-%' 
        AND s.Id = TRY_CAST(REVERSE(SUBSTRING(REVERSE(t.ReferenceNo), 1, CHARINDEX('-', REVERSE(t.ReferenceNo)) - 1)) AS INT)
    WHERE t.TankId = @TankId
      AND t.OwnerId = @OwnerId
      AND (
          (s.Id IS NOT NULL AND s.ShiftDate > @AsOfDate)
          OR
          (s.Id IS NULL AND CAST(t.TxnDateTime AS DATE) > @AsOfDate)
      );

    SELECT @CurrentStock - @Adjustments AS BookStock;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Tank_List]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Tank_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @SearchTerm NVARCHAR(255) = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 20
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        t.Id,
        t.PumpId,
        t.Name,
        t.ProductId,
        p.Name AS ProductName,
        p.Unit,
        t.Capacity,
        t.SafeFillLevel,
        t.CurrentStock,
        t.IsActive
    FROM PUMP.Tanks t
    INNER JOIN PUMP.Products p ON p.Id = t.ProductId
    WHERE t.OwnerId = @OwnerId
      AND t.PumpId = @PumpId
      AND (@SearchTerm IS NULL OR t.Name LIKE '%' + @SearchTerm + '%')
    ORDER BY t.Name
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(1)
    FROM PUMP.Tanks
    WHERE OwnerId = @OwnerId
      AND PumpId = @PumpId
      AND (@SearchTerm IS NULL OR Name LIKE '%' + @SearchTerm + '%');
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Tank_Save]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Tank_Save]
(
    @Id BIGINT,
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @Name NVARCHAR(120),
    @ProductId BIGINT,
    @Capacity DECIMAL(18,2),
    @SafeFillLevel DECIMAL(18,2),
    @CurrentStock DECIMAL(18,2),
    @IsActive BIT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @Id = 0
    BEGIN
        INSERT INTO PUMP.Tanks (OwnerId, PumpId, Name, ProductId, Capacity, SafeFillLevel, CurrentStock, IsActive)
        VALUES (@OwnerId, @PumpId, @Name, @ProductId, @Capacity, @SafeFillLevel, @CurrentStock, @IsActive);
    END
    ELSE
    BEGIN
        UPDATE PUMP.Tanks
        SET Name = @Name,
            ProductId = @ProductId,
            Capacity = @Capacity,
            SafeFillLevel = @SafeFillLevel,
            CurrentStock = @CurrentStock,
            IsActive = @IsActive,
            UpdatedOn = SYSDATETIME()
        WHERE Id = @Id
          AND OwnerId = @OwnerId
          AND PumpId = @PumpId;
    END
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_TankTxn_List]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_TankTxn_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @TankId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 200
        tx.Id,
        tx.OwnerId,
        tx.PumpId,
        tx.TankId,
        t.Name AS TankName,
        tx.TxnType,
        tx.Quantity,
        tx.TxnDateTime,
        tx.ReferenceNo,
        tx.Notes
    FROM PUMP.TankTransactions tx
    INNER JOIN PUMP.Tanks t ON t.Id = tx.TankId
    WHERE tx.OwnerId = @OwnerId
      AND tx.PumpId = @PumpId
      AND (@TankId IS NULL OR tx.TankId = @TankId)
    ORDER BY tx.Id DESC;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_TankTxn_Save]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_TankTxn_Save]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @TankId BIGINT,
    @TxnType NVARCHAR(30),
    @Quantity DECIMAL(18,2),
    @ReferenceNo NVARCHAR(50) = NULL,
    @Notes NVARCHAR(250) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    -- BLOCKER FIX (2026-09-03): pehle INSERT fail hone par (jaise CK_TankTxn_Type
    -- violation) bhi UPDATE chal jaata tha — tank stock badal jaata tha bina kisi
    -- matching TankTransactions row ke. Ab dono ek transaction me hain.
    SET XACT_ABORT ON;

    BEGIN TRANSACTION;

        INSERT INTO PUMP.TankTransactions (OwnerId, PumpId, TankId, TxnType, Quantity, ReferenceNo, Notes)
        VALUES (@OwnerId, @PumpId, @TankId, @TxnType, @Quantity, @ReferenceNo, @Notes);

        UPDATE PUMP.Tanks
        SET CurrentStock = CASE
            WHEN UPPER(@TxnType) IN ('IN', 'RECEIPT', 'PURCHASE', 'OPENING') THEN CurrentStock + @Quantity
            ELSE CurrentStock - @Quantity
        END,
            UpdatedOn = SYSDATETIME()
        WHERE Id = @TankId
          AND OwnerId = @OwnerId
          AND PumpId = @PumpId;

    COMMIT TRANSACTION;

    SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_TestingLoss_List]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_TestingLoss_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 20
)
AS
BEGIN
    SET NOCOUNT ON;
    
    SELECT 
        tl.Id,
        tl.OwnerId,
        tl.PumpId,
        tl.ProductId,
        p.Name AS ProductName,
        tl.TankId,
        t.Name AS TankName,
        tl.LossDate,
        tl.ShiftId,
        tl.LossType,
        tl.Quantity,
        tl.Notes,
        tl.CreatedOn,
        tl.IsActive
    FROM PUMP.TestingLosses tl
    INNER JOIN PUMP.Products p ON p.Id = tl.ProductId
    LEFT JOIN PUMP.Tanks t ON t.Id = tl.TankId
    WHERE tl.OwnerId = @OwnerId 
      AND tl.PumpId = @PumpId
      AND (@FromDate IS NULL OR tl.LossDate >= @FromDate)
      AND (@ToDate IS NULL OR tl.LossDate <= @ToDate)
    ORDER BY tl.LossDate DESC, tl.CreatedOn DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(1)
    FROM PUMP.TestingLosses tl
    WHERE tl.OwnerId = @OwnerId 
      AND tl.PumpId = @PumpId
      AND (@FromDate IS NULL OR tl.LossDate >= @FromDate)
      AND (@ToDate IS NULL OR tl.LossDate <= @ToDate);
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_TestingLoss_Save]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


CREATE OR ALTER PROCEDURE [PUMP].[sp_TestingLoss_Save]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @TankId BIGINT,
    @LossDate DATE,
    @ShiftId BIGINT = NULL,
    @LossType NVARCHAR(50),
    @Quantity DECIMAL(18,2),
    @Notes NVARCHAR(250) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ProductId BIGINT;
    SELECT @ProductId = ProductId FROM PUMP.Tanks WHERE Id = @TankId AND PumpId = @PumpId;

    IF @ProductId IS NULL
    BEGIN
        SELECT CAST(-1 AS BIGINT) AS Id;
        RETURN;
    END

    INSERT INTO PUMP.TestingLosses
    (
        OwnerId, PumpId, ProductId, TankId, LossDate, ShiftId, LossType, Quantity, Notes
    )
    VALUES
    (
        @OwnerId, @PumpId, @ProductId, @TankId, @LossDate, @ShiftId, @LossType, @Quantity, @Notes
    );

    DECLARE @LossId BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);

    -- DEDUCT STOCK
    IF @Quantity > 0
    BEGIN
        INSERT INTO PUMP.TankTransactions
        (
            OwnerId, PumpId, TankId, TxnType, Quantity, TxnDateTime, ReferenceNo, Notes
        )
        VALUES
        (
            @OwnerId, @PumpId, @TankId, 'OUT', @Quantity, SYSDATETIME(), 'LOSS-' + CAST(@LossId AS NVARCHAR(20)), @LossType + ' loss'
        );

        UPDATE PUMP.Tanks
        SET CurrentStock = CurrentStock - @Quantity
        WHERE Id = @TankId;
    END

    SELECT @LossId AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_TestingLoss_ToggleActive]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- 4. TestingLoss ToggleActive
CREATE OR ALTER PROCEDURE [PUMP].[sp_TestingLoss_ToggleActive]
(
    @Id BIGINT,
    @OwnerId BIGINT,
    @PumpId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @OldQty DECIMAL(18,3), @OldTankId BIGINT, @CurrentIsActive BIT, @LossType NVARCHAR(50);
    SELECT @OldQty = Quantity, @OldTankId = TankId, @CurrentIsActive = IsActive, @LossType = LossType
    FROM PUMP.TestingLosses 
    WHERE Id = @Id AND OwnerId = @OwnerId AND PumpId = @PumpId;

    IF @OldQty IS NULL RETURN;

    IF @CurrentIsActive = 1
    BEGIN
        -- Deactivating: Refund the quantity to the tank
        IF @OldQty > 0
        BEGIN
            UPDATE PUMP.Tanks SET CurrentStock = CurrentStock + @OldQty WHERE Id = @OldTankId;
            -- Insert reversing IN transaction
            INSERT INTO PUMP.TankTransactions (OwnerId, PumpId, TankId, TxnType, Quantity, TxnDateTime, ReferenceNo, Notes)
            VALUES (@OwnerId, @PumpId, @OldTankId, 'IN', @OldQty, SYSDATETIME(), 'LOSS-DEL-' + CAST(@Id AS NVARCHAR(20)), 'Refunded due to deletion');
        END
        
        UPDATE PUMP.TestingLosses SET IsActive = 0 WHERE Id = @Id;
    END
    ELSE
    BEGIN
        -- Activating: Deduct the quantity again
        IF @OldQty > 0
        BEGIN
            UPDATE PUMP.Tanks SET CurrentStock = CurrentStock - @OldQty WHERE Id = @OldTankId;
            -- Insert OUT transaction
            INSERT INTO PUMP.TankTransactions (OwnerId, PumpId, TankId, TxnType, Quantity, TxnDateTime, ReferenceNo, Notes)
            VALUES (@OwnerId, @PumpId, @OldTankId, 'OUT', @OldQty, SYSDATETIME(), 'LOSS-' + CAST(@Id AS NVARCHAR(20)), @LossType + ' loss (reactivated)');
        END
        
        UPDATE PUMP.TestingLosses SET IsActive = 1 WHERE Id = @Id;
    END
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_TestingLoss_Update]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- 3. TestingLoss Update
CREATE OR ALTER PROCEDURE [PUMP].[sp_TestingLoss_Update]
(
    @Id BIGINT,
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @TankId BIGINT,
    @LossDate DATE,
    @ShiftId BIGINT = NULL,
    @LossType NVARCHAR(50),
    @Quantity DECIMAL(18,3),
    @Notes NVARCHAR(500) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @OldQty DECIMAL(18,3), @OldTankId BIGINT, @OldIsActive BIT;
    SELECT @OldQty = Quantity, @OldTankId = TankId, @OldIsActive = IsActive
    FROM PUMP.TestingLosses 
    WHERE Id = @Id AND OwnerId = @OwnerId AND PumpId = @PumpId;

    IF @OldQty IS NULL RETURN; -- Record not found

    -- Only adjust stock if it was active and is still active (active state doesn't change here)
    -- If it was inactive, we don't update stock now (user should activate it first)
    IF @OldIsActive = 1
    BEGIN
        -- Add back old quantity to old tank
        IF @OldQty > 0
        BEGIN
            UPDATE PUMP.Tanks SET CurrentStock = CurrentStock + @OldQty WHERE Id = @OldTankId;
            
            -- Insert reversing IN transaction
            INSERT INTO PUMP.TankTransactions (OwnerId, PumpId, TankId, TxnType, Quantity, TxnDateTime, ReferenceNo, Notes)
            VALUES (@OwnerId, @PumpId, @OldTankId, 'IN', @OldQty, SYSDATETIME(), 'LOSS-REV-' + CAST(@Id AS NVARCHAR(20)), 'Reversed for edit');
        END

        -- Deduct new quantity from new tank
        IF @Quantity > 0
        BEGIN
            UPDATE PUMP.Tanks SET CurrentStock = CurrentStock - @Quantity WHERE Id = @TankId;
            
            -- Insert OUT transaction
            INSERT INTO PUMP.TankTransactions (OwnerId, PumpId, TankId, TxnType, Quantity, TxnDateTime, ReferenceNo, Notes)
            VALUES (@OwnerId, @PumpId, @TankId, 'OUT', @Quantity, SYSDATETIME(), 'LOSS-' + CAST(@Id AS NVARCHAR(20)), @LossType + ' loss (edited)');
        END
    END

    UPDATE PUMP.TestingLosses
    SET 
        TankId = @TankId,
        LossDate = @LossDate,
        ShiftId = @ShiftId,
        LossType = @LossType,
        Quantity = @Quantity,
        Notes = @Notes
    WHERE Id = @Id;

END

GO
/****** Object:  StoredProcedure [PUMP].[sp_User_Delete]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ============================================================
-- 5. sp_User_Delete
-- Checks: UserRoles, UserRefreshTokens, ShiftHeaders (OperatorUserId), Employees
-- ============================================================
CREATE OR ALTER PROCEDURE [PUMP].[sp_User_Delete]
(
    @Id      BIGINT,
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.Users WHERE Id = @Id AND OwnerId = @OwnerId)
    BEGIN
        THROW 50060, 'User not found or access denied.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.ShiftHeaders WHERE OperatorUserId = @Id)
    BEGIN
        THROW 50061, 'Cannot delete: User has shifts linked to them.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.Employees WHERE UserId = @Id)
    BEGIN
        THROW 50062, 'Cannot delete: User is linked to an employee record. Remove the employee link first.', 1;
    END

    -- Safe to cascade: UserRoles and UserRefreshTokens
    DELETE FROM PUMP.UserRoles          WHERE UserId = @Id;
    DELETE FROM PUMP.UserRefreshTokens  WHERE UserId = @Id;
    DELETE FROM PUMP.Users              WHERE Id = @Id AND OwnerId = @OwnerId;

    SELECT @Id AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_User_List]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_User_List]
(
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        u.Id,
        u.OwnerId,
        u.FullName,
        u.Username,
        u.Mobile,
        u.IsActive,
        r.Id AS RoleId,
        r.Name AS RoleName
    FROM PUMP.Users u
    LEFT JOIN PUMP.UserRoles ur ON ur.UserId = u.Id
    LEFT JOIN PUMP.Roles r ON r.Id = ur.RoleId
    WHERE u.IsActive = 1
      AND u.OwnerId = @OwnerId
    ORDER BY u.Id DESC;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_User_Save]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_User_Save]
(
    @Id BIGINT = NULL,
    @OwnerId BIGINT,
    @FullName NVARCHAR(200),
    @Username NVARCHAR(100),
    @PasswordHash NVARCHAR(500),
    @Mobile NVARCHAR(20) = NULL,
    @RoleId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRANSACTION;
    IF @Id IS NULL OR @Id = 0
    BEGIN
        INSERT INTO PUMP.Users (OwnerId, FullName, Username, PasswordHash, Mobile)
        VALUES (@OwnerId, @FullName, @Username, @PasswordHash, @Mobile);

        SET @Id = SCOPE_IDENTITY();

        INSERT INTO PUMP.UserRoles (UserId, RoleId)
        VALUES (@Id, @RoleId);
    END
    ELSE
    BEGIN
        UPDATE PUMP.Users
        SET FullName = @FullName,
            Username = @Username,
            PasswordHash = @PasswordHash,
            Mobile = @Mobile
        WHERE Id = @Id;

        DELETE FROM PUMP.UserRoles WHERE UserId = @Id;

        INSERT INTO PUMP.UserRoles (UserId, RoleId)
        VALUES (@Id, @RoleId);
    END
    COMMIT TRANSACTION;

    SELECT @Id AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Vendor_Delete]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ============================================================
-- 6. sp_Vendor_Delete
-- Checks: PurchaseHeaders
-- ============================================================
CREATE OR ALTER PROCEDURE [PUMP].[sp_Vendor_Delete]
(
    @Id      BIGINT,
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.Vendors WHERE Id = @Id AND OwnerId = @OwnerId)
    BEGIN
        THROW 50070, 'Vendor not found or access denied.', 1;
    END

    IF EXISTS (SELECT 1 FROM PUMP.PurchaseHeaders WHERE VendorId = @Id)
    BEGIN
        THROW 50071, 'Cannot delete: Vendor has purchase records linked to it.', 1;
    END

    DELETE FROM PUMP.Vendors WHERE Id = @Id AND OwnerId = @OwnerId;

    SELECT @Id AS Id;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Vendor_List]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Vendor_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        Id,
        OwnerId,
        PumpId,
        VendorName,
        ContactNo,
        GSTIN,
        Address,
        IsActive
    FROM PUMP.Vendors
    WHERE OwnerId = @OwnerId
      AND PumpId = @PumpId
    ORDER BY VendorName;
END

GO
/****** Object:  StoredProcedure [PUMP].[sp_Vendor_Save]    Script Date: 02-08-2026 10:56:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Vendor_Save]
(
    @Id BIGINT = NULL,
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @VendorName NVARCHAR(200),
    @ContactNo NVARCHAR(20) = NULL,
    @GSTIN NVARCHAR(20) = NULL,
    @Address NVARCHAR(300) = NULL,
    @IsActive BIT = 1
)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISNULL(@Id, 0) = 0
    BEGIN
        INSERT INTO PUMP.Vendors (OwnerId, PumpId, VendorName, ContactNo, GSTIN, Address, IsActive)
        VALUES (@OwnerId, @PumpId, @VendorName, @ContactNo, @GSTIN, @Address, @IsActive);

        SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS Id;
        RETURN;
    END

    UPDATE PUMP.Vendors
    SET VendorName = @VendorName,
        ContactNo = @ContactNo,
        GSTIN = @GSTIN,
        Address = @Address,
        IsActive = @IsActive,
        UpdatedOn = SYSDATETIME()
    WHERE Id = @Id
      AND OwnerId = @OwnerId
      AND PumpId = @PumpId;

    SELECT @Id AS Id;
END

GO

/* ==========================================================================================
   ==========================================================================================
                    PPMS  UPGRADE PACK  v2.0   —   PART 2 OF THIS FILE
   ==========================================================================================

   Ye section upar wale original dump ke baad chalta hai aur usko production-grade banata hai.

   PROPERTIES:
     * IDEMPOTENT  — file kitni bhi baar chalao, error nahi aayega, duplicate nahi banega.
     * SELF-CONTAINED — jo table / column / default / index / procedure missing tha, sab yahin hai.
     * NO DATA LOSS — koi existing row delete nahi hoti. Sirf add / alter / backfill hota hai.

   SECTIONS:
     A.  Missing DEFAULT constraints      (iske bina fresh DB par app kuch save nahi kar sakta)
     B.  Missing columns                  (trial, soft-delete, audit, concurrency, GST, meter)
     C.  New tables                       (subscription, payment-ready, cash, audit, tax, states)
     D.  Performance indexes              (5000 concurrent users ke liye)
     E.  Unique + check constraints       (data integrity)
     F.  Seed / backfill data
     G.  Stored procedures                (naye + fix kiye hue)

   ========================================================================================== */
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

PRINT '';
PRINT '===========================================================';
PRINT ' PPMS UPGRADE PACK v2.0 — starting';
PRINT '===========================================================';
GO


/* ==========================================================================================
   SECTION A — MISSING DEFAULT CONSTRAINTS
   ------------------------------------------------------------------------------------------
   PROBLEM: 20 tables me ek bhi DEFAULT nahi tha, jabki CreatedOn / EntryDateTime / TxnDateTime
            NOT NULL hain aur stored procedures unhe INSERT me bhejte hi nahi.
            Fresh DB par har save "Cannot insert the value NULL" se fail hota.
   ========================================================================================== */
PRINT '--- Section A: default constraints ---';
GO

DECLARE @Defaults TABLE (TableName SYSNAME, ColumnName SYSNAME, DefaultExpr NVARCHAR(200));

INSERT INTO @Defaults (TableName, ColumnName, DefaultExpr) VALUES
    -- timestamps
    ('PartyLedger',          'EntryDateTime', 'SYSDATETIME()'),
    ('PartyLedger',          'CreatedOn',     'SYSDATETIME()'),
    ('CashTransactions',     'TxnDateTime',   'SYSDATETIME()'),
    ('CashTransactions',     'CreatedOn',     'SYSDATETIME()'),
    ('SalesHeaders',         'BillDateTime',  'SYSDATETIME()'),
    ('TankTransactions',     'TxnDateTime',   'SYSDATETIME()'),
    ('TankTransactions',     'CreatedOn',     'SYSDATETIME()'),
    ('ExpenseTransactions',  'TxnDateTime',   'SYSDATETIME()'),
    ('ExpenseTransactions',  'CreatedOn',     'SYSDATETIME()'),
    ('Parties',              'CreatedOn',     'SYSDATETIME()'),
    ('Tanks',                'CreatedOn',     'SYSDATETIME()'),
    ('Vendors',              'CreatedOn',     'SYSDATETIME()'),
    ('Employees',            'CreatedOn',     'SYSDATETIME()'),
    ('ExpenseHeads',         'CreatedOn',     'SYSDATETIME()'),
    ('SalaryPayments',       'CreatedOn',     'SYSDATETIME()'),
    ('PurchaseHeaders',      'CreatedOn',     'SYSDATETIME()'),
    ('FleetContracts',       'CreatedOn',     'SYSDATETIME()'),
    ('CouponBooks',          'CreatedOn',     'SYSDATETIME()'),
    ('CouponTransactions',   'CreatedOn',     'SYSDATETIME()'),
    ('StockReconciliations', 'CreatedOn',     'SYSDATETIME()'),
    ('UserRefreshTokens',    'CreatedOn',     'SYSDATETIME()'),
    ('Users',                'CreatedOn',     'SYSDATETIME()'),
    ('Roles',                'CreatedOn',     'SYSDATETIME()'),
    ('Owners',               'CreatedOn',     'SYSDATETIME()'),
    ('Pumps',                'CreatedOn',     'SYSDATETIME()'),
    ('Products',             'CreatedOn',     'SYSDATETIME()'),
    ('Nozzles',              'CreatedOn',     'SYSDATETIME()'),
    ('ShiftNozzleReadings',  'CreatedOn',     'SYSDATETIME()'),
    ('ShiftHeaders',         'OpenedOn',      'SYSDATETIME()'),
    ('Receipts',             'ReceiptDateTime','SYSDATETIME()'),
    -- flags
    ('Parties',              'IsActive',      '1'),
    ('Tanks',                'IsActive',      '1'),
    ('Vendors',              'IsActive',      '1'),
    ('Employees',            'IsActive',      '1'),
    ('ExpenseHeads',         'IsActive',      '1'),
    ('FleetContracts',       'IsActive',      '1'),
    ('CouponBooks',          'IsActive',      '1'),
    -- money / qty
    ('Parties',              'CreditLimit',   '0'),
    ('Parties',              'CurrentBalance','0'),
    ('Tanks',                'CurrentStock',  '0'),
    ('Tanks',                'SafeFillLevel', '0'),
    ('ShiftNozzleReadings',  'SoldQty',       '0'),
    ('ShiftNozzleReadings',  'SoldAmount',    '0'),
    ('ShiftNozzleReadings',  'VarianceQty',   '0'),
    ('ShiftNozzleReadings',  'Rate',          '0'),
    ('SalesHeaders',         'TotalAmount',   '0'),
    ('CashTransactions',     'Amount',        '0');

DECLARE @t SYSNAME, @c SYSNAME, @d NVARCHAR(200), @sql NVARCHAR(MAX);

DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT TableName, ColumnName, DefaultExpr FROM @Defaults;
OPEN cur;
FETCH NEXT FROM cur INTO @t, @c, @d;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF OBJECT_ID('PUMP.' + QUOTENAME(@t), 'U') IS NOT NULL
       AND EXISTS (SELECT 1 FROM sys.columns
                   WHERE object_id = OBJECT_ID('PUMP.' + QUOTENAME(@t)) AND name = @c)
       AND NOT EXISTS (SELECT 1
                       FROM sys.default_constraints dc
                       JOIN sys.columns col
                         ON col.object_id = dc.parent_object_id
                        AND col.column_id = dc.parent_column_id
                       WHERE dc.parent_object_id = OBJECT_ID('PUMP.' + QUOTENAME(@t))
                         AND col.name = @c)
    BEGIN
        SET @sql = 'ALTER TABLE PUMP.' + QUOTENAME(@t)
                 + ' ADD CONSTRAINT ' + QUOTENAME('DF_' + @t + '_' + @c)
                 + ' DEFAULT (' + @d + ') FOR ' + QUOTENAME(@c) + ';';
        EXEC sys.sp_executesql @sql;
        PRINT '  + default  PUMP.' + @t + '.' + @c;
    END

    FETCH NEXT FROM cur INTO @t, @c, @d;
END

CLOSE cur;
DEALLOCATE cur;
GO


/* ==========================================================================================
   SECTION B — MISSING COLUMNS
   ========================================================================================== */
PRINT '--- Section B: missing columns ---';
GO

DECLARE @Cols TABLE (TableName SYSNAME, ColumnName SYSNAME, ColumnDef NVARCHAR(300));

INSERT INTO @Cols (TableName, ColumnName, ColumnDef) VALUES
    /* ---- B1. Subscription / trial (code inko maangta hai, DB me the hi nahi) ---- */
    ('Owners', 'ValidUpto',      'DATE NULL'),
    ('Owners', 'ContactName',    'NVARCHAR(150) NULL'),
    ('Owners', 'ContactNo',      'NVARCHAR(20) NULL'),
    ('Owners', 'Email',          'NVARCHAR(150) NULL'),
    ('Owners', 'City',           'NVARCHAR(100) NULL'),
    ('Owners', 'StateCode',      'NVARCHAR(2) NULL'),
    ('Owners', 'GSTIN',          'NVARCHAR(20) NULL'),
    ('Owners', 'PlanCode',       'NVARCHAR(30) NULL'),
    ('Owners', 'IsTrial',        'BIT NOT NULL CONSTRAINT DF_Owners_IsTrial DEFAULT (1)'),

    /* ---- B2. GST / VAT — pan-India ke liye interstate IGST aur state code chahiye ---- */
    ('Pumps',    'StateCode',    'NVARCHAR(2) NULL'),
    ('Pumps',    'LicenseNo',    'NVARCHAR(50) NULL'),
    ('Products', 'IGSTRate',     'DECIMAL(5,2) NOT NULL CONSTRAINT DF_Products_IGSTRate DEFAULT (0)'),
    ('Products', 'VATRate',      'DECIMAL(5,2) NOT NULL CONSTRAINT DF_Products_VATRate DEFAULT (0)'),
    ('Products', 'IsFuel',       'BIT NOT NULL CONSTRAINT DF_Products_IsFuel DEFAULT (0)'),
    ('Parties',  'StateCode',    'NVARCHAR(2) NULL'),
    ('SalesDetails', 'IGSTAmount','DECIMAL(18,2) NOT NULL CONSTRAINT DF_SalesDetails_IGSTAmount DEFAULT (0)'),
    ('SalesHeaders', 'IsInterState','BIT NOT NULL CONSTRAINT DF_SalesHeaders_IsInterState DEFAULT (0)'),

    /* ---- B3. Nozzle meter — rollover handle karne ke liye ---- */
    ('Nozzles', 'MeterDigits',   'TINYINT NOT NULL CONSTRAINT DF_Nozzles_MeterDigits DEFAULT (6)'),

    /* ---- B4. Shift cash reconciliation ----
       PartyLedger.ShiftId ke bina "is shift me kitni udhaar wapsi cash me aayi" pata
       hi nahi chal sakta — aur uske bina expected cash galat nikalta hai. */
    ('PartyLedger',  'ShiftId',          'BIGINT NULL'),
    ('PartyLedger',  'PaymentMode',      'NVARCHAR(30) NULL'),
    ('ShiftHeaders', 'TotalMeterSale',   'DECIMAL(18,2) NOT NULL CONSTRAINT DF_ShiftHeaders_TotalMeterSale DEFAULT (0)'),
    ('ShiftHeaders', 'ExpectedCash',     'DECIMAL(18,2) NOT NULL CONSTRAINT DF_ShiftHeaders_ExpectedCash DEFAULT (0)'),
    ('ShiftHeaders', 'CashShortExcess',  'DECIMAL(18,2) NOT NULL CONSTRAINT DF_ShiftHeaders_CashShortExcess DEFAULT (0)'),
    ('ShiftHeaders', 'ClosedByUserId',   'BIGINT NULL'),

    /* ---- B5. Shift close ko idempotent banane ke liye ---- */
    ('ShiftNozzleReadings', 'IsRollover', 'BIT NOT NULL CONSTRAINT DF_SNR_IsRollover DEFAULT (0)'),

    /* ---- B6. Rate ko time-effective banane ke liye ---- */
    ('ProductRateHistory', 'EffectiveFrom', 'DATETIME2(7) NULL'),
    ('ProductRateHistory', 'OwnerId',       'BIGINT NULL'),
    ('ProductRateHistory', 'PumpId',        'BIGINT NULL');

DECLARE @bt SYSNAME, @bc SYSNAME, @bd NVARCHAR(300), @bsql NVARCHAR(MAX);

DECLARE curB CURSOR LOCAL FAST_FORWARD FOR
    SELECT TableName, ColumnName, ColumnDef FROM @Cols;
OPEN curB;
FETCH NEXT FROM curB INTO @bt, @bc, @bd;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF OBJECT_ID('PUMP.' + QUOTENAME(@bt), 'U') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM sys.columns
                       WHERE object_id = OBJECT_ID('PUMP.' + QUOTENAME(@bt)) AND name = @bc)
    BEGIN
        SET @bsql = 'ALTER TABLE PUMP.' + QUOTENAME(@bt) + ' ADD ' + QUOTENAME(@bc) + ' ' + @bd + ';';
        EXEC sys.sp_executesql @bsql;
        PRINT '  + column   PUMP.' + @bt + '.' + @bc;
    END

    FETCH NEXT FROM curB INTO @bt, @bc, @bd;
END

CLOSE curB;
DEALLOCATE curB;
GO


/* ------------------------------------------------------------------------------------------
   B7. SOFT DELETE + AUDIT + CONCURRENCY — har master table par ek jaisa
   ------------------------------------------------------------------------------------------
   PROBLEM: UI me har jagah Delete button hai, par delete SP transaction milte hi THROW
            kar deta hai ("Cannot delete: Party has ledger entries"). User ko lagta hai
            delete kaam hi nahi karta.
   SOLUTION: Agar record use ho chuka hai to use HIDE karo (IsDeleted = 1), mitao mat.
            History safe rehti hai, list se gayab ho jaata hai — dono kaam ho gaye.
   ------------------------------------------------------------------------------------------ */
PRINT '--- Section B7: soft-delete / audit / rowversion columns ---';
GO

DECLARE @Masters TABLE (TableName SYSNAME);
INSERT INTO @Masters (TableName) VALUES
    ('Products'), ('Nozzles'), ('Tanks'), ('Parties'), ('Vendors'),
    ('Employees'), ('ExpenseHeads'), ('Pumps'), ('Users'), ('Roles'),
    ('FleetContracts'), ('CouponBooks'), ('Owners');

DECLARE @Txns TABLE (TableName SYSNAME);
INSERT INTO @Txns (TableName) VALUES
    ('SalesHeaders'), ('SalesDetails'), ('PurchaseHeaders'), ('PurchaseDetails'),
    ('CashTransactions'), ('ExpenseTransactions'), ('PartyLedger'), ('TankTransactions'),
    ('SalaryPayments'), ('ShiftHeaders'), ('ShiftNozzleReadings'),
    ('DipReadings'), ('TestingLosses'), ('StockReconciliations'), ('CouponTransactions');

DECLARE @mt SYSNAME, @msql NVARCHAR(MAX);

/* masters: IsDeleted + DeletedOn + DeletedBy + ModifiedBy/On + RowVersion */
DECLARE curM CURSOR LOCAL FAST_FORWARD FOR SELECT TableName FROM @Masters;
OPEN curM;
FETCH NEXT FROM curM INTO @mt;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF OBJECT_ID('PUMP.' + QUOTENAME(@mt), 'U') IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('PUMP.' + QUOTENAME(@mt)) AND name = 'IsDeleted')
        BEGIN
            SET @msql = 'ALTER TABLE PUMP.' + QUOTENAME(@mt)
                      + ' ADD IsDeleted BIT NOT NULL CONSTRAINT ' + QUOTENAME('DF_' + @mt + '_IsDeleted') + ' DEFAULT (0)'
                      + ', DeletedOn DATETIME2(7) NULL'
                      + ', DeletedBy BIGINT NULL;';
            EXEC sys.sp_executesql @msql;
            PRINT '  + softdel  PUMP.' + @mt;
        END
    END
    FETCH NEXT FROM curM INTO @mt;
END
CLOSE curM;
DEALLOCATE curM;

/* masters + txns: audit columns aur RowVersion (optimistic locking) */
DECLARE curAll CURSOR LOCAL FAST_FORWARD FOR
    SELECT TableName FROM @Masters UNION SELECT TableName FROM @Txns;
OPEN curAll;
FETCH NEXT FROM curAll INTO @mt;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF OBJECT_ID('PUMP.' + QUOTENAME(@mt), 'U') IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('PUMP.' + QUOTENAME(@mt)) AND name = 'CreatedBy')
        BEGIN
            SET @msql = 'ALTER TABLE PUMP.' + QUOTENAME(@mt)
                      + ' ADD CreatedBy BIGINT NULL, ModifiedBy BIGINT NULL, ModifiedOn DATETIME2(7) NULL;';
            EXEC sys.sp_executesql @msql;
            PRINT '  + audit    PUMP.' + @mt;
        END

        IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('PUMP.' + QUOTENAME(@mt)) AND name = 'RowVersion')
        BEGIN
            SET @msql = 'ALTER TABLE PUMP.' + QUOTENAME(@mt) + ' ADD [RowVersion] ROWVERSION;';
            EXEC sys.sp_executesql @msql;
            PRINT '  + rowver   PUMP.' + @mt;
        END
    END
    FETCH NEXT FROM curAll INTO @mt;
END
CLOSE curAll;
DEALLOCATE curAll;
GO


/* ==========================================================================================
   SECTION C — NEW TABLES
   ========================================================================================== */
PRINT '--- Section C: new tables ---';
GO

/* ---------- C1. States master — GST state code, pan-India ke liye ---------- */
IF OBJECT_ID('PUMP.States', 'U') IS NULL
BEGIN
    CREATE TABLE PUMP.States
    (
        StateCode   NVARCHAR(2)   NOT NULL,
        StateName   NVARCHAR(100) NOT NULL,
        IsActive    BIT           NOT NULL CONSTRAINT DF_States_IsActive DEFAULT (1),
        CONSTRAINT PK_States PRIMARY KEY CLUSTERED (StateCode)
    );
    PRINT '  + table    PUMP.States';
END
GO

/* ---------- C2. SubscriptionRequests — code ise call karta hai, table tha hi nahi ---------- */
IF OBJECT_ID('PUMP.SubscriptionRequests', 'U') IS NULL
BEGIN
    CREATE TABLE PUMP.SubscriptionRequests
    (
        Id           BIGINT        IDENTITY(1,1) NOT NULL,
        OwnerId      BIGINT        NULL,
        ContactName  NVARCHAR(150) NOT NULL,
        ContactNo    NVARCHAR(20)  NOT NULL,
        PumpName     NVARCHAR(200) NULL,
        PlanType     NVARCHAR(50)  NULL,
        City         NVARCHAR(100) NULL,
        StateCode    NVARCHAR(2)   NULL,
        Status       NVARCHAR(20)  NOT NULL CONSTRAINT DF_SubReq_Status   DEFAULT ('NEW'),
        Notes        NVARCHAR(500) NULL,
        SourceIp     NVARCHAR(45)  NULL,
        CreatedOn    DATETIME2(7)  NOT NULL CONSTRAINT DF_SubReq_CreatedOn DEFAULT (SYSDATETIME()),
        DoneOn       DATETIME2(7)  NULL,
        DoneBy       BIGINT        NULL,
        CONSTRAINT PK_SubscriptionRequests PRIMARY KEY CLUSTERED (Id)
    );
    PRINT '  + table    PUMP.SubscriptionRequests';
END
GO

/* ---------- C3. SubscriptionPlans ---------- */
IF OBJECT_ID('PUMP.SubscriptionPlans', 'U') IS NULL
BEGIN
    CREATE TABLE PUMP.SubscriptionPlans
    (
        Id            BIGINT        IDENTITY(1,1) NOT NULL,
        PlanCode      NVARCHAR(30)  NOT NULL,
        PlanName      NVARCHAR(100) NOT NULL,
        DurationDays  INT           NOT NULL,
        MaxPumps      INT           NOT NULL CONSTRAINT DF_Plan_MaxPumps  DEFAULT (1),
        MaxUsers      INT           NOT NULL CONSTRAINT DF_Plan_MaxUsers  DEFAULT (5),
        BaseAmount    DECIMAL(18,2) NOT NULL CONSTRAINT DF_Plan_BaseAmt   DEFAULT (0),
        GSTRate       DECIMAL(5,2)  NOT NULL CONSTRAINT DF_Plan_GST       DEFAULT (18),
        IsActive      BIT           NOT NULL CONSTRAINT DF_Plan_IsActive  DEFAULT (1),
        CreatedOn     DATETIME2(7)  NOT NULL CONSTRAINT DF_Plan_CreatedOn DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_SubscriptionPlans PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_SubscriptionPlans_Code UNIQUE (PlanCode)
    );
    PRINT '  + table    PUMP.SubscriptionPlans';
END
GO

/* ---------- C4. OwnerSubscriptions — kis owner ka kaunsa plan, kab tak ---------- */
IF OBJECT_ID('PUMP.OwnerSubscriptions', 'U') IS NULL
BEGIN
    CREATE TABLE PUMP.OwnerSubscriptions
    (
        Id           BIGINT        IDENTITY(1,1) NOT NULL,
        OwnerId      BIGINT        NOT NULL,
        PlanId       BIGINT        NOT NULL,
        StartDate    DATE          NOT NULL,
        EndDate      DATE          NOT NULL,
        Amount       DECIMAL(18,2) NOT NULL CONSTRAINT DF_OwnSub_Amount DEFAULT (0),
        GSTAmount    DECIMAL(18,2) NOT NULL CONSTRAINT DF_OwnSub_GST    DEFAULT (0),
        TotalAmount  DECIMAL(18,2) NOT NULL CONSTRAINT DF_OwnSub_Total  DEFAULT (0),
        -- PENDING / ACTIVE / EXPIRED / CANCELLED
        Status       NVARCHAR(20)  NOT NULL CONSTRAINT DF_OwnSub_Status DEFAULT ('PENDING'),
        -- MANUAL abhi. Gateway lagte hi 'RAZORPAY' / 'PHONEPE' / 'CASHFREE' ho jayega.
        PaymentMode  NVARCHAR(30)  NOT NULL CONSTRAINT DF_OwnSub_PayMode DEFAULT ('MANUAL'),
        InvoiceNo    NVARCHAR(50)  NULL,
        Notes        NVARCHAR(500) NULL,
        CreatedOn    DATETIME2(7)  NOT NULL CONSTRAINT DF_OwnSub_CreatedOn DEFAULT (SYSDATETIME()),
        CreatedBy    BIGINT        NULL,
        CONSTRAINT PK_OwnerSubscriptions PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_OwnerSubscriptions_Owner FOREIGN KEY (OwnerId) REFERENCES PUMP.Owners(Id),
        CONSTRAINT FK_OwnerSubscriptions_Plan  FOREIGN KEY (PlanId)  REFERENCES PUMP.SubscriptionPlans(Id)
    );
    PRINT '  + table    PUMP.OwnerSubscriptions';
END
GO

/* ---------- C5. PaymentTransactions — PAYMENT GATEWAY KA JUGAAD ----------
   Gateway abhi nahi lagana, par poora dhaancha taiyaar hai. Jis din Razorpay /
   PhonePe / Cashfree lagana ho, sirf API call add karni hai — DB, SP aur
   idempotency sab ready hai. Provider-neutral rakha gaya hai.
   ------------------------------------------------------------------------- */
IF OBJECT_ID('PUMP.PaymentTransactions', 'U') IS NULL
BEGIN
    CREATE TABLE PUMP.PaymentTransactions
    (
        Id                BIGINT         IDENTITY(1,1) NOT NULL,
        OwnerId           BIGINT         NOT NULL,
        SubscriptionId    BIGINT         NULL,
        -- MANUAL / RAZORPAY / PHONEPE / CASHFREE / PAYTM / STRIPE
        Provider          NVARCHAR(30)   NOT NULL CONSTRAINT DF_PayTxn_Provider DEFAULT ('MANUAL'),
        -- hamara apna reference — gateway par bhejne ke liye
        MerchantOrderId   NVARCHAR(64)   NOT NULL,
        -- gateway ke reference
        ProviderOrderId   NVARCHAR(128)  NULL,
        ProviderPaymentId NVARCHAR(128)  NULL,
        ProviderSignature NVARCHAR(256)  NULL,
        Amount            DECIMAL(18,2)  NOT NULL,
        Currency          NVARCHAR(3)    NOT NULL CONSTRAINT DF_PayTxn_Currency DEFAULT ('INR'),
        -- CREATED / PENDING / SUCCESS / FAILED / REFUNDED
        Status            NVARCHAR(20)   NOT NULL CONSTRAINT DF_PayTxn_Status DEFAULT ('CREATED'),
        FailureReason     NVARCHAR(500)  NULL,
        -- gateway ka raw JSON, debugging aur dispute ke liye
        RawPayload        NVARCHAR(MAX)  NULL,
        CreatedOn         DATETIME2(7)   NOT NULL CONSTRAINT DF_PayTxn_CreatedOn DEFAULT (SYSDATETIME()),
        PaidOn            DATETIME2(7)   NULL,
        CONSTRAINT PK_PaymentTransactions PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_PaymentTransactions_MerchantOrder UNIQUE (MerchantOrderId),
        CONSTRAINT FK_PaymentTransactions_Owner FOREIGN KEY (OwnerId) REFERENCES PUMP.Owners(Id)
    );
    PRINT '  + table    PUMP.PaymentTransactions';
END
GO

/* ---------- C6. PaymentWebhookEvents — gateway callback idempotency ----------
   Gateway ek hi event 3-4 baar bhejta hai. Bina iske subscription 3 baar
   extend ho jayegi. EventId unique hai, isliye duplicate chup-chaap ignore.
   ---------------------------------------------------------------------------- */
IF OBJECT_ID('PUMP.PaymentWebhookEvents', 'U') IS NULL
BEGIN
    CREATE TABLE PUMP.PaymentWebhookEvents
    (
        Id           BIGINT        IDENTITY(1,1) NOT NULL,
        Provider     NVARCHAR(30)  NOT NULL,
        EventId      NVARCHAR(128) NOT NULL,
        EventType    NVARCHAR(80)  NULL,
        PaymentTxnId BIGINT        NULL,
        Payload      NVARCHAR(MAX) NULL,
        IsProcessed  BIT           NOT NULL CONSTRAINT DF_PayHook_Processed DEFAULT (0),
        ReceivedOn   DATETIME2(7)  NOT NULL CONSTRAINT DF_PayHook_ReceivedOn DEFAULT (SYSDATETIME()),
        ProcessedOn  DATETIME2(7)  NULL,
        Error        NVARCHAR(1000) NULL,
        CONSTRAINT PK_PaymentWebhookEvents PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_PaymentWebhookEvents UNIQUE (Provider, EventId)
    );
    PRINT '  + table    PUMP.PaymentWebhookEvents';
END
GO

/* ---------- C7. AuditLog — paise ke system me mandatory ---------- */
IF OBJECT_ID('PUMP.AuditLog', 'U') IS NULL
BEGIN
    CREATE TABLE PUMP.AuditLog
    (
        Id          BIGINT        IDENTITY(1,1) NOT NULL,
        OwnerId     BIGINT        NULL,
        PumpId      BIGINT        NULL,
        UserId      BIGINT        NULL,
        UserName    NVARCHAR(100) NULL,
        EntityName  NVARCHAR(100) NOT NULL,
        EntityId    BIGINT        NULL,
        -- INSERT / UPDATE / DELETE / VOID / LOGIN / LOGIN_FAIL / CLOSE / REOPEN
        Action      NVARCHAR(30)  NOT NULL,
        OldValues   NVARCHAR(MAX) NULL,
        NewValues   NVARCHAR(MAX) NULL,
        Reason      NVARCHAR(500) NULL,
        IpAddress   NVARCHAR(45)  NULL,
        CreatedOn   DATETIME2(7)  NOT NULL CONSTRAINT DF_AuditLog_CreatedOn DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_AuditLog PRIMARY KEY CLUSTERED (Id)
    );
    PRINT '  + table    PUMP.AuditLog';
END
GO

/* ---------- C8. LoginAttempts — brute force lockout ---------- */
IF OBJECT_ID('PUMP.LoginAttempts', 'U') IS NULL
BEGIN
    CREATE TABLE PUMP.LoginAttempts
    (
        Id          BIGINT        IDENTITY(1,1) NOT NULL,
        Username    NVARCHAR(100) NOT NULL,
        IpAddress   NVARCHAR(45)  NULL,
        IsSuccess   BIT           NOT NULL,
        AttemptedOn DATETIME2(7)  NOT NULL CONSTRAINT DF_LoginAttempts_On DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_LoginAttempts PRIMARY KEY CLUSTERED (Id)
    );
    PRINT '  + table    PUMP.LoginAttempts';
END
GO

/* ---------- C9. BankAccounts + BankDeposits — cash kahan gaya ---------- */
IF OBJECT_ID('PUMP.BankAccounts', 'U') IS NULL
BEGIN
    CREATE TABLE PUMP.BankAccounts
    (
        Id            BIGINT        IDENTITY(1,1) NOT NULL,
        OwnerId       BIGINT        NOT NULL,
        PumpId        BIGINT        NOT NULL,
        BankName      NVARCHAR(150) NOT NULL,
        AccountNo     NVARCHAR(30)  NOT NULL,
        IFSC          NVARCHAR(15)  NULL,
        Branch        NVARCHAR(150) NULL,
        OpeningBalance DECIMAL(18,2) NOT NULL CONSTRAINT DF_BankAcc_Opening DEFAULT (0),
        IsActive      BIT           NOT NULL CONSTRAINT DF_BankAcc_IsActive DEFAULT (1),
        IsDeleted     BIT           NOT NULL CONSTRAINT DF_BankAcc_IsDeleted DEFAULT (0),
        CreatedOn     DATETIME2(7)  NOT NULL CONSTRAINT DF_BankAcc_CreatedOn DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_BankAccounts PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_BankAccounts_Pump FOREIGN KEY (PumpId) REFERENCES PUMP.Pumps(Id)
    );
    PRINT '  + table    PUMP.BankAccounts';
END
GO

IF OBJECT_ID('PUMP.BankDeposits', 'U') IS NULL
BEGIN
    CREATE TABLE PUMP.BankDeposits
    (
        Id            BIGINT        IDENTITY(1,1) NOT NULL,
        OwnerId       BIGINT        NOT NULL,
        PumpId        BIGINT        NOT NULL,
        BankAccountId BIGINT        NOT NULL,
        ShiftId       BIGINT        NULL,
        DepositDate   DATE          NOT NULL,
        Amount        DECIMAL(18,2) NOT NULL,
        SlipNo        NVARCHAR(50)  NULL,
        DepositedBy   NVARCHAR(150) NULL,
        Notes         NVARCHAR(300) NULL,
        IsDeleted     BIT           NOT NULL CONSTRAINT DF_BankDep_IsDeleted DEFAULT (0),
        CreatedOn     DATETIME2(7)  NOT NULL CONSTRAINT DF_BankDep_CreatedOn DEFAULT (SYSDATETIME()),
        CreatedBy     BIGINT        NULL,
        CONSTRAINT PK_BankDeposits PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_BankDeposits_Account FOREIGN KEY (BankAccountId) REFERENCES PUMP.BankAccounts(Id)
    );
    PRINT '  + table    PUMP.BankDeposits';
END
GO

/* ---------- C10. ShiftCashDenominations — physical note counting ---------- */
IF OBJECT_ID('PUMP.ShiftCashDenominations', 'U') IS NULL
BEGIN
    CREATE TABLE PUMP.ShiftCashDenominations
    (
        Id           BIGINT        IDENTITY(1,1) NOT NULL,
        OwnerId      BIGINT        NOT NULL,
        PumpId       BIGINT        NOT NULL,
        ShiftId      BIGINT        NOT NULL,
        Denomination INT           NOT NULL,   -- 500, 200, 100, 50, 20, 10, 5, 2, 1
        Pieces       INT           NOT NULL CONSTRAINT DF_ShiftDenom_Pieces DEFAULT (0),
        Amount       AS (CAST(Denomination AS DECIMAL(18,2)) * Pieces) PERSISTED,
        CreatedOn    DATETIME2(7)  NOT NULL CONSTRAINT DF_ShiftDenom_CreatedOn DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_ShiftCashDenominations PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_ShiftCashDenominations UNIQUE (ShiftId, Denomination),
        CONSTRAINT FK_ShiftCashDenom_Shift FOREIGN KEY (ShiftId) REFERENCES PUMP.ShiftHeaders(Id)
    );
    PRINT '  + table    PUMP.ShiftCashDenominations';
END
GO

/* ---------- C11. TaxRates — state x product, effective dating ---------- */
IF OBJECT_ID('PUMP.TaxRates', 'U') IS NULL
BEGIN
    CREATE TABLE PUMP.TaxRates
    (
        Id            BIGINT        IDENTITY(1,1) NOT NULL,
        OwnerId       BIGINT        NULL,
        StateCode     NVARCHAR(2)   NOT NULL,
        ProductId     BIGINT        NULL,
        ProductCategory NVARCHAR(50) NULL,
        CGSTRate      DECIMAL(5,2)  NOT NULL CONSTRAINT DF_TaxRates_CGST DEFAULT (0),
        SGSTRate      DECIMAL(5,2)  NOT NULL CONSTRAINT DF_TaxRates_SGST DEFAULT (0),
        IGSTRate      DECIMAL(5,2)  NOT NULL CONSTRAINT DF_TaxRates_IGST DEFAULT (0),
        VATRate       DECIMAL(5,2)  NOT NULL CONSTRAINT DF_TaxRates_VAT  DEFAULT (0),
        CessRate      DECIMAL(5,2)  NOT NULL CONSTRAINT DF_TaxRates_Cess DEFAULT (0),
        EffectiveFrom DATE          NOT NULL,
        EffectiveTo   DATE          NULL,
        CreatedOn     DATETIME2(7)  NOT NULL CONSTRAINT DF_TaxRates_CreatedOn DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_TaxRates PRIMARY KEY CLUSTERED (Id)
    );
    PRINT '  + table    PUMP.TaxRates';
END
GO

/* ---------- C12. AppSettings — hardcoded values ki jagah ---------- */
IF OBJECT_ID('PUMP.AppSettings', 'U') IS NULL
BEGIN
    CREATE TABLE PUMP.AppSettings
    (
        SettingKey   NVARCHAR(100) NOT NULL,
        SettingValue NVARCHAR(500) NULL,
        -- 0 = global setting, warna owner-specific override
        OwnerId      BIGINT        NOT NULL CONSTRAINT DF_AppSettings_OwnerId DEFAULT (0),
        Description  NVARCHAR(300) NULL,
        ModifiedOn   DATETIME2(7)  NOT NULL CONSTRAINT DF_AppSettings_Modified DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_AppSettings PRIMARY KEY CLUSTERED (SettingKey, OwnerId)
    );
    PRINT '  + table    PUMP.AppSettings';
END
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ==========================================================================================
   SECTION D — PERFORMANCE INDEXES
   ------------------------------------------------------------------------------------------
   PROBLEM: Poore original dump me ek bhi non-clustered index nahi tha. 36 tables, sirf
            clustered PK on Id. 150 foreign keys the — par FK apne aap index nahi banata.
            1 pump par ye dikhta nahi. 5000 pumps x 3 shift x 365 din par SalesDetails,
            PartyLedger aur TankTransactions crore-plus rows me jayenge aur har query
            full table scan karegi.

   NOTE: Har index OwnerId/PumpId se shuru hota hai — multi-tenant system me har query
         pehle tenant filter karti hai, isliye leading column wahi hona chahiye.
   ========================================================================================== */
PRINT '--- Section D: performance indexes ---';
GO

DECLARE @Idx TABLE (IdxName SYSNAME, TableName SYSNAME, IdxDef NVARCHAR(500));

INSERT INTO @Idx (IdxName, TableName, IdxDef) VALUES
    /* ---- auth: har login par chalti hai ---- */
    ('IX_Users_Username',            'Users',                '(Username) INCLUDE (OwnerId, IsActive, IsSuperAdmin)'),
    ('IX_Users_Owner',               'Users',                '(OwnerId, IsActive)'),
    ('IX_UserRefreshTokens_Hash',    'UserRefreshTokens',    '(TokenHash)'),
    ('IX_UserRefreshTokens_User',    'UserRefreshTokens',    '(UserId, ExpiresOnUtc)'),
    ('IX_UserRoles_User',            'UserRoles',            '(UserId) INCLUDE (RoleId)'),
    ('IX_RoleMenus_Role',            'RoleMenus',            '(RoleId) INCLUDE (MenuId)'),
    ('IX_LoginAttempts_User',        'LoginAttempts',        '(Username, AttemptedOn)'),

    /* ---- sales: sabse bada table banega ---- */
    ('IX_SalesHeaders_Tenant_Date',  'SalesHeaders',         '(OwnerId, PumpId, BillDateTime) INCLUDE (ShiftId, PartyId, PaymentMode, TotalAmount)'),
    ('IX_SalesHeaders_Shift',        'SalesHeaders',         '(ShiftId) INCLUDE (PaymentMode, TotalAmount, PartyId)'),
    ('IX_SalesHeaders_Party',        'SalesHeaders',         '(PartyId, BillDateTime)'),
    ('IX_SalesDetails_Header',       'SalesDetails',         '(SalesHeaderId) INCLUDE (ProductId, Quantity, Rate, Amount)'),
    ('IX_SalesDetails_Product',      'SalesDetails',         '(ProductId)'),

    /* ---- shift + meter reading ---- */
    ('IX_ShiftHeaders_Tenant_Date',  'ShiftHeaders',         '(OwnerId, PumpId, ShiftDate) INCLUDE (Status, ShiftCode, OpeningCash, ClosingCash)'),
    ('IX_ShiftHeaders_Open',         'ShiftHeaders',         '(OwnerId, PumpId, Status)'),
    ('IX_SNR_Shift',                 'ShiftNozzleReadings',  '(ShiftId) INCLUDE (NozzleId, ProductId, OpeningReading, ClosingReading, SoldQty, SoldAmount, Rate)'),
    ('IX_SNR_Nozzle',                'ShiftNozzleReadings',  '(NozzleId, ShiftId)'),

    /* ---- party ledger: outstanding report roz chalti hai ---- */
    ('IX_PartyLedger_Tenant_Party',  'PartyLedger',          '(OwnerId, PumpId, PartyId, EntryDateTime) INCLUDE (EntryType, Amount, ReferenceNo)'),
    ('IX_PartyLedger_Date',          'PartyLedger',          '(OwnerId, PumpId, EntryDateTime)'),
    ('IX_Parties_Tenant',            'Parties',              '(OwnerId, PumpId, IsActive) INCLUDE (PartyName, Mobile, CurrentBalance)'),
    ('IX_Parties_Name',              'Parties',              '(OwnerId, PumpId, PartyName)'),

    /* ---- stock ---- */
    ('IX_TankTxn_Tenant_Tank',       'TankTransactions',     '(OwnerId, PumpId, TankId, TxnDateTime) INCLUDE (TxnType, Quantity, ReferenceNo)'),
    ('IX_TankTxn_Ref',               'TankTransactions',     '(ReferenceNo)'),
    ('IX_Tanks_Tenant',              'Tanks',                '(OwnerId, PumpId, IsActive) INCLUDE (ProductId, CurrentStock)'),
    ('IX_Nozzles_Tenant',            'Nozzles',              '(OwnerId, PumpId, IsActive) INCLUDE (ProductId, TankId, NozzleCode)'),
    ('IX_Nozzles_Tank',              'Nozzles',              '(TankId)'),
    ('IX_Products_Tenant',           'Products',             '(OwnerId, PumpId, IsActive) INCLUDE (Name, Category, CurrentRate)'),
    ('IX_DipReadings_Tenant',        'DipReadings',          '(OwnerId, PumpId, ReadingDate) INCLUDE (TankId, IsActive)'),
    ('IX_TestingLosses_Tenant',      'TestingLosses',        '(OwnerId, PumpId, LossDate) INCLUDE (TankId, ProductId, Quantity, IsActive)'),
    ('IX_StockRecon_Tenant',         'StockReconciliations', '(OwnerId, PumpId, ReconciliationDate) INCLUDE (TankId, BookStock, PhysicalStock, VarianceQty)'),

    /* ---- cash / expense: day book aur cash reconciliation ---- */
    ('IX_CashTxn_Tenant_Date',       'CashTransactions',     '(OwnerId, PumpId, TxnDateTime) INCLUDE (ShiftId, TxnType, Amount)'),
    ('IX_CashTxn_Shift',             'CashTransactions',     '(ShiftId) INCLUDE (TxnType, Amount)'),
    ('IX_ExpenseTxn_Tenant_Date',    'ExpenseTransactions',  '(OwnerId, PumpId, TxnDateTime) INCLUDE (ShiftId, ExpenseHeadId, Amount, PaymentMode)'),
    ('IX_ExpenseTxn_Shift',          'ExpenseTransactions',  '(ShiftId) INCLUDE (Amount, PaymentMode)'),
    ('IX_BankDeposits_Tenant',       'BankDeposits',         '(OwnerId, PumpId, DepositDate) INCLUDE (BankAccountId, Amount, ShiftId)'),

    /* ---- purchase ---- */
    ('IX_PurchaseHeaders_Tenant',    'PurchaseHeaders',      '(OwnerId, PumpId, InvoiceDate) INCLUDE (VendorId, TotalAmount)'),
    ('IX_PurchaseDetails_Header',    'PurchaseDetails',      '(PurchaseHeaderId) INCLUDE (ProductId, Quantity, Rate)'),
    ('IX_Vendors_Tenant',            'Vendors',              '(OwnerId, PumpId, IsActive)'),

    /* ---- hr ---- */
    ('IX_Employees_Tenant',          'Employees',            '(OwnerId, PumpId, IsActive)'),
    ('IX_SalaryPayments_Tenant',     'SalaryPayments',       '(OwnerId, PumpId, EmployeeId)'),

    /* ---- fleet / coupon ---- */
    ('IX_FleetContracts_Tenant',     'FleetContracts',       '(OwnerId, PumpId, PartyId)'),
    ('IX_CouponBooks_Tenant',        'CouponBooks',          '(OwnerId, PumpId, IsActive)'),
    ('IX_CouponTxn_Tenant',          'CouponTransactions',   '(OwnerId, PumpId, PartyId)'),

    /* ---- rate history ---- */
    ('IX_ProductRateHistory_Product','ProductRateHistory',   '(ProductId, ChangedAt)'),

    /* ---- subscription / payment ---- */
    ('IX_OwnerSubscriptions_Owner',  'OwnerSubscriptions',   '(OwnerId, Status, EndDate)'),
    ('IX_PaymentTransactions_Owner', 'PaymentTransactions',  '(OwnerId, Status, CreatedOn)'),
    ('IX_SubscriptionRequests_Status','SubscriptionRequests','(Status, CreatedOn)'),

    /* ---- audit ---- */
    ('IX_AuditLog_Tenant',           'AuditLog',             '(OwnerId, CreatedOn)'),
    ('IX_AuditLog_Entity',           'AuditLog',             '(EntityName, EntityId, CreatedOn)');

DECLARE @in SYSNAME, @it SYSNAME, @id NVARCHAR(500), @isql NVARCHAR(MAX);

DECLARE curIdx CURSOR LOCAL FAST_FORWARD FOR SELECT IdxName, TableName, IdxDef FROM @Idx;
OPEN curIdx;
FETCH NEXT FROM curIdx INTO @in, @it, @id;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF OBJECT_ID('PUMP.' + QUOTENAME(@it), 'U') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM sys.indexes
                       WHERE object_id = OBJECT_ID('PUMP.' + QUOTENAME(@it)) AND name = @in)
    BEGIN
        BEGIN TRY
            SET @isql = 'CREATE NONCLUSTERED INDEX ' + QUOTENAME(@in)
                      + ' ON PUMP.' + QUOTENAME(@it) + ' ' + @id + ';';
            EXEC sys.sp_executesql @isql;
            PRINT '  + index    ' + @in;
        END TRY
        BEGIN CATCH
            PRINT '  ! index    ' + @in + '  SKIPPED: ' + ERROR_MESSAGE();
        END CATCH
    END

    FETCH NEXT FROM curIdx INTO @in, @it, @id;
END

CLOSE curIdx;
DEALLOCATE curIdx;
GO


/* ==========================================================================================
   SECTION E — UNIQUE + CHECK CONSTRAINTS
   ------------------------------------------------------------------------------------------
   PROBLEM: Poore DB me sirf 4 unique constraints the. Do "HSD-1" nozzle, do "Diesel"
            product, do same-code shift — sab ban sakte the.
   NOTE: Filtered unique indexes use kiye hain taaki soft-deleted rows count na hon.
   ========================================================================================== */
PRINT '--- Section E: unique + check constraints ---';
GO

DECLARE @Uq TABLE (IdxName SYSNAME, TableName SYSNAME, IdxDef NVARCHAR(500));

INSERT INTO @Uq (IdxName, TableName, IdxDef) VALUES
    ('UX_Nozzles_Code',    'Nozzles',      '(PumpId, NozzleCode) WHERE IsDeleted = 0'),
    ('UX_Products_Name',   'Products',     '(OwnerId, PumpId, Name) WHERE IsDeleted = 0'),
    ('UX_Tanks_Name',      'Tanks',        '(PumpId, Name) WHERE IsDeleted = 0'),
    ('UX_Parties_Name',    'Parties',      '(OwnerId, PumpId, PartyName) WHERE IsDeleted = 0'),
    ('UX_Vendors_Name',    'Vendors',      '(OwnerId, PumpId, VendorName) WHERE IsDeleted = 0'),
    ('UX_ExpenseHeads_Name','ExpenseHeads','(OwnerId, PumpId, HeadName) WHERE IsDeleted = 0'),
    ('UX_Shift_Code',      'ShiftHeaders', '(PumpId, ShiftDate, ShiftCode)'),
    ('UX_Sales_BillNo',    'SalesHeaders', '(OwnerId, PumpId, BillNo)'),
    ('UX_BankAccounts_No', 'BankAccounts', '(OwnerId, AccountNo) WHERE IsDeleted = 0');

DECLARE @un SYSNAME, @ut SYSNAME, @ud NVARCHAR(500), @usql NVARCHAR(MAX);

DECLARE curUq CURSOR LOCAL FAST_FORWARD FOR SELECT IdxName, TableName, IdxDef FROM @Uq;
OPEN curUq;
FETCH NEXT FROM curUq INTO @un, @ut, @ud;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF OBJECT_ID('PUMP.' + QUOTENAME(@ut), 'U') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM sys.indexes
                       WHERE object_id = OBJECT_ID('PUMP.' + QUOTENAME(@ut)) AND name = @un)
    BEGIN
        BEGIN TRY
            SET @usql = 'CREATE UNIQUE NONCLUSTERED INDEX ' + QUOTENAME(@un)
                      + ' ON PUMP.' + QUOTENAME(@ut) + ' ' + @ud + ';';
            EXEC sys.sp_executesql @usql;
            PRINT '  + unique   ' + @un;
        END TRY
        BEGIN CATCH
            -- Duplicate data pehle se ho sakta hai. Tab index skip hota hai aur
            -- neeche wali report me dikh jaata hai, taaki aap data saaf kar sako.
            PRINT '  ! unique   ' + @un + '  SKIPPED (duplicate data?): ' + ERROR_MESSAGE();
        END CATCH
    END

    FETCH NEXT FROM curUq INTO @un, @ut, @ud;
END

CLOSE curUq;
DEALLOCATE curUq;
GO

/* ---- Check constraints: galat data DB level par hi ruk jaye ---- */
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_Tanks_Capacity')
   AND OBJECT_ID('PUMP.Tanks','U') IS NOT NULL
BEGIN
    BEGIN TRY
        ALTER TABLE PUMP.Tanks WITH NOCHECK
            ADD CONSTRAINT CK_Tanks_Capacity CHECK (Capacity > 0 AND SafeFillLevel <= Capacity);
        PRINT '  + check    CK_Tanks_Capacity';
    END TRY BEGIN CATCH PRINT '  ! check    CK_Tanks_Capacity skipped: ' + ERROR_MESSAGE(); END CATCH
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_CashTxn_Type')
   AND OBJECT_ID('PUMP.CashTransactions','U') IS NOT NULL
BEGIN
    BEGIN TRY
        -- 'BANK_DEPOSIT' bhi allowed hai — Cashbook UI isi teesre option ko bhejta hai.
        ALTER TABLE PUMP.CashTransactions WITH NOCHECK
            ADD CONSTRAINT CK_CashTxn_Type CHECK (UPPER(TxnType) IN ('IN','OUT','BANK_DEPOSIT'));
        PRINT '  + check    CK_CashTxn_Type';
    END TRY BEGIN CATCH PRINT '  ! check    CK_CashTxn_Type skipped: ' + ERROR_MESSAGE(); END CATCH
END
GO

/* BLOCKER FIX (2026-09-03): upar wala guarded block sirf FRESH DB par chalta hai (jab
   constraint bilkul nahi hoti). Jis DB par ye script pehle hi chal chuki hai wahan
   CK_CashTxn_Type already ban chuki hai purani definition ('IN','OUT' hi) ke saath, aur
   IF NOT EXISTS use guard karega. Cashbook UI ka "BANK DEPOSIT" option isi wajah se
   HAR BAAR 547 constraint violation deta tha — feature bilkul kaam nahi karta tha.
   Ye block purani (BANK_DEPOSIT allow na karne wali) constraint ko drop karke sahi
   wali dobara bana deta hai — dobara chalane par kuch nahi hota (already correct hogi). */
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_CashTxn_Type')
   AND NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_CashTxn_Type' AND definition LIKE '%BANK_DEPOSIT%')
BEGIN
    ALTER TABLE PUMP.CashTransactions DROP CONSTRAINT CK_CashTxn_Type;
    ALTER TABLE PUMP.CashTransactions WITH NOCHECK
        ADD CONSTRAINT CK_CashTxn_Type CHECK (UPPER(TxnType) IN ('IN','OUT','BANK_DEPOSIT'));
    PRINT '  ~ fix       CK_CashTxn_Type — BANK_DEPOSIT ab allowed hai (pehle Cashbook ka bank deposit save hamesha fail hota tha)';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_TankTxn_Type')
   AND OBJECT_ID('PUMP.TankTransactions','U') IS NOT NULL
BEGIN
    BEGIN TRY
        -- TankStock UI 'PURCHASE'/'RECEIPT'/'SALE'/'ADJUSTMENT' bhejta hai, aur
        -- sp_TankTxn_Save khud 'OPENING' bhi samajhta hai — sab allow karo.
        ALTER TABLE PUMP.TankTransactions WITH NOCHECK
            ADD CONSTRAINT CK_TankTxn_Type CHECK (UPPER(TxnType) IN ('IN','OUT','PURCHASE','RECEIPT','SALE','ADJUSTMENT','OPENING'));
        PRINT '  + check    CK_TankTxn_Type';
    END TRY BEGIN CATCH PRINT '  ! check    CK_TankTxn_Type skipped: ' + ERROR_MESSAGE(); END CATCH
END
GO

/* BLOCKER FIX (2026-09-03): CK_CashTxn_Type jaisa hi bug — CK_TankTxn_Type sirf
   'IN'/'OUT' allow karta tha, jabki TankStock UI
   (`/Operations/TankStock`) 'PURCHASE'/'RECEIPT'/'SALE'/'ADJUSTMENT' bhejta hai.
   Matlab Tank Stock Transaction feature se KOI BHI entry kabhi save nahi hoti thi —
   har baar 547 error. Upar wala guard sirf fresh DB par chalta hai; jis DB par
   script pehle hi chal chuki hai wahan purani constraint ko yahan fix kar rahe hain. */
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_TankTxn_Type')
   AND NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_TankTxn_Type' AND definition LIKE '%PURCHASE%')
BEGIN
    ALTER TABLE PUMP.TankTransactions DROP CONSTRAINT CK_TankTxn_Type;
    ALTER TABLE PUMP.TankTransactions WITH NOCHECK
        ADD CONSTRAINT CK_TankTxn_Type CHECK (UPPER(TxnType) IN ('IN','OUT','PURCHASE','RECEIPT','SALE','ADJUSTMENT','OPENING'));
    PRINT '  ~ fix       CK_TankTxn_Type — PURCHASE/RECEIPT/SALE/ADJUSTMENT ab allowed hain (Tank Stock page pehle kabhi save nahi karti thi)';
END
GO


/* ==========================================================================================
   SECTION F — SEED / BACKFILL DATA
   ========================================================================================== */
PRINT '--- Section F: seed + backfill ---';
GO

/* ---- F1. Indian states (GST state codes) ---- */
IF NOT EXISTS (SELECT 1 FROM PUMP.States)
BEGIN
    INSERT INTO PUMP.States (StateCode, StateName) VALUES
        ('01','Jammu and Kashmir'), ('02','Himachal Pradesh'), ('03','Punjab'),
        ('04','Chandigarh'),        ('05','Uttarakhand'),      ('06','Haryana'),
        ('07','Delhi'),             ('08','Rajasthan'),        ('09','Uttar Pradesh'),
        ('10','Bihar'),             ('11','Sikkim'),           ('12','Arunachal Pradesh'),
        ('13','Nagaland'),          ('14','Manipur'),          ('15','Mizoram'),
        ('16','Tripura'),           ('17','Meghalaya'),        ('18','Assam'),
        ('19','West Bengal'),       ('20','Jharkhand'),        ('21','Odisha'),
        ('22','Chhattisgarh'),      ('23','Madhya Pradesh'),   ('24','Gujarat'),
        ('26','Dadra and Nagar Haveli and Daman and Diu'),
        ('27','Maharashtra'),       ('29','Karnataka'),        ('30','Goa'),
        ('31','Lakshadweep'),       ('32','Kerala'),           ('33','Tamil Nadu'),
        ('34','Puducherry'),        ('35','Andaman and Nicobar Islands'),
        ('36','Telangana'),         ('37','Andhra Pradesh'),   ('38','Ladakh');
    PRINT '  + seed     PUMP.States (36 rows)';
END
GO

/* ---- F2. Subscription plans ---- */
IF NOT EXISTS (SELECT 1 FROM PUMP.SubscriptionPlans)
BEGIN
    INSERT INTO PUMP.SubscriptionPlans (PlanCode, PlanName, DurationDays, MaxPumps, MaxUsers, BaseAmount, GSTRate) VALUES
        ('TRIAL',     'Free Trial',        7,    1,   5,      0.00, 18.00),
        ('BASIC_M',   'Basic Monthly',     30,   1,  10,    999.00, 18.00),
        ('BASIC_Y',   'Basic Yearly',      365,  1,  10,   9990.00, 18.00),
        ('PRO_M',     'Pro Monthly',       30,   3,  25,   2499.00, 18.00),
        ('PRO_Y',     'Pro Yearly',        365,  3,  25,  24990.00, 18.00),
        ('ENT_Y',     'Enterprise Yearly', 365, 50, 500,  99990.00, 18.00);
    PRINT '  + seed     PUMP.SubscriptionPlans (6 rows)';
END
GO

/* ---- F3. App settings ---- */
IF NOT EXISTS (SELECT 1 FROM PUMP.AppSettings WHERE OwnerId = 0)
BEGIN
    INSERT INTO PUMP.AppSettings (SettingKey, SettingValue, OwnerId, Description) VALUES
        ('TrialDays',            '7',     0, 'Naye owner ko kitne din ka free trial'),
        ('CashShortToleranceRs', '100',   0, 'Itne tak ka short/excess normal maana jayega'),
        ('MaxLoginAttempts',     '5',     0, 'Itni galat koshish ke baad account lock'),
        ('LockoutMinutes',       '15',    0, 'Lock kitni der ke liye'),
        ('StockVariancePercent', '0.5',   0, 'Dip vs meter variance ki allowed limit (%)'),
        ('PaymentProvider',      'MANUAL',0, 'MANUAL / RAZORPAY / PHONEPE / CASHFREE'),
        ('PaymentEnabled',       'false', 0, 'Gateway on karne ke liye true kar dena');
    PRINT '  + seed     PUMP.AppSettings (7 rows)';
END
GO

/* ---- F4. Owners.ValidUpto backfill ----
   BLOCKER FIX: sp_Auth_Login ValidUpto return nahi karta tha aur column hi nahi tha,
   isliye AuthService har non-superadmin ko TRIAL_EXPIRED de raha tha. Ab column aa
   gaya hai — purane owners ko 1 saal de rahe hain taaki koi lock out na ho. */
UPDATE PUMP.Owners
SET ValidUpto = DATEADD(YEAR, 1, CAST(SYSDATETIME() AS DATE)),
    IsTrial   = 0,
    PlanCode  = ISNULL(PlanCode, 'BASIC_Y')
WHERE ValidUpto IS NULL;
PRINT '  ~ backfill Owners.ValidUpto -> +1 year (' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' rows)';
GO

/* ---- F5. Nozzle -> Tank mapping backfill ----
   BLOCKER FIX: Nozzles.TankId column tha par kahin use nahi hota tha aur naye nozzle
   par NULL reh jaata tha. Jahan product ka theek ek active tank hai, wahan auto-map
   kar dete hain. Jahan ek se zyada tank hain, wahan manually chunna padega — neeche
   report me dikh jayega. */
UPDATE n
SET n.TankId = t.TankId
FROM PUMP.Nozzles n
CROSS APPLY
(
    SELECT MIN(tk.Id) AS TankId, COUNT(*) AS TankCount
    FROM PUMP.Tanks tk
    WHERE tk.PumpId = n.PumpId
      AND tk.ProductId = n.ProductId
      AND tk.IsActive = 1
) t
WHERE n.TankId IS NULL
  AND t.TankCount = 1;
PRINT '  ~ backfill Nozzles.TankId (' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' rows auto-mapped)';
GO

/* ---- F6. ProductRateHistory ko OwnerId/PumpId de do ---- */
UPDATE h
SET h.OwnerId = p.OwnerId,
    h.PumpId  = p.PumpId,
    h.EffectiveFrom = ISNULL(h.EffectiveFrom, h.ChangedAt)
FROM PUMP.ProductRateHistory h
JOIN PUMP.Products p ON p.Id = h.ProductId
WHERE h.OwnerId IS NULL;
GO

/* ---- F7. Har active product ka current rate history me daal do ----
   Taaki "aaj se pehle ka rate kya tha" ka kam se kam ek baseline mile. */
INSERT INTO PUMP.ProductRateHistory (ProductId, OwnerId, PumpId, OldRate, NewRate, ChangedAt, EffectiveFrom)
SELECT p.Id, p.OwnerId, p.PumpId, p.CurrentRate, p.CurrentRate, SYSDATETIME(), SYSDATETIME()
FROM PUMP.Products p
WHERE NOT EXISTS (SELECT 1 FROM PUMP.ProductRateHistory h WHERE h.ProductId = p.Id);
PRINT '  ~ backfill ProductRateHistory baseline (' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' rows)';
GO

/* ---- F8. Fuel flag ---- */
UPDATE PUMP.Products
SET IsFuel = 1
WHERE Category IN ('Petrol', 'Diesel', 'CNG')
  AND IsFuel = 0;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ==========================================================================================
   SECTION G — STORED PROCEDURES  (naye + fix kiye hue)
   ------------------------------------------------------------------------------------------
   Sab CREATE OR ALTER hain, isliye baar-baar chala sakte ho.
   ========================================================================================== */
PRINT '--- Section G: stored procedures ---';
GO


/* ==========================================================================================
   G1. AUDIT — har jagah se call hota hai
   ========================================================================================== */
CREATE OR ALTER PROCEDURE PUMP.sp_Audit_Log
(
    @OwnerId    BIGINT        = NULL,
    @PumpId     BIGINT        = NULL,
    @UserId     BIGINT        = NULL,
    @UserName   NVARCHAR(100) = NULL,
    @EntityName NVARCHAR(100),
    @EntityId   BIGINT        = NULL,
    @Action     NVARCHAR(30),
    @OldValues  NVARCHAR(MAX) = NULL,
    @NewValues  NVARCHAR(MAX) = NULL,
    @Reason     NVARCHAR(500) = NULL,
    @IpAddress  NVARCHAR(45)  = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO PUMP.AuditLog
        (OwnerId, PumpId, UserId, UserName, EntityName, EntityId, Action, OldValues, NewValues, Reason, IpAddress)
    VALUES
        (@OwnerId, @PumpId, @UserId, @UserName, @EntityName, @EntityId, @Action, @OldValues, @NewValues, @Reason, @IpAddress);
END
GO


/* ==========================================================================================
   G2. AUTH
   ------------------------------------------------------------------------------------------
   BLOCKER FIX: purana sp_Auth_Login ValidUpto return hi nahi karta tha, isliye
   AuthService.cs me `user.ValidUpto ?? DateTime.MinValue` hamesha MinValue banta tha
   aur har non-superadmin ko TRIAL_EXPIRED milta tha. Ab ValidUpto aata hai.

   BLOCKER FIX (2026-09-03): Role join INNER tha, isliye jis user ki koi row
   PUMP.UserRoles me nahi thi (jaise seed `superadmin`, jisse koi role assign hi nahi
   kiya gaya) wo LOGIN HI NAHI KAR SAKTA THA — password sahi hone par bhi row match
   nahi hoti thi. Ab LEFT JOIN hai; role-less user ko RoleId=0 / RoleName='SuperAdmin'
   milta hai (sirf IsSuperAdmin users ke liye relevant — API me RoleId un ke liye
   kahin check nahi hota, /api/menus/my seedha IsSuperAdmin claim dekhta hai). */
CREATE OR ALTER PROCEDURE PUMP.sp_Auth_Login
(
    @Username NVARCHAR(100)
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 1
        u.Id            AS UserId,
        u.OwnerId,
        u.FullName,
        u.Username,
        ISNULL(r.Id, 0)             AS RoleId,
        ISNULL(r.Name, N'SuperAdmin') AS RoleName,
        u.PasswordHash,
        u.IsSuperAdmin,
        o.ValidUpto,                       -- <== ye missing tha
        ISNULL(o.IsActive, 1) AS OwnerIsActive,
        o.PlanCode,
        ISNULL(o.IsTrial, 0)  AS IsTrial
    FROM PUMP.Users u
    LEFT JOIN PUMP.UserRoles ur ON ur.UserId = u.Id
    LEFT JOIN PUMP.Roles     r  ON r.Id = ur.RoleId
    LEFT JOIN PUMP.Owners    o  ON o.Id = u.OwnerId
    WHERE u.Username = @Username
      AND u.IsActive = 1
      AND ISNULL(u.IsDeleted, 0) = 0
      AND (r.IsActive = 1 OR r.Id IS NULL);
END
GO

CREATE OR ALTER PROCEDURE PUMP.sp_Auth_GetByUserId
(
    @UserId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 1
        u.Id AS UserId, u.OwnerId, u.FullName, u.Username,
        ISNULL(r.Id, 0) AS RoleId, ISNULL(r.Name, N'SuperAdmin') AS RoleName, u.PasswordHash, u.IsSuperAdmin,
        o.ValidUpto, ISNULL(o.IsActive, 1) AS OwnerIsActive, o.PlanCode, ISNULL(o.IsTrial, 0) AS IsTrial
    FROM PUMP.Users u
    LEFT JOIN PUMP.UserRoles ur ON ur.UserId = u.Id
    LEFT JOIN PUMP.Roles     r  ON r.Id = ur.RoleId
    LEFT JOIN PUMP.Owners    o  ON o.Id = u.OwnerId
    WHERE u.Id = @UserId
      AND u.IsActive = 1
      AND ISNULL(u.IsDeleted, 0) = 0
      AND (r.IsActive = 1 OR r.Id IS NULL);
END
GO

/* Brute-force lockout — API ka rate limiter global hai (poore India ke liye 10/min),
   isliye per-user lockout DB level par rakha hai. */
CREATE OR ALTER PROCEDURE PUMP.sp_LoginAttempt_Record
(
    @Username  NVARCHAR(100),
    @IpAddress NVARCHAR(45) = NULL,
    @IsSuccess BIT
)
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO PUMP.LoginAttempts (Username, IpAddress, IsSuccess)
    VALUES (@Username, @IpAddress, @IsSuccess);

    -- success par purane fail attempts clear kar do
    IF @IsSuccess = 1
        DELETE FROM PUMP.LoginAttempts
        WHERE Username = @Username AND IsSuccess = 0;

    -- 30 din se purane attempts hata do (table bloat na ho)
    DELETE FROM PUMP.LoginAttempts
    WHERE AttemptedOn < DATEADD(DAY, -30, SYSDATETIME());
END
GO

CREATE OR ALTER PROCEDURE PUMP.sp_LoginAttempt_IsLocked
(
    @Username NVARCHAR(100)
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @MaxAttempts INT = TRY_CAST((SELECT SettingValue FROM PUMP.AppSettings WHERE SettingKey='MaxLoginAttempts' AND OwnerId=0) AS INT);
    DECLARE @LockMinutes INT = TRY_CAST((SELECT SettingValue FROM PUMP.AppSettings WHERE SettingKey='LockoutMinutes'   AND OwnerId=0) AS INT);
    SET @MaxAttempts = ISNULL(@MaxAttempts, 5);
    SET @LockMinutes = ISNULL(@LockMinutes, 15);

    DECLARE @Fails INT =
    (
        SELECT COUNT(*) FROM PUMP.LoginAttempts
        WHERE Username = @Username
          AND IsSuccess = 0
          AND AttemptedOn > DATEADD(MINUTE, -@LockMinutes, SYSDATETIME())
    );

    SELECT
        IsLocked        = CASE WHEN @Fails >= @MaxAttempts THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END,
        FailedAttempts  = @Fails,
        UnlocksInMinutes= @LockMinutes;
END
GO


/* ==========================================================================================
   G3. OWNER / SUBSCRIPTION  (missing SPs — code inhe call karta tha, DB me the hi nahi)
   ========================================================================================== */
CREATE OR ALTER PROCEDURE PUMP.sp_Owner_GetList
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        o.Id, o.Name, o.IsActive, o.CreatedOn,
        o.ValidUpto, o.ContactName, o.ContactNo, o.Email, o.City, o.StateCode,
        o.GSTIN, o.PlanCode, o.IsTrial,
        PumpCount = (SELECT COUNT(*) FROM PUMP.Pumps p WHERE p.OwnerId = o.Id AND ISNULL(p.IsDeleted,0) = 0),
        UserCount = (SELECT COUNT(*) FROM PUMP.Users  u WHERE u.OwnerId = o.Id AND ISNULL(u.IsDeleted,0) = 0),
        DaysLeft  = DATEDIFF(DAY, CAST(SYSDATETIME() AS DATE), o.ValidUpto)
    FROM PUMP.Owners o
    WHERE ISNULL(o.IsDeleted, 0) = 0
      /* '-- SYSTEM --' asli grahak nahi hai. Wo sirf isliye banaya gaya hai ki
         'superadmin' user ko ek OwnerId chahiye (Users.OwnerId ka FK). Use tenant
         ki list me dikhane ka matlab nahi — na uska trial badhta hai, na wo
         suspend hota hai. */
      AND o.Name <> N'-- SYSTEM --'
    ORDER BY o.Id DESC;
END
GO

/* MISSING SP — OwnerRepository.ExtendTrialAsync ise call karta hai */
CREATE OR ALTER PROCEDURE PUMP.sp_Owner_ExtendTrial
(
    @OwnerId      BIGINT,
    @NewValidUpto DATE,
    @UserId       BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Old DATE = (SELECT ValidUpto FROM PUMP.Owners WHERE Id = @OwnerId);

    IF @Old IS NULL AND NOT EXISTS (SELECT 1 FROM PUMP.Owners WHERE Id = @OwnerId)
    BEGIN
        THROW 50100, 'Owner not found.', 1;
    END

    UPDATE PUMP.Owners
    SET ValidUpto  = @NewValidUpto,
        IsTrial    = 0,
        ModifiedBy = @UserId,
        ModifiedOn = SYSDATETIME()
    WHERE Id = @OwnerId;

    EXEC PUMP.sp_Audit_Log
        @OwnerId = @OwnerId, @UserId = @UserId,
        @EntityName = 'Owners', @EntityId = @OwnerId, @Action = 'EXTEND_TRIAL',
        @OldValues = @Old, @NewValues = @NewValidUpto;

    SELECT @OwnerId AS Id;
END
GO

/* MISSING SPs — SubscriptionRequestRepository inhe call karta hai */
CREATE OR ALTER PROCEDURE PUMP.sp_SubscriptionRequest_Save
(
    @ContactName NVARCHAR(150),
    @ContactNo   NVARCHAR(20),
    @PlanType    NVARCHAR(50)  = NULL,
    @OwnerId     BIGINT        = NULL,
    @PumpName    NVARCHAR(200) = NULL,
    @City        NVARCHAR(100) = NULL,
    @StateCode   NVARCHAR(2)   = NULL,
    @SourceIp    NVARCHAR(45)  = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    /* Spam guard — endpoint public hai (bina auth ke). Ek hi number se 1 ghante me
       3 se zyada request nahi. API par rate limit lagne tak ye pehli deewar hai. */
    IF (SELECT COUNT(*) FROM PUMP.SubscriptionRequests
        WHERE ContactNo = @ContactNo
          AND CreatedOn > DATEADD(HOUR, -1, SYSDATETIME())) >= 3
    BEGIN
        SELECT CAST(-1 AS BIGINT) AS Id;
        RETURN;
    END

    INSERT INTO PUMP.SubscriptionRequests
        (OwnerId, ContactName, ContactNo, PumpName, PlanType, City, StateCode, SourceIp)
    VALUES
        (@OwnerId, @ContactName, @ContactNo, @PumpName, @PlanType, @City, @StateCode, @SourceIp);

    SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS Id;
END
GO

CREATE OR ALTER PROCEDURE PUMP.sp_SubscriptionRequest_GetList
(
    @Status NVARCHAR(20) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT r.Id, r.OwnerId, r.ContactName, r.ContactNo, r.PumpName, r.PlanType,
           r.City, r.StateCode, r.Status, r.Notes,
           r.CreatedOn AS RequestedOn,   -- C# DTO me naam RequestedOn hai
           r.DoneOn,
           s.StateName
    FROM PUMP.SubscriptionRequests r
    LEFT JOIN PUMP.States s ON s.StateCode = r.StateCode
    WHERE (@Status IS NULL OR r.Status = @Status)
    ORDER BY r.CreatedOn DESC;
END
GO

CREATE OR ALTER PROCEDURE PUMP.sp_SubscriptionRequest_MarkDone
(
    @Id     BIGINT,
    @UserId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE PUMP.SubscriptionRequests
    SET Status = 'DONE', DoneOn = SYSDATETIME(), DoneBy = @UserId
    WHERE Id = @Id;
    SELECT @Id AS Id;
END
GO

CREATE OR ALTER PROCEDURE PUMP.sp_SubscriptionPlan_List
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, PlanCode, PlanName, DurationDays, MaxPumps, MaxUsers,
           BaseAmount, GSTRate,
           TotalAmount = ROUND(BaseAmount * (1 + GSTRate / 100.0), 2)
    FROM PUMP.SubscriptionPlans
    WHERE IsActive = 1
    ORDER BY BaseAmount;
END
GO


/* ==========================================================================================
   G4. PAYMENT GATEWAY — DHANCHA TAIYAAR, INTEGRATION BAAD ME
   ------------------------------------------------------------------------------------------
   Aapne kaha gateway abhi nahi lagana par jugaad rakhna. Yahan poora flow ready hai:

     1. sp_Payment_CreateOrder   -> apna MerchantOrderId banata hai, txn CREATED
     2. (app gateway ko call kare, ProviderOrderId wapas aaye)
     3. sp_Payment_AttachProviderOrder
     4. sp_PaymentWebhook_Record -> gateway callback, duplicate apne aap ignore
     5. sp_Payment_MarkSuccess   -> subscription ACTIVE + Owner.ValidUpto badha deta hai

   Aaj PaymentMode = 'MANUAL' se yahi flow chalta hai. Gateway lagane ke din sirf
   step 2 aur 4 me HTTP call add karni hai — DB, idempotency, subscription sab ready.
   ========================================================================================== */
CREATE OR ALTER PROCEDURE PUMP.sp_Payment_CreateOrder
(
    @OwnerId  BIGINT,
    @PlanId   BIGINT,
    @Provider NVARCHAR(30) = 'MANUAL',
    @UserId   BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Base DECIMAL(18,2), @Gst DECIMAL(5,2), @Days INT;
    SELECT @Base = BaseAmount, @Gst = GSTRate, @Days = DurationDays
    FROM PUMP.SubscriptionPlans WHERE Id = @PlanId AND IsActive = 1;

    IF @Base IS NULL
    BEGIN
        THROW 50110, 'Subscription plan not found or inactive.', 1;
    END

    DECLARE @GstAmt   DECIMAL(18,2) = ROUND(@Base * @Gst / 100.0, 2);
    DECLARE @Total    DECIMAL(18,2) = @Base + @GstAmt;
    DECLARE @MerchOid NVARCHAR(64)  = CONCAT('PPMS-', @OwnerId, '-', FORMAT(SYSDATETIME(), 'yyyyMMddHHmmss'), '-', ABS(CHECKSUM(NEWID())) % 10000);

    -- naya subscription period current ValidUpto ke aage se shuru hoga
    DECLARE @Start DATE = (SELECT CASE WHEN ISNULL(ValidUpto, CAST(SYSDATETIME() AS DATE)) > CAST(SYSDATETIME() AS DATE)
                                       THEN DATEADD(DAY, 1, ValidUpto)
                                       ELSE CAST(SYSDATETIME() AS DATE) END
                           FROM PUMP.Owners WHERE Id = @OwnerId);
    SET @Start = ISNULL(@Start, CAST(SYSDATETIME() AS DATE));

    BEGIN TRANSACTION;

        INSERT INTO PUMP.OwnerSubscriptions
            (OwnerId, PlanId, StartDate, EndDate, Amount, GSTAmount, TotalAmount, Status, PaymentMode, CreatedBy)
        VALUES
            (@OwnerId, @PlanId, @Start, DATEADD(DAY, @Days - 1, @Start), @Base, @GstAmt, @Total, 'PENDING', @Provider, @UserId);

        DECLARE @SubId BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);

        INSERT INTO PUMP.PaymentTransactions
            (OwnerId, SubscriptionId, Provider, MerchantOrderId, Amount, Status)
        VALUES
            (@OwnerId, @SubId, @Provider, @MerchOid, @Total, 'CREATED');

        DECLARE @PayId BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);

    COMMIT TRANSACTION;

    SELECT PaymentId      = @PayId,
           SubscriptionId = @SubId,
           MerchantOrderId= @MerchOid,
           Amount         = @Total,
           Currency       = 'INR';
END
GO

CREATE OR ALTER PROCEDURE PUMP.sp_Payment_AttachProviderOrder
(
    @PaymentId       BIGINT,
    @ProviderOrderId NVARCHAR(128),
    @RawPayload      NVARCHAR(MAX) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE PUMP.PaymentTransactions
    SET ProviderOrderId = @ProviderOrderId,
        Status          = 'PENDING',
        RawPayload      = ISNULL(@RawPayload, RawPayload)
    WHERE Id = @PaymentId;
    SELECT @PaymentId AS Id;
END
GO

CREATE OR ALTER PROCEDURE PUMP.sp_Payment_MarkSuccess
(
    @PaymentId         BIGINT,
    @ProviderPaymentId NVARCHAR(128) = NULL,
    @ProviderSignature NVARCHAR(256) = NULL,
    @RawPayload        NVARCHAR(MAX) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Idempotent: already SUCCESS ho to kuch mat karo. Gateway ek hi event
       kai baar bhejta hai — bina iske subscription 3 baar extend ho jaati. */
    IF EXISTS (SELECT 1 FROM PUMP.PaymentTransactions WHERE Id = @PaymentId AND Status = 'SUCCESS')
    BEGIN
        SELECT AlreadyProcessed = CAST(1 AS BIT);
        RETURN;
    END

    DECLARE @OwnerId BIGINT, @SubId BIGINT, @End DATE;

    BEGIN TRANSACTION;

        UPDATE PUMP.PaymentTransactions
        SET Status            = 'SUCCESS',
            ProviderPaymentId = @ProviderPaymentId,
            ProviderSignature = @ProviderSignature,
            RawPayload        = ISNULL(@RawPayload, RawPayload),
            PaidOn            = SYSDATETIME()
        WHERE Id = @PaymentId;

        SELECT @OwnerId = OwnerId, @SubId = SubscriptionId
        FROM PUMP.PaymentTransactions WHERE Id = @PaymentId;

        UPDATE PUMP.OwnerSubscriptions SET Status = 'ACTIVE' WHERE Id = @SubId;

        SELECT @End = EndDate FROM PUMP.OwnerSubscriptions WHERE Id = @SubId;

        UPDATE PUMP.Owners
        SET ValidUpto = @End,
            IsTrial   = 0,
            IsActive  = 1,
            PlanCode  = (SELECT p.PlanCode FROM PUMP.SubscriptionPlans p
                         JOIN PUMP.OwnerSubscriptions s ON s.PlanId = p.Id WHERE s.Id = @SubId)
        WHERE Id = @OwnerId;

    COMMIT TRANSACTION;

    EXEC PUMP.sp_Audit_Log
        @OwnerId = @OwnerId, @EntityName = 'PaymentTransactions', @EntityId = @PaymentId,
        @Action = 'PAYMENT_SUCCESS', @NewValues = @End;

    SELECT AlreadyProcessed = CAST(0 AS BIT), NewValidUpto = @End;
END
GO

CREATE OR ALTER PROCEDURE PUMP.sp_Payment_MarkFailed
(
    @PaymentId     BIGINT,
    @FailureReason NVARCHAR(500) = NULL,
    @RawPayload    NVARCHAR(MAX) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE PUMP.PaymentTransactions
    SET Status = 'FAILED', FailureReason = @FailureReason, RawPayload = ISNULL(@RawPayload, RawPayload)
    WHERE Id = @PaymentId AND Status <> 'SUCCESS';
    SELECT @PaymentId AS Id;
END
GO

CREATE OR ALTER PROCEDURE PUMP.sp_PaymentWebhook_Record
(
    @Provider  NVARCHAR(30),
    @EventId   NVARCHAR(128),
    @EventType NVARCHAR(80)  = NULL,
    @Payload   NVARCHAR(MAX) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    -- duplicate event chup-chaap ignore (unique constraint par bharosa)
    IF EXISTS (SELECT 1 FROM PUMP.PaymentWebhookEvents WHERE Provider = @Provider AND EventId = @EventId)
    BEGIN
        SELECT IsDuplicate = CAST(1 AS BIT), Id = (SELECT Id FROM PUMP.PaymentWebhookEvents WHERE Provider = @Provider AND EventId = @EventId);
        RETURN;
    END

    INSERT INTO PUMP.PaymentWebhookEvents (Provider, EventId, EventType, Payload)
    VALUES (@Provider, @EventId, @EventType, @Payload);

    SELECT IsDuplicate = CAST(0 AS BIT), Id = CAST(SCOPE_IDENTITY() AS BIGINT);
END
GO

/* Roz raat ko chalane ke liye — expire ho chuke subscriptions band kar do */
CREATE OR ALTER PROCEDURE PUMP.sp_Subscription_ExpireDue
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE PUMP.OwnerSubscriptions
    SET Status = 'EXPIRED'
    WHERE Status = 'ACTIVE' AND EndDate < CAST(SYSDATETIME() AS DATE);

    SELECT ExpiredCount = @@ROWCOUNT;
END
GO


/* ==========================================================================================
   G5. PRODUCT + RATE
   ------------------------------------------------------------------------------------------
   FIX: purana sp_Product_Save seedha CurrentRate overwrite kar deta tha aur
   ProductRateHistory me kabhi kuch likhta hi nahi tha (poore DB me ek bhi INSERT nahi
   tha). Isliye "17 June ko XP95 ka rate kya tha" ka jawab system me tha hi nahi.
   ========================================================================================== */
CREATE OR ALTER PROCEDURE PUMP.sp_Product_Save
(
    @Id          BIGINT = NULL,
    @OwnerId     BIGINT,
    @PumpId      BIGINT,
    @Name        NVARCHAR(200),
    @Category    NVARCHAR(50),
    @Unit        NVARCHAR(20),
    @CurrentRate DECIMAL(18,2),
    @HSNCode     NVARCHAR(20) = NULL,
    @CGSTRate    DECIMAL(5,2) = 0,
    @SGSTRate    DECIMAL(5,2) = 0,
    @IGSTRate    DECIMAL(5,2) = 0,
    @VATRate     DECIMAL(5,2) = 0,
    @UserId      BIGINT = NULL,
    @EffectiveFrom DATETIME2(7) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @EffectiveFrom = ISNULL(@EffectiveFrom, SYSDATETIME());

    BEGIN TRANSACTION;

    IF @Id IS NULL OR @Id = 0
    BEGIN
        INSERT INTO PUMP.Products
            (OwnerId, PumpId, Name, Category, Unit, CurrentRate, HSNCode, CGSTRate, SGSTRate, IGSTRate, VATRate, CreatedBy,
             IsFuel)
        VALUES
            (@OwnerId, @PumpId, @Name, @Category, @Unit, @CurrentRate, @HSNCode, @CGSTRate, @SGSTRate, @IGSTRate, @VATRate, @UserId,
             CASE WHEN @Category IN ('Petrol','Diesel','CNG') THEN 1 ELSE 0 END);

        SET @Id = CAST(SCOPE_IDENTITY() AS BIGINT);

        INSERT INTO PUMP.ProductRateHistory (ProductId, OwnerId, PumpId, OldRate, NewRate, ChangedAt, ChangedBy, EffectiveFrom)
        VALUES (@Id, @OwnerId, @PumpId, @CurrentRate, @CurrentRate, SYSDATETIME(), @UserId, @EffectiveFrom);
    END
    ELSE
    BEGIN
        DECLARE @OldRate DECIMAL(18,2);
        SELECT @OldRate = CurrentRate
        FROM PUMP.Products
        WHERE Id = @Id AND OwnerId = @OwnerId AND PumpId = @PumpId;

        IF @OldRate IS NULL
        BEGIN
            ROLLBACK TRANSACTION;
            THROW 50120, 'Product not found or access denied.', 1;
        END

        -- rate badla hai to history likho
        IF @OldRate <> @CurrentRate
        BEGIN
            INSERT INTO PUMP.ProductRateHistory (ProductId, OwnerId, PumpId, OldRate, NewRate, ChangedAt, ChangedBy, EffectiveFrom)
            VALUES (@Id, @OwnerId, @PumpId, @OldRate, @CurrentRate, SYSDATETIME(), @UserId, @EffectiveFrom);
        END

        UPDATE PUMP.Products
        SET Name        = @Name,
            Category    = @Category,
            Unit        = @Unit,
            CurrentRate = @CurrentRate,
            HSNCode     = @HSNCode,
            CGSTRate    = @CGSTRate,
            SGSTRate    = @SGSTRate,
            IGSTRate    = @IGSTRate,
            VATRate     = @VATRate,
            IsFuel      = CASE WHEN @Category IN ('Petrol','Diesel','CNG') THEN 1 ELSE 0 END,
            UpdatedOn   = SYSUTCDATETIME(),
            ModifiedBy  = @UserId,
            ModifiedOn  = SYSDATETIME()
        WHERE Id = @Id AND OwnerId = @OwnerId AND PumpId = @PumpId;
    END

    COMMIT TRANSACTION;

    SELECT @Id AS Id;
END
GO

/* Kisi bhi date ka rate — back-dated entry aur audit dono ke liye */
CREATE OR ALTER PROCEDURE PUMP.sp_Product_GetRateOnDate
(
    @ProductId BIGINT,
    @OnDate    DATETIME2(7)
)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 1
        Rate = h.NewRate,
        EffectiveFrom = ISNULL(h.EffectiveFrom, h.ChangedAt)
    FROM PUMP.ProductRateHistory h
    WHERE h.ProductId = @ProductId
      AND ISNULL(h.EffectiveFrom, h.ChangedAt) <= @OnDate
    ORDER BY ISNULL(h.EffectiveFrom, h.ChangedAt) DESC;

    -- history na mile to current rate
    IF @@ROWCOUNT = 0
        SELECT Rate = CurrentRate, EffectiveFrom = CAST(NULL AS DATETIME2(7))
        FROM PUMP.Products WHERE Id = @ProductId;
END
GO

/* Roz subah ka rate update — pan-India me sabse zyada hone wala kaam.

   PEHLE KYA GALAT THA: ye sirf @Category leta tha aur us category ke SAARE product
   ek hi rate par set kar deta tha. Jis pump par ek se zyada petrol grade hain
   (Normal, Premium/XP95, E20 ethanol-blend) wahan ye har subah teeno ka rate
   barabar kar deta — Premium Rs 110.50 aur E20 Rs 99.80 dono Rs 105 ban jaate.
   Test me exactly yahi hua tha (UpdatedCount = 3).

   AB DO TAREEKE HAIN:
   1. @RatesJson — [{"ProductId":1,"NewRate":105.00},{"ProductId":9,"NewRate":112.00}]
      Har grade ka apna rate. Multi-grade pump ke liye YAHI istemaal karein.
   2. @Category + @NewRate — sirf tab chalega jab us category me us owner ka
      ek hi product ho. Ek se zyada honge to saaf error milega, chupchaap
      rate flatten nahi hoga. */
CREATE OR ALTER PROCEDURE PUMP.sp_Product_BulkRateUpdate
(
    @OwnerId    BIGINT,
    @Category   NVARCHAR(50) = NULL,
    @NewRate    DECIMAL(18,2) = NULL,
    @StateCode  NVARCHAR(2)  = NULL,
    @UserId     BIGINT = NULL,
    @RatesJson  NVARCHAR(MAX) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @RatesJson IS NULL AND (@Category IS NULL OR @NewRate IS NULL)
        THROW 50080, 'Provide either @RatesJson, or @Category together with @NewRate.', 1;

    /* Kaun se product badalne hain — dono tareeke ek hi table me la dete hain. */
    DECLARE @Target TABLE (ProductId BIGINT PRIMARY KEY, NewRate DECIMAL(18,2));

    IF @RatesJson IS NOT NULL
    BEGIN
        IF ISJSON(@RatesJson) <> 1
            THROW 50081, 'RatesJson is not valid JSON.', 1;

        INSERT INTO @Target (ProductId, NewRate)
        SELECT p.Id, x.NewRate
        FROM OPENJSON(@RatesJson)
             WITH (ProductId BIGINT '$.ProductId', NewRate DECIMAL(18,2) '$.NewRate') x
        /* Owner ka apna product hi badle — id badal kar doosre owner ka rate
           chhedna mumkin nahi hona chahiye. */
        JOIN PUMP.Products p ON p.Id = x.ProductId AND p.OwnerId = @OwnerId
        JOIN PUMP.Pumps   pm ON pm.Id = p.PumpId
        WHERE p.IsActive = 1
          AND ISNULL(p.IsDeleted, 0) = 0
          AND x.NewRate > 0
          AND (@StateCode IS NULL OR pm.StateCode = @StateCode);
    END
    ELSE
    BEGIN
        /* Category wala purana tareeka — lekin ab surakshit. */
        DECLARE @GradeCount INT =
        (
            SELECT COUNT(DISTINCT p.Id)
            FROM PUMP.Products p
            JOIN PUMP.Pumps pm ON pm.Id = p.PumpId
            WHERE p.OwnerId = @OwnerId AND p.Category = @Category
              AND p.IsActive = 1 AND ISNULL(p.IsDeleted, 0) = 0
              AND (@StateCode IS NULL OR pm.StateCode = @StateCode)
        );

        IF @GradeCount > 1
            THROW 50082, 'This category has more than one grade (e.g. Normal, Premium, E20). Each grade has its own rate - send per-grade rates using @RatesJson.', 1;

        INSERT INTO @Target (ProductId, NewRate)
        SELECT p.Id, @NewRate
        FROM PUMP.Products p
        JOIN PUMP.Pumps pm ON pm.Id = p.PumpId
        WHERE p.OwnerId = @OwnerId AND p.Category = @Category
          AND p.IsActive = 1 AND ISNULL(p.IsDeleted, 0) = 0
          AND (@StateCode IS NULL OR pm.StateCode = @StateCode);
    END

    DECLARE @Updated INT = 0;

    BEGIN TRANSACTION;

        /* History pehle - sirf jinka rate sach me badla hai. */
        INSERT INTO PUMP.ProductRateHistory
            (ProductId, OwnerId, PumpId, OldRate, NewRate, ChangedAt, ChangedBy, EffectiveFrom)
        SELECT p.Id, p.OwnerId, p.PumpId, p.CurrentRate, t.NewRate,
               SYSDATETIME(), @UserId, SYSDATETIME()
        FROM PUMP.Products p
        JOIN @Target t ON t.ProductId = p.Id
        WHERE p.CurrentRate <> t.NewRate;

        UPDATE p
        SET p.CurrentRate = t.NewRate,
            p.UpdatedOn   = SYSUTCDATETIME(),
            p.ModifiedBy  = @UserId,
            p.ModifiedOn  = SYSDATETIME()
        FROM PUMP.Products p
        JOIN @Target t ON t.ProductId = p.Id
        WHERE p.CurrentRate <> t.NewRate;

        SET @Updated = @@ROWCOUNT;

    COMMIT TRANSACTION;

    SELECT UpdatedCount = @Updated;
END
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ==========================================================================================
   G6. SHIFT — sabse zaroori hissa
   ------------------------------------------------------------------------------------------
   Purane sp_Shift_Close me 6 bugs the:

     1. Tank deduction ProductId par join karta tha, Nozzles.TankId par nahi.
        Ek product ke DO tank hote hi har tank se poora sale ghat jaata tha (double).
     2. Meter rollover (999999.99 -> 0) par THROW hota tha, shift close hi nahi hoti thi.
     3. Band shift edit karne par readings sudhar jaate the par tank stock purana galat
        hi rehta tha — sales aur stock hamesha ke liye alag.
     4. TankTransactions.TxnDateTime me SYSDATETIME() jaata tha, ShiftDate nahi —
        back-dated entry aaj ki date par stamp hoti thi.
     5. TestingLoss SoldQty se ghata dete the par tank se nikaalte hi nahi the.
     6. Koi transaction wrapper nahi tha — beech me fail hua to aadha kaam.

   Sab theek. Saath me expected cash bhi calculate hota hai (neeche G7 dekho).
   ========================================================================================== */

CREATE OR ALTER PROCEDURE PUMP.sp_Shift_Open
(
    @OwnerId            BIGINT,
    @PumpId             BIGINT,
    @OperatorUserId     BIGINT = NULL,
    @ShiftDate          DATE,
    @ShiftCode          NVARCHAR(30),
    @OpeningCash        DECIMAL(18,2) = 0,
    @Notes              NVARCHAR(500) = NULL,
    @NozzleReadingsJson NVARCHAR(MAX) = NULL,
    @UserId             BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF EXISTS (SELECT 1 FROM PUMP.ShiftHeaders
               WHERE OwnerId = @OwnerId AND PumpId = @PumpId AND Status = 'OPEN')
    BEGIN
        SELECT CAST(-1 AS BIGINT) AS Id;   -- pehle se ek shift khuli hai
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM PUMP.ShiftHeaders
               WHERE PumpId = @PumpId AND ShiftDate = @ShiftDate AND ShiftCode = @ShiftCode)
    BEGIN
        SELECT CAST(-3 AS BIGINT) AS Id;   -- isi din ka isi code ka shift already hai
        RETURN;
    END

    DECLARE @ShiftId BIGINT;

    BEGIN TRANSACTION;

        INSERT INTO PUMP.ShiftHeaders
            (OwnerId, PumpId, OperatorUserId, ShiftDate, ShiftCode, OpeningCash, Notes, OpenedOn, Status, CreatedBy)
        VALUES
            (@OwnerId, @PumpId, @OperatorUserId, @ShiftDate, @ShiftCode, @OpeningCash, @Notes, SYSDATETIME(), 'OPEN', @UserId);

        SET @ShiftId = CAST(SCOPE_IDENTITY() AS BIGINT);

        IF @NozzleReadingsJson IS NOT NULL AND ISJSON(@NozzleReadingsJson) = 1
        BEGIN
            INSERT INTO PUMP.ShiftNozzleReadings
                (OwnerId, PumpId, ShiftId, NozzleId, ProductId, OpeningReading, Rate, CreatedBy)
            SELECT
                @OwnerId, @PumpId, @ShiftId,
                x.NozzleId,
                n.ProductId,                          -- nozzle master se lo, client se nahi
                ISNULL(x.OpeningReading, 0),
                /* Rate har nozzle ka apne product ka hai — ek pump par petrol, premium
                   petrol, diesel, premium diesel alag-alag rate par chal sakte hain.
                   Aur us DIN ka rate lena hai, aaj ka nahi: 10 din purani shift dalte
                   waqt aaj ka rate lag jaata to sale ka amount galat banta. */
                PUMP.fn_ProductRateOnDate(n.ProductId,
                    DATEADD(HOUR, 23, CAST(@ShiftDate AS DATETIME2(7)))),
                @UserId
            FROM OPENJSON(@NozzleReadingsJson)
            WITH (NozzleId BIGINT '$.NozzleId', OpeningReading DECIMAL(18,3) '$.OpeningReading') x
            INNER JOIN PUMP.Nozzles  n ON n.Id = x.NozzleId
                                      AND n.PumpId = @PumpId
                                      AND n.OwnerId = @OwnerId
                                      AND n.IsActive = 1
                                      AND ISNULL(n.IsDeleted, 0) = 0
            INNER JOIN PUMP.Products p ON p.Id = n.ProductId
            WHERE ISNULL(x.NozzleId, 0) > 0;
        END

        /* Nozzle ka tank map nahi hai to abhi hi bata do — shift close par pata chalna
           bahut late hai. -4 = pehle nozzle master me tank set karo. */
        IF EXISTS
        (
            SELECT 1
            FROM PUMP.ShiftNozzleReadings snr
            JOIN PUMP.Nozzles n ON n.Id = snr.NozzleId
            WHERE snr.ShiftId = @ShiftId
              AND n.TankId IS NULL
              AND (SELECT COUNT(*) FROM PUMP.Tanks t
                   WHERE t.PumpId = @PumpId AND t.ProductId = n.ProductId AND t.IsActive = 1) <> 1
        )
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT CAST(-4 AS BIGINT) AS Id;
            RETURN;
        END

    COMMIT TRANSACTION;

    SELECT @ShiftId AS Id;
END
GO


CREATE OR ALTER PROCEDURE PUMP.sp_Shift_Close
(
    @Id                 BIGINT,
    @ClosingCash        DECIMAL(18,2) = NULL,
    @Notes              NVARCHAR(500) = NULL,
    @NozzleReadingsJson NVARCHAR(MAX) = NULL,
    @UserId             BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @OwnerId BIGINT, @PumpId BIGINT, @Status NVARCHAR(30),
            @ShiftDate DATE, @OpeningCash DECIMAL(18,2), @WasClosed BIT = 0;

    SELECT TOP 1
        @OwnerId     = OwnerId,
        @PumpId      = PumpId,
        @Status      = Status,
        @ShiftDate   = ShiftDate,
        @OpeningCash = OpeningCash
    FROM PUMP.ShiftHeaders
    WHERE Id = @Id;

    IF @OwnerId IS NULL BEGIN SELECT CAST(-1 AS BIGINT) AS Id; RETURN; END
    IF ISNULL(@Status, '') NOT IN ('OPEN', 'CLOSED') BEGIN SELECT CAST(-2 AS BIGINT) AS Id; RETURN; END

    SET @WasClosed = CASE WHEN @Status = 'CLOSED' THEN 1 ELSE 0 END;

    /* FIX #4 — tank movement ki date shift ki date honi chahiye, aaj ki nahi.
       Aaj ki shift hai to asli time, warna us din ka 23:00. */
    DECLARE @TxnStamp DATETIME2(7) =
        CASE WHEN @ShiftDate = CAST(SYSDATETIME() AS DATE)
             THEN SYSDATETIME()
             ELSE DATEADD(HOUR, 23, CAST(CAST(@ShiftDate AS DATETIME2(7)) AS DATETIME2(7)))
        END;

    DECLARE @ShiftRef NVARCHAR(30) = CONCAT('SHIFT-', @Id);

    BEGIN TRY
        BEGIN TRANSACTION;

        /* ---------- 1. Readings update ---------- */
        IF @NozzleReadingsJson IS NOT NULL AND ISJSON(@NozzleReadingsJson) = 1
        BEGIN
            ;WITH cte AS
            (
                SELECT x.NozzleId, x.ClosingReading, ISNULL(x.TestingLoss, 0) AS TestingLoss
                FROM OPENJSON(@NozzleReadingsJson)
                WITH (NozzleId BIGINT '$.NozzleId',
                      ClosingReading DECIMAL(18,3) '$.ClosingReading',
                      TestingLoss DECIMAL(18,3) '$.TestingLoss') x
                WHERE ISNULL(x.NozzleId, 0) > 0
            )
            UPDATE snr
            SET snr.ClosingReading = cte.ClosingReading,
                snr.TestingLoss    = cte.TestingLoss,
                /* FIX #2 — meter rollover. Closing < Opening ka matlab totalizer
                   ghoom gaya hai, galti nahi. Nozzle ke MeterDigits se wapas jodo. */
                snr.IsRollover     = CASE WHEN cte.ClosingReading < snr.OpeningReading THEN 1 ELSE 0 END,
                snr.SoldQty        =
                    CASE
                        WHEN cte.ClosingReading >= snr.OpeningReading
                            THEN cte.ClosingReading - snr.OpeningReading
                        ELSE POWER(CAST(10 AS DECIMAL(18,3)), n.MeterDigits) - snr.OpeningReading + cte.ClosingReading
                    END
                    - cte.TestingLoss,
                snr.SoldAmount     =
                    (
                        CASE
                            WHEN cte.ClosingReading >= snr.OpeningReading
                                THEN cte.ClosingReading - snr.OpeningReading
                            ELSE POWER(CAST(10 AS DECIMAL(18,3)), n.MeterDigits) - snr.OpeningReading + cte.ClosingReading
                        END
                        - cte.TestingLoss
                    ) * snr.Rate,
                snr.UpdatedOn      = SYSDATETIME(),
                snr.ModifiedBy     = @UserId
            FROM PUMP.ShiftNozzleReadings snr
            INNER JOIN cte           ON cte.NozzleId = snr.NozzleId
            INNER JOIN PUMP.Nozzles n ON n.Id = snr.NozzleId
            WHERE snr.ShiftId = @Id;
        END

        /* ---------- 2. Validation ---------- */
        IF EXISTS (SELECT 1 FROM PUMP.ShiftNozzleReadings WHERE ShiftId = @Id AND ClosingReading IS NULL)
            THROW 50002, 'A closing reading is required for every nozzle.', 1;

        IF EXISTS (SELECT 1 FROM PUMP.ShiftNozzleReadings WHERE ShiftId = @Id AND SoldQty < 0)
            THROW 50004, 'Sold quantity is coming out negative. Check the readings or the testing loss.', 1;

        /* Rollover ke naam par bakwas value na aa jaye — ek shift me ek nozzle se
           50,000 litre se zyada realistic nahi hai. */
        IF EXISTS (SELECT 1 FROM PUMP.ShiftNozzleReadings WHERE ShiftId = @Id AND SoldQty > 50000)
            THROW 50005, 'Sold quantity is too high (over 50,000 L). Please re-check the readings.', 1;

        /* FIX #1 — har nozzle ka apna tank. Pehle TankId, na ho to product ka
           akela tank, aur agar do tank hain to saaf error. */
        IF EXISTS
        (
            SELECT 1
            FROM PUMP.ShiftNozzleReadings snr
            JOIN PUMP.Nozzles n ON n.Id = snr.NozzleId
            WHERE snr.ShiftId = @Id
              AND snr.SoldQty > 0
              AND n.TankId IS NULL
              AND (SELECT COUNT(*) FROM PUMP.Tanks t
                   WHERE t.PumpId = @PumpId AND t.ProductId = n.ProductId AND t.IsActive = 1) <> 1
        )
            THROW 50003, 'Some nozzles have no tank set (or the product has more than one tank). Pick a tank in the Nozzle master.', 1;

        /* ---------- 3. Purani deduction reverse karo (FIX #3) ----------
           Band shift dobara close ho rahi hai to pehle ka asar hata do, phir naya
           daalo. Isse edit karne par stock hamesha sales ke barabar rehta hai. */
        IF @WasClosed = 1
        BEGIN
            UPDATE t
            SET t.CurrentStock = t.CurrentStock + x.Qty
            FROM PUMP.Tanks t
            INNER JOIN
            (
                SELECT TankId, SUM(CASE WHEN TxnType = 'OUT' THEN Quantity ELSE -Quantity END) AS Qty
                FROM PUMP.TankTransactions
                WHERE ReferenceNo = @ShiftRef
                GROUP BY TankId
            ) x ON x.TankId = t.Id;

            DELETE FROM PUMP.TankTransactions WHERE ReferenceNo = @ShiftRef;

            -- is shift ke auto testing-loss records bhi hata do, neeche naye banenge
            DELETE FROM PUMP.TestingLosses WHERE ShiftId = @Id AND LossType = 'SHIFT_TEST';

            EXEC PUMP.sp_Audit_Log
                @OwnerId = @OwnerId, @PumpId = @PumpId, @UserId = @UserId,
                @EntityName = 'ShiftHeaders', @EntityId = @Id, @Action = 'REOPEN_RECALC',
                @Reason = 'Closed shift edited — purani tank deduction reverse karke dobara post ki gayi';
        END

        /* ---------- 4. Pump test ka tel ----------
           Is pump par test ka tel naap kar WAPAS tank me daala jaata hai (user ne
           2026-09-04 ko confirm kiya), isliye ye nuksaan hai hi nahi — na tank se
           ghatega, na TestingLosses me darj hoga.

           Pehle yahan 'SHIFT_TEST' ki row banti thi aur tank se sale+test dono
           ghat jaate the. Us wajah se har test wale din tank me test jitna tel kam
           dikhta tha aur DSR ka closing tank se nahi milta tha.

           Kitna tel test me nikla — ye ab bhi poori tarah darj hai
           (ShiftNozzleReadings.TestingLoss), aur DSR ke "Pump Test" column me
           dikhta hai. TestingLosses table ab sirf ASLI nuksaan ke liye hai, jo
           Testing Loss form se aata hai (sp_TestingLoss_Save khud stock ghatata
           hai — wo theek hai, wahan tel wapas nahi jaata).

           Upar wala DELETE (re-close ke waqt) jaanbujh ke rakha hai, taaki is
           badlav se pehle bani hui SHIFT_TEST rows shift edit karte hi saaf ho jayen. */

        /* ---------- 5. Tank se stock nikalo ----------
           Sirf bikri (SoldQty). SoldQty pehle hi testing loss nikaal kar bana hai
           (dekho upar: closing - opening - TestingLoss), isliye yahi wo tel hai jo
           sach me tank se gaya. */
        ;WITH resolved AS
        (
            SELECT
                TankId = COALESCE(n.TankId, ft.TankId),
                Qty    = snr.SoldQty
            FROM PUMP.ShiftNozzleReadings snr
            JOIN PUMP.Nozzles n ON n.Id = snr.NozzleId
            OUTER APPLY
            (
                SELECT TankId = MIN(t.Id)
                FROM PUMP.Tanks t
                WHERE t.PumpId = @PumpId AND t.ProductId = n.ProductId AND t.IsActive = 1
            ) ft
            WHERE snr.ShiftId = @Id
              AND snr.SoldQty > 0
        ),
        perTank AS
        (
            SELECT TankId, Qty = SUM(Qty)
            FROM resolved
            WHERE TankId IS NOT NULL
            GROUP BY TankId
        )
        INSERT INTO PUMP.TankTransactions
            (OwnerId, PumpId, TankId, TxnType, Quantity, TxnDateTime, ReferenceNo, Notes, CreatedBy)
        SELECT @OwnerId, @PumpId, pt.TankId, 'OUT', pt.Qty, @TxnStamp, @ShiftRef,
               'Shift meter sale (test ka tel wapas tank me gaya)', @UserId
        FROM perTank pt
        WHERE pt.TankId IS NOT NULL;

        UPDATE t
        SET t.CurrentStock = t.CurrentStock - x.Qty
        FROM PUMP.Tanks t
        INNER JOIN
        (
            SELECT TankId, SUM(Quantity) AS Qty
            FROM PUMP.TankTransactions
            WHERE ReferenceNo = @ShiftRef AND TxnType = 'OUT'
            GROUP BY TankId
        ) x ON x.TankId = t.Id;

        /* Stock negative ho gaya to shift rokte nahi (warna operator fans jayega),
           par audit me chillate zaroor hain — matlab opening stock galat tha,
           ya purchase entry reh gayi, ya chori hui hai. */
        INSERT INTO PUMP.AuditLog (OwnerId, PumpId, UserId, EntityName, EntityId, Action, Reason, NewValues)
        SELECT @OwnerId, @PumpId, @UserId, 'Tanks', t.Id, 'NEGATIVE_STOCK',
               CONCAT('Shift ', @Id, ' band hone ke baad tank stock negative hai — purchase entry ya opening stock check karein'),
               CAST(t.CurrentStock AS NVARCHAR(50))
        FROM PUMP.Tanks t
        WHERE t.Id IN (SELECT TankId FROM PUMP.TankTransactions WHERE ReferenceNo = @ShiftRef)
          AND t.CurrentStock < 0;

        /* ---------- 6. Cash reconciliation (neeche G7 wala formula) ---------- */
        DECLARE @MeterSale DECIMAL(18,2) =
            ISNULL((SELECT SUM(SoldAmount) FROM PUMP.ShiftNozzleReadings WHERE ShiftId = @Id), 0);

        DECLARE @Credit DECIMAL(18,2) =
            ISNULL((SELECT SUM(TotalAmount) FROM PUMP.SalesHeaders
                    WHERE ShiftId = @Id AND IsVoid = 0
                      AND UPPER(ISNULL(PaymentMode,'')) = 'CREDIT'), 0);

        DECLARE @Digital DECIMAL(18,2) =
            ISNULL((SELECT SUM(TotalAmount) FROM PUMP.SalesHeaders
                    WHERE ShiftId = @Id AND IsVoid = 0
                      AND UPPER(ISNULL(PaymentMode,'')) IN ('UPI','CARD','DIGITAL','ONLINE','BANK','WALLET')), 0);

        DECLARE @Receipts DECIMAL(18,2) =
            ISNULL((SELECT SUM(Amount) FROM PUMP.PartyLedger
                    WHERE ShiftId = @Id
                      AND UPPER(EntryType) IN ('RECEIPT','PAYMENT_IN','CREDIT')
                      AND UPPER(ISNULL(PaymentMode,'CASH')) = 'CASH'), 0);

        DECLARE @CashIn DECIMAL(18,2) =
            ISNULL((SELECT SUM(Amount) FROM PUMP.CashTransactions
                    WHERE ShiftId = @Id AND UPPER(TxnType) = 'IN'), 0);

        DECLARE @CashOut DECIMAL(18,2) =
            ISNULL((SELECT SUM(Amount) FROM PUMP.CashTransactions
                    WHERE ShiftId = @Id AND UPPER(TxnType) = 'OUT'), 0);

        DECLARE @CashExp DECIMAL(18,2) =
            ISNULL((SELECT SUM(Amount) FROM PUMP.ExpenseTransactions
                    WHERE ShiftId = @Id AND UPPER(ISNULL(PaymentMode,'CASH')) = 'CASH'), 0);

        DECLARE @Deposit DECIMAL(18,2) =
            ISNULL((SELECT SUM(Amount) FROM PUMP.BankDeposits
                    WHERE ShiftId = @Id AND IsDeleted = 0), 0);

        DECLARE @Expected DECIMAL(18,2) =
            @OpeningCash + @MeterSale - @Credit - @Digital + @Receipts + @CashIn - @CashOut - @CashExp - @Deposit;

        UPDATE PUMP.ShiftHeaders
        SET ClosedOn        = COALESCE(ClosedOn, SYSDATETIME()),
            ClosingCash     = COALESCE(@ClosingCash, ClosingCash),
            Notes           = COALESCE(@Notes, Notes),
            Status          = 'CLOSED',
            TotalMeterSale  = @MeterSale,
            ExpectedCash    = @Expected,
            CashShortExcess = ISNULL(COALESCE(@ClosingCash, ClosingCash), 0) - @Expected,
            ClosedByUserId  = ISNULL(@UserId, ClosedByUserId),
            ModifiedBy      = @UserId,
            ModifiedOn      = SYSDATETIME()
        WHERE Id = @Id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC PUMP.sp_Audit_Log
        @OwnerId = @OwnerId, @PumpId = @PumpId, @UserId = @UserId,
        @EntityName = 'ShiftHeaders', @EntityId = @Id, @Action = 'CLOSE';

    SELECT @Id AS Id;
END
GO


/* ==========================================================================================
   G7. CASH — jo abhi tak tha hi nahi
   ------------------------------------------------------------------------------------------
   PROBLEM: purana sp_Shift_Collection_Summary sirf SalesHeaders se credit/digital/expense
   jodta tha. Meter ka asli sale (ShiftNozzleReadings.SoldAmount) kabhi count hi nahi hota
   tha, aur "expected cash" naam ki koi cheez thi hi nahi. ClosingCash bas ek number tha
   jo operator type kar deta tha — koi usse verify hi nahi karta tha.

   Iska matlab: cash chori pakadne ka koi tarika nahi tha. Petrol pump software me yahi
   sabse zaroori feature hai.

   FORMULA:
       Opening Cash
     + Meter Sale            (nozzle readings se — asli bikri)
     - Credit Sale           (udhaar gaya, cash nahi aaya)
     - Digital Sale          (UPI / card se aaya, drawer me nahi)
     + Party Receipts (cash) (purana udhaar cash me wapas aaya)
     + Cash In               (owner ne daala)
     - Cash Out              (drawer se nikala)
     - Cash Expenses         (shift me kharcha)
     - Bank Deposit          (bank me jama)
     ------------------------------------
     = Expected Cash

     Short / Excess = Actual Closing Cash - Expected Cash
   ========================================================================================== */
CREATE OR ALTER PROCEDURE PUMP.sp_Shift_CashSummary
(
    @ShiftId BIGINT,
    @OwnerId BIGINT = NULL     -- tenant guard
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PumpId BIGINT, @OpeningCash DECIMAL(18,2), @ClosingCash DECIMAL(18,2), @ShiftOwner BIGINT;

    SELECT @ShiftOwner = OwnerId, @PumpId = PumpId,
           @OpeningCash = OpeningCash, @ClosingCash = ClosingCash
    FROM PUMP.ShiftHeaders WHERE Id = @ShiftId;

    IF @ShiftOwner IS NULL RETURN;
    IF @OwnerId IS NOT NULL AND @OwnerId <> @ShiftOwner
    BEGIN
        THROW 50130, 'Access denied for this shift.', 1;
    END

    DECLARE @MeterSale DECIMAL(18,2) = ISNULL((SELECT SUM(SoldAmount) FROM PUMP.ShiftNozzleReadings WHERE ShiftId = @ShiftId), 0);
    DECLARE @MeterQty  DECIMAL(18,3) = ISNULL((SELECT SUM(SoldQty)    FROM PUMP.ShiftNozzleReadings WHERE ShiftId = @ShiftId), 0);
    DECLARE @Credit    DECIMAL(18,2) = ISNULL((SELECT SUM(TotalAmount) FROM PUMP.SalesHeaders WHERE ShiftId = @ShiftId AND IsVoid = 0 AND UPPER(ISNULL(PaymentMode,'')) = 'CREDIT'), 0);
    DECLARE @Digital   DECIMAL(18,2) = ISNULL((SELECT SUM(TotalAmount) FROM PUMP.SalesHeaders WHERE ShiftId = @ShiftId AND IsVoid = 0 AND UPPER(ISNULL(PaymentMode,'')) IN ('UPI','CARD','DIGITAL','ONLINE','BANK','WALLET')), 0);
    DECLARE @Receipts  DECIMAL(18,2) = ISNULL((SELECT SUM(Amount) FROM PUMP.PartyLedger WHERE ShiftId = @ShiftId AND UPPER(EntryType) IN ('RECEIPT','PAYMENT_IN','CREDIT') AND UPPER(ISNULL(PaymentMode,'CASH')) = 'CASH'), 0);
    DECLARE @CashIn    DECIMAL(18,2) = ISNULL((SELECT SUM(Amount) FROM PUMP.CashTransactions WHERE ShiftId = @ShiftId AND UPPER(TxnType) = 'IN'), 0);
    DECLARE @CashOut   DECIMAL(18,2) = ISNULL((SELECT SUM(Amount) FROM PUMP.CashTransactions WHERE ShiftId = @ShiftId AND UPPER(TxnType) = 'OUT'), 0);
    DECLARE @CashExp   DECIMAL(18,2) = ISNULL((SELECT SUM(Amount) FROM PUMP.ExpenseTransactions WHERE ShiftId = @ShiftId AND UPPER(ISNULL(PaymentMode,'CASH')) = 'CASH'), 0);
    DECLARE @Deposit   DECIMAL(18,2) =
          ISNULL((SELECT SUM(Amount) FROM PUMP.BankDeposits WHERE ShiftId = @ShiftId AND IsDeleted = 0), 0)
        + ISNULL((SELECT SUM(Amount) FROM PUMP.CashTransactions WHERE ShiftId = @ShiftId AND UPPER(TxnType) = 'BANK_DEPOSIT'), 0);
    DECLARE @Counted   DECIMAL(18,2) = ISNULL((SELECT SUM(Amount) FROM PUMP.ShiftCashDenominations WHERE ShiftId = @ShiftId), 0);

    DECLARE @Expected  DECIMAL(18,2) =
        @OpeningCash + @MeterSale - @Credit - @Digital + @Receipts + @CashIn - @CashOut - @CashExp - @Deposit;

    DECLARE @Tolerance DECIMAL(18,2) =
        ISNULL(TRY_CAST((SELECT SettingValue FROM PUMP.AppSettings WHERE SettingKey = 'CashShortToleranceRs' AND OwnerId = 0) AS DECIMAL(18,2)), 100);

    SELECT
        ShiftId            = @ShiftId,
        OpeningCash        = @OpeningCash,
        TotalMeterSale     = @MeterSale,
        TotalMeterQty      = @MeterQty,
        CreditSales        = @Credit,
        DigitalSales       = @Digital,
        CashSales          = @MeterSale - @Credit - @Digital,
        PartyReceiptsCash  = @Receipts,
        CashIn             = @CashIn,
        CashOut            = @CashOut,
        CashExpenses       = @CashExp,
        BankDeposits       = @Deposit,
        ExpectedCash       = @Expected,
        ActualClosingCash  = @ClosingCash,
        CountedByDenomination = @Counted,
        ShortExcess        = ISNULL(@ClosingCash, 0) - @Expected,
        -- OK / SHORT / EXCESS
        CashStatus         = CASE
                                WHEN @ClosingCash IS NULL THEN 'PENDING'
                                WHEN ABS(ISNULL(@ClosingCash,0) - @Expected) <= @Tolerance THEN 'OK'
                                WHEN ISNULL(@ClosingCash,0) < @Expected THEN 'SHORT'
                                ELSE 'EXCESS'
                             END,
        ToleranceRs        = @Tolerance,
        -- denomination count aur typed closing cash match karte hain?
        DenominationMatch  = CASE WHEN @Counted = 0 THEN CAST(NULL AS BIT)
                                  WHEN @Counted = ISNULL(@ClosingCash,0) THEN CAST(1 AS BIT)
                                  ELSE CAST(0 AS BIT) END;
END
GO

/* ------------------------------------------------------------------------------------------
   Purana naam — /api/shifts/{id}/summary isi ko call karta hai.

   NOTE: ye endpoint PEHLE SE TOOTA HUA THA. Purana SP sirf 3 column deta tha
   (TotalCreditSales, TotalDigitalSales, TotalCashExpenses) jabki C# ka
   ShiftCollectionSummaryDto 6 maangta tha — TotalUpiSales, TotalCardSales aur
   TotalBankDeposits kabhi aate hi nahi the. Dapper record ko constructor se banata
   hai, isliye har call par 500 aata tha.

   Ab column list DTO se bilkul match karti hai, aur upar se cash reconciliation
   ke fields bhi aate hain.

   BLOCKER FIX (2026-09-03): @Deposit sirf PUMP.BankDeposits table se aata tha, jiske
   liye sp_BankDeposit_Save kabhi C# se call hi nahi hota (poori BankAccount/BankDeposit
   feature abhi unused hai — koi UI nahi). Asal me user Cashbook page se "BANK DEPOSIT"
   type ki entry karta hai, jo PUMP.CashTransactions me jaati hai — aur wo yahan kahin
   count hi nahi hoti thi (na @Deposit me, na @CashOut me, jo sirf TxnType='OUT' leta
   hai). Matlab: jis bhi shift me bank deposit hua, ExpectedCash utne se zyada reh
   jaata tha, aur asli match hone par bhi "SHORT" dikhta tha. Ab dono jagah se sum
   karte hain.
   ------------------------------------------------------------------------------------------ */
CREATE OR ALTER PROCEDURE PUMP.sp_Shift_Collection_Summary
(
    @ShiftId BIGINT,
    @OwnerId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ShiftOwner BIGINT, @OpeningCash DECIMAL(18,2), @ClosingCash DECIMAL(18,2);

    SELECT @ShiftOwner = OwnerId, @OpeningCash = OpeningCash, @ClosingCash = ClosingCash
    FROM PUMP.ShiftHeaders WHERE Id = @ShiftId;

    IF @ShiftOwner IS NULL RETURN;

    -- TENANT GUARD
    IF @OwnerId IS NOT NULL AND @OwnerId <> @ShiftOwner RETURN;

    DECLARE @MeterSale DECIMAL(18,2) = ISNULL((SELECT SUM(SoldAmount) FROM PUMP.ShiftNozzleReadings WHERE ShiftId = @ShiftId), 0);
    DECLARE @MeterQty  DECIMAL(18,3) = ISNULL((SELECT SUM(SoldQty)    FROM PUMP.ShiftNozzleReadings WHERE ShiftId = @ShiftId), 0);
    DECLARE @Credit    DECIMAL(18,2) = ISNULL((SELECT SUM(TotalAmount) FROM PUMP.SalesHeaders WHERE ShiftId = @ShiftId AND IsVoid = 0 AND UPPER(ISNULL(PaymentMode,'')) = 'CREDIT'), 0);
    DECLARE @Upi       DECIMAL(18,2) = ISNULL((SELECT SUM(TotalAmount) FROM PUMP.SalesHeaders WHERE ShiftId = @ShiftId AND IsVoid = 0 AND UPPER(ISNULL(PaymentMode,'')) IN ('UPI','WALLET')), 0);
    DECLARE @Card      DECIMAL(18,2) = ISNULL((SELECT SUM(TotalAmount) FROM PUMP.SalesHeaders WHERE ShiftId = @ShiftId AND IsVoid = 0 AND UPPER(ISNULL(PaymentMode,'')) = 'CARD'), 0);
    DECLARE @Digital   DECIMAL(18,2) = ISNULL((SELECT SUM(TotalAmount) FROM PUMP.SalesHeaders WHERE ShiftId = @ShiftId AND IsVoid = 0 AND UPPER(ISNULL(PaymentMode,'')) IN ('UPI','CARD','DIGITAL','ONLINE','BANK','WALLET')), 0);
    DECLARE @Receipts  DECIMAL(18,2) = ISNULL((SELECT SUM(Amount) FROM PUMP.PartyLedger WHERE ShiftId = @ShiftId AND UPPER(EntryType) IN ('RECEIPT','PAYMENT_IN','CREDIT') AND UPPER(ISNULL(PaymentMode,'CASH')) = 'CASH'), 0);
    DECLARE @CashIn    DECIMAL(18,2) = ISNULL((SELECT SUM(Amount) FROM PUMP.CashTransactions WHERE ShiftId = @ShiftId AND UPPER(TxnType) = 'IN'), 0);
    DECLARE @CashOut   DECIMAL(18,2) = ISNULL((SELECT SUM(Amount) FROM PUMP.CashTransactions WHERE ShiftId = @ShiftId AND UPPER(TxnType) = 'OUT'), 0);
    DECLARE @CashExp   DECIMAL(18,2) = ISNULL((SELECT SUM(Amount) FROM PUMP.ExpenseTransactions WHERE ShiftId = @ShiftId AND UPPER(ISNULL(PaymentMode,'CASH')) = 'CASH'), 0);
    DECLARE @Deposit   DECIMAL(18,2) =
          ISNULL((SELECT SUM(Amount) FROM PUMP.BankDeposits WHERE ShiftId = @ShiftId AND IsDeleted = 0), 0)
        + ISNULL((SELECT SUM(Amount) FROM PUMP.CashTransactions WHERE ShiftId = @ShiftId AND UPPER(TxnType) = 'BANK_DEPOSIT'), 0);
    DECLARE @Counted   DECIMAL(18,2) = ISNULL((SELECT SUM(Amount) FROM PUMP.ShiftCashDenominations WHERE ShiftId = @ShiftId), 0);

    DECLARE @Expected  DECIMAL(18,2) =
        @OpeningCash + @MeterSale - @Credit - @Digital + @Receipts + @CashIn - @CashOut - @CashExp - @Deposit;

    DECLARE @Tolerance DECIMAL(18,2) =
        ISNULL(TRY_CAST((SELECT SettingValue FROM PUMP.AppSettings WHERE SettingKey = 'CashShortToleranceRs' AND OwnerId = 0) AS DECIMAL(18,2)), 100);

    SELECT
        -- purane 6 field, wahi naam, wahi order
        TotalCreditSales      = @Credit,
        TotalDigitalSales     = @Digital,
        TotalUpiSales         = @Upi,
        TotalCardSales        = @Card,
        TotalCashExpenses     = @CashExp,
        TotalBankDeposits     = @Deposit,
        -- naye cash reconciliation field
        ShiftId               = @ShiftId,
        OpeningCash           = @OpeningCash,
        TotalMeterSale        = @MeterSale,
        TotalMeterQty         = @MeterQty,
        CashSales             = @MeterSale - @Credit - @Digital,
        PartyReceiptsCash     = @Receipts,
        CashIn                = @CashIn,
        CashOut               = @CashOut,
        ExpectedCash          = @Expected,
        ActualClosingCash     = @ClosingCash,
        CountedByDenomination = @Counted,
        ShortExcess           = ISNULL(@ClosingCash, 0) - @Expected,
        CashStatus            = CASE
                                    WHEN @ClosingCash IS NULL THEN 'PENDING'
                                    WHEN ABS(ISNULL(@ClosingCash,0) - @Expected) <= @Tolerance THEN 'OK'
                                    WHEN ISNULL(@ClosingCash,0) < @Expected THEN 'SHORT'
                                    ELSE 'EXCESS'
                                END,
        ToleranceRs           = @Tolerance,
        DenominationMatch     = CASE WHEN @Counted = 0 THEN CAST(NULL AS BIT)
                                     WHEN @Counted = ISNULL(@ClosingCash,0) THEN CAST(1 AS BIT)
                                     ELSE CAST(0 AS BIT) END;
END
GO

CREATE OR ALTER PROCEDURE PUMP.sp_ShiftCashDenomination_Save
(
    @OwnerId BIGINT,
    @PumpId  BIGINT,
    @ShiftId BIGINT,
    @Json    NVARCHAR(MAX)   -- [{"Denomination":500,"Pieces":12}, ...]
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.ShiftHeaders WHERE Id = @ShiftId AND OwnerId = @OwnerId AND PumpId = @PumpId)
        THROW 50131, 'Shift not found or access denied.', 1;

    IF ISJSON(@Json) <> 1
        THROW 50132, 'Invalid denomination data.', 1;

    BEGIN TRANSACTION;

        DELETE FROM PUMP.ShiftCashDenominations WHERE ShiftId = @ShiftId;

        INSERT INTO PUMP.ShiftCashDenominations (OwnerId, PumpId, ShiftId, Denomination, Pieces)
        SELECT @OwnerId, @PumpId, @ShiftId, x.Denomination, x.Pieces
        FROM OPENJSON(@Json)
        WITH (Denomination INT '$.Denomination', Pieces INT '$.Pieces') x
        WHERE x.Denomination > 0 AND ISNULL(x.Pieces, 0) > 0;

    COMMIT TRANSACTION;

    SELECT TotalCounted = ISNULL(SUM(Amount), 0)
    FROM PUMP.ShiftCashDenominations WHERE ShiftId = @ShiftId;
END
GO

CREATE OR ALTER PROCEDURE PUMP.sp_BankAccount_Save
(
    @Id BIGINT = NULL, @OwnerId BIGINT, @PumpId BIGINT,
    @BankName NVARCHAR(150), @AccountNo NVARCHAR(30),
    @IFSC NVARCHAR(15) = NULL, @Branch NVARCHAR(150) = NULL,
    @OpeningBalance DECIMAL(18,2) = 0, @UserId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    IF @Id IS NULL OR @Id = 0
    BEGIN
        INSERT INTO PUMP.BankAccounts (OwnerId, PumpId, BankName, AccountNo, IFSC, Branch, OpeningBalance)
        VALUES (@OwnerId, @PumpId, @BankName, @AccountNo, @IFSC, @Branch, @OpeningBalance);
        SET @Id = CAST(SCOPE_IDENTITY() AS BIGINT);
    END
    ELSE
    BEGIN
        UPDATE PUMP.BankAccounts
        SET BankName = @BankName, AccountNo = @AccountNo, IFSC = @IFSC, Branch = @Branch
        WHERE Id = @Id AND OwnerId = @OwnerId;
    END
    SELECT @Id AS Id;
END
GO

CREATE OR ALTER PROCEDURE PUMP.sp_BankAccount_List
(
    @OwnerId BIGINT, @PumpId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT b.Id, b.BankName, b.AccountNo, b.IFSC, b.Branch, b.OpeningBalance, b.IsActive,
           CurrentBalance = b.OpeningBalance
                          + ISNULL((SELECT SUM(d.Amount) FROM PUMP.BankDeposits d
                                    WHERE d.BankAccountId = b.Id AND d.IsDeleted = 0), 0)
    FROM PUMP.BankAccounts b
    WHERE b.OwnerId = @OwnerId AND b.PumpId = @PumpId AND b.IsDeleted = 0
    ORDER BY b.BankName;
END
GO

CREATE OR ALTER PROCEDURE PUMP.sp_BankDeposit_Save
(
    @Id BIGINT = NULL, @OwnerId BIGINT, @PumpId BIGINT, @BankAccountId BIGINT,
    @ShiftId BIGINT = NULL, @DepositDate DATE, @Amount DECIMAL(18,2),
    @SlipNo NVARCHAR(50) = NULL, @DepositedBy NVARCHAR(150) = NULL,
    @Notes NVARCHAR(300) = NULL, @UserId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.BankAccounts WHERE Id = @BankAccountId AND OwnerId = @OwnerId)
        THROW 50133, 'Bank account not found or access denied.', 1;

    IF @Id IS NULL OR @Id = 0
    BEGIN
        INSERT INTO PUMP.BankDeposits
            (OwnerId, PumpId, BankAccountId, ShiftId, DepositDate, Amount, SlipNo, DepositedBy, Notes, CreatedBy)
        VALUES
            (@OwnerId, @PumpId, @BankAccountId, @ShiftId, @DepositDate, @Amount, @SlipNo, @DepositedBy, @Notes, @UserId);
        SET @Id = CAST(SCOPE_IDENTITY() AS BIGINT);
    END
    ELSE
    BEGIN
        UPDATE PUMP.BankDeposits
        SET BankAccountId = @BankAccountId, ShiftId = @ShiftId, DepositDate = @DepositDate,
            Amount = @Amount, SlipNo = @SlipNo, DepositedBy = @DepositedBy, Notes = @Notes
        WHERE Id = @Id AND OwnerId = @OwnerId AND IsDeleted = 0;
    END

    SELECT @Id AS Id;
END
GO

CREATE OR ALTER PROCEDURE PUMP.sp_BankDeposit_List
(
    @OwnerId BIGINT, @PumpId BIGINT,
    @FromDate DATE = NULL, @ToDate DATE = NULL,
    @PageNumber INT = 1, @PageSize INT = 50
)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Offset INT = (@PageNumber - 1) * @PageSize;

    SELECT d.Id, d.DepositDate, d.Amount, d.SlipNo, d.DepositedBy, d.Notes, d.ShiftId,
           b.BankName, b.AccountNo,
           TotalCount = COUNT(*) OVER()
    FROM PUMP.BankDeposits d
    JOIN PUMP.BankAccounts b ON b.Id = d.BankAccountId
    WHERE d.OwnerId = @OwnerId AND d.PumpId = @PumpId AND d.IsDeleted = 0
      AND (@FromDate IS NULL OR d.DepositDate >= @FromDate)
      AND (@ToDate   IS NULL OR d.DepositDate <= @ToDate)
    ORDER BY d.DepositDate DESC, d.Id DESC
    OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

/* Party ledger — ab ShiftId aur date dono le sakta hai (pehle back-dated entry
   possible hi nahi thi, aur cash reconciliation me receipt count hi nahi hota tha) */
CREATE OR ALTER PROCEDURE PUMP.sp_PartyLedger_Save
(
    @OwnerId        BIGINT,
    @PumpId         BIGINT,
    @PartyId        BIGINT,
    @EntryType      NVARCHAR(30),
    @Amount         DECIMAL(18,2),
    @ReferenceNo    NVARCHAR(50)  = NULL,
    @Notes          NVARCHAR(250) = NULL,
    @EntryDateTime  DATETIME2(7)  = NULL,
    @ShiftId        BIGINT        = NULL,
    @PaymentMode    NVARCHAR(30)  = 'CASH',
    @UserId         BIGINT        = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.Parties WHERE Id = @PartyId AND OwnerId = @OwnerId AND PumpId = @PumpId)
        THROW 50140, 'Party not found or access denied.', 1;

    DECLARE @Id BIGINT;

    BEGIN TRANSACTION;

        INSERT INTO PUMP.PartyLedger
            (OwnerId, PumpId, PartyId, EntryType, Amount, ReferenceNo, Notes, EntryDateTime, ShiftId, PaymentMode, CreatedBy)
        VALUES
            (@OwnerId, @PumpId, @PartyId, @EntryType, @Amount, @ReferenceNo, @Notes,
             ISNULL(@EntryDateTime, SYSDATETIME()), @ShiftId, @PaymentMode, @UserId);

        SET @Id = CAST(SCOPE_IDENTITY() AS BIGINT);

        UPDATE PUMP.Parties
        SET CurrentBalance = CASE
                                WHEN UPPER(@EntryType) IN ('SALE', 'DEBIT', 'CHARGE') THEN CurrentBalance + @Amount
                                ELSE CurrentBalance - @Amount
                             END,
            UpdatedOn  = SYSDATETIME(),
            ModifiedBy = @UserId
        WHERE Id = @PartyId AND OwnerId = @OwnerId AND PumpId = @PumpId;

    COMMIT TRANSACTION;

    SELECT @Id AS Id;
END
GO

/* Party ka balance recalculate — denormalized CurrentBalance drift ho jaye to
   isse theek ho jayega. Mahine me ek baar chalane layak. */
CREATE OR ALTER PROCEDURE PUMP.sp_Party_RecalculateBalance
(
    @OwnerId BIGINT,
    @PartyId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE p
    SET p.CurrentBalance = ISNULL(x.Bal, 0),
        p.UpdatedOn = SYSDATETIME()
    FROM PUMP.Parties p
    OUTER APPLY
    (
        SELECT Bal = SUM(CASE WHEN UPPER(l.EntryType) IN ('SALE','DEBIT','CHARGE') THEN l.Amount ELSE -l.Amount END)
        FROM PUMP.PartyLedger l
        WHERE l.PartyId = p.Id
    ) x
    WHERE p.OwnerId = @OwnerId
      AND (@PartyId IS NULL OR p.Id = @PartyId);

    SELECT UpdatedParties = @@ROWCOUNT;
END
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ==========================================================================================
   G8. DELETE — "delete button dabate hain par delete hota hi nahi" ka fix
   ------------------------------------------------------------------------------------------
   PROBLEM: Purane delete SPs HARD DELETE karte the aur pehle guard lagate the:

       IF EXISTS (SELECT 1 FROM PUMP.PartyLedger WHERE PartyId = @Id)
           THROW 50051, 'Cannot delete: Party has ledger entries. Clear the ledger first.', 1;

   Yaani jis party/product/tank ka ek bhi transaction ho gaya, uska delete hamesha
   fail. User ko lagta hai button kaam hi nahi karta. Aur "clear the ledger first"
   ka matlab hai purana hisaab mitao — jo accounting me kabhi nahi karna chahiye.

   SOLUTION — do-tarfa delete:
       * Record kahin use NAHI hua  -> sach me DELETE kar do (hard delete).
       * Record use ho chuka hai    -> HIDE kar do (IsDeleted = 1, IsActive = 0).
                                       History safe, list se gayab. User ke liye
                                       "delete ho gaya", accounting ke liye "record salamat".

   Har SP ek result set deta hai: Id, Mode ('DELETED' / 'DEACTIVATED'), Message.
   UI wahi message dikha de — user ko saaf pata chalega kya hua.

   NOTE: List wale SPs me `AND ISNULL(IsDeleted,0) = 0` filter neeche G9 me add kiya hai.
   ========================================================================================== */
PRINT '--- Section G8: soft-delete procedures ---';
GO

CREATE OR ALTER PROCEDURE PUMP.sp_Party_Delete
(
    @Id BIGINT, @OwnerId BIGINT, @UserId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.Parties WHERE Id = @Id AND OwnerId = @OwnerId AND ISNULL(IsDeleted,0) = 0)
        THROW 50050, 'Party not found, or you do not have access to it.', 1;

    DECLARE @InUse BIT = 0;
    IF EXISTS (SELECT 1 FROM PUMP.PartyLedger        WHERE PartyId = @Id) SET @InUse = 1;
    IF EXISTS (SELECT 1 FROM PUMP.SalesHeaders       WHERE PartyId = @Id) SET @InUse = 1;
    IF EXISTS (SELECT 1 FROM PUMP.FleetContracts     WHERE PartyId = @Id) SET @InUse = 1;
    IF EXISTS (SELECT 1 FROM PUMP.CouponBooks        WHERE IssuedToPartyId = @Id) SET @InUse = 1;
    IF EXISTS (SELECT 1 FROM PUMP.CouponTransactions WHERE PartyId = @Id) SET @InUse = 1;

    DECLARE @Balance DECIMAL(18,2) = (SELECT CurrentBalance FROM PUMP.Parties WHERE Id = @Id);

    /* Bakaya hai to hide bhi mat karo — warna outstanding report se paisa gayab ho jayega */
    IF ISNULL(@Balance, 0) <> 0
        THROW 50056, 'This party still has an outstanding balance. Settle it before deleting.', 1;

    IF @InUse = 1
    BEGIN
        UPDATE PUMP.Parties
        SET IsDeleted = 1, IsActive = 0, DeletedOn = SYSDATETIME(), DeletedBy = @UserId
        WHERE Id = @Id AND OwnerId = @OwnerId;

        EXEC PUMP.sp_Audit_Log @OwnerId=@OwnerId, @UserId=@UserId, @EntityName='Parties',
             @EntityId=@Id, @Action='SOFT_DELETE', @Reason='Transactions maujood hain';

        SELECT Id = @Id, Mode = 'DEACTIVATED',
               Message = 'Party removed. Its old bills and ledger entries are safe.';
    END
    ELSE
    BEGIN
        DELETE FROM PUMP.Parties WHERE Id = @Id AND OwnerId = @OwnerId;

        EXEC PUMP.sp_Audit_Log @OwnerId=@OwnerId, @UserId=@UserId, @EntityName='Parties',
             @EntityId=@Id, @Action='DELETE';

        SELECT Id = @Id, Mode = 'DELETED', Message = 'Party delete ho gayi.';
    END
END
GO


CREATE OR ALTER PROCEDURE PUMP.sp_Product_Delete
(
    @Id BIGINT, @OwnerId BIGINT, @UserId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.Products WHERE Id = @Id AND OwnerId = @OwnerId AND ISNULL(IsDeleted,0) = 0)
        THROW 50040, 'Product not found, or you do not have access to it.', 1;

    /* Active nozzle ya tank juda ho to pehle wo hatana hi padega — warna shift
       close par stock ka hisaab toot jayega. Ye guard sahi hai, isliye raha. */
    IF EXISTS (SELECT 1 FROM PUMP.Nozzles WHERE ProductId = @Id AND IsActive = 1 AND ISNULL(IsDeleted,0) = 0)
        THROW 50041, 'This product is still assigned to an active nozzle. Remove the nozzle first.', 1;

    IF EXISTS (SELECT 1 FROM PUMP.Tanks WHERE ProductId = @Id AND IsActive = 1 AND ISNULL(IsDeleted,0) = 0)
        THROW 50042, 'This product is still assigned to an active tank. Remove the tank first.', 1;

    DECLARE @InUse BIT = 0;
    IF EXISTS (SELECT 1 FROM PUMP.SalesDetails        WHERE ProductId = @Id) SET @InUse = 1;
    IF EXISTS (SELECT 1 FROM PUMP.PurchaseDetails     WHERE ProductId = @Id) SET @InUse = 1;
    IF EXISTS (SELECT 1 FROM PUMP.FleetContracts      WHERE ProductId = @Id) SET @InUse = 1;
    IF EXISTS (SELECT 1 FROM PUMP.ShiftNozzleReadings WHERE ProductId = @Id) SET @InUse = 1;
    IF EXISTS (SELECT 1 FROM PUMP.TestingLosses       WHERE ProductId = @Id) SET @InUse = 1;

    IF @InUse = 1
    BEGIN
        UPDATE PUMP.Products
        SET IsDeleted = 1, IsActive = 0, DeletedOn = SYSDATETIME(), DeletedBy = @UserId
        WHERE Id = @Id AND OwnerId = @OwnerId;

        EXEC PUMP.sp_Audit_Log @OwnerId=@OwnerId, @UserId=@UserId, @EntityName='Products',
             @EntityId=@Id, @Action='SOFT_DELETE', @Reason='Sale/purchase history maujood hai';

        SELECT Id = @Id, Mode = 'DEACTIVATED',
               Message = 'Product removed. Old sales and purchase reports are unchanged.';
    END
    ELSE
    BEGIN
        BEGIN TRANSACTION;
            DELETE FROM PUMP.ProductRateHistory WHERE ProductId = @Id;
            DELETE FROM PUMP.Products WHERE Id = @Id AND OwnerId = @OwnerId;
        COMMIT TRANSACTION;

        EXEC PUMP.sp_Audit_Log @OwnerId=@OwnerId, @UserId=@UserId, @EntityName='Products',
             @EntityId=@Id, @Action='DELETE';

        SELECT Id = @Id, Mode = 'DELETED', Message = 'Product deleted.';
    END
END
GO


CREATE OR ALTER PROCEDURE PUMP.sp_Nozzle_Delete
(
    @Id BIGINT, @OwnerId BIGINT, @UserId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.Nozzles WHERE Id = @Id AND OwnerId = @OwnerId AND ISNULL(IsDeleted,0) = 0)
        THROW 50060, 'Nozzle not found, or you do not have access to it.', 1;

    /* Khuli shift me laga hua nozzle nahi hata sakte */
    IF EXISTS (SELECT 1 FROM PUMP.ShiftNozzleReadings snr
               JOIN PUMP.ShiftHeaders sh ON sh.Id = snr.ShiftId
               WHERE snr.NozzleId = @Id AND sh.Status = 'OPEN')
        THROW 50061, 'This nozzle is part of an open shift. Close the shift first.', 1;

    IF EXISTS (SELECT 1 FROM PUMP.ShiftNozzleReadings WHERE NozzleId = @Id)
    BEGIN
        UPDATE PUMP.Nozzles
        SET IsDeleted = 1, IsActive = 0, DeletedOn = SYSDATETIME(), DeletedBy = @UserId
        WHERE Id = @Id AND OwnerId = @OwnerId;

        EXEC PUMP.sp_Audit_Log @OwnerId=@OwnerId, @UserId=@UserId, @EntityName='Nozzles',
             @EntityId=@Id, @Action='SOFT_DELETE';

        SELECT Id = @Id, Mode = 'DEACTIVATED',
               Message = 'Nozzle removed. Its old shift readings are safe.';
    END
    ELSE
    BEGIN
        DELETE FROM PUMP.Nozzles WHERE Id = @Id AND OwnerId = @OwnerId;
        EXEC PUMP.sp_Audit_Log @OwnerId=@OwnerId, @UserId=@UserId, @EntityName='Nozzles',
             @EntityId=@Id, @Action='DELETE';
        SELECT Id = @Id, Mode = 'DELETED', Message = 'Nozzle deleted.';
    END
END
GO

/* BLOCKER FIX (2026-09-03): Nozzles.TankId column tha (aur F5 backfill se purane
   rows auto-map bhi ho chuke hain), lekin sp_Nozzle_List ise return hi nahi karta
   tha aur sp_Nozzle_Save ise le hi nahi sakta tha — isliye UI se nozzle ka tank
   kabhi set/change nahi ho pata tha. NozzleDto/SaveNozzleRequest me TankId add
   karke (C# side) yahan wire kiya. */
CREATE OR ALTER PROCEDURE PUMP.sp_Nozzle_List
(
    @OwnerId BIGINT,
    @PumpId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        n.Id,
        n.OwnerId,
        n.PumpId,
        n.ProductId,
        p.Name AS ProductName,
        n.NozzleCode,
        n.TankId,
        n.IsActive
    FROM PUMP.Nozzles n
    INNER JOIN PUMP.Products p ON p.Id = n.ProductId
    WHERE n.OwnerId = @OwnerId
      AND (@PumpId IS NULL OR n.PumpId = @PumpId)
      AND n.IsActive = 1
    ORDER BY n.NozzleCode;
END
GO

CREATE OR ALTER PROCEDURE PUMP.sp_Nozzle_Save
(
    @Id BIGINT = NULL,
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @ProductId BIGINT,
    @NozzleCode NVARCHAR(30),
    @TankId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    -- Tank diya gaya ho to usi pump/product ka hona chahiye, warna galat tank se
    -- deduct hone laga to.
    IF @TankId IS NOT NULL AND NOT EXISTS
    (
        SELECT 1 FROM PUMP.Tanks
        WHERE Id = @TankId AND OwnerId = @OwnerId AND PumpId = @PumpId AND ProductId = @ProductId
    )
        THROW 50062, 'The selected tank does not belong to this pump/product.', 1;

    IF @Id IS NULL OR @Id = 0
    BEGIN
        INSERT INTO PUMP.Nozzles (OwnerId, PumpId, ProductId, NozzleCode, TankId)
        VALUES (@OwnerId, @PumpId, @ProductId, @NozzleCode, @TankId);
    END
    ELSE
    BEGIN
        UPDATE PUMP.Nozzles
        SET ProductId = @ProductId,
            NozzleCode = @NozzleCode,
            TankId = @TankId
        WHERE Id = @Id
          AND OwnerId = @OwnerId
          AND PumpId = @PumpId;
    END

    SELECT COALESCE(@Id, CAST(SCOPE_IDENTITY() AS BIGINT)) AS Id;
END
GO


CREATE OR ALTER PROCEDURE PUMP.sp_Tank_Delete
(
    @Id BIGINT, @OwnerId BIGINT, @UserId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.Tanks WHERE Id = @Id AND OwnerId = @OwnerId AND ISNULL(IsDeleted,0) = 0)
        THROW 50070, 'Tank not found, or you do not have access to it.', 1;

    IF EXISTS (SELECT 1 FROM PUMP.Nozzles WHERE TankId = @Id AND IsActive = 1 AND ISNULL(IsDeleted,0) = 0)
        THROW 50071, 'Nozzles are still attached to this tank. Move them to another tank first.', 1;

    DECLARE @Stock DECIMAL(18,2) = (SELECT CurrentStock FROM PUMP.Tanks WHERE Id = @Id);
    IF ISNULL(@Stock, 0) > 0
        THROW 50072, 'This tank still holds stock. Remove or adjust the stock first.', 1;

    DECLARE @InUse BIT = 0;
    IF EXISTS (SELECT 1 FROM PUMP.TankTransactions     WHERE TankId = @Id) SET @InUse = 1;
    IF EXISTS (SELECT 1 FROM PUMP.DipReadings          WHERE TankId = @Id) SET @InUse = 1;
    IF EXISTS (SELECT 1 FROM PUMP.TestingLosses        WHERE TankId = @Id) SET @InUse = 1;
    IF EXISTS (SELECT 1 FROM PUMP.StockReconciliations WHERE TankId = @Id) SET @InUse = 1;

    IF @InUse = 1
    BEGIN
        UPDATE PUMP.Tanks
        SET IsDeleted = 1, IsActive = 0, DeletedOn = SYSDATETIME(), DeletedBy = @UserId
        WHERE Id = @Id AND OwnerId = @OwnerId;

        EXEC PUMP.sp_Audit_Log @OwnerId=@OwnerId, @UserId=@UserId, @EntityName='Tanks',
             @EntityId=@Id, @Action='SOFT_DELETE';

        SELECT Id = @Id, Mode = 'DEACTIVATED',
               Message = 'Tank removed. Its old stock ledger is safe.';
    END
    ELSE
    BEGIN
        DELETE FROM PUMP.Tanks WHERE Id = @Id AND OwnerId = @OwnerId;
        EXEC PUMP.sp_Audit_Log @OwnerId=@OwnerId, @UserId=@UserId, @EntityName='Tanks',
             @EntityId=@Id, @Action='DELETE';
        SELECT Id = @Id, Mode = 'DELETED', Message = 'Tank deleted.';
    END
END
GO


CREATE OR ALTER PROCEDURE PUMP.sp_Vendor_Delete
(
    @Id BIGINT, @OwnerId BIGINT, @UserId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.Vendors WHERE Id = @Id AND OwnerId = @OwnerId AND ISNULL(IsDeleted,0) = 0)
        THROW 50080, 'Vendor not found, or you do not have access to it.', 1;

    IF EXISTS (SELECT 1 FROM PUMP.PurchaseHeaders WHERE VendorId = @Id)
    BEGIN
        UPDATE PUMP.Vendors
        SET IsDeleted = 1, IsActive = 0, DeletedOn = SYSDATETIME(), DeletedBy = @UserId
        WHERE Id = @Id AND OwnerId = @OwnerId;

        EXEC PUMP.sp_Audit_Log @OwnerId=@OwnerId, @UserId=@UserId, @EntityName='Vendors',
             @EntityId=@Id, @Action='SOFT_DELETE';

        SELECT Id = @Id, Mode = 'DEACTIVATED',
               Message = 'Vendor removed. Its old purchase entries are safe.';
    END
    ELSE
    BEGIN
        DELETE FROM PUMP.Vendors WHERE Id = @Id AND OwnerId = @OwnerId;
        SELECT Id = @Id, Mode = 'DELETED', Message = 'Vendor deleted.';
    END
END
GO


CREATE OR ALTER PROCEDURE PUMP.sp_Employee_Delete
(
    @Id BIGINT, @OwnerId BIGINT, @UserId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.Employees WHERE Id = @Id AND OwnerId = @OwnerId AND ISNULL(IsDeleted,0) = 0)
        THROW 50090, 'Employee not found, or you do not have access to it.', 1;

    IF EXISTS (SELECT 1 FROM PUMP.SalaryPayments WHERE EmployeeId = @Id)
    BEGIN
        UPDATE PUMP.Employees
        SET IsDeleted = 1, IsActive = 0, DeletedOn = SYSDATETIME(), DeletedBy = @UserId
        WHERE Id = @Id AND OwnerId = @OwnerId;

        SELECT Id = @Id, Mode = 'DEACTIVATED',
               Message = 'Employee removed. Their salary history is safe.';
    END
    ELSE
    BEGIN
        DELETE FROM PUMP.Employees WHERE Id = @Id AND OwnerId = @OwnerId;
        SELECT Id = @Id, Mode = 'DELETED', Message = 'Employee deleted.';
    END
END
GO


CREATE OR ALTER PROCEDURE PUMP.sp_ExpenseHead_Delete
(
    @Id BIGINT, @OwnerId BIGINT, @UserId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.ExpenseHeads WHERE Id = @Id AND OwnerId = @OwnerId AND ISNULL(IsDeleted,0) = 0)
        THROW 50095, 'Expense head not found, or you do not have access to it.', 1;

    IF EXISTS (SELECT 1 FROM PUMP.ExpenseTransactions WHERE ExpenseHeadId = @Id)
    BEGIN
        UPDATE PUMP.ExpenseHeads
        SET IsDeleted = 1, IsActive = 0, DeletedOn = SYSDATETIME(), DeletedBy = @UserId
        WHERE Id = @Id AND OwnerId = @OwnerId;

        SELECT Id = @Id, Mode = 'DEACTIVATED',
               Message = 'Expense head removed. Old expenses are unchanged.';
    END
    ELSE
    BEGIN
        DELETE FROM PUMP.ExpenseHeads WHERE Id = @Id AND OwnerId = @OwnerId;
        SELECT Id = @Id, Mode = 'DELETED', Message = 'Expense head deleted.';
    END
END
GO


CREATE OR ALTER PROCEDURE PUMP.sp_User_Delete
(
    @Id BIGINT, @OwnerId BIGINT, @UserId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.Users WHERE Id = @Id AND OwnerId = @OwnerId AND ISNULL(IsDeleted,0) = 0)
        THROW 50096, 'User not found, or you do not have access to it.', 1;

    IF @Id = @UserId
        THROW 50097, 'You cannot delete your own account.', 1;

    /* Owner ka aakhri admin delete na ho jaye */
    IF EXISTS (SELECT 1 FROM PUMP.Users WHERE Id = @Id AND IsOwner = 1)
       AND (SELECT COUNT(*) FROM PUMP.Users
            WHERE OwnerId = @OwnerId AND IsOwner = 1 AND IsActive = 1 AND ISNULL(IsDeleted,0) = 0) <= 1
        THROW 50098, 'This is the last admin user for this owner - it cannot be deleted.', 1;

    /* User ka naam har transaction ke saath juda hai, isliye hamesha soft delete.
       Username free kar dete hain taaki dobara use ho sake. */
    BEGIN TRANSACTION;

        UPDATE PUMP.Users
        SET IsDeleted = 1,
            IsActive  = 0,
            Username  = LEFT(Username + '_del_' + CAST(@Id AS NVARCHAR(20)), 100),
            DeletedOn = SYSDATETIME(),
            DeletedBy = @UserId
        WHERE Id = @Id AND OwnerId = @OwnerId;

        -- saare refresh token revoke kar do, warna deleted user ka session chalta rahega
        UPDATE PUMP.UserRefreshTokens
        SET RevokedOnUtc = SYSUTCDATETIME(), RevokeReason = 'UserDeleted'
        WHERE UserId = @Id AND RevokedOnUtc IS NULL;

    COMMIT TRANSACTION;

    EXEC PUMP.sp_Audit_Log @OwnerId=@OwnerId, @UserId=@UserId, @EntityName='Users',
         @EntityId=@Id, @Action='SOFT_DELETE';

    SELECT Id = @Id, Mode = 'DEACTIVATED',
           Message = 'User removed and all of their sessions were signed out.';
END
GO


CREATE OR ALTER PROCEDURE PUMP.sp_Pump_Delete
(
    @Id BIGINT, @OwnerId BIGINT, @UserId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.Pumps WHERE Id = @Id AND OwnerId = @OwnerId AND ISNULL(IsDeleted,0) = 0)
        THROW 50099, 'Pump not found, or you do not have access to it.', 1;

    IF EXISTS (SELECT 1 FROM PUMP.ShiftHeaders WHERE PumpId = @Id AND Status = 'OPEN')
        THROW 50101, 'This pump has an open shift. Close it first.', 1;

    /* Pump ke neeche sab kuch hota hai — hamesha soft delete */
    UPDATE PUMP.Pumps
    SET IsDeleted = 1, IsActive = 0, DeletedOn = SYSDATETIME(), DeletedBy = @UserId
    WHERE Id = @Id AND OwnerId = @OwnerId;

    EXEC PUMP.sp_Audit_Log @OwnerId=@OwnerId, @UserId=@UserId, @EntityName='Pumps',
         @EntityId=@Id, @Action='SOFT_DELETE';

    SELECT Id = @Id, Mode = 'DEACTIVATED',
           Message = 'Pump removed. Its full record is safe.';
END
GO


/* Galti se delete ho gaya? Wapas le aao. */
CREATE OR ALTER PROCEDURE PUMP.sp_Master_Restore
(
    @EntityName NVARCHAR(50),   -- Parties / Products / Nozzles / Tanks / Vendors / Employees / ExpenseHeads / Pumps / Users
    @Id         BIGINT,
    @OwnerId    BIGINT,
    @UserId     BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @EntityName NOT IN ('Parties','Products','Nozzles','Tanks','Vendors','Employees','ExpenseHeads','Pumps','Users')
        THROW 50102, 'Restore is not supported for this table.', 1;

    DECLARE @sql NVARCHAR(MAX) =
        N'UPDATE PUMP.' + QUOTENAME(@EntityName) + N'
          SET IsDeleted = 0, IsActive = 1, DeletedOn = NULL, DeletedBy = NULL,
              ModifiedBy = @UserId, ModifiedOn = SYSDATETIME()
          WHERE Id = @Id AND OwnerId = @OwnerId AND IsDeleted = 1;';

    EXEC sys.sp_executesql @sql,
         N'@Id BIGINT, @OwnerId BIGINT, @UserId BIGINT',
         @Id = @Id, @OwnerId = @OwnerId, @UserId = @UserId;

    EXEC PUMP.sp_Audit_Log @OwnerId=@OwnerId, @UserId=@UserId,
         @EntityName=@EntityName, @EntityId=@Id, @Action='RESTORE';

    SELECT Id = @Id, Mode = 'RESTORED', Message = 'Record restored.';
END
GO


/* ==========================================================================================
   G9. LIST SPs — soft-deleted rows chhupao
   ------------------------------------------------------------------------------------------
   IsDeleted column add karne se list apne aap filter nahi hoti. Purane list SPs me
   `AND ISNULL(x.IsDeleted, 0) = 0` add karna zaroori hai, warna delete kiya hua record
   list me dikhta rahega.

   Neeche ye kaam automatically hota hai: har PUMP.sp_*_List ka definition padhkar,
   jahan filter nahi hai wahan report kar dete hain. (Automatic text-replace jaanbujh
   ke nahi kiya — SP ka SQL badalna hamesha review maangta hai.)
   ========================================================================================== */
PRINT '';
PRINT '--- Section G9: list SPs jinme IsDeleted filter lagana baaki hai ---';
GO

SELECT
    ProcedureName = 'PUMP.' + p.name,
    Note          = 'IsDeleted filter missing — WHERE me AND ISNULL(IsDeleted,0)=0 add karein'
FROM sys.procedures p
JOIN sys.sql_modules m ON m.object_id = p.object_id
WHERE SCHEMA_NAME(p.schema_id) = 'PUMP'
  AND p.name LIKE 'sp_%_List'
  AND m.definition NOT LIKE '%IsDeleted%'
  AND EXISTS
  (
      -- sirf un SPs ke liye jo soft-delete wale master table ko chhoote hain
      SELECT 1 FROM (VALUES
          ('Products'),('Nozzles'),('Tanks'),('Parties'),('Vendors'),
          ('Employees'),('ExpenseHeads'),('Pumps'),('Users')
      ) AS t(TableName)
      WHERE m.definition LIKE '%PUMP.' + t.TableName + '%'
  )
ORDER BY p.name;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ==========================================================================================
   SECTION I — TENANT OWNERSHIP GUARD
   ------------------------------------------------------------------------------------------
   Kuch API endpoints sirf ek id lete hain aur OwnerId lete hi nahi:

       GET  /api/shifts/{id}/summary
       GET  /api/shifts/{id}/nozzle-readings
       POST /api/sales/{id}/receipt
       GET  /api/products/{id}/rate-history
       GET  /api/roles/{id}/menus
       GET  /api/pumps/{pumpId}/last-nozzle-readings
       GET  /api/reports/daily-stock-register?pumpId=...

   Yaani koi bhi logged-in user id badal kar doosre owner ki shift ka cash summary,
   uska bill, ya poore mahine ki stock report nikal sakta tha.

   API ab har aisi request se pehle ye procedure poochti hai: "kya ye record sach me
   is owner ka hai?" Nahi to 404 milta hai — 403 nahi, kyunki 403 ye bata deta hai ki
   record exist to karta hai, jo khud ek information leak hai.

   Iske alawa upar wali 4 report SPs me @OwnerId parameter add kiya gaya hai
   (sp_Shift_NozzleReadings, sp_ProductRateHistory_List, sp_RoleMenu_GetByRole,
   sp_Report_DailyStockRegister) — defence in depth. Wo parameter optional hai
   taaki purane callers na tootein.
   ========================================================================================== */
PRINT '--- Section I: tenant ownership guard ---';
GO

CREATE OR ALTER PROCEDURE PUMP.sp_Tenant_Owns
(
    @OwnerId    BIGINT,
    @EntityName NVARCHAR(30),
    @EntityId   BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISNULL(@OwnerId, 0) <= 0 OR ISNULL(@EntityId, 0) <= 0
    BEGIN
        SELECT CAST(0 AS INT);
        RETURN;
    END

    DECLARE @Owns INT = 0;

    IF @EntityName = 'Shift'
        SELECT @Owns = CASE WHEN EXISTS (SELECT 1 FROM PUMP.ShiftHeaders    WHERE Id = @EntityId AND OwnerId = @OwnerId) THEN 1 ELSE 0 END;
    ELSE IF @EntityName = 'Sale'
        SELECT @Owns = CASE WHEN EXISTS (SELECT 1 FROM PUMP.SalesHeaders    WHERE Id = @EntityId AND OwnerId = @OwnerId) THEN 1 ELSE 0 END;
    ELSE IF @EntityName = 'Product'
        SELECT @Owns = CASE WHEN EXISTS (SELECT 1 FROM PUMP.Products        WHERE Id = @EntityId AND OwnerId = @OwnerId) THEN 1 ELSE 0 END;
    ELSE IF @EntityName = 'Pump'
        SELECT @Owns = CASE WHEN EXISTS (SELECT 1 FROM PUMP.Pumps           WHERE Id = @EntityId AND OwnerId = @OwnerId) THEN 1 ELSE 0 END;
    ELSE IF @EntityName = 'Role'
        SELECT @Owns = CASE WHEN EXISTS (SELECT 1 FROM PUMP.Roles           WHERE Id = @EntityId AND OwnerId = @OwnerId) THEN 1 ELSE 0 END;
    ELSE IF @EntityName = 'Party'
        SELECT @Owns = CASE WHEN EXISTS (SELECT 1 FROM PUMP.Parties         WHERE Id = @EntityId AND OwnerId = @OwnerId) THEN 1 ELSE 0 END;
    ELSE IF @EntityName = 'Tank'
        SELECT @Owns = CASE WHEN EXISTS (SELECT 1 FROM PUMP.Tanks           WHERE Id = @EntityId AND OwnerId = @OwnerId) THEN 1 ELSE 0 END;
    ELSE IF @EntityName = 'Nozzle'
        SELECT @Owns = CASE WHEN EXISTS (SELECT 1 FROM PUMP.Nozzles         WHERE Id = @EntityId AND OwnerId = @OwnerId) THEN 1 ELSE 0 END;
    ELSE IF @EntityName = 'Purchase'
        SELECT @Owns = CASE WHEN EXISTS (SELECT 1 FROM PUMP.PurchaseHeaders WHERE Id = @EntityId AND OwnerId = @OwnerId) THEN 1 ELSE 0 END;
    ELSE IF @EntityName = 'Vendor'
        SELECT @Owns = CASE WHEN EXISTS (SELECT 1 FROM PUMP.Vendors         WHERE Id = @EntityId AND OwnerId = @OwnerId) THEN 1 ELSE 0 END;
    ELSE IF @EntityName = 'Employee'
        SELECT @Owns = CASE WHEN EXISTS (SELECT 1 FROM PUMP.Employees       WHERE Id = @EntityId AND OwnerId = @OwnerId) THEN 1 ELSE 0 END;

    SELECT @Owns;
END
GO

PRINT '  + PUMP.sp_Tenant_Owns ready';
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ==========================================================================================
   SECTION G10 — 4 TOOTE HUE PAGE (2026-09-03)
   ------------------------------------------------------------------------------------------
   Ye chaar SP aise the ki unke upar bane poore page hi kaam nahi karte the. Har baar
   API 500 deta tha, aur client chupchaap "No data found" dikha deta tha — isliye ye
   kabhi pakde nahi gaye. Local par app chala kar har endpoint hit karne se mile.

     1. sp_User_List          -> User Management page (users list HI nahi dikhti thi)
     2. sp_Menu_GetAll        -> /api/menus 500 (role permission screen ka master list)
     3. sp_CashTxn_List       -> Cashbook page ("too many arguments")
     4. sp_StockReconcile_List-> Stock Reconcile page ("too many arguments")
   ========================================================================================== */

/* ---- G10.1 sp_User_List ----
   Bug: UserDto 9 field maangta hai par SP sirf 8 deta tha — `IsSuperAdmin` column
   missing tha. Dapper ko har constructor param ke liye column chahiye, isliye poori
   list materialize hi nahi hoti thi aur User Management page par HAMESHA "No users
   found" dikhta tha (jabki DB me 6 user the). Saath me role-less user (superadmin)
   ke liye RoleName ab khaali ke bajaye samajh aane wala text dikhata hai, aur
   soft-deleted users list se hat gaye. */
CREATE OR ALTER PROCEDURE PUMP.sp_User_List
(
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        u.Id,
        u.OwnerId,
        u.FullName,
        u.Username,
        u.Mobile,
        u.IsActive,
        r.Id AS RoleId,                 -- NULL ho sakta hai; UserDto me long? hai
        ISNULL(r.Name, CASE WHEN u.IsSuperAdmin = 1 THEN N'SuperAdmin' ELSE N'(No role)' END) AS RoleName,
        u.IsSuperAdmin                  -- <== ye missing tha
    FROM PUMP.Users u
    LEFT JOIN PUMP.UserRoles ur ON ur.UserId = u.Id
    LEFT JOIN PUMP.Roles     r  ON r.Id = ur.RoleId
    WHERE u.IsActive = 1
      AND ISNULL(u.IsDeleted, 0) = 0
      AND u.OwnerId = @OwnerId
    ORDER BY u.Id DESC;
END
GO

/* ---- G10.2 sp_Menu_GetAll ----
   Bug: MenuItemDto 10 field maangta hai (CanView/CanCreate/CanEdit/CanDelete samet)
   par SP sirf 6 deta tha. Ye "saare menu" ka master list hai (kisi ek role ka nahi),
   isliye permission flags 1 bhej rahe hain — role-wise actual permission
   sp_Menu_GetByRole se aati hai. */
CREATE OR ALTER PROCEDURE PUMP.sp_Menu_GetAll
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        Id,
        ParentId,
        MenuName,
        Route,
        Icon,
        Sequence,
        CanView   = CAST(1 AS BIT),
        CanCreate = CAST(1 AS BIT),
        CanEdit   = CAST(1 AS BIT),
        CanDelete = CAST(1 AS BIT)
    FROM PUMP.Menus
    WHERE IsActive = 1
    ORDER BY Sequence, MenuName;
END
GO

/* ---- G10.3 sp_CashTxn_List ----
   Bug: C# repo paging ke liye @FromDate/@ToDate/@SearchTerm/@PageNumber/@PageSize
   bhejta hai aur do result set (rows + total count) padhta hai, par SP purana
   non-paged wala tha jo sirf @OwnerId/@PumpId leta tha -> "too many arguments".
   Cashbook page isi wajah se hamesha khaali dikhta tha. */
CREATE OR ALTER PROCEDURE PUMP.sp_CashTxn_List
(
    @OwnerId    BIGINT,
    @PumpId     BIGINT,
    @FromDate   DATETIME2 = NULL,
    @ToDate     DATETIME2 = NULL,
    @SearchTerm NVARCHAR(100) = NULL,
    @PageNumber INT = 1,
    @PageSize   INT = 50
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize   IS NULL OR @PageSize   < 1 SET @PageSize   = 50;

    ;WITH filtered AS
    (
        SELECT ct.*
        FROM PUMP.CashTransactions ct
        WHERE ct.OwnerId = @OwnerId
          AND ct.PumpId  = @PumpId
          AND (@FromDate   IS NULL OR ct.TxnDateTime >= @FromDate)
          AND (@ToDate     IS NULL OR ct.TxnDateTime <  DATEADD(DAY, 1, CAST(@ToDate AS DATE)))
          AND (@SearchTerm IS NULL OR @SearchTerm = ''
               OR ct.ReferenceNo LIKE '%' + @SearchTerm + '%'
               OR ct.Narration   LIKE '%' + @SearchTerm + '%'
               OR ct.TxnType     LIKE '%' + @SearchTerm + '%')
    )
    SELECT
        Id, OwnerId, PumpId, ShiftId, TxnType, Amount, ReferenceNo, Narration, TxnDateTime
    FROM filtered
    ORDER BY TxnDateTime DESC, Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(*)
    FROM PUMP.CashTransactions ct
    WHERE ct.OwnerId = @OwnerId
      AND ct.PumpId  = @PumpId
      AND (@FromDate   IS NULL OR ct.TxnDateTime >= @FromDate)
      AND (@ToDate     IS NULL OR ct.TxnDateTime <  DATEADD(DAY, 1, CAST(@ToDate AS DATE)))
      AND (@SearchTerm IS NULL OR @SearchTerm = ''
           OR ct.ReferenceNo LIKE '%' + @SearchTerm + '%'
           OR ct.Narration   LIKE '%' + @SearchTerm + '%'
           OR ct.TxnType     LIKE '%' + @SearchTerm + '%');
END
GO

/* ---- G10.4 sp_StockReconcile_List ----
   Bug: sp_CashTxn_List jaisa hi — C# @FromDate/@ToDate/@PageNumber/@PageSize bhejta
   hai aur 2 result set maangta hai, SP purana non-paged tha. Stock Reconcile page ka
   "Dip Testing History" isliye hamesha khaali rehta tha. */
CREATE OR ALTER PROCEDURE PUMP.sp_StockReconcile_List
(
    @OwnerId    BIGINT,
    @PumpId     BIGINT,
    @TankId     BIGINT = NULL,
    @FromDate   DATETIME2 = NULL,
    @ToDate     DATETIME2 = NULL,
    @PageNumber INT = 1,
    @PageSize   INT = 50
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize   IS NULL OR @PageSize   < 1 SET @PageSize   = 50;

    SELECT
        sr.Id,
        sr.OwnerId,
        sr.PumpId,
        sr.TankId,
        t.Name AS TankName,
        sr.ReconciliationDate,
        sr.BookStock,
        sr.PhysicalStock,
        sr.VarianceQty,
        sr.VarianceAmount,
        sr.Reason,
        sr.CreatedOn
    FROM PUMP.StockReconciliations sr
    INNER JOIN PUMP.Tanks t ON t.Id = sr.TankId
    WHERE sr.OwnerId = @OwnerId
      AND sr.PumpId  = @PumpId
      AND (@TankId   IS NULL OR sr.TankId = @TankId)
      AND (@FromDate IS NULL OR sr.ReconciliationDate >= CAST(@FromDate AS DATE))
      AND (@ToDate   IS NULL OR sr.ReconciliationDate <= CAST(@ToDate   AS DATE))
    ORDER BY sr.ReconciliationDate DESC, sr.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(*)
    FROM PUMP.StockReconciliations sr
    WHERE sr.OwnerId = @OwnerId
      AND sr.PumpId  = @PumpId
      AND (@TankId   IS NULL OR sr.TankId = @TankId)
      AND (@FromDate IS NULL OR sr.ReconciliationDate >= CAST(@FromDate AS DATE))
      AND (@ToDate   IS NULL OR sr.ReconciliationDate <= CAST(@ToDate   AS DATE));
END
GO

PRINT '  + G10: sp_User_List / sp_Menu_GetAll / sp_CashTxn_List / sp_StockReconcile_List theek kiye';
GO

/* ---- G10.5 sp_Report_PumpComparison ----
   Bug: report sirf PUMP.SalesHeaders (receipt-wise sale) jodta tha. Petrol pump par
   zyadatar bikri cash me hoti hai jo receipt se nahi, shift ke METER se record hoti
   hai — wo is report me kabhi aati hi nahi thi. Jis pump par sirf meter se kaam hota
   hai uska sale hamesha 0 dikhta tha.

   Ab: band ho chuki shift ka meter total + sirf wo receipt jo kisi band shift ki nahi
   hai (warna dono jagah gine jaate aur total double ho jaata — Dashboard par yahi
   galti thi). */
CREATE OR ALTER PROCEDURE PUMP.sp_Report_PumpComparison
(
    @OwnerId  BIGINT,
    @DateFrom DATE,
    @DateTo   DATE
)
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH ClosedShifts AS
    (
        SELECT sh.Id, sh.PumpId
        FROM PUMP.ShiftHeaders sh
        WHERE sh.OwnerId = @OwnerId
          AND sh.Status = 'CLOSED'
          AND CAST(sh.ShiftDate AS DATE) BETWEEN @DateFrom AND @DateTo
    ),
    MeterCTE AS
    (
        SELECT cs.PumpId, SUM(snr.SoldAmount) AS MeterAmount
        FROM ClosedShifts cs
        JOIN PUMP.ShiftNozzleReadings snr ON snr.ShiftId = cs.Id
        GROUP BY cs.PumpId
    ),
    ReceiptCTE AS
    (
        SELECT sh.PumpId, SUM(sh.TotalAmount) AS ReceiptAmount
        FROM PUMP.SalesHeaders sh
        WHERE sh.OwnerId = @OwnerId
          AND CAST(sh.BillDateTime AS DATE) BETWEEN @DateFrom AND @DateTo
          AND NOT EXISTS (SELECT 1 FROM ClosedShifts cs WHERE cs.Id = sh.ShiftId)
          AND sh.IsVoid = 0
        GROUP BY sh.PumpId
    ),
    PurchaseCTE AS
    (
        SELECT ph.PumpId, SUM(ph.TotalAmount) AS PurchaseAmount
        FROM PUMP.PurchaseHeaders ph
        WHERE ph.OwnerId = @OwnerId
          AND CAST(ph.CreatedOn AS DATE) BETWEEN @DateFrom AND @DateTo
        GROUP BY ph.PumpId
    ),
    ExpenseCTE AS
    (
        SELECT e.PumpId, SUM(e.Amount) AS ExpenseAmount
        FROM PUMP.ExpenseTransactions e
        WHERE e.OwnerId = @OwnerId
          AND CAST(e.TxnDateTime AS DATE) BETWEEN @DateFrom AND @DateTo
        GROUP BY e.PumpId
    )
    SELECT
        p.Id   AS PumpId,
        p.Name AS PumpName,
        p.City,
        SalesAmount    = ISNULL(m.MeterAmount, 0) + ISNULL(r.ReceiptAmount, 0),
        PurchaseAmount = ISNULL(pr.PurchaseAmount, 0),
        ExpenseAmount  = ISNULL(e.ExpenseAmount, 0),
        NetAmount      = ISNULL(m.MeterAmount, 0) + ISNULL(r.ReceiptAmount, 0)
                       - ISNULL(pr.PurchaseAmount, 0) - ISNULL(e.ExpenseAmount, 0)
    FROM PUMP.Pumps p
    LEFT JOIN MeterCTE    m  ON m.PumpId  = p.Id
    LEFT JOIN ReceiptCTE  r  ON r.PumpId  = p.Id
    LEFT JOIN PurchaseCTE pr ON pr.PumpId = p.Id
    LEFT JOIN ExpenseCTE  e  ON e.PumpId  = p.Id
    WHERE p.OwnerId = @OwnerId
      AND p.IsActive = 1
      AND ISNULL(p.IsDeleted, 0) = 0
    ORDER BY NetAmount DESC, p.Name;
END
GO

PRINT '  + G10.5: sp_Report_PumpComparison ab meter sale bhi ginta hai (double count ke bina)';
GO

/* ==========================================================================================
   SECTION G11 — PURANI TAREEKH KI ENTRY (back-date) — 2026-09-03
   ------------------------------------------------------------------------------------------
   Asli zaroorat: pump wale kai baar 5-10 din entry karna bhool jaate hain, phir ek saath
   poora hisaab charhaate hain. Jin SP me tareekh ka parameter hi nahi tha wahan entry
   hamesha "abhi" ki lag jaati thi — purana din kabhi sahi nahi ho paata tha.

   Ab in dono me optional @TxnDateTime hai. NULL bhejein to pehle jaisa hi (abhi ka waqt).
   ========================================================================================== */

CREATE OR ALTER PROCEDURE PUMP.sp_TankTxn_Save
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @TankId BIGINT,
    @TxnType NVARCHAR(30),
    @Quantity DECIMAL(18,2),
    @ReferenceNo NVARCHAR(50) = NULL,
    @Notes NVARCHAR(250) = NULL,
    @TxnDateTime DATETIME2 = NULL      -- purani tareekh ki entry ke liye
)
AS
BEGIN
    SET NOCOUNT ON;
    -- INSERT fail ho to UPDATE bhi na chale — warna stock badal jaata tha bina
    -- kisi matching TankTransactions row ke.
    SET XACT_ABORT ON;

    BEGIN TRANSACTION;

        INSERT INTO PUMP.TankTransactions (OwnerId, PumpId, TankId, TxnType, Quantity, ReferenceNo, Notes, TxnDateTime)
        VALUES (@OwnerId, @PumpId, @TankId, @TxnType, @Quantity, @ReferenceNo, @Notes,
                ISNULL(@TxnDateTime, SYSDATETIME()));

        UPDATE PUMP.Tanks
        SET CurrentStock = CASE
            WHEN UPPER(@TxnType) IN ('IN', 'RECEIPT', 'PURCHASE', 'OPENING') THEN CurrentStock + @Quantity
            ELSE CurrentStock - @Quantity
        END,
            UpdatedOn = SYSDATETIME()
        WHERE Id = @TankId
          AND OwnerId = @OwnerId
          AND PumpId = @PumpId;

    COMMIT TRANSACTION;

    SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS Id;
END
GO

CREATE OR ALTER PROCEDURE PUMP.sp_CouponTxn_Save
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @CouponBookId BIGINT,
    @PartyId BIGINT = NULL,
    @SalesHeaderId BIGINT = NULL,
    @CouponSerialNo INT,
    @Amount DECIMAL(18,2),
    @Notes NVARCHAR(250) = NULL,
    @TxnDateTime DATETIME2 = NULL      -- purani tareekh ki entry ke liye
)
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO PUMP.CouponTransactions
        (OwnerId, PumpId, CouponBookId, PartyId, SalesHeaderId, CouponSerialNo, Amount, Notes, TxnDateTime)
    VALUES
        (@OwnerId, @PumpId, @CouponBookId, @PartyId, @SalesHeaderId, @CouponSerialNo, @Amount, @Notes,
         ISNULL(@TxnDateTime, SYSDATETIME()));

    SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS Id;
END
GO

PRINT '  + G11: sp_TankTxn_Save / sp_CouponTxn_Save me purani tareekh ki entry ka option';
GO

/* ==========================================================================================
   SECTION G12 — PURCHASE KI ENTRY TANK LEDGER ME BHI JAYE (2026-09-03)
   ------------------------------------------------------------------------------------------
   BUG: sp_Purchase_SaveDetail seedha Tanks.CurrentStock badha deta tha par
   PUMP.TankTransactions me koi row nahi banata tha. Nateeja:

     * Tank Stock page ke "Recent Transactions" me purchase kabhi dikhta hi nahi tha —
       stock achanak badh jaata tha aur user ko samajh nahi aata tha kahan se aaya.
     * Ledger ka jod (SUM of TankTransactions) kabhi CurrentStock se match nahi karta tha,
       isliye stock ka audit ho hi nahi sakta tha.

   Ye galti se chhoot gaya tha, jaanbujh kar nahi: sp_Purchase_Delete aur
   sp_Purchase_PrepareUpdate DONO pehle se 'PURCHASE-<id>' waali TankTransactions rows
   ko delete karte hain — matlab wo rows banni hi chahiye thi.

   Ab har purchase line ke saath ek TankTransaction bhi banti hai, invoice ki tareekh par
   (taaki purani tareekh ki purchase sahi din par dikhe).
   ========================================================================================== */
CREATE OR ALTER PROCEDURE [PUMP].[sp_Purchase_SaveDetail]
(
    @PurchaseHeaderId BIGINT,
    @ProductId BIGINT,
    @TankId BIGINT = NULL,
    @Quantity DECIMAL(18,3),
    @Rate DECIMAL(18,4),
    @Amount DECIMAL(18,2)
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @OwnerId BIGINT, @PumpId BIGINT, @InvoiceDate DATE;
    SELECT @OwnerId = OwnerId, @PumpId = PumpId, @InvoiceDate = InvoiceDate
    FROM PUMP.PurchaseHeaders
    WHERE Id = @PurchaseHeaderId;

    BEGIN TRANSACTION;

        INSERT INTO PUMP.PurchaseDetails (PurchaseHeaderId, ProductId, TankId, Quantity, Rate, Amount)
        VALUES (@PurchaseHeaderId, @ProductId, @TankId, @Quantity, @Rate, @Amount);

        IF @TankId IS NOT NULL AND @TankId > 0
        BEGIN
            -- Tank ka stock badhao (sirf usi owner/pump ka tank ho)
            UPDATE PUMP.Tanks
            SET CurrentStock = CurrentStock + @Quantity,
                UpdatedOn    = SYSDATETIME()
            WHERE Id = @TankId
              AND (@OwnerId IS NULL OR OwnerId = @OwnerId);

            -- Ledger me bhi likho, warna stock ka hisaab kabhi milta hi nahi.
            -- ReferenceNo wahi format jo Delete/PrepareUpdate dhoondhte hain.
            IF @OwnerId IS NOT NULL AND @PumpId IS NOT NULL
            BEGIN
                INSERT INTO PUMP.TankTransactions
                    (OwnerId, PumpId, TankId, TxnType, Quantity, ReferenceNo, Notes, TxnDateTime)
                VALUES
                    (@OwnerId, @PumpId, @TankId, 'PURCHASE', @Quantity,
                     CONCAT('PURCHASE-', CAST(@PurchaseHeaderId AS NVARCHAR(20))),
                     'Auto entry from purchase',
                     ISNULL(CAST(@InvoiceDate AS DATETIME2), SYSDATETIME()));
            END
        END

    COMMIT TRANSACTION;
END
GO

PRINT '  + G12: purchase ab TankTransactions me bhi likhta hai (stock ka hisaab milta hai)';
GO

/* ==========================================================================================
   SECTION G13 — STOCK VARIANCE KA POORA HISAAB (2026-09-04)
   ------------------------------------------------------------------------------------------
   Teen alag-alag kharabiyan thi, teeno ka taalluk stock ke nuksaan se hai:

   1. Reconciliation Tanks.CurrentStock badal deta tha lekin TankTransactions me koi row
      nahi likhta tha. DSR mahine ka opening stock CurrentStock se ulta-hisaab karke
      nikalta hai, isliye har reconciliation poore mahine ka opening chupchaap badal
      deti thi — register jhooth bolne lagta tha ki mahina kitne stock se shuru hua.
      (Test: 45 L ka nuksaan daalte hi 1-Sep ka opening 5,795 se 5,750 ho gaya.)
      DSR ki Receipt query me pehle se 'RECON-%' ko chhodne wala filter tha — yaani
      ye row banni to hamesha se chahiye thi, bas banti nahi thi.

   2. Nuksaan ke paise kahin calculate hi nahi hote the. Pump wale ke liye "45 litre
      kam hai" se zyada matlab "₹4,302 ka nuksaan hua" rakhta hai. Ab dono tables me
      VarianceAmount column hai, us din ke rate se.

   3. Back-date entry me aaj ka rate lag raha tha. sp_Product_GetRateOnDate isi kaam
      ke liye likha gaya tha ("back-dated entry aur audit dono ke liye") par use koi
      bulata hi nahi tha. 10 din purani shift khologe to us din ka rate lagna chahiye,
      aaj ka nahi — warna sale ka amount galat banega.
   ========================================================================================== */

/* ---- G13.2 Purani entries ki value bhi bhar do, warna list me khaali dikhega. Rate us din ka
   lete hain (ProductRateHistory), na mile to product ka aaj ka rate. */
UPDATE sr
SET sr.VarianceAmount = ROUND(sr.VarianceQty *
        PUMP.fn_ProductRateOnDate(t.ProductId, CAST(sr.ReconciliationDate AS DATETIME2)), 2)
FROM PUMP.StockReconciliations sr
INNER JOIN PUMP.Tanks t ON t.Id = sr.TankId
WHERE sr.VarianceAmount IS NULL;
GO

UPDATE dr
SET dr.VarianceAmount = ROUND(dr.Variance *
        PUMP.fn_ProductRateOnDate(t.ProductId, CAST(dr.ReadingDate AS DATETIME2)), 2)
FROM PUMP.DipReadings dr
INNER JOIN PUMP.Tanks t ON t.Id = dr.TankId
WHERE dr.VarianceAmount IS NULL;
GO

/* ---- G13.3 Reconciliation ab tank ledger me bhi likhti hai ---- */
CREATE OR ALTER PROCEDURE [PUMP].[sp_StockReconcile_Save]
(
    @OwnerId            BIGINT,
    @PumpId             BIGINT,
    @TankId             BIGINT,
    @ReconciliationDate DATE,
    @BookStock          DECIMAL(18,3),
    @PhysicalStock      DECIMAL(18,3),
    @Reason             NVARCHAR(250) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Tank isi owner/pump ka hona chahiye — id badal kar doosre ka stock na chhed sake. */
    DECLARE @ProductId BIGINT;
    SELECT @ProductId = ProductId
    FROM PUMP.Tanks
    WHERE Id = @TankId AND OwnerId = @OwnerId AND PumpId = @PumpId;

    IF @ProductId IS NULL
        THROW 50070, 'Tank not found, or the tank does not belong to your pump.', 1;

    DECLARE @VarianceQty DECIMAL(18,3) = @PhysicalStock - @BookStock;

    /* Us din ka rate — aaj ka nahi. Purani tareekh ki reconciliation ki value bhi
       tabhi sahi banegi. */
    DECLARE @Rate DECIMAL(18,3) =
        PUMP.fn_ProductRateOnDate(@ProductId, CAST(@ReconciliationDate AS DATETIME2));

    DECLARE @NewId BIGINT;

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO PUMP.StockReconciliations
        (
            OwnerId, PumpId, TankId, ReconciliationDate,
            BookStock, PhysicalStock, VarianceQty, VarianceAmount, Reason
        )
        VALUES
        (
            @OwnerId, @PumpId, @TankId, @ReconciliationDate,
            @BookStock, @PhysicalStock, @VarianceQty,
            ROUND(@VarianceQty * ISNULL(@Rate, 0), 2), @Reason
        );

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        /* Ledger row — ye pehle banti hi nahi thi, isliye stock chupchaap badal jaata
           tha. ReferenceNo 'RECON-' se shuru hota hai, aur DSR ki Receipt query use
           chhod deti hai, to ye Receipt column me nahi ginega — sirf stock ka hisaab
           milayega. Variance 0 ho to koi row nahi banti (bekaar ki entry se bacho). */
        IF @VarianceQty <> 0
        BEGIN
            INSERT INTO PUMP.TankTransactions
                (OwnerId, PumpId, TankId, TxnType, Quantity, ReferenceNo, Notes, TxnDateTime)
            VALUES
            (
                @OwnerId, @PumpId, @TankId,
                CASE WHEN @VarianceQty > 0 THEN 'IN' ELSE 'OUT' END,
                ABS(@VarianceQty),
                CONCAT('RECON-', @NewId),
                CONCAT('Stock reconciliation. ', ISNULL(@Reason, N'')),
                /* Aaj ki reconciliation hai to asli waqt, purani hai to us din ka 23:30
                   (din ki saari sale ke baad, taaki DSR me sahi din par baithe). */
                CASE WHEN @ReconciliationDate = CAST(SYSDATETIME() AS DATE)
                     THEN SYSDATETIME()
                     ELSE DATEADD(MINUTE, 1410, CAST(@ReconciliationDate AS DATETIME2))
                END
            );
        END

        UPDATE PUMP.Tanks
        SET CurrentStock = @PhysicalStock,
            UpdatedOn    = SYSDATETIME()
        WHERE Id = @TankId AND OwnerId = @OwnerId AND PumpId = @PumpId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT @NewId AS Id;
END
GO

/* ---- G13.4 Dip reading bhi variance ki value rakhe ---- */
CREATE OR ALTER PROCEDURE [PUMP].[sp_DipReading_Save]
(
    @OwnerId       BIGINT,
    @PumpId        BIGINT,
    @TankId        BIGINT,
    @ReadingDate   DATE,
    @ShiftId       BIGINT = NULL,
    @DipCm         DECIMAL(10,2),
    @WaterDipCm    DECIMAL(10,2) = NULL,
    @Density       DECIMAL(10,4) = NULL,
    @Temperature   DECIMAL(10,2) = NULL,
    @ExpectedStock DECIMAL(18,2) = 0,
    @ActualStock   DECIMAL(18,2) = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ProductId BIGINT;
    SELECT @ProductId = ProductId
    FROM PUMP.Tanks
    WHERE Id = @TankId AND OwnerId = @OwnerId AND PumpId = @PumpId;

    IF @ProductId IS NULL
        THROW 50071, 'Tank not found, or the tank does not belong to your pump.', 1;

    DECLARE @Variance DECIMAL(18,2) = @ActualStock - @ExpectedStock;

    DECLARE @Rate DECIMAL(18,3) =
        PUMP.fn_ProductRateOnDate(@ProductId, CAST(@ReadingDate AS DATETIME2));

    /* Dip sirf naap hai, stock ko haath nahi lagati — isliye yahan koi ledger row ya
       Tanks update nahi. Stock badalna ho to Reconciliation form se hota hai. */
    INSERT INTO PUMP.DipReadings
    (
        OwnerId, PumpId, TankId, ReadingDate, ShiftId, DipCm, WaterDipCm,
        Density, Temperature, ExpectedStock, ActualStock, Variance, VarianceAmount
    )
    VALUES
    (
        @OwnerId, @PumpId, @TankId, @ReadingDate, @ShiftId, @DipCm, @WaterDipCm,
        @Density, @Temperature, @ExpectedStock, @ActualStock, @Variance,
        ROUND(@Variance * ISNULL(@Rate, 0), 2)
    );

    SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS Id;
END
GO

PRINT '  + G13: reconciliation ab tank ledger me likhti hai, variance ki rupee value bhi banti hai';
GO

/* ==========================================================================================
   SECTION G14 — "AAJ KE RATE" SCREEN (2026-09-04)
   ------------------------------------------------------------------------------------------
   Ek pump par kai fuel grade hote hain (Normal, Premium/XP95, E20 ethanol-blend,
   Diesel, Premium Diesel) aur roz subah sabka rate alag-alag aata hai. Abhi rate
   badalne ke liye Products form ek-ek product ke liye kholna padta hai — 5 grade
   matlab roz 5 baar. Ye SP ek hi screen ke liye saari fuel ki list deti hai,
   pichhle rate ke saath (taaki dikhe ki aaj kitna upar/neeche gaya).

   Rate actually badalne ka kaam sp_Product_BulkRateUpdate @RatesJson karta hai —
   wo har grade ka apna rate leta hai, category-wide flatten nahi karta.
   ========================================================================================== */
CREATE OR ALTER PROCEDURE PUMP.sp_Product_DailyRateList
(
    @OwnerId BIGINT,
    @PumpId  BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        p.Id,
        p.PumpId,
        PumpName = pm.Name,
        p.Name,
        p.Category,
        p.Unit,
        p.CurrentRate,
        /* Pichhla rate = aakhri baar jo badla, uska OldRate. Ek hi din me do baar
           badla ho to bhi sabse naya hi dikhega. */
        PreviousRate  = h.OldRate,
        LastChangedOn = h.EffectiveFrom
    FROM PUMP.Products p
    JOIN PUMP.Pumps pm ON pm.Id = p.PumpId
    OUTER APPLY
    (
        SELECT TOP 1 x.OldRate, EffectiveFrom = ISNULL(x.EffectiveFrom, x.ChangedAt)
        FROM PUMP.ProductRateHistory x
        WHERE x.ProductId = p.Id
          AND x.OldRate <> x.NewRate      -- product banate waqt wali row nahi
        ORDER BY ISNULL(x.EffectiveFrom, x.ChangedAt) DESC, x.Id DESC
    ) h
    WHERE p.OwnerId = @OwnerId
      AND (@PumpId IS NULL OR p.PumpId = @PumpId)
      AND p.IsActive = 1
      AND ISNULL(p.IsDeleted, 0) = 0
      /* Sirf wahi cheezein jinka rate roz badalta hai. Lubricant/EV ka rate roz
         nahi badalta, wo Products form se hi theek hai. */
      AND p.IsFuel = 1
    ORDER BY pm.Name, p.Category, p.Name;
END
GO

PRINT '  + G14: sp_Product_DailyRateList (Aaj ke rate wali screen)';
GO

/* ---- G14.1 "Today's Rates" ka menu ---- */
IF NOT EXISTS (SELECT 1 FROM PUMP.Menus WHERE Route = '/daily-rates')
BEGIN
    /* Products ke bilkul baad rakhte hain — dono ek hi kaam ke aas-paas hain.
       Sequence me jagah banane ke liye baaki ko ek aage khiska rahe hain. */
    DECLARE @AfterSeq INT = ISNULL((SELECT Sequence FROM PUMP.Menus WHERE Route = '/products'), 2);

    UPDATE PUMP.Menus SET Sequence = Sequence + 1
    WHERE Sequence > @AfterSeq AND ParentId IS NULL;

    INSERT INTO PUMP.Menus (ParentId, MenuName, Route, Icon, Sequence, IsVisible, IsActive)
    VALUES (NULL, N'Today''s Rates', '/daily-rates', N'currency-rupee', @AfterSeq + 1, 1, 1);

    DECLARE @RateMenuId BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);

    /* Jis role ke paas Products ka access hai usi ko rate screen bhi milni
       chahiye — rate badalna wahi kaam hai jo pehle Products form se hota tha. */
    INSERT INTO PUMP.RoleMenus (RoleId, MenuId, CanView, CanCreate, CanEdit, CanDelete)
    SELECT rm.RoleId, @RateMenuId, rm.CanView, 0, rm.CanEdit, 0
    FROM PUMP.RoleMenus rm
    JOIN PUMP.Menus m ON m.Id = rm.MenuId AND m.Route = '/products'
    WHERE NOT EXISTS (SELECT 1 FROM PUMP.RoleMenus x
                      WHERE x.RoleId = rm.RoleId AND x.MenuId = @RateMenuId);
END
GO

PRINT '  + G14.1: "Today''s Rates" menu';
GO

/* ==========================================================================================
   SECTION G15 - PASSWORD RESET (OTP se) - 2026-09-04
   ------------------------------------------------------------------------------------------
   Ab tak password bhoolne ka koi raasta hi nahi tha - na user ke liye, na superadmin ke
   liye. Pump wale ka phone aata to seedha DB kholni padti. Pan-India me ye sabse zyada
   aane wala support call hai.

   Email par bharosa nahi kar sakte (bahut se pump operators ke paas email hai hi nahi),
   isliye MOBILE par OTP. Users.Mobile pehle se hai.

   Suraksha ka dhyan:
   - OTP plain nahi, HASH karke rakhte hain (DB dekhne wala bhi use na kar sake).
   - 10 minute me expire.
   - 5 galat koshish ke baad wahi OTP bekaar.
   - Ek mobile se 1 ghante me 3 se zyada OTP nahi.
   - "Ye number registered nahi hai" kabhi nahi batate - warna koi bhi number daal kar
     pata kar lega ki kaun sa number system me hai. Har haal me ek jaisa jawab.
   ========================================================================================== */
IF OBJECT_ID('PUMP.PasswordResetOtps','U') IS NULL
CREATE TABLE PUMP.PasswordResetOtps
(
    Id           BIGINT IDENTITY(1,1) NOT NULL,
    UserId       BIGINT        NOT NULL,
    Mobile       NVARCHAR(20)  NOT NULL,
    OtpHash      NVARCHAR(200) NOT NULL,
    ExpiresOn    DATETIME2(7)  NOT NULL,
    AttemptCount INT           NOT NULL CONSTRAINT DF_PwdOtp_Attempt DEFAULT(0),
    IsUsed       BIT           NOT NULL CONSTRAINT DF_PwdOtp_IsUsed  DEFAULT(0),
    UsedOn       DATETIME2(7)  NULL,
    SourceIp     NVARCHAR(45)  NULL,
    CreatedOn    DATETIME2(7)  NOT NULL CONSTRAINT DF_PwdOtp_Created DEFAULT(DATEADD(MINUTE,330,GETUTCDATE())),
    CONSTRAINT PK_PasswordResetOtps PRIMARY KEY CLUSTERED (Id)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_PwdOtp_Mobile_Created')
    CREATE INDEX IX_PwdOtp_Mobile_Created ON PUMP.PasswordResetOtps (Mobile, CreatedOn DESC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='FK_PwdOtp_User')
    ALTER TABLE PUMP.PasswordResetOtps ADD CONSTRAINT FK_PwdOtp_User
        FOREIGN KEY (UserId) REFERENCES PUMP.Users(Id);
GO

/* ---- G15.1 OTP maango ----
   Number registered ho ya na ho, jawab hamesha ek jaisa. Agar hai to OTP ka hash
   yahan rakh dete hain aur API SMS bhej deti hai. */
CREATE OR ALTER PROCEDURE PUMP.sp_PasswordReset_RequestOtp
(
    @Mobile       NVARCHAR(20),
    @OtpHash      NVARCHAR(200),
    @SourceIp     NVARCHAR(45) = NULL,
    @ValidMinutes INT = 10
)
AS
BEGIN
    SET NOCOUNT ON;

    /* Ek ghante me 3 se zyada nahi - chahe number registered ho ya na ho. */
    IF (SELECT COUNT(*) FROM PUMP.PasswordResetOtps
        WHERE Mobile = @Mobile AND CreatedOn > DATEADD(HOUR, -1, SYSDATETIME())) >= 3
    BEGIN
        SELECT UserId = CAST(NULL AS BIGINT), FullName = CAST(NULL AS NVARCHAR(150)),
               Throttled = CAST(1 AS BIT);
        RETURN;
    END

    DECLARE @UserId BIGINT, @FullName NVARCHAR(150);

    /* Number kai tarah se likha ja sakta hai: 9876543210, +91 9876543210,
       91-9876543210. DB me bhi dono tarah pade hain (kuch 91 ke saath, kuch bina).
       Isliye dono taraf ke AAKHRI 10 ANK milate hain. API sirf ank bhejti hai;
       DB wale number me se + - space hata kar tulna karte hain. */
    DECLARE @Last10 NVARCHAR(10) = RIGHT(@Mobile, 10);

    SELECT TOP 1 @UserId = u.Id, @FullName = u.FullName
    FROM PUMP.Users u
    LEFT JOIN PUMP.Owners o ON o.Id = u.OwnerId
    WHERE RIGHT(REPLACE(REPLACE(REPLACE(REPLACE(u.Mobile, '+', ''), '-', ''), ' ', ''), '(', ''), 10) = @Last10
      AND u.IsActive = 1
      AND ISNULL(u.IsDeleted, 0) = 0
      /* Band pade tenant ka password reset karke bhi kuch nahi hoga - login
         waise bhi nahi hone dega. Isliye OTP bhejna hi nahi. */
      AND (u.IsSuperAdmin = 1 OR ISNULL(o.IsActive, 1) = 1)
    ORDER BY u.Id;

    IF @UserId IS NOT NULL
    BEGIN
        /* Purane OTP bekaar kar do - ek waqt me ek hi chale. */
        UPDATE PUMP.PasswordResetOtps
        SET IsUsed = 1, UsedOn = SYSDATETIME()
        WHERE UserId = @UserId AND IsUsed = 0;

        INSERT INTO PUMP.PasswordResetOtps (UserId, Mobile, OtpHash, ExpiresOn, SourceIp)
        VALUES (@UserId, @Mobile, @OtpHash,
                DATEADD(MINUTE, @ValidMinutes, SYSDATETIME()), @SourceIp);
    END

    /* UserId sirf isliye lautate hain ki API SMS bhej sake. Endpoint bahar
       hamesha ek hi jawab deta hai. */
    SELECT UserId = @UserId, FullName = @FullName, Throttled = CAST(0 AS BIT);
END
GO

/* ---- G15.2 OTP jaancho aur naya password lagao ----
   Hash ki tulna yahin hoti hai. Sahi nikla to password badal kar OTP khatam. */
CREATE OR ALTER PROCEDURE PUMP.sp_PasswordReset_Verify
(
    @Mobile          NVARCHAR(20),
    @OtpHash         NVARCHAR(200),
    @NewPasswordHash NVARCHAR(200)
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Id BIGINT, @UserId BIGINT, @Stored NVARCHAR(200),
            @ExpiresOn DATETIME2(7), @Attempts INT;

    SELECT TOP 1 @Id = Id, @UserId = UserId, @Stored = OtpHash,
                 @ExpiresOn = ExpiresOn, @Attempts = AttemptCount
    FROM PUMP.PasswordResetOtps
    WHERE Mobile = @Mobile AND IsUsed = 0
    ORDER BY Id DESC;

    IF @Id IS NULL
    BEGIN
        SELECT Result = 'NO_REQUEST', AttemptsLeft = CAST(NULL AS INT);
        RETURN;
    END

    IF @ExpiresOn < SYSDATETIME()
    BEGIN
        UPDATE PUMP.PasswordResetOtps SET IsUsed = 1, UsedOn = SYSDATETIME() WHERE Id = @Id;
        SELECT Result = 'EXPIRED', AttemptsLeft = CAST(NULL AS INT);
        RETURN;
    END

    IF @Attempts >= 5
    BEGIN
        UPDATE PUMP.PasswordResetOtps SET IsUsed = 1, UsedOn = SYSDATETIME() WHERE Id = @Id;
        SELECT Result = 'TOO_MANY_ATTEMPTS', AttemptsLeft = 0;
        RETURN;
    END

    IF @Stored <> @OtpHash
    BEGIN
        UPDATE PUMP.PasswordResetOtps SET AttemptCount = AttemptCount + 1 WHERE Id = @Id;
        SELECT Result = 'WRONG_OTP', AttemptsLeft = 5 - (@Attempts + 1);
        RETURN;
    END

    BEGIN TRAN;
        UPDATE PUMP.Users
        SET PasswordHash = @NewPasswordHash, ModifiedOn = SYSDATETIME()
        WHERE Id = @UserId;

        UPDATE PUMP.PasswordResetOtps
        SET IsUsed = 1, UsedOn = SYSDATETIME()
        WHERE Id = @Id;

        /* Password badla to purane refresh token bekaar - agar kisi aur ke paas
           session khula tha to wo ab kaam na kare. */
        /* Column UTC me hai (RevokedOnUtc), isliye SYSUTCDATETIME. */
        UPDATE PUMP.UserRefreshTokens
        SET RevokedOnUtc = SYSUTCDATETIME(),
            RevokeReason = 'PASSWORD_RESET'
        WHERE UserId = @UserId AND RevokedOnUtc IS NULL;
    COMMIT;

    EXEC PUMP.sp_Audit_Log
        @OwnerId = NULL, @PumpId = NULL, @UserId = @UserId,
        @EntityName = 'Users', @EntityId = @UserId, @Action = 'PASSWORD_RESET_OTP',
        @Reason = 'User ne mobile OTP se password reset kiya';

    SELECT Result = 'OK', AttemptsLeft = CAST(NULL AS INT);
END
GO

/* ---- G15.3 Superadmin kisi bhi user ka password reset kare ----
   Support call par turant kaam aata hai. Sirf superadmin ke liye. */
CREATE OR ALTER PROCEDURE PUMP.sp_User_AdminResetPassword
(
    @UserId          BIGINT,
    @NewPasswordHash NVARCHAR(200),
    @ByUserId        BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.Users WHERE Id = @ByUserId AND IsSuperAdmin = 1)
        THROW 50090, 'Only a super admin can reset another users password.', 1;

    IF NOT EXISTS (SELECT 1 FROM PUMP.Users WHERE Id = @UserId AND ISNULL(IsDeleted,0) = 0)
        THROW 50091, 'User not found.', 1;

    BEGIN TRAN;
        UPDATE PUMP.Users
        SET PasswordHash = @NewPasswordHash, ModifiedBy = @ByUserId, ModifiedOn = SYSDATETIME()
        WHERE Id = @UserId;

        /* Column UTC me hai (RevokedOnUtc), isliye SYSUTCDATETIME. */
        UPDATE PUMP.UserRefreshTokens
        SET RevokedOnUtc = SYSUTCDATETIME(),
            RevokeReason = 'PASSWORD_RESET'
        WHERE UserId = @UserId AND RevokedOnUtc IS NULL;
    COMMIT;

    EXEC PUMP.sp_Audit_Log
        @OwnerId = NULL, @PumpId = NULL, @UserId = @ByUserId,
        @EntityName = 'Users', @EntityId = @UserId, @Action = 'PASSWORD_RESET_ADMIN',
        @Reason = 'Superadmin ne password reset kiya';

    SELECT Result = 'OK';
END
GO

PRINT '  + G15: password reset (mobile OTP + superadmin reset)';
GO

/* ==========================================================================================
   SECTION G16 - "KISNE KIYA" KA JAWAB (audit) - 2026-09-04
   ------------------------------------------------------------------------------------------
   AuditLog table shuru se thi, par sirf 11 jagah likhti thi - zyadatar delete par.
   Jin chaar kaamon se pump par sach me paisa ya tel bahar ja sakta hai, unme se kisi
   me audit nahi tha, aur teen me to @UserId parameter hi nahi tha - yaani "kisne kiya"
   ka jawab tha hi nahi:

     1. Sale void  - bill kaat kar cancel kar dena (sabse purana tareeka)
     2. Stock reconciliation - "45 litre kam nikla" likh kar stock ghata dena
     3. Cash transaction - golak se paisa nikalna/daalna
     4. Tank transaction - manual stock ghatana/badhana

   Ab chaaron me @UserId hai (optional - purana code bina bheje bhi chalega) aur
   AuditLog me poori entry jaati hai, purani-nayi value ke saath.
   ========================================================================================== */

/* ---- G16.1 Sale void: ab mitata nahi, nishaan lagata hai ---- */
CREATE OR ALTER PROCEDURE [PUMP].[sp_Sale_Void]
(
    @Id      BIGINT,
    @OwnerId BIGINT,
    @UserId  BIGINT = NULL,
    @Reason  NVARCHAR(250) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.SalesHeaders WHERE Id = @Id AND OwnerId = @OwnerId)
        THROW 50010, 'Sale not found, or you do not have access to it.', 1;

    DECLARE @PartyId BIGINT, @TotalAmount DECIMAL(18,2), @PaymentMode NVARCHAR(30),
            @PumpId BIGINT, @BillNo NVARCHAR(50), @IsVoid BIT,
            @BillDateTime DATETIME2(7), @CustomerName NVARCHAR(150);

    SELECT @PartyId = PartyId, @TotalAmount = TotalAmount, @PaymentMode = PaymentMode,
           @PumpId = PumpId, @BillNo = BillNo, @IsVoid = IsVoid,
           @BillDateTime = BillDateTime, @CustomerName = CustomerName
    FROM PUMP.SalesHeaders
    WHERE Id = @Id AND OwnerId = @OwnerId;

    /* Do baar void hone se party ka balance do baar ghat jaata tha. */
    IF @IsVoid = 1
    BEGIN
        SELECT Result = 'ALREADY_VOID', Id = @Id;
        RETURN;
    END

    BEGIN TRANSACTION;

        IF UPPER(ISNULL(@PaymentMode,'')) = 'CREDIT' AND @PartyId IS NOT NULL
        BEGIN
            UPDATE PUMP.Parties
            SET CurrentBalance = CurrentBalance - @TotalAmount,
                UpdatedOn      = SYSDATETIME()
            WHERE Id = @PartyId AND OwnerId = @OwnerId;

            INSERT INTO PUMP.PartyLedger (OwnerId, PumpId, PartyId, EntryType, Amount, ReferenceNo, Notes)
            VALUES (@OwnerId, @PumpId, @PartyId, 'VOID', -@TotalAmount,
                    CONCAT('VOID-SALE-', @Id), CONCAT('Void of sale #', @Id));
        END

        /* Bill mitate nahi - nishaan lagate hain. SalesDetails aur Receipts bhi
           rehne dete hain, taaki baad me dekha ja sake ki kya kaata gaya tha. */
        UPDATE PUMP.SalesHeaders
        SET IsVoid     = 1,
            VoidedOn   = SYSDATETIME(),
            VoidedBy   = @UserId,
            VoidReason = @Reason
        WHERE Id = @Id AND OwnerId = @OwnerId;

    COMMIT TRANSACTION;

    /* Poori jaankari audit me - bill mit jaata to ye kahin nahi bachti. */
    DECLARE @AuditOld NVARCHAR(MAX) =
        CONCAT('Bill ', @BillNo, ' | ', CONVERT(NVARCHAR(20), @BillDateTime, 120),
               ' | ', @PaymentMode, ' | Rs ', @TotalAmount,
               ISNULL(' | ' + @CustomerName, ''));
    DECLARE @AuditReason NVARCHAR(500) =
        CONCAT('Bill ', @BillNo, ' void kiya. Amount Rs ', @TotalAmount,
               ISNULL(' - ' + @Reason, ''));

    EXEC PUMP.sp_Audit_Log
        @OwnerId = @OwnerId, @PumpId = @PumpId, @UserId = @UserId,
        @EntityName = 'SalesHeaders', @EntityId = @Id, @Action = 'VOID',
        @OldValues = @AuditOld, @NewValues = 'VOID', @Reason = @AuditReason;

    SELECT Result = 'OK', Id = @Id;
END
GO

/* ---- G16.2 Cash transaction ---- */
CREATE OR ALTER PROCEDURE [PUMP].[sp_CashTxn_Save]
(
    @OwnerId     BIGINT,
    @PumpId      BIGINT,
    @ShiftId     BIGINT = NULL,
    @TxnType     NVARCHAR(20),
    @Amount      DECIMAL(18,2),
    @ReferenceNo NVARCHAR(50) = NULL,
    @Narration   NVARCHAR(250) = NULL,
    @TxnDateTime DATETIME2 = NULL,
    @UserId      BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO PUMP.CashTransactions
        (OwnerId, PumpId, ShiftId, TxnType, Amount, ReferenceNo, Narration, TxnDateTime)
    VALUES
        (@OwnerId, @PumpId, @ShiftId, @TxnType, @Amount, @ReferenceNo, @Narration,
         ISNULL(@TxnDateTime, SYSDATETIME()));

    DECLARE @NewId BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);

    DECLARE @AuditReason NVARCHAR(500) =
        CONCAT(@TxnType, ' Rs ', @Amount, ISNULL(' - ' + @Narration, ''));
    DECLARE @AuditNew NVARCHAR(MAX) = @TxnType;

    EXEC PUMP.sp_Audit_Log
        @OwnerId = @OwnerId, @PumpId = @PumpId, @UserId = @UserId,
        @EntityName = 'CashTransactions', @EntityId = @NewId, @Action = 'CREATE',
        @NewValues = @AuditNew, @Reason = @AuditReason;

    SELECT @NewId AS Id;
END
GO

/* ---- G16.3 Tank transaction (manual stock) ---- */
CREATE OR ALTER PROCEDURE PUMP.sp_TankTxn_Save
(
    @OwnerId     BIGINT,
    @PumpId      BIGINT,
    @TankId      BIGINT,
    @TxnType     NVARCHAR(30),
    @Quantity    DECIMAL(18,2),
    @ReferenceNo NVARCHAR(50) = NULL,
    @Notes       NVARCHAR(250) = NULL,
    @TxnDateTime DATETIME2 = NULL,      -- purani tareekh ki entry ke liye
    @UserId      BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    /* INSERT fail ho to UPDATE bhi na chale - warna stock badal jaata tha bina
       kisi matching TankTransactions row ke. */
    SET XACT_ABORT ON;

    DECLARE @OldStock DECIMAL(18,2) =
        (SELECT CurrentStock FROM PUMP.Tanks
         WHERE Id = @TankId AND OwnerId = @OwnerId AND PumpId = @PumpId);

    IF @OldStock IS NULL
        THROW 50072, 'Tank not found, or the tank does not belong to your pump.', 1;

    DECLARE @NewId BIGINT;

    BEGIN TRANSACTION;

        INSERT INTO PUMP.TankTransactions
            (OwnerId, PumpId, TankId, TxnType, Quantity, ReferenceNo, Notes, TxnDateTime)
        VALUES
            (@OwnerId, @PumpId, @TankId, @TxnType, @Quantity, @ReferenceNo, @Notes,
             ISNULL(@TxnDateTime, SYSDATETIME()));

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        UPDATE PUMP.Tanks
        SET CurrentStock = CASE
                WHEN UPPER(@TxnType) IN ('IN', 'RECEIPT', 'PURCHASE', 'OPENING')
                     THEN CurrentStock + @Quantity
                ELSE CurrentStock - @Quantity
            END,
            UpdatedOn = SYSDATETIME()
        WHERE Id = @TankId AND OwnerId = @OwnerId AND PumpId = @PumpId;

    COMMIT TRANSACTION;

    DECLARE @NewStock DECIMAL(18,2) =
        (SELECT CurrentStock FROM PUMP.Tanks WHERE Id = @TankId);

    DECLARE @AuditReason NVARCHAR(500) =
        CONCAT(@TxnType, ' ', @Quantity, ' L. Tank ', @TankId, ISNULL(' - ' + @Notes, ''));
    DECLARE @AuditAction NVARCHAR(60)  = @TxnType;
    DECLARE @AuditOld    NVARCHAR(MAX) = CAST(@OldStock AS NVARCHAR(50));
    DECLARE @AuditNew    NVARCHAR(MAX) = CAST(@NewStock AS NVARCHAR(50));

    EXEC PUMP.sp_Audit_Log
        @OwnerId = @OwnerId, @PumpId = @PumpId, @UserId = @UserId,
        @EntityName = 'TankTransactions', @EntityId = @NewId, @Action = @AuditAction,
        @OldValues = @AuditOld, @NewValues = @AuditNew, @Reason = @AuditReason;

    SELECT @NewId AS Id;
END
GO

/* ---- G16.4 Stock reconciliation ----
   Poori proc dobara likh rahe hain kyunki sirf @UserId jodna kaafi nahi -
   audit call bhi andar chahiye. Baaki sab G13.3 jaisa hi hai. */
CREATE OR ALTER PROCEDURE [PUMP].[sp_StockReconcile_Save]
(
    @OwnerId            BIGINT,
    @PumpId             BIGINT,
    @TankId             BIGINT,
    @ReconciliationDate DATE,
    @BookStock          DECIMAL(18,3),
    @PhysicalStock      DECIMAL(18,3),
    @Reason             NVARCHAR(250) = NULL,
    @UserId             BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Tank isi owner/pump ka hona chahiye - id badal kar doosre ka stock na chhed sake. */
    DECLARE @ProductId BIGINT;
    SELECT @ProductId = ProductId
    FROM PUMP.Tanks
    WHERE Id = @TankId AND OwnerId = @OwnerId AND PumpId = @PumpId;

    IF @ProductId IS NULL
        THROW 50070, 'Tank not found, or the tank does not belong to your pump.', 1;

    DECLARE @VarianceQty DECIMAL(18,3) = @PhysicalStock - @BookStock;

    /* Us din ka rate - aaj ka nahi. */
    DECLARE @Rate DECIMAL(18,3) =
        PUMP.fn_ProductRateOnDate(@ProductId, CAST(@ReconciliationDate AS DATETIME2));

    DECLARE @VarianceAmount DECIMAL(18,2) = ROUND(@VarianceQty * ISNULL(@Rate, 0), 2);
    DECLARE @NewId BIGINT;

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO PUMP.StockReconciliations
        (
            OwnerId, PumpId, TankId, ReconciliationDate,
            BookStock, PhysicalStock, VarianceQty, VarianceAmount, Reason
        )
        VALUES
        (
            @OwnerId, @PumpId, @TankId, @ReconciliationDate,
            @BookStock, @PhysicalStock, @VarianceQty, @VarianceAmount, @Reason
        );

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        /* Ledger row - iske bina stock chupchaap badal jaata tha aur DSR ka
           mahine ka opening galat ho jaata tha (dekho G13). */
        IF @VarianceQty <> 0
        BEGIN
            INSERT INTO PUMP.TankTransactions
                (OwnerId, PumpId, TankId, TxnType, Quantity, ReferenceNo, Notes, TxnDateTime)
            VALUES
            (
                @OwnerId, @PumpId, @TankId,
                CASE WHEN @VarianceQty > 0 THEN 'IN' ELSE 'OUT' END,
                ABS(@VarianceQty),
                CONCAT('RECON-', @NewId),
                CONCAT('Stock reconciliation. ', ISNULL(@Reason, N'')),
                CASE WHEN @ReconciliationDate = CAST(SYSDATETIME() AS DATE)
                     THEN SYSDATETIME()
                     ELSE DATEADD(MINUTE, 1410, CAST(@ReconciliationDate AS DATETIME2))
                END
            );
        END

        UPDATE PUMP.Tanks
        SET CurrentStock = @PhysicalStock,
            UpdatedOn    = SYSDATETIME()
        WHERE Id = @TankId AND OwnerId = @OwnerId AND PumpId = @PumpId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    /* Stock ghatana sabse aasan tareeka hai tel bahar nikalne ka - isliye
       kisne, kitna aur kis wajah se, teeno darj hone chahiye. */
    DECLARE @AuditReason NVARCHAR(500) =
        CONCAT('Tank ', @TankId, ': variance ', @VarianceQty,
               ' L (Rs ', @VarianceAmount, ')', ISNULL(' - ' + @Reason, ''));
    DECLARE @AuditOld NVARCHAR(MAX) = CAST(@BookStock AS NVARCHAR(50));
    DECLARE @AuditNew NVARCHAR(MAX) = CAST(@PhysicalStock AS NVARCHAR(50));

    EXEC PUMP.sp_Audit_Log
        @OwnerId = @OwnerId, @PumpId = @PumpId, @UserId = @UserId,
        @EntityName = 'StockReconciliations', @EntityId = @NewId, @Action = 'RECONCILE',
        @OldValues = @AuditOld, @NewValues = @AuditNew, @Reason = @AuditReason;

    SELECT @NewId AS Id;
END
GO

/* ---- G16.5 Void bikri ab kisi total/report me nahi ginti ----
   Ye saari SP SalesHeaders padhti hain. Har ek me "IsVoid = 0" ki shart
   jodni zaroori hai, warna void kiya hua bill ab bhi kamai me ginta rehta
   (pehle wo delete ho jaata tha isliye sawaal hi nahi uthta tha). */

/* Sales list: void bhi DIKHTA hai (nishaan ke saath) - malik ko pata chalna
   chahiye ki bill kaata gaya. Sirf total me nahi ginta. */
CREATE OR ALTER PROCEDURE [PUMP].[sp_Sales_List]
(
    @OwnerId    BIGINT,
    @PumpId     BIGINT = NULL,
    @FromDate   DATETIME2 = NULL,
    @ToDate     DATETIME2 = NULL,
    @SearchTerm NVARCHAR(100) = NULL,
    @PageNumber INT = 1,
    @PageSize   INT = 50
)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Offset INT = (@PageNumber - 1) * @PageSize;

    SELECT
        h.Id, h.OwnerId, h.PumpId, h.ShiftId, h.PartyId, h.BillNo, h.BillDateTime,
        h.PaymentMode, h.VehicleNo, h.CustomerName, h.AttendantName, h.TotalAmount,
        h.IsVoid, h.VoidedOn, h.VoidReason
    FROM PUMP.SalesHeaders h
    WHERE h.OwnerId = @OwnerId
      AND (@PumpId IS NULL OR @PumpId <= 0 OR h.PumpId = @PumpId)
      AND (@FromDate IS NULL OR h.BillDateTime >= @FromDate)
      AND (@ToDate IS NULL OR h.BillDateTime <= @ToDate)
      AND (@SearchTerm IS NULL OR @SearchTerm = '' OR h.BillNo LIKE '%' + @SearchTerm + '%'
           OR h.VehicleNo LIKE '%' + @SearchTerm + '%' OR h.CustomerName LIKE '%' + @SearchTerm + '%')
    ORDER BY h.Id DESC
    OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(1)
    FROM PUMP.SalesHeaders h
    WHERE h.OwnerId = @OwnerId
      AND (@PumpId IS NULL OR @PumpId <= 0 OR h.PumpId = @PumpId)
      AND (@FromDate IS NULL OR h.BillDateTime >= @FromDate)
      AND (@ToDate IS NULL OR h.BillDateTime <= @ToDate)
      AND (@SearchTerm IS NULL OR @SearchTerm = '' OR h.BillNo LIKE '%' + @SearchTerm + '%'
           OR h.VehicleNo LIKE '%' + @SearchTerm + '%' OR h.CustomerName LIKE '%' + @SearchTerm + '%');
END
GO

PRINT '  + G16: audit ab sale-void, cash, tank aur reconciliation par bhi ("kisne kiya")';
PRINT '  + G16: void ki gayi bikri ab mitti nahi - nishaan lagta hai aur total me nahi ginti';
GO

/* ==========================================================================================
   SECTION G17 - NAYA TENANT (khud sign-up + superadmin dono) - 2026-09-04
   ------------------------------------------------------------------------------------------
   BLOCKER: purana sp_Owner_Create `ValidUpto` set hi nahi karta tha. AuthService me
   `user.ValidUpto ?? DateTime.MinValue` hai, isliye naye tenant ka admin login karte hi
   403 TRIAL_EXPIRED khaata tha. Yaani superadmin ka "Create New Tenant" button ek MARA
   HUA tenant banata tha - test me exactly yahi hua.

   Saath me teen aur kami thi:
   - Pehla PUMP banta hi nahi tha. Login ke baad har page ko pumpId chahiye, to naya
     user khaali screen dekhta.
   - Username pehle se hai ya nahi, ye check nahi hota tha - do owner ka ek hi username
     ban sakta tha aur login kis par jaata, kuch pata nahi.
   - Contact ka naam/number kahin darj nahi hota tha.

   Ab ek hi SP dono kaam karti hai: superadmin bhi isse tenant banata hai, aur login
   page ka "khud sign-up" bhi. Farak sirf itna ki self-signup me trial hamesha lagta hai.
   ========================================================================================== */
CREATE OR ALTER PROCEDURE [PUMP].[sp_Owner_Create]
(
    @Name              NVARCHAR(200),
    @AdminUsername     NVARCHAR(100),
    @AdminPasswordHash NVARCHAR(500),
    @ContactName       NVARCHAR(150) = NULL,
    @ContactNo         NVARCHAR(20)  = NULL,
    @Email             NVARCHAR(150) = NULL,
    @City              NVARCHAR(100) = NULL,
    @StateCode         NVARCHAR(2)   = NULL,
    @PumpName          NVARCHAR(200) = NULL,
    @TrialDays         INT           = 7,
    @PlanCode          NVARCHAR(50)  = '7_DAY_TRIAL',
    @IsTrial           BIT           = 1
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF LTRIM(RTRIM(ISNULL(@Name, ''))) = ''
        THROW 50100, 'Pump / owner name is required.', 1;

    IF LEN(LTRIM(RTRIM(ISNULL(@AdminUsername, '')))) < 4
        THROW 50101, 'Username must be at least 4 characters.', 1;

    SET @AdminUsername = LTRIM(RTRIM(@AdminUsername));

    /* Username poore system me ek hi baar - login username se hota hai, owner se
       nahi, isliye do owner ka ek hi username nahi chal sakta. */
    IF EXISTS (SELECT 1 FROM PUMP.Users
               WHERE Username = @AdminUsername AND ISNULL(IsDeleted, 0) = 0)
        THROW 50102, 'That username is already taken. Please choose another.', 1;

    DECLARE @OwnerId BIGINT, @RoleId BIGINT, @UserId BIGINT, @PumpId BIGINT;

    BEGIN TRY
        BEGIN TRANSACTION;

            /* ValidUpto ke bina naya tenant login hi nahi kar paata - yahi wo
               blocker tha jiski wajah se naya tenant bekaar ban jaata tha. */
            INSERT INTO PUMP.Owners
                (Name, IsActive, ValidUpto, ContactName, ContactNo, Email, City, StateCode, PlanCode, IsTrial)
            VALUES
                (@Name, 1, DATEADD(DAY, ISNULL(NULLIF(@TrialDays, 0), 7), CAST(SYSDATETIME() AS DATE)),
                 @ContactName, @ContactNo, @Email, @City, @StateCode, @PlanCode, @IsTrial);

            SET @OwnerId = CAST(SCOPE_IDENTITY() AS BIGINT);

            INSERT INTO PUMP.Roles (OwnerId, Name, IsSystem, IsActive)
            VALUES (@OwnerId, 'Admin', 1, 1);

            SET @RoleId = CAST(SCOPE_IDENTITY() AS BIGINT);

            INSERT INTO PUMP.Users
                (OwnerId, FullName, Username, PasswordHash, Mobile, IsSuperAdmin, IsOwner, IsActive)
            VALUES
                (@OwnerId, ISNULL(@ContactName, 'Owner Admin'), @AdminUsername,
                 @AdminPasswordHash, @ContactNo, 0, 1, 1);

            SET @UserId = CAST(SCOPE_IDENTITY() AS BIGINT);

            INSERT INTO PUMP.UserRoles (UserId, RoleId) VALUES (@UserId, @RoleId);

            INSERT INTO PUMP.RoleMenus (RoleId, MenuId, CanView, CanCreate, CanEdit, CanDelete)
            SELECT @RoleId, Id, 1, 1, 1, 1
            FROM PUMP.Menus
            WHERE IsActive = 1;

            /* Pehla pump - iske bina login ke baad har page khaali dikhta hai
               (har screen ko pumpId chahiye). Naam baad me badla ja sakta hai. */
            INSERT INTO PUMP.Pumps (OwnerId, Name, City, StateCode, IsActive)
            VALUES (@OwnerId, ISNULL(NULLIF(LTRIM(RTRIM(@PumpName)), ''), @Name),
                    @City, @StateCode, 1);

            SET @PumpId = CAST(SCOPE_IDENTITY() AS BIGINT);

            /* Kharch ke khaate (Section S). Inke bina Expenses page par
               "No expense head available" aata tha aur naya pump kabhi koi
               kharch darj hi nahi kar paata tha. Owner inhe baad me badal
               sakta hai — Masters > Expense Heads se. */
            INSERT INTO PUMP.ExpenseHeads (OwnerId, PumpId, HeadName, IsActive)
            VALUES (@OwnerId, @PumpId, N'Salary', 1),
                   (@OwnerId, @PumpId, N'Electricity', 1),
                   (@OwnerId, @PumpId, N'Rent', 1),
                   (@OwnerId, @PumpId, N'Repair & Maintenance', 1),
                   (@OwnerId, @PumpId, N'Fuel & Transport', 1),
                   (@OwnerId, @PumpId, N'Office & Stationery', 1),
                   (@OwnerId, @PumpId, N'Bank Charges', 1),
                   (@OwnerId, @PumpId, N'Licence & Fees', 1),
                   (@OwnerId, @PumpId, N'Tea & Refreshment', 1),
                   (@OwnerId, @PumpId, N'Miscellaneous', 1);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    DECLARE @AuditReason NVARCHAR(500) =
        CONCAT('Naya tenant: ', @Name, ' (', @AdminUsername, '), trial ',
               ISNULL(NULLIF(@TrialDays, 0), 7), ' din');

    EXEC PUMP.sp_Audit_Log
        @OwnerId = @OwnerId, @PumpId = @PumpId, @UserId = @UserId,
        @EntityName = 'Owners', @EntityId = @OwnerId, @Action = 'CREATE_TENANT',
        @Reason = @AuditReason;

    SELECT Id = @OwnerId, PumpId = @PumpId, UserId = @UserId;
END
GO

/* ---- G17.1 Login page se khud sign-up ----
   Public form hai (bina login ke), isliye upar wali SP se seedha nahi, is wrapper se
   jaata hai - yahan ek number se baar-baar account banane ki rok hai. API par per-IP
   rate limit alag se hai. */
CREATE OR ALTER PROCEDURE [PUMP].[sp_Owner_SelfSignup]
(
    @PumpName          NVARCHAR(200),
    @ContactName       NVARCHAR(150),
    @ContactNo         NVARCHAR(20),
    @AdminUsername     NVARCHAR(100),
    @AdminPasswordHash NVARCHAR(500),
    @City              NVARCHAR(100) = NULL,
    @StateCode         NVARCHAR(2)   = NULL,
    @Email             NVARCHAR(150) = NULL,
    @SourceIp          NVARCHAR(45)  = NULL,
    @TrialDays         INT           = 7
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Last10 NVARCHAR(10) = RIGHT(@ContactNo, 10);

    /* Ek mobile number se ek hi account. Warna ek aadmi 10 trial bana kar
       hamesha muft chalata rahega. */
    IF EXISTS (
        SELECT 1 FROM PUMP.Owners
        WHERE RIGHT(REPLACE(REPLACE(REPLACE(ISNULL(ContactNo,''), '+', ''), '-', ''), ' ', ''), 10) = @Last10
          AND ISNULL(IsDeleted, 0) = 0
    )
        THROW 50103, 'An account already exists for this mobile number. Please sign in or reset your password.', 1;

    EXEC PUMP.sp_Owner_Create
        @Name              = @PumpName,
        @AdminUsername     = @AdminUsername,
        @AdminPasswordHash = @AdminPasswordHash,
        @ContactName       = @ContactName,
        @ContactNo         = @ContactNo,
        @Email             = @Email,
        @City              = @City,
        @StateCode         = @StateCode,
        @PumpName          = @PumpName,
        @TrialDays         = @TrialDays,
        @PlanCode          = '7_DAY_TRIAL',
        @IsTrial           = 1;
END
GO

/* Purane tenant jinki ValidUpto NULL reh gayi thi, unhe upar F4 wala backfill
   pehle hi 1 saal de deta hai (ye script F4 ke baad chalti hai), isliye yahan
   dobara kuch karne ki zaroorat nahi. */

PRINT '  + G17: naya tenant ab sach me chalta hai (ValidUpto + pehla pump + username check)';
PRINT '  + G17: login page se khud sign-up ka SP';
GO

/* ==========================================================================================
   SECTION G18 - SUPERADMIN KO ASLI TASVEER DIKHE - 2026-09-04
   ------------------------------------------------------------------------------------------
   Superadmin page par ab tak sirf naam, validity aur status dikhta tha. Isse ye pata hi
   nahi chalta tha ki KAUN SA GRAHAK SACH ME ISTEMAAL KAR RAHA HAI. Pan-India me 50 pump
   ho jayenge to sabse zaroori sawaal yahi hoga - kaun chhodne wala hai, kise call karna
   hai, aur kis trial ko badhane ka matlab hai.

   Ab har tenant ke saath: aakhri login kab hua, aakhri entry kab hui, is mahine kitni
   bikri, aur kitne din baaki. "Aakhri entry" sabse kaam ki cheez hai - login to koi
   kabhi bhi kar leta hai, par entry na ho to grahak sach me chhod chuka hai.
   ========================================================================================== */
CREATE OR ALTER PROCEDURE PUMP.sp_Owner_GetList
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @MonthStart DATE = DATEFROMPARTS(YEAR(SYSDATETIME()), MONTH(SYSDATETIME()), 1);

    SELECT
        o.Id, o.Name, o.IsActive, o.CreatedOn,
        o.ValidUpto, o.ContactName, o.ContactNo, o.Email, o.City, o.StateCode,
        o.GSTIN, o.PlanCode, o.IsTrial,

        PumpCount = (SELECT COUNT(*) FROM PUMP.Pumps p
                     WHERE p.OwnerId = o.Id AND ISNULL(p.IsDeleted,0) = 0),
        UserCount = (SELECT COUNT(*) FROM PUMP.Users u
                     WHERE u.OwnerId = o.Id AND ISNULL(u.IsDeleted,0) = 0),
        DaysLeft  = DATEDIFF(DAY, CAST(SYSDATETIME() AS DATE), o.ValidUpto),

        /* Aakhri kaamyaab login. LoginAttempts username se judti hai, OwnerId se
           nahi, isliye is owner ke users ke through jaate hain. */
        LastLoginOn = (
            SELECT MAX(la.AttemptedOn)
            FROM PUMP.LoginAttempts la
            WHERE la.IsSuccess = 1
              AND la.Username IN (SELECT u.Username FROM PUMP.Users u WHERE u.OwnerId = o.Id)
        ),

        /* Aakhri ASLI kaam - bikri ya shift. Login se zyada ye batata hai ki
           grahak zinda hai ya nahi. */
        LastActivityOn = (
            SELECT MAX(x.D) FROM (
                SELECT MAX(sh.BillDateTime) AS D FROM PUMP.SalesHeaders sh WHERE sh.OwnerId = o.Id
                UNION ALL
                SELECT CAST(MAX(s.ShiftDate) AS DATETIME2) FROM PUMP.ShiftHeaders s WHERE s.OwnerId = o.Id
            ) x
        ),

        SalesThisMonth = ISNULL((
            SELECT SUM(sh.TotalAmount)
            FROM PUMP.SalesHeaders sh
            WHERE sh.OwnerId = o.Id
              AND sh.IsVoid = 0
              AND CAST(sh.BillDateTime AS DATE) >= @MonthStart
        ), 0)

    FROM PUMP.Owners o
    WHERE ISNULL(o.IsDeleted, 0) = 0
      /* '-- SYSTEM --' asli grahak nahi hai. Wo sirf isliye banaya gaya hai ki
         'superadmin' user ko ek OwnerId chahiye (Users.OwnerId ka FK). Use tenant
         ki list me dikhane ka matlab nahi — na uska trial badhta hai, na wo
         suspend hota hai. */
      AND o.Name <> N'-- SYSTEM --'
    ORDER BY o.Id DESC;
END
GO

/* ---- G18.1 Kisi tenant ke users - password reset ke liye ----
   Grahak ka phone aata hai "password bhool gaya" - superadmin ko us tenant ke
   users chahiye taaki sahi wale ka password reset kar sake. */
CREATE OR ALTER PROCEDURE PUMP.sp_Owner_GetUsers
(
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        u.Id, u.FullName, u.Username, u.Mobile, u.IsActive, u.IsOwner,
        RoleName = ISNULL((SELECT TOP 1 r.Name
                           FROM PUMP.UserRoles ur
                           JOIN PUMP.Roles r ON r.Id = ur.RoleId
                           WHERE ur.UserId = u.Id), N'-'),
        LastLoginOn = (SELECT MAX(la.AttemptedOn) FROM PUMP.LoginAttempts la
                       WHERE la.Username = u.Username AND la.IsSuccess = 1)
    FROM PUMP.Users u
    WHERE u.OwnerId = @OwnerId
      AND ISNULL(u.IsDeleted, 0) = 0
    ORDER BY u.IsOwner DESC, u.Id;
END
GO

PRINT '  + G18: superadmin ko ab aakhri login, aakhri entry aur mahine ki bikri dikhti hai';
GO

/* ==========================================================================================
   SECTION G19 - NOZZLE-WISE AADMI KA CASH HISAAB - 2026-09-04
   ------------------------------------------------------------------------------------------
   Har aadmi ka apna hisaab:

       Milna chahiye = Chhutta (float) + Uske nozzle ki meter sale - Uski parchi (udhaar/UPI)
       Kam/Zyada     = Jo diya - Jo milna chahiye

   Cash lena shift band karne se ALAG hai. Poore din ka cash raat me ek saath lena ho to
   bhi chalta hai - jitne row me CashReturned NULL hai, wo "baaki" me dikhte rehte hain.
   ========================================================================================== */

/* ---- G19.1 Kis nozzle par kaun, aur usse kitna chhutta ----
   Shift khulte waqt bhi set kar sakte hain, aur beech me aadmi badle to bhi. */
CREATE OR ALTER PROCEDURE PUMP.sp_ShiftNozzle_SetAttendant
(
    @ShiftId     BIGINT,
    @NozzleId    BIGINT,
    @EmployeeId  BIGINT = NULL,
    @FloatGiven  DECIMAL(18,2) = NULL,
    @UserId      BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @OwnerId BIGINT, @PumpId BIGINT;
    SELECT @OwnerId = OwnerId, @PumpId = PumpId
    FROM PUMP.ShiftHeaders WHERE Id = @ShiftId;

    IF @OwnerId IS NULL
        THROW 50110, 'Shift not found.', 1;

    /* Employee usi owner ka ho - id badal kar doosre pump ka aadmi na jud jaye. */
    IF @EmployeeId IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM PUMP.Employees
        WHERE Id = @EmployeeId AND OwnerId = @OwnerId AND ISNULL(IsDeleted, 0) = 0)
        THROW 50111, 'Employee not found, or the employee does not belong to your pump.', 1;

    /* Cash le liya gaya ho to aadmi/float badalna theek nahi - hisaab ulta ho jayega. */
    IF EXISTS (SELECT 1 FROM PUMP.ShiftNozzleReadings
               WHERE ShiftId = @ShiftId AND NozzleId = @NozzleId AND CashReturned IS NOT NULL)
        THROW 50112, 'Cash for this nozzle has already been collected. Remove that entry first.', 1;

    UPDATE PUMP.ShiftNozzleReadings
    SET EmployeeId = @EmployeeId,
        FloatGiven = ISNULL(@FloatGiven, FloatGiven),
        ModifiedBy = @UserId,
        ModifiedOn = SYSDATETIME()
    WHERE ShiftId = @ShiftId AND NozzleId = @NozzleId;

    IF @@ROWCOUNT = 0
        THROW 50113, 'This nozzle is not part of the shift.', 1;

    SELECT Result = 'OK';
END
GO

/* ---- G19.2 Kisi aadmi se cash lena ----
   Shift band karte waqt bhi, aur baad me kabhi bhi. */
CREATE OR ALTER PROCEDURE PUMP.sp_ShiftNozzle_CollectCash
(
    @ShiftId      BIGINT,
    @NozzleId     BIGINT,
    @CashReturned DECIMAL(18,2),
    @SlipsAmount  DECIMAL(18,2) = NULL,
    @Notes        NVARCHAR(250) = NULL,
    @UserId       BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @CashReturned < 0
        THROW 50114, 'Cash cannot be negative.', 1;

    DECLARE @OwnerId BIGINT, @PumpId BIGINT;
    SELECT @OwnerId = OwnerId, @PumpId = PumpId FROM PUMP.ShiftHeaders WHERE Id = @ShiftId;

    IF @OwnerId IS NULL
        THROW 50110, 'Shift not found.', 1;

    DECLARE @Sold DECIMAL(18,2), @Float DECIMAL(18,2), @Slips DECIMAL(18,2), @EmpId BIGINT;

    SELECT @Sold = ISNULL(SoldAmount, 0), @Float = ISNULL(FloatGiven, 0),
           @Slips = ISNULL(SlipsAmount, 0), @EmpId = EmployeeId
    FROM PUMP.ShiftNozzleReadings
    WHERE ShiftId = @ShiftId AND NozzleId = @NozzleId;

    IF @Sold IS NULL
        THROW 50113, 'This nozzle is not part of the shift.', 1;

    IF @SlipsAmount IS NOT NULL SET @Slips = @SlipsAmount;

    UPDATE PUMP.ShiftNozzleReadings
    SET CashReturned      = @CashReturned,
        SlipsAmount       = @Slips,
        CashCollectedOn   = SYSDATETIME(),
        CollectedByUserId = @UserId,
        CashNotes         = @Notes,
        ModifiedBy        = @UserId,
        ModifiedOn        = SYSDATETIME()
    WHERE ShiftId = @ShiftId AND NozzleId = @NozzleId;

    DECLARE @Expected DECIMAL(18,2) = @Float + @Sold - @Slips;
    DECLARE @Diff     DECIMAL(18,2) = @CashReturned - @Expected;

    DECLARE @AuditReason NVARCHAR(500) =
        CONCAT('Nozzle ', @NozzleId, ' se cash liya: Rs ', @CashReturned,
               ' (milna tha Rs ', @Expected, ', antar Rs ', @Diff, ')',
               ISNULL(' - ' + @Notes, ''));

    EXEC PUMP.sp_Audit_Log
        @OwnerId = @OwnerId, @PumpId = @PumpId, @UserId = @UserId,
        @EntityName = 'ShiftNozzleReadings', @EntityId = @ShiftId, @Action = 'COLLECT_CASH',
        @Reason = @AuditReason;

    SELECT Result = 'OK', ExpectedCash = @Expected, ShortExcess = @Diff;
END
GO

/* ---- G19.3 Galti se galat cash daal diya to hatao ---- */
CREATE OR ALTER PROCEDURE PUMP.sp_ShiftNozzle_UndoCollection
(
    @ShiftId  BIGINT,
    @NozzleId BIGINT,
    @UserId   BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @OwnerId BIGINT, @PumpId BIGINT, @Old DECIMAL(18,2);
    SELECT @OwnerId = OwnerId, @PumpId = PumpId FROM PUMP.ShiftHeaders WHERE Id = @ShiftId;
    SELECT @Old = CashReturned FROM PUMP.ShiftNozzleReadings
    WHERE ShiftId = @ShiftId AND NozzleId = @NozzleId;

    UPDATE PUMP.ShiftNozzleReadings
    SET CashReturned = NULL, CashCollectedOn = NULL, CollectedByUserId = NULL,
        ModifiedBy = @UserId, ModifiedOn = SYSDATETIME()
    WHERE ShiftId = @ShiftId AND NozzleId = @NozzleId;

    DECLARE @AuditReason NVARCHAR(500) =
        CONCAT('Nozzle ', @NozzleId, ' ki cash entry hatai (pehle Rs ', ISNULL(@Old, 0), ')');

    EXEC PUMP.sp_Audit_Log
        @OwnerId = @OwnerId, @PumpId = @PumpId, @UserId = @UserId,
        @EntityName = 'ShiftNozzleReadings', @EntityId = @ShiftId, @Action = 'UNDO_COLLECT_CASH',
        @Reason = @AuditReason;

    SELECT Result = 'OK';
END
GO

/* ---- G19.4 Ek shift ka aadmi-wise hisaab ---- */
CREATE OR ALTER PROCEDURE PUMP.sp_ShiftNozzle_CashSummary
(
    @ShiftId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        snr.ShiftId,
        snr.NozzleId,
        NozzleCode   = n.NozzleCode,
        ProductName  = p.Name,
        snr.EmployeeId,
        EmployeeName = ISNULL(e.FullName, N'(koi nahi)'),
        snr.OpeningReading,
        snr.ClosingReading,
        snr.SoldQty,
        snr.Rate,
        MeterSale    = ISNULL(snr.SoldAmount, 0),
        snr.FloatGiven,
        snr.SlipsAmount,
        /* Jitna cash is aadmi ke paas hona chahiye. */
        ExpectedCash = ISNULL(snr.FloatGiven, 0) + ISNULL(snr.SoldAmount, 0) - ISNULL(snr.SlipsAmount, 0),
        snr.CashReturned,
        ShortExcess  = CASE WHEN snr.CashReturned IS NULL THEN NULL
                            ELSE snr.CashReturned
                                 - (ISNULL(snr.FloatGiven, 0) + ISNULL(snr.SoldAmount, 0) - ISNULL(snr.SlipsAmount, 0))
                       END,
        snr.CashCollectedOn,
        snr.CashNotes,
        IsCollected  = CAST(CASE WHEN snr.CashReturned IS NULL THEN 0 ELSE 1 END AS BIT)
    FROM PUMP.ShiftNozzleReadings snr
    JOIN PUMP.Nozzles  n ON n.Id = snr.NozzleId
    JOIN PUMP.Products p ON p.Id = snr.ProductId
    LEFT JOIN PUMP.Employees e ON e.Id = snr.EmployeeId
    WHERE snr.ShiftId = @ShiftId
    ORDER BY n.NozzleCode;
END
GO

/* ---- G19.5 Jitna cash abhi tak nahi liya - saari shift ka ----
   Yahi wo screen hai jab poore din ka cash raat me ek saath liya jaata hai. */
CREATE OR ALTER PROCEDURE PUMP.sp_ShiftNozzle_PendingCash
(
    @OwnerId  BIGINT,
    @PumpId   BIGINT = NULL,
    @FromDate DATE = NULL,
    @ToDate   DATE = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        sh.Id AS ShiftId,
        sh.ShiftDate,
        sh.ShiftCode,
        sh.Status,
        snr.NozzleId,
        NozzleCode   = n.NozzleCode,
        ProductName  = p.Name,
        snr.EmployeeId,
        EmployeeName = ISNULL(e.FullName, N'(koi nahi)'),
        EmployeeMobile = e.Mobile,
        MeterSale    = ISNULL(snr.SoldAmount, 0),
        snr.FloatGiven,
        snr.SlipsAmount,
        ExpectedCash = ISNULL(snr.FloatGiven, 0) + ISNULL(snr.SoldAmount, 0) - ISNULL(snr.SlipsAmount, 0),
        DaysPending  = DATEDIFF(DAY, sh.ShiftDate, CAST(SYSDATETIME() AS DATE))
    FROM PUMP.ShiftNozzleReadings snr
    JOIN PUMP.ShiftHeaders sh ON sh.Id = snr.ShiftId
    JOIN PUMP.Nozzles  n ON n.Id = snr.NozzleId
    JOIN PUMP.Products p ON p.Id = snr.ProductId
    LEFT JOIN PUMP.Employees e ON e.Id = snr.EmployeeId
    WHERE sh.OwnerId = @OwnerId
      AND (@PumpId IS NULL OR @PumpId <= 0 OR sh.PumpId = @PumpId)
      AND snr.CashReturned IS NULL
      /* SABSE ZAROORI SHART: ye hisaab tabhi maanga jaye jab pump ne is nozzle par
         ye tareeka istemaal kiya ho - yaani aadmi lagaya ho YA chhutta diya ho.

         Bahut se pump sirf purane tareeke se chalte hain: shift ka ek opening cash,
         ek closing cash, aur bas. Un par har nozzle ki row yahan aa jaati thi
         "(koi nahi)" ke naam se, aur KABHI HATTI NAHI - kyunki cash to nozzle-wise
         liya hi nahi jaata. Roz do-teen row judti jaati aur screen bhar jaati.

         Ab: aadmi bhi nahi aur chhutta bhi nahi = ye pump nozzle-wise cash nahi
         chala raha, to usse kuch mat poocho. */
      AND (snr.EmployeeId IS NOT NULL OR ISNULL(snr.FloatGiven, 0) > 0)
      AND (@FromDate IS NULL OR sh.ShiftDate >= @FromDate)
      AND (@ToDate   IS NULL OR sh.ShiftDate <= @ToDate)
    ORDER BY sh.ShiftDate, sh.Id, n.NozzleCode;
END
GO

/* ---- G19.6 Aadmi-wise hisaab, tareekh ki range me ----
   "Is mahine kis aadmi ka kitna kam pada" - yahi sabse zyada dekha jaata hai. */
CREATE OR ALTER PROCEDURE PUMP.sp_Report_AttendantCash
(
    @OwnerId  BIGINT,
    @PumpId   BIGINT = NULL,
    @FromDate DATE,
    @ToDate   DATE
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        EmployeeId   = snr.EmployeeId,
        EmployeeName = ISNULL(e.FullName, N'(koi nahi)'),
        Shifts       = COUNT(DISTINCT snr.ShiftId),
        TotalMeterSale = SUM(ISNULL(snr.SoldAmount, 0)),
        TotalFloat     = SUM(ISNULL(snr.FloatGiven, 0)),
        TotalSlips     = SUM(ISNULL(snr.SlipsAmount, 0)),
        TotalExpected  = SUM(ISNULL(snr.FloatGiven, 0) + ISNULL(snr.SoldAmount, 0) - ISNULL(snr.SlipsAmount, 0)),
        TotalReturned  = SUM(ISNULL(snr.CashReturned, 0)),
        /* Sirf un shift ka antar jinka cash liya ja chuka hai - jo baaki hai
           use "kam pada" mein ginna galat hoga. */
        TotalShortExcess = SUM(CASE WHEN snr.CashReturned IS NULL THEN 0
                                    ELSE snr.CashReturned
                                         - (ISNULL(snr.FloatGiven, 0) + ISNULL(snr.SoldAmount, 0) - ISNULL(snr.SlipsAmount, 0))
                               END),
        PendingCount   = SUM(CASE WHEN snr.CashReturned IS NULL THEN 1 ELSE 0 END),
        PendingAmount  = SUM(CASE WHEN snr.CashReturned IS NULL
                                  THEN ISNULL(snr.FloatGiven, 0) + ISNULL(snr.SoldAmount, 0) - ISNULL(snr.SlipsAmount, 0)
                                  ELSE 0 END)
    FROM PUMP.ShiftNozzleReadings snr
    JOIN PUMP.ShiftHeaders sh ON sh.Id = snr.ShiftId
    LEFT JOIN PUMP.Employees e ON e.Id = snr.EmployeeId
    WHERE sh.OwnerId = @OwnerId
      AND (@PumpId IS NULL OR @PumpId <= 0 OR sh.PumpId = @PumpId)
      AND sh.ShiftDate BETWEEN @FromDate AND @ToDate
      /* Sirf wahi row jinme ye tareeka istemaal hua. Warna purane tareeke se
         chalne wale pump ki report me "(koi nahi)" ki ek bekaar line aa jaati. */
      AND (snr.EmployeeId IS NOT NULL OR ISNULL(snr.FloatGiven, 0) > 0)
    GROUP BY snr.EmployeeId, e.FullName
    ORDER BY TotalShortExcess;
END
GO

/* ---- G19.7 Menu ---- */
IF NOT EXISTS (SELECT 1 FROM PUMP.Menus WHERE Route = '/nozzle-cash')
BEGIN
    DECLARE @AfterSeq INT = ISNULL((SELECT Sequence FROM PUMP.Menus WHERE Route = '/shift'), 6);

    UPDATE PUMP.Menus SET Sequence = Sequence + 2
    WHERE Sequence > @AfterSeq AND ParentId IS NULL;

    INSERT INTO PUMP.Menus (ParentId, MenuName, Route, Icon, Sequence, IsVisible, IsActive)
    VALUES (NULL, N'Nozzle Cash', '/nozzle-cash', N'cash-stack', @AfterSeq + 1, 1, 1),
           (NULL, N'Attendant Cash', '/attendant-cash', N'person-badge', @AfterSeq + 2, 1, 1);

    /* Jis role ke paas shift ka access hai usi ko cash wali screen bhi -
       cash lena shift ke saath hi hota hai. */
    INSERT INTO PUMP.RoleMenus (RoleId, MenuId, CanView, CanCreate, CanEdit, CanDelete)
    SELECT rm.RoleId, m2.Id, rm.CanView, rm.CanCreate, rm.CanEdit, 0
    FROM PUMP.RoleMenus rm
    JOIN PUMP.Menus m ON m.Id = rm.MenuId AND m.Route = '/shift'
    CROSS JOIN PUMP.Menus m2
    WHERE m2.Route IN ('/nozzle-cash', '/attendant-cash')
      AND NOT EXISTS (SELECT 1 FROM PUMP.RoleMenus x WHERE x.RoleId = rm.RoleId AND x.MenuId = m2.Id);
END
GO

PRINT '  + G19: nozzle-wise aadmi ka cash hisaab (float, parchi, jama, kam/zyada)';
GO

/* ==========================================================================================
   SECTION G20 - GALAT TANK ME GALAT TEL NA CHADHE - 2026-09-04
   ------------------------------------------------------------------------------------------
   Purchase ki entry me Tank ki list me SAARE tank dikhte the, chahe product koi bhi
   chuna ho. Aur SP me koi jaanch nahi thi. Nateeja: Diesel chunkar Petrol ka tank
   chunne par 5,000 litre diesel PETROL ke tank me chadh jaata tha - aur HTTP 200 aata
   tha, koi shikayat nahi.

   Test me exactly yahi hua: diesel ki purchase ke baad Petrol tank 0 se 5,000 ho gaya
   aur Diesel tank 0 hi raha.

   Ye sirf ek galat number nahi hai - poora stock ledger bigad jaata hai:
   - Petrol ka DSR ek jhoothi "Receipt" dikhata hai jo kabhi aayi hi nahi
   - Diesel ka stock kabhi badhta hi nahi, to uska variance roz badhta jaata hai
   - Reconciliation karne wale ko kabhi samajh nahi aata ki galti kahan hui

   Nozzle par ye jaanch pehle se thi (THROW 50062) - purchase chhoot gaya tha.
   Ab wahi jaanch yahan bhi: tank usi product ka hona chahiye jiska tel aaya hai.
   ========================================================================================== */
CREATE OR ALTER PROCEDURE [PUMP].[sp_Purchase_SaveDetail]
(
    @PurchaseHeaderId BIGINT,
    @ProductId        BIGINT,
    @TankId           BIGINT = NULL,
    @Quantity         DECIMAL(18,3),
    @Rate             DECIMAL(18,2),
    /* C# ye bhi bhejta hai. Bhale hi hum khud Quantity x Rate se nikaal lete hain,
       parameter list se hatane par "too many arguments" ki error aati hai. */
    @Amount           DECIMAL(18,2) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Bharosa apni ginti par - client jo bheje. */
    SET @Amount = @Quantity * @Rate;

    DECLARE @OwnerId BIGINT, @PumpId BIGINT, @InvoiceDate DATE;
    SELECT @OwnerId = OwnerId, @PumpId = PumpId, @InvoiceDate = InvoiceDate
    FROM PUMP.PurchaseHeaders
    WHERE Id = @PurchaseHeaderId;

    /* Tank usi product ka hona chahiye jiska tel aaya hai. Iske bina diesel
       petrol ke tank me chadh jaata tha (aur 200 OK milta tha). */
    IF @TankId IS NOT NULL AND @TankId > 0
    BEGIN
        IF NOT EXISTS (
            SELECT 1 FROM PUMP.Tanks
            WHERE Id = @TankId
              AND ProductId = @ProductId
              AND (@OwnerId IS NULL OR OwnerId = @OwnerId)
              AND (@PumpId  IS NULL OR PumpId  = @PumpId)
        )
            THROW 50120, 'The selected tank does not hold this product. Pick the tank that stores this fuel.', 1;
    END

    INSERT INTO PUMP.PurchaseDetails (PurchaseHeaderId, ProductId, TankId, Quantity, Rate, Amount)
    VALUES (@PurchaseHeaderId, @ProductId, @TankId, @Quantity, @Rate, @Amount);

    IF @TankId IS NOT NULL AND @TankId > 0
    BEGIN
        UPDATE PUMP.Tanks
        SET CurrentStock = CurrentStock + @Quantity,
            UpdatedOn    = SYSDATETIME()
        WHERE Id = @TankId;

        /* Purchase tank ledger me bhi jaati hai (G12) - warna DSR ka Receipt
           column khaali rehta aur mahine ka opening galat ban jaata. */
        IF @OwnerId IS NOT NULL AND @PumpId IS NOT NULL
        BEGIN
            INSERT INTO PUMP.TankTransactions
                (OwnerId, PumpId, TankId, TxnType, Quantity, ReferenceNo, Notes, TxnDateTime)
            VALUES
                (@OwnerId, @PumpId, @TankId, 'PURCHASE', @Quantity,
                 CONCAT('PURCHASE-', @PurchaseHeaderId), 'Auto entry from purchase',
                 ISNULL(CAST(@InvoiceDate AS DATETIME2), SYSDATETIME()));
        END
    END
END
GO

PRINT '  + G20: purchase ab galat tank me tel nahi chadhne deti (THROW 50120)';
GO

/* ==========================================================================================
   SECTION G21 - AADMI AUR CHHUTTA SHIFT KHULTE WAQT HI - 2026-09-04
   ------------------------------------------------------------------------------------------
   Shift kholne wale form me "Attendant" ka khaana pehle se tha, lekin wo kahin SAVE hi
   nahi hota tha - na ViewModel me property thi, na API request me. User aadmi chunta,
   submit karta, aur chunav chupchaap gayab ho jaata. Use pata bhi nahi chalta ki kyun
   nahi tika.

   Asli tareeka bhi yahi hai: aadmi aur chhutta SHIFT SHURU HOTE WAQT diya jaata hai -
   tabhi to wo nozzle sambhalta hai. Baad me badalna (aadmi bimar pad gaya, shift badal
   gayi) bhi ho sakta hai - uske liye sp_ShiftNozzle_SetAttendant pehle se hai, aur wo
   cash jama hone tak chalti hai.

   Ab sp_Shift_Open ke JSON me do aur cheezein aati hain: EmployeeId aur FloatGiven.
   Dono optional - jo pump ye tareeka nahi chalata uske liye kuch nahi badla.
   ========================================================================================== */
CREATE OR ALTER PROCEDURE PUMP.sp_Shift_Open
(
    @OwnerId            BIGINT,
    @PumpId             BIGINT,
    @OperatorUserId     BIGINT = NULL,
    @ShiftDate          DATE,
    @ShiftCode          NVARCHAR(30),
    @OpeningCash        DECIMAL(18,2) = 0,
    @Notes              NVARCHAR(500) = NULL,
    @NozzleReadingsJson NVARCHAR(MAX) = NULL,
    @UserId             BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF EXISTS (SELECT 1 FROM PUMP.ShiftHeaders
               WHERE OwnerId = @OwnerId AND PumpId = @PumpId AND Status = 'OPEN')
    BEGIN
        SELECT CAST(-1 AS BIGINT) AS Id;   -- pehle se ek shift khuli hai
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM PUMP.ShiftHeaders
               WHERE PumpId = @PumpId AND ShiftDate = @ShiftDate AND ShiftCode = @ShiftCode)
    BEGIN
        SELECT CAST(-3 AS BIGINT) AS Id;   -- isi din ka isi code ka shift already hai
        RETURN;
    END

    DECLARE @ShiftId BIGINT;

    BEGIN TRANSACTION;

        INSERT INTO PUMP.ShiftHeaders
            (OwnerId, PumpId, OperatorUserId, ShiftDate, ShiftCode, OpeningCash, Notes, OpenedOn, Status, CreatedBy)
        VALUES
            (@OwnerId, @PumpId, @OperatorUserId, @ShiftDate, @ShiftCode, @OpeningCash, @Notes, SYSDATETIME(), 'OPEN', @UserId);

        SET @ShiftId = CAST(SCOPE_IDENTITY() AS BIGINT);

        IF @NozzleReadingsJson IS NOT NULL AND ISJSON(@NozzleReadingsJson) = 1
        BEGIN
            INSERT INTO PUMP.ShiftNozzleReadings
                (OwnerId, PumpId, ShiftId, NozzleId, ProductId, OpeningReading, Rate,
                 EmployeeId, FloatGiven, CreatedBy)
            SELECT
                @OwnerId, @PumpId, @ShiftId,
                x.NozzleId,
                n.ProductId,                          -- nozzle master se lo, client se nahi
                ISNULL(x.OpeningReading, 0),
                /* Rate har nozzle ka apne product ka hai - ek pump par petrol, premium
                   petrol, diesel, premium diesel alag-alag rate par chal sakte hain.
                   Aur us DIN ka rate lena hai, aaj ka nahi. */
                PUMP.fn_ProductRateOnDate(n.ProductId,
                    DATEADD(HOUR, 23, CAST(@ShiftDate AS DATETIME2(7)))),

                /* Aadmi usi owner ka hona chahiye - id badal kar doosre pump ka
                   aadmi na jud jaye. Na mile to NULL (koi nahi lagaya). */
                (SELECT e.Id FROM PUMP.Employees e
                 WHERE e.Id = x.EmployeeId AND e.OwnerId = @OwnerId
                   AND ISNULL(e.IsDeleted, 0) = 0),

                ISNULL(x.FloatGiven, 0),
                @UserId
            FROM OPENJSON(@NozzleReadingsJson)
            WITH (NozzleId       BIGINT        '$.NozzleId',
                  OpeningReading DECIMAL(18,3) '$.OpeningReading',
                  EmployeeId     BIGINT        '$.EmployeeId',
                  FloatGiven     DECIMAL(18,2) '$.FloatGiven') x
            INNER JOIN PUMP.Nozzles  n ON n.Id = x.NozzleId
                                      AND n.PumpId = @PumpId
                                      AND n.OwnerId = @OwnerId
                                      AND n.IsActive = 1
                                      AND ISNULL(n.IsDeleted, 0) = 0
            INNER JOIN PUMP.Products p ON p.Id = n.ProductId
            WHERE ISNULL(x.NozzleId, 0) > 0;
        END

        /* Ek bhi nozzle na juda to shift KHAALI khul jaati thi - "safal" ka
           sandesh milta tha, lekin band karte waqt padhne ko kuch hota hi nahi aur
           us din ki bikri kabhi darj hi nahi hoti.
           Aisa tab hota hai jab bheje gaye nozzle isi pump ke na hon (multi-pump me
           galat pump ka nozzle chun liya), ya wo hata diye gaye hon. */
        IF NOT EXISTS (SELECT 1 FROM PUMP.ShiftNozzleReadings WHERE ShiftId = @ShiftId)
        BEGIN
            ROLLBACK TRANSACTION;
            THROW 50130, 'No nozzle could be added to this shift. Check that the nozzles belong to the selected pump and are active.', 1;
        END

        /* Nozzle ka tank map nahi hai to abhi hi bata do - shift close par pata chalna
           bahut der ho jaati hai. */
        IF EXISTS
        (
            SELECT 1
            FROM PUMP.ShiftNozzleReadings snr
            JOIN PUMP.Nozzles n ON n.Id = snr.NozzleId
            WHERE snr.ShiftId = @ShiftId
              AND n.TankId IS NULL
              AND (SELECT COUNT(*) FROM PUMP.Tanks t
                   WHERE t.PumpId = @PumpId AND t.ProductId = n.ProductId AND t.IsActive = 1) <> 1
        )
        BEGIN
            ROLLBACK TRANSACTION;
            THROW 50003, 'Some nozzles have no tank set (or the product has more than one tank). Pick a tank in the Nozzle master.', 1;
        END

    COMMIT TRANSACTION;

    SELECT @ShiftId AS Id;
END
GO

/* ---- G21.1 User manual ka menu ----
   Sabse neeche rakha hai (sequence 999) - roz ka kaam nahi hai, madad ke liye hai.
   Har role ko dikhta hai: manual padhne se kisi ka nuksaan nahi. */
IF NOT EXISTS (SELECT 1 FROM PUMP.Menus WHERE Route = '/manual')
BEGIN
    INSERT INTO PUMP.Menus (ParentId, MenuName, Route, Icon, Sequence, IsVisible, IsActive)
    VALUES (NULL, N'User Manual', '/manual', N'book', 999, 1, 1);

    DECLARE @ManualMenuId BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);

    INSERT INTO PUMP.RoleMenus (RoleId, MenuId, CanView, CanCreate, CanEdit, CanDelete)
    SELECT r.Id, @ManualMenuId, 1, 0, 0, 0
    FROM PUMP.Roles r
    WHERE NOT EXISTS (SELECT 1 FROM PUMP.RoleMenus x
                      WHERE x.RoleId = r.Id AND x.MenuId = @ManualMenuId);
END
GO

PRINT '  + G21: shift kholte waqt hi aadmi aur chhutta darj hote hain';
GO

/* ==========================================================================================
   SECTION H — HEALTH CHECK
   ------------------------------------------------------------------------------------------
   Script chalne ke baad ye report batati hai ki sab theek hai ya nahi, aur kya kaam
   aapko manually karna hai.
   ========================================================================================== */
PRINT '';
PRINT '===========================================================';
PRINT ' HEALTH CHECK';
PRINT '===========================================================';
GO

/* ---- H1. Object counts ---- */
SELECT
    Item  = 'Tables',
    Count = COUNT(*)
FROM sys.tables WHERE SCHEMA_NAME(schema_id) = 'PUMP'
UNION ALL
SELECT 'Stored procedures', COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'PUMP'
UNION ALL
SELECT 'Non-clustered indexes', COUNT(*) FROM sys.indexes i
    JOIN sys.tables t ON t.object_id = i.object_id
    WHERE SCHEMA_NAME(t.schema_id) = 'PUMP' AND i.type = 2
UNION ALL
SELECT 'Default constraints', COUNT(*) FROM sys.default_constraints dc
    JOIN sys.tables t ON t.object_id = dc.parent_object_id
    WHERE SCHEMA_NAME(t.schema_id) = 'PUMP'
UNION ALL
SELECT 'Foreign keys', COUNT(*) FROM sys.foreign_keys fk
    JOIN sys.tables t ON t.object_id = fk.parent_object_id
    WHERE SCHEMA_NAME(t.schema_id) = 'PUMP';
GO

/* ---- H2. NOT NULL columns jinme default nahi hai ----
   Ye wahi bug tha jisse fresh DB par har save fail hota tha. Ab khaali aana chahiye
   (ya sirf wo columns jo SP hamesha khud bhejta hai). */
SELECT
    Problem    = 'NOT NULL column without default',
    TableName  = t.name,
    ColumnName = c.name,
    DataType   = TYPE_NAME(c.user_type_id)
FROM sys.columns c
JOIN sys.tables  t ON t.object_id = c.object_id
WHERE SCHEMA_NAME(t.schema_id) = 'PUMP'
  AND c.is_nullable = 0
  AND c.is_identity = 0
  AND c.is_computed = 0
  AND c.default_object_id = 0
  AND c.name IN ('CreatedOn','UpdatedOn','TxnDateTime','EntryDateTime','BillDateTime',
                 'ReceiptDateTime','OpenedOn','IsActive','IsDeleted')
ORDER BY t.name, c.name;
GO

/* ---- H3. Nozzles jinka tank set nahi hai ----
   Inhe manually map karna padega. Jab tak map nahi hoga, in nozzles wali shift
   close nahi hogi (jaanbujh ke — warna stock galat ghatega). */
SELECT
    Problem    = 'Nozzle ka tank set nahi hai',
    NozzleId   = n.Id,
    Nozzle     = n.NozzleCode,
    PumpId     = n.PumpId,
    Product    = p.Name,
    TanksForThisProduct = (SELECT COUNT(*) FROM PUMP.Tanks t
                           WHERE t.PumpId = n.PumpId AND t.ProductId = n.ProductId AND t.IsActive = 1),
    Action     = 'Nozzle master me tank chunein'
FROM PUMP.Nozzles n
JOIN PUMP.Products p ON p.Id = n.ProductId
WHERE n.TankId IS NULL
  AND n.IsActive = 1
  AND ISNULL(n.IsDeleted, 0) = 0
  -- Gas (CNG) / charging ka tank hota hi nahi (Section AL) - wo galti nahi.
  AND p.Category NOT IN (N'CNG', N'ElectricCharging');
GO

/* ---- H4. Nozzle ka product aur tank ka product alag to nahi? ----
   Petrol ka nozzle diesel tank par laga ho to stock chup-chaap galat hota rahega. */
SELECT
    Problem      = 'Nozzle aur uske tank ka product alag hai',
    NozzleId     = n.Id,
    Nozzle       = n.NozzleCode,
    NozzleProduct= pn.Name,
    TankName     = t.Name,
    TankProduct  = pt.Name,
    Action       = 'Nozzle ka tank sahi karein'
FROM PUMP.Nozzles n
JOIN PUMP.Tanks    t  ON t.Id = n.TankId
JOIN PUMP.Products pn ON pn.Id = n.ProductId
JOIN PUMP.Products pt ON pt.Id = t.ProductId
WHERE n.ProductId <> t.ProductId
  AND ISNULL(n.IsDeleted, 0) = 0;
GO

/* ---- H5. Ek product ke ek se zyada tank ----
   Ye galat nahi hai — bilkul normal hai. Par purane sp_Shift_Close me isi se
   stock DOUBLE ghat raha tha. Ab fix ho gaya hai, ye sirf jaankari ke liye. */
SELECT
    Info      = 'Is product ke ek se zyada tank hain (ab sahi handle hota hai)',
    PumpId    = t.PumpId,
    Product   = p.Name,
    TankCount = COUNT(*),
    Tanks     = STRING_AGG(t.Name, ', ')
FROM PUMP.Tanks t
JOIN PUMP.Products p ON p.Id = t.ProductId
WHERE t.IsActive = 1 AND ISNULL(t.IsDeleted, 0) = 0
GROUP BY t.PumpId, p.Name
HAVING COUNT(*) > 1;
GO

/* ---- H6. Party balance vs ledger — drift check ----
   YAHAN SE HATA KAR file ke ant me (Section AF, AF6) rakha gaya hai — 2026-10-13.

   Ye jaanch baki ko SIRF khaate ke jod se milati thi. Jis party ko purane baki
   ke saath banaya gaya (live par 103 me se 96) wo sab "galat" dikhti thi, aur
   Action me likha tha "sp_Party_RecalculateBalance chalao" — jo us waqt purana
   baki mita deta. Sahi jaanch ko Parties.OpeningBalance chahiye, jo file ke ant
   me banta hai; isliye jaanch bhi wahin hai. */
PRINT '(H6 party-baki ki jaanch ab Section AF ke ant me hai)';
GO

/* ---- H7. Tank stock vs transactions — drift check ---- */
SELECT TOP 50
    Problem      = 'Tank ka CurrentStock transactions se match nahi karta',
    TankId       = t.Id,
    TankName     = t.Name,
    StoredStock  = t.CurrentStock,
    LedgerStock  = ISNULL(x.Qty, 0),
    Difference   = t.CurrentStock - ISNULL(x.Qty, 0),
    Action       = 'Purani entries se drift hai — reconcile karein'
FROM PUMP.Tanks t
OUTER APPLY
(
    SELECT Qty = SUM(CASE WHEN UPPER(tt.TxnType) = 'IN' THEN tt.Quantity ELSE -tt.Quantity END)
    FROM PUMP.TankTransactions tt WHERE tt.TankId = t.Id
) x
WHERE t.IsActive = 1
  AND ABS(t.CurrentStock - ISNULL(x.Qty, 0)) > 0.01;
GO

/* ---- H8. Owners jinki validity nikal chuki hai ---- */
SELECT
    Info      = 'Owner ki validity',
    OwnerId   = Id,
    OwnerName = Name,
    ValidUpto = ValidUpto,
    DaysLeft  = DATEDIFF(DAY, CAST(SYSDATETIME() AS DATE), ValidUpto),
    Status    = CASE WHEN ValidUpto IS NULL THEN 'NO VALIDITY SET'
                     WHEN ValidUpto < CAST(SYSDATETIME() AS DATE) THEN 'EXPIRED — login nahi hoga'
                     WHEN ValidUpto < DATEADD(DAY, 7, CAST(SYSDATETIME() AS DATE)) THEN 'EXPIRING SOON'
                     ELSE 'OK' END
FROM PUMP.Owners
WHERE ISNULL(IsDeleted, 0) = 0
ORDER BY ValidUpto;
GO

/* ---- H9. Plaintext password wale users ----
   AuthService.cs ka plaintext fallback hata diya gaya hai — ab sirf PBKDF2 hash se
   hi login hota hai. 6 seed/demo users (admin/manager/accountant/salesop/auditor/
   superadmin) upar migrate ho chuke hain. Agar phir bhi koi row yahan dikhe, uska
   password turant reset karayein — warna wo user login hi nahi kar payega. */
SELECT
    Problem  = 'Password hashed nahi hai (plaintext ya purana format) — is user ka login TOOT chuka hai',
    UserId   = Id,
    Username = Username,
    OwnerId  = OwnerId,
    Action   = 'Password reset karayein (naya PBKDF2 hash de dega)'
FROM PUMP.Users
WHERE PasswordHash NOT LIKE 'PBKDF2$%'
  AND IsActive = 1
  AND ISNULL(IsDeleted, 0) = 0;
GO

/* ---- H10. Stored procedures jinme OwnerId filter nahi hai ----
   Multi-tenant system me har SP ko OwnerId lena chahiye. Jinme nahi hai, wahan
   doosre owner ka data nikala ja sakta hai (agar Id guess ho jaye).

   DHYAN DEIN: ye report SECTION M se PEHLE chalti hai. Section M jin teen SP ko
   theek karta hai (sp_ShiftNozzle_CashSummary, sp_Product_GetRateOnDate,
   sp_Sales_SaveDetail) wo yahan PEHLI baar chalane par abhi bhi dikhenge —
   kyunki us waqt tak wo naye bane nahi hote. **Aakhri sach Section M ke ant me
   chhapne wali list hai** — wo khaali honi chahiye. Dobara chalane par yahan
   bhi khaali aayegi. */
PRINT '(Section M se pehle ki list — aakhri sach Section M ke ant me hai)';
SELECT
    Problem       = 'SP me OwnerId parameter nahi hai — tenant leak ka khatra',
    ProcedureName = 'PUMP.' + p.name,
    Action        = 'SP me @OwnerId add karke WHERE me lagayein'
FROM sys.procedures p
JOIN sys.sql_modules m ON m.object_id = p.object_id
WHERE SCHEMA_NAME(p.schema_id) = 'PUMP'
  AND p.name NOT LIKE 'sp_Auth%'
  AND p.name NOT LIKE 'sp_Owner%'
  AND p.name NOT LIKE 'sp_Menu%'
  AND p.name NOT LIKE 'sp_Role%'
  AND p.name NOT LIKE 'sp_Subscription%'
  AND p.name NOT LIKE 'sp_Payment%'
  AND p.name NOT LIKE 'sp_Login%'
  AND p.name NOT LIKE 'sp_Audit%'
  /* Section M dekhein: ye do bhi jaanbujh kar bina OwnerId ke hain —
     sp_RefreshToken% me token hash hi pehchaan hai, aur sp_PasswordReset%
     login se PEHLE chalta hai jab koi owner pata hi nahi hota. */
  AND p.name NOT LIKE 'sp_RefreshToken%'
  AND p.name NOT LIKE 'sp_PasswordReset%'
  AND p.name NOT LIKE 'sp_Master_Restore'
  AND m.definition NOT LIKE '%@OwnerId%'
ORDER BY p.name;
GO

PRINT '';
PRINT '===========================================================';
PRINT ' PPMS UPGRADE PACK v2.0 — done';
PRINT '';
PRINT ' Ab bhi jo kaam BAAKI hai (C# side, DB se nahi ho sakta):';
PRINT '   1. Program.cs:87 — login rate limiter ko per-IP/per-user partition karo.';
PRINT '   2. appsettings.json — DB password, JWT key, SMS key rotate karke env vars me.';
PRINT '   3. Client/Program.cs:25 — DangerousAcceptAnyServerCertificateValidator hatao.';
PRINT '   4. Client/Program.cs:8 — session ko Redis par le jao (2+ server ke liye).';
PRINT '   5. Nozzle DTO me TankId add karo (H3 report ke nozzles map karne ke liye).';
PRINT '===========================================================';
GO

/* ===========================================================================
   SECTION J — Employee <-> User ka rishta, aur pump ki deewar
   ---------------------------------------------------------------------------
   Employee aur User do alag cheezein hain aur alag hi rehni chahiye:

     Users     = LOGIN pehchaan. Owner-level (PumpId hai hi nahi). Isse role/menu
                 permission chalti hai aur ShiftHeaders.OperatorUserId judta hai.
     Employees = HR record. PUMP-level (PumpId NOT NULL). Isse salary
                 (SalaryPayments.EmployeeId) aur nozzle attendant
                 (ShiftNozzleReadings.EmployeeId) judta hai.

   Har user employee nahi hota (owner, superadmin, auditor, accountant) aur har
   employee ka login nahi hota (chowkidar, safai wala, helper). Isliye Employees
   me UserId NULL rehta hai — ye galti nahi, design hai.

   MULTI-PUMP ka niyam (sp_Employee_List PumpId par filter karta hai):
     Ek employee EK PUMP ka hota hai. Wahi aadmi doosre pump par bhi kaam karta
     hai to uska us pump par ALAG Employees row banega — alag EmployeeCode,
     alag MonthlySalary, alag JoinDate. Salary bhi us pump ke khaate se jaati
     hai. Ye jaanbujh ke hai: hisaab pump-wise saaf rehta hai.

     Lekin uska LOGIN ek hi rehta hai. Isliye neeche wala unique index
     (PumpId, UserId) par hai, sirf UserId par nahi — warna ek manager do pump
     par nahi jud paata.

   Ye section 4 chhed band karta hai jo test me mile:
     J1 — ek hi login se kai employee jud jaate the (koi constraint hi nahi tha)
     J2 — sp_Employee_Save doosre owner ka UserId chipka leta tha
     J3 — sp_ShiftNozzle_SetAttendant sirf OwnerId dekhta tha, PumpId nahi
     J4 — sp_SalaryPayment_Save employee ka owner/pump check hi nahi karta tha
   =========================================================================== */
GO

PRINT '';
PRINT '=== Section J: Employee <-> User rishta + pump ki deewar ===';
GO

/* ---- J1. Ek login, ek pump par ek hi employee -----------------------------
   Purana data: do alag aadmi (Id 5 aur 6) dono UserId 4 se jude the. Matlab
   do bande ek hi login share kar rahe the — shift kisne kholi, cash kisne
   diya, kuch pata nahi chalta. Purani link (sabse chhoti Id) rakhte hain,
   baaki hata dete hain. Jo hata, wo neeche list me aayega — use manually
   naya login dena padega. */

IF EXISTS (SELECT 1 FROM PUMP.Employees
           WHERE UserId IS NOT NULL AND ISNULL(IsDeleted, 0) = 0
           GROUP BY PumpId, UserId HAVING COUNT(*) > 1)
BEGIN
    SELECT
        Problem      = 'Ek hi login se kai employee jude the — link hata di gayi',
        e.Id, e.PumpId, e.EmployeeCode, e.FullName,
        ChhinaGayaUserId = e.UserId,
        Action       = 'Is employee ko naya login banakar dobara link karein'
    FROM PUMP.Employees e
    WHERE e.UserId IS NOT NULL
      AND ISNULL(e.IsDeleted, 0) = 0
      AND e.Id > (SELECT MIN(e2.Id) FROM PUMP.Employees e2
                  WHERE e2.PumpId = e.PumpId AND e2.UserId = e.UserId
                    AND ISNULL(e2.IsDeleted, 0) = 0)
    ORDER BY e.PumpId, e.UserId, e.Id;

    UPDATE e
    SET UserId = NULL, UpdatedOn = SYSDATETIME()
    FROM PUMP.Employees e
    WHERE e.UserId IS NOT NULL
      AND ISNULL(e.IsDeleted, 0) = 0
      AND e.Id > (SELECT MIN(e2.Id) FROM PUMP.Employees e2
                  WHERE e2.PumpId = e.PumpId AND e2.UserId = e.UserId
                    AND ISNULL(e2.IsDeleted, 0) = 0);

    PRINT '  * J1: duplicate employee-login link hata di (upar list dekhein)';
END
ELSE
    PRINT '  = J1: koi duplicate employee-login link nahi mili';
GO

/* Filtered index hai, isliye QUOTED_IDENTIFIER ON chahiye — sqlcmd me -I flag. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UX_Employees_PumpUser'
                 AND object_id = OBJECT_ID('PUMP.Employees'))
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX UX_Employees_PumpUser
        ON PUMP.Employees (PumpId, UserId)
        WHERE UserId IS NOT NULL AND IsDeleted = 0;
    PRINT '  + J1: UX_Employees_PumpUser bana (ek login = ek pump par ek employee)';
END
ELSE
    PRINT '  = J1: UX_Employees_PumpUser pehle se hai';
GO

/* ---- J2. sp_Employee_Save — linked login ki jaanch -------------------------
   Pehle @UserId bina kisi check ke chipka diya jaata tha. Request me doosre
   owner ka UserId bhej do to wo jud jaata tha — tenant ki deewar tut jaati.
   Ab teen jaanch hain: user maujood ho, usi owner ka ho, aur usi pump par
   kisi aur employee se pehle se juda na ho. */
CREATE OR ALTER PROCEDURE [PUMP].[sp_Employee_Save]
(
    @Id BIGINT = NULL,
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @UserId BIGINT = NULL,
    @EmployeeCode NVARCHAR(30),
    @FullName NVARCHAR(150),
    @Mobile NVARCHAR(20) = NULL,
    @JoinDate DATE,
    @Designation NVARCHAR(80) = NULL,
    @MonthlySalary DECIMAL(18,2) = 0,
    @IsActive BIT = 1
)
AS
BEGIN
    SET NOCOUNT ON;

    /* Login usi owner ka ho — id badal kar doosre tenant ka login na jud jaye. */
    IF @UserId IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM PUMP.Users
        WHERE Id = @UserId AND OwnerId = @OwnerId AND ISNULL(IsDeleted, 0) = 0)
        THROW 50150, 'Login user not found, or it does not belong to your account.', 1;

    /* Ek login is pump par sirf ek hi employee ka. Wahi aadmi doosre pump par
       hai to wahan alag row banegi — usme yahi UserId chalega, ye check us par
       nahi lagta (PumpId alag hai). */
    IF @UserId IS NOT NULL AND EXISTS (
        SELECT 1 FROM PUMP.Employees
        WHERE UserId = @UserId
          AND PumpId = @PumpId
          AND ISNULL(IsDeleted, 0) = 0
          AND Id <> ISNULL(@Id, 0))
        THROW 50151, 'This login is already linked to another employee on this pump.', 1;

    IF ISNULL(@Id, 0) = 0
    BEGIN
        INSERT INTO PUMP.Employees
        (
            OwnerId, PumpId, UserId, EmployeeCode, FullName, Mobile, JoinDate, Designation, MonthlySalary, IsActive
        )
        VALUES
        (
            @OwnerId, @PumpId, @UserId, @EmployeeCode, @FullName, @Mobile, @JoinDate, @Designation, @MonthlySalary, @IsActive
        );

        SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS Id;
        RETURN;
    END

    UPDATE PUMP.Employees
    SET UserId = @UserId,
        EmployeeCode = @EmployeeCode,
        FullName = @FullName,
        Mobile = @Mobile,
        JoinDate = @JoinDate,
        Designation = @Designation,
        MonthlySalary = @MonthlySalary,
        IsActive = @IsActive,
        UpdatedOn = SYSDATETIME()
    WHERE Id = @Id
      AND OwnerId = @OwnerId
      AND PumpId = @PumpId;

    SELECT @Id AS Id;
END
GO

/* ---- J3. sp_ShiftNozzle_SetAttendant — PumpId ki jaanch --------------------
   Comment kehta tha "doosre pump ka aadmi na jud jaye", par check sirf OwnerId
   par tha. @PumpId nikaala to jaata tha par use hi nahi hota tha. Nateeja:
   Pump A ka employee Pump B ke nozzle par lag sakta tha, aur uska cash Pump B
   ke hisaab me chala jaata. Ab PumpId bhi match hota hai. */
CREATE OR ALTER PROCEDURE PUMP.sp_ShiftNozzle_SetAttendant
(
    @ShiftId     BIGINT,
    @NozzleId    BIGINT,
    @EmployeeId  BIGINT = NULL,
    @FloatGiven  DECIMAL(18,2) = NULL,
    @UserId      BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @OwnerId BIGINT, @PumpId BIGINT;
    SELECT @OwnerId = OwnerId, @PumpId = PumpId
    FROM PUMP.ShiftHeaders WHERE Id = @ShiftId;

    IF @OwnerId IS NULL
        THROW 50110, 'Shift not found.', 1;

    /* Employee usi owner KA AUR USI PUMP ka ho. */
    IF @EmployeeId IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM PUMP.Employees
        WHERE Id = @EmployeeId
          AND OwnerId = @OwnerId
          AND PumpId = @PumpId
          AND ISNULL(IsDeleted, 0) = 0)
        THROW 50111, 'Employee not found, or the employee does not belong to your pump.', 1;

    /* Cash le liya gaya ho to aadmi/float badalna theek nahi - hisaab ulta ho jayega. */
    IF EXISTS (SELECT 1 FROM PUMP.ShiftNozzleReadings
               WHERE ShiftId = @ShiftId AND NozzleId = @NozzleId AND CashReturned IS NOT NULL)
        THROW 50112, 'Cash for this nozzle has already been collected. Remove that entry first.', 1;

    UPDATE PUMP.ShiftNozzleReadings
    SET EmployeeId = @EmployeeId,
        FloatGiven = ISNULL(@FloatGiven, FloatGiven),
        ModifiedBy = @UserId,
        ModifiedOn = SYSDATETIME()
    WHERE ShiftId = @ShiftId AND NozzleId = @NozzleId;

    IF @@ROWCOUNT = 0
        THROW 50113, 'This nozzle is not part of the shift.', 1;

    SELECT Result = 'OK';
END
GO

/* ---- J4. sp_SalaryPayment_Save — employee ka owner/pump check --------------
   Yahan @EmployeeId par koi jaanch hi nahi thi. Pump A ke aadmi ki salary
   Pump B ke khaate se nikal sakti thi, ya doosre owner ke employee ki bhi.
   Baaki poora SP waisa hi hai — sirf shuru me guard laga hai. */
CREATE OR ALTER PROCEDURE [PUMP].[sp_SalaryPayment_Save]
(
    @Id BIGINT = NULL,
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @EmployeeId BIGINT,
    @SalaryYear INT,
    @SalaryMonth INT,
    @Amount DECIMAL(18,2),
    @PaidOn DATE,
    @PaymentMode NVARCHAR(20) = 'Cash',
    @ReferenceNo NVARCHAR(60) = NULL,
    @Notes NVARCHAR(250) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    /* Salary usi pump ke employee ki hi ban sakti hai. */
    IF NOT EXISTS (
        SELECT 1 FROM PUMP.Employees
        WHERE Id = @EmployeeId
          AND OwnerId = @OwnerId
          AND PumpId = @PumpId
          AND ISNULL(IsDeleted, 0) = 0)
        THROW 50152, 'Employee not found, or the employee does not belong to this pump.', 1;

    DECLARE @ExistingId BIGINT;
    IF ISNULL(@Id, 0) = 0
    BEGIN
        SELECT TOP 1 @ExistingId = Id
        FROM PUMP.SalaryPayments
        WHERE OwnerId = @OwnerId
          AND PumpId = @PumpId
          AND EmployeeId = @EmployeeId
          AND SalaryYear = @SalaryYear
          AND SalaryMonth = @SalaryMonth;

        IF @ExistingId IS NOT NULL
        BEGIN
            SET @Id = @ExistingId;
        END
    END

    IF ISNULL(@Id, 0) = 0
    BEGIN
        INSERT INTO PUMP.SalaryPayments
        (
            OwnerId, PumpId, EmployeeId, SalaryYear, SalaryMonth, Amount, PaidOn, PaymentMode, ReferenceNo, Notes
        )
        VALUES
        (
            @OwnerId, @PumpId, @EmployeeId, @SalaryYear, @SalaryMonth, @Amount, @PaidOn, @PaymentMode, @ReferenceNo, @Notes
        );

        SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS Id;
        RETURN;
    END

    UPDATE PUMP.SalaryPayments
    SET EmployeeId = @EmployeeId,
        SalaryYear = @SalaryYear,
        SalaryMonth = @SalaryMonth,
        Amount = @Amount,
        PaidOn = @PaidOn,
        PaymentMode = @PaymentMode,
        ReferenceNo = @ReferenceNo,
        Notes = @Notes,
        UpdatedOn = SYSDATETIME()
    WHERE Id = @Id
      AND OwnerId = @OwnerId
      AND PumpId = @PumpId;

    SELECT @Id AS Id;
END
GO

/* ---- J5. Shift ka "aadmi" do jagah tha -> ab SECTION K me fix hai ----------
   Pehle:
     ShiftHeaders.OperatorUserId    -> PUMP.Users     (owner-level)
     ShiftNozzleReadings.EmployeeId -> PUMP.Employees (pump-level)

   Ek hi baat ("is shift ka zimmedar kaun") do alag master se judi thi, isliye
   "shift kisne kholi" aur "nozzle par kaun tha" wali report kabhi match nahi
   karti thi.

   Ye ab neeche SECTION K me fix ho jaata hai — wahan ShiftHeaders me
   OperatorEmployeeId column banta hai, purana data migrate hota hai, aur
   sp_Shift_Open us employee se OperatorUserId khud bhar deta hai. Yahan sirf
   ginti chhod rahe hain; Section K ka apna report batata hai ki kitni purani
   shift jud nahi paayi. */
PRINT '  i J5: shift ke in-charge ka fix Section K me hai (neeche)';
GO

PRINT '=== Section J done ===';
GO

/* ===========================================================================
   SECTION K — Shift ka "aadmi" ab ek hi jagah se: Employees
   ---------------------------------------------------------------------------
   Section J5 me ye problem report ki thi. Ab fix kar rahe hain.

   PEHLE:
     ShiftHeaders.OperatorUserId    -> PUMP.Users     (login, owner-level)
     ShiftNozzleReadings.EmployeeId -> PUMP.Employees (aadmi, pump-level)

   Ek hi baat — "is shift ka zimmedar kaun tha" — do alag master se judi thi.
   Iska seedha nuksaan UI me dikhta tha: Shift ka "In-charge" dropdown me
   OperationsController sirf wahi employee dikhata tha jinka login bana ho
   (`x.UserId is > 0`). Yaani chowkidar, helper, ya koi bhi bina-login wala
   aadmi shift ka in-charge ban hi nahi sakta tha — jabki nozzle par wahi aadmi
   attendant ban sakta tha. Do jagah do niyam.

   AB:
     ShiftHeaders.OperatorEmployeeId -> PUMP.Employees   <-- asli source
     ShiftHeaders.OperatorUserId     -> PUMP.Users       <-- saath me bharte
                                                             rehte hain taaki
                                                             purani reports na
                                                             tootein

   OperatorUserId ab khud nahi bharna padta — sp_Shift_Open use employee ke
   record se nikaal leta hai. Do column hain par SACH ek hi hai.
   =========================================================================== */
GO

PRINT '';
PRINT '=== Section K: shift ka in-charge ab Employees se ===';
GO

/* ---- K1. Naya column + FK + index ---------------------------------------- */
IF COL_LENGTH('PUMP.ShiftHeaders', 'OperatorEmployeeId') IS NULL
BEGIN
    ALTER TABLE PUMP.ShiftHeaders ADD OperatorEmployeeId BIGINT NULL;
    PRINT '  + K1: ShiftHeaders.OperatorEmployeeId column bana';
END
ELSE
    PRINT '  = K1: OperatorEmployeeId pehle se hai';
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_PUMP_ShiftHeaders_OperatorEmployee')
BEGIN
    ALTER TABLE PUMP.ShiftHeaders WITH CHECK
        ADD CONSTRAINT FK_PUMP_ShiftHeaders_OperatorEmployee
        FOREIGN KEY (OperatorEmployeeId) REFERENCES PUMP.Employees (Id);
    PRINT '  + K1: FK_PUMP_ShiftHeaders_OperatorEmployee laga';
END
ELSE
    PRINT '  = K1: FK pehle se hai';
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_ShiftHeaders_OperatorEmployee'
                 AND object_id = OBJECT_ID('PUMP.ShiftHeaders'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_ShiftHeaders_OperatorEmployee
        ON PUMP.ShiftHeaders (OperatorEmployeeId) WHERE OperatorEmployeeId IS NOT NULL;
    PRINT '  + K1: IX_ShiftHeaders_OperatorEmployee bana';
END
ELSE
    PRINT '  = K1: index pehle se hai';
GO

/* ---- K2. Purana data migrate ---------------------------------------------
   Har purani shift ka OperatorUserId dekh kar USI PUMP ka employee dhoondte
   hain. Mil gaya to jod dete hain. Nahi mila (jaise malik ne khud shift kholi,
   ya us login ka koi employee record hi nahi) to NULL hi rehta hai — wo galat
   nahi hai, uska matlab hai "in-charge koi employee nahi tha". */
UPDATE sh
SET sh.OperatorEmployeeId = e.Id
FROM PUMP.ShiftHeaders sh
JOIN PUMP.Employees e
  ON  e.UserId  = sh.OperatorUserId
  AND e.OwnerId = sh.OwnerId
  AND e.PumpId  = sh.PumpId
  AND ISNULL(e.IsDeleted, 0) = 0
WHERE sh.OperatorEmployeeId IS NULL
  AND sh.OperatorUserId IS NOT NULL;

PRINT '  * K2: ' + CAST(@@ROWCOUNT AS VARCHAR(20)) + ' purani shift ka in-charge employee se jod diya';
GO

/* Jo jud nahi paayi unki ginti — report ke liye, error nahi. */
SELECT
    Info = 'In shifts ka OperatorUserId hai par us pump par uska employee record nahi mila',
    Kitni = COUNT(*)
FROM PUMP.ShiftHeaders
WHERE OperatorUserId IS NOT NULL AND OperatorEmployeeId IS NULL;
GO

/* ---- K3. sp_Shift_Open — in-charge ab employee ----------------------------
   Do badlav:
     1. Naya @OperatorEmployeeId param. Owner AUR pump dono check hote hain.
        OperatorUserId ab khud isi employee se nikalta hai (purani reports chalti
        rahengi). Purana @OperatorUserId param abhi bhi le rahe hain taaki koi
        purana caller toote nahi — par wo tabhi use hota hai jab
        @OperatorEmployeeId na diya gaya ho.
     2. Nozzle attendant ka check: pehle sirf OwnerId dekhta tha (wahi J3 wala
        bug, yahan bhi tha) — ab PumpId bhi. Pump A ka aadmi Pump B ke nozzle
        par nahi lag sakta.
   Baaki poora SP jaisa tha waisa hi hai. */
CREATE OR ALTER PROCEDURE PUMP.sp_Shift_Open
(
    @OwnerId            BIGINT,
    @PumpId             BIGINT,
    @OperatorUserId     BIGINT = NULL,
    @ShiftDate          DATE,
    @ShiftCode          NVARCHAR(30),
    @OpeningCash        DECIMAL(18,2) = 0,
    @Notes              NVARCHAR(500) = NULL,
    @NozzleReadingsJson NVARCHAR(MAX) = NULL,
    @UserId             BIGINT = NULL,
    @OperatorEmployeeId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF EXISTS (SELECT 1 FROM PUMP.ShiftHeaders
               WHERE OwnerId = @OwnerId AND PumpId = @PumpId AND Status = 'OPEN')
    BEGIN
        SELECT CAST(-1 AS BIGINT) AS Id;   -- pehle se ek shift khuli hai
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM PUMP.ShiftHeaders
               WHERE PumpId = @PumpId AND ShiftDate = @ShiftDate AND ShiftCode = @ShiftCode)
    BEGIN
        SELECT CAST(-3 AS BIGINT) AS Id;   -- isi din ka isi code ka shift already hai
        RETURN;
    END

    /* In-charge usi owner ka aur USI PUMP ka employee ho. */
    IF @OperatorEmployeeId IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM PUMP.Employees
        WHERE Id = @OperatorEmployeeId
          AND OwnerId = @OwnerId
          AND PumpId = @PumpId
          AND ISNULL(IsDeleted, 0) = 0)
        THROW 50153, 'Shift in-charge not found, or that employee does not belong to this pump.', 1;

    /* OperatorUserId ab employee ke record se aata hai — sach ek hi jagah rahe.
       Employee na diya ho to purana param hi chalega (backward compatible). */
    IF @OperatorEmployeeId IS NOT NULL
        SELECT @OperatorUserId = UserId FROM PUMP.Employees WHERE Id = @OperatorEmployeeId;

    DECLARE @ShiftId BIGINT;

    BEGIN TRANSACTION;

        INSERT INTO PUMP.ShiftHeaders
            (OwnerId, PumpId, OperatorUserId, OperatorEmployeeId, ShiftDate, ShiftCode, OpeningCash, Notes, OpenedOn, Status, CreatedBy)
        VALUES
            (@OwnerId, @PumpId, @OperatorUserId, @OperatorEmployeeId, @ShiftDate, @ShiftCode, @OpeningCash, @Notes, SYSDATETIME(), 'OPEN', @UserId);

        SET @ShiftId = CAST(SCOPE_IDENTITY() AS BIGINT);

        IF @NozzleReadingsJson IS NOT NULL AND ISJSON(@NozzleReadingsJson) = 1
        BEGIN
            INSERT INTO PUMP.ShiftNozzleReadings
                (OwnerId, PumpId, ShiftId, NozzleId, ProductId, OpeningReading, Rate,
                 EmployeeId, FloatGiven, CreatedBy)
            SELECT
                @OwnerId, @PumpId, @ShiftId,
                x.NozzleId,
                n.ProductId,                          -- nozzle master se lo, client se nahi
                ISNULL(x.OpeningReading, 0),
                /* Rate har nozzle ka apne product ka hai - ek pump par petrol, premium
                   petrol, diesel, premium diesel alag-alag rate par chal sakte hain.
                   Aur us DIN ka rate lena hai, aaj ka nahi. */
                PUMP.fn_ProductRateOnDate(n.ProductId,
                    DATEADD(HOUR, 23, CAST(@ShiftDate AS DATETIME2(7)))),

                /* Aadmi usi owner KA AUR USI PUMP ka hona chahiye - id badal kar
                   doosre pump ka aadmi na jud jaye. Na mile to NULL. */
                (SELECT e.Id FROM PUMP.Employees e
                 WHERE e.Id = x.EmployeeId
                   AND e.OwnerId = @OwnerId
                   AND e.PumpId  = @PumpId
                   AND ISNULL(e.IsDeleted, 0) = 0),

                ISNULL(x.FloatGiven, 0),
                @UserId
            FROM OPENJSON(@NozzleReadingsJson)
            WITH (NozzleId       BIGINT        '$.NozzleId',
                  OpeningReading DECIMAL(18,3) '$.OpeningReading',
                  EmployeeId     BIGINT        '$.EmployeeId',
                  FloatGiven     DECIMAL(18,2) '$.FloatGiven') x
            INNER JOIN PUMP.Nozzles  n ON n.Id = x.NozzleId
                                      AND n.PumpId = @PumpId
                                      AND n.OwnerId = @OwnerId
                                      AND n.IsActive = 1
                                      AND ISNULL(n.IsDeleted, 0) = 0
            INNER JOIN PUMP.Products p ON p.Id = n.ProductId
            WHERE ISNULL(x.NozzleId, 0) > 0;
        END

        /* Ek bhi nozzle na juda to shift KHAALI khul jaati thi - "safal" ka
           sandesh milta tha, lekin band karte waqt padhne ko kuch hota hi nahi aur
           us din ki bikri kabhi darj hi nahi hoti.
           Aisa tab hota hai jab bheje gaye nozzle isi pump ke na hon (multi-pump me
           galat pump ka nozzle chun liya), ya wo hata diye gaye hon. */
        IF NOT EXISTS (SELECT 1 FROM PUMP.ShiftNozzleReadings WHERE ShiftId = @ShiftId)
        BEGIN
            ROLLBACK TRANSACTION;
            THROW 50130, 'No nozzle could be added to this shift. Check that the nozzles belong to the selected pump and are active.', 1;
        END

        /* Nozzle ka tank map nahi hai to abhi hi bata do - shift close par pata chalna
           bahut der ho jaati hai. */
        IF EXISTS
        (
            SELECT 1
            FROM PUMP.ShiftNozzleReadings snr
            JOIN PUMP.Nozzles n ON n.Id = snr.NozzleId
            WHERE snr.ShiftId = @ShiftId
              AND n.TankId IS NULL
              AND (SELECT COUNT(*) FROM PUMP.Tanks t
                   WHERE t.PumpId = @PumpId AND t.ProductId = n.ProductId AND t.IsActive = 1) <> 1
        )
        BEGIN
            ROLLBACK TRANSACTION;
            THROW 50003, 'Some nozzles have no tank set (or the product has more than one tank). Pick a tank in the Nozzle master.', 1;
        END

    COMMIT TRANSACTION;

    SELECT @ShiftId AS Id;
END
GO

/* ---- K4. sp_Shift_List — naam ab Employees se ----------------------------
   OperatorName pehle Users.FullName se aata tha. Ab Employees se aata hai;
   purani shift (jinka employee link nahi bana) ke liye Users par fallback hai
   taaki list me naam khaali na dikhe.

   NOTE (CLAUDE.md niyam 5): yahan naya column OperatorEmployeeId add hua hai,
   isliye ShiftRepository.ShiftRow record me bhi wahi param add kiya gaya hai —
   warna Dapper positional record ko bana nahi paata. */
CREATE OR ALTER PROCEDURE [PUMP].[sp_Shift_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT = NULL,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @SearchTerm NVARCHAR(100) = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 50
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Offset INT = (@PageNumber - 1) * @PageSize;

    ;WITH ShiftBase AS
    (
        SELECT
            sh.Id,
            sh.OwnerId,
            sh.PumpId,
            sh.OperatorUserId,
            sh.OperatorEmployeeId,
            OperatorName = COALESCE(e.FullName, u.FullName),
            sh.ShiftDate,
            sh.ShiftCode,
            sh.OpeningCash,
            sh.ClosingCash,
            sh.Notes,
            sh.OpenedOn,
            sh.ClosedOn,
            sh.Status
        FROM PUMP.ShiftHeaders sh
        LEFT JOIN PUMP.Employees e ON e.Id = sh.OperatorEmployeeId
        LEFT JOIN PUMP.Users     u ON u.Id = sh.OperatorUserId
        WHERE sh.OwnerId = @OwnerId
          AND (@PumpId IS NULL OR @PumpId <= 0 OR sh.PumpId = @PumpId)
          AND (@FromDate IS NULL OR sh.ShiftDate >= @FromDate)
          AND (@ToDate IS NULL OR sh.ShiftDate <= @ToDate)
          AND (@SearchTerm IS NULL OR @SearchTerm = '' OR sh.ShiftCode LIKE '%' + @SearchTerm + '%' OR sh.Notes LIKE '%' + @SearchTerm + '%')
    )
    SELECT
        b.Id,
        b.OwnerId,
        b.PumpId,
        b.OperatorUserId,
        b.OperatorEmployeeId,
        b.OperatorName,
        b.ShiftDate,
        b.ShiftCode,
        b.OpeningCash,
        b.ClosingCash,
        TotalSoldQty = ISNULL(snr.TotalSoldQty, 0),
        TotalSoldAmount = ISNULL(snr.TotalSoldAmount, 0),
        b.Notes,
        b.OpenedOn,
        b.ClosedOn,
        b.Status
    FROM ShiftBase b
    OUTER APPLY
    (
        SELECT
            SUM(ISNULL(x.SoldQty, 0)) AS TotalSoldQty,
            SUM(ISNULL(x.SoldAmount, 0)) AS TotalSoldAmount
        FROM PUMP.ShiftNozzleReadings x
        WHERE x.ShiftId = b.Id
    ) snr
    ORDER BY b.Id DESC
    OFFSET @Offset ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(1)
    FROM PUMP.ShiftHeaders sh
    WHERE sh.OwnerId = @OwnerId
      AND (@PumpId IS NULL OR @PumpId <= 0 OR sh.PumpId = @PumpId)
      AND (@FromDate IS NULL OR sh.ShiftDate >= @FromDate)
      AND (@ToDate IS NULL OR sh.ShiftDate <= @ToDate)
      AND (@SearchTerm IS NULL OR @SearchTerm = '' OR sh.ShiftCode LIKE '%' + @SearchTerm + '%' OR sh.Notes LIKE '%' + @SearchTerm + '%');
END
GO

PRINT '=== Section K done ===';
GO

/* ===========================================================================
   SECTION L — sp_User_Save ka fix, aur ek hi form se Staff (employee + login)
   ---------------------------------------------------------------------------
   L1 me jo bug fix ho raha hai wo LIVE JAANE SE PEHLE hi pakadna zaroori tha:

     UserService.cs password na badla ho to literal '***UNCHANGED***' bhejti hai,
     aur comment me likha hai "The stored procedure should detect this and skip
     updating PasswordHash". Lekin sp_User_Save me aisa koi check tha hi nahi —
     wo seedha PasswordHash = '***UNCHANGED***' likh deta tha.

     Nateeja: kisi user ka naam/mobile/role edit karo (password khaali chhod do)
     aur us aadmi ka login HAMESHA ke liye band. Password hash ki jagah wo
     placeholder pada rehta, jo kisi bhi password se match nahi karta. Test DB
     par chalake dekha — PasswordHash sach me '***UNCHANGED***' ho gaya tha.

   L2 me ek hi form se employee + login banane wala sp_Staff_Save hai.
   =========================================================================== */
GO

PRINT '';
PRINT '=== Section L: user save ka fix + Staff (employee+login) ek saath ===';
GO

/* ---- L0. Jo user pehle se toot chuke hain unhe dhoondo ---------------------
   Agar kisi ne ye bug chalte hue user edit kiye hain to unka hash placeholder
   bana pada hai. Wo log login nahi kar paayenge. Yahan sirf report kar rahe hain
   — password hum khud set nahi kar sakte, admin ko reset karna padega. */
IF EXISTS (SELECT 1 FROM PUMP.Users WHERE PasswordHash = N'***UNCHANGED***')
BEGIN
    SELECT
        Problem  = 'Is user ka password hash placeholder ban gaya tha — ye login NAHI kar payega',
        Id, OwnerId, Username, FullName,
        Action   = 'Users page se ise naya password dein (ya sp_User_AdminResetPassword)'
    FROM PUMP.Users
    WHERE PasswordHash = N'***UNCHANGED***';

    /* Login band kar dete hain — chupchaap "galat password" dikhne se behtar hai
       ki saaf pata chale ki is account ko reset chahiye. */
    UPDATE PUMP.Users SET IsActive = 0 WHERE PasswordHash = N'***UNCHANGED***';
    PRINT '  ! L0: toote hue account mile — upar list hai, unhe deactivate kar diya';
END
ELSE
    PRINT '  = L0: kisi user ka password hash placeholder nahi bana';
GO

/* ---- L1. sp_User_Save — teen fix -----------------------------------------
     1. '***UNCHANGED***' aaye to PasswordHash ko haath mat lagao.
     2. UPDATE me OwnerId ka filter (pehle sirf `WHERE Id = @Id` tha — doosre
        owner ka user id se edit ho sakta tha).
     3. Username pehle se hai to saaf message. (Pehle raw SQL error 2627 aata
        tha jo user ko "500" dikhta tha.) Role bhi usi owner ka ho.
*/
CREATE OR ALTER PROCEDURE [PUMP].[sp_User_Save]
(
    @Id BIGINT = NULL,
    @OwnerId BIGINT,
    @FullName NVARCHAR(200),
    @Username NVARCHAR(100),
    @PasswordHash NVARCHAR(500),
    @Mobile NVARCHAR(20) = NULL,
    @RoleId BIGINT,
    /* sp_Staff_Save yahan se user banata hai. Wahan ise EXEC ... OUTPUT se
       bulaya jaata hai, INSERT..EXEC se nahi — kyunki SQL Server me INSERT..EXEC
       nest nahi ho sakta (Msg 8164), aur andar wala SELECT ek fazool result set
       bhi bhej deta jise Dapper pehla samajh leta. @Quiet=1 dono problem hata
       deta hai. */
    @Quiet BIT = 0,
    @NewUserId BIGINT = NULL OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Role usi owner ka ho — id badal kar doosre tenant ka role na chipak jaye. */
    IF NOT EXISTS (SELECT 1 FROM PUMP.Roles
                   WHERE Id = @RoleId AND OwnerId = @OwnerId AND ISNULL(IsDeleted, 0) = 0)
        THROW 50160, 'Role not found, or it does not belong to your account.', 1;

    /* Username poore system me ek hi baar — is par UNIQUE constraint hai, par
       message saaf hona chahiye. */
    IF EXISTS (SELECT 1 FROM PUMP.Users
               WHERE Username = @Username AND Id <> ISNULL(@Id, 0))
        THROW 50161, 'This username is already taken. Please choose another one.', 1;

    BEGIN TRANSACTION;

    IF ISNULL(@Id, 0) = 0
    BEGIN
        /* Naya user bina asli password ke nahi ban sakta. */
        IF @PasswordHash IS NULL OR @PasswordHash = N'' OR @PasswordHash = N'***UNCHANGED***'
            THROW 50162, 'A password is required when creating a new login.', 1;

        INSERT INTO PUMP.Users (OwnerId, FullName, Username, PasswordHash, Mobile)
        VALUES (@OwnerId, @FullName, @Username, @PasswordHash, @Mobile);

        SET @Id = SCOPE_IDENTITY();

        INSERT INTO PUMP.UserRoles (UserId, RoleId)
        VALUES (@Id, @RoleId);
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM PUMP.Users WHERE Id = @Id AND OwnerId = @OwnerId)
            THROW 50163, 'User not found, or it does not belong to your account.', 1;

        /* YAHAN WALA FIX: placeholder aaye to purana hash waisa hi rehne do. */
        UPDATE PUMP.Users
        SET FullName = @FullName,
            Username = @Username,
            PasswordHash = CASE WHEN @PasswordHash IS NULL
                                  OR @PasswordHash = N''
                                  OR @PasswordHash = N'***UNCHANGED***'
                                THEN PasswordHash
                                ELSE @PasswordHash END,
            Mobile = @Mobile
        WHERE Id = @Id
          AND OwnerId = @OwnerId;

        DELETE FROM PUMP.UserRoles WHERE UserId = @Id;

        INSERT INTO PUMP.UserRoles (UserId, RoleId)
        VALUES (@Id, @RoleId);
    END

    COMMIT TRANSACTION;

    SET @NewUserId = @Id;
    IF @Quiet = 0
        SELECT @Id AS Id;
END
GO

PRINT '  + L1: sp_User_Save fix (password placeholder, owner check, saaf message)';
GO

/* ---- L2. sp_Staff_Save — ek form, dono record -----------------------------
   Ab tak naye aadmi ko login dena ho to do page bharne padte the: pehle
   /Operations/Users par login, phir /Operations/Employees par HR record, aur
   dono jagah naam-mobile alag-alag bharna padta tha.

   Ye SP dono ek transaction me karta hai:
     @WantsLogin = 0  -> sirf Employees row (chowkidar, helper — login nahi chahiye)
     @WantsLogin = 1  -> pehle Users row (ya purana update), phir Employees row
                         usi UserId ke saath

   Tables bilkul waise ke waise hain — sirf save ek jagah se ho raha hai.
   Password hashing C# me hoti hai (IPasswordHasher), yahan hamesha hash hi aata
   hai; edit karte waqt password khaali chhoda ho to '***UNCHANGED***' aata hai
   aur upar wala L1 fix use sambhal leta hai.
*/
CREATE OR ALTER PROCEDURE PUMP.sp_Staff_Save
(
    @Id            BIGINT = NULL,          -- Employees.Id
    @OwnerId       BIGINT,
    @PumpId        BIGINT,
    @EmployeeCode  NVARCHAR(30),
    @FullName      NVARCHAR(150),
    @Mobile        NVARCHAR(20) = NULL,
    @JoinDate      DATE,
    @Designation   NVARCHAR(80) = NULL,
    @MonthlySalary DECIMAL(18,2) = 0,
    @IsActive      BIT = 1,
    -- login wala hissa
    @WantsLogin    BIT = 0,
    @Username      NVARCHAR(100) = NULL,
    @PasswordHash  NVARCHAR(500) = NULL,
    @RoleId        BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Pump usi owner ka ho. */
    IF NOT EXISTS (SELECT 1 FROM PUMP.Pumps
                   WHERE Id = @PumpId AND OwnerId = @OwnerId AND ISNULL(IsDeleted, 0) = 0)
        THROW 50170, 'Pump not found, or it does not belong to your account.', 1;

    /* Edit ho raha ho to employee bhi usi owner+pump ka ho. */
    IF ISNULL(@Id, 0) <> 0 AND NOT EXISTS (
        SELECT 1 FROM PUMP.Employees
        WHERE Id = @Id AND OwnerId = @OwnerId AND PumpId = @PumpId
          AND ISNULL(IsDeleted, 0) = 0)
        THROW 50171, 'Employee not found, or it does not belong to this pump.', 1;

    /* Is employee ka pehle se koi login juda hai kya. */
    DECLARE @UserId BIGINT = NULL;
    IF ISNULL(@Id, 0) <> 0
        SELECT @UserId = UserId FROM PUMP.Employees WHERE Id = @Id;

    /* Neeche har THROW par SET XACT_ABORT ON khud poora transaction rollback kar
       deta hai — isliye explicit ROLLBACK nahi likha. Wo likhne par, agar koi is
       SP ko INSERT..EXEC se bulaye to asli error ki jagah 3915 aa jaata tha. */
    IF @WantsLogin = 1
    BEGIN
        IF @Username IS NULL OR LTRIM(RTRIM(@Username)) = N''
            THROW 50172, 'Username is required when you give this person a login.', 1;

        IF @RoleId IS NULL
            THROW 50173, 'Please pick a role for this login.', 1;
    END

    DECLARE @NewEmployeeId BIGINT = @Id;

    BEGIN TRANSACTION;

    IF @WantsLogin = 1
    BEGIN
        /* sp_User_Save khud saare check karta hai (role ka owner, username
           duplicate, password placeholder) — dobara likhne ki zaroorat nahi.
           OUTPUT param se bula rahe hain, INSERT..EXEC se nahi: wo nest nahi
           hota (Msg 8164) aur ek extra result set bhi bhej deta hai. */
        DECLARE @SavedUserId BIGINT;

        EXEC PUMP.sp_User_Save
            @Id           = @UserId,
            @OwnerId      = @OwnerId,
            @FullName     = @FullName,
            @Username     = @Username,
            @PasswordHash = @PasswordHash,
            @Mobile       = @Mobile,
            @RoleId       = @RoleId,
            @Quiet        = 1,
            @NewUserId    = @SavedUserId OUTPUT;

        SET @UserId = @SavedUserId;

        IF ISNULL(@UserId, 0) = 0
            THROW 50174, 'Could not create the login for this person.', 1;
    END
    ELSE
    BEGIN
        /* Login nahi chahiye. Purana juda hua login MITATE NAHI hain — us login
           se shift khuli ho sakti hai, audit me uska naam pada ho sakta hai.
           Bas rishta tod dete hain. */
        SET @UserId = NULL;
    END

    /* Ek login is pump par sirf ek hi employee ka (Section J1 wala niyam). */
    IF @UserId IS NOT NULL AND EXISTS (
        SELECT 1 FROM PUMP.Employees
        WHERE UserId = @UserId AND PumpId = @PumpId
          AND ISNULL(IsDeleted, 0) = 0
          AND Id <> ISNULL(@Id, 0))
        THROW 50151, 'This login is already linked to another employee on this pump.', 1;

    /* Employee code ka faisla yahin hota hai, transaction ke andar (Section T).
       Client jo bhejta hai wo sirf sujhav hai — do log ek saath form kholein to
       dono ko wahi "EMP-003" dikhta tha. Khaali ho ya kisi aur ne le liya ho to
       agla khaali number khud de dete hain. UPDLOCK/HOLDLOCK isliye ki ek waqt
       me ek hi save is pump ka code chune. */
    SET @EmployeeCode = LTRIM(RTRIM(ISNULL(@EmployeeCode, '')));

    DECLARE @CodeTaken BIT = 0;
    IF @EmployeeCode = ''
        SET @CodeTaken = 1;
    ELSE IF EXISTS (
        SELECT 1 FROM PUMP.Employees WITH (UPDLOCK, HOLDLOCK)
        WHERE PumpId = @PumpId AND EmployeeCode = @EmployeeCode
          AND ISNULL(IsDeleted, 0) = 0 AND Id <> ISNULL(@Id, 0))
        SET @CodeTaken = 1;

    IF @CodeTaken = 1
        SET @EmployeeCode = PUMP.fn_NextEmployeeCode(@PumpId);

    IF ISNULL(@Id, 0) = 0
    BEGIN
        INSERT INTO PUMP.Employees
            (OwnerId, PumpId, UserId, EmployeeCode, FullName, Mobile, JoinDate,
             Designation, MonthlySalary, IsActive)
        VALUES
            (@OwnerId, @PumpId, @UserId, @EmployeeCode, @FullName, @Mobile, @JoinDate,
             @Designation, @MonthlySalary, @IsActive);

        SET @NewEmployeeId = CAST(SCOPE_IDENTITY() AS BIGINT);
    END
    ELSE
    BEGIN
        UPDATE PUMP.Employees
        SET UserId        = @UserId,
            EmployeeCode  = @EmployeeCode,
            FullName      = @FullName,
            Mobile        = @Mobile,
            JoinDate      = @JoinDate,
            Designation   = @Designation,
            MonthlySalary = @MonthlySalary,
            IsActive      = @IsActive,
            UpdatedOn     = SYSDATETIME()
        WHERE Id = @Id AND OwnerId = @OwnerId AND PumpId = @PumpId;
    END

    COMMIT TRANSACTION;

    SELECT EmployeeId = @NewEmployeeId, UserId = @UserId;
END
GO

PRINT '  + L2: sp_Staff_Save ready (ek form se employee + login)';
GO

/* ---- L3. sp_Staff_List — employee + uska login ek saath -------------------
   sp_Employee_List jaisa hi, par login ka role/username bhi saath deta hai
   taaki Staff page ek hi call me poori list dikha sake. */
CREATE OR ALTER PROCEDURE PUMP.sp_Staff_List
(
    @OwnerId BIGINT,
    @PumpId  BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        e.Id,
        e.OwnerId,
        e.PumpId,
        e.UserId,
        e.EmployeeCode,
        e.FullName,
        e.Mobile,
        e.JoinDate,
        e.Designation,
        e.MonthlySalary,
        e.IsActive,
        UserName = u.Username,
        RoleId   = r.Id,
        RoleName = r.Name,
        LoginActive = CAST(CASE WHEN u.Id IS NULL THEN 0 ELSE u.IsActive END AS BIT)
    FROM PUMP.Employees e
    LEFT JOIN PUMP.Users     u  ON u.Id = e.UserId
    LEFT JOIN PUMP.UserRoles ur ON ur.UserId = u.Id
    LEFT JOIN PUMP.Roles     r  ON r.Id = ur.RoleId
    WHERE e.OwnerId = @OwnerId
      AND e.PumpId = @PumpId
      AND ISNULL(e.IsDeleted, 0) = 0
    ORDER BY e.FullName;
END
GO


/* ---- L4. Staff ka menu ----------------------------------------------------
   Employees (sequence 20) ke theek paas rakha hai. Purane Employees aur Users
   menu ko hataya NAHI hai — Users page ab bhi chahiye un logon ke liye jo
   employee nahi hain (owner, auditor, accountant), aur purane link kisi ke
   bookmark me ho sakte hain.

   Permission wahi hai jo Employees menu ki hai — jo role employee bana sakta
   tha wahi Staff bhi bana sake. Naya menu chupchaap kisi ko extra adhikar na
   de de, isliye role-by-role copy kar rahe hain. */
IF NOT EXISTS (SELECT 1 FROM PUMP.Menus WHERE Route = '/staff')
BEGIN
    INSERT INTO PUMP.Menus (ParentId, MenuName, Route, Icon, Sequence, IsVisible, IsActive)
    SELECT ParentId, N'Staff', '/staff', N'badge', 19, 1, 1
    FROM PUMP.Menus WHERE Route = '/employees';

    DECLARE @StaffMenuId BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);
    DECLARE @EmpMenuId   BIGINT = (SELECT Id FROM PUMP.Menus WHERE Route = '/employees');

    INSERT INTO PUMP.RoleMenus (RoleId, MenuId, CanView, CanCreate, CanEdit, CanDelete)
    SELECT rm.RoleId, @StaffMenuId, rm.CanView, rm.CanCreate, rm.CanEdit, rm.CanDelete
    FROM PUMP.RoleMenus rm
    WHERE rm.MenuId = @EmpMenuId
      AND NOT EXISTS (SELECT 1 FROM PUMP.RoleMenus x
                      WHERE x.RoleId = rm.RoleId AND x.MenuId = @StaffMenuId);

    PRINT '  + L4: Staff menu bana (Employees ki hi permission ke saath)';
END
ELSE
    PRINT '  = L4: Staff menu pehle se hai';
GO

PRINT '  + L3: sp_Staff_List ready';
PRINT '=== Section L done ===';
GO

/* ===========================================================================
   SECTION M — "SP me OwnerId nahi hai" wali health check report saaf ki
   ---------------------------------------------------------------------------
   HEALTH CHECK (H10) 7 procedures flag kar raha tha. Ek-ek karke dekha:

   TEEN me sach me kami thi — SP khud apne bharose surakshit nahi tha:

     sp_ShiftNozzle_CashSummary  sirf @ShiftId leta tha. Aaj bhi ye endpoint
                                 ITenantGuard se bacha hua hai, isliye leak
                                 HO NAHI raha — par SP ko caller ke bharose
                                 nahi chhodna chahiye. @OwnerId add kiya.
     sp_Product_GetRateOnDate    sirf @ProductId leta tha — kisi bhi tenant ke
                                 product ka rate history nikal sakta tha.
     sp_Sales_SaveDetail         sirf @SalesHeaderId leta tha. Ye padhne se
                                 zyada khatarnak hai: galat header id bhej kar
                                 DOOSRE tenant ke bill me line add ki ja sakti
                                 thi. Aaj SalesRepository header khud usi
                                 transaction me banata hai, isliye pahunch ka
                                 rasta nahi hai — par SP ab khud jaanchta hai.

   CHAAR jaanbujh kar bina OwnerId ke hain — ye H10 ka false positive hai:

     sp_RefreshToken_GetValid    @TokenHash se pehchaan BANTI hai. Us waqt
                                 OwnerId hota hi nahi — maangna circular hoga.
                                 User active hai ya nahi, ye baad me
                                 sp_Auth_GetByUserId dekhta hai.
     sp_RefreshToken_Revoke      TokenHash hi raaz hai; jiske paas hai wahi
                                 apna token radd kar sakta hai.
     sp_RefreshToken_Save        Login safal hone ke turant baad chalta hai.
     sp_PasswordReset_RequestOtp Login se PEHLE ka kaam hai — abhi koi owner
                                 pata hi nahi. Ye pehle se owner ka IsActive
                                 dekhta hai aur number registered ho ya na ho,
                                 jawab hamesha ek jaisa deta hai.

   In chaar ko M4 me health check se hata rahe hain — taaki report me sirf
   ASLI problem dikhe. Har baar 4 "problem" dikhte rahenge to asli wala
   unke beech chhup jayega.
   =========================================================================== */
GO

PRINT '';
PRINT '=== Section M: tenant guard — 3 SP theek, 4 false positive ===';
GO

/* ---- M1. sp_ShiftNozzle_CashSummary — @OwnerId ---------------------------
   Doosre owner ki ShiftId bhejne par ab khaali list milti hai. */
CREATE OR ALTER PROCEDURE PUMP.sp_ShiftNozzle_CashSummary
(
    @ShiftId BIGINT,
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        snr.ShiftId,
        snr.NozzleId,
        NozzleCode   = n.NozzleCode,
        ProductName  = p.Name,
        snr.EmployeeId,
        EmployeeName = ISNULL(e.FullName, N'(koi nahi)'),
        snr.OpeningReading,
        snr.ClosingReading,
        snr.SoldQty,
        snr.Rate,
        MeterSale    = ISNULL(snr.SoldAmount, 0),
        snr.FloatGiven,
        snr.SlipsAmount,
        /* Jitna cash is aadmi ke paas hona chahiye. */
        ExpectedCash = ISNULL(snr.FloatGiven, 0) + ISNULL(snr.SoldAmount, 0) - ISNULL(snr.SlipsAmount, 0),
        snr.CashReturned,
        ShortExcess  = CASE WHEN snr.CashReturned IS NULL THEN NULL
                            ELSE snr.CashReturned
                                 - (ISNULL(snr.FloatGiven, 0) + ISNULL(snr.SoldAmount, 0) - ISNULL(snr.SlipsAmount, 0))
                       END,
        snr.CashCollectedOn,
        snr.CashNotes,
        IsCollected  = CAST(CASE WHEN snr.CashReturned IS NULL THEN 0 ELSE 1 END AS BIT)
    FROM PUMP.ShiftNozzleReadings snr
    JOIN PUMP.Nozzles  n ON n.Id = snr.NozzleId
    JOIN PUMP.Products p ON p.Id = snr.ProductId
    LEFT JOIN PUMP.Employees e ON e.Id = snr.EmployeeId
    WHERE snr.ShiftId = @ShiftId
      AND snr.OwnerId = @OwnerId
    ORDER BY n.NozzleCode;
END
GO

PRINT '  + M1: sp_ShiftNozzle_CashSummary ab @OwnerId maangta hai';
GO

/* ---- M2. sp_Product_GetRateOnDate — @OwnerId ------------------------------
   Product usi owner ka ho. Nahi to kuch nahi lautta (rate leak nahi hoga). */
CREATE OR ALTER PROCEDURE PUMP.sp_Product_GetRateOnDate
(
    @ProductId BIGINT,
    @OnDate    DATETIME2(7),
    @OwnerId   BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.Products
                   WHERE Id = @ProductId AND OwnerId = @OwnerId)
    BEGIN
        SELECT Rate = CAST(NULL AS DECIMAL(18,2)), EffectiveFrom = CAST(NULL AS DATETIME2(7))
        WHERE 1 = 0;                       -- khaali result, shape wahi
        RETURN;
    END

    SELECT TOP 1
        Rate = h.NewRate,
        EffectiveFrom = ISNULL(h.EffectiveFrom, h.ChangedAt)
    FROM PUMP.ProductRateHistory h
    WHERE h.ProductId = @ProductId
      AND ISNULL(h.EffectiveFrom, h.ChangedAt) <= @OnDate
    ORDER BY ISNULL(h.EffectiveFrom, h.ChangedAt) DESC;

    -- history na mile to current rate
    IF @@ROWCOUNT = 0
        SELECT Rate = CurrentRate, EffectiveFrom = CAST(NULL AS DATETIME2(7))
        FROM PUMP.Products WHERE Id = @ProductId AND OwnerId = @OwnerId;
END
GO

PRINT '  + M2: sp_Product_GetRateOnDate ab @OwnerId maangta hai';
GO

/* ---- M3. sp_Sales_SaveDetail — @OwnerId + jaanch --------------------------
   Ye teeno me sabse zaroori tha: bill ki line LIKHTA hai. Bina check ke,
   doosre tenant ke bill me line ghusaayi ja sakti thi — uska hisaab bigad
   jaata aur pata bhi na chalta.

   Ab header aur product dono usi owner ke hone chahiye. */
CREATE OR ALTER PROCEDURE [PUMP].[sp_Sales_SaveDetail]
(
    @SalesHeaderId BIGINT,
    @ProductId BIGINT,
    @NozzleNo NVARCHAR(30) = NULL,
    @Quantity DECIMAL(18,3),
    @Rate DECIMAL(18,2),
    @Amount DECIMAL(18,2),
    @BaseAmount DECIMAL(18,2) = 0,
    @CGSTAmount DECIMAL(18,2) = 0,
    @SGSTAmount DECIMAL(18,2) = 0,
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.SalesHeaders
                   WHERE Id = @SalesHeaderId AND OwnerId = @OwnerId)
        THROW 50180, 'Sales bill not found, or it does not belong to your account.', 1;

    IF NOT EXISTS (SELECT 1 FROM PUMP.Products
                   WHERE Id = @ProductId AND OwnerId = @OwnerId)
        THROW 50181, 'Product not found, or it does not belong to your account.', 1;

    INSERT INTO PUMP.SalesDetails
    (
        SalesHeaderId,
        ProductId,
        NozzleNo,
        Quantity,
        Rate,
        Amount,
        BaseAmount,
        CGSTAmount,
        SGSTAmount
    )
    VALUES
    (
        @SalesHeaderId,
        @ProductId,
        @NozzleNo,
        @Quantity,
        @Rate,
        @Amount,
        @BaseAmount,
        @CGSTAmount,
        @SGSTAmount
    );
END
GO

PRINT '  + M3: sp_Sales_SaveDetail ab header aur product dono ka owner jaanchta hai';
GO

/* ---- M4. Health check ki H10 report se auth wale SP hatao -----------------
   Ye chaar jaanbujh kar bina OwnerId ke hain (upar wajah likhi hai). Report me
   inhe "problem" dikhate rehne se asli problem chhup jaati hai. Ab H10 me
   sp_RefreshToken% aur sp_PasswordReset% bhi chhod diye jaate hain, waise hi
   jaise sp_Auth% aur sp_Login% pehle se chhode ja rahe the.

   NOTE: ye report H10 me upar likhi hai, isliye yahan sirf DOBARA chala rahe
   hain — updated filter ke saath. Agar list khaali aayi to sab theek hai. */
SELECT
    Problem       = 'SP me OwnerId parameter nahi hai — tenant leak ka khatra',
    ProcedureName = 'PUMP.' + p.name,
    Action        = 'SP me @OwnerId add karke WHERE me lagayein'
FROM sys.procedures p
JOIN sys.sql_modules m ON m.object_id = p.object_id
WHERE SCHEMA_NAME(p.schema_id) = 'PUMP'
  AND p.name NOT LIKE 'sp_Auth%'
  AND p.name NOT LIKE 'sp_Owner%'
  AND p.name NOT LIKE 'sp_Menu%'
  AND p.name NOT LIKE 'sp_Role%'
  AND p.name NOT LIKE 'sp_Subscription%'
  AND p.name NOT LIKE 'sp_Payment%'
  AND p.name NOT LIKE 'sp_Login%'
  AND p.name NOT LIKE 'sp_Audit%'
  /* ---- neeche wale do Section M me jode gaye ---- */
  AND p.name NOT LIKE 'sp_RefreshToken%'    -- token hash hi pehchaan hai
  AND p.name NOT LIKE 'sp_PasswordReset%'   -- login se pehle ka kaam
  AND p.name NOT LIKE 'sp_Master_Restore'
  AND m.definition NOT LIKE '%@OwnerId%'
ORDER BY p.name;
GO

PRINT '=== Section M done (upar wali list KHAALI honi chahiye) ===';
GO

/* ===========================================================================
   SECTION N — Bootstrap: system owner + superadmin
   ---------------------------------------------------------------------------
   Sabse aakhir me isliye hai ki yahan tak har column aur table ban chuka hota
   hai (Owners.ValidUpto PART 2 me aata hai).

   Ye DB me ghusne ka ekmatra rasta hai. Iske alawa fresh DB me koi data nahi.
   =========================================================================== */
GO

PRINT '';
PRINT '=== Section N: bootstrap (system owner + superadmin) ===';
GO

/* ---- System owner: sirf superadmin ko rakhne ke liye ---------------------
   Ye tenant NAHI hai. Iska koi pump, product ya transaction nahi hota. Sirf
   isliye hai ki PUMP.Users.OwnerId par PUMP.Owners ki foreign key lagi hai. */
IF NOT EXISTS (SELECT 1 FROM PUMP.Owners WHERE Name = N'-- SYSTEM --')
BEGIN
    INSERT INTO PUMP.Owners (Name, IsActive, CreatedOn, ValidUpto)
    VALUES (N'-- SYSTEM --', 1, SYSDATETIME(), '2099-12-31');
    PRINT '  + N1: system owner bana (superadmin ke liye — ye koi pump nahi hai)';
END
ELSE
    PRINT '  = N1: system owner pehle se hai';
GO

/* ---- Superadmin login ----------------------------------------------------
   Ye ekmatra login hai jo fresh DB me hota hai. Iska kaam sirf naye tenant
   banana hai — apne pump ka rozmarra ka kaam is login se NAHI karna.

   Password: password123
   Hash PBKDF2 hai (wahi jo app istemaal karti hai), plaintext kahin nahi pada.

   >>> PEHLE LOGIN KE BAAD YE PASSWORD TURANT BADLEIN. <<<
*/
IF NOT EXISTS (SELECT 1 FROM PUMP.Users WHERE Username = N'superadmin')
BEGIN
    INSERT INTO PUMP.Users (OwnerId, FullName, Username, PasswordHash, Mobile, IsActive, CreatedOn, IsSuperAdmin, IsOwner)
    SELECT TOP 1 o.Id, N'System Super Admin', N'superadmin',
           N'PBKDF2$100000$0qIOUTggHCNRV2dhyLXTsg==$GZd3hzuHO1bInC+gDjKybKLsjBFyZIJR9Wdp1GAtQQw=',
           NULL, 1, SYSDATETIME(), 1, 0
    FROM PUMP.Owners o WHERE o.Name = N'-- SYSTEM --' ORDER BY o.Id;

    PRINT '';
    PRINT '  **********************************************************';
    PRINT '   SUPERADMIN BAN GAYA';
    PRINT '     Username : superadmin';
    PRINT '     Password : password123    <-- TURANT BADLEIN';
    PRINT '   Isse login karke Super Admin > Create Tenant se pehla pump banayein.';
    PRINT '  **********************************************************';
    PRINT '';
END
ELSE
    PRINT '  = N2: superadmin pehle se hai (password waisa hi hai)';
GO

/* ---- N3. Fresh DB me kya hai, ek nazar me ------------------------------- */
SELECT
    Cheez = 'Menus (app ka dhaancha)',        Kitne = (SELECT COUNT(*) FROM PUMP.Menus)
UNION ALL SELECT 'States (GST master)',              (SELECT COUNT(*) FROM PUMP.States)
UNION ALL SELECT 'SubscriptionPlans',                (SELECT COUNT(*) FROM PUMP.SubscriptionPlans)
UNION ALL SELECT 'AppSettings',                      (SELECT COUNT(*) FROM PUMP.AppSettings)
UNION ALL SELECT 'Owners (system wala bhi ginke)',   (SELECT COUNT(*) FROM PUMP.Owners)
UNION ALL SELECT 'Users (sirf superadmin)',          (SELECT COUNT(*) FROM PUMP.Users)
UNION ALL SELECT 'Pumps',                            (SELECT COUNT(*) FROM PUMP.Pumps)
UNION ALL SELECT 'Products',                         (SELECT COUNT(*) FROM PUMP.Products)
UNION ALL SELECT 'Employees',                        (SELECT COUNT(*) FROM PUMP.Employees)
UNION ALL SELECT 'ShiftHeaders',                     (SELECT COUNT(*) FROM PUMP.ShiftHeaders)
UNION ALL SELECT 'SalesHeaders',                     (SELECT COUNT(*) FROM PUMP.SalesHeaders);
GO

PRINT '=== Section N done ===';
PRINT '';
PRINT '===========================================================';
PRINT ' AGLA KADAM';
PRINT '   1. App chalayein aur superadmin / password123 se login karein';
PRINT '   2. Super Admin > Create Tenant se pehla pump banayein';
PRINT '   3. superadmin ka password badal dein';
PRINT '===========================================================';
GO

/* ===========================================================================
   SECTION O — Nozzle ke bina tank ka jhol
   ---------------------------------------------------------------------------
   Nozzle bina tank chune ban jaata tha. @TankId optional tha, UI me "-- Not set --"
   chuna reh jaata tha, aur nozzle chup-chaap tank ke bina save ho jaata tha.

   Iska nuksaan turant nahi dikhta — bahut baad me dikhta hai:

     * Shift kholte waqt sp_Shift_Open THROW 50003 deta hai ("Some nozzles have
       no tank set"). Yaani pump wala setup poora karke bhi shift khol hi nahi
       paata, aur error uss page par aata hai jahan galti hui hi nahi thi.
     * Us nozzle se bikne wala tel kisi tank se ghata hi nahi — stock hamesha
       zyada dikhta rehta aur reconcile me antar aata rehta.

   Ab tank chunna ZAROORI hai. Teen jagah rok lagai hai:
     1. Form me select `required` hai (turant pata chale)
     2. Controller me jaanch (form bypass ho jaye to bhi)
     3. Yahan SP me (asli deewar — API se seedha call ho to bhi)

   Saath me menu ka kram bhi theek kiya: pehle Tanks, phir Nozzles. Nozzle banane
   ke liye tank pehle se hona chahiye, par menu me Nozzles upar tha — isliye log
   pehle Nozzles par pahunchte the, tank milta hi nahi tha aur "-- Not set --"
   chun kar aage badh jaate the. Yahi is bug ki asli jad thi.
   =========================================================================== */
GO

PRINT '';
PRINT '=== Section O: nozzle ke liye tank zaroori + menu ka kram ===';
GO

/* ---- O1. Menu: Tanks ab Nozzles se UPAR ---------------------------------- */
UPDATE PUMP.Menus SET Sequence = 3 WHERE Route = '/tank'   AND Sequence <> 3;
UPDATE PUMP.Menus SET Sequence = 4 WHERE Route = '/nozzle' AND Sequence <> 4;
PRINT '  + O1: menu ka kram — Tanks (3) phir Nozzles (4)';
GO

/* ---- O2. Purane nozzle jinme tank set hi nahi hai ------------------------
   Inhe hum khud theek NAHI kar sakte — kaunsa tank sahi hai ye sirf pump wala
   jaanta hai. Isliye sirf list kar rahe hain. Jab tak ye theek nahi honge,
   in par shift nahi khulegi (THROW 50003). */
-- Gas (CNG) / charging ka tank hota hi nahi (Section AL) - un nozzle ko yahan nahi ginte.
IF EXISTS (SELECT 1 FROM PUMP.Nozzles n0
           JOIN PUMP.Products p0 ON p0.Id = n0.ProductId
           WHERE n0.TankId IS NULL AND n0.IsActive = 1 AND ISNULL(n0.IsDeleted, 0) = 0
             AND p0.Category NOT IN (N'CNG', N'ElectricCharging'))
BEGIN
    SELECT
        Problem  = 'Is nozzle ka tank set nahi hai — is par shift nahi khulegi',
        n.Id, n.OwnerId, n.PumpId, n.NozzleCode,
        Product  = p.Name,
        KaunseTankChun_Sakte_Hain =
            ISNULL(STUFF((SELECT ', ' + t.Name
                          FROM PUMP.Tanks t
                          WHERE t.PumpId = n.PumpId AND t.ProductId = n.ProductId
                            AND t.IsActive = 1 AND ISNULL(t.IsDeleted, 0) = 0
                          FOR XML PATH('')), 1, 2, ''),
                   '(is product ka koi tank hi nahi — pehle tank banayein)'),
        Action   = 'Nozzles page par Edit karke tank chunein'
    FROM PUMP.Nozzles n
    LEFT JOIN PUMP.Products p ON p.Id = n.ProductId
    WHERE n.TankId IS NULL AND n.IsActive = 1 AND ISNULL(n.IsDeleted, 0) = 0
      AND ISNULL(p.Category, N'') NOT IN (N'CNG', N'ElectricCharging')
    ORDER BY n.PumpId, n.NozzleCode;

    PRINT '  ! O2: kuch nozzle bina tank ke hain — upar list hai, unhe Edit karke tank dein';
END
ELSE
    PRINT '  = O2: har nozzle ka tank set hai';
GO

/* ---- O3. sp_Nozzle_Save — tank ab zaroori ------------------------------- */
CREATE OR ALTER PROCEDURE PUMP.sp_Nozzle_Save
(
    @Id BIGINT = NULL,
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @ProductId BIGINT,
    @NozzleCode NVARCHAR(30),
    @TankId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    /* Tank ke bina nozzle ka koi matlab nahi — bikne wala tel kisi tank se
       ghatna hi chahiye. Pehle ye NULL ho sakta tha aur galti shift kholte
       waqt pakadi jaati thi (THROW 50003), jo bahut der ho jaati hai. */
    IF @TankId IS NULL OR @TankId = 0
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM PUMP.Tanks
                       WHERE OwnerId = @OwnerId AND PumpId = @PumpId AND ProductId = @ProductId
                         AND IsActive = 1 AND ISNULL(IsDeleted, 0) = 0)
            THROW 50063, 'This product has no tank on this pump yet. Add the tank first, then create the nozzle.', 1;

        THROW 50064, 'Please pick the tank this nozzle draws from.', 1;
    END

    -- Tank usi pump/product ka hona chahiye, warna galat tank se deduct hone laga to.
    IF NOT EXISTS
    (
        SELECT 1 FROM PUMP.Tanks
        WHERE Id = @TankId AND OwnerId = @OwnerId AND PumpId = @PumpId AND ProductId = @ProductId
    )
        THROW 50062, 'The selected tank does not belong to this pump/product.', 1;

    IF @Id IS NULL OR @Id = 0
    BEGIN
        INSERT INTO PUMP.Nozzles (OwnerId, PumpId, ProductId, NozzleCode, TankId)
        VALUES (@OwnerId, @PumpId, @ProductId, @NozzleCode, @TankId);
    END
    ELSE
    BEGIN
        UPDATE PUMP.Nozzles
        SET ProductId = @ProductId,
            NozzleCode = @NozzleCode,
            TankId = @TankId
        WHERE Id = @Id
          AND OwnerId = @OwnerId
          AND PumpId = @PumpId;
    END

    SELECT COALESCE(@Id, CAST(SCOPE_IDENTITY() AS BIGINT)) AS Id;
END
GO

PRINT '  + O3: sp_Nozzle_Save ab tank ke bina nozzle nahi banne deta';
PRINT '=== Section O done ===';
GO

/* ===========================================================================
   SECTION P — Owner ko alert: number apne tenant ka, aur owner ki apni marzi
   ---------------------------------------------------------------------------
   CHEH JAGAH ALERT BHEJNE KA CODE HAI, PAR ABHI EK BHI NAHI JAATA.

   Application me cheh jagah owner ko sandesh bhejne ka code hai — shift close,
   bank deposit, bada kharcha, purchase, stock loss, aur party ledger ki copy.
   Sabhi `SendMessageAsync("", msg)` likhte hain. Wo khaali "" ka matlab tha
   "owner ka number tum khud dhoondh lo".

   Dhoondhne wala code aisa tha:
       SELECT TOP 1 Mobile FROM PUMP.Users WHERE IsOwner = 1
   Ismein OwnerId ka filter hi nahi tha — yaani multi-tenant DB me ye KISI BHI
   pump ke malik ka number utha leta. Ek pump ki bikri aur cash ki jaankari
   doosre pump ke malik ke phone par ja sakti thi, aur kisi ko pata bhi na
   chalta. Security review me ye pakda gaya aur wo code hata diya gaya —
   isliye ab wo cheho alert chup-chaap bhejte hi nahi.

   AB KYA HO RAHA HAI:

     1. Number HAR OWNER KA APNA — `Owners.ContactNo`, aur wo khaali ho to us
        owner ke `IsOwner = 1` wale user ka Mobile. Doosre tenant ka number
        aa hi nahi sakta, kyunki dono jagah OwnerId ka filter hai.

     2. Owner khud tay kare ki kaunsa alert chahiye. Har alert ka apna switch.
        Ye aage kaam aayega: WhatsApp par har sandesh ka paisa lagta hai, to
        jo alert nahi chahiye wo band karke owner apna kharcha ghata sakta hai.

   Naye owner ke liye kuch karna nahi padta — row na ho to alert CHALU maana
   jaata hai. Yaani purana vyavhaar hi default hai.
   =========================================================================== */
GO

PRINT '';
PRINT '=== Section P: owner alerts (per-tenant number + on/off) ===';
GO

/* ---- P1. Har alert ka switch ------------------------------------------- */
IF OBJECT_ID('PUMP.OwnerAlertSettings', 'U') IS NULL
BEGIN
    CREATE TABLE PUMP.OwnerAlertSettings
    (
        Id        BIGINT IDENTITY(1,1) PRIMARY KEY,
        OwnerId   BIGINT       NOT NULL,
        AlertKey  NVARCHAR(40) NOT NULL,
        IsEnabled BIT          NOT NULL CONSTRAINT DF_OwnerAlert_IsEnabled DEFAULT (1),
        UpdatedOn DATETIME2(7) NULL,
        CONSTRAINT FK_OwnerAlert_Owner FOREIGN KEY (OwnerId) REFERENCES PUMP.Owners (Id)
    );
    PRINT '  + P1: PUMP.OwnerAlertSettings bana';
END
ELSE
    PRINT '  = P1: OwnerAlertSettings pehle se hai';
GO

/* Ek owner ka ek alert ek hi baar. Filtered index nahi hai, par -I flag ki
   aadat bani rahe isliye QUOTED_IDENTIFIER ON ka dhyan rakhein. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UX_OwnerAlertSettings'
                 AND object_id = OBJECT_ID('PUMP.OwnerAlertSettings'))
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX UX_OwnerAlertSettings
        ON PUMP.OwnerAlertSettings (OwnerId, AlertKey);
    PRINT '  + P1: UX_OwnerAlertSettings bana';
END
ELSE
    PRINT '  = P1: index pehle se hai';
GO

/* ---- P2. Alert bhejne se pehle: kise, aur bhejna bhi hai ya nahi --------
   Application har alert se pehle yahi bulaata hai. Do baatein ek saath deta
   hai — number, aur ye alert us owner ne chaalu rakha hai ya nahi.

   Row na mile to IsEnabled = 1 (chaalu). Naye owner ko kuch set karna na pade. */
CREATE OR ALTER PROCEDURE PUMP.sp_Notification_GetOwnerTarget
(
    @OwnerId  BIGINT,
    @AlertKey NVARCHAR(40)
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 1
        /* Pehle Owners.ContactNo — malik khud yahi number settings me rakhta
           hai. Khaali ho to usi owner ke owner-user ka mobile. Dono jagah
           OwnerId ka filter hai, isliye doosre tenant ka number aa hi nahi sakta. */
        Mobile = COALESCE(
                    NULLIF(LTRIM(RTRIM(o.ContactNo)), ''),
                    (SELECT TOP 1 NULLIF(LTRIM(RTRIM(u.Mobile)), '')
                     FROM PUMP.Users u
                     WHERE u.OwnerId = o.Id
                       AND u.IsOwner = 1
                       AND u.IsActive = 1
                       AND ISNULL(u.IsDeleted, 0) = 0
                       AND NULLIF(LTRIM(RTRIM(u.Mobile)), '') IS NOT NULL
                     ORDER BY u.Id)
                 ),
        IsEnabled = CAST(ISNULL(s.IsEnabled, 1) AS BIT),
        OwnerName = o.Name
    FROM PUMP.Owners o
    LEFT JOIN PUMP.OwnerAlertSettings s
           ON s.OwnerId = o.Id AND s.AlertKey = @AlertKey
    WHERE o.Id = @OwnerId
      AND o.IsActive = 1
      AND ISNULL(o.IsDeleted, 0) = 0;
END
GO

PRINT '  + P2: sp_Notification_GetOwnerTarget ready';
GO

/* ---- P3. Settings screen ke liye — saari alert ek list me ---------------
   Alert ki list yahin rakhi hai (application me nahi), taaki naya alert
   jodne par sirf yahan ek line badle. */
CREATE OR ALTER PROCEDURE PUMP.sp_OwnerAlert_List
(
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @All TABLE (AlertKey NVARCHAR(40), Title NVARCHAR(80), Description NVARCHAR(200), Sequence INT);
    INSERT INTO @All (AlertKey, Title, Description, Sequence) VALUES
        ('SHIFT_CLOSE',  N'Shift closed',       N'Sent when a shift is closed, with the day''s sale and cash summary.', 1),
        ('PURCHASE',     N'Stock purchase',     N'Sent when a tanker load is recorded.', 2),
        ('STOCK_LOSS',   N'High stock loss',    N'Sent when a dip reconciliation shows a loss of more than 50 litres.', 3),
        ('BANK_DEPOSIT', N'Bank deposit',       N'Sent when cash is recorded as deposited into the bank.', 4),
        ('BIG_EXPENSE',  N'Large expense',      N'Sent when an expense above Rs. 5,000 is recorded.', 5),
        ('PARTY_LEDGER', N'Credit party entry', N'A copy of the entry that goes to a credit customer''s ledger.', 6);

    SELECT
        a.AlertKey,
        a.Title,
        a.Description,
        IsEnabled = CAST(ISNULL(s.IsEnabled, 1) AS BIT)
    FROM @All a
    LEFT JOIN PUMP.OwnerAlertSettings s
           ON s.OwnerId = @OwnerId AND s.AlertKey = a.AlertKey
    ORDER BY a.Sequence;
END
GO

PRINT '  + P3: sp_OwnerAlert_List ready';
GO

/* ---- P4. Ek switch on/off ---------------------------------------------- */
CREATE OR ALTER PROCEDURE PUMP.sp_OwnerAlert_Save
(
    @OwnerId   BIGINT,
    @AlertKey  NVARCHAR(40),
    @IsEnabled BIT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.Owners
                   WHERE Id = @OwnerId AND ISNULL(IsDeleted, 0) = 0)
        THROW 50190, 'Account not found.', 1;

    IF @AlertKey NOT IN ('SHIFT_CLOSE','PURCHASE','STOCK_LOSS','BANK_DEPOSIT','BIG_EXPENSE','PARTY_LEDGER')
        THROW 50191, 'Unknown alert type.', 1;

    UPDATE PUMP.OwnerAlertSettings
    SET IsEnabled = @IsEnabled, UpdatedOn = SYSDATETIME()
    WHERE OwnerId = @OwnerId AND AlertKey = @AlertKey;

    IF @@ROWCOUNT = 0
        INSERT INTO PUMP.OwnerAlertSettings (OwnerId, AlertKey, IsEnabled, UpdatedOn)
        VALUES (@OwnerId, @AlertKey, @IsEnabled, SYSDATETIME());

    SELECT Result = 'OK';
END
GO

PRINT '  + P4: sp_OwnerAlert_Save ready';
GO

/* ---- P5. Alert ka number set karna ------------------------------------- */
CREATE OR ALTER PROCEDURE PUMP.sp_OwnerAlert_SaveMobile
(
    @OwnerId BIGINT,
    @Mobile  NVARCHAR(20)
)
AS
BEGIN
    SET NOCOUNT ON;

    SET @Mobile = NULLIF(LTRIM(RTRIM(@Mobile)), '');

    /* Sirf ank rakhe hain ya nahi (+ - space chhod kar). Galat number par
       sandesh chala gaya to pata bhi nahi chalega ki gaya kahan. */
    IF @Mobile IS NOT NULL
    BEGIN
        DECLARE @Digits NVARCHAR(20) =
            REPLACE(REPLACE(REPLACE(REPLACE(@Mobile, '+', ''), '-', ''), ' ', ''), '(', '');

        IF LEN(@Digits) < 10 OR @Digits LIKE '%[^0-9]%'
            THROW 50192, 'Please enter a valid mobile number (at least 10 digits).', 1;
    END

    IF NOT EXISTS (SELECT 1 FROM PUMP.Owners
                   WHERE Id = @OwnerId AND ISNULL(IsDeleted, 0) = 0)
        THROW 50190, 'Account not found.', 1;

    UPDATE PUMP.Owners SET ContactNo = @Mobile WHERE Id = @OwnerId;

    SELECT Result = 'OK';
END
GO

PRINT '  + P5: sp_OwnerAlert_SaveMobile ready';
GO

/* ---- P6. Kis owner ka number set hi nahi hai --------------------------- */
SELECT
    Info      = 'Is owner ka alert number set nahi hai — inhe koi sandesh nahi jayega',
    o.Id, o.Name,
    Action    = 'Settings > Alerts me jaakar mobile number daalein'
FROM PUMP.Owners o
WHERE o.IsActive = 1
  AND ISNULL(o.IsDeleted, 0) = 0
  AND o.Name <> N'-- SYSTEM --'
  AND NULLIF(LTRIM(RTRIM(o.ContactNo)), '') IS NULL
  AND NOT EXISTS (SELECT 1 FROM PUMP.Users u
                  WHERE u.OwnerId = o.Id AND u.IsOwner = 1 AND u.IsActive = 1
                    AND ISNULL(u.IsDeleted, 0) = 0
                    AND NULLIF(LTRIM(RTRIM(u.Mobile)), '') IS NOT NULL)
ORDER BY o.Id;
GO

/* ---- P7. Alerts ka menu ------------------------------------------------
   Settings jaisa koi group nahi hai, isliye sabse neeche rakha hai (User Manual
   se thoda upar). Permission wahi jo Users menu ki hai — alert settings malik ka
   kaam hai, har operator ka nahi. */
IF NOT EXISTS (SELECT 1 FROM PUMP.Menus WHERE Route = '/alerts')
BEGIN
    INSERT INTO PUMP.Menus (ParentId, MenuName, Route, Icon, Sequence, IsVisible, IsActive)
    SELECT ParentId, N'Alerts', '/alerts', N'notifications', 30, 1, 1
    FROM PUMP.Menus WHERE Route = '/users';

    DECLARE @AlertMenuId BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);
    DECLARE @UsersMenuId BIGINT = (SELECT Id FROM PUMP.Menus WHERE Route = '/users');

    INSERT INTO PUMP.RoleMenus (RoleId, MenuId, CanView, CanCreate, CanEdit, CanDelete)
    SELECT rm.RoleId, @AlertMenuId, rm.CanView, rm.CanCreate, rm.CanEdit, rm.CanDelete
    FROM PUMP.RoleMenus rm
    WHERE rm.MenuId = @UsersMenuId
      AND NOT EXISTS (SELECT 1 FROM PUMP.RoleMenus x
                      WHERE x.RoleId = rm.RoleId AND x.MenuId = @AlertMenuId);

    PRINT '  + P7: Alerts menu bana (Users ki hi permission ke saath)';
END
ELSE
    PRINT '  = P7: Alerts menu pehle se hai';
GO

PRINT '=== Section P done ===';
GO

/* ===========================================================================
   SECTION Q — Message credits: aapka stock, tenant ka wallet, UPI recharge
   ---------------------------------------------------------------------------
   KYA BANANA HAI

   Aap Twilio se message khareedte hain (jaise Rs.100 ka). Pump owner aapse
   khareedta hai. Do alag khaate hain, aur beech me ek pakka niyam:

       aapne jitne message khareede hain,
       usse ZYADA tenant ko bech nahi sakte.

   Ye wahi baat hai jo poochi gayi thi: "maine 100 ka khareeda hai, owner 1000
   maang raha hai — 1000 add nahi hone chahiye."

   TEEN KHAATE

     1. PlatformCreditPurchases — aapne Twilio se kya khareeda (rupaye + kitne
        message). Ye aapka STOCK hai.

     2. OwnerCreditWallet — har owner ka bacha hua balance.
        Sabhi owner ka jod kabhi aapke stock se zyada nahi ho sakta.

     3. OwnerCreditLedger — har aana-jaana. Bina iske "paisa gaya kahan" ka
        jawab kabhi nahi milta.

   GINTI MESSAGE ME, RUPAYE ME NAHI

   Wallet me "credit" rakhte hain: 1 credit = 1 message. Rupaya sirf khareedte
   waqt lagta hai. Aisa isliye ki Twilio ka rate badalta rehta hai — agar wallet
   rupaye me hota to rate badalne par purana balance galat ho jaata. Message ki
   ginti kabhi galat nahi hoti.

   RECHARGE KA RASTA (bina payment gateway ke)

     owner recharge maangta hai  ->  aapki UPI par paisa bhejta hai
     ->  UPI reference number app me daalta hai  ->  request PENDING
     ->  aap paisa aaya dekh kar APPROVE karte hain  ->  credit chadhte hain

   Approve karte waqt hi stock ki jaanch hoti hai — isliye zyada bech dena
   mumkin hi nahi.
   =========================================================================== */
GO

PRINT '';
PRINT '=== Section Q: message credits (stock + wallet + UPI) ===';
GO

/* ---- Q1. Aapka stock: Twilio se jo khareeda ---------------------------- */
IF OBJECT_ID('PUMP.PlatformCreditPurchases', 'U') IS NULL
BEGIN
    CREATE TABLE PUMP.PlatformCreditPurchases
    (
        Id           BIGINT IDENTITY(1,1) PRIMARY KEY,
        PurchasedOn  DATETIME2(7)   NOT NULL CONSTRAINT DF_PCP_On DEFAULT (SYSDATETIME()),
        Provider     NVARCHAR(40)   NOT NULL CONSTRAINT DF_PCP_Provider DEFAULT ('Twilio'),
        AmountPaid   DECIMAL(18,2)  NOT NULL,   -- rupaye jo aapne diye
        CreditsBought INT           NOT NULL,   -- kitne message mile
        ReferenceNo  NVARCHAR(80)   NULL,       -- Twilio ka invoice/receipt
        Notes        NVARCHAR(300)  NULL,
        CreatedBy    BIGINT         NULL
    );
    PRINT '  + Q1: PlatformCreditPurchases bana';
END
ELSE
    PRINT '  = Q1: PlatformCreditPurchases pehle se hai';
GO

/* ---- Q2. Har owner ka wallet ------------------------------------------- */
IF OBJECT_ID('PUMP.OwnerCreditWallet', 'U') IS NULL
BEGIN
    CREATE TABLE PUMP.OwnerCreditWallet
    (
        OwnerId        BIGINT       NOT NULL PRIMARY KEY,
        Balance        INT          NOT NULL CONSTRAINT DF_OCW_Balance DEFAULT (0),
        LifetimeAdded  INT          NOT NULL CONSTRAINT DF_OCW_Added DEFAULT (0),
        LifetimeUsed   INT          NOT NULL CONSTRAINT DF_OCW_Used DEFAULT (0),
        UpdatedOn      DATETIME2(7) NULL,
        CONSTRAINT FK_OCW_Owner FOREIGN KEY (OwnerId) REFERENCES PUMP.Owners (Id),
        /* Balance kabhi minus me na jaye — bhale hi code me kahin bug ho. */
        CONSTRAINT CK_OCW_Balance CHECK (Balance >= 0)
    );
    PRINT '  + Q2: OwnerCreditWallet bana';
END
ELSE
    PRINT '  = Q2: OwnerCreditWallet pehle se hai';
GO

/* ---- Q3. Har aana-jaana ------------------------------------------------ */
IF OBJECT_ID('PUMP.OwnerCreditLedger', 'U') IS NULL
BEGIN
    CREATE TABLE PUMP.OwnerCreditLedger
    (
        Id           BIGINT IDENTITY(1,1) PRIMARY KEY,
        OwnerId      BIGINT        NOT NULL,
        EntryOn      DATETIME2(7)  NOT NULL CONSTRAINT DF_OCL_On DEFAULT (SYSDATETIME()),
        EntryType    NVARCHAR(20)  NOT NULL,   -- RECHARGE | USE | REFUND | ADJUST
        Credits      INT           NOT NULL,   -- + chadha, - ghata
        BalanceAfter INT           NOT NULL,
        AlertKey     NVARCHAR(40)  NULL,       -- USE ke saath: kaunsa alert tha
        ReferenceNo  NVARCHAR(80)  NULL,
        Notes        NVARCHAR(300) NULL,
        CONSTRAINT FK_OCL_Owner FOREIGN KEY (OwnerId) REFERENCES PUMP.Owners (Id)
    );
    CREATE NONCLUSTERED INDEX IX_OCL_Owner ON PUMP.OwnerCreditLedger (OwnerId, EntryOn DESC);
    PRINT '  + Q3: OwnerCreditLedger bana';
END
ELSE
    PRINT '  = Q3: OwnerCreditLedger pehle se hai';
GO

/* ---- Q4. Recharge ki request (UPI) ------------------------------------- */
IF OBJECT_ID('PUMP.CreditRechargeRequests', 'U') IS NULL
BEGIN
    CREATE TABLE PUMP.CreditRechargeRequests
    (
        Id           BIGINT IDENTITY(1,1) PRIMARY KEY,
        OwnerId      BIGINT        NOT NULL,
        RequestedOn  DATETIME2(7)  NOT NULL CONSTRAINT DF_CRR_On DEFAULT (SYSDATETIME()),
        Amount       DECIMAL(18,2) NOT NULL,   -- kitne rupaye bheje
        Credits      INT           NOT NULL,   -- utne me kitne message
        UpiReference NVARCHAR(80)  NULL,       -- UPI ka transaction number
        Status       NVARCHAR(20)  NOT NULL CONSTRAINT DF_CRR_Status DEFAULT ('PENDING'),
        DecidedOn    DATETIME2(7)  NULL,
        DecidedBy    BIGINT        NULL,
        DecisionNote NVARCHAR(300) NULL,
        CONSTRAINT FK_CRR_Owner FOREIGN KEY (OwnerId) REFERENCES PUMP.Owners (Id),
        CONSTRAINT CK_CRR_Status CHECK (Status IN ('PENDING','APPROVED','REJECTED'))
    );
    CREATE NONCLUSTERED INDEX IX_CRR_Status ON PUMP.CreditRechargeRequests (Status, RequestedOn DESC);
    PRINT '  + Q4: CreditRechargeRequests bana';
END
ELSE
    PRINT '  = Q4: CreditRechargeRequests pehle se hai';
GO

/* ---- Q5. UPI id aur rate — AppSettings me (OwnerId = 0 ka matlab global) -- */
IF NOT EXISTS (SELECT 1 FROM PUMP.AppSettings WHERE SettingKey = 'Credit.UpiId' AND OwnerId = 0)
    INSERT INTO PUMP.AppSettings (SettingKey, SettingValue, OwnerId, Description)
    VALUES ('Credit.UpiId', '', 0,
            'Jis UPI id par pump owner recharge ka paisa bhejenge. Khaali ho to recharge ka page recharge nahi lene dega.');

IF NOT EXISTS (SELECT 1 FROM PUMP.AppSettings WHERE SettingKey = 'Credit.UpiName' AND OwnerId = 0)
    INSERT INTO PUMP.AppSettings (SettingKey, SettingValue, OwnerId, Description)
    VALUES ('Credit.UpiName', '', 0,
            'UPI par jo naam dikhta hai. Owner ko paisa bhejte waqt milaan karne ke liye.');

IF NOT EXISTS (SELECT 1 FROM PUMP.AppSettings WHERE SettingKey = 'Credit.PricePerCredit' AND OwnerId = 0)
    INSERT INTO PUMP.AppSettings (SettingKey, SettingValue, OwnerId, Description)
    VALUES ('Credit.PricePerCredit', '0.50', 0,
            'Ek message ka daam (rupaye) jo aap owner se lete hain. Rs.100 me 200 message.');
PRINT '  = Q5: UPI aur rate ki settings taiyar';
GO

/* ---- Q6. Aapka stock ek nazar me -------------------------------------- */
CREATE OR ALTER PROCEDURE PUMP.sp_PlatformCredit_Summary
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Bought INT = ISNULL((SELECT SUM(CreditsBought) FROM PUMP.PlatformCreditPurchases), 0);
    /* Jo tenant ke wallet me pada hai + jo wo kharch kar chuke hain = jitna
       aapne bech diya. Bacha hua stock isi se nikalta hai. */
    DECLARE @Allocated INT = ISNULL((SELECT SUM(LifetimeAdded) FROM PUMP.OwnerCreditWallet), 0);
    DECLARE @Spent INT = ISNULL((SELECT SUM(LifetimeUsed) FROM PUMP.OwnerCreditWallet), 0);
    DECLARE @Pending INT = ISNULL((SELECT SUM(Credits) FROM PUMP.CreditRechargeRequests WHERE Status = 'PENDING'), 0);

    SELECT
        CreditsBought    = @Bought,
        AmountPaid       = ISNULL((SELECT SUM(AmountPaid) FROM PUMP.PlatformCreditPurchases), 0),
        CreditsAllocated = @Allocated,
        CreditsAvailable = @Bought - @Allocated,      -- itne aur bech sakte hain
        CreditsPending   = @Pending,                   -- approve ka intezaar
        CreditsSpent     = @Spent,
        TenantCount      = ISNULL((SELECT COUNT(*) FROM PUMP.OwnerCreditWallet WHERE Balance > 0), 0);
END
GO

PRINT '  + Q6: sp_PlatformCredit_Summary ready';
GO

/* ---- Q7. Aapne Twilio se khareeda — darj karo ------------------------- */
CREATE OR ALTER PROCEDURE PUMP.sp_PlatformCredit_Add
(
    @AmountPaid    DECIMAL(18,2),
    @CreditsBought INT,
    @Provider      NVARCHAR(40) = 'Twilio',
    @ReferenceNo   NVARCHAR(80) = NULL,
    @Notes         NVARCHAR(300) = NULL,
    @UserId        BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @CreditsBought IS NULL OR @CreditsBought <= 0
        THROW 50200, 'Number of messages must be more than zero.', 1;

    IF @AmountPaid IS NULL OR @AmountPaid < 0
        THROW 50201, 'Amount paid cannot be negative.', 1;

    INSERT INTO PUMP.PlatformCreditPurchases (Provider, AmountPaid, CreditsBought, ReferenceNo, Notes, CreatedBy)
    VALUES (@Provider, @AmountPaid, @CreditsBought, @ReferenceNo, @Notes, @UserId);

    EXEC PUMP.sp_PlatformCredit_Summary;
END
GO

PRINT '  + Q7: sp_PlatformCredit_Add ready';
GO

/* ---- Q8. Owner ka wallet ---------------------------------------------- */
CREATE OR ALTER PROCEDURE PUMP.sp_Wallet_Get
(
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        Balance       = ISNULL(w.Balance, 0),
        LifetimeAdded = ISNULL(w.LifetimeAdded, 0),
        LifetimeUsed  = ISNULL(w.LifetimeUsed, 0),
        PendingCredits = ISNULL((SELECT SUM(Credits) FROM PUMP.CreditRechargeRequests
                                 WHERE OwnerId = @OwnerId AND Status = 'PENDING'), 0),
        UpiId          = ISNULL((SELECT TOP 1 SettingValue FROM PUMP.AppSettings
                                 WHERE SettingKey = 'Credit.UpiId' AND OwnerId = 0), ''),
        UpiName        = ISNULL((SELECT TOP 1 SettingValue FROM PUMP.AppSettings
                                 WHERE SettingKey = 'Credit.UpiName' AND OwnerId = 0), ''),
        PricePerCredit = TRY_CONVERT(DECIMAL(18,2),
                                 (SELECT TOP 1 SettingValue FROM PUMP.AppSettings
                                  WHERE SettingKey = 'Credit.PricePerCredit' AND OwnerId = 0))
    FROM PUMP.Owners o
    LEFT JOIN PUMP.OwnerCreditWallet w ON w.OwnerId = o.Id
    WHERE o.Id = @OwnerId AND ISNULL(o.IsDeleted, 0) = 0;
END
GO

PRINT '  + Q8: sp_Wallet_Get ready';
GO

/* ---- Q9. Owner recharge maangta hai ----------------------------------- */
CREATE OR ALTER PROCEDURE PUMP.sp_Wallet_RequestRecharge
(
    @OwnerId      BIGINT,
    @Amount       DECIMAL(18,2),
    @UpiReference NVARCHAR(80) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Amount IS NULL OR @Amount <= 0
        THROW 50202, 'Please enter the amount you paid.', 1;

    DECLARE @Price DECIMAL(18,2) = TRY_CONVERT(DECIMAL(18,2),
        (SELECT TOP 1 SettingValue FROM PUMP.AppSettings
         WHERE SettingKey = 'Credit.PricePerCredit' AND OwnerId = 0));

    IF @Price IS NULL OR @Price <= 0
        THROW 50203, 'Message pricing is not set up yet. Please contact support.', 1;

    DECLARE @Credits INT = CAST(FLOOR(@Amount / @Price) AS INT);
    IF @Credits <= 0
        THROW 50204, 'That amount is too small to buy even one message.', 1;

    /* Ek waqt me ek hi request. Warna owner 10 request daal kar sab approve
       karwa lega aur ginti gadbad ho jayegi. */
    IF EXISTS (SELECT 1 FROM PUMP.CreditRechargeRequests
               WHERE OwnerId = @OwnerId AND Status = 'PENDING')
        THROW 50205, 'You already have a recharge waiting for approval. Please wait for it to be processed.', 1;

    INSERT INTO PUMP.CreditRechargeRequests (OwnerId, Amount, Credits, UpiReference)
    VALUES (@OwnerId, @Amount, @Credits, NULLIF(LTRIM(RTRIM(@UpiReference)), ''));

    SELECT Id = CAST(SCOPE_IDENTITY() AS BIGINT), Credits = @Credits;
END
GO

PRINT '  + Q9: sp_Wallet_RequestRecharge ready';
GO

/* ---- Q10. Aap approve karte hain — YAHI PAR STOCK KI JAANCH HAI --------
   Yahi wo jagah hai jiski baat hui thi. Aapke paas 200 message ka stock hai
   aur owner 2000 maang raha hai — to yahan ruk jayega, saaf batayega ki aapke
   paas kitne bache hain.

   Poora kaam ek transaction me, aur wallet ki row par UPDLOCK — taaki do
   approve ek saath chalen to bhi stock se zyada na nikle. */
CREATE OR ALTER PROCEDURE PUMP.sp_Wallet_ApproveRecharge
(
    @RequestId BIGINT,
    @UserId    BIGINT = NULL,
    @Note      NVARCHAR(300) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @OwnerId BIGINT, @Credits INT, @Status NVARCHAR(20);
    DECLARE @NewBalance INT;

    /* TRY/CATCH ke bina: THROW transaction ko "doomed" chhod deta tha, aur agar
       caller usi batch me aage kuch karta to "current transaction cannot be
       committed" milta. Yahi pattern sp_Owner_Create me pehle se hai. */
    BEGIN TRY
    BEGIN TRANSACTION;

        SELECT @OwnerId = OwnerId, @Credits = Credits, @Status = Status
        FROM PUMP.CreditRechargeRequests WITH (UPDLOCK, HOLDLOCK)
        WHERE Id = @RequestId;

        IF @OwnerId IS NULL
            THROW 50206, 'Recharge request not found.', 1;

        IF @Status <> 'PENDING'
            THROW 50207, 'This request has already been dealt with.', 1;

        /* Stock ki ginti — lock ke andar, taaki beech me koi aur approve na kar de. */
        DECLARE @Bought INT = ISNULL((SELECT SUM(CreditsBought) FROM PUMP.PlatformCreditPurchases), 0);
        DECLARE @Allocated INT = ISNULL((SELECT SUM(LifetimeAdded) FROM PUMP.OwnerCreditWallet WITH (UPDLOCK, HOLDLOCK)), 0);
        DECLARE @Available INT = @Bought - @Allocated;

        IF @Credits > @Available
            THROW 50208, 'Not enough platform credit. Buy more messages from your provider first, then approve this request.', 1;

        /* Wallet — na ho to bana do */
        IF NOT EXISTS (SELECT 1 FROM PUMP.OwnerCreditWallet WHERE OwnerId = @OwnerId)
            INSERT INTO PUMP.OwnerCreditWallet (OwnerId, Balance, LifetimeAdded, LifetimeUsed, UpdatedOn)
            VALUES (@OwnerId, 0, 0, 0, SYSDATETIME());

        UPDATE PUMP.OwnerCreditWallet
        SET Balance       = Balance + @Credits,
            LifetimeAdded = LifetimeAdded + @Credits,
            UpdatedOn     = SYSDATETIME()
        WHERE OwnerId = @OwnerId;

        SET @NewBalance = (SELECT Balance FROM PUMP.OwnerCreditWallet WHERE OwnerId = @OwnerId);

        INSERT INTO PUMP.OwnerCreditLedger (OwnerId, EntryType, Credits, BalanceAfter, ReferenceNo, Notes)
        SELECT @OwnerId, 'RECHARGE', @Credits, @NewBalance, UpiReference,
               CONCAT('Recharge of Rs.', CAST(Amount AS NVARCHAR(20)), ' approved')
        FROM PUMP.CreditRechargeRequests WHERE Id = @RequestId;

        UPDATE PUMP.CreditRechargeRequests
        SET Status = 'APPROVED', DecidedOn = SYSDATETIME(), DecidedBy = @UserId, DecisionNote = @Note
        WHERE Id = @RequestId;

    COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT Result = 'OK', OwnerId = @OwnerId, Credits = @Credits, NewBalance = @NewBalance;
END
GO

PRINT '  + Q10: sp_Wallet_ApproveRecharge ready (stock ki jaanch ke saath)';
GO

/* ---- Q11. Reject ------------------------------------------------------ */
CREATE OR ALTER PROCEDURE PUMP.sp_Wallet_RejectRecharge
(
    @RequestId BIGINT,
    @UserId    BIGINT = NULL,
    @Note      NVARCHAR(300) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.CreditRechargeRequests WHERE Id = @RequestId AND Status = 'PENDING')
        THROW 50207, 'This request has already been dealt with.', 1;

    UPDATE PUMP.CreditRechargeRequests
    SET Status = 'REJECTED', DecidedOn = SYSDATETIME(), DecidedBy = @UserId, DecisionNote = @Note
    WHERE Id = @RequestId;

    SELECT Result = 'OK';
END
GO

PRINT '  + Q11: sp_Wallet_RejectRecharge ready';
GO

/* ---- Q12. Message bhejte waqt ek credit kaato ------------------------
   Sandesh bhejne se PEHLE bulaya jaata hai. Balance na ho to 0 lautata hai
   aur sandesh bhejа hi nahi jaata — warna aap apne paise se doosre ka
   sandesh bhej denge. */
CREATE OR ALTER PROCEDURE PUMP.sp_Wallet_Consume
(
    @OwnerId  BIGINT,
    @AlertKey NVARCHAR(40) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @NewBalance INT;

    BEGIN TRANSACTION;

        /* UPDLOCK — do sandesh ek saath jayein to bhi balance minus me na jaye. */
        DECLARE @Balance INT = (SELECT Balance FROM PUMP.OwnerCreditWallet WITH (UPDLOCK, HOLDLOCK)
                                WHERE OwnerId = @OwnerId);

        IF @Balance IS NULL OR @Balance <= 0
        BEGIN
            COMMIT TRANSACTION;
            SELECT Allowed = CAST(0 AS BIT), Balance = ISNULL(@Balance, 0);
            RETURN;
        END

        UPDATE PUMP.OwnerCreditWallet
        SET Balance      = Balance - 1,
            LifetimeUsed = LifetimeUsed + 1,
            UpdatedOn    = SYSDATETIME()
        WHERE OwnerId = @OwnerId;

        SET @NewBalance = @Balance - 1;

        INSERT INTO PUMP.OwnerCreditLedger (OwnerId, EntryType, Credits, BalanceAfter, AlertKey)
        VALUES (@OwnerId, 'USE', -1, @NewBalance, @AlertKey);

    COMMIT TRANSACTION;

    SELECT Allowed = CAST(1 AS BIT), Balance = @NewBalance;
END
GO

PRINT '  + Q12: sp_Wallet_Consume ready';
GO

/* ---- Q13. Ledger (owner apna hisaab dekhe) ---------------------------- */
CREATE OR ALTER PROCEDURE PUMP.sp_Wallet_Ledger
(
    @OwnerId  BIGINT,
    @TopCount INT = 50
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (@TopCount)
        Id, EntryOn, EntryType, Credits, BalanceAfter, AlertKey, ReferenceNo, Notes
    FROM PUMP.OwnerCreditLedger
    WHERE OwnerId = @OwnerId
    ORDER BY EntryOn DESC, Id DESC;
END
GO

/* ---- Q12b. Sandesh gaya hi nahi -> credit wapas ----------------------
   Provider se gadbad ho (Twilio down, galat number) to paisa lena galat hai.
   Ye sirf wahi credit wapas karta hai jo abhi kata tha. */
CREATE OR ALTER PROCEDURE PUMP.sp_Wallet_Refund
(
    @OwnerId  BIGINT,
    @AlertKey NVARCHAR(40) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @NewBalance INT;

    BEGIN TRY
    BEGIN TRANSACTION;

        IF NOT EXISTS (SELECT 1 FROM PUMP.OwnerCreditWallet WITH (UPDLOCK, HOLDLOCK) WHERE OwnerId = @OwnerId)
        BEGIN
            COMMIT TRANSACTION;
            SELECT Allowed = CAST(0 AS BIT), Balance = 0;
            RETURN;
        END

        UPDATE PUMP.OwnerCreditWallet
        SET Balance      = Balance + 1,
            LifetimeUsed = CASE WHEN LifetimeUsed > 0 THEN LifetimeUsed - 1 ELSE 0 END,
            UpdatedOn    = SYSDATETIME()
        WHERE OwnerId = @OwnerId;

        SET @NewBalance = (SELECT Balance FROM PUMP.OwnerCreditWallet WHERE OwnerId = @OwnerId);

        INSERT INTO PUMP.OwnerCreditLedger (OwnerId, EntryType, Credits, BalanceAfter, AlertKey, Notes)
        VALUES (@OwnerId, 'REFUND', 1, @NewBalance, @AlertKey, 'Message could not be delivered');

    COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT Allowed = CAST(1 AS BIT), Balance = @NewBalance;
END
GO

PRINT '  + Q12b: sp_Wallet_Refund ready';
GO

PRINT '  + Q13: sp_Wallet_Ledger ready';
GO

/* ---- Q14. Recharge requests ki list ----------------------------------
   @OwnerId diya to sirf usi ki (owner apni list dekhta hai);
   NULL diya to sab (superadmin ke liye). */
CREATE OR ALTER PROCEDURE PUMP.sp_Wallet_RechargeList
(
    @OwnerId BIGINT = NULL,
    @Status  NVARCHAR(20) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        r.Id, r.OwnerId, OwnerName = o.Name, r.RequestedOn, r.Amount, r.Credits,
        r.UpiReference, r.Status, r.DecidedOn, r.DecisionNote
    FROM PUMP.CreditRechargeRequests r
    JOIN PUMP.Owners o ON o.Id = r.OwnerId
    WHERE (@OwnerId IS NULL OR r.OwnerId = @OwnerId)
      AND (@Status IS NULL OR r.Status = @Status)
    ORDER BY CASE WHEN r.Status = 'PENDING' THEN 0 ELSE 1 END, r.RequestedOn DESC;
END
GO

PRINT '  + Q14: sp_Wallet_RechargeList ready';
GO

/* ---- Q15. UPI / rate ki setting badalna (superadmin) ------------------ */
CREATE OR ALTER PROCEDURE PUMP.sp_PlatformCredit_SaveSettings
(
    @UpiId          NVARCHAR(200) = NULL,
    @UpiName        NVARCHAR(200) = NULL,
    @PricePerCredit DECIMAL(18,2) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    /* UPI id ka aakar: kuch@kuch . Galat id par owner ka paisa kahin aur chala
       jayega aur pata bhi nahi chalega. */
    IF @UpiId IS NOT NULL AND LTRIM(RTRIM(@UpiId)) <> ''
       AND (@UpiId NOT LIKE '%_@_%' OR @UpiId LIKE '% %')
        THROW 50209, 'That does not look like a UPI ID. It should look like name@bank.', 1;

    IF @PricePerCredit IS NOT NULL AND @PricePerCredit <= 0
        THROW 50210, 'Price per message must be more than zero.', 1;

    IF @UpiId IS NOT NULL
        UPDATE PUMP.AppSettings SET SettingValue = LTRIM(RTRIM(@UpiId))
        WHERE SettingKey = 'Credit.UpiId' AND OwnerId = 0;

    IF @UpiName IS NOT NULL
        UPDATE PUMP.AppSettings SET SettingValue = LTRIM(RTRIM(@UpiName))
        WHERE SettingKey = 'Credit.UpiName' AND OwnerId = 0;

    IF @PricePerCredit IS NOT NULL
        UPDATE PUMP.AppSettings SET SettingValue = CAST(@PricePerCredit AS NVARCHAR(20))
        WHERE SettingKey = 'Credit.PricePerCredit' AND OwnerId = 0;

    SELECT
        UpiId          = ISNULL((SELECT TOP 1 SettingValue FROM PUMP.AppSettings WHERE SettingKey='Credit.UpiId' AND OwnerId = 0), ''),
        UpiName        = ISNULL((SELECT TOP 1 SettingValue FROM PUMP.AppSettings WHERE SettingKey='Credit.UpiName' AND OwnerId = 0), ''),
        PricePerCredit = TRY_CONVERT(DECIMAL(18,2), (SELECT TOP 1 SettingValue FROM PUMP.AppSettings WHERE SettingKey='Credit.PricePerCredit' AND OwnerId = 0));
END
GO

/* ---- Q16. Wallet ka menu (owner ke liye) ------------------------------
   Alerts ke theek baad — dono ek hi kaam ke hain (sandesh). */
IF NOT EXISTS (SELECT 1 FROM PUMP.Menus WHERE Route = '/wallet')
BEGIN
    INSERT INTO PUMP.Menus (ParentId, MenuName, Route, Icon, Sequence, IsVisible, IsActive)
    SELECT ParentId, N'Message Balance', '/wallet', N'account_balance_wallet', 31, 1, 1
    FROM PUMP.Menus WHERE Route = '/alerts';

    DECLARE @WalletMenuId BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);
    DECLARE @AlertsMenuId BIGINT = (SELECT Id FROM PUMP.Menus WHERE Route = '/alerts');

    INSERT INTO PUMP.RoleMenus (RoleId, MenuId, CanView, CanCreate, CanEdit, CanDelete)
    SELECT rm.RoleId, @WalletMenuId, rm.CanView, rm.CanCreate, rm.CanEdit, rm.CanDelete
    FROM PUMP.RoleMenus rm
    WHERE rm.MenuId = @AlertsMenuId
      AND NOT EXISTS (SELECT 1 FROM PUMP.RoleMenus x
                      WHERE x.RoleId = rm.RoleId AND x.MenuId = @WalletMenuId);

    PRINT '  + Q16: Message Balance ka menu bana';
END
ELSE
    PRINT '  = Q16: Message Balance ka menu pehle se hai';
GO

PRINT '  + Q15: sp_PlatformCredit_SaveSettings ready';
PRINT '=== Section Q done ===';
GO

/* ================================================================================
   SECTION R — Meter ki kadi (meter chain)
   --------------------------------------------------------------------------------
   Dikkat: shift kholte waqt opening reading jaisi bheji jaati thi waisi hi rakh li
   jaati thi. Us nozzle ki pichli shift ke closing se milaan koi nahi karta tha.

   Aam din me khatra nahi — UI opening ko pichli closing se khud bhar deta hai.
   Khatra do jagah tha:
     * "Forgot a day? Enter it later" se purani tareekh ki shift beech me daalna
     * bhari hui value haath se badal dena

   Aisa hone par us din ka sale, stock aur cash — teeno galat, aur koi warning nahi.

   Do taraf se pakadte hain:
     R1. sp_Shift_Open ab kadi jodta hai. Farak mile to rok deta hai aur saaf batata
         hai kitna farak hai. Meter badla ho ya rollover ho to @AllowMeterGap = 1
         bhej kar aage badh sakte hain (jaayaz case rukna nahi chahiye).
     R2. sp_Shift_MeterChainCheck — poori list, kahin bhi kadi tooti ho to dikha deta
         hai. Ye rokta nahi, sirf batata hai — taaki ek jagah nazar chook jaye to
         doosri jagah pakad me aa jaye.
   ================================================================================ */
PRINT '';
PRINT '=== Section R: meter ki kadi ===';
GO

/* ---- R1: shift kholte waqt kadi ki jaanch ---- */
CREATE OR ALTER PROCEDURE PUMP.sp_Shift_Open
(
    @OwnerId            BIGINT,
    @PumpId             BIGINT,
    @OperatorUserId     BIGINT = NULL,
    @ShiftDate          DATE,
    @ShiftCode          NVARCHAR(30),
    @OpeningCash        DECIMAL(18,2) = 0,
    @Notes              NVARCHAR(500) = NULL,
    @NozzleReadingsJson NVARCHAR(MAX) = NULL,
    @UserId             BIGINT = NULL,
    @OperatorEmployeeId BIGINT = NULL,
    /* Meter badla, rollover hua, ya user ne jaan-boojh kar farak maana —
       tab client ye 1 bhejta hai aur R1 wali rok hat jaati hai. */
    @AllowMeterGap      BIT    = 0
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF EXISTS (SELECT 1 FROM PUMP.ShiftHeaders
               WHERE OwnerId = @OwnerId AND PumpId = @PumpId AND Status = 'OPEN')
    BEGIN
        SELECT CAST(-1 AS BIGINT) AS Id;   -- pehle se ek shift khuli hai
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM PUMP.ShiftHeaders
               WHERE PumpId = @PumpId AND ShiftDate = @ShiftDate AND ShiftCode = @ShiftCode)
    BEGIN
        SELECT CAST(-3 AS BIGINT) AS Id;   -- isi din ka isi code ka shift already hai
        RETURN;
    END

    /* In-charge usi owner ka aur USI PUMP ka employee ho. */
    IF @OperatorEmployeeId IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM PUMP.Employees
        WHERE Id = @OperatorEmployeeId
          AND OwnerId = @OwnerId
          AND PumpId = @PumpId
          AND ISNULL(IsDeleted, 0) = 0)
        THROW 50153, 'Shift in-charge not found, or that employee does not belong to this pump.', 1;

    /* OperatorUserId ab employee ke record se aata hai — sach ek hi jagah rahe. */
    IF @OperatorEmployeeId IS NOT NULL
        SELECT @OperatorUserId = UserId FROM PUMP.Employees WHERE Id = @OperatorEmployeeId;

    DECLARE @ShiftId BIGINT;

    BEGIN TRANSACTION;

        INSERT INTO PUMP.ShiftHeaders
            (OwnerId, PumpId, OperatorUserId, OperatorEmployeeId, ShiftDate, ShiftCode, OpeningCash, Notes, OpenedOn, Status, CreatedBy)
        VALUES
            (@OwnerId, @PumpId, @OperatorUserId, @OperatorEmployeeId, @ShiftDate, @ShiftCode, @OpeningCash, @Notes, SYSDATETIME(), 'OPEN', @UserId);

        SET @ShiftId = CAST(SCOPE_IDENTITY() AS BIGINT);

        IF @NozzleReadingsJson IS NOT NULL AND ISJSON(@NozzleReadingsJson) = 1
        BEGIN
            INSERT INTO PUMP.ShiftNozzleReadings
                (OwnerId, PumpId, ShiftId, NozzleId, ProductId, OpeningReading, Rate,
                 EmployeeId, FloatGiven, CreatedBy)
            SELECT
                @OwnerId, @PumpId, @ShiftId,
                x.NozzleId,
                n.ProductId,                          -- nozzle master se lo, client se nahi
                ISNULL(x.OpeningReading, 0),
                /* Rate har nozzle ka apne product ka, aur US DIN ka. */
                PUMP.fn_ProductRateOnDate(n.ProductId,
                    DATEADD(HOUR, 23, CAST(@ShiftDate AS DATETIME2(7)))),

                /* Aadmi usi owner KA AUR USI PUMP ka ho. Na mile to NULL. */
                (SELECT e.Id FROM PUMP.Employees e
                 WHERE e.Id = x.EmployeeId
                   AND e.OwnerId = @OwnerId
                   AND e.PumpId  = @PumpId
                   AND ISNULL(e.IsDeleted, 0) = 0),

                ISNULL(x.FloatGiven, 0),
                @UserId
            FROM OPENJSON(@NozzleReadingsJson)
            WITH (NozzleId       BIGINT        '$.NozzleId',
                  OpeningReading DECIMAL(18,3) '$.OpeningReading',
                  EmployeeId     BIGINT        '$.EmployeeId',
                  FloatGiven     DECIMAL(18,2) '$.FloatGiven') x
            INNER JOIN PUMP.Nozzles  n ON n.Id = x.NozzleId
                                      AND n.PumpId = @PumpId
                                      AND n.OwnerId = @OwnerId
                                      AND n.IsActive = 1
                                      AND ISNULL(n.IsDeleted, 0) = 0
            INNER JOIN PUMP.Products p ON p.Id = n.ProductId
            WHERE ISNULL(x.NozzleId, 0) > 0;
        END

        IF NOT EXISTS (SELECT 1 FROM PUMP.ShiftNozzleReadings WHERE ShiftId = @ShiftId)
        BEGIN
            ROLLBACK TRANSACTION;
            THROW 50130, 'No nozzle could be added to this shift. Check that the nozzles belong to the selected pump and are active.', 1;
        END

        IF EXISTS
        (
            SELECT 1
            FROM PUMP.ShiftNozzleReadings snr
            JOIN PUMP.Nozzles n ON n.Id = snr.NozzleId
            WHERE snr.ShiftId = @ShiftId
              AND n.TankId IS NULL
              AND (SELECT COUNT(*) FROM PUMP.Tanks t
                   WHERE t.PumpId = @PumpId AND t.ProductId = n.ProductId AND t.IsActive = 1) <> 1
        )
        BEGIN
            ROLLBACK TRANSACTION;
            THROW 50003, 'Some nozzles have no tank set (or the product has more than one tank). Pick a tank in the Nozzle master.', 1;
        END

        /* ---- R1: meter ki kadi ----
           Har nozzle ka opening us nozzle ki PICHLI shift ke closing se milna
           chahiye. "Pichli" tareekh se nikalte hain, Id se nahi — kyunki purani
           tareekh ki shift baad me bhi daali ja sakti hai. */
        IF @AllowMeterGap = 0
        BEGIN
            DECLARE @GapMsg NVARCHAR(1800);

            ;WITH chain AS
            (
                SELECT
                    n.NozzleCode,
                    snr.OpeningReading,
                    LastClosing =
                    (
                        SELECT TOP 1 r2.ClosingReading
                        FROM PUMP.ShiftNozzleReadings r2
                        JOIN PUMP.ShiftHeaders h2 ON h2.Id = r2.ShiftId
                        WHERE r2.NozzleId = snr.NozzleId
                          AND r2.ClosingReading IS NOT NULL
                          AND h2.Id <> @ShiftId
                          AND (h2.ShiftDate < @ShiftDate
                               OR (h2.ShiftDate = @ShiftDate AND h2.Id < @ShiftId))
                        ORDER BY h2.ShiftDate DESC, h2.Id DESC
                    )
                FROM PUMP.ShiftNozzleReadings snr
                JOIN PUMP.Nozzles n ON n.Id = snr.NozzleId
                WHERE snr.ShiftId = @ShiftId
            )
            SELECT @GapMsg = STRING_AGG(
                       CAST('Nozzle ' + NozzleCode
                          + ': last closing was ' + FORMAT(LastClosing, 'N3')
                          + ' but you entered ' + FORMAT(OpeningReading, 'N3')
                          + ' (' + FORMAT(OpeningReading - LastClosing, 'N3') + ' difference).'
                            AS NVARCHAR(MAX)), ' ')
            FROM chain
            WHERE LastClosing IS NOT NULL
              AND ABS(LastClosing - OpeningReading) > 0.001;

            IF @GapMsg IS NOT NULL
            BEGIN
                ROLLBACK TRANSACTION;
                SET @GapMsg = 'Meter reading does not continue from the last shift. ' + @GapMsg
                            + ' Correct the opening reading, or tick "Meter was changed - accept this difference" to continue.';
                THROW 50132, @GapMsg, 1;
            END
        END

    COMMIT TRANSACTION;

    SELECT @ShiftId AS Id;
END
GO
PRINT '  + R1: sp_Shift_Open ab meter ki kadi jodta hai (@AllowMeterGap se chhoot)';
GO

/* ---- R2: kahin bhi kadi tooti ho to dikha do ----
   Rokta kuch nahi. Har nozzle ki shift tareekh ke kram me lagakar dekhta hai ki
   agli shift ka opening pichli ke closing se juda hai ya nahi. */
CREATE OR ALTER PROCEDURE PUMP.sp_Shift_MeterChainCheck
(
    @OwnerId BIGINT,
    @PumpId  BIGINT = NULL,
    @Days    INT    = 90
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @OwnerId IS NULL OR @OwnerId <= 0
        THROW 50133, 'Owner is required.', 1;

    DECLARE @From DATE = DATEADD(DAY, -ABS(ISNULL(@Days, 90)), CAST(SYSDATETIME() AS DATE));

    ;WITH ordered AS
    (
        SELECT
            r.NozzleId,
            n.NozzleCode,
            h.Id        AS ShiftId,
            h.PumpId,
            h.ShiftDate,
            h.ShiftCode,
            r.OpeningReading,
            PrevClosing  = LAG(r.ClosingReading) OVER (PARTITION BY r.NozzleId ORDER BY h.ShiftDate, h.Id),
            PrevShiftId  = LAG(h.Id)             OVER (PARTITION BY r.NozzleId ORDER BY h.ShiftDate, h.Id),
            PrevDate     = LAG(h.ShiftDate)      OVER (PARTITION BY r.NozzleId ORDER BY h.ShiftDate, h.Id)
        FROM PUMP.ShiftNozzleReadings r
        JOIN PUMP.ShiftHeaders h ON h.Id = r.ShiftId
        JOIN PUMP.Nozzles      n ON n.Id = r.NozzleId
        WHERE h.OwnerId = @OwnerId
          AND (@PumpId IS NULL OR h.PumpId = @PumpId)
          AND h.ShiftDate >= @From
    )
    SELECT
        NozzleId,
        NozzleCode,
        PumpId,
        PrevShiftId,
        PrevDate,
        PrevClosing,
        ShiftId,
        ShiftDate,
        ShiftCode,
        OpeningReading,
        GapQty = CAST(OpeningReading - PrevClosing AS DECIMAL(18,3))
    FROM ordered
    WHERE PrevClosing IS NOT NULL
      AND ABS(OpeningReading - PrevClosing) > 0.001
    ORDER BY ShiftDate DESC, NozzleCode;
END
GO
PRINT '  + R2: sp_Shift_MeterChainCheck ready';
PRINT '=== Section R done ===';
GO

/* ================================================================================
   SECTION S — Expense head (kharch ke khaate)
   --------------------------------------------------------------------------------
   Dikkat: Expenses page par "No expense head available" aata tha, yaani kharch
   darj hi nahi ho sakta tha. Wajah — ExpenseHeads table khaali tha:

     * script me uska koi seed nahi tha,
     * sp_Owner_Create naye tenant ke liye kuch nahi banata tha,
     * aur head jodne/dekhne ke liye koi SP ya page bhi nahi tha.

   Yaani naye pump par Expenses module SHURU SE HI bekaar tha.

   S1. Har owner ke liye standard khaate ban jaate hain (jiske paas ek bhi na ho).
   S2. sp_Owner_Create ab naye tenant ko bhi wahi khaate deta hai.
   S3. sp_ExpenseHead_List / _Save / _Delete — taaki owner apne khaate khud
       jod, badal aur hata sake.
   S4. "Expense Heads" ka menu.
   ================================================================================ */
PRINT '';
PRINT '=== Section S: expense head ===';
GO

/* ---- S1: purane owners ko standard khaate ---- */
IF OBJECT_ID('tempdb..#DefaultHeads') IS NOT NULL DROP TABLE #DefaultHeads;
CREATE TABLE #DefaultHeads (HeadName NVARCHAR(150) PRIMARY KEY);
INSERT INTO #DefaultHeads (HeadName) VALUES
    (N'Salary'), (N'Electricity'), (N'Rent'), (N'Repair & Maintenance'),
    (N'Fuel & Transport'), (N'Office & Stationery'), (N'Bank Charges'),
    (N'Licence & Fees'), (N'Tea & Refreshment'), (N'Miscellaneous');

DECLARE @AddedFor INT = 0;

/* PumpId is table me NOT NULL hai, yaani khaate PUMP-wise hain, owner-wise
   nahi. Isliye har pump ke liye apni row banti hai. */
INSERT INTO PUMP.ExpenseHeads (OwnerId, PumpId, HeadName, IsActive)
SELECT p.OwnerId, p.Id, d.HeadName, 1
FROM PUMP.Pumps p
JOIN PUMP.Owners o ON o.Id = p.OwnerId
CROSS JOIN #DefaultHeads d
WHERE o.Name <> N'-- SYSTEM --'
  AND ISNULL(o.IsDeleted, 0) = 0
  AND ISNULL(p.IsDeleted, 0) = 0
  /* Sirf un pump ko jinke paas ek bhi khaata nahi hai — jinhone apne khud ke
     bana liye hain unme hum apni list nahi thoponge. */
  AND NOT EXISTS (SELECT 1 FROM PUMP.ExpenseHeads e
                  WHERE e.PumpId = p.Id AND ISNULL(e.IsDeleted, 0) = 0);

SET @AddedFor = @@ROWCOUNT;
DROP TABLE #DefaultHeads;

IF @AddedFor > 0
    PRINT '  * S1: ' + CAST(@AddedFor AS VARCHAR) + ' expense head bana diye (jin owners ke paas ek bhi nahi tha)';
ELSE
    PRINT '  = S1: sab owners ke paas expense head pehle se hain';
GO

/* ---- S3: expense head ka apna master ----
   OwnerId hamesha caller se aata hai (API JWT se bharti hai), kabhi row se nahi. */
CREATE OR ALTER PROCEDURE PUMP.sp_ExpenseHead_List
(
    @OwnerId BIGINT,
    @PumpId  BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @OwnerId IS NULL OR @OwnerId <= 0
        THROW 50220, 'Owner is required.', 1;

    /* CLAUDE.md niyam 5: ExpenseHeadDto positional record hai —
       (Id, OwnerId, PumpId, HeadName, IsActive). Yahan CreatedOn bhi de rahe
       the, to Dapper koi matching constructor dhoondh nahi paata tha aur
       endpoint 400 deta tha; client use chup-chaap khaali list maan leta tha
       aur page par "No expense head available" chhap jaata tha.
       Column badlo to DTO bhi usi waqt badalna. */
    SELECT
        Id, OwnerId, PumpId, HeadName, IsActive
    FROM PUMP.ExpenseHeads
    WHERE OwnerId = @OwnerId
      AND ISNULL(IsDeleted, 0) = 0
      AND (@PumpId IS NULL OR PumpId = @PumpId)
    ORDER BY HeadName;
END
GO
PRINT '  + S3: sp_ExpenseHead_List ready';
GO

CREATE OR ALTER PROCEDURE PUMP.sp_ExpenseHead_Save
(
    @Id       BIGINT = NULL,
    @OwnerId  BIGINT,
    @PumpId   BIGINT = NULL,
    @HeadName NVARCHAR(150),
    @IsActive BIT = 1,
    @UserId   BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @HeadName = LTRIM(RTRIM(ISNULL(@HeadName, '')));

    IF @OwnerId IS NULL OR @OwnerId <= 0
        THROW 50220, 'Owner is required.', 1;

    IF @HeadName = ''
        THROW 50221, 'Enter a name for the expense head.', 1;

    /* PumpId NOT NULL hai. Na aaye to owner ke pehle pump par daal dete hain —
       ek hi pump wale ke liye ye sawaal hi bekaar hai. */
    IF @PumpId IS NULL OR @PumpId <= 0
        SELECT TOP 1 @PumpId = Id FROM PUMP.Pumps
        WHERE OwnerId = @OwnerId AND ISNULL(IsDeleted, 0) = 0 ORDER BY Id;

    IF @PumpId IS NULL
        THROW 50224, 'Create a pump first, then add expense heads.', 1;

    /* Pump usi owner ka ho — id badal kar doosre tenant me row na ban jaye. */
    IF NOT EXISTS (SELECT 1 FROM PUMP.Pumps
                   WHERE Id = @PumpId AND OwnerId = @OwnerId AND ISNULL(IsDeleted, 0) = 0)
        THROW 50225, 'That pump does not belong to you.', 1;

    /* Ek hi naam do baar na bane — warna report me kharch do jagah bat jaata hai. */
    IF EXISTS (SELECT 1 FROM PUMP.ExpenseHeads
               WHERE OwnerId = @OwnerId
                 AND HeadName = @HeadName
                 AND ISNULL(IsDeleted, 0) = 0
                 AND (@Id IS NULL OR Id <> @Id))
        THROW 50222, 'An expense head with this name already exists.', 1;

    IF @Id IS NULL OR @Id = 0
    BEGIN
        INSERT INTO PUMP.ExpenseHeads (OwnerId, PumpId, HeadName, IsActive, CreatedBy)
        VALUES (@OwnerId, @PumpId, @HeadName, ISNULL(@IsActive, 1), @UserId);

        SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS Id;
        RETURN;
    END

    /* Doosre owner ki row na chhoo paye — id andaaze se badalne ka rasta band. */
    IF NOT EXISTS (SELECT 1 FROM PUMP.ExpenseHeads
                   WHERE Id = @Id AND OwnerId = @OwnerId AND ISNULL(IsDeleted, 0) = 0)
        THROW 50223, 'That expense head was not found.', 1;

    UPDATE PUMP.ExpenseHeads
    SET HeadName   = @HeadName,
        PumpId     = @PumpId,
        IsActive   = ISNULL(@IsActive, 1),
        UpdatedOn  = SYSDATETIME(),
        ModifiedBy = @UserId,
        ModifiedOn = SYSDATETIME()
    WHERE Id = @Id AND OwnerId = @OwnerId;

    SELECT @Id AS Id;
END
GO
PRINT '  + S3: sp_ExpenseHead_Save ready';
GO

CREATE OR ALTER PROCEDURE PUMP.sp_ExpenseHead_Delete
(
    @Id      BIGINT,
    @OwnerId BIGINT,
    @UserId  BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.ExpenseHeads
                   WHERE Id = @Id AND OwnerId = @OwnerId AND ISNULL(IsDeleted, 0) = 0)
        THROW 50223, 'That expense head was not found.', 1;

    /* Jiske naam par kharch darj ho chuka hai use mitate nahi — warna purani
       report me khaate ka naam gayab ho jayega. Sirf band kar dete hain. */
    IF EXISTS (SELECT 1 FROM PUMP.ExpenseTransactions WHERE ExpenseHeadId = @Id)
    BEGIN
        UPDATE PUMP.ExpenseHeads
        SET IsActive = 0, UpdatedOn = SYSDATETIME(), ModifiedBy = @UserId, ModifiedOn = SYSDATETIME()
        WHERE Id = @Id AND OwnerId = @OwnerId;

        SELECT CAST(0 AS BIT) AS Deleted, CAST(1 AS BIT) AS Deactivated;
        RETURN;
    END

    UPDATE PUMP.ExpenseHeads
    SET IsDeleted = 1, DeletedOn = SYSDATETIME(), DeletedBy = @UserId
    WHERE Id = @Id AND OwnerId = @OwnerId;

    SELECT CAST(1 AS BIT) AS Deleted, CAST(0 AS BIT) AS Deactivated;
END
GO
PRINT '  + S3: sp_ExpenseHead_Delete ready';
GO

/* ---- S4: menu ----
   ABHI NAHI. SP taiyar hain, par client par /expense-head ka page abhi bana
   nahi hai — menu daal dete to link 404 par le jaata. Page banne ke baad yahan
   menu ka INSERT jod dena.

   Filhaal owner ko khaate khud jodne ki zaroorat nahi: S1 aur sp_Owner_Create
   har pump ko 10 standard khaate de dete hain. */
IF EXISTS (SELECT 1 FROM PUMP.Menus WHERE Route = '/expense-head')
BEGIN
    /* Pehle ke chale hue run me ye menu ban gaya tha — hata dete hain,
       warna sidebar me ek aisa link rehta hai jo kahin le jaata hi nahi. */
    DELETE rm FROM PUMP.RoleMenus rm
    JOIN PUMP.Menus m ON m.Id = rm.MenuId
    WHERE m.Route = '/expense-head';

    DELETE FROM PUMP.Menus WHERE Route = '/expense-head';
    PRINT '  * S4: /expense-head ka adhoora menu hata diya (page abhi nahi bana)';
END
ELSE
    PRINT '  i S4: Expense Heads ka menu abhi nahi banaya (page pending)';
GO

PRINT '=== Section S done ===';
GO

/* ================================================================================
   SECTION T — Employee code do logon ko ek jaisa mil jaata tha
   --------------------------------------------------------------------------------
   Dikkat: "EMP-001" jaisa code CLIENT banata tha — maujooda list dekh kar agla
   number nikal leta tha (OperationsController: GenerateNextEmployeeCode).

   Do log ek hi waqt par form kholein to dono ko "EMP-003" dikhta tha, aur dono
   save ho jaate the. DB par koi rok nahi thi — EmployeeCode par koi unique
   index tha hi nahi. Nateeja: do aadmi, ek hi code. Salary, attendant cash aur
   report — sab me uljhan.

   Ilaaj (dono zaroori hain):
     T1. Purane duplicate code alag kar do.
     T2. (PumpId, EmployeeCode) par UNIQUE index — DB khud rok de.
     T3. Code ab SP banata hai, save ke waqt, transaction ke andar. Client jo
         bheje wo sirf sujhav hai; wo khaali ho ya kisi aur ne beech me le liya
         ho, to SP agla khaali number khud de deta hai.

   Yaani do log ek saath save karein to dono ko alag code milega — kisi ko koi
   error bhi nahi dikhega.
   ================================================================================ */
PRINT '';
PRINT '=== Section T: employee code ===';
GO

/* ---- T1: purane duplicate theek karo ---- */
IF EXISTS (
    SELECT 1 FROM PUMP.Employees
    WHERE ISNULL(IsDeleted, 0) = 0 AND ISNULL(EmployeeCode, '') <> ''
    GROUP BY PumpId, EmployeeCode HAVING COUNT(*) > 1)
BEGIN
    ;WITH dup AS
    (
        SELECT Id, PumpId, EmployeeCode,
               rn = ROW_NUMBER() OVER (PARTITION BY PumpId, EmployeeCode ORDER BY Id)
        FROM PUMP.Employees
        WHERE ISNULL(IsDeleted, 0) = 0 AND ISNULL(EmployeeCode, '') <> ''
    )
    /* Pehle wala apna code rakhta hai; baad walon ko unki Id ke saath alag
       kar dete hain — kaam rukta nahi, aur owner baad me theek kar sakta hai. */
    UPDATE dup
    SET EmployeeCode = LEFT(EmployeeCode, 20) + '-D' + CAST(Id AS NVARCHAR(10))
    WHERE rn > 1;

    PRINT '  * T1: duplicate employee code alag kar diye';
END
ELSE
    PRINT '  = T1: koi duplicate employee code nahi mila';
GO

/* ---- T2: DB par pakki rok ----
   Filtered index: mitaye hue (soft-deleted) aur khaali code ise nahi rokte. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_Employees_PumpCode'
               AND object_id = OBJECT_ID('PUMP.Employees'))
BEGIN
    CREATE UNIQUE INDEX UX_Employees_PumpCode
        ON PUMP.Employees (PumpId, EmployeeCode)
        WHERE IsDeleted = 0 AND EmployeeCode IS NOT NULL;
    PRINT '  + T2: UX_Employees_PumpCode bana (ek pump par ek hi code)';
END
ELSE
    PRINT '  = T2: UX_Employees_PumpCode pehle se hai';
GO

/* ---- T3: agla khaali code nikalne wala helper ----
   "EMP-007" jaise code me se number nikal kar sabse bada dhoondhta hai aur
   usse agla deta hai. Jo code is dhaanche me nahi hain unhe chhod deta hai. */
CREATE OR ALTER FUNCTION PUMP.fn_NextEmployeeCode (@PumpId BIGINT)
RETURNS NVARCHAR(30)
AS
BEGIN
    DECLARE @MaxNo INT =
    (
        SELECT ISNULL(MAX(TRY_CAST(SUBSTRING(EmployeeCode, 5, 20) AS INT)), 0)
        FROM PUMP.Employees
        WHERE PumpId = @PumpId
          AND ISNULL(IsDeleted, 0) = 0
          AND EmployeeCode LIKE 'EMP-%'
          AND TRY_CAST(SUBSTRING(EmployeeCode, 5, 20) AS INT) IS NOT NULL
    );

    RETURN 'EMP-' + RIGHT('000' + CAST(@MaxNo + 1 AS NVARCHAR(10)), 3);
END
GO
PRINT '  + T3: fn_NextEmployeeCode ready';
GO

/* ---- T3b: sp_Employee_Save ab code khud sambhalta hai ---- */
CREATE OR ALTER PROCEDURE [PUMP].[sp_Employee_Save]
(
    @Id BIGINT = NULL,
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @UserId BIGINT = NULL,
    @EmployeeCode NVARCHAR(30),
    @FullName NVARCHAR(150),
    @Mobile NVARCHAR(20) = NULL,
    @JoinDate DATE,
    @Designation NVARCHAR(80) = NULL,
    @MonthlySalary DECIMAL(18,2) = 0,
    @IsActive BIT = 1
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Login usi owner ka ho — id badal kar doosre tenant ka login na jud jaye. */
    IF @UserId IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM PUMP.Users
        WHERE Id = @UserId AND OwnerId = @OwnerId AND ISNULL(IsDeleted, 0) = 0)
        THROW 50150, 'Login user not found, or it does not belong to your account.', 1;

    /* Ek login is pump par sirf ek hi employee ka. */
    IF @UserId IS NOT NULL AND EXISTS (
        SELECT 1 FROM PUMP.Employees
        WHERE UserId = @UserId
          AND PumpId = @PumpId
          AND ISNULL(IsDeleted, 0) = 0
          AND Id <> ISNULL(@Id, 0))
        THROW 50151, 'This login is already linked to another employee on this pump.', 1;

    SET @EmployeeCode = LTRIM(RTRIM(ISNULL(@EmployeeCode, '')));

    BEGIN TRANSACTION;

        /* Yahi wo jagah hai jahan pehle do log takra jaate the.
           UPDLOCK/HOLDLOCK se ek waqt me ek hi save is pump ka code chunta hai;
           doosra wala thoda ruk kar AGLA number uthata hai. */
        DECLARE @Taken BIT = 0;

        IF @EmployeeCode = ''
            SET @Taken = 1;
        ELSE IF EXISTS (
            SELECT 1 FROM PUMP.Employees WITH (UPDLOCK, HOLDLOCK)
            WHERE PumpId = @PumpId
              AND EmployeeCode = @EmployeeCode
              AND ISNULL(IsDeleted, 0) = 0
              AND Id <> ISNULL(@Id, 0))
            SET @Taken = 1;

        IF @Taken = 1
            SET @EmployeeCode = PUMP.fn_NextEmployeeCode(@PumpId);

        IF ISNULL(@Id, 0) = 0
        BEGIN
            INSERT INTO PUMP.Employees
            (
                OwnerId, PumpId, UserId, EmployeeCode, FullName, Mobile, JoinDate, Designation, MonthlySalary, IsActive
            )
            VALUES
            (
                @OwnerId, @PumpId, @UserId, @EmployeeCode, @FullName, @Mobile, @JoinDate, @Designation, @MonthlySalary, @IsActive
            );

            DECLARE @NewId BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);

            COMMIT TRANSACTION;
            SELECT @NewId AS Id;
            RETURN;
        END

        UPDATE PUMP.Employees
        SET UserId = @UserId,
            EmployeeCode = @EmployeeCode,
            FullName = @FullName,
            Mobile = @Mobile,
            JoinDate = @JoinDate,
            Designation = @Designation,
            MonthlySalary = @MonthlySalary,
            IsActive = @IsActive,
            UpdatedOn = SYSDATETIME()
        WHERE Id = @Id
          AND OwnerId = @OwnerId
          AND PumpId = @PumpId;

    COMMIT TRANSACTION;

    SELECT @Id AS Id;
END
GO
PRINT '  + T3: sp_Employee_Save ab code khud allot karta hai';
PRINT '=== Section T done ===';
GO

/* ================================================================================
   SECTION U — "Employees" ka menu hata diya (Staff usi ka kaam karta hai)
   --------------------------------------------------------------------------------
   Teen form the aur teenon aadmi hi jodte the:

     Employees  - sirf aadmi (naam, mobile, salary). Login alag se banana padta tha.
     Users      - sirf login (username, password, role).
     Staff      - dono ek saath (Section L me isiliye banaya gaya tha).

   Yaani "Employees" ab Staff ka aadha hissa hai — do jagah ek hi cheez.
   Do alag form hone se do row ban jaati thi aur salary/attendant cash me uljhan
   hoti thi.

   Isliye: Employees ka menu CHHUPA rahe hain.
     * Data, table, SP, page — kuch nahi mitaya. Purani entry jaisi hai waisi hai.
     * Sirf sidebar se hat raha hai, taaki naya banda galat form na khole.
     * Wapas chahiye to: UPDATE PUMP.Menus SET IsVisible = 1 WHERE Route = '/employees';

   "Users" jaanbujh kar rakha hai — uska apna kaam hai:
     * kisi ka password reset karna
     * login band/chaalu karna, role badalna
     * aise log jinka pump par kaam nahi par login chahiye (jaise accountant)
   ================================================================================ */
PRINT '';
PRINT '=== Section U: Employees ka menu chhupaya ===';
GO

IF EXISTS (SELECT 1 FROM PUMP.Menus WHERE Route = '/employees' AND IsVisible = 1)
BEGIN
    UPDATE PUMP.Menus SET IsVisible = 0 WHERE Route = '/employees';
    PRINT '  * U1: Employees ka menu chhupa diya (Staff use karein)';
END
ELSE
    PRINT '  = U1: Employees ka menu pehle se chhupa hai';
GO

PRINT '=== Section U done ===';
GO

/* ================================================================================
   SECTION V — do cheezein
   --------------------------------------------------------------------------------
   V1. sp_Tank_GetStockAsOfDate purchase ko ULTA gin raha tha
   V2. DSR ke Remarks me sirf "Variance" likha aata tha
   ================================================================================ */
PRINT '';
PRINT '=== Section V ===';
GO

/* ---- V1: purani tareekh ka book stock galat aata tha ----------------------
   Purana code:
       SUM(CASE WHEN t.TxnType = 'IN' THEN t.Quantity ELSE -t.Quantity END)

   Sirf 'IN' ko aavak maanta tha. Tanker ki delivery se banne wali row ka
   TxnType 'PURCHASE' hota hai (dekho sp_Purchase_SaveDetail), isliye wo ELSE
   me girti thi aur JAAVAK gin li jaati thi. Uske baad `@CurrentStock -
   @Adjustments` me minus ka minus plus ban jaata tha.

   Nateeja: jis tareekh ke BAAD koi delivery hui ho, us tareekh ka book stock
   delivery ka DOGUNA zyada aata tha.

   Asli misaal (Vikash Filling Center, 9000 L MS ki delivery 3 Sep ko):
       1 Sep ka MS book stock  ->  aa raha tha 26,138 L
                                   sahi hai      8,138 L   (18,000 = 2 x 9000 ka farak)

   Ye galti do jagah dikhti thi — Dip & Testing ka "Book Stock" aur Stock
   Reconcile ka book stock. Yaani reconciliation bhi galat ho rahi thi.

   Yahi galti pehle DSR me thi aur wahan theek ki ja chuki hai; ye SP chhoot
   gaya tha. Ab dono ek hi list maante hain: IN / RECEIPT / PURCHASE / OPENING.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE [PUMP].[sp_Tank_GetStockAsOfDate]
(
    @OwnerId  BIGINT,
    @TankId   BIGINT,
    @AsOfDate DATE
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @CurrentStock DECIMAL(18,3) = 0;

    SELECT @CurrentStock = ISNULL(CurrentStock, 0)
    FROM PUMP.Tanks
    WHERE Id = @TankId AND OwnerId = @OwnerId;

    DECLARE @Adjustments DECIMAL(18,3) = 0;

    SELECT @Adjustments = ISNULL(
        SUM(CASE WHEN UPPER(t.TxnType) IN ('IN', 'RECEIPT', 'PURCHASE', 'OPENING')
                 THEN t.Quantity ELSE -t.Quantity END), 0)
    FROM PUMP.TankTransactions t
    LEFT JOIN PUMP.ShiftHeaders s
        ON t.ReferenceNo LIKE 'SHIFT-%'
        AND s.Id = TRY_CAST(REVERSE(SUBSTRING(REVERSE(t.ReferenceNo), 1, CHARINDEX('-', REVERSE(t.ReferenceNo)) - 1)) AS INT)
    WHERE t.TankId = @TankId
      AND t.OwnerId = @OwnerId
      AND (
          (s.Id IS NOT NULL AND s.ShiftDate > @AsOfDate)
          OR
          (s.Id IS NULL AND CAST(t.TxnDateTime AS DATE) > @AsOfDate)
      );

    SELECT @CurrentStock - @Adjustments AS BookStock;
END
GO
PRINT '  + V1: sp_Tank_GetStockAsOfDate ab purchase ko aavak ginta hai';
GO
PRINT '=== Section V done ===';
GO

/* ================================================================================
   SECTION W — "Din ka collection" (Online / Card / Udhaar)
   --------------------------------------------------------------------------------
   Dikkat: din ki bikri meter se banti hai (maan lo Rs 1,05,219). Par wo paisa teen
   raaston se aata hai — nakad, Phone Pe, aur udhaar. Abhi sirf nakad darj hota tha,
   isliye har shift me bada "short" likha aata tha:

       Bikri     1,05,219
       Cash         55,244
       Short        49,975    <- jabki kisi ne kuch nahi maara,
                                 49,975 Phone Pe aur udhaar me gaya tha

   Iska sabse bura nateeja: jis din SACH ME paisa kam ho, wo is bade short me chhup
   jaata hai. Aadmi 2,000 maar le to bhi "51,975 short" hi dikhega — pakad me hi
   nahi aayega.

   Ab tak ye likhne ke liye Sales screen bharni padti thi (product, nozzle, litre,
   rate — har parchi ka alag bill). Pump wale ke liye ye bahut lamba kaam hai; wo
   karega hi nahi. Isliye ye chhota raasta:

       ek shift, teen khaane — Online, Card, aur udhaar ki list (party + rupaye)

   Andar wahi SalesHeaders banti hain jo pehle se system samajhta hai
   (sp_Shift_Collection_Summary inhi ko ginta hai), aur udhaar PartyLedger me bhi
   jaata hai taaki Outstanding report me naam aa jaye.

   STOCK PAR KOI ASAR NAHI: sp_Sales_SaveDetail tank ko haath nahi lagata, aur
   hum detail line banate hi nahi. Bikri bhi dobara nahi ginti — meter se aayi
   bikri me se ye ghataye jaate hain, jode nahi jaate.
   ================================================================================ */
PRINT '';
PRINT '=== Section W: din ka collection (Online / Card / Udhaar) ===';
GO

/* ---- W1: ek shift ka collection padho ---- */
CREATE OR ALTER PROCEDURE PUMP.sp_ShiftCollection_Get
(
    @ShiftId BIGINT,
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.ShiftHeaders WHERE Id = @ShiftId AND OwnerId = @OwnerId)
        THROW 50230, 'That shift was not found.', 1;

    /* Pehli row: UPI aur Card ka jod */
    SELECT
        UpiAmount  = ISNULL(SUM(CASE WHEN UPPER(PaymentMode) IN ('UPI','WALLET') THEN TotalAmount END), 0),
        CardAmount = ISNULL(SUM(CASE WHEN UPPER(PaymentMode) = 'CARD' THEN TotalAmount END), 0)
    FROM PUMP.SalesHeaders
    WHERE ShiftId = @ShiftId AND OwnerId = @OwnerId AND IsVoid = 0
      AND BillNo LIKE 'COLL-%';

    /* Doosri row-set: udhaar kis-kis ka */
    SELECT
        h.PartyId,
        PartyName = p.PartyName,
        Amount    = h.TotalAmount
    FROM PUMP.SalesHeaders h
    JOIN PUMP.Parties p ON p.Id = h.PartyId
    WHERE h.ShiftId = @ShiftId AND h.OwnerId = @OwnerId AND h.IsVoid = 0
      AND h.BillNo LIKE 'COLL-%'
      AND UPPER(h.PaymentMode) = 'CREDIT'
    ORDER BY p.PartyName;
END
GO
PRINT '  + W1: sp_ShiftCollection_Get ready';
GO

/* ---- W2: collection save karo (poora badal kar) ----
   Har baar purani COLL- entry hata kar nayi banate hain, taaki user jitni baar
   chahe sudhaar sake aur kabhi dohri entry na bane. */
CREATE OR ALTER PROCEDURE PUMP.sp_ShiftCollection_Save
(
    @ShiftId     BIGINT,
    @OwnerId     BIGINT,
    @UpiAmount   DECIMAL(18,2) = 0,
    @CardAmount  DECIMAL(18,2) = 0,
    @CreditJson  NVARCHAR(MAX) = NULL,   -- [{"PartyId":1,"Amount":300}, ...]
    @UserId      BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @PumpId BIGINT, @ShiftDate DATE;

    SELECT @PumpId = PumpId, @ShiftDate = ShiftDate
    FROM PUMP.ShiftHeaders
    WHERE Id = @ShiftId AND OwnerId = @OwnerId;

    IF @PumpId IS NULL
        THROW 50230, 'That shift was not found.', 1;

    SET @UpiAmount  = ISNULL(@UpiAmount, 0);
    SET @CardAmount = ISNULL(@CardAmount, 0);

    IF @UpiAmount < 0 OR @CardAmount < 0
        THROW 50231, 'Amount cannot be negative.', 1;

    /* Udhaar ki list — party usi owner ki honi chahiye. Doosre tenant ki party
       ki id daal kar uske khaate me entry na ho jaye. */
    DECLARE @Credit TABLE (PartyId BIGINT, Amount DECIMAL(18,2));

    IF @CreditJson IS NOT NULL AND ISJSON(@CreditJson) = 1
    BEGIN
        INSERT INTO @Credit (PartyId, Amount)
        SELECT x.PartyId, x.Amount
        FROM OPENJSON(@CreditJson)
        WITH (PartyId BIGINT '$.PartyId', Amount DECIMAL(18,2) '$.Amount') x
        WHERE ISNULL(x.PartyId, 0) > 0 AND ISNULL(x.Amount, 0) > 0;

        IF EXISTS (SELECT 1 FROM @Credit c
                   WHERE NOT EXISTS (SELECT 1 FROM PUMP.Parties p
                                     WHERE p.Id = c.PartyId AND p.OwnerId = @OwnerId
                                       AND ISNULL(p.IsDeleted, 0) = 0))
            THROW 50232, 'One of the credit customers does not belong to your account.', 1;
    END

    DECLARE @Stamp DATETIME2(7) = DATEADD(HOUR, 20, CAST(@ShiftDate AS DATETIME2(7)));

    BEGIN TRANSACTION;

        /* Purani COLL- entry saaf. Sirf apni banayi hui — Sales screen se bani
           asli parchiyon ko haath nahi lagate.

           PEHLE PURANA UDHAAR PARTY KE KHAATE SE GHATANA ZAROORI HAI. Bina iske
           dobara save karne par wahi udhaar do baar jud jaata: 300 ka udhaar
           theek karke 200 karo to khaata 500 dikhane lagta. */
        UPDATE p
        SET p.CurrentBalance = ISNULL(p.CurrentBalance, 0) - old.Amount
        FROM PUMP.Parties p
        JOIN (
            SELECT PartyId, Amount = SUM(TotalAmount)
            FROM PUMP.SalesHeaders
            WHERE ShiftId = @ShiftId AND OwnerId = @OwnerId AND IsVoid = 0
              AND BillNo LIKE 'COLL-%' AND UPPER(PaymentMode) = 'CREDIT'
              AND PartyId IS NOT NULL
            GROUP BY PartyId
        ) old ON old.PartyId = p.Id;

        DELETE FROM PUMP.PartyLedger
        WHERE ShiftId = @ShiftId AND OwnerId = @OwnerId
          AND ReferenceNo LIKE 'COLL-%';

        DELETE FROM PUMP.SalesHeaders
        WHERE ShiftId = @ShiftId AND OwnerId = @OwnerId
          AND BillNo LIKE 'COLL-%';

        IF @UpiAmount > 0
            INSERT INTO PUMP.SalesHeaders
                (OwnerId, PumpId, ShiftId, PartyId, BillNo, BillDateTime, PaymentMode,
                 CustomerName, TotalAmount, IsVoid, IsInterState, CreatedBy)
            VALUES
                (@OwnerId, @PumpId, @ShiftId, NULL,
                 CONCAT('COLL-', @ShiftId, '-UPI'), @Stamp, 'UPI',
                 N'Online (day total)', @UpiAmount, 0, 0, @UserId);

        IF @CardAmount > 0
            INSERT INTO PUMP.SalesHeaders
                (OwnerId, PumpId, ShiftId, PartyId, BillNo, BillDateTime, PaymentMode,
                 CustomerName, TotalAmount, IsVoid, IsInterState, CreatedBy)
            VALUES
                (@OwnerId, @PumpId, @ShiftId, NULL,
                 CONCAT('COLL-', @ShiftId, '-CARD'), @Stamp, 'CARD',
                 N'Card (day total)', @CardAmount, 0, 0, @UserId);

        /* Udhaar — har party ki apni row */
        INSERT INTO PUMP.SalesHeaders
            (OwnerId, PumpId, ShiftId, PartyId, BillNo, BillDateTime, PaymentMode,
             CustomerName, TotalAmount, IsVoid, IsInterState, CreatedBy)
        SELECT
            @OwnerId, @PumpId, @ShiftId, c.PartyId,
            CONCAT('COLL-', @ShiftId, '-CR-', c.PartyId), @Stamp, 'CREDIT',
            p.PartyName, c.Amount, 0, 0, @UserId
        FROM @Credit c
        JOIN PUMP.Parties p ON p.Id = c.PartyId;

        /* Party ka khaata bhi badhna chahiye, warna Outstanding report me
           ye udhaar dikhega hi nahi. */
        INSERT INTO PUMP.PartyLedger
            (OwnerId, PumpId, PartyId, EntryType, Amount, EntryDateTime,
             ReferenceNo, Notes, ShiftId, PaymentMode, CreatedBy)
        SELECT
            @OwnerId, @PumpId, c.PartyId, 'SALE', c.Amount, @Stamp,
            CONCAT('COLL-', @ShiftId, '-CR-', c.PartyId),
            N'Credit given during the shift', @ShiftId, 'CREDIT', @UserId
        FROM @Credit c;

        UPDATE p
        SET p.CurrentBalance = ISNULL(p.CurrentBalance, 0) + c.Amount
        FROM PUMP.Parties p
        JOIN @Credit c ON c.PartyId = p.Id;

    COMMIT TRANSACTION;

    SELECT Saved = 1;
END
GO
PRINT '  + W2: sp_ShiftCollection_Save ready';
PRINT '=== Section W done ===';
GO

/* ================================================================================
   SECTION X — Shift ka number: pump-wise, din-wise (1, 2, 3...)
   --------------------------------------------------------------------------------
   Shift list me abhi ShiftHeaders.Id dikhta tha — 6, 7, 8, 9... Wo poore system ka
   ek hi chalta hua number hai, saare pump aur saare din mila kar. Do dikkat:

     * Kuch mahine chalte hi ye 4-5 ank ka ho jayega (shift 2847). Pump wale ke
       liye us number ka koi matlab hi nahi.
     * Do pump wale owner ke liye number aage-peeche kudte hain, kyunki beech me
       doosre pump ki shift ban gayi hoti hai.

   Chahiye ye tha: HAR PUMP par, HAR DIN, number 1 se shuru ho. Ek din me do shift
   chalayi to 1 aur 2; teen chalayi to 1, 2, 3.

   Isliye ab list ek naya column deti hai — ShiftNo — jo ROW_NUMBER se banta hai
   (PumpId + ShiftDate ke andar, khulne ke kram me). Id waise ki waise rehti hai
   (link, close, edit sab usi se chalte hain), bas dikhta ShiftNo hai.

   NOTE (CLAUDE.md niyam 5): naya column SABSE AAKHIR me joda hai, aur ShiftDto
   (API + client) dono me bhi aakhir me hi param joda gaya hai.
   ================================================================================ */
PRINT '';
PRINT '=== Section X: shift ka number pump-wise, din-wise ===';
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Shift_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT = NULL,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @SearchTerm NVARCHAR(100) = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 50
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Offset INT = (@PageNumber - 1) * @PageSize;

    ;WITH ShiftBase AS
    (
        SELECT
            sh.Id,
            sh.OwnerId,
            sh.PumpId,
            sh.OperatorUserId,
            sh.OperatorEmployeeId,
            OperatorName = COALESCE(e.FullName, u.FullName),
            sh.ShiftDate,
            sh.ShiftCode,
            sh.OpeningCash,
            sh.ClosingCash,
            sh.Notes,
            sh.OpenedOn,
            sh.ClosedOn,
            sh.Status,
            /* Us pump par us din ki kaunsi shift — 1, 2, 3...
               Filter se pehle ginna zaroori hai: agar user ne tareekh ka filter
               lagaya ho to bhi number wahi rehna chahiye jo asal me hai. */
            /* CAST zaroori hai: ROW_NUMBER() BIGINT lautata hai, aur ShiftDto ka
               param `int` hai. Bina CAST ke Dapper record bana hi nahi paata
               aur POORI shift list 400 de deti hai (CLAUDE.md niyam 5). */
            ShiftNo = CAST(ROW_NUMBER() OVER (
                          PARTITION BY sh.PumpId, sh.ShiftDate
                          ORDER BY sh.OpenedOn, sh.Id) AS INT)
        FROM PUMP.ShiftHeaders sh
        LEFT JOIN PUMP.Employees e ON e.Id = sh.OperatorEmployeeId
        LEFT JOIN PUMP.Users     u ON u.Id = sh.OperatorUserId
        WHERE sh.OwnerId = @OwnerId
    )
    SELECT
        b.Id,
        b.OwnerId,
        b.PumpId,
        b.OperatorUserId,
        b.OperatorEmployeeId,
        b.OperatorName,
        b.ShiftDate,
        b.ShiftCode,
        b.OpeningCash,
        b.ClosingCash,
        TotalSoldQty = ISNULL(snr.TotalSoldQty, 0),
        TotalSoldAmount = ISNULL(snr.TotalSoldAmount, 0),
        b.Notes,
        b.OpenedOn,
        b.ClosedOn,
        b.Status,
        b.ShiftNo
    FROM ShiftBase b
    OUTER APPLY
    (
        SELECT
            SUM(ISNULL(x.SoldQty, 0)) AS TotalSoldQty,
            SUM(ISNULL(x.SoldAmount, 0)) AS TotalSoldAmount
        FROM PUMP.ShiftNozzleReadings x
        WHERE x.ShiftId = b.Id
    ) snr
    WHERE (@PumpId IS NULL OR @PumpId <= 0 OR b.PumpId = @PumpId)
      AND (@FromDate IS NULL OR b.ShiftDate >= @FromDate)
      AND (@ToDate IS NULL OR b.ShiftDate <= @ToDate)
      AND (@SearchTerm IS NULL OR @SearchTerm = '' OR b.ShiftCode LIKE '%' + @SearchTerm + '%' OR b.Notes LIKE '%' + @SearchTerm + '%')
    ORDER BY b.Id DESC
    OFFSET @Offset ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(1)
    FROM PUMP.ShiftHeaders sh
    WHERE sh.OwnerId = @OwnerId
      AND (@PumpId IS NULL OR @PumpId <= 0 OR sh.PumpId = @PumpId)
      AND (@FromDate IS NULL OR sh.ShiftDate >= @FromDate)
      AND (@ToDate IS NULL OR sh.ShiftDate <= @ToDate)
      AND (@SearchTerm IS NULL OR @SearchTerm = '' OR sh.ShiftCode LIKE '%' + @SearchTerm + '%' OR sh.Notes LIKE '%' + @SearchTerm + '%');
END
GO
PRINT '  + X1: sp_Shift_List ab ShiftNo deta hai (pump + din ke hisaab se 1,2,3)';
PRINT '=== Section X done ===';
GO

/* ================================================================================
   SECTION Y — Galti se band hui shift dobara kholna
   --------------------------------------------------------------------------------
   Hota ye hai: aadmi "Close Shift" daba deta hai bina reading bhare. Form me
   closing reading pehle se opening ke barabar bhari hoti hai, isliye shift band
   ho jaati hai aur us din ki bikri 0 darj ho jaati hai.

   Ab tak iska koi ilaaj nahi tha — shift band ho gayi to band. Us din ka poora
   hisaab hamesha ke liye 0 rehta.

   Ye SP use wapas khol deta hai: closing reading, bikri, band karne ka waqt aur
   cash — sab hata kar Status wapas 'OPEN'.

   JAANBUJH KAR ROK: agar us shift se stock hil chuka hai (TankTransactions me
   uski row hai), to SP mana kar deta hai. Aisi shift ko yun hi kholna tank ka
   hisaab bigaad dega — uske liye "Edit" hai, jo reading sudhaar kar stock bhi
   theek karta hai. Ye SP sirf us soorat ke liye hai jab galti se, bina kuch
   beche, shift band ho gayi ho.
   ================================================================================ */
PRINT '';
PRINT '=== Section Y: galti se band hui shift dobara kholna ===';
GO

CREATE OR ALTER PROCEDURE PUMP.sp_Shift_Reopen
(
    @ShiftId BIGINT,
    @OwnerId BIGINT,
    @UserId  BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @PumpId BIGINT, @Status NVARCHAR(20);

    SELECT @PumpId = PumpId, @Status = Status
    FROM PUMP.ShiftHeaders
    WHERE Id = @ShiftId AND OwnerId = @OwnerId;

    IF @PumpId IS NULL
        THROW 50240, 'That shift was not found.', 1;

    IF UPPER(@Status) = 'OPEN'
        THROW 50241, 'This shift is already open.', 1;

    /* Us pump par pehle se koi shift khuli ho to doosri nahi khul sakti —
       sp_Shift_Open bhi yahi niyam maanta hai. */
    IF EXISTS (SELECT 1 FROM PUMP.ShiftHeaders
               WHERE OwnerId = @OwnerId AND PumpId = @PumpId
                 AND Status = 'OPEN' AND Id <> @ShiftId)
        THROW 50242, 'Another shift is already open for this pump. Close it first.', 1;

    /* Stock hil chuka ho to yun hi mat kholo. */
    IF EXISTS (SELECT 1 FROM PUMP.TankTransactions
               WHERE OwnerId = @OwnerId
                 AND ReferenceNo = CONCAT('SHIFT-', @ShiftId))
        THROW 50243, 'This shift already moved stock. Use Edit to correct the readings instead of reopening it.', 1;

    BEGIN TRANSACTION;

        UPDATE PUMP.ShiftNozzleReadings
        SET ClosingReading = NULL,
            SoldQty        = 0,
            SoldAmount     = 0,
            /* Ye column NOT NULL hai, isliye 0 — NULL dene par Msg 515. */
            VarianceQty    = 0,
            TestingLoss    = 0,
            UpdatedOn      = SYSDATETIME(),
            ModifiedBy     = @UserId,
            ModifiedOn     = SYSDATETIME()
        WHERE ShiftId = @ShiftId;

        UPDATE PUMP.ShiftHeaders
        SET Status          = 'OPEN',
            ClosedOn        = NULL,
            ClosingCash     = NULL,
            ClosedByUserId  = NULL,
            /* Teenon NOT NULL hain — 0 kar dete hain, NULL nahi. */
            TotalMeterSale  = 0,
            ExpectedCash    = 0,
            CashShortExcess = 0,
            ModifiedBy      = @UserId,
            ModifiedOn      = SYSDATETIME()
        WHERE Id = @ShiftId AND OwnerId = @OwnerId;

    COMMIT TRANSACTION;

    /* Kisne kholi, kab — audit me nishaan chhod dete hain. */
    EXEC PUMP.sp_Audit_Log
        @OwnerId = @OwnerId, @PumpId = @PumpId, @UserId = @UserId,
        @EntityName = 'ShiftHeaders', @EntityId = @ShiftId, @Action = 'REOPEN_SHIFT',
        @Reason = N'Shift reopened (was closed without readings)';

    SELECT Reopened = 1;
END
GO
PRINT '  + Y1: sp_Shift_Reopen ready';
PRINT '=== Section Y done ===';
GO

/* ================================================================================
   SECTION Z — Support console (sirf Super Admin ke liye)
   --------------------------------------------------------------------------------
   Ab tak kuch cheezein SIRF SQL se ho paati thi: galti se band hui shift kholna,
   khaali shift hatana, kisi owner ka hisaab dekhna. Har baar developer ko
   database me ghusna padta tha.

   Ye do SP us kaam ko Super Admin ke screen par le aate hain.

   Dhyan: dono me OwnerId ZAROORI hai. Support wala bhi galti se doosre pump ka
   data na chhoo le, isliye har jagah owner milaya jaata hai.
   ================================================================================ */
PRINT '';
PRINT '=== Section Z: Support console ===';
GO

/* ---- Z1. Kisi bhi owner ki shift ki soorat-e-haal ------------------------------
   Har shift ke saath ye bhi batata hai ki us se kya-kya juda hai, taaki support
   wala DEKH kar faisla kare — andaaze se na hataye.

   NOTE (CLAUDE.md niyam 5): SupportShiftDto ke param theek isi kram me hain.
   Column jodo to DTO bhi usi waqt badlo, warna Dapper row bana hi nahi paayega.
------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE PUMP.sp_Support_ShiftList
(
    @OwnerId BIGINT,
    @PumpId  BIGINT = NULL,
    @Days    INT    = 60
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @From DATE = DATEADD(DAY, -ABS(ISNULL(@Days, 60)), CAST(SYSDATETIME() AS DATE));

    SELECT
        Id              = sh.Id,
        PumpId          = sh.PumpId,
        PumpName        = p.Name,
        ShiftDate       = sh.ShiftDate,
        ShiftCode       = ISNULL(sh.ShiftCode, N''),
        Status          = ISNULL(sh.Status, N''),
        OpenedOn        = sh.OpenedOn,
        ClosedOn        = sh.ClosedOn,
        TotalMeterSale  = ISNULL(sh.TotalMeterSale, 0),
        OpeningCash     = ISNULL(sh.OpeningCash, 0),
        ClosingCash     = sh.ClosingCash,
        NozzleCount     = ISNULL(x.NozzleCount, 0),
        ReadingsFilled  = ISNULL(x.ReadingsFilled, 0),
        SalesCount      = ISNULL(x.SalesCount, 0),
        CashTxnCount    = ISNULL(x.CashTxnCount, 0),
        ExpenseCount    = ISNULL(x.ExpenseCount, 0),
        DipCount        = ISNULL(x.DipCount, 0),
        TankTxnCount    = ISNULL(x.TankTxnCount, 0),
        /* Stock hil chuka ho to shift yun hi kholna tank ka hisaab bigaad dega. */
        CanReopen       = CAST(CASE WHEN UPPER(ISNULL(sh.Status, N'')) <> 'OPEN'
                                     AND ISNULL(x.TankTxnCount, 0) = 0
                                THEN 1 ELSE 0 END AS BIT),
        /* Hatane layak sirf wahi shift jisme sach me kuch hai hi nahi. */
        CanDelete       = CAST(CASE WHEN ISNULL(x.SalesCount, 0) = 0
                                     AND ISNULL(x.CashTxnCount, 0) = 0
                                     AND ISNULL(x.ExpenseCount, 0) = 0
                                     AND ISNULL(x.DipCount, 0) = 0
                                     AND ISNULL(x.TankTxnCount, 0) = 0
                                     AND ISNULL(x.ReadingsFilled, 0) = 0
                                THEN 1 ELSE 0 END AS BIT)
    FROM PUMP.ShiftHeaders sh
    LEFT JOIN PUMP.Pumps p ON p.Id = sh.PumpId
    OUTER APPLY
    (
        SELECT
            NozzleCount    = (SELECT COUNT(*) FROM PUMP.ShiftNozzleReadings r WHERE r.ShiftId = sh.Id),
            ReadingsFilled = (SELECT COUNT(*) FROM PUMP.ShiftNozzleReadings r WHERE r.ShiftId = sh.Id AND r.ClosingReading IS NOT NULL),
            SalesCount     = (SELECT COUNT(*) FROM PUMP.SalesHeaders s WHERE s.ShiftId = sh.Id AND s.IsVoid = 0),
            CashTxnCount   = (SELECT COUNT(*) FROM PUMP.CashTransactions c WHERE c.ShiftId = sh.Id),
            ExpenseCount   = (SELECT COUNT(*) FROM PUMP.ExpenseTransactions e WHERE e.ShiftId = sh.Id),
            DipCount       = (SELECT COUNT(*) FROM PUMP.DipReadings d WHERE d.ShiftId = sh.Id),
            TankTxnCount   = (SELECT COUNT(*) FROM PUMP.TankTransactions t
                              WHERE t.ReferenceNo = CONCAT('SHIFT-', sh.Id))
    ) x
    WHERE sh.OwnerId = @OwnerId
      AND (@PumpId IS NULL OR @PumpId <= 0 OR sh.PumpId = @PumpId)
      AND sh.ShiftDate >= @From
    ORDER BY sh.ShiftDate DESC, sh.Id DESC;
END
GO
PRINT '  + Z1: sp_Support_ShiftList ready';
GO

/* ---- Z2. Khaali shift hatana ---------------------------------------------------
   Sirf us shift ke liye jisme SACH ME kuch nahi hai. Ek bhi bikri, cash, kharcha,
   dip, stock ya bhari hui closing reading mile to SP mana kar deta hai — kyunki
   phir wo "khaali" nahi hai, aur hatane se hisaab me chhed ho jayega.

   Aisi shift ke liye "Reopen" hai (Section Y), delete nahi.
------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE PUMP.sp_Shift_Delete
(
    @ShiftId BIGINT,
    @OwnerId BIGINT,
    @UserId  BIGINT = NULL,
    @Reason  NVARCHAR(500) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @PumpId BIGINT, @ShiftDate DATE;

    SELECT @PumpId = PumpId, @ShiftDate = ShiftDate
    FROM PUMP.ShiftHeaders
    WHERE Id = @ShiftId AND OwnerId = @OwnerId;

    IF @PumpId IS NULL
        THROW 50250, 'That shift was not found.', 1;

    IF EXISTS (SELECT 1 FROM PUMP.SalesHeaders WHERE ShiftId = @ShiftId AND IsVoid = 0)
        THROW 50251, 'This shift has sales against it. Remove them first, or reopen the shift instead.', 1;

    IF EXISTS (SELECT 1 FROM PUMP.TankTransactions WHERE ReferenceNo = CONCAT('SHIFT-', @ShiftId))
        THROW 50252, 'This shift has already moved tank stock. Reopen or edit it instead of deleting.', 1;

    IF EXISTS (SELECT 1 FROM PUMP.CashTransactions WHERE ShiftId = @ShiftId)
        OR EXISTS (SELECT 1 FROM PUMP.ExpenseTransactions WHERE ShiftId = @ShiftId)
        OR EXISTS (SELECT 1 FROM PUMP.PartyLedger WHERE ShiftId = @ShiftId)
        THROW 50253, 'Cash, expense or ledger entries are linked to this shift. Move them first.', 1;

    IF EXISTS (SELECT 1 FROM PUMP.DipReadings WHERE ShiftId = @ShiftId)
        THROW 50254, 'Dip readings are linked to this shift. Unlink them first.', 1;

    IF EXISTS (SELECT 1 FROM PUMP.ShiftNozzleReadings
               WHERE ShiftId = @ShiftId AND ClosingReading IS NOT NULL)
        THROW 50255, 'This shift already has closing readings. Reopen it instead of deleting.', 1;

    BEGIN TRANSACTION;

        /* Nishaan pehle chhodo — row hatne ke baad EntityId ka koi matlab nahi rehta. */
        EXEC PUMP.sp_Audit_Log
            @OwnerId = @OwnerId, @PumpId = @PumpId, @UserId = @UserId,
            @EntityName = 'ShiftHeaders', @EntityId = @ShiftId, @Action = 'DELETE',
            @Reason = @Reason,
            @OldValues = @ShiftDate;

        DELETE FROM PUMP.ShiftCashDenominations WHERE ShiftId = @ShiftId;
        DELETE FROM PUMP.ShiftNozzleReadings   WHERE ShiftId = @ShiftId;
        DELETE FROM PUMP.ShiftHeaders          WHERE Id = @ShiftId AND OwnerId = @OwnerId;

    COMMIT TRANSACTION;

    SELECT Deleted = 1;
END
GO
PRINT '  + Z2: sp_Shift_Delete ready';
PRINT '=== Section Z done ===';
GO

/* ==========================================================================================
   SECTION AA — "Unable to update" ka jhootha sandesh (2026-09-13)
   ------------------------------------------------------------------------------------------
   Owner ne bataya: Dip Testing me kisi entry ko Edit karo to laal sandesh
   "Unable to update dip reading." aata hai — PAR entry update ho jaati hai.

   WAJAH: API in SP ko Dapper ke ExecuteAsync se chalati hai aur uske
   rows-affected par bharosa karti hai (return result > 0). In sab SP me pehli
   line SET NOCOUNT ON hai — usi ka kaam rows-affected batana BAND kar dena
   hai. Dapper ko -1 milta hai, -1 > 0 false, API 404 NotFound bhejti hai, aur
   client "Unable to update..." dikha deta hai. Kaam poora ho chuka hota hai,
   sirf khabar galat jaati hai.

   ILAAJ: SET NOCOUNT ON rehne do (wo sahi hai), par asli UPDATE ke turant baad
   @@ROWCOUNT pakad kar WAPAS BHEJO. API ab use padhti hai. @@ROWCOUNT har
   statement ke baad reset ho jaata hai, isliye turant variable me lena zaroori
   hai.

   Yahi galti chaaron jagah thi — dono Dip wale, dono Testing Loss wale. Owner
   ko abhi sirf pehla mila kyunki Testing Loss abhi use nahi hota.

   SAATH ME: sp_DipReading_Update VarianceAmount (variance ki RUPEE value) ko
   haath hi nahi lagata tha. Dip edit karne par litre to badal jaate the par
   rupaye purane hi pade rehte the — list me "-2 L" aur "-Rs 1,210" ek saath
   dikhta tha. Ab wo bhi naye hisaab se banta hai.

   NOTE: SQL aur API ko kisi bhi kram me chadhaya ja sakta hai. Ek akela chadhe
   to haalat aaj jaisi hi rahegi (jhootha sandesh) — isse bura kuch nahi hoga.
   ========================================================================================== */
PRINT '=== Section AA: "Unable to update" ka jhootha sandesh ===';
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_DipReading_Update]
(
    @Id BIGINT,
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @TankId BIGINT,
    @ReadingDate DATE,
    @ShiftId BIGINT = NULL,
    @DipCm DECIMAL(10,2),
    @WaterDipCm DECIMAL(10,2) = NULL,
    @Density DECIMAL(10,4) = NULL,
    @Temperature DECIMAL(10,2) = NULL,
    @ExpectedStock DECIMAL(18,2) = 0,
    @ActualStock DECIMAL(18,2) = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Variance DECIMAL(18,2) = @ActualStock - @ExpectedStock;

    /* Rupee value ke liye US TANK ka product chahiye jis par dip ja rahi hai —
       naya tank chuna gaya ho to naye ka. Rate us din ka (ProductRateHistory se). */
    DECLARE @ProductId BIGINT;
    SELECT @ProductId = ProductId
    FROM PUMP.Tanks
    WHERE Id = @TankId AND OwnerId = @OwnerId AND PumpId = @PumpId;

    DECLARE @Rate DECIMAL(18,3) =
        PUMP.fn_ProductRateOnDate(@ProductId, CAST(@ReadingDate AS DATETIME2));

    UPDATE PUMP.DipReadings
    SET
        TankId         = @TankId,
        ReadingDate    = @ReadingDate,
        ShiftId        = @ShiftId,
        DipCm          = @DipCm,
        WaterDipCm     = @WaterDipCm,
        Density        = @Density,
        Temperature    = @Temperature,
        ExpectedStock  = @ExpectedStock,
        ActualStock    = @ActualStock,
        Variance       = @Variance,
        VarianceAmount = ROUND(@Variance * ISNULL(@Rate, 0), 2)
    WHERE Id = @Id AND OwnerId = @OwnerId AND PumpId = @PumpId;

    DECLARE @Rows INT = @@ROWCOUNT;
    SELECT @Rows AS Affected;
END
GO
PRINT '  + AA1: sp_DipReading_Update ab rowcount lautata hai (aur rupee value bhi bharta hai)';
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_DipReading_ToggleActive]
(
    @Id BIGINT,
    @OwnerId BIGINT,
    @PumpId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE PUMP.DipReadings
    SET IsActive = CASE WHEN IsActive = 1 THEN 0 ELSE 1 END
    WHERE Id = @Id AND OwnerId = @OwnerId AND PumpId = @PumpId;

    DECLARE @Rows INT = @@ROWCOUNT;
    SELECT @Rows AS Affected;
END
GO
PRINT '  + AA2: sp_DipReading_ToggleActive ab rowcount lautata hai';
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_TestingLoss_Update]
(
    @Id BIGINT,
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @TankId BIGINT,
    @LossDate DATE,
    @ShiftId BIGINT = NULL,
    @LossType NVARCHAR(50),
    @Quantity DECIMAL(18,3),
    @Notes NVARCHAR(500) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @OldQty DECIMAL(18,3), @OldTankId BIGINT, @OldIsActive BIT;
    SELECT @OldQty = Quantity, @OldTankId = TankId, @OldIsActive = IsActive
    FROM PUMP.TestingLosses
    WHERE Id = @Id AND OwnerId = @OwnerId AND PumpId = @PumpId;

    /* Mila hi nahi (ya doosre owner ka hai) — saaf 0 bhejo. */
    IF @OldQty IS NULL
    BEGIN
        SELECT 0 AS Affected;
        RETURN;
    END

    -- Stock ka asar tabhi badlo jab entry chaalu ho (band entry ne stock ghataya hi nahi tha)
    IF @OldIsActive = 1
    BEGIN
        IF @OldQty > 0
        BEGIN
            UPDATE PUMP.Tanks SET CurrentStock = CurrentStock + @OldQty WHERE Id = @OldTankId;

            INSERT INTO PUMP.TankTransactions (OwnerId, PumpId, TankId, TxnType, Quantity, TxnDateTime, ReferenceNo, Notes)
            VALUES (@OwnerId, @PumpId, @OldTankId, 'IN', @OldQty, SYSDATETIME(), 'LOSS-REV-' + CAST(@Id AS NVARCHAR(20)), 'Reversed for edit');
        END

        IF @Quantity > 0
        BEGIN
            UPDATE PUMP.Tanks SET CurrentStock = CurrentStock - @Quantity WHERE Id = @TankId;

            INSERT INTO PUMP.TankTransactions (OwnerId, PumpId, TankId, TxnType, Quantity, TxnDateTime, ReferenceNo, Notes)
            VALUES (@OwnerId, @PumpId, @TankId, 'OUT', @Quantity, SYSDATETIME(), 'LOSS-' + CAST(@Id AS NVARCHAR(20)), @LossType + ' loss (edited)');
        END
    END

    UPDATE PUMP.TestingLosses
    SET
        TankId   = @TankId,
        LossDate = @LossDate,
        ShiftId  = @ShiftId,
        LossType = @LossType,
        Quantity = @Quantity,
        Notes    = @Notes
    WHERE Id = @Id;

    /* Sirf ISI UPDATE ka rowcount chahiye — upar wale Tanks/TankTransactions ka
       nahi. Isiliye @@ROWCOUNT yahan, is statement ke turant baad liya ja raha hai. */
    DECLARE @Rows INT = @@ROWCOUNT;
    SELECT @Rows AS Affected;
END
GO
PRINT '  + AA3: sp_TestingLoss_Update ab rowcount lautata hai';
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_TestingLoss_ToggleActive]
(
    @Id BIGINT,
    @OwnerId BIGINT,
    @PumpId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @OldQty DECIMAL(18,3), @OldTankId BIGINT, @CurrentIsActive BIT, @LossType NVARCHAR(50);
    SELECT @OldQty = Quantity, @OldTankId = TankId, @CurrentIsActive = IsActive, @LossType = LossType
    FROM PUMP.TestingLosses
    WHERE Id = @Id AND OwnerId = @OwnerId AND PumpId = @PumpId;

    IF @OldQty IS NULL
    BEGIN
        SELECT 0 AS Affected;
        RETURN;
    END

    DECLARE @Rows INT = 0;

    IF @CurrentIsActive = 1
    BEGIN
        -- Band kar rahe hain: tel tank ko wapas
        IF @OldQty > 0
        BEGIN
            UPDATE PUMP.Tanks SET CurrentStock = CurrentStock + @OldQty WHERE Id = @OldTankId;

            INSERT INTO PUMP.TankTransactions (OwnerId, PumpId, TankId, TxnType, Quantity, TxnDateTime, ReferenceNo, Notes)
            VALUES (@OwnerId, @PumpId, @OldTankId, 'IN', @OldQty, SYSDATETIME(), 'LOSS-DEL-' + CAST(@Id AS NVARCHAR(20)), 'Refunded due to deletion');
        END

        UPDATE PUMP.TestingLosses SET IsActive = 0 WHERE Id = @Id;
        SET @Rows = @@ROWCOUNT;
    END
    ELSE
    BEGIN
        -- Dobara chaalu: tel phir se ghatao
        IF @OldQty > 0
        BEGIN
            UPDATE PUMP.Tanks SET CurrentStock = CurrentStock - @OldQty WHERE Id = @OldTankId;

            INSERT INTO PUMP.TankTransactions (OwnerId, PumpId, TankId, TxnType, Quantity, TxnDateTime, ReferenceNo, Notes)
            VALUES (@OwnerId, @PumpId, @OldTankId, 'OUT', @OldQty, SYSDATETIME(), 'LOSS-' + CAST(@Id AS NVARCHAR(20)), @LossType + ' loss (reactivated)');
        END

        UPDATE PUMP.TestingLosses SET IsActive = 1 WHERE Id = @Id;
        SET @Rows = @@ROWCOUNT;
    END

    SELECT @Rows AS Affected;
END
GO
PRINT '  + AA4: sp_TestingLoss_ToggleActive ab rowcount lautata hai';
PRINT '=== Section AA done ===';
GO

/* ==========================================================================================
   SECTION AB — Dip ka "Book Stock" DSR wale hisaab se + shift band karte waqt hi dip (2026-09-19)
   ------------------------------------------------------------------------------------------
   DO SHIKAYATEIN, EK JAD:

   (1) Dip Testing page ka Variance DSR se kabhi nahi milta tha. 08 Sep ki diesel
       dip par page "+40.63" bolta tha, DSR "+4.74". Wajah: page ka Book Stock
       tank ka CurrentStock (sp_Tank_GetStockAsOfDate) se aata tha — aur wo stock
       1 tarikh se kabhi dip par barabar nahi hua, to 1-4 Sep ka purana farak roz
       dobara jud kar dikhta tha. DSR har din pichhli dip se naya hisaab shuru
       karta hai. Owner ko do alag number dikhte the aur samajh nahi aata tha
       kaun sahi hai.

   (2) Dip SHIFT BAND HONE SE PEHLE daal di jaaye to Book Stock me us din ki bikri
       ghati hi nahi hoti (tank ka hisaab shift close par badalta hai). 09 Sep
       ko yahi hua: dip 20:42 par, shift 20:54 par band — variance "-615", phir
       "+700", phir "+1002". Chaar baar daala, teen baar band kiya.

   ILAAJ:
     AB1  fn_TankBookStockForDip — Book Stock BILKUL DSR ke tareeke se:
          us din se pehle ki AAKHRI naap (chaalu dip, ya reconciliation)
          + us ke baad aaya tel (receipt) - us ke baad ki band shifton ki net bikri.
          Ab dip page ka variance = DSR ka Variation. Ek hi number.
     AB2  sp_Tank_GetDipBookStock — page ke liye.
     AB3  sp_DipReading_Save / AB4 sp_DipReading_Update — Book Stock ab SERVER
          khud nikaalta hai; client jo bheje use nahi maanta. Purana/cached page
          bhi galat variance save nahi kar paayega.
     AB5  sp_Shift_ClosingDipList — Close Shift form ke liye: pump ke tank, shift
          ki bikri ke bina book stock, aur (edit par) pehle se padi dip.
     AB6  sp_Shift_SaveClosingDips — shift band hone ke TURANT BAAD usi form se
          dip. Date = shift ki date, ShiftId = wahi shift. Galat din / shift se
          pehle wali galti ho hi nahi sakti.
     AB7  Purani dip ka Book Stock / Variance naye hisaab se dobara (re-runnable).

   Stock Reconcile ko jaanbujh ke NAHI chheda — wahan tank ka CurrentStock hi sahi
   aadhaar hai (reconcile ussi ko physical par set karta hai aur farak ledger me
   likhta hai). sp_Tank_GetStockAsOfDate waisa hi hai.
   ========================================================================================== */
PRINT '=== Section AB: dip ka book stock DSR wale hisaab se + shift form me dip ===';
GO

/* ---------- AB1 ---------- */
CREATE OR ALTER FUNCTION PUMP.fn_TankBookStockForDip
(
    @TankId   BIGINT,
    @AsOfDate DATE
)
RETURNS DECIMAL(18,3)
AS
BEGIN
    DECLARE @PumpId BIGINT, @ProductId BIGINT, @OwnerId BIGINT, @Cur DECIMAL(18,3);

    SELECT @PumpId = PumpId, @ProductId = ProductId, @OwnerId = OwnerId,
           @Cur = ISNULL(CurrentStock, 0)
    FROM PUMP.Tanks
    WHERE Id = @TankId;

    IF @PumpId IS NULL RETURN NULL;

    /* Is product ka pump par ek hi chaalu tank ho to jin nozzle par TankId nahi
       bhara, unki bikri bhi isi tank ki - wahi niyam jo sp_Shift_Close lagata hai. */
    DECLARE @OnlyTank BIT =
        CASE WHEN (SELECT COUNT(*) FROM PUMP.Tanks
                   WHERE PumpId = @PumpId AND ProductId = @ProductId AND IsActive = 1) = 1
             THEN 1 ELSE 0 END;

    /* 1. Is din se PEHLE ki aakhri naap. DSR ki tarah: dip (chaalu, >0) pehle,
          us din dip na ho to reconciliation. */
    DECLARE @BaseDate DATE;
    SELECT @BaseDate = MAX(x.D)
    FROM
    (
        SELECT D = ReadingDate
        FROM PUMP.DipReadings
        WHERE TankId = @TankId AND IsActive = 1 AND ActualStock > 0 AND ReadingDate < @AsOfDate
        UNION ALL
        SELECT CAST(ReconciliationDate AS DATE)
        FROM PUMP.StockReconciliations
        WHERE TankId = @TankId AND CAST(ReconciliationDate AS DATE) < @AsOfDate
    ) x;

    /* Kabhi napa hi nahi gaya - tab tank ka kitaabi stock us din ke ant par
       (sp_Tank_GetStockAsOfDate wala hi hisaab). */
    IF @BaseDate IS NULL
    BEGIN
        DECLARE @After DECIMAL(18,3) = ISNULL((
            SELECT SUM(CASE WHEN UPPER(t.TxnType) IN ('IN','RECEIPT','PURCHASE','OPENING')
                            THEN t.Quantity ELSE -t.Quantity END)
            FROM PUMP.TankTransactions t
            LEFT JOIN PUMP.ShiftHeaders s
                   ON t.ReferenceNo LIKE 'SHIFT-%'
                  AND s.Id = TRY_CAST(REVERSE(SUBSTRING(REVERSE(t.ReferenceNo), 1,
                                      CHARINDEX('-', REVERSE(t.ReferenceNo)) - 1)) AS BIGINT)
            WHERE t.TankId = @TankId
              AND (   (s.Id IS NOT NULL AND s.ShiftDate > @AsOfDate)
                   OR (s.Id IS NULL AND CAST(t.TxnDateTime AS DATE) > @AsOfDate))
        ), 0);
        RETURN @Cur - @After;
    END

    DECLARE @Base DECIMAL(18,3);
    SELECT TOP 1 @Base = ActualStock
    FROM PUMP.DipReadings
    WHERE TankId = @TankId AND IsActive = 1 AND ActualStock > 0 AND ReadingDate = @BaseDate
    ORDER BY Id DESC;

    IF @Base IS NULL
        SELECT TOP 1 @Base = PhysicalStock
        FROM PUMP.StockReconciliations
        WHERE TankId = @TankId AND CAST(ReconciliationDate AS DATE) = @BaseDate
        ORDER BY Id DESC;

    /* 2. Us ke baad aaya tel - DSR ke Receipt khaane wali hi shartein. */
    DECLARE @Receipt DECIMAL(18,3) = ISNULL((
        SELECT SUM(Quantity)
        FROM PUMP.TankTransactions
        WHERE TankId = @TankId
          AND UPPER(TxnType) IN ('IN','RECEIPT','PURCHASE','OPENING')
          AND CAST(TxnDateTime AS DATE) >  @BaseDate
          AND CAST(TxnDateTime AS DATE) <= @AsOfDate
          AND ISNULL(ReferenceNo, N'') NOT LIKE 'LOSS-DEL-%'
          AND ISNULL(ReferenceNo, N'') NOT LIKE 'VOID-SALE-%'
          AND ISNULL(ReferenceNo, N'') NOT LIKE 'SHIFT-EDIT-%'
          AND ISNULL(ReferenceNo, N'') NOT LIKE 'RECON-%'
    ), 0);

    /* 3. Us ke baad ki BAND shifton ki net bikri (test ka tel wapas tank me jaata
          hai, isliye SoldQty - DSR ka NetSalesByMeter). */
    DECLARE @Sold DECIMAL(18,3) = ISNULL((
        SELECT SUM(snr.SoldQty)
        FROM PUMP.ShiftNozzleReadings snr
        JOIN PUMP.ShiftHeaders sh ON sh.Id = snr.ShiftId
        JOIN PUMP.Nozzles n       ON n.Id  = snr.NozzleId
        WHERE sh.PumpId = @PumpId
          AND sh.Status = 'CLOSED'
          AND sh.ShiftDate >  @BaseDate
          AND sh.ShiftDate <= @AsOfDate
          AND (   n.TankId = @TankId
               OR (n.TankId IS NULL AND n.ProductId = @ProductId AND @OnlyTank = 1))
    ), 0);

    RETURN @Base + @Receipt - @Sold;
END
GO
PRINT '  + AB1: fn_TankBookStockForDip (DSR wala book stock, ek tank ke liye)';
GO

/* ---------- AB2 ---------- */
CREATE OR ALTER PROCEDURE PUMP.sp_Tank_GetDipBookStock
(
    @OwnerId  BIGINT,
    @TankId   BIGINT,
    @AsOfDate DATE
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.Tanks WHERE Id = @TankId AND OwnerId = @OwnerId)
    BEGIN
        SELECT CAST(0 AS DECIMAL(18,3)) AS BookStock;
        RETURN;
    END

    SELECT CAST(ISNULL(PUMP.fn_TankBookStockForDip(@TankId, @AsOfDate), 0) AS DECIMAL(18,3)) AS BookStock;
END
GO
PRINT '  + AB2: sp_Tank_GetDipBookStock';
GO

/* ---------- AB3 ---------- */
CREATE OR ALTER PROCEDURE [PUMP].[sp_DipReading_Save]
(
    @OwnerId       BIGINT,
    @PumpId        BIGINT,
    @TankId        BIGINT,
    @ReadingDate   DATE,
    @ShiftId       BIGINT = NULL,
    @DipCm         DECIMAL(10,2),
    @WaterDipCm    DECIMAL(10,2) = NULL,
    @Density       DECIMAL(10,4) = NULL,
    @Temperature   DECIMAL(10,2) = NULL,
    @ExpectedStock DECIMAL(18,2) = 0,     -- ab sirf fallback; asli server nikaalta hai
    @ActualStock   DECIMAL(18,2) = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ProductId BIGINT;
    SELECT @ProductId = ProductId
    FROM PUMP.Tanks
    WHERE Id = @TankId AND OwnerId = @OwnerId AND PumpId = @PumpId;

    IF @ProductId IS NULL
        THROW 50071, 'Tank not found, or the tank does not belong to your pump.', 1;

    SET @ExpectedStock = ISNULL(CAST(PUMP.fn_TankBookStockForDip(@TankId, @ReadingDate) AS DECIMAL(18,2)), @ExpectedStock);

    DECLARE @Variance DECIMAL(18,2) = @ActualStock - @ExpectedStock;
    DECLARE @Rate DECIMAL(18,3) =
        PUMP.fn_ProductRateOnDate(@ProductId, CAST(@ReadingDate AS DATETIME2));

    /* Dip sirf naap hai, stock ko haath nahi lagati. */
    INSERT INTO PUMP.DipReadings
    (
        OwnerId, PumpId, TankId, ReadingDate, ShiftId, DipCm, WaterDipCm,
        Density, Temperature, ExpectedStock, ActualStock, Variance, VarianceAmount
    )
    VALUES
    (
        @OwnerId, @PumpId, @TankId, @ReadingDate, @ShiftId, @DipCm, @WaterDipCm,
        @Density, @Temperature, @ExpectedStock, @ActualStock, @Variance,
        ROUND(@Variance * ISNULL(@Rate, 0), 2)
    );

    SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS Id;
END
GO
PRINT '  + AB3: sp_DipReading_Save - book stock server par';
GO

/* ---------- AB4 ---------- */
CREATE OR ALTER PROCEDURE [PUMP].[sp_DipReading_Update]
(
    @Id BIGINT,
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @TankId BIGINT,
    @ReadingDate DATE,
    @ShiftId BIGINT = NULL,
    @DipCm DECIMAL(10,2),
    @WaterDipCm DECIMAL(10,2) = NULL,
    @Density DECIMAL(10,4) = NULL,
    @Temperature DECIMAL(10,2) = NULL,
    @ExpectedStock DECIMAL(18,2) = 0,
    @ActualStock DECIMAL(18,2) = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ProductId BIGINT;
    SELECT @ProductId = ProductId
    FROM PUMP.Tanks
    WHERE Id = @TankId AND OwnerId = @OwnerId AND PumpId = @PumpId;

    SET @ExpectedStock = ISNULL(CAST(PUMP.fn_TankBookStockForDip(@TankId, @ReadingDate) AS DECIMAL(18,2)), @ExpectedStock);

    DECLARE @Variance DECIMAL(18,2) = @ActualStock - @ExpectedStock;
    DECLARE @Rate DECIMAL(18,3) =
        PUMP.fn_ProductRateOnDate(@ProductId, CAST(@ReadingDate AS DATETIME2));

    UPDATE PUMP.DipReadings
    SET
        TankId         = @TankId,
        ReadingDate    = @ReadingDate,
        ShiftId        = @ShiftId,
        DipCm          = @DipCm,
        WaterDipCm     = @WaterDipCm,
        Density        = @Density,
        Temperature    = @Temperature,
        ExpectedStock  = @ExpectedStock,
        ActualStock    = @ActualStock,
        Variance       = @Variance,
        VarianceAmount = ROUND(@Variance * ISNULL(@Rate, 0), 2),
        UpdatedOn      = SYSDATETIME()
    WHERE Id = @Id AND OwnerId = @OwnerId AND PumpId = @PumpId;

    DECLARE @Rows INT = @@ROWCOUNT;     -- Section AA: API isi se safal/asafal jaanti hai
    SELECT @Rows AS Affected;
END
GO
PRINT '  + AB4: sp_DipReading_Update - book stock server par';
GO

/* ---------- AB5 ---------- */
CREATE OR ALTER PROCEDURE PUMP.sp_Shift_ClosingDipList
(
    @ShiftId BIGINT,
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PumpId BIGINT, @Dt DATE, @Status NVARCHAR(30);
    SELECT @PumpId = PumpId, @Dt = ShiftDate, @Status = Status
    FROM PUMP.ShiftHeaders
    WHERE Id = @ShiftId AND OwnerId = @OwnerId;

    /* Positional DTO ke liye khaali result bhi usi aakaar ka chahiye. */
    SELECT
        TankId             = t.Id,
        TankName           = t.Name,
        ProductName        = p.Name,
        /* Is shift ki apni bikri CHHOD kar book stock. Form me jaise-jaise
           closing reading bharte hain, JS usme se is shift ki bikri ghata kar
           turant farak dikhata hai. Band shift (edit) ki bikri fn me pehle se
           judi hoti hai - use wapas jod dete hain. */
        BookExcludingShift = CAST(ISNULL(PUMP.fn_TankBookStockForDip(t.Id, @Dt), 0)
                                  + CASE WHEN @Status = 'CLOSED' THEN ISNULL(ts.Sold, 0) ELSE 0 END
                                  AS DECIMAL(18,3)),
        NozzleIds          = ISNULL(nz.Ids, N''),
        DipId              = d.Id,
        DipCm              = d.DipCm,
        ActualStock        = d.ActualStock
    FROM PUMP.Tanks t
    JOIN PUMP.Products p ON p.Id = t.ProductId
    OUTER APPLY
    (
        SELECT OnlyTank = CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END
        FROM PUMP.Tanks t2
        WHERE t2.PumpId = t.PumpId AND t2.ProductId = t.ProductId AND t2.IsActive = 1
    ) o
    OUTER APPLY
    (
        SELECT Sold = SUM(snr.SoldQty)
        FROM PUMP.ShiftNozzleReadings snr
        JOIN PUMP.Nozzles n ON n.Id = snr.NozzleId
        WHERE snr.ShiftId = @ShiftId
          AND (n.TankId = t.Id OR (n.TankId IS NULL AND n.ProductId = t.ProductId AND o.OnlyTank = 1))
    ) ts
    OUTER APPLY
    (
        SELECT Ids = STRING_AGG(CAST(n.Id AS NVARCHAR(20)), N',')
        FROM PUMP.Nozzles n
        WHERE n.PumpId = t.PumpId
          AND (n.TankId = t.Id OR (n.TankId IS NULL AND n.ProductId = t.ProductId AND o.OnlyTank = 1))
    ) nz
    OUTER APPLY
    (
        SELECT TOP 1 dr.Id, dr.DipCm, dr.ActualStock
        FROM PUMP.DipReadings dr
        WHERE dr.ShiftId = @ShiftId AND dr.TankId = t.Id AND dr.IsActive = 1
        ORDER BY dr.Id DESC
    ) d
    WHERE t.PumpId = @PumpId
      AND t.IsActive = 1
      AND ISNULL(t.IsDeleted, 0) = 0
    ORDER BY t.Name;
END
GO
PRINT '  + AB5: sp_Shift_ClosingDipList';
GO

/* ---------- AB6 ---------- */
CREATE OR ALTER PROCEDURE PUMP.sp_Shift_SaveClosingDips
(
    @ShiftId  BIGINT,
    @OwnerId  BIGINT,
    @UserId   BIGINT = NULL,
    @DipsJson NVARCHAR(MAX)
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @PumpId BIGINT, @Dt DATE, @Status NVARCHAR(30);
    SELECT @PumpId = PumpId, @Dt = ShiftDate, @Status = Status
    FROM PUMP.ShiftHeaders
    WHERE Id = @ShiftId AND OwnerId = @OwnerId;

    IF @PumpId IS NULL
        THROW 50260, 'Shift not found.', 1;

    /* Dip ko shift ke BAAD ke stock se milana hai. Khuli shift par dip lena hi
       09 Sep wali galti thi. */
    IF @Status <> 'CLOSED'
        THROW 50261, 'Close the shift first - the dip is compared with the stock after this shift''s sale.', 1;

    IF ISJSON(@DipsJson) <> 1
        THROW 50262, 'Invalid dip data.', 1;

    DECLARE @In TABLE (TankId BIGINT PRIMARY KEY, DipCm DECIMAL(10,2), ActualStock DECIMAL(18,2));

    INSERT INTO @In (TankId, DipCm, ActualStock)
    SELECT j.TankId, MAX(ISNULL(j.DipCm, 0)), MAX(j.ActualStock)
    FROM OPENJSON(@DipsJson)
         WITH (TankId      BIGINT         '$.TankId',
               DipCm       DECIMAL(10,2)  '$.DipCm',
               ActualStock DECIMAL(18,2)  '$.ActualStock') j
    WHERE ISNULL(j.TankId, 0) > 0 AND ISNULL(j.ActualStock, 0) > 0
    GROUP BY j.TankId;

    IF EXISTS (SELECT 1 FROM @In i
               WHERE NOT EXISTS (SELECT 1 FROM PUMP.Tanks t
                                 WHERE t.Id = i.TankId AND t.PumpId = @PumpId AND t.OwnerId = @OwnerId))
        THROW 50263, 'A tank does not belong to this shift''s pump.', 1;

    BEGIN TRANSACTION;

    /* Is shift + tank par pehle se chaalu dip hai (shift edit karke dobara
       band ki) to NAYI mat banao - wahi badlo. Warna har edit par ek aur dip
       judti aur list me dohri-tehri entry ho jaati. */
    ;WITH cur AS
    (
        SELECT dr.*, rn = ROW_NUMBER() OVER (PARTITION BY dr.TankId ORDER BY dr.Id DESC)
        FROM PUMP.DipReadings dr
        WHERE dr.ShiftId = @ShiftId AND dr.IsActive = 1
    )
    UPDATE c
    SET c.ReadingDate    = @Dt,
        c.DipCm          = i.DipCm,
        c.ActualStock    = i.ActualStock,
        c.ExpectedStock  = b.Book,
        c.Variance       = i.ActualStock - b.Book,
        c.VarianceAmount = ROUND((i.ActualStock - b.Book) *
                           ISNULL(PUMP.fn_ProductRateOnDate(t.ProductId, CAST(@Dt AS DATETIME2)), 0), 2),
        c.UpdatedOn      = SYSDATETIME()
    FROM cur c
    JOIN @In i        ON i.TankId = c.TankId
    JOIN PUMP.Tanks t ON t.Id = c.TankId
    CROSS APPLY (SELECT Book = CAST(ISNULL(PUMP.fn_TankBookStockForDip(c.TankId, @Dt), 0) AS DECIMAL(18,2))) b
    WHERE c.rn = 1;

    INSERT INTO PUMP.DipReadings
        (OwnerId, PumpId, TankId, ReadingDate, ShiftId, DipCm,
         ExpectedStock, ActualStock, Variance, VarianceAmount)
    SELECT @OwnerId, @PumpId, i.TankId, @Dt, @ShiftId, i.DipCm,
           b.Book, i.ActualStock, i.ActualStock - b.Book,
           ROUND((i.ActualStock - b.Book) *
                 ISNULL(PUMP.fn_ProductRateOnDate(t.ProductId, CAST(@Dt AS DATETIME2)), 0), 2)
    FROM @In i
    JOIN PUMP.Tanks t ON t.Id = i.TankId
    CROSS APPLY (SELECT Book = CAST(ISNULL(PUMP.fn_TankBookStockForDip(i.TankId, @Dt), 0) AS DECIMAL(18,2))) b
    WHERE NOT EXISTS (SELECT 1 FROM PUMP.DipReadings dr
                      WHERE dr.ShiftId = @ShiftId AND dr.TankId = i.TankId AND dr.IsActive = 1);

    COMMIT TRANSACTION;

    /* Jo bacha wo form ko wapas - "HSD Tank: farak +4.7 L" jaisa sandesh. */
    SELECT TankId        = i.TankId,
           TankName      = t.Name,
           ExpectedStock = x.ExpectedStock,
           ActualStock   = x.ActualStock,
           Variance      = x.Variance
    FROM @In i
    JOIN PUMP.Tanks t ON t.Id = i.TankId
    CROSS APPLY
    (
        SELECT TOP 1 dr.ExpectedStock, dr.ActualStock, dr.Variance
        FROM PUMP.DipReadings dr
        WHERE dr.ShiftId = @ShiftId AND dr.TankId = i.TankId AND dr.IsActive = 1
        ORDER BY dr.Id DESC
    ) x
    ORDER BY t.Name;
END
GO
PRINT '  + AB6: sp_Shift_SaveClosingDips';
GO

/* ---------- AB7: purani dip ka Book Stock / Variance naye hisaab se ----------
   Sirf nikaale hue khaane badalte hain (ExpectedStock, Variance, VarianceAmount).
   Napa hua ActualStock, date, tank - kuch nahi chhua. Dobara chalao to wahi
   nateeja - kuch dohra nahi hota. */
UPDATE d
SET d.ExpectedStock  = b.Book,
    d.Variance       = d.ActualStock - b.Book,
    d.VarianceAmount = ROUND((d.ActualStock - b.Book) *
                       ISNULL(PUMP.fn_ProductRateOnDate(t.ProductId, CAST(d.ReadingDate AS DATETIME2)), 0), 2)
FROM PUMP.DipReadings d
JOIN PUMP.Tanks t ON t.Id = d.TankId
CROSS APPLY (SELECT Book = CAST(PUMP.fn_TankBookStockForDip(d.TankId, d.ReadingDate) AS DECIMAL(18,2))) b
WHERE b.Book IS NOT NULL
  AND (d.ExpectedStock <> b.Book OR d.Variance <> d.ActualStock - b.Book);
PRINT '  + AB7: purani dip ka book stock / variance dobara gina';
GO

/* ---------- AB8: Dip list ka variance LIVE ----------
   Stored ExpectedStock ek pal ki tasveer hai. Baad me pichhle din ki dip badle,
   ya koi shift edit ho, to aage ke din ki stored value purani pad jaati hai -
   aur list phir se DSR se alag bolne lagti. Isliye list ab har baar naye sire
   se nikaalti hai. Column, kram aur type wahi (ApiDipReadingDto positional hai). */
CREATE OR ALTER PROCEDURE [PUMP].[sp_DipReading_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 20
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        dr.Id,
        dr.OwnerId,
        dr.PumpId,
        dr.TankId,
        t.Name + ' (' + p.Name + ')' AS TankName,
        dr.ReadingDate,
        dr.ShiftId,
        dr.DipCm,
        dr.WaterDipCm,
        dr.Density,
        dr.Temperature,
        ExpectedStock  = b.Book,
        dr.ActualStock,
        Variance       = CAST(dr.ActualStock - b.Book AS DECIMAL(18,2)),
        VarianceAmount = CAST(ROUND((dr.ActualStock - b.Book) *
                         ISNULL(PUMP.fn_ProductRateOnDate(t.ProductId, CAST(dr.ReadingDate AS DATETIME2)), 0), 2) AS DECIMAL(18,2)),
        dr.CreatedOn,
        dr.IsActive
    FROM PUMP.DipReadings dr
    INNER JOIN PUMP.Tanks t    ON t.Id = dr.TankId
    INNER JOIN PUMP.Products p ON p.Id = t.ProductId
    CROSS APPLY (SELECT Book = CAST(ISNULL(PUMP.fn_TankBookStockForDip(dr.TankId, dr.ReadingDate),
                                           dr.ExpectedStock) AS DECIMAL(18,2))) b
    WHERE dr.OwnerId = @OwnerId
      AND dr.PumpId = @PumpId
      AND (@FromDate IS NULL OR dr.ReadingDate >= @FromDate)
      AND (@ToDate IS NULL OR dr.ReadingDate <= @ToDate)
    ORDER BY dr.ReadingDate DESC, dr.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(1)
    FROM PUMP.DipReadings dr
    WHERE dr.OwnerId = @OwnerId
      AND dr.PumpId = @PumpId
      AND (@FromDate IS NULL OR dr.ReadingDate >= @FromDate)
      AND (@ToDate IS NULL OR dr.ReadingDate <= @ToDate);
END
GO
PRINT '  + AB8: sp_DipReading_List - variance live, hamesha DSR ke barabar';
PRINT '=== Section AB done ===';
GO

/* ==========================================================================================
   SECTION AC — DSR: mahine ka opening = pichhle mahine ka closing (2026-09-19)
   ------------------------------------------------------------------------------------------
   Back-date / current-day hisaab ki jaanch me mila: register mahine ke andar har
   din dip se naya shuru karta hai, par har MAHINE ki shuruaat tank ke kitaabi
   stock se karta tha. Dono me 1 tarikh se ka jama farak hota hai - to October ka
   closing aur November ka opening alag the, aur nayi mahine ki pehli dip par
   saara purana farak ek din me "Excess/Short" dikhta. Dip list (Section AB) aur
   register tab alag number bolte. LocalDB par chala kar pakda: 2 Nov ko list
   "-2", register "0.00".

   Poora SP dobara (file ke ANT me, kyunki ye Section AB ke fn_TankBookStockForDip
   par tika hai - PART 1 me likhne par wo abhi bana hi nahi hota). Sirf opening
   wala hissa naya hai; baaki SP hoobahoo wahi.
   ========================================================================================== */
PRINT '=== Section AC: DSR ka mahine ka opening = pichhle mahine ka closing ===';
GO
CREATE OR ALTER PROCEDURE [PUMP].[sp_Report_DailyStockRegister]

(

    @PumpId    BIGINT,

    @ProductId BIGINT,

    @Month     INT,

    @Year      INT

,
    @OwnerId BIGINT = NULL
)

AS

BEGIN

    SET NOCOUNT ON;

    -- TENANT GUARD: pump usi owner ka hona chahiye. Pehle is report me OwnerId
    -- tha hi nahi — sirf pumpId guess karke doosre owner ki poore mahine ki
    -- stock report nikaali ja sakti thi.
    IF @OwnerId IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM PUMP.Pumps WHERE Id = @PumpId AND OwnerId = @OwnerId)
        RETURN;




    DECLARE @StartDate DATE = DATEFROMPARTS(@Year, @Month, 1);

    DECLARE @EndDate   DATE = EOMONTH(@StartDate);



    -- 1. Calculate Initial Opening Stock at the start of the month

    DECLARE @InitialOpening DECIMAL(18,3) = 0;

    SELECT @InitialOpening = ISNULL(SUM(CurrentStock), 0)

    FROM PUMP.Tanks

    WHERE PumpId = @PumpId AND ProductId = @ProductId AND IsActive = 1;



    DECLARE @NetChangeSinceStart DECIMAL(18,3) = 0;

    -- Stock badhane wale TxnType wahi hone chahiye jo sp_TankTxn_Save maanta hai:
    -- IN, RECEIPT, PURCHASE, OPENING. Pehle yahan sirf 'IN' likha tha, isliye har
    -- PURCHASE row ko ghatav (-) maan liya jaata tha aur mahine ka opening stock
    -- purchase ki maatra jitna ZYADA dikhta tha. Purchase se ab automatic
    -- TxnType='PURCHASE' row banti hai (dekho sp_Purchase_SaveDetail), isliye ye
    -- galti har delivery par register bigaad rahi thi.
    SELECT @NetChangeSinceStart = ISNULL(

        SUM(CASE WHEN UPPER(TxnType) IN ('IN', 'RECEIPT', 'PURCHASE', 'OPENING')
                 THEN Quantity ELSE -Quantity END), 0)

    FROM PUMP.TankTransactions

    WHERE PumpId = @PumpId

      AND TankId IN (SELECT Id FROM PUMP.Tanks WHERE ProductId = @ProductId AND PumpId = @PumpId)

      AND CAST(TxnDateTime AS DATE) >= @StartDate;



    SET @InitialOpening = @InitialOpening - @NetChangeSinceStart;

    /* ---- Section AC: pichhle mahine ka closing = is mahine ka opening ----
       Upar wala hisaab tank ke KITAABI stock (CurrentStock) se ulta chalta hai.
       Mahine ke andar register har din dip par naya shuru hota hai, par mahine
       ki pehli tareekh par wapas kitaabi stock par aa jaata tha - usme 1 tarikh
       se ka saara jama farak hota hai. Nateeja: pichhle mahine ka closing aur
       is mahine ka opening alag, aur agle mahine ki pehli dip wale din poora
       purana farak ek saath "Excess/Short" ban kar dikhta (UAT par 1 Oct ko
       diesel ~+55 L aata).

       Ab jis tank ki pichhle mahine ke ant tak koi naap (chaalu dip ya
       reconciliation) hai, uska opening = us aakhri din ka closing: us din dip
       thi to dip, warna reconciliation, warna fn_TankBookStockForDip (wahi
       hisaab jo register roz lagata hai). Jis tank ki kabhi naap hi nahi hui,
       uska purana hisaab bilkul waisa hi - isliye bina dip wale register ka ek
       ank nahi badalta. */
    DECLARE @PrevDay DATE = DATEADD(DAY, -1, @StartDate);
    DECLARE @OpeningSwap DECIMAL(18,3) = 0;

    ;WITH measured AS
    (
        SELECT t.Id,
               OldOpening = t.CurrentStock - ISNULL((
                   SELECT SUM(CASE WHEN UPPER(x.TxnType) IN ('IN', 'RECEIPT', 'PURCHASE', 'OPENING')
                                   THEN x.Quantity ELSE -x.Quantity END)
                   FROM PUMP.TankTransactions x
                   WHERE x.PumpId = @PumpId AND x.TankId = t.Id
                     AND CAST(x.TxnDateTime AS DATE) >= @StartDate), 0),
               NewOpening = COALESCE(
                   (SELECT TOP 1 d.ActualStock FROM PUMP.DipReadings d
                    WHERE d.TankId = t.Id AND d.IsActive = 1 AND d.ActualStock > 0 AND d.ReadingDate = @PrevDay
                    ORDER BY d.Id DESC),
                   (SELECT TOP 1 r.PhysicalStock FROM PUMP.StockReconciliations r
                    WHERE r.TankId = t.Id AND CAST(r.ReconciliationDate AS DATE) = @PrevDay
                    ORDER BY r.Id DESC),
                   PUMP.fn_TankBookStockForDip(t.Id, @PrevDay))
        FROM PUMP.Tanks t
        WHERE t.PumpId = @PumpId AND t.ProductId = @ProductId AND t.IsActive = 1
          AND (   EXISTS (SELECT 1 FROM PUMP.DipReadings d
                          WHERE d.TankId = t.Id AND d.IsActive = 1 AND d.ActualStock > 0 AND d.ReadingDate <= @PrevDay)
               OR EXISTS (SELECT 1 FROM PUMP.StockReconciliations r
                          WHERE r.TankId = t.Id AND CAST(r.ReconciliationDate AS DATE) <= @PrevDay))
    )
    SELECT @OpeningSwap = ISNULL(SUM(NewOpening - OldOpening), 0) FROM measured;

    SET @InitialOpening = @InitialOpening + @OpeningSwap;



    -- 2. Generate Calendar for the Month

    CREATE TABLE #Calendar ( DateValue DATE PRIMARY KEY );

    DECLARE @CurDate DATE = @StartDate;

    WHILE @CurDate <= @EndDate

    BEGIN

        INSERT INTO #Calendar (DateValue) VALUES (@CurDate);

        SET @CurDate = DATEADD(day, 1, @CurDate);

    END



    -- 3. Daily Base Data

    CREATE TABLE #DailyReport

    (

        RowId INT IDENTITY(1,1) PRIMARY KEY,

        [Date] DATE,

        OpeningStock DECIMAL(18,3),

        Receipt DECIMAL(18,3),

        TotalStock DECIMAL(18,3),

        SalesByMeter DECIMAL(18,3),

        PumpTest DECIMAL(18,3),

        NetSalesByMeter DECIMAL(18,3),

        ClosingDipStock DECIMAL(18,3),

        SalesByDip DECIMAL(18,3),

        VariationDaily DECIMAL(18,3),
        -- CA ke liye zaroori: kitaabi closing aur asli (dip) closing ALAG-ALAG
        -- dikhne chahiye. Pehle sirf ek "ClosingStock" tha jo chupke se dip par
        -- switch ho jaata tha - dekhne wale ko pata hi nahi chalta tha ki
        -- variance kis aadhaar par nikla.
        BookClosingStock DECIMAL(18,3),
        PhysicalClosingStock DECIMAL(18,3),
        -- Us din stock physically napa gaya tha ya nahi. Bina iske "variance 0"
        -- ke do matlab ho jaate hain: sab theek, ya napa hi nahi gaya.
        StockChecked BIT,
        -- Us din ka rate aur us hisaab se bikri ki rupee value. CA isi se
        -- register ko bikri khaate aur GST return se milata hai.
        RateApplied DECIMAL(18,3),
        SalesValue DECIMAL(18,2),

        -- Din ke aakhir ka bacha hua stock. Register me ye column tha hi nahi,
        -- jabki DSR ka matlab hi yahi hota hai — aur agle din ka opening isi se
        -- banta hai, to dono ka milna user ko dikhna chahiye.
        ClosingStock DECIMAL(18,3),

        -- Nuksaan/faayde ke PAISE. "45 litre kam hai" se zyada matlab
        -- "Rs 4,302 ka nuksaan" rakhta hai — pump wale ko yahi dekhna hota hai.
        VariationValue DECIMAL(18,2),

        Remarks NVARCHAR(255)

    );



    INSERT INTO #DailyReport ([Date], Receipt, SalesByMeter, PumpTest, NetSalesByMeter, ClosingDipStock)

    SELECT

        c.DateValue,

        -- Receipts (excluding internal adjustments and reconciliations)

        ISNULL((

            SELECT SUM(Quantity)

            FROM PUMP.TankTransactions

            WHERE PumpId   = @PumpId

              -- Sirf 'IN' dekhne se tanker delivery (TxnType='PURCHASE') Receipt me
              -- 0 dikhti thi. Ab wahi chaar type jo stock badhate hain.
              AND UPPER(TxnType) IN ('IN', 'RECEIPT', 'PURCHASE', 'OPENING')

              AND TankId IN (SELECT Id FROM PUMP.Tanks WHERE ProductId = @ProductId AND PumpId = @PumpId)

              AND CAST(TxnDateTime AS DATE) = c.DateValue

              -- ISNULL zaroori hai: SQL me "NULL NOT LIKE '...'" ka jawab NULL hota
              -- hai, TRUE nahi — yaani jis entry me ReferenceNo khaali chhoda gaya
              -- (manual tank stock entry) wo chupchaap Receipt se gayab ho jaati thi.
              AND ISNULL(ReferenceNo, N'') NOT LIKE 'LOSS-DEL-%'

              AND ISNULL(ReferenceNo, N'') NOT LIKE 'VOID-SALE-%'

              AND ISNULL(ReferenceNo, N'') NOT LIKE 'SHIFT-EDIT-%'

              AND ISNULL(ReferenceNo, N'') NOT LIKE 'RECON-%'

        ), 0) AS Receipt,

        -- Gross Sales grouped by ShiftDate

        ISNULL((

            SELECT SUM(snr.SoldQty + snr.TestingLoss)

            FROM PUMP.ShiftNozzleReadings snr

            INNER JOIN PUMP.ShiftHeaders sh ON sh.Id = snr.ShiftId

            WHERE snr.ProductId = @ProductId AND sh.PumpId = @PumpId

              AND sh.Status = 'CLOSED'

              AND sh.ShiftDate = c.DateValue

        ), 0) AS SalesByMeter,

        -- Pump Test grouped by ShiftDate

        ISNULL((

            SELECT SUM(snr.TestingLoss)

            FROM PUMP.ShiftNozzleReadings snr

            INNER JOIN PUMP.ShiftHeaders sh ON sh.Id = snr.ShiftId

            WHERE snr.ProductId = @ProductId AND sh.PumpId = @PumpId

              AND sh.Status = 'CLOSED'

              AND sh.ShiftDate = c.DateValue

        ), 0) AS PumpTest,

        -- Net Sales grouped by ShiftDate

        ISNULL((

            SELECT SUM(snr.SoldQty)

            FROM PUMP.ShiftNozzleReadings snr

            INNER JOIN PUMP.ShiftHeaders sh ON sh.Id = snr.ShiftId

            WHERE snr.ProductId = @ProductId AND sh.PumpId = @PumpId

              AND sh.Status = 'CLOSED'

              AND sh.ShiftDate = c.DateValue

        ), 0) AS NetSalesByMeter,

        -- Closing physical dip stock

        ISNULL(

            (

                SELECT SUM(ActualStock) FROM (

                    SELECT dr.ActualStock,

                           ROW_NUMBER() OVER (PARTITION BY dr.TankId ORDER BY dr.Id DESC) as rn

                    FROM PUMP.DipReadings dr

                    INNER JOIN PUMP.Tanks tk ON tk.Id = dr.TankId

                    WHERE tk.PumpId = @PumpId AND tk.ProductId = @ProductId

                      AND dr.ReadingDate = c.DateValue

                      /* Dip list me switch band karne par row par laal "Deleted" ka
                         nishaan aa jaata hai, par ye query use phir bhi ginti thi -
                         yaani hataayi hui dip chupchaap poore din ka closing banti
                         rehti thi, aur wahi agle din ka opening bhi ban jaata tha. */
                      AND dr.IsActive = 1

                ) x WHERE x.rn = 1

            ),

            ISNULL(

                (

                    SELECT SUM(PhysicalStock) FROM (

                        SELECT sr.PhysicalStock,

                               ROW_NUMBER() OVER (PARTITION BY sr.TankId ORDER BY sr.Id DESC) as rn

                        FROM PUMP.StockReconciliations sr

                        INNER JOIN PUMP.Tanks tk ON tk.Id = sr.TankId

                        WHERE tk.PumpId = @PumpId AND tk.ProductId = @ProductId

                          AND CAST(sr.ReconciliationDate AS DATE) = c.DateValue

                    ) y WHERE y.rn = 1

                ), 0

            )

        ) AS ClosingDipStock

    FROM #Calendar c

    ORDER BY c.DateValue;



    -- 4. Iterative Calculation for Running Totals

    DECLARE @i INT = 1;

    DECLARE @MaxI INT;

    SELECT @MaxI = MAX(RowId) FROM #DailyReport;



    DECLARE @CurrentOpening DECIMAL(18,3) = @InitialOpening;

    DECLARE @Receipt DECIMAL(18,3), @NetSales DECIMAL(18,3), @Dip DECIMAL(18,3);




    WHILE @i <= @MaxI

    BEGIN

        SELECT

            @Receipt = Receipt,

            @NetSales = NetSalesByMeter,

            @Dip = ClosingDipStock

        FROM #DailyReport WHERE RowId = @i;



        DECLARE @ReportDate DATE = (SELECT [Date] FROM #DailyReport WHERE RowId = @i);

        /* "Aaj stock physically napa gaya tha ya nahi" — ye dip AUR reconciliation
           dono se aa sakta hai. Pehle sirf DipReadings ginti thi, isliye jis din
           sirf reconciliation hui thi us din variance zabardasti 0 dikhta tha,
           jabki ClosingDipStock me reconciliation ka physical stock pehle se
           aa raha tha. Nateeja: nuksaan sirf Remarks ke text me dikhta tha,
           Variation column aur mahine ke cumulative variance me nahi. */
        DECLARE @HasDip INT =
        (
            SELECT COUNT(1) FROM PUMP.DipReadings
            WHERE TankId IN (SELECT Id FROM PUMP.Tanks WHERE ProductId = @ProductId AND PumpId = @PumpId)
              AND ReadingDate = @ReportDate
              /* Upar wali query se milna zaroori hai: wahan dip chhut jaye aur
                 yahan gin li jaye to "Stock Checked = Yes" dikhega jabki variance
                 kisi aur hi aadhaar par nikla hoga. */
              AND IsActive = 1
        )
        +
        (
            SELECT COUNT(1) FROM PUMP.StockReconciliations
            WHERE TankId IN (SELECT Id FROM PUMP.Tanks WHERE ProductId = @ProductId AND PumpId = @PumpId)
              AND CAST(ReconciliationDate AS DATE) = @ReportDate
        );

        /* @Dip aage badal jaata hai (jis din napa nahi gaya us din use kitaabi
           stock se bhar dete hain), isliye asli napa hua stock yahin alag rakh
           lete hain - register me wahi dikhana hai. */
        DECLARE @MeasuredDip DECIMAL(18,3) = CASE WHEN @HasDip > 0 THEN @Dip ELSE NULL END;

        DECLARE @Total DECIMAL(18,3) = @CurrentOpening + @Receipt;
        DECLARE @SalesDip DECIMAL(18,3);
        DECLARE @VarDaily DECIMAL(18,3);

        /* Us din ka rate — mahine ke beech rate badla ho to har din apne rate par
           gina jaye, warna nuksaan ki value galat banegi. */
        DECLARE @DayRate DECIMAL(18,3) =
            PUMP.fn_ProductRateOnDate(@ProductId, DATEADD(HOUR, 23, CAST(@ReportDate AS DATETIME2(7))));

        /* Kitaabi (book) closing — jitna stock hona chahiye tha. Net se ghatao:
           test ka tel wapas tank me chala jaata hai, isliye wo tank se gaya hi nahi. */
        DECLARE @BookClosing DECIMAL(18,3) = @Total - @NetSales;

        IF @HasDip = 0
        BEGIN
            /* Aaj stock napa hi nahi gaya — variance ka koi sawaal nahi. */
            SET @SalesDip = @NetSales;
            SET @Dip = CASE WHEN @NetSales > 0 THEN @BookClosing ELSE @Dip END;
            SET @VarDaily = 0;
        END
        ELSE
        BEGIN
            /* Variance = physical - book. Minus = nuksaan (laal), plus = zyada
               nikla (hara). Pehle ulta tha (@SalesDip - @NetSales), isliye ek hi
               row me Remarks "-45" bolti thi aur Variation column "+45".
               StockReconciliations.VarianceQty aur DipReadings.Variance dono
               physical-book hi rakhte hain, ab register bhi wahi bolta hai. */
            SET @VarDaily = CASE WHEN @Dip > 0 THEN @Dip - @BookClosing ELSE 0 END;

            /* Dip se nikli sale = jitna stock ghata. Agar dip kitaabi stock se
               ZYADA nikle (bina entry wali delivery, ya galat purani entry) to ye
               rinaatmak ho jaata tha — "-7,916 litre bika" jaisi bekaar line.
               Sale kabhi minus nahi hoti; aisi soorat me 0 dikhao aur poori kahani
               Variation column me aa jaati hai. */
            SET @SalesDip =
                CASE WHEN @Dip > 0 AND @Total > @Dip THEN @Total - @Dip ELSE 0 END;
        END



        -- Fetch saved manual reconciliation variance

        DECLARE @ManualVar DECIMAL(18,3) = 0;

        DECLARE @ReconCount INT = 0;

        SELECT

            @ManualVar = ISNULL(SUM(VarianceQty), 0),

            @ReconCount = COUNT(Id)

        FROM PUMP.StockReconciliations

        WHERE TankId IN (SELECT Id FROM PUMP.Tanks WHERE ProductId = @ProductId AND PumpId = @PumpId)

          AND CAST(ReconciliationDate AS DATE) = (SELECT [Date] FROM #DailyReport WHERE RowId = @i);



        DECLARE @RemarksStr NVARCHAR(255) = NULL;

        /* Remarks me pehle bas 'Variance' likha aata tha. CA ko usse kuch pata
           nahi chalta tha: kitna, kis taraf, aur us din tank napa bhi gaya tha
           ya nahi. Khaali variance column ka matlab log "sab theek" samajh lete
           the, jabki asal me us din dip li hi nahi gayi hoti thi.
           Ab poori baat likhi jaati hai. */
        IF @ReconCount > 0
        BEGIN
            SET @RemarksStr = CONCAT('Reconciled by hand. Difference ',
                CASE WHEN @ManualVar < 0 THEN 'short ' ELSE 'excess ' END,
                CAST(CAST(ABS(@ManualVar) AS DECIMAL(18,1)) AS NVARCHAR(20)), ' L.');
        END
        ELSE IF @HasDip = 0
        BEGIN
            SET @RemarksStr = CASE WHEN @NetSales > 0 THEN N'Stock not measured' ELSE NULL END;
        END
        ELSE IF @VarDaily = 0
        BEGIN
            SET @RemarksStr = N'Dip matches book';
        END
        ELSE
        BEGIN
            SET @RemarksStr = CONCAT(
                CASE WHEN @VarDaily < 0 THEN 'Short ' ELSE 'Excess ' END,
                CAST(CAST(ABS(@VarDaily) AS DECIMAL(18,1)) AS NVARCHAR(20)), ' L',
                /* Seedha NVARCHAR me daalne par 'Rs 371.000000' chhapta tha -
                   pehle DECIMAL(18,0) me le aate hain, tabhi 'Rs 371' aata hai. */
                ' (Rs ', CAST(CAST(ABS(ROUND(@VarDaily * @DayRate, 0)) AS DECIMAL(18,0)) AS NVARCHAR(20)), ')');
        END



        -- Aaj ka closing = physical dip (agar liya gaya ho) warna kitaabi stock.
        -- Yahi agle din ka opening banega, isliye ek hi jagah nikaal kar dono me
        -- daal rahe hain — warna register ki do lines aapas me nahi milengi.
        DECLARE @ClosingStk DECIMAL(18,3) =
            CASE WHEN @Dip > 0 THEN @Dip ELSE @BookClosing END;

        UPDATE #DailyReport

        SET

            OpeningStock = @CurrentOpening,

            TotalStock = @Total,

            SalesByDip = @SalesDip,

            VariationDaily = @VarDaily,

            ClosingStock = @ClosingStk,

            BookClosingStock = @BookClosing,

            PhysicalClosingStock = @MeasuredDip,

            StockChecked = CASE WHEN @HasDip > 0 THEN 1 ELSE 0 END,

            RateApplied = @DayRate,

            SalesValue = ROUND(@NetSales * @DayRate, 2),

            VariationValue = ROUND(@VarDaily * @DayRate, 2),

            Remarks = @RemarksStr

        WHERE RowId = @i;



        SET @CurrentOpening = @ClosingStk;



        SET @i = @i + 1;

    END



    -- 5. Final Output

    SELECT

        DAY([Date])                                   AS DayOfMonth,

        [Date],

        CAST(OpeningStock    AS DECIMAL(18,0))        AS OpeningStock,

        CAST(Receipt         AS DECIMAL(18,0))        AS Receipt,

        CAST(TotalStock      AS DECIMAL(18,0))        AS TotalStock,

        CAST(SalesByMeter    AS DECIMAL(18,0))        AS SalesByMeter,

        CAST(PumpTest        AS DECIMAL(18,0))        AS PumpTest,

        CAST(NetSalesByMeter AS DECIMAL(18,0))        AS NetSalesByMeter,

        CAST(SUM(NetSalesByMeter) OVER (ORDER BY [Date]) AS DECIMAL(18,0)) AS CumulativeSales,

        CAST(SalesByDip      AS DECIMAL(18,0))        AS SalesByDip,

        /* Kitaabi closing = opening + receipt - net sale. Jitna hona chahiye tha. */

        CAST(BookClosingStock AS DECIMAL(18,0))       AS BookClosingStock,

        /* Asli napa hua stock. Jis din napa nahi gaya us din NULL - register me

           "-" dikhta hai, 0 nahi (0 ka matlab "tank khaali tha" hota hai). */

        CAST(PhysicalClosingStock AS DECIMAL(18,0))   AS PhysicalClosingStock,

        ISNULL(StockChecked, 0)                       AS StockChecked,

        CAST(ClosingStock    AS DECIMAL(18,0))        AS ClosingStock,

        /* Ye do column jaanbujh ke 2 decimal me hain (baaki poore litre me).
           Variance me chhote fraction bhi maayne rakhte hain: 0.46 L roz ka
           nuksaan poore litre me round hokar "0" dikhta tha, jabki mahine bhar
           me 14 litre ban jaata hai — aur uski rupee value column me dikhti bhi
           thi, to row aapas me ulat lagti thi (Variation 0, Value -Rs 43.98). */
        CAST(VariationDaily  AS DECIMAL(18,2))        AS VariationDaily,

        ISNULL(VariationValue, 0)                     AS VariationValue,

   CAST(SUM(VariationDaily) OVER (ORDER BY [Date]) AS DECIMAL(18,2)) AS VariationCumulative,

        /* Rate aur rupee value - CA register ko bikri khaate se yahin milata hai. */

        ISNULL(RateApplied, 0)                        AS RateApplied,

        ISNULL(SalesValue, 0)                         AS SalesValue,

        CAST(SUM(ISNULL(SalesValue, 0)) OVER (ORDER BY [Date]) AS DECIMAL(18,2)) AS CumulativeSalesValue,

        Remarks

    FROM #DailyReport

    ORDER BY [Date];



    DROP TABLE #Calendar;

    DROP TABLE #DailyReport;

END

GO
PRINT '  + AC1: sp_Report_DailyStockRegister - mahine ki opening ab pichhle mahine ke closing se';
PRINT '=== Section AC done ===';
GO

/* ==========================================================================================
   SECTION AD — Maahwar bikri-khareed register (2026-10-04)
   ------------------------------------------------------------------------------------------
   Owner ka apna haath se likha rajistar: EK MAHINA, EK PRODUCT, aur sirf chhe
   khaane — dinaank, bikri (litre), rate, total (Rs), khareed (litre), khareed (Rs);
   neeche mahine ka jod. CA ko yahi chahiye hota hai.

   DSR (sp_Report_DailyStockRegister) stock ka milaan hai — opening, dip, variation.
   Ye uska bhai hai: paise ka milaan. Dono ek hi aadhaar par:
     bikri  = band shifton ki SoldQty (test ka tel nahi — wo tank me wapas jaata hai)
     rate   = fn_ProductRateOnDate(us din 23:00) — mahine ke beech rate badla ho to
              har din apna rate (DSR ka SalesValue bhi yahi lagata hai)
     total  = bikri x rate  (isliye DSR ka "Sale Value" aur is register ka total milta hai)
     khareed= PurchaseDetails, bill ki tareekh (InvoiceDate) par — wahi din jis din
              stock tank me judta hai (sp_Purchase_SaveDetail)

   Mahine ka har din aata hai, chahe us din kuch na hua ho — rajistar me khaali
   line bhi apni jagah rehti hai.
   ========================================================================================== */
PRINT '=== Section AD: maahwar bikri-khareed register ===';
GO

CREATE OR ALTER PROCEDURE PUMP.sp_Report_MonthlySaleRegister
(
    @PumpId    BIGINT,
    @ProductId BIGINT,
    @Month     INT,
    @Year      INT,
    @OwnerId   BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    /* Tenant guard — DSR par ye pehle nahi tha aur doosre owner ka poora mahina
       sirf pumpId guess karke nikala ja sakta tha. Yahan shuru se hi. */
    IF @OwnerId IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM PUMP.Pumps WHERE Id = @PumpId AND OwnerId = @OwnerId)
        RETURN;

    DECLARE @Start DATE = DATEFROMPARTS(@Year, @Month, 1);
    DECLARE @End   DATE = EOMONTH(@Start);

    ;WITH cal AS
    (
        SELECT d = @Start
        UNION ALL
        SELECT DATEADD(DAY, 1, d) FROM cal WHERE d < @End
    )
    SELECT
        DayOfMonth     = DAY(c.d),
        [Date]         = c.d,
        SaleQty        = CAST(ISNULL(s.Qty, 0) AS DECIMAL(18,2)),
        Rate           = CAST(ISNULL(r.Rate, 0) AS DECIMAL(18,3)),
        SaleAmount     = CAST(ROUND(ISNULL(s.Qty, 0) * ISNULL(r.Rate, 0), 2) AS DECIMAL(18,2)),
        PurchaseQty    = CAST(ISNULL(p.Qty, 0) AS DECIMAL(18,2)),
        PurchaseAmount = CAST(ISNULL(p.Amt, 0) AS DECIMAL(18,2))
    FROM cal c
    CROSS APPLY
    (
        SELECT Rate = PUMP.fn_ProductRateOnDate(@ProductId, DATEADD(HOUR, 23, CAST(c.d AS DATETIME2(7))))
    ) r
    OUTER APPLY
    (
        SELECT Qty = SUM(snr.SoldQty)
        FROM PUMP.ShiftNozzleReadings snr
        JOIN PUMP.ShiftHeaders sh ON sh.Id = snr.ShiftId
        WHERE sh.PumpId = @PumpId
          AND sh.Status = 'CLOSED'
          AND sh.ShiftDate = c.d
          AND snr.ProductId = @ProductId
    ) s
    OUTER APPLY
    (
        SELECT Qty = SUM(pd.Quantity), Amt = SUM(pd.Amount)
        FROM PUMP.PurchaseDetails pd
        JOIN PUMP.PurchaseHeaders ph ON ph.Id = pd.PurchaseHeaderId
        WHERE ph.PumpId = @PumpId
          AND pd.ProductId = @ProductId
          AND ph.InvoiceDate = c.d
    ) p
    ORDER BY c.d
    OPTION (MAXRECURSION 400);
END
GO
PRINT '  + AD1: sp_Report_MonthlySaleRegister ready';
GO

/* ---- AD2: menu ---- */
IF NOT EXISTS (SELECT 1 FROM PUMP.Menus WHERE Route = '/sale-purchase-register')
BEGIN
    INSERT INTO PUMP.Menus (ParentId, MenuName, Route, Icon, Sequence, IsVisible, IsActive)
    SELECT ParentId, N'Sale / Purchase Register', '/sale-purchase-register', N'receipt_long', 23, 1, 1
    FROM PUMP.Menus WHERE Route = '/daily-stock-register';

    DECLARE @NewMenuId BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);
    DECLARE @DsrMenuId BIGINT = (SELECT Id FROM PUMP.Menus WHERE Route = '/daily-stock-register');

    /* Jis role ko DSR dikhta hai, usi ko ye bhi — wahi haq. */
    INSERT INTO PUMP.RoleMenus (RoleId, MenuId, CanView, CanCreate, CanEdit, CanDelete)
    SELECT rm.RoleId, @NewMenuId, rm.CanView, rm.CanCreate, rm.CanEdit, rm.CanDelete
    FROM PUMP.RoleMenus rm
    WHERE rm.MenuId = @DsrMenuId
      AND NOT EXISTS (SELECT 1 FROM PUMP.RoleMenus x
                      WHERE x.RoleId = rm.RoleId AND x.MenuId = @NewMenuId);

    PRINT '  + AD2: Sale / Purchase Register ka menu bana';
END
ELSE
    PRINT '  = AD2: Sale / Purchase Register ka menu pehle se hai';
GO
PRINT '=== Section AD done ===';
GO

/* ==========================================================================================
   SECTION AE — Khareed me BILL KI RAKAM hi sach hai (2026-10-08)
   ------------------------------------------------------------------------------------------
   Owner ne asli bill dikhaya:

       HSD 15,000 L   mool 11,91,750.30 + VAT 2,03,550.95 + SSLF 2,949.45 = 13,98,250.70
       MS   5,000 L   mool  4,10,993.70 + VAT   79,568.38 + SSLF 1,179.80 =  4,91,741.88
                                                           bill ka jod    = 18,89,992.58

   Form "rate per litre" maangta tha. Do dikkat:
     1. Khaane me BIKRI ka rate (95.60) pehle se bhara aata tha - log wahi chhod dete,
        to khareed aur bikri ka rate ek hi ho jaata.
     2. Sahi rate nikaalne ke liye user ko 13,98,250.70 / 15,000 khud karna padta -
        aur wo 93.2167 aata hai, jabki @Rate DECIMAL(18,2) tha. 93.22 likho to
        rakam 13,98,300.00 banti hai - bill se Rs 49.30 zyada.
   Upar se SP client ki bheji rakam maanta hi nahi tha:  SET @Amount = @Quantity * @Rate.
   Isliye Sale / Purchase Register me khareed ki rakam bill se kabhi nahi milti thi.

   AB: rakam di ho to WAHI save hoti hai, rate usse nikalta hai (4 ank, column pehle
   se DECIMAL(18,4) hai). Rakam na ho (purana client) to pehle jaisa Quantity x Rate.
   Isliye ye SP purani API ke saath bhi hoobahoo pehle jaisa chalta hai - wo
   Amount = Quantity x Rate hi bhejti hai.
   ========================================================================================== */
PRINT '=== Section AE: khareed me bill ki rakam hi sach ===';
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Purchase_SaveDetail]
(
    @PurchaseHeaderId BIGINT,
    @ProductId        BIGINT,
    @TankId           BIGINT = NULL,
    @Quantity         DECIMAL(18,3),
    @Rate             DECIMAL(18,4) = NULL,
    @Amount           DECIMAL(18,2) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF ISNULL(@Quantity, 0) <= 0
        THROW 50121, 'Purchase quantity must be more than zero.', 1;

    IF ISNULL(@Amount, 0) > 0
        /* Bill ki rakam di hai - wahi sach. Rate sirf jaankari ke liye. */
        SET @Rate = ROUND(@Amount / @Quantity, 4);
    ELSE IF ISNULL(@Rate, 0) > 0
        SET @Amount = ROUND(@Quantity * @Rate, 2);
    ELSE
        THROW 50122, 'Enter the bill amount for this purchase line.', 1;

    DECLARE @OwnerId BIGINT, @PumpId BIGINT, @InvoiceDate DATE;
    SELECT @OwnerId = OwnerId, @PumpId = PumpId, @InvoiceDate = InvoiceDate
    FROM PUMP.PurchaseHeaders
    WHERE Id = @PurchaseHeaderId;

    /* Tank usi product ka hona chahiye jiska tel aaya hai (G20). */
    IF @TankId IS NOT NULL AND @TankId > 0
    BEGIN
        IF NOT EXISTS (
            SELECT 1 FROM PUMP.Tanks
            WHERE Id = @TankId
              AND ProductId = @ProductId
              AND (@OwnerId IS NULL OR OwnerId = @OwnerId)
              AND (@PumpId  IS NULL OR PumpId  = @PumpId)
        )
            THROW 50120, 'The selected tank does not hold this product. Pick the tank that stores this fuel.', 1;
    END

    INSERT INTO PUMP.PurchaseDetails (PurchaseHeaderId, ProductId, TankId, Quantity, Rate, Amount)
    VALUES (@PurchaseHeaderId, @ProductId, @TankId, @Quantity, @Rate, @Amount);

    IF @TankId IS NOT NULL AND @TankId > 0
    BEGIN
        UPDATE PUMP.Tanks
        SET CurrentStock = CurrentStock + @Quantity,
            UpdatedOn    = SYSDATETIME()
        WHERE Id = @TankId;

        /* Purchase tank ledger me bhi jaati hai (G12). */
        IF @OwnerId IS NOT NULL AND @PumpId IS NOT NULL
        BEGIN
            INSERT INTO PUMP.TankTransactions
                (OwnerId, PumpId, TankId, TxnType, Quantity, ReferenceNo, Notes, TxnDateTime)
            VALUES
                (@OwnerId, @PumpId, @TankId, 'PURCHASE', @Quantity,
                 CONCAT('PURCHASE-', @PurchaseHeaderId), 'Auto entry from purchase',
                 ISNULL(CAST(@InvoiceDate AS DATETIME2), SYSDATETIME()));
        END
    END
END
GO
PRINT '  + AE1: sp_Purchase_SaveDetail - rakam di ho to wahi save, rate usse';
GO

/* ---- AE2: list ki line me rate ki jagah RAKAM ----
   Pehle "Diesel: 15000L @ Rs 93.2167" dikhta - 4 ank ka rate kisi kaam ka nahi.
   Ab "HSD: 15000 L = Rs 13,98,250.70" - wahi jo bill par hai. Column, kram aur
   type wahi (PurchaseDto positional hai). */
CREATE OR ALTER PROCEDURE [PUMP].[sp_Purchase_List]
(
    @OwnerId    BIGINT,
    @PumpId     BIGINT,
    @FromDate   DATE        = NULL,
    @ToDate     DATE        = NULL,
    @PageNumber INT         = 1,
    @PageSize   INT         = 20
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        ph.Id,
        ph.OwnerId,
        ph.PumpId,
        ph.VendorId,
        ISNULL(v.VendorName, 'Unknown')    AS VendorName,
        ph.InvoiceNo,
        ph.InvoiceDate,
        ph.VehicleNo,
        ph.DriverName,
        ph.TotalAmount,
        ph.Notes,
        ph.CreatedOn,
        ISNULL((
            SELECT SUM(pd.Quantity)
            FROM PUMP.PurchaseDetails pd
            WHERE pd.PurchaseHeaderId = ph.Id
        ), 0) AS TotalQty,
        ISNULL((
            SELECT STRING_AGG(
                CAST(pr.Name + N': ' + FORMAT(pd.Quantity, '0.##') + N' L = ' + NCHAR(8377)
                     + FORMAT(pd.Amount, 'N2', 'en-IN') AS NVARCHAR(MAX)),
                N' | ')
            FROM PUMP.PurchaseDetails pd
            INNER JOIN PUMP.Products pr ON pr.Id = pd.ProductId
            WHERE pd.PurchaseHeaderId = ph.Id
        ), N'') AS ProductSummary
    FROM PUMP.PurchaseHeaders ph
    LEFT JOIN PUMP.Vendors v ON v.Id = ph.VendorId
    WHERE ph.OwnerId = @OwnerId
      AND ph.PumpId  = @PumpId
      AND (@FromDate IS NULL OR CAST(ph.InvoiceDate AS DATE) >= @FromDate)
      AND (@ToDate   IS NULL OR CAST(ph.InvoiceDate AS DATE) <= @ToDate)
    ORDER BY ph.InvoiceDate DESC, ph.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(1)
    FROM PUMP.PurchaseHeaders ph
    WHERE ph.OwnerId = @OwnerId
      AND ph.PumpId  = @PumpId
      AND (@FromDate IS NULL OR CAST(ph.InvoiceDate AS DATE) >= @FromDate)
      AND (@ToDate   IS NULL OR CAST(ph.InvoiceDate AS DATE) <= @ToDate);
END
GO
PRINT '  + AE2: sp_Purchase_List - line me rakam';
GO

/* ---- AE3 / AE4: bill hatane ya badalne par stock POORA wapas ghate ----
   Dono SP me tha:

       UPDATE t SET CurrentStock = CurrentStock - pd.Quantity
       FROM PUMP.Tanks t JOIN PUMP.PurchaseDetails pd ON pd.TankId = t.Id ...

   Ek hi tank par bill ki DO line hon to SQL Server har tank ki row ko sirf EK
   baar update karta hai - doosri line ka stock tank me hi pada reh jaata hai.
   Test me pakda gaya: 15,000 + 100 + 10 litre wala bill hataya, tank se sirf 100
   ghata; 15,010 litre ka jhootha stock reh gaya. Ab pehle tank-wise JOD, phir ghatav.

   PrepareUpdate me ek aur kami thi: detail hatate waqt owner dekha hi nahi jaata
   tha. Ab bill usi owner ka na ho to kuch nahi chhua jaata. */
CREATE OR ALTER PROCEDURE [PUMP].[sp_Purchase_Delete]
(
    @Id      BIGINT,
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.PurchaseHeaders WHERE Id = @Id AND OwnerId = @OwnerId)
        THROW 50012, 'Purchase not found or access denied.', 1;

    BEGIN TRANSACTION;

        UPDATE t
        SET t.CurrentStock = t.CurrentStock - x.Qty,
            t.UpdatedOn    = SYSDATETIME()
        FROM PUMP.Tanks t
        INNER JOIN
        (
            SELECT TankId, Qty = SUM(Quantity)
            FROM PUMP.PurchaseDetails
            WHERE PurchaseHeaderId = @Id AND TankId IS NOT NULL
            GROUP BY TankId
        ) x ON x.TankId = t.Id
        WHERE t.OwnerId = @OwnerId;

        DELETE FROM PUMP.TankTransactions
        WHERE (ReferenceNo = CONCAT('PURCHASE-', CAST(@Id AS NVARCHAR(20)))
               OR ReferenceNo = CONCAT('PUR-', CAST(@Id AS NVARCHAR(20))))
          AND OwnerId = @OwnerId;

        DELETE FROM PUMP.PurchaseDetails WHERE PurchaseHeaderId = @Id;
        DELETE FROM PUMP.PurchaseHeaders WHERE Id = @Id AND OwnerId = @OwnerId;

    COMMIT TRANSACTION;

    SELECT @Id AS Id;
END
GO
PRINT '  + AE3: sp_Purchase_Delete - har tank ka poora stock wapas';
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Purchase_PrepareUpdate]
(
    @Id      BIGINT,
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    /* Doosre owner ka bill ho to kuch mat chhuo. (Transaction API kholti hai,
       isliye yahan apna nahi.) */
    IF NOT EXISTS (SELECT 1 FROM PUMP.PurchaseHeaders WHERE Id = @Id AND OwnerId = @OwnerId)
        THROW 50012, 'Purchase not found or access denied.', 1;

    UPDATE t
    SET t.CurrentStock = t.CurrentStock - x.Qty,
        t.UpdatedOn    = SYSDATETIME()
    FROM PUMP.Tanks t
    INNER JOIN
    (
        SELECT TankId, Qty = SUM(Quantity)
        FROM PUMP.PurchaseDetails
        WHERE PurchaseHeaderId = @Id AND TankId IS NOT NULL
        GROUP BY TankId
    ) x ON x.TankId = t.Id
    WHERE t.OwnerId = @OwnerId;

    DELETE FROM PUMP.TankTransactions
    WHERE (ReferenceNo = CONCAT('PURCHASE-', CAST(@Id AS NVARCHAR(20)))
           OR ReferenceNo = CONCAT('PUR-', CAST(@Id AS NVARCHAR(20))))
      AND OwnerId = @OwnerId;

    DELETE FROM PUMP.PurchaseDetails WHERE PurchaseHeaderId = @Id;
END
GO
PRINT '  + AE4: sp_Purchase_PrepareUpdate - wahi sudhaar + owner ki jaanch';
PRINT '=== Section AE done ===';
GO

/* ==========================================================================================
   SECTION AF — Party ka PURANA BAKI: dikhe bhi, aur "dobara gino" se mite bhi nahi (2026-10-13)
   ------------------------------------------------------------------------------------------
   Owner ka sawaal: "Ek party ka baki 41 hazaar, 25 hazaar jama kiya, phir bhi 41 hazaar?"

   Hisaab sahi tha:  46,500 (purana baki) + 20,000 (udhaar) - 25,000 (jama) = 41,500.
   Par 46,500 kahin dikhta hi nahi tha. Party banate waqt form me jo baki bhara jaata
   hai wo seedha Parties.CurrentBalance me chala jaata hai - khaate (PartyLedger) me
   uski koi line nahi. Khaate ki do line (20,000 aur 25,000) dekh kar lagta tha ki
   jama ka asar hi nahi hua.

   ISSE BADI BAAT: Support Console ka "Recount from ledger" (sp_Party_RecalculateBalance)
   baki ko sirf khaate ki line jod kar likh deta tha. Live par 101 me se 94 party ka
   purana baki khaate me nahi hai - kul Rs 12,51,239. Ek click me sab mit jaata.

   ILAAJ: purana baki party ke apne record me, ALAG khaane me (Parties.OpeningBalance).
       baki = OpeningBalance + khaate ki line
   Khaate me nayi line NAHI jodi: PartyLedger ko Day Book, shift ka cash, din ka
   collection - sab padhte hain; usme naya EntryType daalna har padhne wale ko
   samjhana padta. Alag khaana kisi purane hisaab ko chhuta hi nahi.

   SAB KUCH PURANI API/CLIENT KE SAATH CHALTA HAI: kisi purane SP ka result nahi badla.
     AF1  fn_PartyLedgerSigned         - ek line baki ko kitna badalti hai (+/-), EK jagah
          fn_PartyLedgerNet            - ek party ki saari line ka jod
     AF2  Parties.OpeningBalance       - column + EK BAAR ka backfill
                                         (= CurrentBalance - khaata; kisi ka baki nahi badalta)
     AF3  sp_Party_Save                - nayi party: OpeningBalance = bhara hua baki.
                                         Edit: baki badla to OpeningBalance utna hi badle
                                         (niyam bana rahe). @KeepBalance = 1 -> baki chhuo hi mat.
     AF4  sp_Party_RecalculateBalance  - ab OpeningBalance + khaata. Sach me surakshit.
     AF5  sp_PartyLedger_Statement     - NAYA: ek party ka khaata, har line ke saath chalta
                                         hua baki, aur purana baki / udhaar / jama alag-alag.

   COUPON: purana sp_CouponTxn_Save party ka baki ghatata tha; Section G11 wali
   definition (jo ab chalti hai) baki ko chhuti hi nahi. Isliye coupon yahan
   jaanbujh kar NAHI gine - ginte to "dobara gino" har coupon wali party ka baki
   ghata deta.
   ========================================================================================== */
PRINT '=== Section AF: party ka purana baki ===';
GO

/* ---------- AF1 ---------- */
CREATE OR ALTER FUNCTION PUMP.fn_PartyLedgerSigned (@EntryType NVARCHAR(30), @Amount DECIMAL(18,2))
RETURNS DECIMAL(18,2)
AS
BEGIN
    /* Wahi niyam jo likhne wale SP lagate hain:
         SALE / DEBIT / CHARGE -> baki BADHTA hai   (sp_PartyLedger_Save, sp_Sales_SaveHeader,
                                                     sp_ShiftCollection_Save)
         baaki sab             -> baki GHATTA hai   (RECEIPT, CREDIT ...)

       EK APVAAD - VOID. sp_Sale_Void line me rakam MINUS me likhta hai (-500) aur
       baki 500 ghatata hai. "Baaki sab ghatao" lagane par -(-500) = +500 ho jaata,
       yaani kaata hua bill khaate ke jod me DOBARA jud jaata. Purana recount yahi
       galti karta tha. */
    RETURN CASE
               WHEN UPPER(@EntryType) IN ('SALE', 'DEBIT', 'CHARGE') THEN @Amount
               WHEN UPPER(@EntryType) = 'VOID' AND @Amount < 0       THEN @Amount
               ELSE -@Amount
           END;
END
GO

CREATE OR ALTER FUNCTION PUMP.fn_PartyLedgerNet (@PartyId BIGINT)
RETURNS DECIMAL(18,2)
AS
BEGIN
    RETURN ISNULL((
        SELECT SUM(PUMP.fn_PartyLedgerSigned(l.EntryType, l.Amount))
        FROM PUMP.PartyLedger l
        WHERE l.PartyId = @PartyId), 0);
END
GO
PRINT '  + AF1: fn_PartyLedgerSigned / fn_PartyLedgerNet';
GO

/* ---------- AF2: column + ek baar ka backfill ----------
   Backfill SIRF usi waqt chalta hai jab column pehli baar banta hai. Dobara
   chalane par ye hissa kuch nahi karta - warna agar kabhi baki bigda ho to wo
   bigaad chupchaap "purana baki" ban jaata. (Dynamic SQL isliye ki column isi
   batch me ban raha hai; seedha likhne par "Invalid column name" aata.) */
IF COL_LENGTH('PUMP.Parties', 'OpeningBalance') IS NULL
BEGIN
    ALTER TABLE PUMP.Parties
        ADD OpeningBalance DECIMAL(18,2) NOT NULL
            CONSTRAINT DF_Parties_OpeningBalance DEFAULT (0);

    EXEC (N'UPDATE p
            SET p.OpeningBalance = p.CurrentBalance - PUMP.fn_PartyLedgerNet(p.Id)
            FROM PUMP.Parties p;');

    PRINT '  + AF2: Parties.OpeningBalance bana, purana baki bhar diya';
END
ELSE
    PRINT '  = AF2: Parties.OpeningBalance pehle se hai (backfill dobara nahi)';
GO

/* ---------- AF3 ---------- */
CREATE OR ALTER PROCEDURE [PUMP].[sp_Party_Save]
(
    @Id BIGINT,
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @PartyName NVARCHAR(150),
    @PartyType NVARCHAR(50),
    @Address NVARCHAR(250),
    @Mobile NVARCHAR(20),
    @Email NVARCHAR(100),
    @GSTIN NVARCHAR(20),
    @CreditLimit DECIMAL(18,2),
    @CurrentBalance DECIMAL(18,2),
    @IsActive BIT,
    /* Naya client ye 1 bhejta hai jab user ne baki ka khaana chhua hi nahi.
       Purana client ise nahi bhejta (0) - tab pehle jaisa vyavhaar. */
    @KeepBalance BIT = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @Id = 0
    BEGIN
        /* Nayi party: form ka baki hi uska PURANA BAKI hai. */
        INSERT INTO PUMP.Parties
            (OwnerId, PumpId, PartyName, PartyType, Address, Mobile, Email, GSTIN,
             CreditLimit, CurrentBalance, OpeningBalance, IsActive)
        VALUES
            (@OwnerId, @PumpId, @PartyName, @PartyType, @Address, @Mobile, @Email, @GSTIN,
             @CreditLimit, @CurrentBalance, @CurrentBalance, @IsActive);
    END
    ELSE
    BEGIN
        /* Edit: form ka khaana "abhi ka baki" hai. Use badla gaya ho to farak
           PURANE BAKI me jaata hai - khaate ki line waise ki waisi. Isse niyam
           (baki = purana baki + khaata) kabhi nahi toot-ta, aur "dobara gino"
           is sudhaar ko mitata nahi.

           Ek hi UPDATE me dono: daayin taraf ke CurrentBalance / OpeningBalance
           UPDATE se PEHLE ki value hain. */
        UPDATE PUMP.Parties
        SET PartyName      = @PartyName,
            PartyType      = @PartyType,
            Address        = @Address,
            Mobile         = @Mobile,
            Email          = @Email,
            GSTIN          = @GSTIN,
            CreditLimit    = @CreditLimit,
            OpeningBalance = CASE WHEN @KeepBalance = 1 THEN OpeningBalance
                                  ELSE OpeningBalance + (@CurrentBalance - CurrentBalance) END,
            CurrentBalance = CASE WHEN @KeepBalance = 1 THEN CurrentBalance ELSE @CurrentBalance END,
            IsActive       = @IsActive,
            UpdatedOn      = SYSDATETIME()
        WHERE Id = @Id
          AND OwnerId = @OwnerId
          AND PumpId = @PumpId;
    END
END
GO
PRINT '  + AF3: sp_Party_Save - purana baki alag, edit me niyam bana rahe';
GO

/* ---------- AF4 ---------- */
CREATE OR ALTER PROCEDURE PUMP.sp_Party_RecalculateBalance
(
    @OwnerId BIGINT,
    @PartyId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    /* Pehle: CurrentBalance = sirf khaate ka jod  -> purana baki mit jaata tha.
       Ab:    CurrentBalance = purana baki + khaata.
       Sirf unhi party ko chhuo jinka baki sach me alag hai - @@ROWCOUNT ab
       "kitni party theek hui" batata hai (0 = sab pehle se sahi). */
    UPDATE p
    SET p.CurrentBalance = p.OpeningBalance + PUMP.fn_PartyLedgerNet(p.Id),
        p.UpdatedOn      = SYSDATETIME()
    FROM PUMP.Parties p
    WHERE p.OwnerId = @OwnerId
      AND (@PartyId IS NULL OR p.Id = @PartyId)
      AND p.CurrentBalance <> p.OpeningBalance + PUMP.fn_PartyLedgerNet(p.Id);

    SELECT UpdatedParties = @@ROWCOUNT;
END
GO
PRINT '  + AF4: sp_Party_RecalculateBalance - ab purana baki nahi mitata';
GO

/* ---------- AF5 ---------- */
CREATE OR ALTER PROCEDURE PUMP.sp_PartyLedger_Statement
(
    @OwnerId    BIGINT,
    @PumpId     BIGINT,
    @PartyId    BIGINT,
    @SearchTerm NVARCHAR(100) = NULL,
    @PageNumber INT = 1,
    @PageSize   INT = 50
)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISNULL(@PageNumber, 0) < 1 SET @PageNumber = 1;
    IF ISNULL(@PageSize, 0)   < 1 SET @PageSize = 50;
    IF LTRIM(RTRIM(ISNULL(@SearchTerm, N''))) = N'' SET @SearchTerm = NULL;

    DECLARE @Opening DECIMAL(18,2), @Current DECIMAL(18,2), @Name NVARCHAR(150);
    SELECT @Opening = OpeningBalance, @Current = CurrentBalance, @Name = PartyName
    FROM PUMP.Parties
    WHERE Id = @PartyId AND OwnerId = @OwnerId AND PumpId = @PumpId;

    /* Doosre owner / pump ki party: khaali, par usi aakaar ka (positional DTO). */
    DECLARE @Rows TABLE
    (
        Seq INT PRIMARY KEY, Id BIGINT, EntryDateTime DATETIME2(7), EntryType NVARCHAR(30),
        Amount DECIMAL(18,2), ReferenceNo NVARCHAR(50), Notes NVARCHAR(250),
        PaymentMode NVARCHAR(30), SignedAmount DECIMAL(18,2), RunningBalance DECIMAL(18,2)
    );

    IF @Name IS NOT NULL
    BEGIN
        ;WITH e AS
        (
            SELECT l.Id, l.EntryDateTime, l.EntryType, l.Amount, l.ReferenceNo, l.Notes, l.PaymentMode,
                   Signed = PUMP.fn_PartyLedgerSigned(l.EntryType, l.Amount)
            FROM PUMP.PartyLedger l
            WHERE l.PartyId = @PartyId
        )
        INSERT INTO @Rows (Seq, Id, EntryDateTime, EntryType, Amount, ReferenceNo, Notes,
                           PaymentMode, SignedAmount, RunningBalance)
        SELECT ROW_NUMBER() OVER (ORDER BY EntryDateTime, Id),
               Id, EntryDateTime, EntryType, Amount, ReferenceNo, Notes, PaymentMode, Signed,
               /* Chalta hua baki SAARI line par (tareekh ke kram me) - sirf dikh rahe
                  page ya khoj ke nateeje par nahi. */
               @Opening + SUM(Signed) OVER (ORDER BY EntryDateTime, Id ROWS UNBOUNDED PRECEDING)
        FROM e;
    END

    /* 1. sirnaam:  purana baki + udhaar - jama = baki */
    SELECT
        PartyId        = @PartyId,
        PartyName      = ISNULL(@Name, N''),
        OpeningBalance = ISNULL(@Opening, 0),
        TotalDebit     = ISNULL((SELECT SUM(SignedAmount)  FROM @Rows WHERE SignedAmount > 0), 0),
        TotalCredit    = ISNULL((SELECT SUM(-SignedAmount) FROM @Rows WHERE SignedAmount < 0), 0),
        CurrentBalance = ISNULL(@Current, 0),
        /* Purana baki + khaata. CurrentBalance se alag ho to record bigda hai -
           Support Console ka "Recount" use theek karta hai. */
        LedgerBalance  = ISNULL(@Opening, 0) + ISNULL((SELECT SUM(SignedAmount) FROM @Rows), 0),
        TotalCount     = (SELECT COUNT(*) FROM @Rows r
                          WHERE @SearchTerm IS NULL
                             OR r.ReferenceNo LIKE '%' + @SearchTerm + '%'
                             OR r.Notes       LIKE '%' + @SearchTerm + '%'
                             OR r.EntryType   LIKE '%' + @SearchTerm + '%');

    /* 2. line - nayi sabse upar */
    SELECT r.Id, r.EntryDateTime, r.EntryType, r.Amount,
           ReferenceNo = ISNULL(r.ReferenceNo, N''), Notes = ISNULL(r.Notes, N''),
           PaymentMode = ISNULL(r.PaymentMode, N''), r.SignedAmount, r.RunningBalance
    FROM @Rows r
    WHERE @SearchTerm IS NULL
       OR r.ReferenceNo LIKE '%' + @SearchTerm + '%'
       OR r.Notes       LIKE '%' + @SearchTerm + '%'
       OR r.EntryType   LIKE '%' + @SearchTerm + '%'
    ORDER BY r.Seq DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END
GO
PRINT '  + AF5: sp_PartyLedger_Statement (chalta hua baki + purana baki)';
GO

/* ---------- AF6: jaanch (pehle Section H me H6 thi) ----------
   Kuch na dikhe = sab theek. Jo party dikhe uska record khaate se alag ho gaya
   hai; Action wala SP ab use bina purana baki mitaye theek karta hai. */
SELECT TOP 50
    Problem        = 'Party ka baki (purana baki + khaata) se match nahi karta',
    PartyId        = p.Id,
    PartyName      = p.PartyName,
    StoredBalance  = p.CurrentBalance,
    OpeningBalance = p.OpeningBalance,
    LedgerNet      = PUMP.fn_PartyLedgerNet(p.Id),
    Difference     = p.CurrentBalance - (p.OpeningBalance + PUMP.fn_PartyLedgerNet(p.Id)),
    Action         = 'EXEC PUMP.sp_Party_RecalculateBalance @OwnerId = <owner>'
FROM PUMP.Parties p
WHERE ABS(p.CurrentBalance - (p.OpeningBalance + PUMP.fn_PartyLedgerNet(p.Id))) > 0.01;
GO
PRINT '=== Section AF done ===';
GO

/* ==========================================================================================
   SECTION AG — Hatayi hui party list aur dropdown me na aaye (2026-10-14)
   ------------------------------------------------------------------------------------------
   sp_Party_Delete jis party ka len-den ho chuka hai use mitata nahi, chhupata hai
   (IsDeleted = 1). Par sp_Party_List me IsDeleted ka filter tha hi nahi: "hatayi" hui
   party Parties ki list me bhi dikhti rahi aur har dropdown me bhi (live par
   do aisi party). Dropdown pehli 100 party laata tha, to ye do
   hatayi hui party do asli party ki jagah gher rahi thi.

   Result ka aakaar wahi hai (11 column + ginti) - purani API/Client waise hi chalte hain.
   sp_Party_GetById ko nahi chhua: purane bill / khaate me hatayi hui party ka naam
   ab bhi khulna chahiye.
   ========================================================================================== */
PRINT '=== Section AG: hatayi hui party list me nahi ===';
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Party_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @SearchTerm NVARCHAR(255) = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 20
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        Id,
        PumpId,
        PartyName,
        PartyType,
        ISNULL(Address, '') AS Address,
        ISNULL(Mobile, '') AS Mobile,
        ISNULL(Email, '') AS Email,
        ISNULL(GSTIN, '') AS GSTIN,
        CreditLimit,
        CurrentBalance,
        IsActive
    FROM PUMP.Parties
    WHERE OwnerId = @OwnerId
      AND PumpId = @PumpId
      AND ISNULL(IsDeleted, 0) = 0
      AND (@SearchTerm IS NULL OR PartyName LIKE '%' + @SearchTerm + '%' OR Mobile LIKE '%' + @SearchTerm + '%')
    ORDER BY PartyName, Id          -- Id: ek hi naam ki do party ho to page-dar-page kram na badle
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(1)
    FROM PUMP.Parties
    WHERE OwnerId = @OwnerId
      AND PumpId = @PumpId
      AND ISNULL(IsDeleted, 0) = 0
      AND (@SearchTerm IS NULL OR PartyName LIKE '%' + @SearchTerm + '%' OR Mobile LIKE '%' + @SearchTerm + '%');
END
GO
PRINT '  + AG1: sp_Party_List - IsDeleted = 0, aur page ka kram pakka';
PRINT '=== Section AG done ===';
GO

/* ==========================================================================================
   SECTION AH — "Purana baki" wahi dikhe jo owner ne BHARA tha, us din ka (2026-10-14)
   ------------------------------------------------------------------------------------------
   Owner: "purana wala jo 13 log ka baki tha wo to 0 kar diya tha, wo to nahi jud raha?"

   Live par 10 party September me bani thi aur 1-3 Sep ke udhaar (COLL-6/7/8) unke
   khaate me pade hain. 9-10 Oct ko owner ne un sab ka baki form se DOBARA bhara
   (rajistar se) - yaani purana hisaab chhod kar naya shuru kiya.

   Baki (CurrentBalance) us din se sahi hai: jo bhara + uske baad ki entry. Par Section AF
   ka khaata use aise dikhata:
        Ek purani party:  purana baki 1,10,949 + udhaar 28,900 = 1,39,849
   1,10,949 owner ne kabhi bhara hi nahi (usne 1,20,149 bhara tha), aur 28,900 me
   September ke 9,200 bhi hain jinhe wo "0 kar chuka" hai. Jod sahi, par padhne me
   lagta hai ki purana udhaar DOBARA jud raha hai.

   ILAAJ - sirf DIKHANE ka: Parties.OpeningAsOf = baki aakhri baar HAATH se kab bhara gaya.
        dikhne wala purana baki = OpeningBalance + us pal se PEHLE bani line
        list me sirf us pal ke BAAD bani line
        Ek purani party:  purana baki 1,20,149 (10-Oct ko bhara) + udhaar 19,700 = 1,39,849

   RAKHA HUA HISAAB NAHI BADLA: CurrentBalance, OpeningBalance aur niyam
   (baki = OpeningBalance + SAARI line) wahi hain - Recount (AF4) aur jaanch (AF6) ko
   OpeningAsOf se koi matlab nahi. Isliye din ka collection dobara save ho (line mit kar
   nayi banti hain) to bhi hisaab nahi hilta; bas wo line "baad wali" ginne lagti hain
   aur dikhne wala purana baki utna hi kam ho jaata hai.

   "Pehle / baad" line ke CreatedOn se (software me kab chadhi), EntryDateTime se nahi:
   13 Oct ko chadhayi gayi 10 Oct ki jama ne baki 13 Oct ko badla tha.

     AH1  Parties.OpeningAsOf + EK BAAR ka backfill
     AH2  sp_Party_Save   - nayi party / haath se baki badla -> OpeningAsOf = abhi
     AH3  sp_PartyLedger_Statement - upar wala dikhava; sirnaam me 3 naye column
          (ye SP abhi kisi lagi hui API me nahi hai, isliye aakaar badalna surakshit)
   ========================================================================================== */
PRINT '=== Section AH: purana baki = jo bhara tha, us din ka ===';
GO

/* ---------- AH1 ----------
   Backfill ka niyam:
     * record kabhi badla hi nahi (UpdatedOn NULL)            -> party banne ka samay
     * UpdatedOn kisi line ke banne ke 5 second ke andar hai  -> wo badlav jama / udhaar ki
       entry ka tha (sp_PartyLedger_Save, sp_Sales_SaveHeader, sp_Sale_Void UpdatedOn
       likhte hain), haath se baki bharne ka nahi           -> party banne ka samay
     * warna                                                  -> UpdatedOn (form se save hua tha)
   Ghadi: CreatedOn ka default IST hai (getutcdate + 330). UpdatedOn SYSDATETIME() se
   likha jaata hai - live server IST par hai, isliye dono ek hi ghadi ke hain. */
IF COL_LENGTH('PUMP.Parties', 'OpeningAsOf') IS NULL
BEGIN
    ALTER TABLE PUMP.Parties ADD OpeningAsOf DATETIME2(7) NULL;

    EXEC (N'UPDATE p
            SET p.OpeningAsOf =
                CASE
                    WHEN p.UpdatedOn IS NULL THEN p.CreatedOn
                    WHEN EXISTS (SELECT 1 FROM PUMP.PartyLedger l
                                 WHERE l.PartyId = p.Id
                                   AND ABS(DATEDIFF(SECOND, l.CreatedOn, p.UpdatedOn)) <= 5) THEN p.CreatedOn
                    ELSE p.UpdatedOn
                END
            FROM PUMP.Parties p;');

    PRINT '  + AH1: Parties.OpeningAsOf bana aur bhar diya';
END
ELSE
    PRINT '  = AH1: Parties.OpeningAsOf pehle se hai (backfill dobara nahi)';
GO

/* ---------- AH2 ---------- */
CREATE OR ALTER PROCEDURE [PUMP].[sp_Party_Save]
(
    @Id BIGINT,
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @PartyName NVARCHAR(150),
    @PartyType NVARCHAR(50),
    @Address NVARCHAR(250),
    @Mobile NVARCHAR(20),
    @Email NVARCHAR(100),
    @GSTIN NVARCHAR(20),
    @CreditLimit DECIMAL(18,2),
    @CurrentBalance DECIMAL(18,2),
    @IsActive BIT,
    /* Naya client ye 1 bhejta hai jab user ne baki ka khaana chhua hi nahi.
       Purana client ise nahi bhejta (0) - tab pehle jaisa vyavhaar. */
    @KeepBalance BIT = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    /* PartyLedger.CreatedOn ka default yahi hai - "pehle / baad" isi ghadi se napta hai. */
    DECLARE @Now DATETIME2(7) = DATEADD(MINUTE, 330, GETUTCDATE());

    IF @Id = 0
    BEGIN
        /* Nayi party: form ka baki hi uska PURANA BAKI hai, aaj ka. */
        INSERT INTO PUMP.Parties
            (OwnerId, PumpId, PartyName, PartyType, Address, Mobile, Email, GSTIN,
             CreditLimit, CurrentBalance, OpeningBalance, OpeningAsOf, IsActive)
        VALUES
            (@OwnerId, @PumpId, @PartyName, @PartyType, @Address, @Mobile, @Email, @GSTIN,
             @CreditLimit, @CurrentBalance, @CurrentBalance, @Now, @IsActive);
    END
    ELSE
    BEGIN
        /* Edit: form ka khaana "abhi ka baki" hai. Use badla gaya ho to:
             * farak OpeningBalance me jaata hai (khaate ki line waise ki waisi) - isse
               niyam (baki = OpeningBalance + saari line) kabhi nahi toot-ta, aur
               "dobara gino" is sudhaar ko mitata nahi;
             * OpeningAsOf = abhi - haath se bhara hua baki ek NAYI SHURUAAT hai, isse
               pehle ki line usi me shaamil maani jaati hain (AH3 unhe alag nahi jodta).

           Ek hi UPDATE me: daayin taraf ke CurrentBalance / OpeningBalance / OpeningAsOf
           UPDATE se PEHLE ki value hain. */
        UPDATE PUMP.Parties
        SET PartyName      = @PartyName,
            PartyType      = @PartyType,
            Address        = @Address,
            Mobile         = @Mobile,
            Email          = @Email,
            GSTIN          = @GSTIN,
            CreditLimit    = @CreditLimit,
            OpeningBalance = CASE WHEN @KeepBalance = 1 THEN OpeningBalance
                                  ELSE OpeningBalance + (@CurrentBalance - CurrentBalance) END,
            OpeningAsOf    = CASE WHEN @KeepBalance = 1 OR @CurrentBalance = CurrentBalance THEN OpeningAsOf
                                  ELSE @Now END,
            CurrentBalance = CASE WHEN @KeepBalance = 1 THEN CurrentBalance ELSE @CurrentBalance END,
            IsActive       = @IsActive,
            UpdatedOn      = SYSDATETIME()
        WHERE Id = @Id
          AND OwnerId = @OwnerId
          AND PumpId = @PumpId;
    END
END
GO
PRINT '  + AH2: sp_Party_Save - haath se bhara baki = nayi shuruaat (OpeningAsOf)';
GO

/* ---------- AH3 ---------- */
CREATE OR ALTER PROCEDURE PUMP.sp_PartyLedger_Statement
(
    @OwnerId    BIGINT,
    @PumpId     BIGINT,
    @PartyId    BIGINT,
    @SearchTerm NVARCHAR(100) = NULL,
    @PageNumber INT = 1,
    @PageSize   INT = 50
)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISNULL(@PageNumber, 0) < 1 SET @PageNumber = 1;
    IF ISNULL(@PageSize, 0)   < 1 SET @PageSize = 50;
    IF LTRIM(RTRIM(ISNULL(@SearchTerm, N''))) = N'' SET @SearchTerm = NULL;

    DECLARE @Opening DECIMAL(18,2), @Current DECIMAL(18,2), @Name NVARCHAR(150), @AsOf DATETIME2(7);
    SELECT @Opening = OpeningBalance, @Current = CurrentBalance, @Name = PartyName, @AsOf = OpeningAsOf
    FROM PUMP.Parties
    WHERE Id = @PartyId AND OwnerId = @OwnerId AND PumpId = @PumpId;

    /* Baki haath se bharne se PEHLE bani line: bhare hue baki me shaamil, alag nahi judti. */
    DECLARE @EarlierCount INT = 0, @EarlierNet DECIMAL(18,2) = 0;
    IF @Name IS NOT NULL AND @AsOf IS NOT NULL
        SELECT @EarlierCount = COUNT(*),
               @EarlierNet   = ISNULL(SUM(PUMP.fn_PartyLedgerSigned(l.EntryType, l.Amount)), 0)
        FROM PUMP.PartyLedger l
        WHERE l.PartyId = @PartyId AND l.CreatedOn < @AsOf;

    /* Dikhne wala purana baki = jo us din bhara gaya tha. */
    DECLARE @Shown DECIMAL(18,2) = ISNULL(@Opening, 0) + @EarlierNet;

    /* Doosre owner / pump ki party: khaali, par usi aakaar ka (positional DTO). */
    DECLARE @Rows TABLE
    (
        Seq INT PRIMARY KEY, Id BIGINT, EntryDateTime DATETIME2(7), EntryType NVARCHAR(30),
        Amount DECIMAL(18,2), ReferenceNo NVARCHAR(50), Notes NVARCHAR(250),
        PaymentMode NVARCHAR(30), SignedAmount DECIMAL(18,2), RunningBalance DECIMAL(18,2)
    );

    IF @Name IS NOT NULL
    BEGIN
        ;WITH e AS
        (
            SELECT l.Id, l.EntryDateTime, l.EntryType, l.Amount, l.ReferenceNo, l.Notes, l.PaymentMode,
                   Signed = PUMP.fn_PartyLedgerSigned(l.EntryType, l.Amount)
            FROM PUMP.PartyLedger l
            WHERE l.PartyId = @PartyId
              AND (@AsOf IS NULL OR l.CreatedOn >= @AsOf)
        )
        INSERT INTO @Rows (Seq, Id, EntryDateTime, EntryType, Amount, ReferenceNo, Notes,
                           PaymentMode, SignedAmount, RunningBalance)
        SELECT ROW_NUMBER() OVER (ORDER BY EntryDateTime, Id),
               Id, EntryDateTime, EntryType, Amount, ReferenceNo, Notes, PaymentMode, Signed,
               /* Chalta hua baki SAARI line par (tareekh ke kram me) - sirf dikh rahe
                  page ya khoj ke nateeje par nahi. */
               @Shown + SUM(Signed) OVER (ORDER BY EntryDateTime, Id ROWS UNBOUNDED PRECEDING)
        FROM e;
    END

    /* 1. sirnaam:  purana baki + udhaar - jama = baki */
    SELECT
        PartyId        = @PartyId,
        PartyName      = ISNULL(@Name, N''),
        OpeningBalance = @Shown,
        TotalDebit     = ISNULL((SELECT SUM(SignedAmount)  FROM @Rows WHERE SignedAmount > 0), 0),
        TotalCredit    = ISNULL((SELECT SUM(-SignedAmount) FROM @Rows WHERE SignedAmount < 0), 0),
        CurrentBalance = ISNULL(@Current, 0),
        /* Purana baki + khaata. CurrentBalance se alag ho to record bigda hai -
           Support Console ka "Recount" use theek karta hai. */
        LedgerBalance  = @Shown + ISNULL((SELECT SUM(SignedAmount) FROM @Rows), 0),
        TotalCount     = (SELECT COUNT(*) FROM @Rows r
                          WHERE @SearchTerm IS NULL
                             OR r.ReferenceNo LIKE '%' + @SearchTerm + '%'
                             OR r.Notes       LIKE '%' + @SearchTerm + '%'
                             OR r.EntryType   LIKE '%' + @SearchTerm + '%'),
        OpeningAsOf    = @AsOf,
        EarlierCount   = @EarlierCount,
        EarlierNet     = @EarlierNet;

    /* 2. line - nayi sabse upar */
    SELECT r.Id, r.EntryDateTime, r.EntryType, r.Amount,
           ReferenceNo = ISNULL(r.ReferenceNo, N''), Notes = ISNULL(r.Notes, N''),
           PaymentMode = ISNULL(r.PaymentMode, N''), r.SignedAmount, r.RunningBalance
    FROM @Rows r
    WHERE @SearchTerm IS NULL
       OR r.ReferenceNo LIKE '%' + @SearchTerm + '%'
       OR r.Notes       LIKE '%' + @SearchTerm + '%'
       OR r.EntryType   LIKE '%' + @SearchTerm + '%'
    ORDER BY r.Seq DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END
GO
PRINT '  + AH3: sp_PartyLedger_Statement - purana baki us din ka jab bhara gaya';
PRINT '=== Section AH done ===';
GO

/* ==========================================================================================
   SECTION AI — Khaate ki galat entry badalna / hatana (2026-10-14)
   ------------------------------------------------------------------------------------------
   Owner: "Party Ledger form pe edit wala nahi hai — kisi ka galat jama ho gaya ya galat
   date me jama ho gaya tab?"

   Ab tak sirf ulti "adjustment" entry daal kar sudhaar hota tha: khaate me teen line
   (galat, ulti, sahi) aur party ko statement dikhao to samjhana padta.

   KAUN SI ENTRY BADAL SAKTI HAI — sirf jo Party Ledger form se haath se bani:
       ShiftId NULL  +  RECEIPT / SALE / DEBIT / CREDIT  +  system ka nishaan nahi.
   Baaki NAHI badalti, kyunki unka jod kahin aur bhi pada hai:
     * COLL-...        din ke collection se (SalesHeaders me bhi wahi udhaar; collection
                       dobara save karne par ye line mit kar nayi banti hai)
     * "Auto from sale #" / VOID-SALE-...   Sales screen ke bill aur unka radd hona
     * ShiftId wali     shift ke cash hisaab (sp_Shift_CashSummary, sp_Shift_Close) me gini
                       jaati hai — badalne se band shift ka cash badal jaata
   Party Ledger form ShiftId bhejta hi nahi, isliye haath ki saari entry pehli shart me aati hain.

   PAISE KA NIYAM wahi (Section AF): baki = OpeningBalance + saari line. Line badli to baki
   utna hi badalta hai, OpeningBalance nahi. Line ka CreatedOn nahi chhuta, isliye AH ka
   "purana baki kab bhara" wala hisaab bhi waisa hi rehta hai.

   HATANA: sach me DELETE (PartyLedger me IsDeleted nahi hai — jodna padta to use padhne wale
   har SP me filter lagana padta). Puraani poori line AuditLog me JSON ban kar rehti hai, saath
   me "kisne, kab, kyun". Wajah dono kaam me ZAROORI.

     AI1  fn_PartyLedgerIsManual   - upar wala niyam, EK jagah
     AI2  sp_PartyLedger_Update
     AI3  sp_PartyLedger_Delete
     AI4  sp_PartyLedger_Statement - har line ke saath CanEdit (screen par button usi se)
   ========================================================================================== */
PRINT '=== Section AI: khaate ki entry badalna / hatana ===';
GO

/* ---------- AI1 ---------- */
CREATE OR ALTER FUNCTION PUMP.fn_PartyLedgerIsManual
(
    @ShiftId     BIGINT,
    @EntryType   NVARCHAR(30),
    @ReferenceNo NVARCHAR(50),
    @Notes       NVARCHAR(250)
)
RETURNS BIT
AS
BEGIN
    RETURN CASE
               WHEN @ShiftId IS NOT NULL                                   THEN 0
               WHEN UPPER(ISNULL(@EntryType, N'')) NOT IN (N'RECEIPT', N'SALE', N'DEBIT', N'CREDIT') THEN 0
               WHEN ISNULL(@ReferenceNo, N'') LIKE N'COLL-%'               THEN 0
               WHEN ISNULL(@ReferenceNo, N'') LIKE N'VOID-SALE-%'          THEN 0
               WHEN ISNULL(@Notes, N'') LIKE N'Auto from sale #%'          THEN 0
               ELSE 1
           END;
END
GO
PRINT '  + AI1: fn_PartyLedgerIsManual';
GO

/* ---------- AI2 ---------- */
CREATE OR ALTER PROCEDURE PUMP.sp_PartyLedger_Update
(
    @Id            BIGINT,
    @OwnerId       BIGINT,
    @PumpId        BIGINT,
    @EntryType     NVARCHAR(30),
    @Amount        DECIMAL(18,2),
    @EntryDateTime DATETIME2(7)  = NULL,   -- NULL = tareekh waisi hi
    @ReferenceNo   NVARCHAR(50)  = NULL,
    @Notes         NVARCHAR(250) = NULL,
    @UserId        BIGINT        = NULL,
    @Reason        NVARCHAR(500) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @PartyId BIGINT, @ShiftId BIGINT, @OldType NVARCHAR(30), @OldAmount DECIMAL(18,2),
            @OldDate DATETIME2(7), @OldRef NVARCHAR(50), @OldNotes NVARCHAR(250);

    SELECT @PartyId = PartyId, @ShiftId = ShiftId, @OldType = EntryType, @OldAmount = Amount,
           @OldDate = EntryDateTime, @OldRef = ReferenceNo, @OldNotes = Notes
    FROM PUMP.PartyLedger
    WHERE Id = @Id AND OwnerId = @OwnerId AND PumpId = @PumpId;

    IF @PartyId IS NULL
        THROW 50290, 'Ledger entry not found, or you do not have access to it.', 1;
    IF PUMP.fn_PartyLedgerIsManual(@ShiftId, @OldType, @OldRef, @OldNotes) = 0
        THROW 50291, 'This entry came from a day collection or a sale bill. Change it there, not here.', 1;
    IF ISNULL(@Amount, 0) <= 0
        THROW 50292, 'Amount must be more than zero.', 1;
    SET @EntryType = UPPER(LTRIM(RTRIM(ISNULL(@EntryType, N''))));
    IF @EntryType NOT IN (N'RECEIPT', N'SALE', N'DEBIT', N'CREDIT')
        THROW 50293, 'Please pick a valid entry type.', 1;
    IF LTRIM(RTRIM(ISNULL(@Reason, N''))) = N''
        THROW 50294, 'Please write why this entry is being changed.', 1;

    DECLARE @OldSigned DECIMAL(18,2) = PUMP.fn_PartyLedgerSigned(@OldType, @OldAmount);
    DECLARE @NewSigned DECIMAL(18,2) = PUMP.fn_PartyLedgerSigned(@EntryType, @Amount);
    DECLARE @NewDate   DATETIME2(7)  = ISNULL(@EntryDateTime, @OldDate);

    BEGIN TRANSACTION;

        UPDATE PUMP.PartyLedger
        SET EntryType     = @EntryType,
            Amount        = @Amount,
            EntryDateTime = @NewDate,
            ReferenceNo   = NULLIF(LTRIM(RTRIM(ISNULL(@ReferenceNo, N''))), N''),
            Notes         = NULLIF(LTRIM(RTRIM(ISNULL(@Notes, N''))), N''),
            ModifiedBy    = @UserId,
            ModifiedOn    = SYSDATETIME()
        WHERE Id = @Id AND OwnerId = @OwnerId;

        /* Baki utna hi badle jitna line ka asar badla. OpeningBalance nahi chhuta. */
        UPDATE PUMP.Parties
        SET CurrentBalance = CurrentBalance + (@NewSigned - @OldSigned),
            UpdatedOn      = SYSDATETIME(),
            ModifiedBy     = @UserId
        WHERE Id = @PartyId AND OwnerId = @OwnerId;

        DECLARE @OldJson NVARCHAR(MAX) = (SELECT PartyId = @PartyId, EntryType = @OldType, Amount = @OldAmount,
                                                 EntryDateTime = @OldDate, ReferenceNo = @OldRef, Notes = @OldNotes
                                          FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @NewJson NVARCHAR(MAX) = (SELECT PartyId = @PartyId, EntryType = @EntryType, Amount = @Amount,
                                                 EntryDateTime = @NewDate, ReferenceNo = @ReferenceNo, Notes = @Notes
                                          FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC PUMP.sp_Audit_Log @OwnerId = @OwnerId, @PumpId = @PumpId, @UserId = @UserId,
             @EntityName = 'PartyLedger', @EntityId = @Id, @Action = 'UPDATE',
             @OldValues = @OldJson, @NewValues = @NewJson, @Reason = @Reason;

    COMMIT TRANSACTION;

    SELECT Id = @Id, PartyId = @PartyId, BalanceChange = @NewSigned - @OldSigned;
END
GO
PRINT '  + AI2: sp_PartyLedger_Update';
GO

/* ---------- AI3 ---------- */
CREATE OR ALTER PROCEDURE PUMP.sp_PartyLedger_Delete
(
    @Id      BIGINT,
    @OwnerId BIGINT,
    @PumpId  BIGINT,
    @UserId  BIGINT        = NULL,
    @Reason  NVARCHAR(500) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @PartyId BIGINT, @ShiftId BIGINT, @OldType NVARCHAR(30), @OldAmount DECIMAL(18,2),
            @OldDate DATETIME2(7), @OldRef NVARCHAR(50), @OldNotes NVARCHAR(250), @OldCreated DATETIME2(7);

    SELECT @PartyId = PartyId, @ShiftId = ShiftId, @OldType = EntryType, @OldAmount = Amount,
           @OldDate = EntryDateTime, @OldRef = ReferenceNo, @OldNotes = Notes, @OldCreated = CreatedOn
    FROM PUMP.PartyLedger
    WHERE Id = @Id AND OwnerId = @OwnerId AND PumpId = @PumpId;

    IF @PartyId IS NULL
        THROW 50290, 'Ledger entry not found, or you do not have access to it.', 1;
    IF PUMP.fn_PartyLedgerIsManual(@ShiftId, @OldType, @OldRef, @OldNotes) = 0
        THROW 50291, 'This entry came from a day collection or a sale bill. Change it there, not here.', 1;
    IF LTRIM(RTRIM(ISNULL(@Reason, N''))) = N''
        THROW 50294, 'Please write why this entry is being deleted.', 1;

    DECLARE @OldSigned DECIMAL(18,2) = PUMP.fn_PartyLedgerSigned(@OldType, @OldAmount);

    BEGIN TRANSACTION;

        /* Line jaate hi uska asar bhi jaaye. */
        UPDATE PUMP.Parties
        SET CurrentBalance = CurrentBalance - @OldSigned,
            UpdatedOn      = SYSDATETIME(),
            ModifiedBy     = @UserId
        WHERE Id = @PartyId AND OwnerId = @OwnerId;

        DELETE FROM PUMP.PartyLedger WHERE Id = @Id AND OwnerId = @OwnerId;

        DECLARE @OldJson NVARCHAR(MAX) = (SELECT PartyId = @PartyId, EntryType = @OldType, Amount = @OldAmount,
                                                 EntryDateTime = @OldDate, ReferenceNo = @OldRef, Notes = @OldNotes,
                                                 CreatedOn = @OldCreated
                                          FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC PUMP.sp_Audit_Log @OwnerId = @OwnerId, @PumpId = @PumpId, @UserId = @UserId,
             @EntityName = 'PartyLedger', @EntityId = @Id, @Action = 'DELETE',
             @OldValues = @OldJson, @Reason = @Reason;

    COMMIT TRANSACTION;

    SELECT Id = @Id, PartyId = @PartyId, BalanceChange = -@OldSigned;
END
GO
PRINT '  + AI3: sp_PartyLedger_Delete';
GO

/* ---------- AI4: AH3 jaisa hi, bas har line ke ant me CanEdit ---------- */
CREATE OR ALTER PROCEDURE PUMP.sp_PartyLedger_Statement
(
    @OwnerId    BIGINT,
    @PumpId     BIGINT,
    @PartyId    BIGINT,
    @SearchTerm NVARCHAR(100) = NULL,
    @PageNumber INT = 1,
    @PageSize   INT = 50
)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISNULL(@PageNumber, 0) < 1 SET @PageNumber = 1;
    IF ISNULL(@PageSize, 0)   < 1 SET @PageSize = 50;
    IF LTRIM(RTRIM(ISNULL(@SearchTerm, N''))) = N'' SET @SearchTerm = NULL;

    DECLARE @Opening DECIMAL(18,2), @Current DECIMAL(18,2), @Name NVARCHAR(150), @AsOf DATETIME2(7);
    SELECT @Opening = OpeningBalance, @Current = CurrentBalance, @Name = PartyName, @AsOf = OpeningAsOf
    FROM PUMP.Parties
    WHERE Id = @PartyId AND OwnerId = @OwnerId AND PumpId = @PumpId;

    /* Baki haath se bharne se PEHLE bani line: bhare hue baki me shaamil, alag nahi judti. */
    DECLARE @EarlierCount INT = 0, @EarlierNet DECIMAL(18,2) = 0;
    IF @Name IS NOT NULL AND @AsOf IS NOT NULL
        SELECT @EarlierCount = COUNT(*),
               @EarlierNet   = ISNULL(SUM(PUMP.fn_PartyLedgerSigned(l.EntryType, l.Amount)), 0)
        FROM PUMP.PartyLedger l
        WHERE l.PartyId = @PartyId AND l.CreatedOn < @AsOf;

    DECLARE @Shown DECIMAL(18,2) = ISNULL(@Opening, 0) + @EarlierNet;

    DECLARE @Rows TABLE
    (
        Seq INT PRIMARY KEY, Id BIGINT, EntryDateTime DATETIME2(7), EntryType NVARCHAR(30),
        Amount DECIMAL(18,2), ReferenceNo NVARCHAR(50), Notes NVARCHAR(250),
        PaymentMode NVARCHAR(30), SignedAmount DECIMAL(18,2), RunningBalance DECIMAL(18,2),
        CanEdit BIT
    );

    IF @Name IS NOT NULL
    BEGIN
        ;WITH e AS
        (
            SELECT l.Id, l.EntryDateTime, l.EntryType, l.Amount, l.ReferenceNo, l.Notes, l.PaymentMode,
                   Signed  = PUMP.fn_PartyLedgerSigned(l.EntryType, l.Amount),
                   CanEdit = PUMP.fn_PartyLedgerIsManual(l.ShiftId, l.EntryType, l.ReferenceNo, l.Notes)
            FROM PUMP.PartyLedger l
            WHERE l.PartyId = @PartyId
              AND (@AsOf IS NULL OR l.CreatedOn >= @AsOf)
        )
        INSERT INTO @Rows (Seq, Id, EntryDateTime, EntryType, Amount, ReferenceNo, Notes,
                           PaymentMode, SignedAmount, RunningBalance, CanEdit)
        SELECT ROW_NUMBER() OVER (ORDER BY EntryDateTime, Id),
               Id, EntryDateTime, EntryType, Amount, ReferenceNo, Notes, PaymentMode, Signed,
               @Shown + SUM(Signed) OVER (ORDER BY EntryDateTime, Id ROWS UNBOUNDED PRECEDING),
               CanEdit
        FROM e;
    END

    SELECT
        PartyId        = @PartyId,
        PartyName      = ISNULL(@Name, N''),
        OpeningBalance = @Shown,
        TotalDebit     = ISNULL((SELECT SUM(SignedAmount)  FROM @Rows WHERE SignedAmount > 0), 0),
        TotalCredit    = ISNULL((SELECT SUM(-SignedAmount) FROM @Rows WHERE SignedAmount < 0), 0),
        CurrentBalance = ISNULL(@Current, 0),
        LedgerBalance  = @Shown + ISNULL((SELECT SUM(SignedAmount) FROM @Rows), 0),
        TotalCount     = (SELECT COUNT(*) FROM @Rows r
                          WHERE @SearchTerm IS NULL
                             OR r.ReferenceNo LIKE '%' + @SearchTerm + '%'
                             OR r.Notes       LIKE '%' + @SearchTerm + '%'
                             OR r.EntryType   LIKE '%' + @SearchTerm + '%'),
        OpeningAsOf    = @AsOf,
        EarlierCount   = @EarlierCount,
        EarlierNet     = @EarlierNet;

    SELECT r.Id, r.EntryDateTime, r.EntryType, r.Amount,
           ReferenceNo = ISNULL(r.ReferenceNo, N''), Notes = ISNULL(r.Notes, N''),
           PaymentMode = ISNULL(r.PaymentMode, N''), r.SignedAmount, r.RunningBalance, r.CanEdit
    FROM @Rows r
    WHERE @SearchTerm IS NULL
       OR r.ReferenceNo LIKE '%' + @SearchTerm + '%'
       OR r.Notes       LIKE '%' + @SearchTerm + '%'
       OR r.EntryType   LIKE '%' + @SearchTerm + '%'
    ORDER BY r.Seq DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END
GO
PRINT '  + AI4: sp_PartyLedger_Statement - har line ke saath CanEdit';
PRINT '=== Section AI done ===';
GO

/* ==========================================================================================
   SECTION AJ — Hatayi hui cheez list me na aaye: tank, vendor, karmchari (2026-10-14)
   ------------------------------------------------------------------------------------------
   Section G8 ke delete SP jo cheez kahin istemaal ho chuki hai use mitate nahi, chhupate hain
   (IsDeleted = 1, IsActive = 0). G9 ne sirf "filter baaki hai" ki list chhaapi thi — filter
   kabhi laga hi nahi. Party me AG ne theek kiya; yahan baaki teen.

   Jinme ye kami NAHI thi: sp_Product_List, sp_Pump_List, sp_Nozzle_List pehle se
   `IsActive = 1` lagate hain, aur hatane par IsActive bhi 0 hota hai — wo pehle se chhupte the.
   (G9 / health check unhe bhi dikhata hai kyunki wo sirf "IsDeleted" shabd dhoondhta hai.)
   Roles me IsDeleted column hai par koi SP use 1 karta hi nahi.

   Yahan sirf IsDeleted ka filter — "band" (IsActive = 0) tank / vendor / karmchari list me
   rehte hain, taaki unhe dobara chalu kiya ja sake. Result ka aakaar wahi; purani API / Client
   waise hi chalte hain.

   Purane record (khareed bill ka tank / vendor, shift ka attendant) jo hatayi hui cheez ki
   taraf ishara karte hain: client un form me wahi value "(hataya hua)" likh kar chuni rakhta
   hai — warna bill kholne par vendor chupchaap pehle wale par, aur tank khaali ho jaata.
   ========================================================================================== */
PRINT '=== Section AJ: hatayi hui tank / vendor / karmchari list me nahi ===';
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Tank_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @SearchTerm NVARCHAR(255) = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 20
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        t.Id,
        t.PumpId,
        t.Name,
        t.ProductId,
        p.Name AS ProductName,
        p.Unit,
        t.Capacity,
        t.SafeFillLevel,
        t.CurrentStock,
        t.IsActive
    FROM PUMP.Tanks t
    INNER JOIN PUMP.Products p ON p.Id = t.ProductId
    WHERE t.OwnerId = @OwnerId
      AND t.PumpId = @PumpId
      AND ISNULL(t.IsDeleted, 0) = 0
      AND (@SearchTerm IS NULL OR t.Name LIKE '%' + @SearchTerm + '%')
    ORDER BY t.Name, t.Id
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(1)
    FROM PUMP.Tanks
    WHERE OwnerId = @OwnerId
      AND PumpId = @PumpId
      AND ISNULL(IsDeleted, 0) = 0
      AND (@SearchTerm IS NULL OR Name LIKE '%' + @SearchTerm + '%');
END
GO
PRINT '  + AJ1: sp_Tank_List';
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Vendor_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        Id,
        OwnerId,
        PumpId,
        VendorName,
        ContactNo,
        GSTIN,
        Address,
        IsActive
    FROM PUMP.Vendors
    WHERE OwnerId = @OwnerId
      AND PumpId = @PumpId
      AND ISNULL(IsDeleted, 0) = 0
    ORDER BY VendorName, Id;
END
GO
PRINT '  + AJ2: sp_Vendor_List';
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Employee_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        e.Id,
        e.OwnerId,
        e.PumpId,
        e.UserId,
        e.EmployeeCode,
        e.FullName,
        e.Mobile,
        e.JoinDate,
        e.Designation,
        e.MonthlySalary,
        e.IsActive,
        u.Username AS UserName
    FROM PUMP.Employees e
    LEFT JOIN PUMP.Users u ON u.Id = e.UserId
    WHERE e.OwnerId = @OwnerId
      AND e.PumpId = @PumpId
      AND ISNULL(e.IsDeleted, 0) = 0
    ORDER BY e.FullName, e.Id;
END
GO
PRINT '  + AJ3: sp_Employee_List';
PRINT '=== Section AJ done ===';
GO


/* ==========================================================================================
   SECTION AK — Udhaar ki parchi: gaadi number aur note ke saath (2026-10-22)
   ------------------------------------------------------------------------------------------
   "Aaj ki shift" wali ek-screen entry (Operations/TodayShift) me in-charge har udhaar
   parchi alag likhta hai — party, gaadi number, rakam, aur chhota note (parchi no. /
   kitne litre). Section W ka collection ek party ka saara udhaar jod kar EK line banata
   tha, isliye ek party ki teen gaadiyan ek hi line me ghul jaati thi aur party ke hisaab
   me ye dikhta hi nahi tha ki kaunsi gaadi ne kitna liya.

   Ab:
     * har parchi ki apni SalesHeaders row (VehicleNo column pehle se tha, khaali padta tha)
       aur apni PartyLedger SALE line — party statement me gaadi number dikhta hai
     * note ke liye SalesHeaders.SlipNote (naya, NULL chal jaata hai)
     * BillNo: COLL-<shift>-CR-<party>-<kram>. UX_Sales_BillNo (OwnerId, PumpId, BillNo)
       unique hai, isliye kram zaroori hai — ek party ki do parchi ho sakti hain.

   Purana tareeka bhi chalta hai: JSON me VehicleNo / SlipNote na ho to NULL. Purane
   COLL-<shift>-CR-<party> rows jaisi ki taisi; collection dobara save hote hi naye
   format me ban jaati hain (save hamesha poora hata kar dobara banata hai).

   Paisa / stock par koi naya asar nahi: wahi rakam, wahi CREDIT mode, wahi ledger SALE.
   Party ka balance Section AF ke niyam se hi badalta hai (purana ghata, naya joda).
   ========================================================================================== */
PRINT '=== Section AK: udhaar parchi me gaadi number + note ===';
GO

IF COL_LENGTH('PUMP.SalesHeaders', 'SlipNote') IS NULL
    ALTER TABLE PUMP.SalesHeaders ADD SlipNote NVARCHAR(150) NULL;
GO
PRINT '  + AK1: SalesHeaders.SlipNote';
GO

/* ---- AK2: collection padho — har parchi alag, likhne ke kram me ---- */
CREATE OR ALTER PROCEDURE PUMP.sp_ShiftCollection_Get
(
    @ShiftId BIGINT,
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.ShiftHeaders WHERE Id = @ShiftId AND OwnerId = @OwnerId)
        THROW 50230, 'That shift was not found.', 1;

    /* Pehli row: UPI aur Card ka jod */
    SELECT
        UpiAmount  = ISNULL(SUM(CASE WHEN UPPER(PaymentMode) IN ('UPI','WALLET') THEN TotalAmount END), 0),
        CardAmount = ISNULL(SUM(CASE WHEN UPPER(PaymentMode) = 'CARD' THEN TotalAmount END), 0)
    FROM PUMP.SalesHeaders
    WHERE ShiftId = @ShiftId AND OwnerId = @OwnerId AND IsVoid = 0
      AND BillNo LIKE 'COLL-%';

    /* Doosri row-set: udhaar ki har parchi. Column ka kram C# ke
       ShiftCollectionCreditRow jaisa hi rakhna (CLAUDE.md niyam 5). */
    SELECT
        h.PartyId,
        PartyName = p.PartyName,
        Amount    = h.TotalAmount,
        h.VehicleNo,
        h.SlipNote
    FROM PUMP.SalesHeaders h
    JOIN PUMP.Parties p ON p.Id = h.PartyId
    WHERE h.ShiftId = @ShiftId AND h.OwnerId = @OwnerId AND h.IsVoid = 0
      AND h.BillNo LIKE 'COLL-%'
      AND UPPER(h.PaymentMode) = 'CREDIT'
    ORDER BY h.Id;
END
GO
PRINT '  + AK2: sp_ShiftCollection_Get (VehicleNo, SlipNote)';
GO

/* ---- AK3: collection save — har parchi ki apni row ---- */
CREATE OR ALTER PROCEDURE PUMP.sp_ShiftCollection_Save
(
    @ShiftId     BIGINT,
    @OwnerId     BIGINT,
    @UpiAmount   DECIMAL(18,2) = 0,
    @CardAmount  DECIMAL(18,2) = 0,
    @CreditJson  NVARCHAR(MAX) = NULL,   -- [{"PartyId":1,"Amount":300,"VehicleNo":"UP32AB1234","SlipNote":"20 L"}, ...]
    @UserId      BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @PumpId BIGINT, @ShiftDate DATE;

    SELECT @PumpId = PumpId, @ShiftDate = ShiftDate
    FROM PUMP.ShiftHeaders
    WHERE Id = @ShiftId AND OwnerId = @OwnerId;

    IF @PumpId IS NULL
        THROW 50230, 'That shift was not found.', 1;

    SET @UpiAmount  = ISNULL(@UpiAmount, 0);
    SET @CardAmount = ISNULL(@CardAmount, 0);

    IF @UpiAmount < 0 OR @CardAmount < 0
        THROW 50231, 'Amount cannot be negative.', 1;

    /* Parchi likhne ke kram me (Seq) — BillNo ka kram yahi se. */
    DECLARE @Credit TABLE
    (
        Seq       INT IDENTITY(1,1),
        PartyId   BIGINT,
        Amount    DECIMAL(18,2),
        VehicleNo NVARCHAR(30) NULL,
        SlipNote  NVARCHAR(150) NULL
    );

    IF @CreditJson IS NOT NULL AND ISJSON(@CreditJson) = 1
    BEGIN
        INSERT INTO @Credit (PartyId, Amount, VehicleNo, SlipNote)
        SELECT x.PartyId, x.Amount,
               NULLIF(LEFT(UPPER(LTRIM(RTRIM(x.VehicleNo))), 30), N''),
               NULLIF(LEFT(LTRIM(RTRIM(x.SlipNote)), 150), N'')
        FROM OPENJSON(@CreditJson) j
        CROSS APPLY OPENJSON(j.value)
        WITH (PartyId   BIGINT        '$.PartyId',
              Amount    DECIMAL(18,2) '$.Amount',
              VehicleNo NVARCHAR(100) '$.VehicleNo',
              SlipNote  NVARCHAR(400) '$.SlipNote') x
        WHERE ISNULL(x.PartyId, 0) > 0 AND ISNULL(x.Amount, 0) > 0
        ORDER BY CAST(j.[key] AS INT);

        /* Party usi owner ki honi chahiye. Doosre tenant ki party ki id daal kar
           uske khaate me entry na ho jaye. */
        IF EXISTS (SELECT 1 FROM @Credit c
                   WHERE NOT EXISTS (SELECT 1 FROM PUMP.Parties p
                                     WHERE p.Id = c.PartyId AND p.OwnerId = @OwnerId
                                       AND ISNULL(p.IsDeleted, 0) = 0))
            THROW 50232, 'One of the credit customers does not belong to your account.', 1;
    END

    DECLARE @Stamp DATETIME2(7) = DATEADD(HOUR, 20, CAST(@ShiftDate AS DATETIME2(7)));

    BEGIN TRANSACTION;

        /* Purani COLL- entry saaf — pehle purana udhaar party ke khaate se ghatao,
           warna dobara save karne par wahi udhaar do baar jud jaata (Section W). */
        UPDATE p
        SET p.CurrentBalance = ISNULL(p.CurrentBalance, 0) - old.Amount
        FROM PUMP.Parties p
        JOIN (
            SELECT PartyId, Amount = SUM(TotalAmount)
            FROM PUMP.SalesHeaders
            WHERE ShiftId = @ShiftId AND OwnerId = @OwnerId AND IsVoid = 0
              AND BillNo LIKE 'COLL-%' AND UPPER(PaymentMode) = 'CREDIT'
              AND PartyId IS NOT NULL
            GROUP BY PartyId
        ) old ON old.PartyId = p.Id;

        DELETE FROM PUMP.PartyLedger
        WHERE ShiftId = @ShiftId AND OwnerId = @OwnerId
          AND ReferenceNo LIKE 'COLL-%';

        DELETE FROM PUMP.SalesHeaders
        WHERE ShiftId = @ShiftId AND OwnerId = @OwnerId
          AND BillNo LIKE 'COLL-%';

        IF @UpiAmount > 0
            INSERT INTO PUMP.SalesHeaders
                (OwnerId, PumpId, ShiftId, PartyId, BillNo, BillDateTime, PaymentMode,
                 CustomerName, TotalAmount, IsVoid, IsInterState, CreatedBy)
            VALUES
                (@OwnerId, @PumpId, @ShiftId, NULL,
                 CONCAT('COLL-', @ShiftId, '-UPI'), @Stamp, 'UPI',
                 N'Online (day total)', @UpiAmount, 0, 0, @UserId);

        IF @CardAmount > 0
            INSERT INTO PUMP.SalesHeaders
                (OwnerId, PumpId, ShiftId, PartyId, BillNo, BillDateTime, PaymentMode,
                 CustomerName, TotalAmount, IsVoid, IsInterState, CreatedBy)
            VALUES
                (@OwnerId, @PumpId, @ShiftId, NULL,
                 CONCAT('COLL-', @ShiftId, '-CARD'), @Stamp, 'CARD',
                 N'Card (day total)', @CardAmount, 0, 0, @UserId);

        /* Udhaar — har parchi ki apni row, Seq ke kram me */
        INSERT INTO PUMP.SalesHeaders
            (OwnerId, PumpId, ShiftId, PartyId, BillNo, BillDateTime, PaymentMode,
             VehicleNo, CustomerName, TotalAmount, IsVoid, IsInterState, CreatedBy, SlipNote)
        SELECT
            @OwnerId, @PumpId, @ShiftId, c.PartyId,
            CONCAT('COLL-', @ShiftId, '-CR-', c.PartyId, '-', c.Seq), @Stamp, 'CREDIT',
            c.VehicleNo, p.PartyName, c.Amount, 0, 0, @UserId, c.SlipNote
        FROM @Credit c
        JOIN PUMP.Parties p ON p.Id = c.PartyId
        ORDER BY c.Seq;

        /* Party ka khaata — gaadi number aur note bhi, taaki party ke hisaab me
           dikhe ki kaunsi gaadi ne kitna liya. */
        INSERT INTO PUMP.PartyLedger
            (OwnerId, PumpId, PartyId, EntryType, Amount, EntryDateTime,
             ReferenceNo, Notes, ShiftId, PaymentMode, CreatedBy)
        SELECT
            @OwnerId, @PumpId, c.PartyId, 'SALE', c.Amount, @Stamp,
            CONCAT('COLL-', @ShiftId, '-CR-', c.PartyId, '-', c.Seq),
            CONCAT(N'Credit given during the shift',
                   N' · ' + c.VehicleNo,
                   N' · ' + c.SlipNote),
            @ShiftId, 'CREDIT', @UserId
        FROM @Credit c
        ORDER BY c.Seq;

        UPDATE p
        SET p.CurrentBalance = ISNULL(p.CurrentBalance, 0) + x.Amount
        FROM PUMP.Parties p
        JOIN (SELECT PartyId, Amount = SUM(Amount) FROM @Credit GROUP BY PartyId) x
          ON x.PartyId = p.Id;

    COMMIT TRANSACTION;

    SELECT Saved = 1;
END
GO
PRINT '  + AK3: sp_ShiftCollection_Save (har parchi alag)';
PRINT '=== Section AK done ===';
GO


/* ==========================================================================================
   SECTION AL — CNG (gas) ka stock tank se nahi chalta (2026-10-22)
   ------------------------------------------------------------------------------------------
   CNG ki asli duniya: pipeline se gas aati hai, compressor se storage cylinder (cascade) me
   jaati hai, wahan se dispenser tak. Na tanker aata hai, na dip hoti hai, na testing. Hisaab
   gas company ke meter / bill se hota hai. Software tank maangta tha:
     * nozzle bina tank ke banta hi nahi tha - to nakli "CNG Storage" tank banana padta tha
     * us tank se har shift ki bikri ghat-ti thi, stock har din minus (test: -561 kg)
     * DSR me CNG "Stock not measured" aur minus closing
     * shift band karte waqt dip ka khaana

   Ab Products.TracksStock (computed): CNG aur ElectricCharging = 0, baaki sab 1. Computed
   isliye ki Category se hamesha mel khaaye - alag se bharna / bhoolna nahi padta, aur purana
   data bina backfill ke sahi ho jaata hai. TracksStock = 0 par:
     * sp_Nozzle_Save: tank zaroori nahi (aur product usi pump ka hona seedha jaancha jaata hai)
     * sp_Shift_Open / sp_Shift_Close: "nozzle ka tank nahi" wali jaanch gas ko chhodti hai, aur
       sp_Shift_Close tank se kuch ghatata nahi (purana tank bhi ho to wo jaisa tha waisa rehta hai)
     * sp_Shift_ClosingDipList: gas ka tank dip ki list me nahi
     * sp_Purchase_List: bill ki line me ikai ("CNG: 500 kg = Rs ..."; pehle har jagah "L" pakka tha)
     * sp_Receipt_Generate: naya aakhri column QuantityUnit ("kg" / "L", mili-juli ho to NULL) - raseed par
       "Volume (Ltr)" ki jagah sahi ikai. API ka ReceiptDto purane 17-column SP par bhi chalta hai.
     * sp_Shift_List: TotalSoldQty sirf tel (litre) - kg aur L ka jod bekaar tha (rupaye sab ke)
     * sp_Report_DailyStockRegister: stock ke khaane 0, remark "Stock not tracked (gas)"; bikri ki
       ginti / rate / rupee value pehle jaisi
   Gas ka KHAREED: sp_Purchase_SaveDetail bina tank ke pehle se chalta hai (tank na ho to stock
   par kuch nahi, bas bill darj) - isliye gas company ka bill ab bhi Purchase me likha ja sakta hai.

   Neeche ke SP main file ki aakhri (chalti hui) likhawat hain, sirf upar likhi lines badli hain.
   ========================================================================================== */
PRINT '=== Section AL: gas (CNG) ka stock tank se nahi ===';
GO

IF COL_LENGTH('PUMP.Products', 'TracksStock') IS NULL
    ALTER TABLE PUMP.Products ADD TracksStock AS
        (CASE WHEN Category IN (N'CNG', N'ElectricCharging') THEN CAST(0 AS BIT) ELSE CAST(1 AS BIT) END);
GO
PRINT '  + AL1: Products.TracksStock (CNG / ElectricCharging = 0)';
GO

CREATE OR ALTER PROCEDURE PUMP.sp_Nozzle_Save
(
    @Id BIGINT = NULL,
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @ProductId BIGINT,
    @NozzleCode NVARCHAR(30),
    @TankId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @TankId = 0 SET @TankId = NULL;

    /* Product usi pump ka ho. Pehle ye jaanch tank ke raste hoti thi; gas jaise product ka
       tank hota hi nahi, isliye ab seedhi jaanch. */
    IF NOT EXISTS (SELECT 1 FROM PUMP.Products
                   WHERE Id = @ProductId AND OwnerId = @OwnerId AND PumpId = @PumpId)
        THROW 50065, 'This product does not belong to this pump.', 1;

    DECLARE @TracksStock BIT =
        ISNULL((SELECT TracksStock FROM PUMP.Products WHERE Id = @ProductId), 1);

    /* Tank ke bina nozzle ka koi matlab nahi — bikne wala tel kisi tank se
       ghatna hi chahiye. Pehle ye NULL ho sakta tha aur galti shift kholte
       waqt pakadi jaati thi (THROW 50003), jo bahut der ho jaati hai. */
    IF @TankId IS NULL AND @TracksStock = 1
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM PUMP.Tanks
                       WHERE OwnerId = @OwnerId AND PumpId = @PumpId AND ProductId = @ProductId
                         AND IsActive = 1 AND ISNULL(IsDeleted, 0) = 0)
            THROW 50063, 'This product has no tank on this pump yet. Add the tank first, then create the nozzle.', 1;

        THROW 50064, 'Please pick the tank this nozzle draws from.', 1;
    END

    -- Tank usi pump/product ka hona chahiye, warna galat tank se deduct hone laga to.
    IF @TankId IS NOT NULL AND NOT EXISTS
    (
        SELECT 1 FROM PUMP.Tanks
        WHERE Id = @TankId AND OwnerId = @OwnerId AND PumpId = @PumpId AND ProductId = @ProductId
    )
        THROW 50062, 'The selected tank does not belong to this pump/product.', 1;

    IF @Id IS NULL OR @Id = 0
    BEGIN
        INSERT INTO PUMP.Nozzles (OwnerId, PumpId, ProductId, NozzleCode, TankId)
        VALUES (@OwnerId, @PumpId, @ProductId, @NozzleCode, @TankId);
    END
    ELSE
    BEGIN
        UPDATE PUMP.Nozzles
        SET ProductId = @ProductId,
            NozzleCode = @NozzleCode,
            TankId = @TankId
        WHERE Id = @Id
          AND OwnerId = @OwnerId
          AND PumpId = @PumpId;
    END

    SELECT COALESCE(@Id, CAST(SCOPE_IDENTITY() AS BIGINT)) AS Id;
END
GO
PRINT '  + AL2: sp_Nozzle_Save - gas ke liye tank zaroori nahi';
GO

CREATE OR ALTER PROCEDURE PUMP.sp_Shift_Open
(
    @OwnerId            BIGINT,
    @PumpId             BIGINT,
    @OperatorUserId     BIGINT = NULL,
    @ShiftDate          DATE,
    @ShiftCode          NVARCHAR(30),
    @OpeningCash        DECIMAL(18,2) = 0,
    @Notes              NVARCHAR(500) = NULL,
    @NozzleReadingsJson NVARCHAR(MAX) = NULL,
    @UserId             BIGINT = NULL,
    @OperatorEmployeeId BIGINT = NULL,
    /* Meter badla, rollover hua, ya user ne jaan-boojh kar farak maana —
       tab client ye 1 bhejta hai aur R1 wali rok hat jaati hai. */
    @AllowMeterGap      BIT    = 0
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF EXISTS (SELECT 1 FROM PUMP.ShiftHeaders
               WHERE OwnerId = @OwnerId AND PumpId = @PumpId AND Status = 'OPEN')
    BEGIN
        SELECT CAST(-1 AS BIGINT) AS Id;   -- pehle se ek shift khuli hai
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM PUMP.ShiftHeaders
               WHERE PumpId = @PumpId AND ShiftDate = @ShiftDate AND ShiftCode = @ShiftCode)
    BEGIN
        SELECT CAST(-3 AS BIGINT) AS Id;   -- isi din ka isi code ka shift already hai
        RETURN;
    END

    /* In-charge usi owner ka aur USI PUMP ka employee ho. */
    IF @OperatorEmployeeId IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM PUMP.Employees
        WHERE Id = @OperatorEmployeeId
          AND OwnerId = @OwnerId
          AND PumpId = @PumpId
          AND ISNULL(IsDeleted, 0) = 0)
        THROW 50153, 'Shift in-charge not found, or that employee does not belong to this pump.', 1;

    /* OperatorUserId ab employee ke record se aata hai — sach ek hi jagah rahe. */
    IF @OperatorEmployeeId IS NOT NULL
        SELECT @OperatorUserId = UserId FROM PUMP.Employees WHERE Id = @OperatorEmployeeId;

    DECLARE @ShiftId BIGINT;

    BEGIN TRANSACTION;

        INSERT INTO PUMP.ShiftHeaders
            (OwnerId, PumpId, OperatorUserId, OperatorEmployeeId, ShiftDate, ShiftCode, OpeningCash, Notes, OpenedOn, Status, CreatedBy)
        VALUES
            (@OwnerId, @PumpId, @OperatorUserId, @OperatorEmployeeId, @ShiftDate, @ShiftCode, @OpeningCash, @Notes, SYSDATETIME(), 'OPEN', @UserId);

        SET @ShiftId = CAST(SCOPE_IDENTITY() AS BIGINT);

        IF @NozzleReadingsJson IS NOT NULL AND ISJSON(@NozzleReadingsJson) = 1
        BEGIN
            INSERT INTO PUMP.ShiftNozzleReadings
                (OwnerId, PumpId, ShiftId, NozzleId, ProductId, OpeningReading, Rate,
                 EmployeeId, FloatGiven, CreatedBy)
            SELECT
                @OwnerId, @PumpId, @ShiftId,
                x.NozzleId,
                n.ProductId,                          -- nozzle master se lo, client se nahi
                ISNULL(x.OpeningReading, 0),
                /* Rate har nozzle ka apne product ka, aur US DIN ka. */
                PUMP.fn_ProductRateOnDate(n.ProductId,
                    DATEADD(HOUR, 23, CAST(@ShiftDate AS DATETIME2(7)))),

                /* Aadmi usi owner KA AUR USI PUMP ka ho. Na mile to NULL. */
                (SELECT e.Id FROM PUMP.Employees e
                 WHERE e.Id = x.EmployeeId
                   AND e.OwnerId = @OwnerId
                   AND e.PumpId  = @PumpId
                   AND ISNULL(e.IsDeleted, 0) = 0),

                ISNULL(x.FloatGiven, 0),
                @UserId
            FROM OPENJSON(@NozzleReadingsJson)
            WITH (NozzleId       BIGINT        '$.NozzleId',
                  OpeningReading DECIMAL(18,3) '$.OpeningReading',
                  EmployeeId     BIGINT        '$.EmployeeId',
                  FloatGiven     DECIMAL(18,2) '$.FloatGiven') x
            INNER JOIN PUMP.Nozzles  n ON n.Id = x.NozzleId
                                      AND n.PumpId = @PumpId
                                      AND n.OwnerId = @OwnerId
                                      AND n.IsActive = 1
                                      AND ISNULL(n.IsDeleted, 0) = 0
            INNER JOIN PUMP.Products p ON p.Id = n.ProductId
            WHERE ISNULL(x.NozzleId, 0) > 0;
        END

        IF NOT EXISTS (SELECT 1 FROM PUMP.ShiftNozzleReadings WHERE ShiftId = @ShiftId)
        BEGIN
            ROLLBACK TRANSACTION;
            THROW 50130, 'No nozzle could be added to this shift. Check that the nozzles belong to the selected pump and are active.', 1;
        END

        IF EXISTS
        (
            SELECT 1
            FROM PUMP.ShiftNozzleReadings snr
            JOIN PUMP.Nozzles n ON n.Id = snr.NozzleId
            WHERE snr.ShiftId = @ShiftId
              AND n.TankId IS NULL
              AND ISNULL((SELECT pr.TracksStock FROM PUMP.Products pr WHERE pr.Id = n.ProductId), 1) = 1
              AND (SELECT COUNT(*) FROM PUMP.Tanks t
                   WHERE t.PumpId = @PumpId AND t.ProductId = n.ProductId AND t.IsActive = 1) <> 1
        )
        BEGIN
            ROLLBACK TRANSACTION;
            THROW 50003, 'Some nozzles have no tank set (or the product has more than one tank). Pick a tank in the Nozzle master.', 1;
        END

        /* ---- R1: meter ki kadi ----
           Har nozzle ka opening us nozzle ki PICHLI shift ke closing se milna
           chahiye. "Pichli" tareekh se nikalte hain, Id se nahi — kyunki purani
           tareekh ki shift baad me bhi daali ja sakti hai. */
        IF @AllowMeterGap = 0
        BEGIN
            DECLARE @GapMsg NVARCHAR(1800);

            ;WITH chain AS
            (
                SELECT
                    n.NozzleCode,
                    snr.OpeningReading,
                    LastClosing =
                    (
                        SELECT TOP 1 r2.ClosingReading
                        FROM PUMP.ShiftNozzleReadings r2
                        JOIN PUMP.ShiftHeaders h2 ON h2.Id = r2.ShiftId
                        WHERE r2.NozzleId = snr.NozzleId
                          AND r2.ClosingReading IS NOT NULL
                          AND h2.Id <> @ShiftId
                          AND (h2.ShiftDate < @ShiftDate
                               OR (h2.ShiftDate = @ShiftDate AND h2.Id < @ShiftId))
                        ORDER BY h2.ShiftDate DESC, h2.Id DESC
                    )
                FROM PUMP.ShiftNozzleReadings snr
                JOIN PUMP.Nozzles n ON n.Id = snr.NozzleId
                WHERE snr.ShiftId = @ShiftId
            )
            SELECT @GapMsg = STRING_AGG(
                       CAST('Nozzle ' + NozzleCode
                          + ': last closing was ' + FORMAT(LastClosing, 'N3')
                          + ' but you entered ' + FORMAT(OpeningReading, 'N3')
                          + ' (' + FORMAT(OpeningReading - LastClosing, 'N3') + ' difference).'
                            AS NVARCHAR(MAX)), ' ')
            FROM chain
            WHERE LastClosing IS NOT NULL
              AND ABS(LastClosing - OpeningReading) > 0.001;

            IF @GapMsg IS NOT NULL
            BEGIN
                ROLLBACK TRANSACTION;
                SET @GapMsg = 'Meter reading does not continue from the last shift. ' + @GapMsg
                            + ' Correct the opening reading, or tick "Meter was changed - accept this difference" to continue.';
                THROW 50132, @GapMsg, 1;
            END
        END

    COMMIT TRANSACTION;

    SELECT @ShiftId AS Id;
END
GO
PRINT '  + AL3: sp_Shift_Open - gas tank-check se bahar';
GO

CREATE OR ALTER PROCEDURE PUMP.sp_Shift_Close
(
    @Id                 BIGINT,
    @ClosingCash        DECIMAL(18,2) = NULL,
    @Notes              NVARCHAR(500) = NULL,
    @NozzleReadingsJson NVARCHAR(MAX) = NULL,
    @UserId             BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @OwnerId BIGINT, @PumpId BIGINT, @Status NVARCHAR(30),
            @ShiftDate DATE, @OpeningCash DECIMAL(18,2), @WasClosed BIT = 0;

    SELECT TOP 1
        @OwnerId     = OwnerId,
        @PumpId      = PumpId,
        @Status      = Status,
        @ShiftDate   = ShiftDate,
        @OpeningCash = OpeningCash
    FROM PUMP.ShiftHeaders
    WHERE Id = @Id;

    IF @OwnerId IS NULL BEGIN SELECT CAST(-1 AS BIGINT) AS Id; RETURN; END
    IF ISNULL(@Status, '') NOT IN ('OPEN', 'CLOSED') BEGIN SELECT CAST(-2 AS BIGINT) AS Id; RETURN; END

    SET @WasClosed = CASE WHEN @Status = 'CLOSED' THEN 1 ELSE 0 END;

    /* FIX #4 — tank movement ki date shift ki date honi chahiye, aaj ki nahi.
       Aaj ki shift hai to asli time, warna us din ka 23:00. */
    DECLARE @TxnStamp DATETIME2(7) =
        CASE WHEN @ShiftDate = CAST(SYSDATETIME() AS DATE)
             THEN SYSDATETIME()
             ELSE DATEADD(HOUR, 23, CAST(CAST(@ShiftDate AS DATETIME2(7)) AS DATETIME2(7)))
        END;

    DECLARE @ShiftRef NVARCHAR(30) = CONCAT('SHIFT-', @Id);

    BEGIN TRY
        BEGIN TRANSACTION;

        /* ---------- 1. Readings update ---------- */
        IF @NozzleReadingsJson IS NOT NULL AND ISJSON(@NozzleReadingsJson) = 1
        BEGIN
            ;WITH cte AS
            (
                SELECT x.NozzleId, x.ClosingReading, ISNULL(x.TestingLoss, 0) AS TestingLoss
                FROM OPENJSON(@NozzleReadingsJson)
                WITH (NozzleId BIGINT '$.NozzleId',
                      ClosingReading DECIMAL(18,3) '$.ClosingReading',
                      TestingLoss DECIMAL(18,3) '$.TestingLoss') x
                WHERE ISNULL(x.NozzleId, 0) > 0
            )
            UPDATE snr
            SET snr.ClosingReading = cte.ClosingReading,
                snr.TestingLoss    = cte.TestingLoss,
                /* FIX #2 — meter rollover. Closing < Opening ka matlab totalizer
                   ghoom gaya hai, galti nahi. Nozzle ke MeterDigits se wapas jodo. */
                snr.IsRollover     = CASE WHEN cte.ClosingReading < snr.OpeningReading THEN 1 ELSE 0 END,
                snr.SoldQty        =
                    CASE
                        WHEN cte.ClosingReading >= snr.OpeningReading
                            THEN cte.ClosingReading - snr.OpeningReading
                        ELSE POWER(CAST(10 AS DECIMAL(18,3)), n.MeterDigits) - snr.OpeningReading + cte.ClosingReading
                    END
                    - cte.TestingLoss,
                snr.SoldAmount     =
                    (
                        CASE
                            WHEN cte.ClosingReading >= snr.OpeningReading
                                THEN cte.ClosingReading - snr.OpeningReading
                            ELSE POWER(CAST(10 AS DECIMAL(18,3)), n.MeterDigits) - snr.OpeningReading + cte.ClosingReading
                        END
                        - cte.TestingLoss
                    ) * snr.Rate,
                snr.UpdatedOn      = SYSDATETIME(),
                snr.ModifiedBy     = @UserId
            FROM PUMP.ShiftNozzleReadings snr
            INNER JOIN cte           ON cte.NozzleId = snr.NozzleId
            INNER JOIN PUMP.Nozzles n ON n.Id = snr.NozzleId
            WHERE snr.ShiftId = @Id;
        END

        /* ---------- 2. Validation ---------- */
        IF EXISTS (SELECT 1 FROM PUMP.ShiftNozzleReadings WHERE ShiftId = @Id AND ClosingReading IS NULL)
            THROW 50002, 'A closing reading is required for every nozzle.', 1;

        IF EXISTS (SELECT 1 FROM PUMP.ShiftNozzleReadings WHERE ShiftId = @Id AND SoldQty < 0)
            THROW 50004, 'Sold quantity is coming out negative. Check the readings or the testing loss.', 1;

        /* Rollover ke naam par bakwas value na aa jaye — ek shift me ek nozzle se
           50,000 litre se zyada realistic nahi hai. */
        IF EXISTS (SELECT 1 FROM PUMP.ShiftNozzleReadings WHERE ShiftId = @Id AND SoldQty > 50000)
            THROW 50005, 'Sold quantity is too high (over 50,000 L). Please re-check the readings.', 1;

        /* FIX #1 — har nozzle ka apna tank. Pehle TankId, na ho to product ka
           akela tank, aur agar do tank hain to saaf error. */
        IF EXISTS
        (
            SELECT 1
            FROM PUMP.ShiftNozzleReadings snr
            JOIN PUMP.Nozzles n ON n.Id = snr.NozzleId
            WHERE snr.ShiftId = @Id
              AND snr.SoldQty > 0
              AND n.TankId IS NULL
              AND ISNULL((SELECT pr.TracksStock FROM PUMP.Products pr WHERE pr.Id = n.ProductId), 1) = 1
              AND (SELECT COUNT(*) FROM PUMP.Tanks t
                   WHERE t.PumpId = @PumpId AND t.ProductId = n.ProductId AND t.IsActive = 1) <> 1
        )
            THROW 50003, 'Some nozzles have no tank set (or the product has more than one tank). Pick a tank in the Nozzle master.', 1;

        /* ---------- 3. Purani deduction reverse karo (FIX #3) ----------
           Band shift dobara close ho rahi hai to pehle ka asar hata do, phir naya
           daalo. Isse edit karne par stock hamesha sales ke barabar rehta hai. */
        IF @WasClosed = 1
        BEGIN
            UPDATE t
            SET t.CurrentStock = t.CurrentStock + x.Qty
            FROM PUMP.Tanks t
            INNER JOIN
            (
                SELECT TankId, SUM(CASE WHEN TxnType = 'OUT' THEN Quantity ELSE -Quantity END) AS Qty
                FROM PUMP.TankTransactions
                WHERE ReferenceNo = @ShiftRef
                GROUP BY TankId
            ) x ON x.TankId = t.Id;

            DELETE FROM PUMP.TankTransactions WHERE ReferenceNo = @ShiftRef;

            -- is shift ke auto testing-loss records bhi hata do, neeche naye banenge
            DELETE FROM PUMP.TestingLosses WHERE ShiftId = @Id AND LossType = 'SHIFT_TEST';

            EXEC PUMP.sp_Audit_Log
                @OwnerId = @OwnerId, @PumpId = @PumpId, @UserId = @UserId,
                @EntityName = 'ShiftHeaders', @EntityId = @Id, @Action = 'REOPEN_RECALC',
                @Reason = 'Closed shift edited — purani tank deduction reverse karke dobara post ki gayi';
        END

        /* ---------- 4. Pump test ka tel ----------
           Is pump par test ka tel naap kar WAPAS tank me daala jaata hai (user ne
           2026-09-04 ko confirm kiya), isliye ye nuksaan hai hi nahi — na tank se
           ghatega, na TestingLosses me darj hoga.

           Pehle yahan 'SHIFT_TEST' ki row banti thi aur tank se sale+test dono
           ghat jaate the. Us wajah se har test wale din tank me test jitna tel kam
           dikhta tha aur DSR ka closing tank se nahi milta tha.

           Kitna tel test me nikla — ye ab bhi poori tarah darj hai
           (ShiftNozzleReadings.TestingLoss), aur DSR ke "Pump Test" column me
           dikhta hai. TestingLosses table ab sirf ASLI nuksaan ke liye hai, jo
           Testing Loss form se aata hai (sp_TestingLoss_Save khud stock ghatata
           hai — wo theek hai, wahan tel wapas nahi jaata).

           Upar wala DELETE (re-close ke waqt) jaanbujh ke rakha hai, taaki is
           badlav se pehle bani hui SHIFT_TEST rows shift edit karte hi saaf ho jayen. */

        /* ---------- 5. Tank se stock nikalo ----------
           Sirf bikri (SoldQty). SoldQty pehle hi testing loss nikaal kar bana hai
           (dekho upar: closing - opening - TestingLoss), isliye yahi wo tel hai jo
           sach me tank se gaya. */
        ;WITH resolved AS
        (
            SELECT
                TankId = COALESCE(n.TankId, ft.TankId),
                Qty    = snr.SoldQty
            FROM PUMP.ShiftNozzleReadings snr
            JOIN PUMP.Nozzles n ON n.Id = snr.NozzleId
            OUTER APPLY
            (
                SELECT TankId = MIN(t.Id)
                FROM PUMP.Tanks t
                WHERE t.PumpId = @PumpId AND t.ProductId = n.ProductId AND t.IsActive = 1
            ) ft
            WHERE snr.ShiftId = @Id
              AND snr.SoldQty > 0
              /* Gas (CNG) / bijli ka stock tank me nahi naapa jaata - uska kuch ghatana nahi. */
              AND ISNULL((SELECT pr.TracksStock FROM PUMP.Products pr WHERE pr.Id = n.ProductId), 1) = 1
        ),
        perTank AS
        (
            SELECT TankId, Qty = SUM(Qty)
            FROM resolved
            WHERE TankId IS NOT NULL
            GROUP BY TankId
        )
        INSERT INTO PUMP.TankTransactions
            (OwnerId, PumpId, TankId, TxnType, Quantity, TxnDateTime, ReferenceNo, Notes, CreatedBy)
        SELECT @OwnerId, @PumpId, pt.TankId, 'OUT', pt.Qty, @TxnStamp, @ShiftRef,
               'Shift meter sale (test ka tel wapas tank me gaya)', @UserId
        FROM perTank pt
        WHERE pt.TankId IS NOT NULL;

        UPDATE t
        SET t.CurrentStock = t.CurrentStock - x.Qty
        FROM PUMP.Tanks t
        INNER JOIN
        (
            SELECT TankId, SUM(Quantity) AS Qty
            FROM PUMP.TankTransactions
            WHERE ReferenceNo = @ShiftRef AND TxnType = 'OUT'
            GROUP BY TankId
        ) x ON x.TankId = t.Id;

        /* Stock negative ho gaya to shift rokte nahi (warna operator fans jayega),
           par audit me chillate zaroor hain — matlab opening stock galat tha,
           ya purchase entry reh gayi, ya chori hui hai. */
        INSERT INTO PUMP.AuditLog (OwnerId, PumpId, UserId, EntityName, EntityId, Action, Reason, NewValues)
        SELECT @OwnerId, @PumpId, @UserId, 'Tanks', t.Id, 'NEGATIVE_STOCK',
               CONCAT('Shift ', @Id, ' band hone ke baad tank stock negative hai — purchase entry ya opening stock check karein'),
               CAST(t.CurrentStock AS NVARCHAR(50))
        FROM PUMP.Tanks t
        WHERE t.Id IN (SELECT TankId FROM PUMP.TankTransactions WHERE ReferenceNo = @ShiftRef)
          AND t.CurrentStock < 0;

        /* ---------- 6. Cash reconciliation (neeche G7 wala formula) ---------- */
        DECLARE @MeterSale DECIMAL(18,2) =
            ISNULL((SELECT SUM(SoldAmount) FROM PUMP.ShiftNozzleReadings WHERE ShiftId = @Id), 0);

        DECLARE @Credit DECIMAL(18,2) =
            ISNULL((SELECT SUM(TotalAmount) FROM PUMP.SalesHeaders
                    WHERE ShiftId = @Id AND IsVoid = 0
                      AND UPPER(ISNULL(PaymentMode,'')) = 'CREDIT'), 0);

        DECLARE @Digital DECIMAL(18,2) =
            ISNULL((SELECT SUM(TotalAmount) FROM PUMP.SalesHeaders
                    WHERE ShiftId = @Id AND IsVoid = 0
                      AND UPPER(ISNULL(PaymentMode,'')) IN ('UPI','CARD','DIGITAL','ONLINE','BANK','WALLET')), 0);

        DECLARE @Receipts DECIMAL(18,2) =
            ISNULL((SELECT SUM(Amount) FROM PUMP.PartyLedger
                    WHERE ShiftId = @Id
                      AND UPPER(EntryType) IN ('RECEIPT','PAYMENT_IN','CREDIT')
                      AND UPPER(ISNULL(PaymentMode,'CASH')) = 'CASH'), 0);

        DECLARE @CashIn DECIMAL(18,2) =
            ISNULL((SELECT SUM(Amount) FROM PUMP.CashTransactions
                    WHERE ShiftId = @Id AND UPPER(TxnType) = 'IN'), 0);

        DECLARE @CashOut DECIMAL(18,2) =
            ISNULL((SELECT SUM(Amount) FROM PUMP.CashTransactions
                    WHERE ShiftId = @Id AND UPPER(TxnType) = 'OUT'), 0);

        DECLARE @CashExp DECIMAL(18,2) =
            ISNULL((SELECT SUM(Amount) FROM PUMP.ExpenseTransactions
                    WHERE ShiftId = @Id AND UPPER(ISNULL(PaymentMode,'CASH')) = 'CASH'), 0);

        DECLARE @Deposit DECIMAL(18,2) =
            ISNULL((SELECT SUM(Amount) FROM PUMP.BankDeposits
                    WHERE ShiftId = @Id AND IsDeleted = 0), 0);

        DECLARE @Expected DECIMAL(18,2) =
            @OpeningCash + @MeterSale - @Credit - @Digital + @Receipts + @CashIn - @CashOut - @CashExp - @Deposit;

        UPDATE PUMP.ShiftHeaders
        SET ClosedOn        = COALESCE(ClosedOn, SYSDATETIME()),
            ClosingCash     = COALESCE(@ClosingCash, ClosingCash),
            Notes           = COALESCE(@Notes, Notes),
            Status          = 'CLOSED',
            TotalMeterSale  = @MeterSale,
            ExpectedCash    = @Expected,
            CashShortExcess = ISNULL(COALESCE(@ClosingCash, ClosingCash), 0) - @Expected,
            ClosedByUserId  = ISNULL(@UserId, ClosedByUserId),
            ModifiedBy      = @UserId,
            ModifiedOn      = SYSDATETIME()
        WHERE Id = @Id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC PUMP.sp_Audit_Log
        @OwnerId = @OwnerId, @PumpId = @PumpId, @UserId = @UserId,
        @EntityName = 'ShiftHeaders', @EntityId = @Id, @Action = 'CLOSE';

    SELECT @Id AS Id;
END
GO
PRINT '  + AL4: sp_Shift_Close - gas tank-check aur tank se ghatane se bahar';
GO

CREATE OR ALTER PROCEDURE PUMP.sp_Shift_ClosingDipList
(
    @ShiftId BIGINT,
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PumpId BIGINT, @Dt DATE, @Status NVARCHAR(30);
    SELECT @PumpId = PumpId, @Dt = ShiftDate, @Status = Status
    FROM PUMP.ShiftHeaders
    WHERE Id = @ShiftId AND OwnerId = @OwnerId;

    /* Positional DTO ke liye khaali result bhi usi aakaar ka chahiye. */
    SELECT
        TankId             = t.Id,
        TankName           = t.Name,
        ProductName        = p.Name,
        /* Is shift ki apni bikri CHHOD kar book stock. Form me jaise-jaise
           closing reading bharte hain, JS usme se is shift ki bikri ghata kar
           turant farak dikhata hai. Band shift (edit) ki bikri fn me pehle se
           judi hoti hai - use wapas jod dete hain. */
        BookExcludingShift = CAST(ISNULL(PUMP.fn_TankBookStockForDip(t.Id, @Dt), 0)
                                  + CASE WHEN @Status = 'CLOSED' THEN ISNULL(ts.Sold, 0) ELSE 0 END
                                  AS DECIMAL(18,3)),
        NozzleIds          = ISNULL(nz.Ids, N''),
        DipId              = d.Id,
        DipCm              = d.DipCm,
        ActualStock        = d.ActualStock
    FROM PUMP.Tanks t
    JOIN PUMP.Products p ON p.Id = t.ProductId AND p.TracksStock = 1
    OUTER APPLY
    (
        SELECT OnlyTank = CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END
        FROM PUMP.Tanks t2
        WHERE t2.PumpId = t.PumpId AND t2.ProductId = t.ProductId AND t2.IsActive = 1
    ) o
    OUTER APPLY
    (
        SELECT Sold = SUM(snr.SoldQty)
        FROM PUMP.ShiftNozzleReadings snr
        JOIN PUMP.Nozzles n ON n.Id = snr.NozzleId
        WHERE snr.ShiftId = @ShiftId
          AND (n.TankId = t.Id OR (n.TankId IS NULL AND n.ProductId = t.ProductId AND o.OnlyTank = 1))
    ) ts
    OUTER APPLY
    (
        SELECT Ids = STRING_AGG(CAST(n.Id AS NVARCHAR(20)), N',')
        FROM PUMP.Nozzles n
        WHERE n.PumpId = t.PumpId
          AND (n.TankId = t.Id OR (n.TankId IS NULL AND n.ProductId = t.ProductId AND o.OnlyTank = 1))
    ) nz
    OUTER APPLY
    (
        SELECT TOP 1 dr.Id, dr.DipCm, dr.ActualStock
        FROM PUMP.DipReadings dr
        WHERE dr.ShiftId = @ShiftId AND dr.TankId = t.Id AND dr.IsActive = 1
        ORDER BY dr.Id DESC
    ) d
    WHERE t.PumpId = @PumpId
      AND t.IsActive = 1
      AND ISNULL(t.IsDeleted, 0) = 0
    ORDER BY t.Name;
END
GO
PRINT '  + AL5: sp_Shift_ClosingDipList - dip sirf tel ke tank ki';
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Purchase_List]
(
    @OwnerId    BIGINT,
    @PumpId     BIGINT,
    @FromDate   DATE        = NULL,
    @ToDate     DATE        = NULL,
    @PageNumber INT         = 1,
    @PageSize   INT         = 20
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        ph.Id,
        ph.OwnerId,
        ph.PumpId,
        ph.VendorId,
        ISNULL(v.VendorName, 'Unknown')    AS VendorName,
        ph.InvoiceNo,
        ph.InvoiceDate,
        ph.VehicleNo,
        ph.DriverName,
        ph.TotalAmount,
        ph.Notes,
        ph.CreatedOn,
        ISNULL((
            SELECT SUM(pd.Quantity)
            FROM PUMP.PurchaseDetails pd
            WHERE pd.PurchaseHeaderId = ph.Id
        ), 0) AS TotalQty,
        ISNULL((
            SELECT STRING_AGG(
                CAST(pr.Name + N': ' + FORMAT(pd.Quantity, '0.##') + N' ' + CASE WHEN LOWER(pr.Unit) IN (N'kg', N'किलो') THEN N'kg'
                                                           WHEN LOWER(pr.Unit) = N'kwh' THEN N'kWh'
                                                           WHEN LOWER(pr.Unit) IN (N'piece', N'नग') THEN N'pcs'
                                                           ELSE N'L' END + N' = ' + NCHAR(8377)
                     + FORMAT(pd.Amount, 'N2', 'en-IN') AS NVARCHAR(MAX)),
                N' | ')
            FROM PUMP.PurchaseDetails pd
            INNER JOIN PUMP.Products pr ON pr.Id = pd.ProductId
            WHERE pd.PurchaseHeaderId = ph.Id
        ), N'') AS ProductSummary
    FROM PUMP.PurchaseHeaders ph
    LEFT JOIN PUMP.Vendors v ON v.Id = ph.VendorId
    WHERE ph.OwnerId = @OwnerId
      AND ph.PumpId  = @PumpId
      AND (@FromDate IS NULL OR CAST(ph.InvoiceDate AS DATE) >= @FromDate)
      AND (@ToDate   IS NULL OR CAST(ph.InvoiceDate AS DATE) <= @ToDate)
    ORDER BY ph.InvoiceDate DESC, ph.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(1)
    FROM PUMP.PurchaseHeaders ph
    WHERE ph.OwnerId = @OwnerId
      AND ph.PumpId  = @PumpId
      AND (@FromDate IS NULL OR CAST(ph.InvoiceDate AS DATE) >= @FromDate)
      AND (@ToDate   IS NULL OR CAST(ph.InvoiceDate AS DATE) <= @ToDate);
END
GO
PRINT '  + AL5b: sp_Purchase_List - line me ikai (kg / L)';
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Receipt_Generate]
(
    @SalesHeaderId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.Receipts WHERE SalesHeaderId = @SalesHeaderId)
    BEGIN
        DECLARE @OwnerId BIGINT;
        DECLARE @PumpId BIGINT;
        DECLARE @BillDateTime DATETIME2;
        DECLARE @FinancialYear NVARCHAR(9);
        DECLARE @Prefix NVARCHAR(20);
        DECLARE @ReceiptNo NVARCHAR(50);

        SELECT
            @OwnerId = OwnerId,
            @PumpId = PumpId,
            @BillDateTime = BillDateTime
        FROM PUMP.SalesHeaders
        WHERE Id = @SalesHeaderId;

        IF @OwnerId IS NULL OR @PumpId IS NULL
        BEGIN
            RAISERROR('Invalid SalesHeaderId for receipt generation.', 16, 1);
            RETURN;
        END

        DECLARE @FYStartYear INT = CASE WHEN MONTH(@BillDateTime) >= 4 THEN YEAR(@BillDateTime) ELSE YEAR(@BillDateTime) - 1 END;
        SET @FinancialYear = CONCAT(@FYStartYear, '-', RIGHT(CAST(@FYStartYear + 1 AS NVARCHAR(4)), 2));
        SET @Prefix = CONCAT('RCP', REPLACE(@FinancialYear, '-', ''), '/');

        DECLARE @Series TABLE (NextNumber NVARCHAR(50));
        INSERT INTO @Series (NextNumber)
        EXEC PUMP.sp_NumberSeries_Next
            @OwnerId = @OwnerId,
            @PumpId = @PumpId,
            @SeriesKey = 'RECEIPT',
            @FinancialYear = @FinancialYear,
            @Prefix = @Prefix,
            @PaddingLength = 6;

        SELECT TOP 1 @ReceiptNo = NextNumber FROM @Series;

        INSERT INTO PUMP.Receipts (SalesHeaderId, ReceiptNo)
        VALUES (@SalesHeaderId, @ReceiptNo);
    END

    -- Get aggregated GST amounts and Pump Details
    SELECT
        r.Id,
        r.SalesHeaderId,
        r.ReceiptNo,
        r.ReceiptDateTime,
        h.BillNo,
        h.BillDateTime,
        h.PaymentMode,
        h.VehicleNo,
        h.CustomerName,
        h.AttendantName,
        h.TotalAmount,
        -- BLOCKER FIX (2026-09-03): TotalQuantity ReceiptDto me tha par SP isse deta hi
        -- nahi tha — isliye har sale ke baad "Sale saved, but receipt generation failed."
        -- aata tha aur customer ko receipt/bill kabhi print nahi hoti thi.
        COALESCE((SELECT SUM(Quantity)   FROM PUMP.SalesDetails WHERE SalesHeaderId = h.Id), 0) AS TotalQuantity,
        COALESCE((SELECT SUM(BaseAmount) FROM PUMP.SalesDetails WHERE SalesHeaderId = h.Id), h.TotalAmount) AS BaseAmount,
        COALESCE((SELECT SUM(CGSTAmount) FROM PUMP.SalesDetails WHERE SalesHeaderId = h.Id), 0) AS TotalCGST,
        COALESCE((SELECT SUM(SGSTAmount) FROM PUMP.SalesDetails WHERE SalesHeaderId = h.Id), 0) AS TotalSGST,
        p.GSTIN AS PumpGSTIN,
        p.Address AS PumpAddress,
        /* Sale ki saari line ki ikai ek ho to wahi ("kg" / "L"), mili-juli ho to NULL - raseed par
           kg aur litre ka jod nahi chhapta. */
        (SELECT CASE WHEN COUNT(DISTINCT x.U) = 1 THEN MAX(x.U) END
         FROM (SELECT U = CASE WHEN LOWER(pr.Unit) IN (N'kg', N'किलो') THEN N'kg'
                               WHEN LOWER(pr.Unit) = N'kwh' THEN N'kWh'
                               WHEN LOWER(pr.Unit) IN (N'piece', N'नग') THEN N'pcs'
                               ELSE N'L' END
               FROM PUMP.SalesDetails d
               JOIN PUMP.Products pr ON pr.Id = d.ProductId
               WHERE d.SalesHeaderId = h.Id) x) AS QuantityUnit
    FROM PUMP.Receipts r
    INNER JOIN PUMP.SalesHeaders h ON h.Id = r.SalesHeaderId
    INNER JOIN PUMP.Pumps p ON p.Id = h.PumpId
    WHERE r.SalesHeaderId = @SalesHeaderId;
END
GO
PRINT '  + AL5c: sp_Receipt_Generate - raseed par QuantityUnit';
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Shift_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT = NULL,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @SearchTerm NVARCHAR(100) = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 50
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Offset INT = (@PageNumber - 1) * @PageSize;

    ;WITH ShiftBase AS
    (
        SELECT
            sh.Id,
            sh.OwnerId,
            sh.PumpId,
            sh.OperatorUserId,
            sh.OperatorEmployeeId,
            OperatorName = COALESCE(e.FullName, u.FullName),
            sh.ShiftDate,
            sh.ShiftCode,
            sh.OpeningCash,
            sh.ClosingCash,
            sh.Notes,
            sh.OpenedOn,
            sh.ClosedOn,
            sh.Status,
            /* Us pump par us din ki kaunsi shift — 1, 2, 3...
               Filter se pehle ginna zaroori hai: agar user ne tareekh ka filter
               lagaya ho to bhi number wahi rehna chahiye jo asal me hai. */
            /* CAST zaroori hai: ROW_NUMBER() BIGINT lautata hai, aur ShiftDto ka
               param `int` hai. Bina CAST ke Dapper record bana hi nahi paata
               aur POORI shift list 400 de deti hai (CLAUDE.md niyam 5). */
            ShiftNo = CAST(ROW_NUMBER() OVER (
                          PARTITION BY sh.PumpId, sh.ShiftDate
                          ORDER BY sh.OpenedOn, sh.Id) AS INT)
        FROM PUMP.ShiftHeaders sh
        LEFT JOIN PUMP.Employees e ON e.Id = sh.OperatorEmployeeId
        LEFT JOIN PUMP.Users     u ON u.Id = sh.OperatorUserId
        WHERE sh.OwnerId = @OwnerId
    )
    SELECT
        b.Id,
        b.OwnerId,
        b.PumpId,
        b.OperatorUserId,
        b.OperatorEmployeeId,
        b.OperatorName,
        b.ShiftDate,
        b.ShiftCode,
        b.OpeningCash,
        b.ClosingCash,
        TotalSoldQty = ISNULL(snr.TotalSoldQty, 0),
        TotalSoldAmount = ISNULL(snr.TotalSoldAmount, 0),
        b.Notes,
        b.OpenedOn,
        b.ClosedOn,
        b.Status,
        b.ShiftNo
    FROM ShiftBase b
    OUTER APPLY
    (
        SELECT
            /* Sirf tel (litre): gas ke kg aur tel ke litre ka jod kisi kaam ka nahi. Rupaye (neeche) sab ke. */
            SUM(CASE WHEN ISNULL(pr.TracksStock, 1) = 1 THEN ISNULL(x.SoldQty, 0) ELSE 0 END) AS TotalSoldQty,
            SUM(ISNULL(x.SoldAmount, 0)) AS TotalSoldAmount
        FROM PUMP.ShiftNozzleReadings x
        LEFT JOIN PUMP.Products pr ON pr.Id = x.ProductId
        WHERE x.ShiftId = b.Id
    ) snr
    WHERE (@PumpId IS NULL OR @PumpId <= 0 OR b.PumpId = @PumpId)
      AND (@FromDate IS NULL OR b.ShiftDate >= @FromDate)
      AND (@ToDate IS NULL OR b.ShiftDate <= @ToDate)
      AND (@SearchTerm IS NULL OR @SearchTerm = '' OR b.ShiftCode LIKE '%' + @SearchTerm + '%' OR b.Notes LIKE '%' + @SearchTerm + '%')
    ORDER BY b.Id DESC
    OFFSET @Offset ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(1)
    FROM PUMP.ShiftHeaders sh
    WHERE sh.OwnerId = @OwnerId
      AND (@PumpId IS NULL OR @PumpId <= 0 OR sh.PumpId = @PumpId)
      AND (@FromDate IS NULL OR sh.ShiftDate >= @FromDate)
      AND (@ToDate IS NULL OR sh.ShiftDate <= @ToDate)
      AND (@SearchTerm IS NULL OR @SearchTerm = '' OR sh.ShiftCode LIKE '%' + @SearchTerm + '%' OR sh.Notes LIKE '%' + @SearchTerm + '%');
END
GO
PRINT '  + AL5d: sp_Shift_List - Sold Qty sirf tel (litre)';
GO

CREATE OR ALTER PROCEDURE [PUMP].[sp_Report_DailyStockRegister]

(

    @PumpId    BIGINT,

    @ProductId BIGINT,

    @Month     INT,

    @Year      INT

,
    @OwnerId BIGINT = NULL
)

AS

BEGIN

    SET NOCOUNT ON;

    -- TENANT GUARD: pump usi owner ka hona chahiye. Pehle is report me OwnerId
    -- tha hi nahi — sirf pumpId guess karke doosre owner ki poore mahine ki
    -- stock report nikaali ja sakti thi.
    IF @OwnerId IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM PUMP.Pumps WHERE Id = @PumpId AND OwnerId = @OwnerId)
        RETURN;




    DECLARE @StartDate DATE = DATEFROMPARTS(@Year, @Month, 1);

    DECLARE @EndDate   DATE = EOMONTH(@StartDate);



    -- 1. Calculate Initial Opening Stock at the start of the month

    DECLARE @InitialOpening DECIMAL(18,3) = 0;

    SELECT @InitialOpening = ISNULL(SUM(CurrentStock), 0)

    FROM PUMP.Tanks

    WHERE PumpId = @PumpId AND ProductId = @ProductId AND IsActive = 1;



    DECLARE @NetChangeSinceStart DECIMAL(18,3) = 0;

    -- Stock badhane wale TxnType wahi hone chahiye jo sp_TankTxn_Save maanta hai:
    -- IN, RECEIPT, PURCHASE, OPENING. Pehle yahan sirf 'IN' likha tha, isliye har
    -- PURCHASE row ko ghatav (-) maan liya jaata tha aur mahine ka opening stock
    -- purchase ki maatra jitna ZYADA dikhta tha. Purchase se ab automatic
    -- TxnType='PURCHASE' row banti hai (dekho sp_Purchase_SaveDetail), isliye ye
    -- galti har delivery par register bigaad rahi thi.
    SELECT @NetChangeSinceStart = ISNULL(

        SUM(CASE WHEN UPPER(TxnType) IN ('IN', 'RECEIPT', 'PURCHASE', 'OPENING')
                 THEN Quantity ELSE -Quantity END), 0)

    FROM PUMP.TankTransactions

    WHERE PumpId = @PumpId

      AND TankId IN (SELECT Id FROM PUMP.Tanks WHERE ProductId = @ProductId AND PumpId = @PumpId)

      AND CAST(TxnDateTime AS DATE) >= @StartDate;



    SET @InitialOpening = @InitialOpening - @NetChangeSinceStart;

    /* ---- Section AC: pichhle mahine ka closing = is mahine ka opening ----
       Upar wala hisaab tank ke KITAABI stock (CurrentStock) se ulta chalta hai.
       Mahine ke andar register har din dip par naya shuru hota hai, par mahine
       ki pehli tareekh par wapas kitaabi stock par aa jaata tha - usme 1 tarikh
       se ka saara jama farak hota hai. Nateeja: pichhle mahine ka closing aur
       is mahine ka opening alag, aur agle mahine ki pehli dip wale din poora
       purana farak ek saath "Excess/Short" ban kar dikhta (UAT par 1 Oct ko
       diesel ~+55 L aata).

       Ab jis tank ki pichhle mahine ke ant tak koi naap (chaalu dip ya
       reconciliation) hai, uska opening = us aakhri din ka closing: us din dip
       thi to dip, warna reconciliation, warna fn_TankBookStockForDip (wahi
       hisaab jo register roz lagata hai). Jis tank ki kabhi naap hi nahi hui,
       uska purana hisaab bilkul waisa hi - isliye bina dip wale register ka ek
       ank nahi badalta. */
    DECLARE @PrevDay DATE = DATEADD(DAY, -1, @StartDate);
    DECLARE @OpeningSwap DECIMAL(18,3) = 0;

    ;WITH measured AS
    (
        SELECT t.Id,
               OldOpening = t.CurrentStock - ISNULL((
                   SELECT SUM(CASE WHEN UPPER(x.TxnType) IN ('IN', 'RECEIPT', 'PURCHASE', 'OPENING')
                                   THEN x.Quantity ELSE -x.Quantity END)
                   FROM PUMP.TankTransactions x
                   WHERE x.PumpId = @PumpId AND x.TankId = t.Id
                     AND CAST(x.TxnDateTime AS DATE) >= @StartDate), 0),
               NewOpening = COALESCE(
                   (SELECT TOP 1 d.ActualStock FROM PUMP.DipReadings d
                    WHERE d.TankId = t.Id AND d.IsActive = 1 AND d.ActualStock > 0 AND d.ReadingDate = @PrevDay
                    ORDER BY d.Id DESC),
                   (SELECT TOP 1 r.PhysicalStock FROM PUMP.StockReconciliations r
                    WHERE r.TankId = t.Id AND CAST(r.ReconciliationDate AS DATE) = @PrevDay
                    ORDER BY r.Id DESC),
                   PUMP.fn_TankBookStockForDip(t.Id, @PrevDay))
        FROM PUMP.Tanks t
        WHERE t.PumpId = @PumpId AND t.ProductId = @ProductId AND t.IsActive = 1
          AND (   EXISTS (SELECT 1 FROM PUMP.DipReadings d
                          WHERE d.TankId = t.Id AND d.IsActive = 1 AND d.ActualStock > 0 AND d.ReadingDate <= @PrevDay)
               OR EXISTS (SELECT 1 FROM PUMP.StockReconciliations r
                          WHERE r.TankId = t.Id AND CAST(r.ReconciliationDate AS DATE) <= @PrevDay))
    )
    SELECT @OpeningSwap = ISNULL(SUM(NewOpening - OldOpening), 0) FROM measured;

    SET @InitialOpening = @InitialOpening + @OpeningSwap;



    -- 2. Generate Calendar for the Month

    CREATE TABLE #Calendar ( DateValue DATE PRIMARY KEY );

    DECLARE @CurDate DATE = @StartDate;

    WHILE @CurDate <= @EndDate

    BEGIN

        INSERT INTO #Calendar (DateValue) VALUES (@CurDate);

        SET @CurDate = DATEADD(day, 1, @CurDate);

    END



    -- 3. Daily Base Data

    CREATE TABLE #DailyReport

    (

        RowId INT IDENTITY(1,1) PRIMARY KEY,

        [Date] DATE,

        OpeningStock DECIMAL(18,3),

        Receipt DECIMAL(18,3),

        TotalStock DECIMAL(18,3),

        SalesByMeter DECIMAL(18,3),

        PumpTest DECIMAL(18,3),

        NetSalesByMeter DECIMAL(18,3),

        ClosingDipStock DECIMAL(18,3),

        SalesByDip DECIMAL(18,3),

        VariationDaily DECIMAL(18,3),
        -- CA ke liye zaroori: kitaabi closing aur asli (dip) closing ALAG-ALAG
        -- dikhne chahiye. Pehle sirf ek "ClosingStock" tha jo chupke se dip par
        -- switch ho jaata tha - dekhne wale ko pata hi nahi chalta tha ki
        -- variance kis aadhaar par nikla.
        BookClosingStock DECIMAL(18,3),
        PhysicalClosingStock DECIMAL(18,3),
        -- Us din stock physically napa gaya tha ya nahi. Bina iske "variance 0"
        -- ke do matlab ho jaate hain: sab theek, ya napa hi nahi gaya.
        StockChecked BIT,
        -- Us din ka rate aur us hisaab se bikri ki rupee value. CA isi se
        -- register ko bikri khaate aur GST return se milata hai.
        RateApplied DECIMAL(18,3),
        SalesValue DECIMAL(18,2),

        -- Din ke aakhir ka bacha hua stock. Register me ye column tha hi nahi,
        -- jabki DSR ka matlab hi yahi hota hai — aur agle din ka opening isi se
        -- banta hai, to dono ka milna user ko dikhna chahiye.
        ClosingStock DECIMAL(18,3),

        -- Nuksaan/faayde ke PAISE. "45 litre kam hai" se zyada matlab
        -- "Rs 4,302 ka nuksaan" rakhta hai — pump wale ko yahi dekhna hota hai.
        VariationValue DECIMAL(18,2),

        Remarks NVARCHAR(255)

    );



    INSERT INTO #DailyReport ([Date], Receipt, SalesByMeter, PumpTest, NetSalesByMeter, ClosingDipStock)

    SELECT

        c.DateValue,

        -- Receipts (excluding internal adjustments and reconciliations)

        ISNULL((

            SELECT SUM(Quantity)

            FROM PUMP.TankTransactions

            WHERE PumpId   = @PumpId

              -- Sirf 'IN' dekhne se tanker delivery (TxnType='PURCHASE') Receipt me
              -- 0 dikhti thi. Ab wahi chaar type jo stock badhate hain.
              AND UPPER(TxnType) IN ('IN', 'RECEIPT', 'PURCHASE', 'OPENING')

              AND TankId IN (SELECT Id FROM PUMP.Tanks WHERE ProductId = @ProductId AND PumpId = @PumpId)

              AND CAST(TxnDateTime AS DATE) = c.DateValue

              -- ISNULL zaroori hai: SQL me "NULL NOT LIKE '...'" ka jawab NULL hota
              -- hai, TRUE nahi — yaani jis entry me ReferenceNo khaali chhoda gaya
              -- (manual tank stock entry) wo chupchaap Receipt se gayab ho jaati thi.
              AND ISNULL(ReferenceNo, N'') NOT LIKE 'LOSS-DEL-%'

              AND ISNULL(ReferenceNo, N'') NOT LIKE 'VOID-SALE-%'

              AND ISNULL(ReferenceNo, N'') NOT LIKE 'SHIFT-EDIT-%'

              AND ISNULL(ReferenceNo, N'') NOT LIKE 'RECON-%'

        ), 0) AS Receipt,

        -- Gross Sales grouped by ShiftDate

        ISNULL((

            SELECT SUM(snr.SoldQty + snr.TestingLoss)

            FROM PUMP.ShiftNozzleReadings snr

            INNER JOIN PUMP.ShiftHeaders sh ON sh.Id = snr.ShiftId

            WHERE snr.ProductId = @ProductId AND sh.PumpId = @PumpId

              AND sh.Status = 'CLOSED'

              AND sh.ShiftDate = c.DateValue

        ), 0) AS SalesByMeter,

        -- Pump Test grouped by ShiftDate

        ISNULL((

            SELECT SUM(snr.TestingLoss)

            FROM PUMP.ShiftNozzleReadings snr

            INNER JOIN PUMP.ShiftHeaders sh ON sh.Id = snr.ShiftId

            WHERE snr.ProductId = @ProductId AND sh.PumpId = @PumpId

              AND sh.Status = 'CLOSED'

              AND sh.ShiftDate = c.DateValue

        ), 0) AS PumpTest,

        -- Net Sales grouped by ShiftDate

        ISNULL((

            SELECT SUM(snr.SoldQty)

            FROM PUMP.ShiftNozzleReadings snr

            INNER JOIN PUMP.ShiftHeaders sh ON sh.Id = snr.ShiftId

            WHERE snr.ProductId = @ProductId AND sh.PumpId = @PumpId

              AND sh.Status = 'CLOSED'

              AND sh.ShiftDate = c.DateValue

        ), 0) AS NetSalesByMeter,

        -- Closing physical dip stock

        ISNULL(

            (

                SELECT SUM(ActualStock) FROM (

                    SELECT dr.ActualStock,

                           ROW_NUMBER() OVER (PARTITION BY dr.TankId ORDER BY dr.Id DESC) as rn

                    FROM PUMP.DipReadings dr

                    INNER JOIN PUMP.Tanks tk ON tk.Id = dr.TankId

                    WHERE tk.PumpId = @PumpId AND tk.ProductId = @ProductId

                      AND dr.ReadingDate = c.DateValue

                      /* Dip list me switch band karne par row par laal "Deleted" ka
                         nishaan aa jaata hai, par ye query use phir bhi ginti thi -
                         yaani hataayi hui dip chupchaap poore din ka closing banti
                         rehti thi, aur wahi agle din ka opening bhi ban jaata tha. */
                      AND dr.IsActive = 1

                ) x WHERE x.rn = 1

            ),

            ISNULL(

                (

                    SELECT SUM(PhysicalStock) FROM (

                        SELECT sr.PhysicalStock,

                               ROW_NUMBER() OVER (PARTITION BY sr.TankId ORDER BY sr.Id DESC) as rn

                        FROM PUMP.StockReconciliations sr

                        INNER JOIN PUMP.Tanks tk ON tk.Id = sr.TankId

                        WHERE tk.PumpId = @PumpId AND tk.ProductId = @ProductId

                          AND CAST(sr.ReconciliationDate AS DATE) = c.DateValue

                    ) y WHERE y.rn = 1

                ), 0

            )

        ) AS ClosingDipStock

    FROM #Calendar c

    ORDER BY c.DateValue;



    -- 4. Iterative Calculation for Running Totals

    DECLARE @i INT = 1;

    DECLARE @MaxI INT;

    SELECT @MaxI = MAX(RowId) FROM #DailyReport;



    DECLARE @CurrentOpening DECIMAL(18,3) = @InitialOpening;

    DECLARE @Receipt DECIMAL(18,3), @NetSales DECIMAL(18,3), @Dip DECIMAL(18,3);




    WHILE @i <= @MaxI

    BEGIN

        SELECT

            @Receipt = Receipt,

            @NetSales = NetSalesByMeter,

            @Dip = ClosingDipStock

        FROM #DailyReport WHERE RowId = @i;



        DECLARE @ReportDate DATE = (SELECT [Date] FROM #DailyReport WHERE RowId = @i);

        /* "Aaj stock physically napa gaya tha ya nahi" — ye dip AUR reconciliation
           dono se aa sakta hai. Pehle sirf DipReadings ginti thi, isliye jis din
           sirf reconciliation hui thi us din variance zabardasti 0 dikhta tha,
           jabki ClosingDipStock me reconciliation ka physical stock pehle se
           aa raha tha. Nateeja: nuksaan sirf Remarks ke text me dikhta tha,
           Variation column aur mahine ke cumulative variance me nahi. */
        DECLARE @HasDip INT =
        (
            SELECT COUNT(1) FROM PUMP.DipReadings
            WHERE TankId IN (SELECT Id FROM PUMP.Tanks WHERE ProductId = @ProductId AND PumpId = @PumpId)
              AND ReadingDate = @ReportDate
              /* Upar wali query se milna zaroori hai: wahan dip chhut jaye aur
                 yahan gin li jaye to "Stock Checked = Yes" dikhega jabki variance
                 kisi aur hi aadhaar par nikla hoga. */
              AND IsActive = 1
        )
        +
        (
            SELECT COUNT(1) FROM PUMP.StockReconciliations
            WHERE TankId IN (SELECT Id FROM PUMP.Tanks WHERE ProductId = @ProductId AND PumpId = @PumpId)
              AND CAST(ReconciliationDate AS DATE) = @ReportDate
        );

        /* @Dip aage badal jaata hai (jis din napa nahi gaya us din use kitaabi
           stock se bhar dete hain), isliye asli napa hua stock yahin alag rakh
           lete hain - register me wahi dikhana hai. */
        DECLARE @MeasuredDip DECIMAL(18,3) = CASE WHEN @HasDip > 0 THEN @Dip ELSE NULL END;

        DECLARE @Total DECIMAL(18,3) = @CurrentOpening + @Receipt;
        DECLARE @SalesDip DECIMAL(18,3);
        DECLARE @VarDaily DECIMAL(18,3);

        /* Us din ka rate — mahine ke beech rate badla ho to har din apne rate par
           gina jaye, warna nuksaan ki value galat banegi. */
        DECLARE @DayRate DECIMAL(18,3) =
            PUMP.fn_ProductRateOnDate(@ProductId, DATEADD(HOUR, 23, CAST(@ReportDate AS DATETIME2(7))));

        /* Kitaabi (book) closing — jitna stock hona chahiye tha. Net se ghatao:
           test ka tel wapas tank me chala jaata hai, isliye wo tank se gaya hi nahi. */
        DECLARE @BookClosing DECIMAL(18,3) = @Total - @NetSales;

        IF @HasDip = 0
        BEGIN
            /* Aaj stock napa hi nahi gaya — variance ka koi sawaal nahi. */
            SET @SalesDip = @NetSales;
            SET @Dip = CASE WHEN @NetSales > 0 THEN @BookClosing ELSE @Dip END;
            SET @VarDaily = 0;
        END
        ELSE
        BEGIN
            /* Variance = physical - book. Minus = nuksaan (laal), plus = zyada
               nikla (hara). Pehle ulta tha (@SalesDip - @NetSales), isliye ek hi
               row me Remarks "-45" bolti thi aur Variation column "+45".
               StockReconciliations.VarianceQty aur DipReadings.Variance dono
               physical-book hi rakhte hain, ab register bhi wahi bolta hai. */
            SET @VarDaily = CASE WHEN @Dip > 0 THEN @Dip - @BookClosing ELSE 0 END;

            /* Dip se nikli sale = jitna stock ghata. Agar dip kitaabi stock se
               ZYADA nikle (bina entry wali delivery, ya galat purani entry) to ye
               rinaatmak ho jaata tha — "-7,916 litre bika" jaisi bekaar line.
               Sale kabhi minus nahi hoti; aisi soorat me 0 dikhao aur poori kahani
               Variation column me aa jaati hai. */
            SET @SalesDip =
                CASE WHEN @Dip > 0 AND @Total > @Dip THEN @Total - @Dip ELSE 0 END;
        END



        -- Fetch saved manual reconciliation variance

        DECLARE @ManualVar DECIMAL(18,3) = 0;

        DECLARE @ReconCount INT = 0;

        SELECT

            @ManualVar = ISNULL(SUM(VarianceQty), 0),

            @ReconCount = COUNT(Id)

        FROM PUMP.StockReconciliations

        WHERE TankId IN (SELECT Id FROM PUMP.Tanks WHERE ProductId = @ProductId AND PumpId = @PumpId)

          AND CAST(ReconciliationDate AS DATE) = (SELECT [Date] FROM #DailyReport WHERE RowId = @i);



        DECLARE @RemarksStr NVARCHAR(255) = NULL;

        /* Remarks me pehle bas 'Variance' likha aata tha. CA ko usse kuch pata
           nahi chalta tha: kitna, kis taraf, aur us din tank napa bhi gaya tha
           ya nahi. Khaali variance column ka matlab log "sab theek" samajh lete
           the, jabki asal me us din dip li hi nahi gayi hoti thi.
           Ab poori baat likhi jaati hai. */
        IF @ReconCount > 0
        BEGIN
            SET @RemarksStr = CONCAT('Reconciled by hand. Difference ',
                CASE WHEN @ManualVar < 0 THEN 'short ' ELSE 'excess ' END,
                CAST(CAST(ABS(@ManualVar) AS DECIMAL(18,1)) AS NVARCHAR(20)), ' L.');
        END
        ELSE IF @HasDip = 0
        BEGIN
            SET @RemarksStr = CASE WHEN @NetSales > 0 THEN N'Stock not measured' ELSE NULL END;
        END
        ELSE IF @VarDaily = 0
        BEGIN
            SET @RemarksStr = N'Dip matches book';
        END
        ELSE
        BEGIN
            SET @RemarksStr = CONCAT(
                CASE WHEN @VarDaily < 0 THEN 'Short ' ELSE 'Excess ' END,
                CAST(CAST(ABS(@VarDaily) AS DECIMAL(18,1)) AS NVARCHAR(20)), ' L',
                /* Seedha NVARCHAR me daalne par 'Rs 371.000000' chhapta tha -
                   pehle DECIMAL(18,0) me le aate hain, tabhi 'Rs 371' aata hai. */
                ' (Rs ', CAST(CAST(ABS(ROUND(@VarDaily * @DayRate, 0)) AS DECIMAL(18,0)) AS NVARCHAR(20)), ')');
        END



        -- Aaj ka closing = physical dip (agar liya gaya ho) warna kitaabi stock.
        -- Yahi agle din ka opening banega, isliye ek hi jagah nikaal kar dono me
        -- daal rahe hain — warna register ki do lines aapas me nahi milengi.
        DECLARE @ClosingStk DECIMAL(18,3) =
            CASE WHEN @Dip > 0 THEN @Dip ELSE @BookClosing END;

        UPDATE #DailyReport

        SET

            OpeningStock = @CurrentOpening,

            TotalStock = @Total,

            SalesByDip = @SalesDip,

            VariationDaily = @VarDaily,

            ClosingStock = @ClosingStk,

            BookClosingStock = @BookClosing,

            PhysicalClosingStock = @MeasuredDip,

            StockChecked = CASE WHEN @HasDip > 0 THEN 1 ELSE 0 END,

            RateApplied = @DayRate,

            SalesValue = ROUND(@NetSales * @DayRate, 2),

            VariationValue = ROUND(@VarDaily * @DayRate, 2),

            Remarks = @RemarksStr

        WHERE RowId = @i;



        SET @CurrentOpening = @ClosingStk;



        SET @i = @i + 1;

    END



    /* Gas (CNG) / bijli ka stock register me nahi chalta: na tank, na dip, na tanker. Bina iske
       opening 0 se shuru hokar har din minus (-561 kg) dikhta tha. Sirf bikri sach hai - baaki
       khaane 0 aur remark me saaf likha. */
    IF EXISTS (SELECT 1 FROM PUMP.Products WHERE Id = @ProductId AND TracksStock = 0)
        UPDATE #DailyReport
        SET OpeningStock = 0, Receipt = 0, TotalStock = 0, SalesByDip = 0, ClosingStock = 0,
            BookClosingStock = 0, PhysicalClosingStock = NULL, StockChecked = 0,
            VariationDaily = 0, VariationValue = 0,
            Remarks = CASE WHEN NetSalesByMeter > 0 THEN N'Stock not tracked (gas)' ELSE NULL END;

    -- 5. Final Output

    SELECT

        DAY([Date])                                   AS DayOfMonth,

        [Date],

        CAST(OpeningStock    AS DECIMAL(18,0))        AS OpeningStock,

        CAST(Receipt         AS DECIMAL(18,0))        AS Receipt,

        CAST(TotalStock      AS DECIMAL(18,0))        AS TotalStock,

        CAST(SalesByMeter    AS DECIMAL(18,0))        AS SalesByMeter,

        CAST(PumpTest        AS DECIMAL(18,0))        AS PumpTest,

        CAST(NetSalesByMeter AS DECIMAL(18,0))        AS NetSalesByMeter,

        CAST(SUM(NetSalesByMeter) OVER (ORDER BY [Date]) AS DECIMAL(18,0)) AS CumulativeSales,

        CAST(SalesByDip      AS DECIMAL(18,0))        AS SalesByDip,

        /* Kitaabi closing = opening + receipt - net sale. Jitna hona chahiye tha. */

        CAST(BookClosingStock AS DECIMAL(18,0))       AS BookClosingStock,

        /* Asli napa hua stock. Jis din napa nahi gaya us din NULL - register me

           "-" dikhta hai, 0 nahi (0 ka matlab "tank khaali tha" hota hai). */

        CAST(PhysicalClosingStock AS DECIMAL(18,0))   AS PhysicalClosingStock,

        ISNULL(StockChecked, 0)                       AS StockChecked,

        CAST(ClosingStock    AS DECIMAL(18,0))        AS ClosingStock,

        /* Ye do column jaanbujh ke 2 decimal me hain (baaki poore litre me).
           Variance me chhote fraction bhi maayne rakhte hain: 0.46 L roz ka
           nuksaan poore litre me round hokar "0" dikhta tha, jabki mahine bhar
           me 14 litre ban jaata hai — aur uski rupee value column me dikhti bhi
           thi, to row aapas me ulat lagti thi (Variation 0, Value -Rs 43.98). */
        CAST(VariationDaily  AS DECIMAL(18,2))        AS VariationDaily,

        ISNULL(VariationValue, 0)                     AS VariationValue,

   CAST(SUM(VariationDaily) OVER (ORDER BY [Date]) AS DECIMAL(18,2)) AS VariationCumulative,

        /* Rate aur rupee value - CA register ko bikri khaate se yahin milata hai. */

        ISNULL(RateApplied, 0)                        AS RateApplied,

        ISNULL(SalesValue, 0)                         AS SalesValue,

        CAST(SUM(ISNULL(SalesValue, 0)) OVER (ORDER BY [Date]) AS DECIMAL(18,2)) AS CumulativeSalesValue,

        Remarks

    FROM #DailyReport

    ORDER BY [Date];



    DROP TABLE #Calendar;

    DROP TABLE #DailyReport;

END
GO
PRINT '  + AL6: sp_Report_DailyStockRegister - gas ka stock khaana khaali';
GO

PRINT '=== Section AL done ===';
GO


/* ==========================================================================================
   SECTION AM — shift band karte waqt Cashbook ka "bank me jama" bhi ginna (2026-10-22)
   ------------------------------------------------------------------------------------------
   "Aaj ki shift" me ab galle se nikala nakad darj hota hai: malik ko diya (Cashbook OUT) aur
   bank me jama (BANK_DEPOSIT). Jo cheez sp_Shift_Collection_Summary pehle se ginta tha, wahi
   sp_Shift_Close nahi ginta tha: uska @Deposit sirf BankDeposits table se aata tha. Nateeja:
   Cashbook ya is screen se bank me jama nakad ShiftHeaders.ExpectedCash me ghatta nahi tha, aur
   stored CashShortExcess utne se galat aata. Screen par dikhne wala farak (summary se) pehle
   bhi sahi tha — ye sirf stored column ko uske barabar karta hai.

   Sirf naye / dobara band hone wale shift par asar. Purani band shift ki rows nahi chhuti.
   Baaki sp_Shift_Close hu-ba-hu AL wali.
   ========================================================================================== */
PRINT '=== Section AM: shift band me bank-jama (Cashbook) bhi ===';
GO

CREATE OR ALTER PROCEDURE PUMP.sp_Shift_Close
(
    @Id                 BIGINT,
    @ClosingCash        DECIMAL(18,2) = NULL,
    @Notes              NVARCHAR(500) = NULL,
    @NozzleReadingsJson NVARCHAR(MAX) = NULL,
    @UserId             BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @OwnerId BIGINT, @PumpId BIGINT, @Status NVARCHAR(30),
            @ShiftDate DATE, @OpeningCash DECIMAL(18,2), @WasClosed BIT = 0;

    SELECT TOP 1
        @OwnerId     = OwnerId,
        @PumpId      = PumpId,
        @Status      = Status,
        @ShiftDate   = ShiftDate,
        @OpeningCash = OpeningCash
    FROM PUMP.ShiftHeaders
    WHERE Id = @Id;

    IF @OwnerId IS NULL BEGIN SELECT CAST(-1 AS BIGINT) AS Id; RETURN; END
    IF ISNULL(@Status, '') NOT IN ('OPEN', 'CLOSED') BEGIN SELECT CAST(-2 AS BIGINT) AS Id; RETURN; END

    SET @WasClosed = CASE WHEN @Status = 'CLOSED' THEN 1 ELSE 0 END;

    /* FIX #4 — tank movement ki date shift ki date honi chahiye, aaj ki nahi.
       Aaj ki shift hai to asli time, warna us din ka 23:00. */
    DECLARE @TxnStamp DATETIME2(7) =
        CASE WHEN @ShiftDate = CAST(SYSDATETIME() AS DATE)
             THEN SYSDATETIME()
             ELSE DATEADD(HOUR, 23, CAST(CAST(@ShiftDate AS DATETIME2(7)) AS DATETIME2(7)))
        END;

    DECLARE @ShiftRef NVARCHAR(30) = CONCAT('SHIFT-', @Id);

    BEGIN TRY
        BEGIN TRANSACTION;

        /* ---------- 1. Readings update ---------- */
        IF @NozzleReadingsJson IS NOT NULL AND ISJSON(@NozzleReadingsJson) = 1
        BEGIN
            ;WITH cte AS
            (
                SELECT x.NozzleId, x.ClosingReading, ISNULL(x.TestingLoss, 0) AS TestingLoss
                FROM OPENJSON(@NozzleReadingsJson)
                WITH (NozzleId BIGINT '$.NozzleId',
                      ClosingReading DECIMAL(18,3) '$.ClosingReading',
                      TestingLoss DECIMAL(18,3) '$.TestingLoss') x
                WHERE ISNULL(x.NozzleId, 0) > 0
            )
            UPDATE snr
            SET snr.ClosingReading = cte.ClosingReading,
                snr.TestingLoss    = cte.TestingLoss,
                /* FIX #2 — meter rollover. Closing < Opening ka matlab totalizer
                   ghoom gaya hai, galti nahi. Nozzle ke MeterDigits se wapas jodo. */
                snr.IsRollover     = CASE WHEN cte.ClosingReading < snr.OpeningReading THEN 1 ELSE 0 END,
                snr.SoldQty        =
                    CASE
                        WHEN cte.ClosingReading >= snr.OpeningReading
                            THEN cte.ClosingReading - snr.OpeningReading
                        ELSE POWER(CAST(10 AS DECIMAL(18,3)), n.MeterDigits) - snr.OpeningReading + cte.ClosingReading
                    END
                    - cte.TestingLoss,
                snr.SoldAmount     =
                    (
                        CASE
                            WHEN cte.ClosingReading >= snr.OpeningReading
                                THEN cte.ClosingReading - snr.OpeningReading
                            ELSE POWER(CAST(10 AS DECIMAL(18,3)), n.MeterDigits) - snr.OpeningReading + cte.ClosingReading
                        END
                        - cte.TestingLoss
                    ) * snr.Rate,
                snr.UpdatedOn      = SYSDATETIME(),
                snr.ModifiedBy     = @UserId
            FROM PUMP.ShiftNozzleReadings snr
            INNER JOIN cte           ON cte.NozzleId = snr.NozzleId
            INNER JOIN PUMP.Nozzles n ON n.Id = snr.NozzleId
            WHERE snr.ShiftId = @Id;
        END

        /* ---------- 2. Validation ---------- */
        IF EXISTS (SELECT 1 FROM PUMP.ShiftNozzleReadings WHERE ShiftId = @Id AND ClosingReading IS NULL)
            THROW 50002, 'A closing reading is required for every nozzle.', 1;

        IF EXISTS (SELECT 1 FROM PUMP.ShiftNozzleReadings WHERE ShiftId = @Id AND SoldQty < 0)
            THROW 50004, 'Sold quantity is coming out negative. Check the readings or the testing loss.', 1;

        /* Rollover ke naam par bakwas value na aa jaye — ek shift me ek nozzle se
           50,000 litre se zyada realistic nahi hai. */
        IF EXISTS (SELECT 1 FROM PUMP.ShiftNozzleReadings WHERE ShiftId = @Id AND SoldQty > 50000)
            THROW 50005, 'Sold quantity is too high (over 50,000 L). Please re-check the readings.', 1;

        /* FIX #1 — har nozzle ka apna tank. Pehle TankId, na ho to product ka
           akela tank, aur agar do tank hain to saaf error. */
        IF EXISTS
        (
            SELECT 1
            FROM PUMP.ShiftNozzleReadings snr
            JOIN PUMP.Nozzles n ON n.Id = snr.NozzleId
            WHERE snr.ShiftId = @Id
              AND snr.SoldQty > 0
              AND n.TankId IS NULL
              AND ISNULL((SELECT pr.TracksStock FROM PUMP.Products pr WHERE pr.Id = n.ProductId), 1) = 1
              AND (SELECT COUNT(*) FROM PUMP.Tanks t
                   WHERE t.PumpId = @PumpId AND t.ProductId = n.ProductId AND t.IsActive = 1) <> 1
        )
            THROW 50003, 'Some nozzles have no tank set (or the product has more than one tank). Pick a tank in the Nozzle master.', 1;

        /* ---------- 3. Purani deduction reverse karo (FIX #3) ----------
           Band shift dobara close ho rahi hai to pehle ka asar hata do, phir naya
           daalo. Isse edit karne par stock hamesha sales ke barabar rehta hai. */
        IF @WasClosed = 1
        BEGIN
            UPDATE t
            SET t.CurrentStock = t.CurrentStock + x.Qty
            FROM PUMP.Tanks t
            INNER JOIN
            (
                SELECT TankId, SUM(CASE WHEN TxnType = 'OUT' THEN Quantity ELSE -Quantity END) AS Qty
                FROM PUMP.TankTransactions
                WHERE ReferenceNo = @ShiftRef
                GROUP BY TankId
            ) x ON x.TankId = t.Id;

            DELETE FROM PUMP.TankTransactions WHERE ReferenceNo = @ShiftRef;

            -- is shift ke auto testing-loss records bhi hata do, neeche naye banenge
            DELETE FROM PUMP.TestingLosses WHERE ShiftId = @Id AND LossType = 'SHIFT_TEST';

            EXEC PUMP.sp_Audit_Log
                @OwnerId = @OwnerId, @PumpId = @PumpId, @UserId = @UserId,
                @EntityName = 'ShiftHeaders', @EntityId = @Id, @Action = 'REOPEN_RECALC',
                @Reason = 'Closed shift edited — purani tank deduction reverse karke dobara post ki gayi';
        END

        /* ---------- 4. Pump test ka tel ----------
           Is pump par test ka tel naap kar WAPAS tank me daala jaata hai (user ne
           2026-09-04 ko confirm kiya), isliye ye nuksaan hai hi nahi — na tank se
           ghatega, na TestingLosses me darj hoga.

           Pehle yahan 'SHIFT_TEST' ki row banti thi aur tank se sale+test dono
           ghat jaate the. Us wajah se har test wale din tank me test jitna tel kam
           dikhta tha aur DSR ka closing tank se nahi milta tha.

           Kitna tel test me nikla — ye ab bhi poori tarah darj hai
           (ShiftNozzleReadings.TestingLoss), aur DSR ke "Pump Test" column me
           dikhta hai. TestingLosses table ab sirf ASLI nuksaan ke liye hai, jo
           Testing Loss form se aata hai (sp_TestingLoss_Save khud stock ghatata
           hai — wo theek hai, wahan tel wapas nahi jaata).

           Upar wala DELETE (re-close ke waqt) jaanbujh ke rakha hai, taaki is
           badlav se pehle bani hui SHIFT_TEST rows shift edit karte hi saaf ho jayen. */

        /* ---------- 5. Tank se stock nikalo ----------
           Sirf bikri (SoldQty). SoldQty pehle hi testing loss nikaal kar bana hai
           (dekho upar: closing - opening - TestingLoss), isliye yahi wo tel hai jo
           sach me tank se gaya. */
        ;WITH resolved AS
        (
            SELECT
                TankId = COALESCE(n.TankId, ft.TankId),
                Qty    = snr.SoldQty
            FROM PUMP.ShiftNozzleReadings snr
            JOIN PUMP.Nozzles n ON n.Id = snr.NozzleId
            OUTER APPLY
            (
                SELECT TankId = MIN(t.Id)
                FROM PUMP.Tanks t
                WHERE t.PumpId = @PumpId AND t.ProductId = n.ProductId AND t.IsActive = 1
            ) ft
            WHERE snr.ShiftId = @Id
              AND snr.SoldQty > 0
              /* Gas (CNG) / bijli ka stock tank me nahi naapa jaata - uska kuch ghatana nahi. */
              AND ISNULL((SELECT pr.TracksStock FROM PUMP.Products pr WHERE pr.Id = n.ProductId), 1) = 1
        ),
        perTank AS
        (
            SELECT TankId, Qty = SUM(Qty)
            FROM resolved
            WHERE TankId IS NOT NULL
            GROUP BY TankId
        )
        INSERT INTO PUMP.TankTransactions
            (OwnerId, PumpId, TankId, TxnType, Quantity, TxnDateTime, ReferenceNo, Notes, CreatedBy)
        SELECT @OwnerId, @PumpId, pt.TankId, 'OUT', pt.Qty, @TxnStamp, @ShiftRef,
               'Shift meter sale (test ka tel wapas tank me gaya)', @UserId
        FROM perTank pt
        WHERE pt.TankId IS NOT NULL;

        UPDATE t
        SET t.CurrentStock = t.CurrentStock - x.Qty
        FROM PUMP.Tanks t
        INNER JOIN
        (
            SELECT TankId, SUM(Quantity) AS Qty
            FROM PUMP.TankTransactions
            WHERE ReferenceNo = @ShiftRef AND TxnType = 'OUT'
            GROUP BY TankId
        ) x ON x.TankId = t.Id;

        /* Stock negative ho gaya to shift rokte nahi (warna operator fans jayega),
           par audit me chillate zaroor hain — matlab opening stock galat tha,
           ya purchase entry reh gayi, ya chori hui hai. */
        INSERT INTO PUMP.AuditLog (OwnerId, PumpId, UserId, EntityName, EntityId, Action, Reason, NewValues)
        SELECT @OwnerId, @PumpId, @UserId, 'Tanks', t.Id, 'NEGATIVE_STOCK',
               CONCAT('Shift ', @Id, ' band hone ke baad tank stock negative hai — purchase entry ya opening stock check karein'),
               CAST(t.CurrentStock AS NVARCHAR(50))
        FROM PUMP.Tanks t
        WHERE t.Id IN (SELECT TankId FROM PUMP.TankTransactions WHERE ReferenceNo = @ShiftRef)
          AND t.CurrentStock < 0;

        /* ---------- 6. Cash reconciliation (neeche G7 wala formula) ---------- */
        DECLARE @MeterSale DECIMAL(18,2) =
            ISNULL((SELECT SUM(SoldAmount) FROM PUMP.ShiftNozzleReadings WHERE ShiftId = @Id), 0);

        DECLARE @Credit DECIMAL(18,2) =
            ISNULL((SELECT SUM(TotalAmount) FROM PUMP.SalesHeaders
                    WHERE ShiftId = @Id AND IsVoid = 0
                      AND UPPER(ISNULL(PaymentMode,'')) = 'CREDIT'), 0);

        DECLARE @Digital DECIMAL(18,2) =
            ISNULL((SELECT SUM(TotalAmount) FROM PUMP.SalesHeaders
                    WHERE ShiftId = @Id AND IsVoid = 0
                      AND UPPER(ISNULL(PaymentMode,'')) IN ('UPI','CARD','DIGITAL','ONLINE','BANK','WALLET')), 0);

        DECLARE @Receipts DECIMAL(18,2) =
            ISNULL((SELECT SUM(Amount) FROM PUMP.PartyLedger
                    WHERE ShiftId = @Id
                      AND UPPER(EntryType) IN ('RECEIPT','PAYMENT_IN','CREDIT')
                      AND UPPER(ISNULL(PaymentMode,'CASH')) = 'CASH'), 0);

        DECLARE @CashIn DECIMAL(18,2) =
            ISNULL((SELECT SUM(Amount) FROM PUMP.CashTransactions
                    WHERE ShiftId = @Id AND UPPER(TxnType) = 'IN'), 0);

        DECLARE @CashOut DECIMAL(18,2) =
            ISNULL((SELECT SUM(Amount) FROM PUMP.CashTransactions
                    WHERE ShiftId = @Id AND UPPER(TxnType) = 'OUT'), 0);

        DECLARE @CashExp DECIMAL(18,2) =
            ISNULL((SELECT SUM(Amount) FROM PUMP.ExpenseTransactions
                    WHERE ShiftId = @Id AND UPPER(ISNULL(PaymentMode,'CASH')) = 'CASH'), 0);

        /* Bank jama: BankDeposits table + Cashbook ki BANK_DEPOSIT entry (sp_Shift_Collection_Summary bhi dono
           ginta hai). Pehle yahan sirf pehla tha, isliye Cashbook / "Aaj ki shift" se bank me jama kiya nakad
           ExpectedCash me ghatta nahi tha aur stored CashShortExcess usi rakam se galat aata tha. */
        DECLARE @Deposit DECIMAL(18,2) =
            ISNULL((SELECT SUM(Amount) FROM PUMP.BankDeposits
                    WHERE ShiftId = @Id AND IsDeleted = 0), 0)
          + ISNULL((SELECT SUM(Amount) FROM PUMP.CashTransactions
                    WHERE ShiftId = @Id AND UPPER(TxnType) = 'BANK_DEPOSIT'), 0);

        DECLARE @Expected DECIMAL(18,2) =
            @OpeningCash + @MeterSale - @Credit - @Digital + @Receipts + @CashIn - @CashOut - @CashExp - @Deposit;

        UPDATE PUMP.ShiftHeaders
        SET ClosedOn        = COALESCE(ClosedOn, SYSDATETIME()),
            ClosingCash     = COALESCE(@ClosingCash, ClosingCash),
            Notes           = COALESCE(@Notes, Notes),
            Status          = 'CLOSED',
            TotalMeterSale  = @MeterSale,
            ExpectedCash    = @Expected,
            CashShortExcess = ISNULL(COALESCE(@ClosingCash, ClosingCash), 0) - @Expected,
            ClosedByUserId  = ISNULL(@UserId, ClosedByUserId),
            ModifiedBy      = @UserId,
            ModifiedOn      = SYSDATETIME()
        WHERE Id = @Id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC PUMP.sp_Audit_Log
        @OwnerId = @OwnerId, @PumpId = @PumpId, @UserId = @UserId,
        @EntityName = 'ShiftHeaders', @EntityId = @Id, @Action = 'CLOSE';

    SELECT @Id AS Id;
END
GO
PRINT '  + AM1: sp_Shift_Close - Deposit me BANK_DEPOSIT bhi';
PRINT '=== Section AM done ===';
GO


/* ==========================================================================================
   SECTION AN — shift band hote hi galle ka nakad malik ko (2026-10-22)
   ------------------------------------------------------------------------------------------
   Owner: "galle ka nakad roz malik ke paas jaata hai, galle me Rs 0 rakho; opening = kal ki
   closing aur closing apne aap bharna - ye automatic hi rehna chahiye."

   Ab tak: closing apne aap = opening + aaj ka nakad, aur malik ko diya kahin darj nahi hota tha.
   Live par OpeningCash jud-jud kar ~Rs 1.11 crore ho gaya (19 Oct 2026).

   Ab: sp_Shift_Close khud Cashbook me "Cash given to owner (automatic at shift close)" (OUT,
   ReferenceNo 'HANDOVER-AUTO') likhta hai aur ClosingCash = 0. Agli shift 0 se shuru. Short /
   excess pehle jaisa (ExpectedCash bhi utna hi ghatta hai). sp_Shift_Reopen wo entry hatata hai.

   Kis report par asar: Cashbook me har shift ki ek OUT line. Shift list me Close Cash 0.
   Day Book se ye line bahar (AN3) - wahan shift ki bikri aati hi nahi, akela nikalna ulta dikhta.
   Dashboard, DSR, Sale/Purchase, Outstanding, Pump Comparison Cashbook nahi padhte.
   Purani band shift ki rows nahi chhuti. Baaki teeno SP hu-ba-hu pichhle jaise (AM / Y1 / Day Book).
   ========================================================================================== */
PRINT '=== Section AN: galle ka nakad malik ko (shift band par) ===';
GO

CREATE OR ALTER PROCEDURE PUMP.sp_Shift_Close
(
    @Id                 BIGINT,
    @ClosingCash        DECIMAL(18,2) = NULL,
    @Notes              NVARCHAR(500) = NULL,
    @NozzleReadingsJson NVARCHAR(MAX) = NULL,
    @UserId             BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @OwnerId BIGINT, @PumpId BIGINT, @Status NVARCHAR(30),
            @ShiftDate DATE, @OpeningCash DECIMAL(18,2), @WasClosed BIT = 0;

    SELECT TOP 1
        @OwnerId     = OwnerId,
        @PumpId      = PumpId,
        @Status      = Status,
        @ShiftDate   = ShiftDate,
        @OpeningCash = OpeningCash
    FROM PUMP.ShiftHeaders
    WHERE Id = @Id;

    IF @OwnerId IS NULL BEGIN SELECT CAST(-1 AS BIGINT) AS Id; RETURN; END
    IF ISNULL(@Status, '') NOT IN ('OPEN', 'CLOSED') BEGIN SELECT CAST(-2 AS BIGINT) AS Id; RETURN; END

    SET @WasClosed = CASE WHEN @Status = 'CLOSED' THEN 1 ELSE 0 END;

    /* FIX #4 — tank movement ki date shift ki date honi chahiye, aaj ki nahi.
       Aaj ki shift hai to asli time, warna us din ka 23:00. */
    DECLARE @TxnStamp DATETIME2(7) =
        CASE WHEN @ShiftDate = CAST(SYSDATETIME() AS DATE)
             THEN SYSDATETIME()
             ELSE DATEADD(HOUR, 23, CAST(CAST(@ShiftDate AS DATETIME2(7)) AS DATETIME2(7)))
        END;

    DECLARE @ShiftRef NVARCHAR(30) = CONCAT('SHIFT-', @Id);

    BEGIN TRY
        BEGIN TRANSACTION;

        /* ---------- 1. Readings update ---------- */
        IF @NozzleReadingsJson IS NOT NULL AND ISJSON(@NozzleReadingsJson) = 1
        BEGIN
            ;WITH cte AS
            (
                SELECT x.NozzleId, x.ClosingReading, ISNULL(x.TestingLoss, 0) AS TestingLoss
                FROM OPENJSON(@NozzleReadingsJson)
                WITH (NozzleId BIGINT '$.NozzleId',
                      ClosingReading DECIMAL(18,3) '$.ClosingReading',
                      TestingLoss DECIMAL(18,3) '$.TestingLoss') x
                WHERE ISNULL(x.NozzleId, 0) > 0
            )
            UPDATE snr
            SET snr.ClosingReading = cte.ClosingReading,
                snr.TestingLoss    = cte.TestingLoss,
                /* FIX #2 — meter rollover. Closing < Opening ka matlab totalizer
                   ghoom gaya hai, galti nahi. Nozzle ke MeterDigits se wapas jodo. */
                snr.IsRollover     = CASE WHEN cte.ClosingReading < snr.OpeningReading THEN 1 ELSE 0 END,
                snr.SoldQty        =
                    CASE
                        WHEN cte.ClosingReading >= snr.OpeningReading
                            THEN cte.ClosingReading - snr.OpeningReading
                        ELSE POWER(CAST(10 AS DECIMAL(18,3)), n.MeterDigits) - snr.OpeningReading + cte.ClosingReading
                    END
                    - cte.TestingLoss,
                snr.SoldAmount     =
                    (
                        CASE
                            WHEN cte.ClosingReading >= snr.OpeningReading
                                THEN cte.ClosingReading - snr.OpeningReading
                            ELSE POWER(CAST(10 AS DECIMAL(18,3)), n.MeterDigits) - snr.OpeningReading + cte.ClosingReading
                        END
                        - cte.TestingLoss
                    ) * snr.Rate,
                snr.UpdatedOn      = SYSDATETIME(),
                snr.ModifiedBy     = @UserId
            FROM PUMP.ShiftNozzleReadings snr
            INNER JOIN cte           ON cte.NozzleId = snr.NozzleId
            INNER JOIN PUMP.Nozzles n ON n.Id = snr.NozzleId
            WHERE snr.ShiftId = @Id;
        END

        /* ---------- 2. Validation ---------- */
        IF EXISTS (SELECT 1 FROM PUMP.ShiftNozzleReadings WHERE ShiftId = @Id AND ClosingReading IS NULL)
            THROW 50002, 'A closing reading is required for every nozzle.', 1;

        IF EXISTS (SELECT 1 FROM PUMP.ShiftNozzleReadings WHERE ShiftId = @Id AND SoldQty < 0)
            THROW 50004, 'Sold quantity is coming out negative. Check the readings or the testing loss.', 1;

        /* Rollover ke naam par bakwas value na aa jaye — ek shift me ek nozzle se
           50,000 litre se zyada realistic nahi hai. */
        IF EXISTS (SELECT 1 FROM PUMP.ShiftNozzleReadings WHERE ShiftId = @Id AND SoldQty > 50000)
            THROW 50005, 'Sold quantity is too high (over 50,000 L). Please re-check the readings.', 1;

        /* FIX #1 — har nozzle ka apna tank. Pehle TankId, na ho to product ka
           akela tank, aur agar do tank hain to saaf error. */
        IF EXISTS
        (
            SELECT 1
            FROM PUMP.ShiftNozzleReadings snr
            JOIN PUMP.Nozzles n ON n.Id = snr.NozzleId
            WHERE snr.ShiftId = @Id
              AND snr.SoldQty > 0
              AND n.TankId IS NULL
              AND ISNULL((SELECT pr.TracksStock FROM PUMP.Products pr WHERE pr.Id = n.ProductId), 1) = 1
              AND (SELECT COUNT(*) FROM PUMP.Tanks t
                   WHERE t.PumpId = @PumpId AND t.ProductId = n.ProductId AND t.IsActive = 1) <> 1
        )
            THROW 50003, 'Some nozzles have no tank set (or the product has more than one tank). Pick a tank in the Nozzle master.', 1;

        /* ---------- 3. Purani deduction reverse karo (FIX #3) ----------
           Band shift dobara close ho rahi hai to pehle ka asar hata do, phir naya
           daalo. Isse edit karne par stock hamesha sales ke barabar rehta hai. */
        IF @WasClosed = 1
        BEGIN
            UPDATE t
            SET t.CurrentStock = t.CurrentStock + x.Qty
            FROM PUMP.Tanks t
            INNER JOIN
            (
                SELECT TankId, SUM(CASE WHEN TxnType = 'OUT' THEN Quantity ELSE -Quantity END) AS Qty
                FROM PUMP.TankTransactions
                WHERE ReferenceNo = @ShiftRef
                GROUP BY TankId
            ) x ON x.TankId = t.Id;

            DELETE FROM PUMP.TankTransactions WHERE ReferenceNo = @ShiftRef;

            -- is shift ke auto testing-loss records bhi hata do, neeche naye banenge
            DELETE FROM PUMP.TestingLosses WHERE ShiftId = @Id AND LossType = 'SHIFT_TEST';

            EXEC PUMP.sp_Audit_Log
                @OwnerId = @OwnerId, @PumpId = @PumpId, @UserId = @UserId,
                @EntityName = 'ShiftHeaders', @EntityId = @Id, @Action = 'REOPEN_RECALC',
                @Reason = 'Closed shift edited — purani tank deduction reverse karke dobara post ki gayi';
        END

        /* ---------- 4. Pump test ka tel ----------
           Is pump par test ka tel naap kar WAPAS tank me daala jaata hai (user ne
           2026-09-04 ko confirm kiya), isliye ye nuksaan hai hi nahi — na tank se
           ghatega, na TestingLosses me darj hoga.

           Pehle yahan 'SHIFT_TEST' ki row banti thi aur tank se sale+test dono
           ghat jaate the. Us wajah se har test wale din tank me test jitna tel kam
           dikhta tha aur DSR ka closing tank se nahi milta tha.

           Kitna tel test me nikla — ye ab bhi poori tarah darj hai
           (ShiftNozzleReadings.TestingLoss), aur DSR ke "Pump Test" column me
           dikhta hai. TestingLosses table ab sirf ASLI nuksaan ke liye hai, jo
           Testing Loss form se aata hai (sp_TestingLoss_Save khud stock ghatata
           hai — wo theek hai, wahan tel wapas nahi jaata).

           Upar wala DELETE (re-close ke waqt) jaanbujh ke rakha hai, taaki is
           badlav se pehle bani hui SHIFT_TEST rows shift edit karte hi saaf ho jayen. */

        /* ---------- 5. Tank se stock nikalo ----------
           Sirf bikri (SoldQty). SoldQty pehle hi testing loss nikaal kar bana hai
           (dekho upar: closing - opening - TestingLoss), isliye yahi wo tel hai jo
           sach me tank se gaya. */
        ;WITH resolved AS
        (
            SELECT
                TankId = COALESCE(n.TankId, ft.TankId),
                Qty    = snr.SoldQty
            FROM PUMP.ShiftNozzleReadings snr
            JOIN PUMP.Nozzles n ON n.Id = snr.NozzleId
            OUTER APPLY
            (
                SELECT TankId = MIN(t.Id)
                FROM PUMP.Tanks t
                WHERE t.PumpId = @PumpId AND t.ProductId = n.ProductId AND t.IsActive = 1
            ) ft
            WHERE snr.ShiftId = @Id
              AND snr.SoldQty > 0
              /* Gas (CNG) / bijli ka stock tank me nahi naapa jaata - uska kuch ghatana nahi. */
              AND ISNULL((SELECT pr.TracksStock FROM PUMP.Products pr WHERE pr.Id = n.ProductId), 1) = 1
        ),
        perTank AS
        (
            SELECT TankId, Qty = SUM(Qty)
            FROM resolved
            WHERE TankId IS NOT NULL
            GROUP BY TankId
        )
        INSERT INTO PUMP.TankTransactions
            (OwnerId, PumpId, TankId, TxnType, Quantity, TxnDateTime, ReferenceNo, Notes, CreatedBy)
        SELECT @OwnerId, @PumpId, pt.TankId, 'OUT', pt.Qty, @TxnStamp, @ShiftRef,
               'Shift meter sale (test ka tel wapas tank me gaya)', @UserId
        FROM perTank pt
        WHERE pt.TankId IS NOT NULL;

        UPDATE t
        SET t.CurrentStock = t.CurrentStock - x.Qty
        FROM PUMP.Tanks t
        INNER JOIN
        (
            SELECT TankId, SUM(Quantity) AS Qty
            FROM PUMP.TankTransactions
            WHERE ReferenceNo = @ShiftRef AND TxnType = 'OUT'
            GROUP BY TankId
        ) x ON x.TankId = t.Id;

        /* Stock negative ho gaya to shift rokte nahi (warna operator fans jayega),
           par audit me chillate zaroor hain — matlab opening stock galat tha,
           ya purchase entry reh gayi, ya chori hui hai. */
        INSERT INTO PUMP.AuditLog (OwnerId, PumpId, UserId, EntityName, EntityId, Action, Reason, NewValues)
        SELECT @OwnerId, @PumpId, @UserId, 'Tanks', t.Id, 'NEGATIVE_STOCK',
               CONCAT('Shift ', @Id, ' band hone ke baad tank stock negative hai — purchase entry ya opening stock check karein'),
               CAST(t.CurrentStock AS NVARCHAR(50))
        FROM PUMP.Tanks t
        WHERE t.Id IN (SELECT TankId FROM PUMP.TankTransactions WHERE ReferenceNo = @ShiftRef)
          AND t.CurrentStock < 0;

        /* ---------- 5b. Galle ka nakad malik ko (Section AN) ----------
           Pump ka niyam: shift band hote hi galle ka saara nakad malik le jaata hai, galle me
           @KeepInDrawer (abhi Rs 0) bachta hai. Ye yahin Cashbook me OUT ki entry ban jaata hai
           (ReferenceNo 'HANDOVER-AUTO', isi shift se juda) aur ClosingCash = @KeepInDrawer.
           Neeche ka @CashOut is entry ko ginta hai, isliye ExpectedCash bhi utna hi ghatta hai -
           short / excess pehle jitna hi rehta hai. Pehle ye entry kabhi nahi banti thi, isliye
           OpeningCash roz pichhla ClosingCash hoke jud-jud kar crore tak pahunch gaya.

           @ClosingCash = handover se PEHLE galle me jitna hai (dono screen yahi bhejti hain).
           - Pehli baar band: hamesha (closing cash diya ho to).
           - Band shift dobara band (edit): sirf tab jab uski auto entry pehle se thi - purani entry
             hata kar naye hisaab se. Is section se pehle band hui shift edit ho to wahi purana
             vyavhaar: purane din ka nakad yahan se nahi badalta.
           Client me yahi rakam OperationsController.CashKeptInDrawer hai - dono saath badalna. */
        DECLARE @KeepInDrawer DECIMAL(18,2) = 0;
        DECLARE @HadAuto BIT =
            CASE WHEN EXISTS (SELECT 1 FROM PUMP.CashTransactions
                              WHERE ShiftId = @Id AND ReferenceNo = 'HANDOVER-AUTO') THEN 1 ELSE 0 END;

        IF (@WasClosed = 0 AND @ClosingCash IS NOT NULL) OR @HadAuto = 1
        BEGIN
            DECLARE @Drawer DECIMAL(18,2) =
                CASE WHEN @ClosingCash IS NOT NULL THEN @ClosingCash
                     ELSE ISNULL((SELECT ClosingCash FROM PUMP.ShiftHeaders WHERE Id = @Id), 0)
                        + ISNULL((SELECT SUM(Amount) FROM PUMP.CashTransactions
                                  WHERE ShiftId = @Id AND ReferenceNo = 'HANDOVER-AUTO'), 0)
                END;

            DELETE FROM PUMP.CashTransactions WHERE ShiftId = @Id AND ReferenceNo = 'HANDOVER-AUTO';

            IF @Drawer > @KeepInDrawer
            BEGIN
                INSERT INTO PUMP.CashTransactions
                    (OwnerId, PumpId, ShiftId, TxnType, Amount, ReferenceNo, Narration, TxnDateTime)
                VALUES
                    (@OwnerId, @PumpId, @Id, 'OUT', @Drawer - @KeepInDrawer, 'HANDOVER-AUTO',
                     'Cash given to owner (automatic at shift close)', @TxnStamp);
                SET @ClosingCash = @KeepInDrawer;
            END
            ELSE
                SET @ClosingCash = @Drawer;
        END

        /* ---------- 6. Cash reconciliation (neeche G7 wala formula) ---------- */
        DECLARE @MeterSale DECIMAL(18,2) =
            ISNULL((SELECT SUM(SoldAmount) FROM PUMP.ShiftNozzleReadings WHERE ShiftId = @Id), 0);

        DECLARE @Credit DECIMAL(18,2) =
            ISNULL((SELECT SUM(TotalAmount) FROM PUMP.SalesHeaders
                    WHERE ShiftId = @Id AND IsVoid = 0
                      AND UPPER(ISNULL(PaymentMode,'')) = 'CREDIT'), 0);

        DECLARE @Digital DECIMAL(18,2) =
            ISNULL((SELECT SUM(TotalAmount) FROM PUMP.SalesHeaders
                    WHERE ShiftId = @Id AND IsVoid = 0
                      AND UPPER(ISNULL(PaymentMode,'')) IN ('UPI','CARD','DIGITAL','ONLINE','BANK','WALLET')), 0);

        DECLARE @Receipts DECIMAL(18,2) =
            ISNULL((SELECT SUM(Amount) FROM PUMP.PartyLedger
                    WHERE ShiftId = @Id
                      AND UPPER(EntryType) IN ('RECEIPT','PAYMENT_IN','CREDIT')
                      AND UPPER(ISNULL(PaymentMode,'CASH')) = 'CASH'), 0);

        DECLARE @CashIn DECIMAL(18,2) =
            ISNULL((SELECT SUM(Amount) FROM PUMP.CashTransactions
                    WHERE ShiftId = @Id AND UPPER(TxnType) = 'IN'), 0);

        DECLARE @CashOut DECIMAL(18,2) =
            ISNULL((SELECT SUM(Amount) FROM PUMP.CashTransactions
                    WHERE ShiftId = @Id AND UPPER(TxnType) = 'OUT'), 0);

        DECLARE @CashExp DECIMAL(18,2) =
            ISNULL((SELECT SUM(Amount) FROM PUMP.ExpenseTransactions
                    WHERE ShiftId = @Id AND UPPER(ISNULL(PaymentMode,'CASH')) = 'CASH'), 0);

        /* Bank jama: BankDeposits table + Cashbook ki BANK_DEPOSIT entry (sp_Shift_Collection_Summary bhi dono
           ginta hai). Pehle yahan sirf pehla tha, isliye Cashbook / "Aaj ki shift" se bank me jama kiya nakad
           ExpectedCash me ghatta nahi tha aur stored CashShortExcess usi rakam se galat aata tha. */
        DECLARE @Deposit DECIMAL(18,2) =
            ISNULL((SELECT SUM(Amount) FROM PUMP.BankDeposits
                    WHERE ShiftId = @Id AND IsDeleted = 0), 0)
          + ISNULL((SELECT SUM(Amount) FROM PUMP.CashTransactions
                    WHERE ShiftId = @Id AND UPPER(TxnType) = 'BANK_DEPOSIT'), 0);

        DECLARE @Expected DECIMAL(18,2) =
            @OpeningCash + @MeterSale - @Credit - @Digital + @Receipts + @CashIn - @CashOut - @CashExp - @Deposit;

        UPDATE PUMP.ShiftHeaders
        SET ClosedOn        = COALESCE(ClosedOn, SYSDATETIME()),
            ClosingCash     = COALESCE(@ClosingCash, ClosingCash),
            Notes           = COALESCE(@Notes, Notes),
            Status          = 'CLOSED',
            TotalMeterSale  = @MeterSale,
            ExpectedCash    = @Expected,
            CashShortExcess = ISNULL(COALESCE(@ClosingCash, ClosingCash), 0) - @Expected,
            ClosedByUserId  = ISNULL(@UserId, ClosedByUserId),
            ModifiedBy      = @UserId,
            ModifiedOn      = SYSDATETIME()
        WHERE Id = @Id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC PUMP.sp_Audit_Log
        @OwnerId = @OwnerId, @PumpId = @PumpId, @UserId = @UserId,
        @EntityName = 'ShiftHeaders', @EntityId = @Id, @Action = 'CLOSE';

    SELECT @Id AS Id;
END
GO
PRINT '  + AN1: sp_Shift_Close - galle ka nakad malik ko (auto)';
GO

CREATE OR ALTER PROCEDURE PUMP.sp_Shift_Reopen
(
    @ShiftId BIGINT,
    @OwnerId BIGINT,
    @UserId  BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @PumpId BIGINT, @Status NVARCHAR(20);

    SELECT @PumpId = PumpId, @Status = Status
    FROM PUMP.ShiftHeaders
    WHERE Id = @ShiftId AND OwnerId = @OwnerId;

    IF @PumpId IS NULL
        THROW 50240, 'That shift was not found.', 1;

    IF UPPER(@Status) = 'OPEN'
        THROW 50241, 'This shift is already open.', 1;

    /* Us pump par pehle se koi shift khuli ho to doosri nahi khul sakti —
       sp_Shift_Open bhi yahi niyam maanta hai. */
    IF EXISTS (SELECT 1 FROM PUMP.ShiftHeaders
               WHERE OwnerId = @OwnerId AND PumpId = @PumpId
                 AND Status = 'OPEN' AND Id <> @ShiftId)
        THROW 50242, 'Another shift is already open for this pump. Close it first.', 1;

    /* Stock hil chuka ho to yun hi mat kholo. */
    IF EXISTS (SELECT 1 FROM PUMP.TankTransactions
               WHERE OwnerId = @OwnerId
                 AND ReferenceNo = CONCAT('SHIFT-', @ShiftId))
        THROW 50243, 'This shift already moved stock. Use Edit to correct the readings instead of reopening it.', 1;

    BEGIN TRANSACTION;

        /* Section AN: band karte waqt bani 'malik ko diya' wali auto entry bhi hatao - shift
           dobara band hogi to naye nakad se phir banegi. Warna wo do baar ghatti. */
        DELETE FROM PUMP.CashTransactions WHERE ShiftId = @ShiftId AND ReferenceNo = 'HANDOVER-AUTO';

        UPDATE PUMP.ShiftNozzleReadings
        SET ClosingReading = NULL,
            SoldQty        = 0,
            SoldAmount     = 0,
            /* Ye column NOT NULL hai, isliye 0 — NULL dene par Msg 515. */
            VarianceQty    = 0,
            TestingLoss    = 0,
            UpdatedOn      = SYSDATETIME(),
            ModifiedBy     = @UserId,
            ModifiedOn     = SYSDATETIME()
        WHERE ShiftId = @ShiftId;

        UPDATE PUMP.ShiftHeaders
        SET Status          = 'OPEN',
            ClosedOn        = NULL,
            ClosingCash     = NULL,
            ClosedByUserId  = NULL,
            /* Teenon NOT NULL hain — 0 kar dete hain, NULL nahi. */
            TotalMeterSale  = 0,
            ExpectedCash    = 0,
            CashShortExcess = 0,
            ModifiedBy      = @UserId,
            ModifiedOn      = SYSDATETIME()
        WHERE Id = @ShiftId AND OwnerId = @OwnerId;

    COMMIT TRANSACTION;

    /* Kisne kholi, kab — audit me nishaan chhod dete hain. */
    EXEC PUMP.sp_Audit_Log
        @OwnerId = @OwnerId, @PumpId = @PumpId, @UserId = @UserId,
        @EntityName = 'ShiftHeaders', @EntityId = @ShiftId, @Action = 'REOPEN_SHIFT',
        @Reason = N'Shift reopened (was closed without readings)';

    SELECT Reopened = 1;
END
GO
PRINT '  + AN2: sp_Shift_Reopen - auto entry bhi hatao';
GO

/* AN3: Day Book me auto "malik ko diya" nahi (upar dekho). Baaki SP hu-ba-hu pehle jaisa. */
CREATE OR ALTER PROCEDURE [PUMP].[sp_Report_DayBook]
(
    @OwnerId BIGINT,
    @PumpId BIGINT,
    @DateFrom DATE,
    @DateTo DATE
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        x.EntryDateTime,
        x.EntryType,
        x.ReferenceNo,
        x.Description,
        x.Debit,
        x.Credit
    FROM
    (
        SELECT
            sh.BillDateTime AS EntryDateTime,
            CAST('SALE' AS NVARCHAR(30)) AS EntryType,
            sh.BillNo AS ReferenceNo,
            CONCAT('Sale - ', ISNULL(sh.CustomerName, 'Walk-In')) AS Description,
            CAST(0 AS DECIMAL(18,2)) AS Debit,
            sh.TotalAmount AS Credit
        FROM PUMP.SalesHeaders sh
        WHERE sh.OwnerId = @OwnerId
          AND sh.PumpId = @PumpId
          AND CAST(sh.BillDateTime AS DATE) BETWEEN @DateFrom AND @DateTo
          AND sh.IsVoid = 0

        UNION ALL

        SELECT
            ph.CreatedOn,
            CAST('PURCHASE' AS NVARCHAR(30)),
            ph.InvoiceNo,
            CONCAT('Purchase - ', v.VendorName),
            ph.TotalAmount,
            CAST(0 AS DECIMAL(18,2))
        FROM PUMP.PurchaseHeaders ph
        INNER JOIN PUMP.Vendors v ON v.Id = ph.VendorId
        WHERE ph.OwnerId = @OwnerId
          AND ph.PumpId = @PumpId
          AND CAST(ph.CreatedOn AS DATE) BETWEEN @DateFrom AND @DateTo

        UNION ALL

        SELECT
            et.TxnDateTime,
            CAST('EXPENSE' AS NVARCHAR(30)),
            et.ReferenceNo,
            CONCAT('Expense - ', eh.HeadName),
            et.Amount,
            CAST(0 AS DECIMAL(18,2))
        FROM PUMP.ExpenseTransactions et
        INNER JOIN PUMP.ExpenseHeads eh ON eh.Id = et.ExpenseHeadId
        WHERE et.OwnerId = @OwnerId
          AND et.PumpId = @PumpId
          AND CAST(et.TxnDateTime AS DATE) BETWEEN @DateFrom AND @DateTo

        UNION ALL

        SELECT
            ct.TxnDateTime,
            CAST('CASH' AS NVARCHAR(30)),
            ct.ReferenceNo,
            CONCAT('Cash ', UPPER(ct.TxnType), ' - ', ISNULL(ct.Narration, 'Manual')),
            CASE WHEN UPPER(ct.TxnType) = 'OUT' THEN ct.Amount ELSE CAST(0 AS DECIMAL(18,2)) END,
            CASE WHEN UPPER(ct.TxnType) = 'IN' THEN ct.Amount ELSE CAST(0 AS DECIMAL(18,2)) END
        FROM PUMP.CashTransactions ct
        WHERE ct.OwnerId = @OwnerId
          AND ct.PumpId = @PumpId
          AND CAST(ct.TxnDateTime AS DATE) BETWEEN @DateFrom AND @DateTo
          /* Section AN: shift band par apne aap bana "malik ko diya" yahan nahi. Day Book me shift ki
             meter bikri aati hi nahi (sirf bill), to akela ye nikalna Debit ko ulta bada dikhata. Cashbook me hai. */
          AND ISNULL(ct.ReferenceNo, '') <> 'HANDOVER-AUTO'
    ) x
    ORDER BY x.EntryDateTime DESC;
END
GO
PRINT '  + AN3: sp_Report_DayBook - auto handover Day Book me nahi';
GO

/* AN4: shift list me asli farak (CashShortExcess) aur apne aap malik ko gaya nakad - list ka "Variance"
   pehle (closing - opening - bikri) se banta tha, jo galle me 0 bachne par poori bikri ko kam dikhata. */
CREATE OR ALTER PROCEDURE [PUMP].[sp_Shift_List]
(
    @OwnerId BIGINT,
    @PumpId BIGINT = NULL,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @SearchTerm NVARCHAR(100) = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 50
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Offset INT = (@PageNumber - 1) * @PageSize;

    ;WITH ShiftBase AS
    (
        SELECT
            sh.Id,
            sh.OwnerId,
            sh.PumpId,
            sh.OperatorUserId,
            sh.OperatorEmployeeId,
            OperatorName = COALESCE(e.FullName, u.FullName),
            sh.ShiftDate,
            sh.ShiftCode,
            sh.OpeningCash,
            sh.ClosingCash,
            sh.Notes,
            sh.OpenedOn,
            sh.ClosedOn,
            sh.Status,
            sh.CashShortExcess,
            /* Us pump par us din ki kaunsi shift — 1, 2, 3...
               Filter se pehle ginna zaroori hai: agar user ne tareekh ka filter
               lagaya ho to bhi number wahi rehna chahiye jo asal me hai. */
            /* CAST zaroori hai: ROW_NUMBER() BIGINT lautata hai, aur ShiftDto ka
               param `int` hai. Bina CAST ke Dapper record bana hi nahi paata
               aur POORI shift list 400 de deti hai (CLAUDE.md niyam 5). */
            ShiftNo = CAST(ROW_NUMBER() OVER (
                          PARTITION BY sh.PumpId, sh.ShiftDate
                          ORDER BY sh.OpenedOn, sh.Id) AS INT)
        FROM PUMP.ShiftHeaders sh
        LEFT JOIN PUMP.Employees e ON e.Id = sh.OperatorEmployeeId
        LEFT JOIN PUMP.Users     u ON u.Id = sh.OperatorUserId
        WHERE sh.OwnerId = @OwnerId
    )
    SELECT
        b.Id,
        b.OwnerId,
        b.PumpId,
        b.OperatorUserId,
        b.OperatorEmployeeId,
        b.OperatorName,
        b.ShiftDate,
        b.ShiftCode,
        b.OpeningCash,
        b.ClosingCash,
        TotalSoldQty = ISNULL(snr.TotalSoldQty, 0),
        TotalSoldAmount = ISNULL(snr.TotalSoldAmount, 0),
        b.Notes,
        b.OpenedOn,
        b.ClosedOn,
        b.Status,
        b.ShiftNo,
        /* Section AN: galle me ab 0 bachta hai, isliye list khud farak / aaya nakad nahi nikaal sakti.
           Ye dono aakhir me - ShiftDto / ShiftRow ka kram yahi hai (CLAUDE.md niyam 5). */
        b.CashShortExcess,
        CashToOwner = (SELECT SUM(ct.Amount) FROM PUMP.CashTransactions ct
                       WHERE ct.ShiftId = b.Id AND ct.ReferenceNo = 'HANDOVER-AUTO')
    FROM ShiftBase b
    OUTER APPLY
    (
        SELECT
            /* Sirf tel (litre): gas ke kg aur tel ke litre ka jod kisi kaam ka nahi. Rupaye (neeche) sab ke. */
            SUM(CASE WHEN ISNULL(pr.TracksStock, 1) = 1 THEN ISNULL(x.SoldQty, 0) ELSE 0 END) AS TotalSoldQty,
            SUM(ISNULL(x.SoldAmount, 0)) AS TotalSoldAmount
        FROM PUMP.ShiftNozzleReadings x
        LEFT JOIN PUMP.Products pr ON pr.Id = x.ProductId
        WHERE x.ShiftId = b.Id
    ) snr
    WHERE (@PumpId IS NULL OR @PumpId <= 0 OR b.PumpId = @PumpId)
      AND (@FromDate IS NULL OR b.ShiftDate >= @FromDate)
      AND (@ToDate IS NULL OR b.ShiftDate <= @ToDate)
      AND (@SearchTerm IS NULL OR @SearchTerm = '' OR b.ShiftCode LIKE '%' + @SearchTerm + '%' OR b.Notes LIKE '%' + @SearchTerm + '%')
    ORDER BY b.Id DESC
    OFFSET @Offset ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(1)
    FROM PUMP.ShiftHeaders sh
    WHERE sh.OwnerId = @OwnerId
      AND (@PumpId IS NULL OR @PumpId <= 0 OR sh.PumpId = @PumpId)
      AND (@FromDate IS NULL OR sh.ShiftDate >= @FromDate)
      AND (@ToDate IS NULL OR sh.ShiftDate <= @ToDate)
      AND (@SearchTerm IS NULL OR @SearchTerm = '' OR sh.ShiftCode LIKE '%' + @SearchTerm + '%' OR sh.Notes LIKE '%' + @SearchTerm + '%');
END
GO
PRINT '  + AN4: sp_Shift_List - CashShortExcess + CashToOwner';
GO

PRINT '=== Section AN done ===';
GO


/* ==========================================================================================
   SECTION AO — Munafa (P&L) report aur Activity Log (2026-10-22)
   ------------------------------------------------------------------------------------------
   PetroPulse360 se milaan me do kami thi (owner: "ab bacha kya hai vo banao"):

   AO1 sp_Report_ProfitLoss — dashboard ka "Net" sirf bikri - kharcha hai; tel ki kharid ghatti hi
       nahi, isliye wo munafa nahi. Ye report product-wise:
         bikri (meter, testing ke bina; bina nozzle wale product ke bill) - kharid (bechi matra x
         tanker bill ka ausat rate) = asli margin, phir kharcha aur salary ghata kar shuddh munafa.
       Kharid rate: us samay ke bill ka bhaarit ausat (Amount / Quantity). Us samay koi bill na ho to
       us din tak ka aakhri bill ('LAST'); kabhi bill hi na ho to 'NONE' - client us product ka
       margin nahi ginta aur saaf likhta hai. Dip ka ghata-badha isme nahi (DSR me hai).
       Nozzle wale product ka Sales bill meter bikri ka hi hissa hai (paisa kaise aaya) - alag nahi.

   AO2 sp_AuditLog_List — AuditLog me 2 mahine se sab likha ja raha hai (shift band / edit / hatana,
       Cashbook, party, purchase, void...), par dekhne ki koi screen nahi thi. Sirf apne owner ki.

   AO3 menu — "Profit & Loss" (Reports) aur "Activity Log" (Management). Jin role ko "Users" menu
       milta hai (owner / admin), unhi ko. Naye owner ko sp_Owner_Create saare menu deta hai.

   Sirf naye SP aur menu; koi table / purana SP nahi badla.
   ========================================================================================== */
PRINT '=== Section AO: P&L report + Activity Log ===';
GO

CREATE OR ALTER PROCEDURE PUMP.sp_Report_ProfitLoss
(
    @OwnerId  BIGINT,
    @PumpId   BIGINT,
    @DateFrom DATE,
    @DateTo   DATE
)
AS
BEGIN
    SET NOCOUNT ON;

    /* NOTE (CLAUDE.md niyam 5): ProfitLossLineDto ke param theek isi kram / type me hain. */
    ;WITH meter AS
    (
        SELECT r.ProductId, Qty = SUM(ISNULL(r.SoldQty, 0)), Amount = SUM(ISNULL(r.SoldAmount, 0))
        FROM PUMP.ShiftNozzleReadings r
        JOIN PUMP.ShiftHeaders sh ON sh.Id = r.ShiftId
        WHERE sh.OwnerId = @OwnerId AND sh.PumpId = @PumpId AND sh.Status = 'CLOSED'
          AND sh.ShiftDate BETWEEN @DateFrom AND @DateTo
        GROUP BY r.ProductId
    ),
    counterSale AS
    (
        /* Mobil / saaman: jis product ka koi nozzle hi nahi, uska bill hi uski bikri hai. */
        SELECT d.ProductId, Qty = SUM(ISNULL(d.Quantity, 0)), Amount = SUM(ISNULL(d.Amount, 0))
        FROM PUMP.SalesDetails d
        JOIN PUMP.SalesHeaders h ON h.Id = d.SalesHeaderId
        WHERE h.OwnerId = @OwnerId AND h.PumpId = @PumpId AND h.IsVoid = 0
          AND CAST(h.BillDateTime AS DATE) BETWEEN @DateFrom AND @DateTo
          AND NOT EXISTS (SELECT 1 FROM PUMP.Nozzles n WHERE n.ProductId = d.ProductId)
        GROUP BY d.ProductId
    ),
    sold AS
    (
        SELECT x.ProductId, Qty = SUM(x.Qty), Amount = SUM(x.Amount)
        FROM (SELECT ProductId, Qty, Amount FROM meter
              UNION ALL
              SELECT ProductId, Qty, Amount FROM counterSale) x
        GROUP BY x.ProductId
    ),
    costed AS
    (
        SELECT s.ProductId, s.Qty, s.Amount,
               PeriodRate = (SELECT SUM(d.Amount) / NULLIF(SUM(d.Quantity), 0)
                             FROM PUMP.PurchaseDetails d
                             JOIN PUMP.PurchaseHeaders h ON h.Id = d.PurchaseHeaderId
                             WHERE h.OwnerId = @OwnerId AND h.PumpId = @PumpId AND d.ProductId = s.ProductId
                               AND d.Quantity > 0
                               AND h.InvoiceDate BETWEEN @DateFrom AND @DateTo),
               LastRate   = (SELECT TOP 1 d.Amount / NULLIF(d.Quantity, 0)
                             FROM PUMP.PurchaseDetails d
                             JOIN PUMP.PurchaseHeaders h ON h.Id = d.PurchaseHeaderId
                             WHERE h.OwnerId = @OwnerId AND h.PumpId = @PumpId AND d.ProductId = s.ProductId
                               AND d.Quantity > 0
                               AND h.InvoiceDate <= @DateTo
                             ORDER BY h.InvoiceDate DESC, h.Id DESC)
        FROM sold s
        WHERE s.Qty <> 0 OR s.Amount <> 0
    )
    SELECT
        Section    = CAST(N'SALE' AS NVARCHAR(20)),
        SortOrder  = CAST(ROW_NUMBER() OVER (ORDER BY p.IsFuel DESC, p.Name) AS INT),
        ItemId     = CAST(c.ProductId AS BIGINT),
        Name       = CAST(p.Name AS NVARCHAR(200)),
        Unit       = CAST(p.Unit AS NVARCHAR(20)),
        Qty        = CAST(c.Qty AS DECIMAL(18,3)),
        Amount     = CAST(c.Amount AS DECIMAL(18,2)),
        CostRate   = CAST(COALESCE(c.PeriodRate, c.LastRate) AS DECIMAL(18,4)),
        CostAmount = CAST(c.Qty * COALESCE(c.PeriodRate, c.LastRate) AS DECIMAL(18,2)),
        CostSource = CAST(CASE WHEN c.PeriodRate IS NOT NULL THEN N'PERIOD'
                               WHEN c.LastRate   IS NOT NULL THEN N'LAST'
                               ELSE N'NONE' END AS NVARCHAR(10))
    FROM costed c
    JOIN PUMP.Products p ON p.Id = c.ProductId

    UNION ALL

    SELECT
        CAST(N'EXPENSE' AS NVARCHAR(20)),
        CAST(ROW_NUMBER() OVER (ORDER BY SUM(e.Amount) DESC) AS INT),
        CAST(e.ExpenseHeadId AS BIGINT),
        CAST(ISNULL(eh.HeadName, N'-') AS NVARCHAR(200)),
        CAST(NULL AS NVARCHAR(20)),
        CAST(COUNT(*) AS DECIMAL(18,3)),
        CAST(SUM(e.Amount) AS DECIMAL(18,2)),
        CAST(NULL AS DECIMAL(18,4)),
        CAST(NULL AS DECIMAL(18,2)),
        CAST(N'' AS NVARCHAR(10))
    FROM PUMP.ExpenseTransactions e
    LEFT JOIN PUMP.ExpenseHeads eh ON eh.Id = e.ExpenseHeadId
    WHERE e.OwnerId = @OwnerId AND e.PumpId = @PumpId
      AND CAST(e.TxnDateTime AS DATE) BETWEEN @DateFrom AND @DateTo
    GROUP BY e.ExpenseHeadId, eh.HeadName

    UNION ALL

    SELECT
        CAST(N'SALARY' AS NVARCHAR(20)),
        CAST(1 AS INT),
        CAST(NULL AS BIGINT),
        CAST(N'Salary' AS NVARCHAR(200)),
        CAST(NULL AS NVARCHAR(20)),
        CAST(COUNT(*) AS DECIMAL(18,3)),
        CAST(SUM(sp.Amount) AS DECIMAL(18,2)),
        CAST(NULL AS DECIMAL(18,4)),
        CAST(NULL AS DECIMAL(18,2)),
        CAST(N'' AS NVARCHAR(10))
    FROM PUMP.SalaryPayments sp
    WHERE sp.OwnerId = @OwnerId AND sp.PumpId = @PumpId
      AND sp.PaidOn BETWEEN @DateFrom AND @DateTo
    HAVING COUNT(*) > 0;
END
GO
PRINT '  + AO1: sp_Report_ProfitLoss';
GO

CREATE OR ALTER PROCEDURE PUMP.sp_AuditLog_List
(
    @OwnerId    BIGINT,
    @DateFrom   DATE,
    @DateTo     DATE,
    /* SHIFT / CASH / PARTY / STOCK / SALE / MASTER / USER - khaali = sab */
    @Area       NVARCHAR(20) = NULL,
    @PageNumber INT = 1,
    @PageSize   INT = 100
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Offset INT = (CASE WHEN @PageNumber < 1 THEN 0 ELSE @PageNumber - 1 END) * @PageSize;

    /* NOTE (CLAUDE.md niyam 5): AuditLogEntryDto ke param theek isi kram / type me hain. */
    ;WITH a AS
    (
        SELECT a.*,
               Area = CASE
                   WHEN a.EntityName IN ('ShiftHeaders', 'Shift', 'ShiftNozzleReadings') THEN 'SHIFT'
                   WHEN a.EntityName IN ('CashTransactions') THEN 'CASH'
                   WHEN a.EntityName IN ('Parties', 'Party', 'PartyLedger') THEN 'PARTY'
                   WHEN a.EntityName IN ('Tanks', 'Tank', 'TankTransactions', 'Purchase', 'StockReconciliations') THEN 'STOCK'
                   WHEN a.EntityName IN ('Sale', 'SalesHeaders') THEN 'SALE'
                   WHEN a.EntityName IN ('Users', 'Role', 'Owners', 'PaymentTransactions') THEN 'USER'
                   ELSE 'MASTER' END
        FROM PUMP.AuditLog a
        WHERE a.OwnerId = @OwnerId
          AND CAST(a.CreatedOn AS DATE) BETWEEN @DateFrom AND @DateTo
    )
    SELECT
        Id         = a.Id,
        CreatedOn  = a.CreatedOn,
        PumpId     = a.PumpId,
        UserName   = CAST(COALESCE(u.FullName, a.UserName, u.Username) AS NVARCHAR(150)),
        EntityName = CAST(a.EntityName AS NVARCHAR(100)),
        EntityId   = a.EntityId,
        Action     = CAST(a.Action AS NVARCHAR(30)),
        Reason     = CAST(LEFT(a.Reason, 500) AS NVARCHAR(500)),
        OldValues  = CAST(LEFT(a.OldValues, 300) AS NVARCHAR(300)),
        NewValues  = CAST(LEFT(a.NewValues, 300) AS NVARCHAR(300)),
        /* Kis cheez par: shift ka din + code, party ka naam - id se aadmi kuch nahi samajhta. */
        Detail     = CAST(CASE
                         WHEN sh.Id IS NOT NULL THEN CONCAT(CONVERT(VARCHAR(10), sh.ShiftDate, 23), N' · ', sh.ShiftCode)
                         WHEN pa.Id IS NOT NULL THEN pa.PartyName
                         WHEN pl.Id IS NOT NULL THEN plp.PartyName
                         ELSE NULL END AS NVARCHAR(200)),
        Area       = CAST(a.Area AS NVARCHAR(20)),
        TotalCount = COUNT(*) OVER ()
    FROM a
    LEFT JOIN PUMP.Users u         ON u.Id = a.UserId
    LEFT JOIN PUMP.ShiftHeaders sh ON a.EntityName IN ('ShiftHeaders', 'Shift') AND sh.Id = a.EntityId AND sh.OwnerId = @OwnerId
    LEFT JOIN PUMP.Parties pa      ON a.EntityName IN ('Parties', 'Party') AND pa.Id = a.EntityId AND pa.OwnerId = @OwnerId
    LEFT JOIN PUMP.PartyLedger pl  ON a.EntityName = 'PartyLedger' AND pl.Id = a.EntityId AND pl.OwnerId = @OwnerId
    LEFT JOIN PUMP.Parties plp     ON plp.Id = pl.PartyId
    WHERE (@Area IS NULL OR @Area = '' OR a.Area = @Area)
    ORDER BY a.Id DESC
    OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO
PRINT '  + AO2: sp_AuditLog_List';
GO

/* ---- AO3: menu ---- */
DECLARE @UsersMenu BIGINT = (SELECT TOP 1 Id FROM PUMP.Menus WHERE Route = '/users');
DECLARE @NewId BIGINT;

IF NOT EXISTS (SELECT 1 FROM PUMP.Menus WHERE Route = '/profit-loss')
BEGIN
    INSERT INTO PUMP.Menus (ParentId, MenuName, Route, Icon, Sequence, IsVisible, IsActive)
    VALUES (NULL, N'Profit & Loss', '/profit-loss', N'trending_up', 24, 1, 1);
    SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

    INSERT INTO PUMP.RoleMenus (RoleId, MenuId, CanView, CanCreate, CanEdit, CanDelete)
    SELECT rm.RoleId, @NewId, rm.CanView, 0, 0, 0
    FROM PUMP.RoleMenus rm
    WHERE rm.MenuId = @UsersMenu
      AND NOT EXISTS (SELECT 1 FROM PUMP.RoleMenus x WHERE x.RoleId = rm.RoleId AND x.MenuId = @NewId);
    PRINT '  + AO3: Profit & Loss ka menu bana';
END
ELSE
    PRINT '  = AO3: Profit & Loss ka menu pehle se hai';

IF NOT EXISTS (SELECT 1 FROM PUMP.Menus WHERE Route = '/activity-log')
BEGIN
    INSERT INTO PUMP.Menus (ParentId, MenuName, Route, Icon, Sequence, IsVisible, IsActive)
    VALUES (NULL, N'Activity Log', '/activity-log', N'history', 32, 1, 1);
    SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

    INSERT INTO PUMP.RoleMenus (RoleId, MenuId, CanView, CanCreate, CanEdit, CanDelete)
    SELECT rm.RoleId, @NewId, rm.CanView, 0, 0, 0
    FROM PUMP.RoleMenus rm
    WHERE rm.MenuId = @UsersMenu
      AND NOT EXISTS (SELECT 1 FROM PUMP.RoleMenus x WHERE x.RoleId = rm.RoleId AND x.MenuId = @NewId);
    PRINT '  + AO3: Activity Log ka menu bana';
END
ELSE
    PRINT '  = AO3: Activity Log ka menu pehle se hai';
GO

PRINT '=== Section AO done ===';
GO


/* ==========================================================================================
   SECTION AP — Financials: paisa kahan hai (2026-10-22)
   ------------------------------------------------------------------------------------------
   PetroPulse360 ki "Financials" jaisi ek screen - owner ke liye, sirf jo data pehle se darj hai
   usi se (koi nayi entry nahi maangti):

   POSITION (aaj ki haalat, tareekh se nahi):
     STOCK_VALUE      tank me pada tel x us product ka aakhri kharid rate (bill na ho to bikri rate)
     RECEIVABLE       party par baaki udhaar (CurrentBalance > 0) + kitni party
     ADVANCE          party ka hamare paas jama (CurrentBalance < 0)
     DRAWER_CASH      har pump ki aakhri band shift ka ClosingCash (galle me)
   FLOW (chuni tareekh me paisa kahan gaya; shift wali cheez shift ke din se, baaki apni tareekh se):
     METER_SALE, COUNTER_SALE (bina nozzle wale bill), CREDIT_GIVEN, DIGITAL (UPI / card),
     DUES_IN_CASH / DUES_IN_BANK (udhaar wapas - fn_PartyLedgerSigned ghataane wali entry, VOID nahi),
     CASH_EXPENSE / OTHER_EXPENSE, BANK_DEPOSIT (BankDeposits + Cashbook BANK_DEPOSIT),
     TO_OWNER (Cashbook OUT HANDOVER-AUTO / HANDOVER-OWNER), OTHER_CASH_OUT, CASH_IN,
     SHORT_EXCESS, PURCHASE_BILLS, SALARY
   STOCK  - har tank ki line.   RECEIVABLE_TOP - sabse zyada udhaar wali 10 party.

   Bank ka balance aur OMC ko kitna dena baaki - ye nahi, kyunki OMC / bank ko kiya bhugtaan abhi
   kahin darj hi nahi hota. Sirf naya SP aur menu; koi table / purana SP nahi badla.
   ========================================================================================== */
PRINT '=== Section AP: Financials ===';
GO

CREATE OR ALTER PROCEDURE PUMP.sp_Report_Financials
(
    @OwnerId  BIGINT,
    @PumpId   BIGINT,
    @DateFrom DATE,
    @DateTo   DATE
)
AS
BEGIN
    SET NOCOUNT ON;

    /* Shift ki tareekh se (back-dated entry ka din wahi jo shift ka). */
    DECLARE @Shifts TABLE (Id BIGINT PRIMARY KEY, ShiftDate DATE, CashShortExcess DECIMAL(18,2));
    INSERT INTO @Shifts (Id, ShiftDate, CashShortExcess)
    SELECT sh.Id, sh.ShiftDate, sh.CashShortExcess
    FROM PUMP.ShiftHeaders sh
    WHERE sh.OwnerId = @OwnerId AND sh.PumpId = @PumpId AND sh.Status = 'CLOSED'
      AND sh.ShiftDate BETWEEN @DateFrom AND @DateTo;

    DECLARE @Lines TABLE
    (
        Section   NVARCHAR(20),
        SortOrder INT,
        Name      NVARCHAR(200),
        Qty       DECIMAL(18,3) NULL,
        Rate      DECIMAL(18,4) NULL,
        Amount    DECIMAL(18,2),
        Note      NVARCHAR(30) NULL
    );

    /* ---- STOCK: har tank ---- */
    INSERT INTO @Lines (Section, SortOrder, Name, Qty, Rate, Amount, Note)
    SELECT N'STOCK',
           ROW_NUMBER() OVER (ORDER BY t.Name),
           CONCAT(t.Name, N' · ', p.Name),
           t.CurrentStock,
           COALESCE(lr.Rate, p.CurrentRate),
           t.CurrentStock * COALESCE(lr.Rate, p.CurrentRate),
           CASE WHEN lr.Rate IS NOT NULL THEN N'PURCHASE' ELSE N'SALE_RATE' END
    FROM PUMP.Tanks t
    JOIN PUMP.Products p ON p.Id = t.ProductId
    OUTER APPLY
    (
        SELECT TOP 1 Rate = d.Amount / NULLIF(d.Quantity, 0)
        FROM PUMP.PurchaseDetails d
        JOIN PUMP.PurchaseHeaders h ON h.Id = d.PurchaseHeaderId
        WHERE h.OwnerId = @OwnerId AND h.PumpId = @PumpId AND d.ProductId = t.ProductId AND d.Quantity > 0
        ORDER BY h.InvoiceDate DESC, h.Id DESC
    ) lr
    WHERE t.OwnerId = @OwnerId AND t.PumpId = @PumpId AND t.IsActive = 1 AND ISNULL(t.IsDeleted, 0) = 0;

    /* ---- RECEIVABLE_TOP: sabse bade 10 udhaar ---- */
    INSERT INTO @Lines (Section, SortOrder, Name, Qty, Rate, Amount, Note)
    SELECT TOP 10 N'RECEIVABLE_TOP',
           ROW_NUMBER() OVER (ORDER BY pa.CurrentBalance DESC),
           pa.PartyName, NULL, NULL, pa.CurrentBalance, NULL
    FROM PUMP.Parties pa
    WHERE pa.OwnerId = @OwnerId AND pa.PumpId = @PumpId AND pa.IsActive = 1 AND ISNULL(pa.IsDeleted, 0) = 0
      AND pa.CurrentBalance > 0
    ORDER BY pa.CurrentBalance DESC;

    /* ---- POSITION ---- */
    INSERT INTO @Lines (Section, SortOrder, Name, Qty, Rate, Amount, Note)
    SELECT N'POSITION', 1, N'STOCK_VALUE', NULL, NULL,
           ISNULL((SELECT SUM(Amount) FROM @Lines WHERE Section = N'STOCK'), 0), NULL;

    INSERT INTO @Lines (Section, SortOrder, Name, Qty, Rate, Amount, Note)
    SELECT N'POSITION', 2, N'RECEIVABLE',
           (SELECT COUNT(*) FROM PUMP.Parties pa
            WHERE pa.OwnerId = @OwnerId AND pa.PumpId = @PumpId AND pa.IsActive = 1 AND ISNULL(pa.IsDeleted, 0) = 0
              AND pa.CurrentBalance > 0),
           NULL,
           ISNULL((SELECT SUM(pa.CurrentBalance) FROM PUMP.Parties pa
                   WHERE pa.OwnerId = @OwnerId AND pa.PumpId = @PumpId AND pa.IsActive = 1 AND ISNULL(pa.IsDeleted, 0) = 0
                     AND pa.CurrentBalance > 0), 0),
           NULL;

    INSERT INTO @Lines (Section, SortOrder, Name, Qty, Rate, Amount, Note)
    SELECT N'POSITION', 3, N'ADVANCE', NULL, NULL,
           ISNULL((SELECT -SUM(pa.CurrentBalance) FROM PUMP.Parties pa
                   WHERE pa.OwnerId = @OwnerId AND pa.PumpId = @PumpId AND pa.IsActive = 1 AND ISNULL(pa.IsDeleted, 0) = 0
                     AND pa.CurrentBalance < 0), 0),
           NULL;

    INSERT INTO @Lines (Section, SortOrder, Name, Qty, Rate, Amount, Note)
    SELECT N'POSITION', 4, N'DRAWER_CASH', NULL, NULL,
           ISNULL((SELECT TOP 1 sh.ClosingCash FROM PUMP.ShiftHeaders sh
                   WHERE sh.OwnerId = @OwnerId AND sh.PumpId = @PumpId AND sh.Status = 'CLOSED'
                   ORDER BY sh.ShiftDate DESC, sh.Id DESC), 0),
           NULL;

    /* ---- FLOW ---- */
    DECLARE @MeterSale DECIMAL(18,2) =
        ISNULL((SELECT SUM(r.SoldAmount) FROM PUMP.ShiftNozzleReadings r JOIN @Shifts s ON s.Id = r.ShiftId), 0);

    DECLARE @CounterSale DECIMAL(18,2) =
        ISNULL((SELECT SUM(d.Amount)
                FROM PUMP.SalesDetails d
                JOIN PUMP.SalesHeaders h ON h.Id = d.SalesHeaderId
                WHERE h.OwnerId = @OwnerId AND h.PumpId = @PumpId AND h.IsVoid = 0
                  AND CAST(h.BillDateTime AS DATE) BETWEEN @DateFrom AND @DateTo
                  AND NOT EXISTS (SELECT 1 FROM PUMP.Nozzles n WHERE n.ProductId = d.ProductId)), 0);

    /* Bill ka din: shift se juda ho to shift ka din, warna bill ka. */
    DECLARE @Bills TABLE (Mode NVARCHAR(30), Amount DECIMAL(18,2));
    INSERT INTO @Bills (Mode, Amount)
    SELECT UPPER(ISNULL(h.PaymentMode, '')), h.TotalAmount
    FROM PUMP.SalesHeaders h
    LEFT JOIN PUMP.ShiftHeaders sh ON sh.Id = h.ShiftId
    WHERE h.OwnerId = @OwnerId AND h.PumpId = @PumpId AND h.IsVoid = 0
      AND COALESCE(sh.ShiftDate, CAST(h.BillDateTime AS DATE)) BETWEEN @DateFrom AND @DateTo;

    DECLARE @Dues TABLE (IsCash BIT, Amount DECIMAL(18,2));
    INSERT INTO @Dues (IsCash, Amount)
    SELECT CASE WHEN UPPER(ISNULL(pl.PaymentMode, 'CASH')) = 'CASH' THEN 1 ELSE 0 END,
           -PUMP.fn_PartyLedgerSigned(pl.EntryType, pl.Amount)
    FROM PUMP.PartyLedger pl
    LEFT JOIN PUMP.ShiftHeaders sh ON sh.Id = pl.ShiftId
    WHERE pl.OwnerId = @OwnerId AND pl.PumpId = @PumpId
      AND UPPER(pl.EntryType) <> 'VOID'
      AND PUMP.fn_PartyLedgerSigned(pl.EntryType, pl.Amount) < 0
      AND COALESCE(sh.ShiftDate, CAST(pl.EntryDateTime AS DATE)) BETWEEN @DateFrom AND @DateTo;

    DECLARE @Cash TABLE (TxnType NVARCHAR(20), Ref NVARCHAR(50), Amount DECIMAL(18,2));
    INSERT INTO @Cash (TxnType, Ref, Amount)
    SELECT UPPER(ct.TxnType), ISNULL(ct.ReferenceNo, ''), ct.Amount
    FROM PUMP.CashTransactions ct
    LEFT JOIN PUMP.ShiftHeaders sh ON sh.Id = ct.ShiftId
    WHERE ct.OwnerId = @OwnerId AND ct.PumpId = @PumpId
      AND COALESCE(sh.ShiftDate, CAST(ct.TxnDateTime AS DATE)) BETWEEN @DateFrom AND @DateTo;

    DECLARE @Exp TABLE (IsCash BIT, Amount DECIMAL(18,2));
    INSERT INTO @Exp (IsCash, Amount)
    SELECT CASE WHEN UPPER(ISNULL(e.PaymentMode, 'CASH')) = 'CASH' THEN 1 ELSE 0 END, e.Amount
    FROM PUMP.ExpenseTransactions e
    WHERE e.OwnerId = @OwnerId AND e.PumpId = @PumpId
      AND CAST(e.TxnDateTime AS DATE) BETWEEN @DateFrom AND @DateTo;

    INSERT INTO @Lines (Section, SortOrder, Name, Qty, Rate, Amount, Note)
    VALUES
        (N'FLOW',  1, N'METER_SALE',     NULL, NULL, @MeterSale, NULL),
        (N'FLOW',  2, N'COUNTER_SALE',   NULL, NULL, @CounterSale, NULL),
        (N'FLOW',  3, N'CREDIT_GIVEN',   NULL, NULL, ISNULL((SELECT SUM(Amount) FROM @Bills WHERE Mode = 'CREDIT'), 0), NULL),
        (N'FLOW',  4, N'DIGITAL',        NULL, NULL, ISNULL((SELECT SUM(Amount) FROM @Bills WHERE Mode IN ('UPI','CARD','DIGITAL','ONLINE','BANK','WALLET')), 0), NULL),
        (N'FLOW',  5, N'DUES_IN_CASH',   NULL, NULL, ISNULL((SELECT SUM(Amount) FROM @Dues WHERE IsCash = 1), 0), NULL),
        (N'FLOW',  6, N'DUES_IN_BANK',   NULL, NULL, ISNULL((SELECT SUM(Amount) FROM @Dues WHERE IsCash = 0), 0), NULL),
        (N'FLOW',  7, N'CASH_IN',        NULL, NULL, ISNULL((SELECT SUM(Amount) FROM @Cash WHERE TxnType = 'IN'), 0), NULL),
        (N'FLOW',  8, N'CASH_EXPENSE',   NULL, NULL, ISNULL((SELECT SUM(Amount) FROM @Exp WHERE IsCash = 1), 0), NULL),
        (N'FLOW',  9, N'OTHER_EXPENSE',  NULL, NULL, ISNULL((SELECT SUM(Amount) FROM @Exp WHERE IsCash = 0), 0), NULL),
        (N'FLOW', 10, N'BANK_DEPOSIT',   NULL, NULL,
             ISNULL((SELECT SUM(Amount) FROM @Cash WHERE TxnType = 'BANK_DEPOSIT'), 0)
           + ISNULL((SELECT SUM(bd.Amount) FROM PUMP.BankDeposits bd
                     LEFT JOIN PUMP.ShiftHeaders sh ON sh.Id = bd.ShiftId
                     WHERE bd.OwnerId = @OwnerId AND bd.PumpId = @PumpId AND bd.IsDeleted = 0
                       AND COALESCE(sh.ShiftDate, bd.DepositDate) BETWEEN @DateFrom AND @DateTo), 0), NULL),
        (N'FLOW', 11, N'TO_OWNER',       NULL, NULL, ISNULL((SELECT SUM(Amount) FROM @Cash WHERE TxnType = 'OUT' AND Ref IN ('HANDOVER-AUTO', 'HANDOVER-OWNER')), 0), NULL),
        (N'FLOW', 12, N'OTHER_CASH_OUT', NULL, NULL, ISNULL((SELECT SUM(Amount) FROM @Cash WHERE TxnType = 'OUT' AND Ref NOT IN ('HANDOVER-AUTO', 'HANDOVER-OWNER')), 0), NULL),
        (N'FLOW', 13, N'SHORT_EXCESS',   NULL, NULL, ISNULL((SELECT SUM(CashShortExcess) FROM @Shifts), 0), NULL),
        (N'FLOW', 14, N'PURCHASE_BILLS', NULL, NULL,
             ISNULL((SELECT SUM(h.TotalAmount) FROM PUMP.PurchaseHeaders h
                     WHERE h.OwnerId = @OwnerId AND h.PumpId = @PumpId
                       AND h.InvoiceDate BETWEEN @DateFrom AND @DateTo), 0), NULL),
        (N'FLOW', 15, N'SALARY',         NULL, NULL,
             ISNULL((SELECT SUM(sp.Amount) FROM PUMP.SalaryPayments sp
                     WHERE sp.OwnerId = @OwnerId AND sp.PumpId = @PumpId
                       AND sp.PaidOn BETWEEN @DateFrom AND @DateTo), 0), NULL);

    /* NOTE (CLAUDE.md niyam 5): FinancialLineDto ke param theek isi kram / type me hain. */
    SELECT Section   = CAST(Section AS NVARCHAR(20)),
           SortOrder = CAST(SortOrder AS INT),
           Name      = CAST(Name AS NVARCHAR(200)),
           Qty       = CAST(Qty AS DECIMAL(18,3)),
           Rate      = CAST(Rate AS DECIMAL(18,4)),
           Amount    = CAST(Amount AS DECIMAL(18,2)),
           Note      = CAST(Note AS NVARCHAR(30))
    FROM @Lines
    ORDER BY Section, SortOrder;
END
GO
PRINT '  + AP1: sp_Report_Financials';
GO

/* ---- AP2: menu - jinhe "Users" milta hai (owner / admin) ---- */
IF NOT EXISTS (SELECT 1 FROM PUMP.Menus WHERE Route = '/financials')
BEGIN
    DECLARE @UsersMenu BIGINT = (SELECT TOP 1 Id FROM PUMP.Menus WHERE Route = '/users');
    INSERT INTO PUMP.Menus (ParentId, MenuName, Route, Icon, Sequence, IsVisible, IsActive)
    VALUES (NULL, N'Financials', '/financials', N'account_balance', 24, 1, 1);
    DECLARE @NewId BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);

    INSERT INTO PUMP.RoleMenus (RoleId, MenuId, CanView, CanCreate, CanEdit, CanDelete)
    SELECT rm.RoleId, @NewId, rm.CanView, 0, 0, 0
    FROM PUMP.RoleMenus rm
    WHERE rm.MenuId = @UsersMenu
      AND NOT EXISTS (SELECT 1 FROM PUMP.RoleMenus x WHERE x.RoleId = rm.RoleId AND x.MenuId = @NewId);
    PRINT '  + AP2: Financials ka menu bana';
END
ELSE
    PRINT '  = AP2: Financials ka menu pehle se hai';
GO

PRINT '=== Section AP done ===';
GO


/* ==========================================================================================
   SECTION AQ — Udhaar parchi me tel + matra, ek jaisi udhaar par chetavni, karmchari ka advance
                (2026-10-23)
   ------------------------------------------------------------------------------------------
   Owner ne PetroPulse360 ke milaan me ye teen maange ("3 4 5 ye teen kaam karo"):

   AQ1-3  Udhaar parchi me kaunsa tel aur kitna (litre / kg). "Aaj ki shift" me litre likhne ka
          khaana pehle se tha par sirf rakam save hoti thi. Ab SalesHeaders.SlipProductId / SlipQty
          (SalesDetails me NAHI - use P&L, raseed, void padhte hain; matra wahan jaati to dobara
          ginti). Party ke khaate ke Notes me "20.00 L Diesel" bhi.
   AQ4    sp_Credit_FindDuplicates - wahi party, wahi din, wahi rakam ki udhaar pehle se ho to
          batata hai (screen chetavni deti hai, rokti nahi). Isi shift ki apni COLL- entry aur
          void bill ki entry nahi ginti.
   AQ5-6  EmployeeAdvances: advance diya (GIVEN), wapas mila (RETURNED), salary me se kata
          (SALARY_CUT, salary payment se juda). sp_Salary_Summary - mahine ki salary, diya,
          kata, baaki salary aur baaki advance.
   AQ7    P&L me salary = nakad diya + advance se kata.

   Purana koi data nahi badla: do NULL column, ek nayi table, naye SP; teen SP (collection get /
   save, P&L) me sirf jodna.
   ========================================================================================== */
PRINT '=== Section AQ: parchi me tel + matra, udhaar duplicate, advance ===';
GO

IF COL_LENGTH('PUMP.SalesHeaders', 'SlipProductId') IS NULL
    ALTER TABLE PUMP.SalesHeaders ADD SlipProductId BIGINT NULL;
IF COL_LENGTH('PUMP.SalesHeaders', 'SlipQty') IS NULL
    ALTER TABLE PUMP.SalesHeaders ADD SlipQty DECIMAL(18,3) NULL;
GO
PRINT '  + AQ1: SalesHeaders.SlipProductId, SlipQty';
GO

CREATE OR ALTER PROCEDURE PUMP.sp_ShiftCollection_Get
(
    @ShiftId BIGINT,
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.ShiftHeaders WHERE Id = @ShiftId AND OwnerId = @OwnerId)
        THROW 50230, 'That shift was not found.', 1;

    /* Pehli row: UPI aur Card ka jod */
    SELECT
        UpiAmount  = ISNULL(SUM(CASE WHEN UPPER(PaymentMode) IN ('UPI','WALLET') THEN TotalAmount END), 0),
        CardAmount = ISNULL(SUM(CASE WHEN UPPER(PaymentMode) = 'CARD' THEN TotalAmount END), 0)
    FROM PUMP.SalesHeaders
    WHERE ShiftId = @ShiftId AND OwnerId = @OwnerId AND IsVoid = 0
      AND BillNo LIKE 'COLL-%';

    /* Doosri row-set: udhaar ki har parchi. Column ka kram C# ke
       ShiftCollectionCreditRow jaisa hi rakhna (CLAUDE.md niyam 5). */
    SELECT
        h.PartyId,
        PartyName = p.PartyName,
        Amount    = h.TotalAmount,
        h.VehicleNo,
        h.SlipNote,
        /* Section AQ: parchi ka tel aur matra. API ye naam se padhti hai (purane SP par null). */
        ProductId   = h.SlipProductId,
        ProductName = pr.Name,
        Quantity    = h.SlipQty,
        Unit        = pr.Unit
    FROM PUMP.SalesHeaders h
    JOIN PUMP.Parties p ON p.Id = h.PartyId
    LEFT JOIN PUMP.Products pr ON pr.Id = h.SlipProductId
    WHERE h.ShiftId = @ShiftId AND h.OwnerId = @OwnerId AND h.IsVoid = 0
      AND h.BillNo LIKE 'COLL-%'
      AND UPPER(h.PaymentMode) = 'CREDIT'
    ORDER BY h.Id;
END
GO
PRINT '  + AQ2: sp_ShiftCollection_Get (tel + matra)';
GO

CREATE OR ALTER PROCEDURE PUMP.sp_ShiftCollection_Save
(
    @ShiftId     BIGINT,
    @OwnerId     BIGINT,
    @UpiAmount   DECIMAL(18,2) = 0,
    @CardAmount  DECIMAL(18,2) = 0,
    @CreditJson  NVARCHAR(MAX) = NULL,   -- [{"PartyId":1,"Amount":300,"VehicleNo":"UP32AB1234","SlipNote":"..","ProductId":4,"Quantity":20}, ...]
    @UserId      BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @PumpId BIGINT, @ShiftDate DATE;

    SELECT @PumpId = PumpId, @ShiftDate = ShiftDate
    FROM PUMP.ShiftHeaders
    WHERE Id = @ShiftId AND OwnerId = @OwnerId;

    IF @PumpId IS NULL
        THROW 50230, 'That shift was not found.', 1;

    SET @UpiAmount  = ISNULL(@UpiAmount, 0);
    SET @CardAmount = ISNULL(@CardAmount, 0);

    IF @UpiAmount < 0 OR @CardAmount < 0
        THROW 50231, 'Amount cannot be negative.', 1;

    /* Parchi likhne ke kram me (Seq) — BillNo ka kram yahi se. */
    DECLARE @Credit TABLE
    (
        Seq       INT IDENTITY(1,1),
        PartyId   BIGINT,
        Amount    DECIMAL(18,2),
        VehicleNo NVARCHAR(30) NULL,
        SlipNote  NVARCHAR(150) NULL,
        ProductId BIGINT NULL,
        Quantity  DECIMAL(18,3) NULL
    );

    IF @CreditJson IS NOT NULL AND ISJSON(@CreditJson) = 1
    BEGIN
        INSERT INTO @Credit (PartyId, Amount, VehicleNo, SlipNote, ProductId, Quantity)
        SELECT x.PartyId, x.Amount,
               NULLIF(LEFT(UPPER(LTRIM(RTRIM(x.VehicleNo))), 30), N''),
               NULLIF(LEFT(LTRIM(RTRIM(x.SlipNote)), 150), N''),
               NULLIF(x.ProductId, 0),
               CASE WHEN x.Quantity > 0 THEN x.Quantity END
        FROM OPENJSON(@CreditJson) j
        CROSS APPLY OPENJSON(j.value)
        WITH (PartyId   BIGINT        '$.PartyId',
              Amount    DECIMAL(18,2) '$.Amount',
              VehicleNo NVARCHAR(100) '$.VehicleNo',
              SlipNote  NVARCHAR(400) '$.SlipNote',
              ProductId BIGINT        '$.ProductId',
              Quantity  DECIMAL(18,3) '$.Quantity') x
        WHERE ISNULL(x.PartyId, 0) > 0 AND ISNULL(x.Amount, 0) > 0
        ORDER BY CAST(j.[key] AS INT);

        /* Party usi owner ki honi chahiye. Doosre tenant ki party ki id daal kar
           uske khaate me entry na ho jaye. */
        IF EXISTS (SELECT 1 FROM @Credit c
                   WHERE NOT EXISTS (SELECT 1 FROM PUMP.Parties p
                                     WHERE p.Id = c.PartyId AND p.OwnerId = @OwnerId
                                       AND ISNULL(p.IsDeleted, 0) = 0))
            THROW 50232, 'One of the credit customers does not belong to your account.', 1;

        /* Section AQ: parchi ka tel isi pump ka ho - doosre pump / tenant ka product nahi. */
        IF EXISTS (SELECT 1 FROM @Credit c
                   WHERE c.ProductId IS NOT NULL
                     AND NOT EXISTS (SELECT 1 FROM PUMP.Products pr
                                     WHERE pr.Id = c.ProductId AND pr.OwnerId = @OwnerId AND pr.PumpId = @PumpId))
            THROW 50233, 'Pick a product of this pump for the credit slip.', 1;
    END

    DECLARE @Stamp DATETIME2(7) = DATEADD(HOUR, 20, CAST(@ShiftDate AS DATETIME2(7)));

    BEGIN TRANSACTION;

        /* Purani COLL- entry saaf — pehle purana udhaar party ke khaate se ghatao,
           warna dobara save karne par wahi udhaar do baar jud jaata (Section W). */
        UPDATE p
        SET p.CurrentBalance = ISNULL(p.CurrentBalance, 0) - old.Amount
        FROM PUMP.Parties p
        JOIN (
            SELECT PartyId, Amount = SUM(TotalAmount)
            FROM PUMP.SalesHeaders
            WHERE ShiftId = @ShiftId AND OwnerId = @OwnerId AND IsVoid = 0
              AND BillNo LIKE 'COLL-%' AND UPPER(PaymentMode) = 'CREDIT'
              AND PartyId IS NOT NULL
            GROUP BY PartyId
        ) old ON old.PartyId = p.Id;

        DELETE FROM PUMP.PartyLedger
        WHERE ShiftId = @ShiftId AND OwnerId = @OwnerId
          AND ReferenceNo LIKE 'COLL-%';

        DELETE FROM PUMP.SalesHeaders
        WHERE ShiftId = @ShiftId AND OwnerId = @OwnerId
          AND BillNo LIKE 'COLL-%';

        IF @UpiAmount > 0
            INSERT INTO PUMP.SalesHeaders
                (OwnerId, PumpId, ShiftId, PartyId, BillNo, BillDateTime, PaymentMode,
                 CustomerName, TotalAmount, IsVoid, IsInterState, CreatedBy)
            VALUES
                (@OwnerId, @PumpId, @ShiftId, NULL,
                 CONCAT('COLL-', @ShiftId, '-UPI'), @Stamp, 'UPI',
                 N'Online (day total)', @UpiAmount, 0, 0, @UserId);

        IF @CardAmount > 0
            INSERT INTO PUMP.SalesHeaders
                (OwnerId, PumpId, ShiftId, PartyId, BillNo, BillDateTime, PaymentMode,
                 CustomerName, TotalAmount, IsVoid, IsInterState, CreatedBy)
            VALUES
                (@OwnerId, @PumpId, @ShiftId, NULL,
                 CONCAT('COLL-', @ShiftId, '-CARD'), @Stamp, 'CARD',
                 N'Card (day total)', @CardAmount, 0, 0, @UserId);

        /* Udhaar — har parchi ki apni row, Seq ke kram me */
        INSERT INTO PUMP.SalesHeaders
            (OwnerId, PumpId, ShiftId, PartyId, BillNo, BillDateTime, PaymentMode,
             VehicleNo, CustomerName, TotalAmount, IsVoid, IsInterState, CreatedBy, SlipNote,
             SlipProductId, SlipQty)
        SELECT
            @OwnerId, @PumpId, @ShiftId, c.PartyId,
            CONCAT('COLL-', @ShiftId, '-CR-', c.PartyId, '-', c.Seq), @Stamp, 'CREDIT',
            c.VehicleNo, p.PartyName, c.Amount, 0, 0, @UserId, c.SlipNote,
            c.ProductId, CASE WHEN c.ProductId IS NOT NULL THEN c.Quantity END
        FROM @Credit c
        JOIN PUMP.Parties p ON p.Id = c.PartyId
        ORDER BY c.Seq;

        /* Party ka khaata — gaadi number aur note bhi, taaki party ke hisaab me
           dikhe ki kaunsi gaadi ne kitna liya. */
        INSERT INTO PUMP.PartyLedger
            (OwnerId, PumpId, PartyId, EntryType, Amount, EntryDateTime,
             ReferenceNo, Notes, ShiftId, PaymentMode, CreatedBy)
        SELECT
            @OwnerId, @PumpId, c.PartyId, 'SALE', c.Amount, @Stamp,
            CONCAT('COLL-', @ShiftId, '-CR-', c.PartyId, '-', c.Seq),
            CONCAT(N'Credit given during the shift',
                   N' · ' + c.VehicleNo,
                   /* Section AQ: "20.00 L Diesel" - party ke khaate me dikhe kitna tel liya. */
                   N' · ' + CASE WHEN c.ProductId IS NOT NULL AND c.Quantity IS NOT NULL
                                 THEN CONCAT(FORMAT(c.Quantity, 'N2'), N' ',
                                             CASE WHEN pr.Unit IN (N'Kg', N'kg', N'किलो') THEN N'kg'
                                                  WHEN pr.Unit = N'kWh' THEN N'kWh'
                                                  WHEN pr.Unit IN (N'Piece', N'नग') THEN N'pcs'
                                                  ELSE N'L' END,
                                             N' ', pr.Name) END,
                   N' · ' + c.SlipNote),
            @ShiftId, 'CREDIT', @UserId
        FROM @Credit c
        LEFT JOIN PUMP.Products pr ON pr.Id = c.ProductId
        ORDER BY c.Seq;

        UPDATE p
        SET p.CurrentBalance = ISNULL(p.CurrentBalance, 0) + x.Amount
        FROM PUMP.Parties p
        JOIN (SELECT PartyId, Amount = SUM(Amount) FROM @Credit GROUP BY PartyId) x
          ON x.PartyId = p.Id;

    COMMIT TRANSACTION;

    SELECT Saved = 1;
END
GO
PRINT '  + AQ3: sp_ShiftCollection_Save (tel + matra)';
GO

CREATE OR ALTER PROCEDURE PUMP.sp_Credit_FindDuplicates
(
    @OwnerId   BIGINT,
    @ShiftId   BIGINT = NULL,       -- shift ki parchi: din shift ka, aur isi shift ki apni entry nahi
    @EntryDate DATE   = NULL,       -- bina shift (party khaata): ye din
    @LinesJson NVARCHAR(MAX)        -- [{"PartyId":1,"Amount":500}, ...]
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Day DATE = @EntryDate;
    IF @ShiftId IS NOT NULL
        SELECT @Day = ShiftDate FROM PUMP.ShiftHeaders WHERE Id = @ShiftId AND OwnerId = @OwnerId;

    DECLARE @Lines TABLE (PartyId BIGINT, Amount DECIMAL(18,2));
    IF @Day IS NOT NULL AND ISJSON(@LinesJson) = 1
        INSERT INTO @Lines (PartyId, Amount)
        SELECT DISTINCT x.PartyId, x.Amount
        FROM OPENJSON(@LinesJson) WITH (PartyId BIGINT '$.PartyId', Amount DECIMAL(18,2) '$.Amount') x
        WHERE ISNULL(x.PartyId, 0) > 0 AND ISNULL(x.Amount, 0) > 0;

    /* NOTE (CLAUDE.md niyam 5): CreditDuplicateDto ke param theek isi kram / type me hain. */
    SELECT
        PartyId     = CAST(pl.PartyId AS BIGINT),
        PartyName   = CAST(p.PartyName AS NVARCHAR(200)),
        Amount      = CAST(pl.Amount AS DECIMAL(18,2)),
        EntryDate   = CAST(COALESCE(sh.ShiftDate, CAST(pl.EntryDateTime AS DATE)) AS DATE),
        ReferenceNo = CAST(pl.ReferenceNo AS NVARCHAR(50)),
        Notes       = CAST(LEFT(pl.Notes, 300) AS NVARCHAR(300))
    FROM @Lines l
    JOIN PUMP.PartyLedger pl ON pl.PartyId = l.PartyId AND pl.Amount = l.Amount AND pl.OwnerId = @OwnerId
    JOIN PUMP.Parties p      ON p.Id = pl.PartyId
    LEFT JOIN PUMP.ShiftHeaders sh ON sh.Id = pl.ShiftId
    WHERE UPPER(pl.EntryType) IN ('SALE', 'DEBIT', 'CHARGE')
      AND COALESCE(sh.ShiftDate, CAST(pl.EntryDateTime AS DATE)) = @Day
      AND NOT (@ShiftId IS NOT NULL AND ISNULL(pl.ShiftId, 0) = @ShiftId AND ISNULL(pl.ReferenceNo, '') LIKE 'COLL-%')
      AND NOT EXISTS (SELECT 1 FROM PUMP.SalesHeaders h
                      WHERE h.OwnerId = @OwnerId AND h.BillNo = pl.ReferenceNo AND h.IsVoid = 1)
    ORDER BY p.PartyName, pl.Id;
END
GO
PRINT '  + AQ4: sp_Credit_FindDuplicates';
GO

IF OBJECT_ID('PUMP.EmployeeAdvances', 'U') IS NULL
BEGIN
    CREATE TABLE PUMP.EmployeeAdvances
    (
        Id              BIGINT        IDENTITY(1,1) NOT NULL,
        OwnerId         BIGINT        NOT NULL,
        PumpId          BIGINT        NOT NULL,
        EmployeeId      BIGINT        NOT NULL,
        -- GIVEN = advance diya, RETURNED = nakad wapas mila, SALARY_CUT = salary me se kata
        EntryType       NVARCHAR(12)  NOT NULL,
        Amount          DECIMAL(18,2) NOT NULL,
        EntryDate       DATE          NOT NULL,
        PaymentMode     NVARCHAR(20)  NULL,
        SalaryPaymentId BIGINT        NULL,
        Notes           NVARCHAR(250) NULL,
        IsDeleted       BIT           NOT NULL CONSTRAINT DF_EmpAdv_IsDeleted DEFAULT (0),
        CreatedOn       DATETIME2(7)  NOT NULL CONSTRAINT DF_EmpAdv_CreatedOn DEFAULT (SYSDATETIME()),
        CreatedBy       BIGINT        NULL,
        CONSTRAINT PK_EmployeeAdvances PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_EmpAdv_Employee FOREIGN KEY (EmployeeId) REFERENCES PUMP.Employees(Id),
        CONSTRAINT CK_EmpAdv_Type CHECK (EntryType IN ('GIVEN', 'RETURNED', 'SALARY_CUT')),
        CONSTRAINT CK_EmpAdv_Amount CHECK (Amount > 0)
    );
    CREATE INDEX IX_EmpAdv_Employee ON PUMP.EmployeeAdvances (EmployeeId, IsDeleted);
    PRINT '  + AQ5: table PUMP.EmployeeAdvances';
END
ELSE
    PRINT '  = AQ5: table PUMP.EmployeeAdvances pehle se hai';
GO

/* Ek karmchari ka baaki advance: diya - wapas mila - salary se kata. */
CREATE OR ALTER FUNCTION PUMP.fn_EmployeeAdvanceBalance (@EmployeeId BIGINT)
RETURNS DECIMAL(18,2)
AS
BEGIN
    RETURN ISNULL((SELECT SUM(CASE WHEN EntryType = 'GIVEN' THEN Amount ELSE -Amount END)
                   FROM PUMP.EmployeeAdvances
                   WHERE EmployeeId = @EmployeeId AND IsDeleted = 0), 0);
END
GO

CREATE OR ALTER PROCEDURE PUMP.sp_EmployeeAdvance_Save
(
    @OwnerId     BIGINT,
    @PumpId      BIGINT,
    @EmployeeId  BIGINT,
    @EntryType   NVARCHAR(12),      -- GIVEN / RETURNED (SALARY_CUT sirf salary se)
    @Amount      DECIMAL(18,2),
    @EntryDate   DATE,
    @PaymentMode NVARCHAR(20) = NULL,
    @Notes       NVARCHAR(250) = NULL,
    @UserId      BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM PUMP.Employees
                   WHERE Id = @EmployeeId AND OwnerId = @OwnerId AND PumpId = @PumpId AND ISNULL(IsDeleted, 0) = 0)
        THROW 50152, 'Employee not found, or the employee does not belong to this pump.', 1;
    IF @EntryType NOT IN ('GIVEN', 'RETURNED')
        THROW 50160, 'Pick whether the advance was given or returned.', 1;
    IF ISNULL(@Amount, 0) <= 0
        THROW 50161, 'Enter the amount.', 1;
    IF @EntryType = 'RETURNED' AND @Amount > PUMP.fn_EmployeeAdvanceBalance(@EmployeeId)
        THROW 50162, 'More is being returned than the advance this employee has.', 1;

    INSERT INTO PUMP.EmployeeAdvances (OwnerId, PumpId, EmployeeId, EntryType, Amount, EntryDate, PaymentMode, Notes, CreatedBy)
    VALUES (@OwnerId, @PumpId, @EmployeeId, @EntryType, @Amount, @EntryDate, NULLIF(@PaymentMode, N''), NULLIF(@Notes, N''), @UserId);
    DECLARE @Id BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);

    DECLARE @Reason NVARCHAR(500) = CONCAT(@EntryType, ' Rs ', @Amount, ISNULL(' - ' + NULLIF(@Notes, N''), ''));
    EXEC PUMP.sp_Audit_Log @OwnerId = @OwnerId, @PumpId = @PumpId, @UserId = @UserId,
         @EntityName = 'EmployeeAdvances', @EntityId = @Id, @Action = 'CREATE', @Reason = @Reason;

    SELECT @Id AS Id;
END
GO

CREATE OR ALTER PROCEDURE PUMP.sp_EmployeeAdvance_Delete
(
    @Id      BIGINT,
    @OwnerId BIGINT,
    @UserId  BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PumpId BIGINT, @Type NVARCHAR(12), @EmployeeId BIGINT, @Amount DECIMAL(18,2);
    SELECT @PumpId = PumpId, @Type = EntryType, @EmployeeId = EmployeeId, @Amount = Amount
    FROM PUMP.EmployeeAdvances WHERE Id = @Id AND OwnerId = @OwnerId AND IsDeleted = 0;

    IF @PumpId IS NULL
        THROW 50163, 'That advance entry was not found.', 1;
    IF @Type = 'SALARY_CUT'
        THROW 50164, 'This was cut from a salary - change it on that salary payment.', 1;
    /* Diya hua advance hataane se baaki minus me na jaye (wapas / kata pehle se ho). */
    IF @Type = 'GIVEN' AND PUMP.fn_EmployeeAdvanceBalance(@EmployeeId) - @Amount < 0
        THROW 50165, 'Part of this advance is already returned or cut from salary. Remove those first.', 1;

    UPDATE PUMP.EmployeeAdvances SET IsDeleted = 1 WHERE Id = @Id AND OwnerId = @OwnerId;

    EXEC PUMP.sp_Audit_Log @OwnerId = @OwnerId, @PumpId = @PumpId, @UserId = @UserId,
         @EntityName = 'EmployeeAdvances', @EntityId = @Id, @Action = 'DELETE';

    SELECT Deleted = 1;
END
GO

CREATE OR ALTER PROCEDURE PUMP.sp_EmployeeAdvance_List
(
    @OwnerId BIGINT,
    @PumpId  BIGINT,
    @Top     INT = 50
)
AS
BEGIN
    SET NOCOUNT ON;
    /* NOTE (CLAUDE.md niyam 5): EmployeeAdvanceDto ke param theek isi kram / type me hain. */
    SELECT TOP (@Top)
        Id              = a.Id,
        EmployeeId      = a.EmployeeId,
        EmployeeName    = CAST(e.FullName AS NVARCHAR(200)),
        EntryType       = CAST(a.EntryType AS NVARCHAR(12)),
        Amount          = a.Amount,
        EntryDate       = a.EntryDate,
        PaymentMode     = CAST(a.PaymentMode AS NVARCHAR(20)),
        Notes           = CAST(a.Notes AS NVARCHAR(250)),
        SalaryPaymentId = a.SalaryPaymentId
    FROM PUMP.EmployeeAdvances a
    JOIN PUMP.Employees e ON e.Id = a.EmployeeId
    WHERE a.OwnerId = @OwnerId AND a.PumpId = @PumpId AND a.IsDeleted = 0
    ORDER BY a.EntryDate DESC, a.Id DESC;
END
GO

/* Salary payment ke saath "advance me se kata" - us payment ki purani kati entry hata kar nayi. */
CREATE OR ALTER PROCEDURE PUMP.sp_SalaryPayment_SetAdvanceCut
(
    @OwnerId         BIGINT,
    @PumpId          BIGINT,
    @SalaryPaymentId BIGINT,
    @Amount          DECIMAL(18,2),
    @UserId          BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @EmployeeId BIGINT, @PaidOn DATE, @Year INT, @Month INT;
    SELECT @EmployeeId = EmployeeId, @PaidOn = PaidOn, @Year = SalaryYear, @Month = SalaryMonth
    FROM PUMP.SalaryPayments
    WHERE Id = @SalaryPaymentId AND OwnerId = @OwnerId AND PumpId = @PumpId;

    IF @EmployeeId IS NULL
        THROW 50166, 'That salary payment was not found.', 1;

    SET @Amount = ISNULL(@Amount, 0);
    IF @Amount < 0
        THROW 50161, 'Enter the amount.', 1;

    BEGIN TRANSACTION;
        UPDATE PUMP.EmployeeAdvances SET IsDeleted = 1
        WHERE SalaryPaymentId = @SalaryPaymentId AND EntryType = 'SALARY_CUT' AND IsDeleted = 0;

        IF @Amount > PUMP.fn_EmployeeAdvanceBalance(@EmployeeId)
            THROW 50167, 'More is being cut than the advance this employee has.', 1;

        IF @Amount > 0
            INSERT INTO PUMP.EmployeeAdvances (OwnerId, PumpId, EmployeeId, EntryType, Amount, EntryDate, SalaryPaymentId, Notes, CreatedBy)
            VALUES (@OwnerId, @PumpId, @EmployeeId, 'SALARY_CUT', @Amount, @PaidOn, @SalaryPaymentId,
                    CONCAT(N'Cut from salary ', RIGHT('0' + CAST(@Month AS VARCHAR(2)), 2), '/', @Year), @UserId);
    COMMIT TRANSACTION;

    SELECT Saved = 1;
END
GO

/* Mahine ka hisaab: har karmchari ki salary, diya (nakad), advance se kata, baaki salary, baaki advance. */
CREATE OR ALTER PROCEDURE PUMP.sp_Salary_Summary
(
    @OwnerId BIGINT,
    @PumpId  BIGINT,
    @Year    INT,
    @Month   INT
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @MonthEnd DATE = EOMONTH(DATEFROMPARTS(@Year, @Month, 1));

    /* NOTE (CLAUDE.md niyam 5): SalarySummaryDto ke param theek isi kram / type me hain. */
    SELECT
        EmployeeId         = e.Id,
        EmployeeCode       = CAST(e.EmployeeCode AS NVARCHAR(30)),
        FullName           = CAST(e.FullName AS NVARCHAR(200)),
        MonthlySalary      = CAST(ISNULL(e.MonthlySalary, 0) AS DECIMAL(18,2)),
        Paid               = CAST(ISNULL(sp.Amount, 0) AS DECIMAL(18,2)),
        AdvanceCut         = CAST(ISNULL(cut.Amount, 0) AS DECIMAL(18,2)),
        Pending            = CAST(CASE WHEN ISNULL(e.MonthlySalary, 0) > 0
                                       THEN ISNULL(e.MonthlySalary, 0) - ISNULL(sp.Amount, 0) - ISNULL(cut.Amount, 0)
                                       ELSE 0 END AS DECIMAL(18,2)),
        AdvanceOutstanding = CAST(PUMP.fn_EmployeeAdvanceBalance(e.Id) AS DECIMAL(18,2)),
        SalaryPaymentId    = sp.Id
    FROM PUMP.Employees e
    OUTER APPLY (SELECT TOP 1 s.Id, s.Amount FROM PUMP.SalaryPayments s
                 WHERE s.EmployeeId = e.Id AND s.OwnerId = @OwnerId AND s.PumpId = @PumpId
                   AND s.SalaryYear = @Year AND s.SalaryMonth = @Month) sp
    OUTER APPLY (SELECT Amount = SUM(a.Amount) FROM PUMP.EmployeeAdvances a
                 WHERE a.SalaryPaymentId = sp.Id AND a.EntryType = 'SALARY_CUT' AND a.IsDeleted = 0) cut
    WHERE e.OwnerId = @OwnerId AND e.PumpId = @PumpId AND ISNULL(e.IsDeleted, 0) = 0
      AND (e.IsActive = 1 OR sp.Id IS NOT NULL OR PUMP.fn_EmployeeAdvanceBalance(e.Id) <> 0)
      AND (e.JoinDate IS NULL OR e.JoinDate <= @MonthEnd)
    ORDER BY e.FullName;
END
GO
PRINT '  + AQ6: advance (save / delete / list / salary cut) + sp_Salary_Summary';
GO

CREATE OR ALTER PROCEDURE PUMP.sp_Report_ProfitLoss
(
    @OwnerId  BIGINT,
    @PumpId   BIGINT,
    @DateFrom DATE,
    @DateTo   DATE
)
AS
BEGIN
    SET NOCOUNT ON;

    /* NOTE (CLAUDE.md niyam 5): ProfitLossLineDto ke param theek isi kram / type me hain. */
    ;WITH meter AS
    (
        SELECT r.ProductId, Qty = SUM(ISNULL(r.SoldQty, 0)), Amount = SUM(ISNULL(r.SoldAmount, 0))
        FROM PUMP.ShiftNozzleReadings r
        JOIN PUMP.ShiftHeaders sh ON sh.Id = r.ShiftId
        WHERE sh.OwnerId = @OwnerId AND sh.PumpId = @PumpId AND sh.Status = 'CLOSED'
          AND sh.ShiftDate BETWEEN @DateFrom AND @DateTo
        GROUP BY r.ProductId
    ),
    counterSale AS
    (
        /* Mobil / saaman: jis product ka koi nozzle hi nahi, uska bill hi uski bikri hai. */
        SELECT d.ProductId, Qty = SUM(ISNULL(d.Quantity, 0)), Amount = SUM(ISNULL(d.Amount, 0))
        FROM PUMP.SalesDetails d
        JOIN PUMP.SalesHeaders h ON h.Id = d.SalesHeaderId
        WHERE h.OwnerId = @OwnerId AND h.PumpId = @PumpId AND h.IsVoid = 0
          AND CAST(h.BillDateTime AS DATE) BETWEEN @DateFrom AND @DateTo
          AND NOT EXISTS (SELECT 1 FROM PUMP.Nozzles n WHERE n.ProductId = d.ProductId)
        GROUP BY d.ProductId
    ),
    sold AS
    (
        SELECT x.ProductId, Qty = SUM(x.Qty), Amount = SUM(x.Amount)
        FROM (SELECT ProductId, Qty, Amount FROM meter
              UNION ALL
              SELECT ProductId, Qty, Amount FROM counterSale) x
        GROUP BY x.ProductId
    ),
    costed AS
    (
        SELECT s.ProductId, s.Qty, s.Amount,
               PeriodRate = (SELECT SUM(d.Amount) / NULLIF(SUM(d.Quantity), 0)
                             FROM PUMP.PurchaseDetails d
                             JOIN PUMP.PurchaseHeaders h ON h.Id = d.PurchaseHeaderId
                             WHERE h.OwnerId = @OwnerId AND h.PumpId = @PumpId AND d.ProductId = s.ProductId
                               AND d.Quantity > 0
                               AND h.InvoiceDate BETWEEN @DateFrom AND @DateTo),
               LastRate   = (SELECT TOP 1 d.Amount / NULLIF(d.Quantity, 0)
                             FROM PUMP.PurchaseDetails d
                             JOIN PUMP.PurchaseHeaders h ON h.Id = d.PurchaseHeaderId
                             WHERE h.OwnerId = @OwnerId AND h.PumpId = @PumpId AND d.ProductId = s.ProductId
                               AND d.Quantity > 0
                               AND h.InvoiceDate <= @DateTo
                             ORDER BY h.InvoiceDate DESC, h.Id DESC)
        FROM sold s
        WHERE s.Qty <> 0 OR s.Amount <> 0
    )
    SELECT
        Section    = CAST(N'SALE' AS NVARCHAR(20)),
        SortOrder  = CAST(ROW_NUMBER() OVER (ORDER BY p.IsFuel DESC, p.Name) AS INT),
        ItemId     = CAST(c.ProductId AS BIGINT),
        Name       = CAST(p.Name AS NVARCHAR(200)),
        Unit       = CAST(p.Unit AS NVARCHAR(20)),
        Qty        = CAST(c.Qty AS DECIMAL(18,3)),
        Amount     = CAST(c.Amount AS DECIMAL(18,2)),
        CostRate   = CAST(COALESCE(c.PeriodRate, c.LastRate) AS DECIMAL(18,4)),
        CostAmount = CAST(c.Qty * COALESCE(c.PeriodRate, c.LastRate) AS DECIMAL(18,2)),
        CostSource = CAST(CASE WHEN c.PeriodRate IS NOT NULL THEN N'PERIOD'
                               WHEN c.LastRate   IS NOT NULL THEN N'LAST'
                               ELSE N'NONE' END AS NVARCHAR(10))
    FROM costed c
    JOIN PUMP.Products p ON p.Id = c.ProductId

    UNION ALL

    SELECT
        CAST(N'EXPENSE' AS NVARCHAR(20)),
        CAST(ROW_NUMBER() OVER (ORDER BY SUM(e.Amount) DESC) AS INT),
        CAST(e.ExpenseHeadId AS BIGINT),
        CAST(ISNULL(eh.HeadName, N'-') AS NVARCHAR(200)),
        CAST(NULL AS NVARCHAR(20)),
        CAST(COUNT(*) AS DECIMAL(18,3)),
        CAST(SUM(e.Amount) AS DECIMAL(18,2)),
        CAST(NULL AS DECIMAL(18,4)),
        CAST(NULL AS DECIMAL(18,2)),
        CAST(N'' AS NVARCHAR(10))
    FROM PUMP.ExpenseTransactions e
    LEFT JOIN PUMP.ExpenseHeads eh ON eh.Id = e.ExpenseHeadId
    WHERE e.OwnerId = @OwnerId AND e.PumpId = @PumpId
      AND CAST(e.TxnDateTime AS DATE) BETWEEN @DateFrom AND @DateTo
    GROUP BY e.ExpenseHeadId, eh.HeadName

    UNION ALL

    SELECT
        CAST(N'SALARY' AS NVARCHAR(20)),
        CAST(1 AS INT),
        CAST(NULL AS BIGINT),
        CAST(N'Salary' AS NVARCHAR(200)),
        CAST(NULL AS NVARCHAR(20)),
        CAST(COUNT(*) AS DECIMAL(18,3)),
        CAST(SUM(x.Amount) AS DECIMAL(18,2)),
        CAST(NULL AS DECIMAL(18,4)),
        CAST(NULL AS DECIMAL(18,2)),
        CAST(N'' AS NVARCHAR(10))
    FROM
    (
        /* Section AQ: salary ka kharcha = haath me diya + advance me se kata (wo bhi salary hai). */
        SELECT sp.Amount FROM PUMP.SalaryPayments sp
        WHERE sp.OwnerId = @OwnerId AND sp.PumpId = @PumpId
          AND sp.PaidOn BETWEEN @DateFrom AND @DateTo
        UNION ALL
        SELECT ea.Amount FROM PUMP.EmployeeAdvances ea
        WHERE ea.OwnerId = @OwnerId AND ea.PumpId = @PumpId AND ea.IsDeleted = 0
          AND ea.EntryType = 'SALARY_CUT'
          AND ea.EntryDate BETWEEN @DateFrom AND @DateTo
    ) x
    HAVING COUNT(*) > 0;
END
GO
PRINT '  + AQ7: sp_Report_ProfitLoss - salary me advance se kata bhi';
GO

PRINT '=== Section AQ done ===';
GO


/* ==========================================================================================
   SECTION AR — Support ke number Super Admin se (2026-10-23)
   ------------------------------------------------------------------------------------------
   Support number (6394389973) 16 jagah code me likha tha - Login page, Manual, Shifts page,
   API ke OTP / free-trial sandesh. Badalna ho to code badal kar deploy karna padta. Owner:
   "super admin pe panel bana do, waha number dale to jaha jaha display hota hai waha display
   ho jaye, 2-3 number dalne ka option".

   AppSettings (OwnerId = 0, global) me Support.Phone1 / Phone2 / Phone3. Phone1 zaroori -
   pehli baar purana number hi bhar diya. Get bina login (login page ko chahiye).
   ========================================================================================== */
PRINT '=== Section AR: support number ===';
GO

IF NOT EXISTS (SELECT 1 FROM PUMP.AppSettings WHERE SettingKey = 'Support.Phone1' AND OwnerId = 0)
    INSERT INTO PUMP.AppSettings (SettingKey, SettingValue, OwnerId, Description)
    VALUES ('Support.Phone1', '6394389973', 0, N'Support number 1 - Login, Manual, sandesh me dikhta hai (Super Admin > Support numbers)');
GO

CREATE OR ALTER PROCEDURE PUMP.sp_SupportContacts_Get
AS
BEGIN
    SET NOCOUNT ON;
    /* NOTE (CLAUDE.md niyam 5): SupportContacts record ke param theek isi kram me. */
    SELECT
        Phone1 = CAST(NULLIF(LTRIM(RTRIM((SELECT SettingValue FROM PUMP.AppSettings WHERE SettingKey = 'Support.Phone1' AND OwnerId = 0))), '') AS NVARCHAR(20)),
        Phone2 = CAST(NULLIF(LTRIM(RTRIM((SELECT SettingValue FROM PUMP.AppSettings WHERE SettingKey = 'Support.Phone2' AND OwnerId = 0))), '') AS NVARCHAR(20)),
        Phone3 = CAST(NULLIF(LTRIM(RTRIM((SELECT SettingValue FROM PUMP.AppSettings WHERE SettingKey = 'Support.Phone3' AND OwnerId = 0))), '') AS NVARCHAR(20));
END
GO

CREATE OR ALTER PROCEDURE PUMP.sp_SupportContacts_Save
(
    @Phone1 NVARCHAR(20),
    @Phone2 NVARCHAR(20) = NULL,
    @Phone3 NVARCHAR(20) = NULL,
    @UserId BIGINT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Phone1 = NULLIF(LTRIM(RTRIM(@Phone1)), N'');
    SET @Phone2 = NULLIF(LTRIM(RTRIM(@Phone2)), N'');
    SET @Phone3 = NULLIF(LTRIM(RTRIM(@Phone3)), N'');

    IF @Phone1 IS NULL
        THROW 50170, 'The first support number is required.', 1;

    DECLARE @Old NVARCHAR(200) = CONCAT(
        (SELECT SettingValue FROM PUMP.AppSettings WHERE SettingKey = 'Support.Phone1' AND OwnerId = 0), ' / ',
        (SELECT SettingValue FROM PUMP.AppSettings WHERE SettingKey = 'Support.Phone2' AND OwnerId = 0), ' / ',
        (SELECT SettingValue FROM PUMP.AppSettings WHERE SettingKey = 'Support.Phone3' AND OwnerId = 0));

    BEGIN TRANSACTION;
        MERGE PUMP.AppSettings AS t
        USING (VALUES ('Support.Phone1', @Phone1), ('Support.Phone2', @Phone2), ('Support.Phone3', @Phone3)) AS s (SettingKey, SettingValue)
           ON t.SettingKey = s.SettingKey AND t.OwnerId = 0
        WHEN MATCHED THEN
            UPDATE SET SettingValue = s.SettingValue, ModifiedOn = SYSDATETIME()
        WHEN NOT MATCHED THEN
            INSERT (SettingKey, SettingValue, OwnerId, Description)
            VALUES (s.SettingKey, s.SettingValue, 0, N'Support number (Super Admin > Support numbers)');
    COMMIT TRANSACTION;

    DECLARE @New NVARCHAR(200) = CONCAT(@Phone1, ' / ', @Phone2, ' / ', @Phone3);
    EXEC PUMP.sp_Audit_Log @UserId = @UserId, @EntityName = 'AppSettings', @Action = 'UPDATE',
         @OldValues = @Old, @NewValues = @New, @Reason = N'Support numbers';

    EXEC PUMP.sp_SupportContacts_Get;
END
GO
PRINT '  + AR1: Support.Phone1..3, sp_SupportContacts_Get / Save';
PRINT '=== Section AR done ===';
GO
