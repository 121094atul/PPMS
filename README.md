# PPMS Starter Workspace

This workspace contains:
- Separate API solution: `src/API/PPMS.Api.sln`
- Separate Client solution: `src/Client/PPMS.Client.sln`
- SQL scripts: `Database/`

## API

Path: `src/API/PPMS.Api`

Set DB connection in:
- `src/API/PPMS.Api/appsettings.json`
- `src/API/PPMS.Api/appsettings.Development.json`

Run:

```powershell
dotnet run --project .\src\API\PPMS.Api\PPMS.Api.csproj
```

Current implemented endpoints:
- `POST /api/auth/login`
- `POST /api/auth/refresh`
- `POST /api/auth/logout`
- `GET /api/menus/my` (JWT required)
- `GET /api/products?ownerId={id}&pumpId={id}` (JWT required)
- `POST /api/products` (JWT required)
- `GET /api/pumps?ownerId={id}` (JWT required)
- `POST /api/pumps` (JWT required)
- `GET /api/nozzles?ownerId={id}&pumpId={id}` (JWT required)
- `POST /api/nozzles` (JWT required)
- `GET /api/tanks?ownerId={id}&pumpId={id}&searchTerm=&pageNumber=1&pageSize=20` (JWT required)
- `POST /api/tanks` (JWT required)
- `GET /api/parties?ownerId={id}&pumpId={id}&searchTerm=&pageNumber=1&pageSize=20` (JWT required)
- `GET /api/parties/{id}?ownerId={id}&pumpId={id}` (JWT required)
- `POST /api/parties` (JWT required)
- `GET /api/tank-transactions?ownerId={id}&pumpId={id}&tankId={id}` (JWT required)
- `POST /api/tank-transactions` (JWT required)
- `GET /api/party-ledger?ownerId={id}&pumpId={id}&partyId={id}` (JWT required)
- `POST /api/party-ledger` (JWT required)
- `GET /api/users` (JWT required)
- `POST /api/users` (JWT required)
- `GET /api/roles` (JWT required)
- `POST /api/roles` (JWT required)
- `GET /api/shifts` (JWT required)
- `POST /api/shifts/open` (JWT required)
- `POST /api/shifts/{id}/close` (JWT required)
- `GET /api/sales` (JWT required)
- `POST /api/sales` (JWT required)
- `POST /api/sales/{id}/receipt` (JWT required)

Demo login (seeded in `PUMP` schema):
- `username`: `owneradmin`
- `password`: `admin@123`

## Client

Path: `src/Client/PPMS.Client.Web`

Set API URL in:
- `src/Client/PPMS.Client.Web/appsettings.json` (`Api:BaseUrl`)

Run:

```powershell
dotnet run --project .\src\Client\PPMS.Client.Web\PPMS.Client.Web.csproj
```

Client behavior:
- Login screen at `/Account/Login`
- Session token is stored after login
- Left accordion menu is loaded dynamically from API endpoint `/api/menus/my`

## Database

All SQL scripts are in `Database/`.
Execution order is documented in [Database/README.md](Database/README.md).

When SQL credentials are available, scripts can be executed directly using `sqlcmd`.
