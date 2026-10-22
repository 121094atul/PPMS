using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;

namespace PPMS.Client.Web.Services;

public sealed class PPMSApiClient(HttpClient httpClient)
{
    public async Task<ApiLoginAttemptResult> LoginAsync(string username, string password, CancellationToken cancellationToken = default)
    {
        try
        {
            var response = await httpClient.PostAsJsonAsync(
                "/api/account/access",
                new ApiLoginRequest(username, password),
                cancellationToken);

            if (response.StatusCode == System.Net.HttpStatusCode.Unauthorized)
            {
                return new ApiLoginAttemptResult(false, null, "Invalid username or password.");
            }

            if (!response.IsSuccessStatusCode)
            {
                // Plan khatam / account band / bahut galat password - API 403/429 ke
                // saath saaf karan bhejti hai ({ error, message }). Pehle ye padha hi
                // nahi jaata tha aur owner ko "Login failed. API returned 403." dikhta
                // tha - use pata hi nahi chalta tha ki plan khatam hua hai.
                string? code = null, apiMessage = null;
                try
                {
                    var raw = await response.Content.ReadAsStringAsync(cancellationToken);
                    using var doc = JsonDocument.Parse(raw);
                    if (doc.RootElement.ValueKind == JsonValueKind.Object)
                    {
                        foreach (var prop in doc.RootElement.EnumerateObject())
                        {
                            if (string.Equals(prop.Name, "error", StringComparison.OrdinalIgnoreCase) && prop.Value.ValueKind == JsonValueKind.String)
                                code = prop.Value.GetString();
                            else if (string.Equals(prop.Name, "message", StringComparison.OrdinalIgnoreCase) && prop.Value.ValueKind == JsonValueKind.String)
                                apiMessage = prop.Value.GetString();
                        }
                    }
                }
                catch
                {
                    // JSON nahi aaya - neeche wala aam sandesh chalega.
                }

                int? lockMinutes = null;
                if (code == "ACCOUNT_LOCKED" && apiMessage is not null)
                {
                    var digits = System.Text.RegularExpressions.Regex.Match(apiMessage, @"\d+");
                    if (digits.Success && int.TryParse(digits.Value, out var m)) lockMinutes = m;
                }

                var message = code switch
                {
                    "TRIAL_EXPIRED"   => "Your plan has expired. Please contact support to renew.",
                    "OWNER_SUSPENDED" => "This account has been suspended. Please contact support.",
                    "ACCOUNT_LOCKED"  => "Too many failed login attempts. Please try again later.",
                    _ => string.IsNullOrWhiteSpace(apiMessage)
                            ? $"Login failed. API returned {(int)response.StatusCode}."
                            : apiMessage
                };
                return new ApiLoginAttemptResult(false, null, message, code, lockMinutes);
            }

            var payload = await response.Content.ReadFromJsonAsync<ApiLoginResponse>(cancellationToken: cancellationToken);
            if (payload is null)
            {
                return new ApiLoginAttemptResult(false, null, "Login response was empty.");
            }

            return new ApiLoginAttemptResult(true, payload, null);
        }
        catch (HttpRequestException)
        {
            return new ApiLoginAttemptResult(false, null, "API unreachable. Check API server is running.");
        }
        catch (TaskCanceledException)
        {
            return new ApiLoginAttemptResult(false, null, "Login request timed out.");
        }
    }

    public async Task<ApiLoginResponse?> RefreshAsync(string refreshToken, CancellationToken cancellationToken = default)
    {
        var response = await httpClient.PostAsJsonAsync(
            "/api/account/renew",
            new ApiRefreshTokenRequest(refreshToken),
            cancellationToken);

        if (!response.IsSuccessStatusCode)
        {
            return null;
        }

        return await response.Content.ReadFromJsonAsync<ApiLoginResponse>(cancellationToken: cancellationToken);
    }

    public async Task LogoutAsync(string refreshToken, CancellationToken cancellationToken = default)
    {
        await httpClient.PostAsJsonAsync(
            "/api/account/signout",
            new ApiLogoutRequest(refreshToken),
            cancellationToken);
    }

    public async Task<IReadOnlyList<ApiMenuItem>> GetMenusAsync(string token, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, "/api/menus/my");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiMenuItem>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiMenuItem>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiMenuItem>() : items;
    }

    public async Task<IReadOnlyList<ApiMenuItem>> GetAllMenusAsync(string token, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, "/api/menus");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiMenuItem>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiMenuItem>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiMenuItem>() : items;
    }

    /// <summary>
    /// Shift ki list.
    ///
    /// SAWDHANI: purana /api/shifts (bina paging wala) andar se `sp_Shift_List` ko
    /// bulata hai jiska default `@PageSize = 50` hai — yaani wo CHUPCHAAP sirf aakhri
    /// 50 shift lauta deta tha. 3 shift roz wale pump par ek mahine me 90 shift hoti
    /// hain, to mahine ka total galat ban jaata aur purani shift dropdown me aati hi
    /// nahi thi. (Test me DB me 90 thi, API 50 laayi.)
    ///
    /// Ab har screen wahi maangti hai jo use chahiye — tareekh ki range aur limit
    /// saaf-saaf batakar, paged endpoint se.
    /// </summary>
    public async Task<IReadOnlyList<ApiShiftDto>> GetShiftsAsync(
        string token, long ownerId, long? pumpId,
        DateOnly? fromDate = null, DateOnly? toDate = null, int pageSize = 500,
        CancellationToken cancellationToken = default)
    {
        var url = $"/api/shifts/paged?ownerId={ownerId}&pageNumber=1&pageSize={pageSize}";
        if (pumpId is > 0)
        {
            url += $"&pumpId={pumpId.Value}";
        }
        if (fromDate is not null)
        {
            url += $"&fromDate={fromDate:yyyy-MM-dd}";
        }
        if (toDate is not null)
        {
            url += $"&toDate={toDate:yyyy-MM-dd}";
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiShiftDto>();
        }

        var page = await response.Content.ReadFromJsonAsync<ApiPagedResponse<ApiShiftDto>>(cancellationToken: cancellationToken);
        return page?.Items ?? (IReadOnlyList<ApiShiftDto>)Array.Empty<ApiShiftDto>();
    }

    public async Task<ApiPagedResponse<ApiShiftDto>> GetPagedShiftsAsync(
        string token, 
        long ownerId, 
        long? pumpId, 
        DateTime? fromDate,
        DateTime? toDate,
        string? searchTerm,
        int pageNumber,
        int pageSize,
        CancellationToken cancellationToken = default)
    {
        var url = $"/api/shifts/paged?ownerId={ownerId}";
        if (pumpId is > 0)
        {
            url += $"&pumpId={pumpId.Value}";
        }
        if (fromDate.HasValue)
        {
            url += $"&fromDate={fromDate.Value:yyyy-MM-dd}";
        }
        if (toDate.HasValue)
        {
            url += $"&toDate={toDate.Value:yyyy-MM-dd}";
        }
        if (!string.IsNullOrWhiteSpace(searchTerm))
        {
            url += $"&searchTerm={Uri.EscapeDataString(searchTerm)}";
        }
        url += $"&pageNumber={pageNumber}&pageSize={pageSize}";

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return new ApiPagedResponse<ApiShiftDto>(Array.Empty<ApiShiftDto>(), 1, pageSize, 0);
        }

        var items = await response.Content.ReadFromJsonAsync<ApiPagedResponse<ApiShiftDto>>(cancellationToken: cancellationToken);
        return items ?? new ApiPagedResponse<ApiShiftDto>(Array.Empty<ApiShiftDto>(), 1, pageSize, 0);
    }

    public async Task<ApiShiftCollectionSummaryDto?> GetShiftCollectionSummaryAsync(string token, long shiftId, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/shifts/{shiftId}/summary");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return null;
        }

        return await response.Content.ReadFromJsonAsync<ApiShiftCollectionSummaryDto>(cancellationToken: cancellationToken);
    }

    public async Task<IReadOnlyList<ApiPumpDto>> GetPumpsAsync(string token, long ownerId, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/pumps?ownerId={ownerId}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiPumpDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiPumpDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiPumpDto>() : items;
    }

    public async Task<(bool Success, string? ErrorMessage)> SavePumpAsync(string token, ApiSavePumpRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/pumps");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        // Server ka asli sandesh user tak pahunchana hai. Pehle ye method
        // sirf true/false lautata tha, isliye SP ka saaf message (jaise
        // "Please pick the tank this nozzle draws from.") raste me hi gum ho
        // jaata tha aur user ko bas "Unable to save" dikhta tha.
        var error = await ReadErrorMessageAsync(response, "Could not save the pump.", cancellationToken);
        return (false, error);
    }

    public async Task<(bool Success, string? ErrorMessage)> DeletePumpAsync(string token, long id, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Delete, $"/api/pumps/{id}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }
        var error = await ReadErrorMessageAsync(response, "Unable to delete pump.", cancellationToken);
        return (false, error);
    }

    public async Task<IReadOnlyList<ApiProductDto>> GetProductsAsync(
        string token,
        long ownerId,
        long? pumpId,
        CancellationToken cancellationToken = default)
    {
        var url = $"/api/products?ownerId={ownerId}";
        if (pumpId is > 0)
        {
            url += $"&pumpId={pumpId.Value}";
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiProductDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiProductDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiProductDto>() : items;
    }

    /// <summary>Login page se naya pump khud account banaye. Bina login ke chalti hai.</summary>
    public async Task<(bool Success, string Message)> SignupAsync(object payload, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/account/signup")
        {
            Content = JsonContent.Create(payload)
        };

        var response = await httpClient.SendAsync(request, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        var message = ExtractMessage(body)
                      ?? (response.IsSuccessStatusCode ? "Account ban gaya." : "Account nahi ban paya.");
        return (response.IsSuccessStatusCode, message);
    }

    /// <summary>Bina login ke chalti hai. Jawab hamesha safal — bahar se pata nahi
    /// chalna chahiye ki number registered hai ya nahi.</summary>
    public async Task<(bool SmsAvailable, string Message)> ForgotPasswordAsync(string mobile, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/account/forgot-password")
        {
            Content = JsonContent.Create(new { Mobile = mobile })
        };

        var response = await httpClient.SendAsync(request, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);

        var smsAvailable = true;
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(body);
            if (doc.RootElement.TryGetProperty("smsAvailable", out var el))
            {
                smsAvailable = el.GetBoolean();
            }
        }
        catch (System.Text.Json.JsonException)
        {
            // Jawab padha nahi ja saka — maan lete hain SMS chalu hai, warna
            // sahi-salamat user bhi bina wajah rok diya jayega.
        }

        return (smsAvailable, ExtractMessage(body) ?? "If this number is registered, an OTP has been sent.");
    }

    public async Task<(bool Success, string Message)> ResetPasswordAsync(
        string mobile, string otp, string newPassword, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/account/reset-password")
        {
            Content = JsonContent.Create(new { Mobile = mobile, Otp = otp, NewPassword = newPassword })
        };

        var response = await httpClient.SendAsync(request, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        var message = ExtractMessage(body) ?? (response.IsSuccessStatusCode ? "Password badal gaya." : "Password reset nahi ho paya.");
        return (response.IsSuccessStatusCode, message);
    }

    public async Task<IReadOnlyList<ApiNozzleCashDto>> GetShiftNozzleCashAsync(string token, long shiftId, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/shifts/{shiftId}/nozzle-cash");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode) { return Array.Empty<ApiNozzleCashDto>(); }
        var items = await response.Content.ReadFromJsonAsync<List<ApiNozzleCashDto>>(cancellationToken: cancellationToken);
        return items ?? (IReadOnlyList<ApiNozzleCashDto>)Array.Empty<ApiNozzleCashDto>();
    }

    public async Task<(bool Success, string? Error)> SetNozzleAttendantAsync(string token, long shiftId, long nozzleId, long? employeeId, decimal? floatGiven, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, $"/api/shifts/{shiftId}/nozzle-attendant")
        {
            Content = JsonContent.Create(new { ShiftId = shiftId, NozzleId = nozzleId, EmployeeId = employeeId, FloatGiven = floatGiven })
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode) { return (true, null); }
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        return (false, ExtractMessage(body));
    }

    public async Task<(bool Success, string? Error)> CollectNozzleCashAsync(string token, long shiftId, long nozzleId, decimal cashReturned, decimal? slipsAmount, string? notes, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, $"/api/shifts/{shiftId}/collect-cash")
        {
            Content = JsonContent.Create(new { ShiftId = shiftId, NozzleId = nozzleId, CashReturned = cashReturned, SlipsAmount = slipsAmount, Notes = notes })
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode) { return (true, null); }
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        return (false, ExtractMessage(body));
    }

    public async Task<(bool Success, string? ErrorMessage)> UndoNozzleCashAsync(string token, long shiftId, long nozzleId, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Delete, $"/api/shifts/{shiftId}/collect-cash/{nozzleId}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        // Server ka asli sandesh user tak pahunchana hai. Pehle ye method
        // sirf true/false lautata tha, isliye SP ka saaf message (jaise
        // "Please pick the tank this nozzle draws from.") raste me hi gum ho
        // jaata tha aur user ko bas "Unable to save" dikhta tha.
        var error = await ReadErrorMessageAsync(response, "Could not undo this cash entry.", cancellationToken);
        return (false, error);
    }

    public async Task<IReadOnlyList<ApiPendingCashDto>> GetPendingNozzleCashAsync(string token, long? pumpId, DateOnly? fromDate, DateOnly? toDate, CancellationToken cancellationToken = default)
    {
        var url = "/api/nozzle-cash/pending";
        var q = new List<string>();
        if (pumpId is > 0) { q.Add($"pumpId={pumpId}"); }
        if (fromDate is not null) { q.Add($"fromDate={fromDate:yyyy-MM-dd}"); }
        if (toDate is not null) { q.Add($"toDate={toDate:yyyy-MM-dd}"); }
        if (q.Count > 0) { url += "?" + string.Join("&", q); }

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode) { return Array.Empty<ApiPendingCashDto>(); }
        var items = await response.Content.ReadFromJsonAsync<List<ApiPendingCashDto>>(cancellationToken: cancellationToken);
        return items ?? (IReadOnlyList<ApiPendingCashDto>)Array.Empty<ApiPendingCashDto>();
    }

    public async Task<IReadOnlyList<ApiAttendantCashDto>> GetAttendantCashReportAsync(string token, long? pumpId, DateOnly fromDate, DateOnly toDate, CancellationToken cancellationToken = default)
    {
        var url = $"/api/reports/attendant-cash?fromDate={fromDate:yyyy-MM-dd}&toDate={toDate:yyyy-MM-dd}";
        if (pumpId is > 0) { url += $"&pumpId={pumpId}"; }

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode) { return Array.Empty<ApiAttendantCashDto>(); }
        var items = await response.Content.ReadFromJsonAsync<List<ApiAttendantCashDto>>(cancellationToken: cancellationToken);
        return items ?? (IReadOnlyList<ApiAttendantCashDto>)Array.Empty<ApiAttendantCashDto>();
    }

    public async Task<IReadOnlyList<ApiTenantUserDto>> GetTenantUsersAsync(string token, long ownerId, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/owners/{ownerId}/users");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiTenantUserDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiTenantUserDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiTenantUserDto>() : items;
    }

    public async Task<(bool Success, string? ErrorMessage)> AdminResetUserPasswordAsync(string token, long userId, string newPassword, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, $"/api/users/{userId}/reset-password")
        {
            Content = JsonContent.Create(new { NewPassword = newPassword })
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        // Server ka asli sandesh user tak pahunchana hai. Pehle ye method
        // sirf true/false lautata tha, isliye SP ka saaf message (jaise
        // "Please pick the tank this nozzle draws from.") raste me hi gum ho
        // jaata tha aur user ko bas "Unable to save" dikhta tha.
        var error = await ReadErrorMessageAsync(response, "Could not reset the password.", cancellationToken);
        return (false, error);
    }

    public async Task<IReadOnlyList<ApiDailyRateDto>> GetDailyRatesAsync(string token, long ownerId, long? pumpId, CancellationToken cancellationToken = default)
    {
        var url = $"/api/products/daily-rates?ownerId={ownerId}";
        if (pumpId is > 0)
        {
            url += $"&pumpId={pumpId}";
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiDailyRateDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiDailyRateDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiDailyRateDto>() : items;
    }

    /// <summary>Kitne rate badle wo lautata hai; kuch galat ho to error message.</summary>
    public async Task<(bool Success, int Updated, string? Error)> UpdateDailyRatesAsync(
        string token, ApiUpdateDailyRatesRequest payload, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/products/daily-rates")
        {
            Content = JsonContent.Create(payload)
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await httpClient.SendAsync(request, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);

        if (!response.IsSuccessStatusCode)
        {
            // API business-rule tootne par 400 + asli wajah bhejta hai
            // (GlobalExceptionMiddleware), wahi user ko dikhana hai.
            var reason = ExtractMessage(body) ?? "Could not update the rates.";
            return (false, 0, reason);
        }

        var updated = 0;
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(body);
            if (doc.RootElement.TryGetProperty("updatedCount", out var el))
            {
                updated = el.GetInt32();
            }
        }
        catch (System.Text.Json.JsonException)
        {
            // count na mile to bhi update ho chuka hai — sirf ginti nahi bata payenge.
        }

        return (true, updated, null);
    }

    private static string? ExtractMessage(string body)
    {
        if (string.IsNullOrWhiteSpace(body))
        {
            return null;
        }

        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(body);
            if (doc.RootElement.ValueKind == System.Text.Json.JsonValueKind.Object &&
                doc.RootElement.TryGetProperty("message", out var msg))
            {
                return msg.GetString();
            }
        }
        catch (System.Text.Json.JsonException)
        {
            // plain text aaya hoga
        }

        return body.Length > 300 ? body[..300] : body;
    }

    public async Task<IReadOnlyList<ApiProductRateHistoryDto>> GetProductRateHistoryAsync(string token, long productId, CancellationToken cancellationToken = default)
    {
        var url = $"/api/products/{productId}/rate-history";
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiProductRateHistoryDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiProductRateHistoryDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiProductRateHistoryDto>() : items;
    }

    public async Task<IReadOnlyList<ApiNozzleDto>> GetNozzlesAsync(string token, long ownerId, long? pumpId, CancellationToken cancellationToken = default)
    {
        var url = $"/api/nozzles?ownerId={ownerId}";
        if (pumpId is > 0)
        {
            url += $"&pumpId={pumpId.Value}";
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiNozzleDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiNozzleDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiNozzleDto>() : items;
    }

    public async Task<(bool Success, string? ErrorMessage)> SaveNozzleAsync(string token, ApiSaveNozzleRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/nozzles");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        // Server ka asli sandesh user tak pahunchana hai. Pehle ye method
        // sirf true/false lautata tha, isliye SP ka saaf message (jaise
        // "Please pick the tank this nozzle draws from.") raste me hi gum ho
        // jaata tha aur user ko bas "Unable to save" dikhta tha.
        var error = await ReadErrorMessageAsync(response, "Could not save the nozzle.", cancellationToken);
        return (false, error);
    }

    public async Task<(bool Success, string? ErrorMessage)> DeleteNozzleAsync(string token, long id, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Delete, $"/api/nozzles/{id}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }
        var error = await ReadErrorMessageAsync(response, "Unable to delete nozzle.", cancellationToken);
        return (false, error);
    }

    public async Task<ApiPagedResponse<ApiTankDto>> GetTanksAsync(
        string token,
        long ownerId,
        long pumpId,
        string? searchTerm,
        int pageNumber,
        int pageSize,
        CancellationToken cancellationToken = default)
    {
        var url = $"/api/tanks?ownerId={ownerId}&pumpId={pumpId}&pageNumber={pageNumber}&pageSize={pageSize}";
        if (!string.IsNullOrWhiteSpace(searchTerm))
        {
            url += $"&searchTerm={Uri.EscapeDataString(searchTerm)}";
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return new ApiPagedResponse<ApiTankDto>(Array.Empty<ApiTankDto>(), 0, pageNumber, pageSize);
        }

        var payload = await response.Content.ReadFromJsonAsync<ApiPagedResponse<ApiTankDto>>(cancellationToken: cancellationToken);
        return payload ?? new ApiPagedResponse<ApiTankDto>(Array.Empty<ApiTankDto>(), 0, pageNumber, pageSize);
    }

    public async Task<(bool Success, string? ErrorMessage)> SaveTankAsync(string token, ApiSaveTankRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/tanks");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        // Server ka asli sandesh user tak pahunchana hai. Pehle ye method
        // sirf true/false lautata tha, isliye SP ka saaf message (jaise
        // "Please pick the tank this nozzle draws from.") raste me hi gum ho
        // jaata tha aur user ko bas "Unable to save" dikhta tha.
        var error = await ReadErrorMessageAsync(response, "Could not save the tank.", cancellationToken);
        return (false, error);
    }

    public async Task<(bool Success, string? ErrorMessage)> DeleteTankAsync(string token, long id, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Delete, $"/api/tanks/{id}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }
        var error = await ReadErrorMessageAsync(response, "Unable to delete tank.", cancellationToken);
        return (false, error);
    }

    public async Task<ApiPagedResponse<ApiPartyDto>> GetPartiesAsync(
        string token,
        long ownerId,
        long pumpId,
        string? searchTerm,
        int pageNumber,
        int pageSize,
        CancellationToken cancellationToken = default)
    {
        var url = $"/api/parties?ownerId={ownerId}&pumpId={pumpId}&pageNumber={pageNumber}&pageSize={pageSize}";
        if (!string.IsNullOrWhiteSpace(searchTerm))
        {
            url += $"&searchTerm={Uri.EscapeDataString(searchTerm)}";
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return new ApiPagedResponse<ApiPartyDto>(Array.Empty<ApiPartyDto>(), 0, pageNumber, pageSize);
        }

        var payload = await response.Content.ReadFromJsonAsync<ApiPagedResponse<ApiPartyDto>>(cancellationToken: cancellationToken);
        return payload ?? new ApiPagedResponse<ApiPartyDto>(Array.Empty<ApiPartyDto>(), 0, pageNumber, pageSize);
    }

    /// <summary>
    /// DROPDOWN ke liye: pump ki SAARI party, naam ke kram me.
    ///
    /// Pehle har page apni seema khud likhta tha (Party Ledger aur Sales 100, Fleet /
    /// Coupon 200, Day Collection 500). Live par 103 party thi — naam ke kram me
    /// 101vi, 102vi, 103vi party dropdown me aati hi nahi thi,
    /// aur unka khaata bhara hi nahi ja sakta tha.
    ///
    /// Tukdon me isliye ki ek hi bahut bada jawab na maangna pade; 40 tukde = 20,000
    /// party, isse aage dropdown ka matlab hi nahi rehta.
    /// </summary>
    public async Task<IReadOnlyList<ApiPartyDto>> GetAllPartiesAsync(string token, long ownerId, long pumpId, CancellationToken cancellationToken = default)
    {
        const int chunk = 500;
        var all = new List<ApiPartyDto>();

        for (var page = 1; page <= 40; page++)
        {
            var response = await GetPartiesAsync(token, ownerId, pumpId, null, page, chunk, cancellationToken);
            all.AddRange(response.Items);

            if (response.Items.Count < chunk || all.Count >= response.TotalCount)
            {
                break;
            }
        }

        return all;
    }

    public async Task<ApiPartyDto?> GetPartyByIdAsync(string token, long ownerId, long pumpId, long id, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/parties/{id}?ownerId={ownerId}&pumpId={pumpId}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return null;
        }

        return await response.Content.ReadFromJsonAsync<ApiPartyDto>(cancellationToken: cancellationToken);
    }

    public async Task<(bool Success, string? ErrorMessage)> SavePartyAsync(string token, ApiSavePartyRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/parties");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        // Server ka asli sandesh user tak pahunchana hai. Pehle ye method
        // sirf true/false lautata tha, isliye SP ka saaf message (jaise
        // "Please pick the tank this nozzle draws from.") raste me hi gum ho
        // jaata tha aur user ko bas "Unable to save" dikhta tha.
        var error = await ReadErrorMessageAsync(response, "Could not save the party.", cancellationToken);
        return (false, error);
    }

    public async Task<(bool Success, string? ErrorMessage)> DeletePartyAsync(string token, long id, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Delete, $"/api/parties/{id}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }
        var error = await ReadErrorMessageAsync(response, "Unable to delete party.", cancellationToken);
        return (false, error);
    }

    public async Task<IReadOnlyList<ApiTankTransactionDto>> GetTankTransactionsAsync(string token, long ownerId, long pumpId, long? tankId, CancellationToken cancellationToken = default)
    {
        var url = $"/api/tank-transactions?ownerId={ownerId}&pumpId={pumpId}";
        if (tankId is > 0)
        {
            url += $"&tankId={tankId.Value}";
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiTankTransactionDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiTankTransactionDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiTankTransactionDto>() : items;
    }

    public async Task<(bool Success, string? ErrorMessage)> SaveTankTransactionAsync(string token, ApiSaveTankTransactionRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/tank-transactions");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        // Server ka asli sandesh user tak pahunchana hai. Pehle ye method
        // sirf true/false lautata tha, isliye SP ka saaf message (jaise
        // "Please pick the tank this nozzle draws from.") raste me hi gum ho
        // jaata tha aur user ko bas "Unable to save" dikhta tha.
        var error = await ReadErrorMessageAsync(response, "Could not save the stock entry.", cancellationToken);
        return (false, error);
    }

    public async Task<IReadOnlyList<ApiPartyLedgerEntryDto>> GetPartyLedgerAsync(string token, long ownerId, long pumpId, long? partyId, CancellationToken cancellationToken = default)
    {
        var url = $"/api/party-ledger?ownerId={ownerId}&pumpId={pumpId}";
        if (partyId is > 0)
        {
            url += $"&partyId={partyId.Value}";
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiPartyLedgerEntryDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiPartyLedgerEntryDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiPartyLedgerEntryDto>() : items;
    }

    public async Task<ApiPagedResponse<ApiPartyLedgerEntryDto>> GetPagedPartyLedgerAsync(
        string token, long ownerId, long pumpId, long? partyId, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
    {
        var url = $"/api/party-ledger/paged?ownerId={ownerId}&pumpId={pumpId}&pageNumber={pageNumber}&pageSize={pageSize}";
        if (partyId is > 0)
        {
            url += $"&partyId={partyId.Value}";
        }
        if (!string.IsNullOrWhiteSpace(searchTerm))
        {
            url += $"&searchTerm={Uri.EscapeDataString(searchTerm)}";
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return new ApiPagedResponse<ApiPartyLedgerEntryDto>(Array.Empty<ApiPartyLedgerEntryDto>(), 0, pageNumber, pageSize);
        }

        var payload = await response.Content.ReadFromJsonAsync<ApiPagedResponse<ApiPartyLedgerEntryDto>>(cancellationToken: cancellationToken);
        return payload ?? new ApiPagedResponse<ApiPartyLedgerEntryDto>(Array.Empty<ApiPartyLedgerEntryDto>(), 0, pageNumber, pageSize);
    }

    /// <summary>
    /// Ek party ka khaata: purana baki + har line ke saath chalta hua baki.
    /// null = API se nahi mila (purani API, ya party is owner ki nahi) — tab page
    /// purani saadi list dikha deta hai.
    /// </summary>
    public async Task<ApiPartyStatementDto?> GetPartyStatementAsync(
        string token, long pumpId, long partyId, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
    {
        var url = $"/api/party-ledger/statement?pumpId={pumpId}&partyId={partyId}&pageNumber={pageNumber}&pageSize={pageSize}";
        if (!string.IsNullOrWhiteSpace(searchTerm))
        {
            url += $"&searchTerm={Uri.EscapeDataString(searchTerm)}";
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return null;
        }

        return await response.Content.ReadFromJsonAsync<ApiPartyStatementDto>(cancellationToken: cancellationToken);
    }

    /// <summary>Khaate ki haath se bani entry sudharna (rakam, tareekh, prakar, ref, note).</summary>
    public async Task<(bool Success, string? ErrorMessage)> UpdatePartyLedgerEntryAsync(string token, long id, ApiUpdatePartyLedgerEntryRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Put, $"/api/party-ledger/{id}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }
        var error = await ReadErrorMessageAsync(response, "Could not update the ledger entry.", cancellationToken);
        return (false, error);
    }

    /// <summary>Khaate ki haath se bani entry hatana. Puraani line AuditLog me rehti hai.</summary>
    public async Task<(bool Success, string? ErrorMessage)> DeletePartyLedgerEntryAsync(string token, long id, long pumpId, string? reason, CancellationToken cancellationToken = default)
    {
        var url = $"/api/party-ledger/{id}?pumpId={pumpId}";
        if (!string.IsNullOrWhiteSpace(reason))
        {
            url += "&reason=" + Uri.EscapeDataString(reason);
        }

        using var request = new HttpRequestMessage(HttpMethod.Delete, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }
        var error = await ReadErrorMessageAsync(response, "Could not delete the ledger entry.", cancellationToken);
        return (false, error);
    }

    public async Task<(bool Success, string? ErrorMessage)> SavePartyLedgerAsync(string token, ApiSavePartyLedgerEntryRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/party-ledger");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        // Server ka asli sandesh user tak pahunchana hai. Pehle ye method
        // sirf true/false lautata tha, isliye SP ka saaf message (jaise
        // "Please pick the tank this nozzle draws from.") raste me hi gum ho
        // jaata tha aur user ko bas "Unable to save" dikhta tha.
        var error = await ReadErrorMessageAsync(response, "Could not save the ledger entry.", cancellationToken);
        return (false, error);
    }

    public async Task<IReadOnlyList<ApiVendorDto>> GetVendorsAsync(string token, long ownerId, long pumpId, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/vendors?ownerId={ownerId}&pumpId={pumpId}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiVendorDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiVendorDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiVendorDto>() : items;
    }

    public async Task<(bool Success, string? ErrorMessage)> SaveVendorAsync(string token, ApiSaveVendorRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/vendors");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        // Server ka asli sandesh user tak pahunchana hai. Pehle ye method
        // sirf true/false lautata tha, isliye SP ka saaf message (jaise
        // "Please pick the tank this nozzle draws from.") raste me hi gum ho
        // jaata tha aur user ko bas "Unable to save" dikhta tha.
        var error = await ReadErrorMessageAsync(response, "Could not save the vendor.", cancellationToken);
        return (false, error);
    }

    public async Task<ApiPagedResponse<ApiPurchaseDto>> GetPagedPurchasesAsync(
        string token, 
        long ownerId, 
        long pumpId, 
        DateTime? fromDate,
        DateTime? toDate,
        string? searchTerm,
        int pageNumber,
        int pageSize,
        CancellationToken cancellationToken = default)
    {
        var url = $"/api/purchase?ownerId={ownerId}&pumpId={pumpId}";
        if (fromDate.HasValue) url += $"&fromDate={fromDate.Value:yyyy-MM-dd}";
        if (toDate.HasValue) url += $"&toDate={toDate.Value:yyyy-MM-dd}";
        if (!string.IsNullOrWhiteSpace(searchTerm)) url += $"&searchTerm={Uri.EscapeDataString(searchTerm)}";
        url += $"&pageNumber={pageNumber}&pageSize={pageSize}";

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return new ApiPagedResponse<ApiPurchaseDto>(Array.Empty<ApiPurchaseDto>(), 0, pageNumber, pageSize);
        }

        var payload = await response.Content.ReadFromJsonAsync<ApiPagedResponse<ApiPurchaseDto>>(cancellationToken: cancellationToken);
        return payload ?? new ApiPagedResponse<ApiPurchaseDto>(Array.Empty<ApiPurchaseDto>(), 0, pageNumber, pageSize);
    }

    public async Task<long?> SavePurchaseAsync(string token, ApiSavePurchaseRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/purchase");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return null;
        }

        var payload = await response.Content.ReadFromJsonAsync<SaveResult>(cancellationToken: cancellationToken);
        return payload?.Id;
    }

    public async Task<ApiPurchaseDetailDto?> GetPurchaseByIdAsync(string token, long id, long ownerId, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/purchase/{id}?ownerId={ownerId}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return null;
        }

        return await response.Content.ReadFromJsonAsync<ApiPurchaseDetailDto>(cancellationToken: cancellationToken);
    }

    public async Task<ApiPagedResponse<ApiStockReconciliationDto>> GetPagedStockReconciliationsAsync(
        string token, 
        long ownerId, 
        long pumpId, 
        long? tankId,
        DateTime? fromDate,
        DateTime? toDate,
        string? searchTerm,
        int pageNumber,
        int pageSize,
        CancellationToken cancellationToken = default)
    {
        var url = $"/api/stock-reconciliation?ownerId={ownerId}&pumpId={pumpId}";
        if (tankId is > 0) url += $"&tankId={tankId.Value}";
        if (fromDate.HasValue) url += $"&fromDate={fromDate.Value:yyyy-MM-dd}";
        if (toDate.HasValue) url += $"&toDate={toDate.Value:yyyy-MM-dd}";
        if (!string.IsNullOrWhiteSpace(searchTerm)) url += $"&searchTerm={Uri.EscapeDataString(searchTerm)}";
        url += $"&pageNumber={pageNumber}&pageSize={pageSize}";

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return new ApiPagedResponse<ApiStockReconciliationDto>(Array.Empty<ApiStockReconciliationDto>(), 0, pageNumber, pageSize);
        }

        var payload = await response.Content.ReadFromJsonAsync<ApiPagedResponse<ApiStockReconciliationDto>>(cancellationToken: cancellationToken);
        return payload ?? new ApiPagedResponse<ApiStockReconciliationDto>(Array.Empty<ApiStockReconciliationDto>(), 0, pageNumber, pageSize);
    }

    public async Task<(bool Success, string? ErrorMessage)> SaveStockReconciliationAsync(string token, ApiSaveStockReconciliationRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/stock-reconciliation");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        // Server ka asli sandesh user tak pahunchana hai. Pehle ye method
        // sirf true/false lautata tha, isliye SP ka saaf message (jaise
        // "Please pick the tank this nozzle draws from.") raste me hi gum ho
        // jaata tha aur user ko bas "Unable to save" dikhta tha.
        var error = await ReadErrorMessageAsync(response, "Could not save the reconciliation.", cancellationToken);
        return (false, error);
    }

    public async Task<IReadOnlyList<ApiExpenseHeadDto>> GetExpenseHeadsAsync(string token, long ownerId, long pumpId, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/expense-heads?ownerId={ownerId}&pumpId={pumpId}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiExpenseHeadDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiExpenseHeadDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiExpenseHeadDto>() : items;
    }

    public async Task<(bool Success, string? ErrorMessage)> SaveExpenseHeadAsync(string token, ApiSaveExpenseHeadRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/expense-heads");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        // Server ka asli sandesh user tak pahunchana hai. Pehle ye method
        // sirf true/false lautata tha, isliye SP ka saaf message (jaise
        // "Please pick the tank this nozzle draws from.") raste me hi gum ho
        // jaata tha aur user ko bas "Unable to save" dikhta tha.
        var error = await ReadErrorMessageAsync(response, "Could not save the expense head.", cancellationToken);
        return (false, error);
    }

    public async Task<ApiPagedResponse<ApiCashTransactionDto>> GetPagedCashTransactionsAsync(
        string token, 
        long ownerId, 
        long pumpId,
        DateTime? fromDate,
        DateTime? toDate,
        string? searchTerm,
        int pageNumber,
        int pageSize,
        CancellationToken cancellationToken = default)
    {
        var url = $"/api/cash-transactions?ownerId={ownerId}&pumpId={pumpId}";
        if (fromDate.HasValue) url += $"&fromDate={fromDate.Value:yyyy-MM-dd}";
        if (toDate.HasValue) url += $"&toDate={toDate.Value:yyyy-MM-dd}";
        if (!string.IsNullOrWhiteSpace(searchTerm)) url += $"&searchTerm={Uri.EscapeDataString(searchTerm)}";
        url += $"&pageNumber={pageNumber}&pageSize={pageSize}";

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        Console.WriteLine($"[API CLIENT] GetPagedCashTransactionsAsync URL: {url}");
        Console.WriteLine($"[API CLIENT] Response Code: {response.StatusCode}");
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadAsStringAsync(cancellationToken);
            Console.WriteLine($"[API CLIENT] Error Body: {err}");
            return new ApiPagedResponse<ApiCashTransactionDto>(Array.Empty<ApiCashTransactionDto>(), 0, pageNumber, pageSize);
        }

        var payload = await response.Content.ReadFromJsonAsync<ApiPagedResponse<ApiCashTransactionDto>>(cancellationToken: cancellationToken);
        return payload ?? new ApiPagedResponse<ApiCashTransactionDto>(Array.Empty<ApiCashTransactionDto>(), 0, pageNumber, pageSize);
    }

    public async Task<(bool Success, string? ErrorMessage)> SaveCashTransactionAsync(string token, ApiSaveCashTransactionRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/cash-transactions");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        // Server ka asli sandesh user tak pahunchana hai. Pehle ye method
        // sirf true/false lautata tha, isliye SP ka saaf message (jaise
        // "Please pick the tank this nozzle draws from.") raste me hi gum ho
        // jaata tha aur user ko bas "Unable to save" dikhta tha.
        var error = await ReadErrorMessageAsync(response, "Could not save the cash entry.", cancellationToken);
        return (false, error);
    }

    public async Task<IReadOnlyList<ApiExpenseDto>> GetExpensesAsync(string token, long ownerId, long pumpId, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/expenses?ownerId={ownerId}&pumpId={pumpId}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiExpenseDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiExpenseDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiExpenseDto>() : items;
    }

    public async Task<ApiPagedResponse<ApiExpenseDto>> GetPagedExpensesAsync(
        string token, 
        long ownerId, 
        long pumpId, 
        DateTime? fromDate,
        DateTime? toDate,
        string? searchTerm,
        int pageNumber,
        int pageSize,
        CancellationToken cancellationToken = default)
    {
        var url = $"/api/expenses/paged?ownerId={ownerId}&pumpId={pumpId}";
        if (fromDate.HasValue)
        {
            url += $"&fromDate={fromDate.Value:yyyy-MM-dd}";
        }
        if (toDate.HasValue)
        {
            url += $"&toDate={EndOfDay(toDate.Value)}";
        }
        if (!string.IsNullOrWhiteSpace(searchTerm))
        {
            url += $"&searchTerm={Uri.EscapeDataString(searchTerm)}";
        }
        url += $"&pageNumber={pageNumber}&pageSize={pageSize}";

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return new ApiPagedResponse<ApiExpenseDto>(Array.Empty<ApiExpenseDto>(), 0, pageNumber, pageSize);
        }

        var result = await response.Content.ReadFromJsonAsync<ApiPagedResponse<ApiExpenseDto>>(cancellationToken: cancellationToken);
        return result ?? new ApiPagedResponse<ApiExpenseDto>(Array.Empty<ApiExpenseDto>(), 0, pageNumber, pageSize);
    }

    public async Task<(bool Success, string? ErrorMessage)> SaveExpenseAsync(string token, ApiSaveExpenseRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/expenses");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        // Server ka asli sandesh user tak pahunchana hai. Pehle ye method
        // sirf true/false lautata tha, isliye SP ka saaf message (jaise
        // "Please pick the tank this nozzle draws from.") raste me hi gum ho
        // jaata tha aur user ko bas "Unable to save" dikhta tha.
        var error = await ReadErrorMessageAsync(response, "Could not save the expense.", cancellationToken);
        return (false, error);
    }

    public async Task<ApiPagedResponse<ApiDipReadingDto>> GetPagedDipReadingsAsync(
        string token,
        long ownerId,
        long pumpId,
        DateTime? fromDate,
        DateTime? toDate,
        int pageNumber,
        int pageSize,
        CancellationToken cancellationToken = default)
    {
        var url = $"/api/dip-readings?ownerId={ownerId}&pumpId={pumpId}";
        if (fromDate.HasValue)
        {
            url += $"&fromDate={fromDate.Value:yyyy-MM-dd}";
        }
        if (toDate.HasValue)
        {
            url += $"&toDate={toDate.Value:yyyy-MM-dd}";
        }
        url += $"&pageNumber={pageNumber}&pageSize={pageSize}";

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return new ApiPagedResponse<ApiDipReadingDto>(Array.Empty<ApiDipReadingDto>(), 0, pageNumber, pageSize);
        }

        var payload = await response.Content.ReadFromJsonAsync<ApiPagedResponse<ApiDipReadingDto>>(cancellationToken: cancellationToken);
        return payload ?? new ApiPagedResponse<ApiDipReadingDto>(Array.Empty<ApiDipReadingDto>(), 0, pageNumber, pageSize);
    }

    public async Task<(bool Success, string? ErrorMessage)> SaveDipReadingAsync(
        string token,
        ApiSaveDipReadingRequest requestModel,
        CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/dip-readings");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        var error = await ReadErrorMessageAsync(response, "Unable to save dip reading.", cancellationToken);
        return (false, error);
    }

    public async Task<ApiPagedResponse<ApiTestingLossDto>> GetPagedTestingLossesAsync(
        string token,
        long ownerId,
        long pumpId,
        DateTime? fromDate,
        DateTime? toDate,
        int pageNumber,
        int pageSize,
        CancellationToken cancellationToken = default)
    {
        var url = $"/api/testing-losses?ownerId={ownerId}&pumpId={pumpId}";
        if (fromDate.HasValue)
        {
            url += $"&fromDate={fromDate.Value:yyyy-MM-dd}";
        }
        if (toDate.HasValue)
        {
            url += $"&toDate={toDate.Value:yyyy-MM-dd}";
        }
        url += $"&pageNumber={pageNumber}&pageSize={pageSize}";

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return new ApiPagedResponse<ApiTestingLossDto>(Array.Empty<ApiTestingLossDto>(), 0, pageNumber, pageSize);
        }

        var payload = await response.Content.ReadFromJsonAsync<ApiPagedResponse<ApiTestingLossDto>>(cancellationToken: cancellationToken);
        return payload ?? new ApiPagedResponse<ApiTestingLossDto>(Array.Empty<ApiTestingLossDto>(), 0, pageNumber, pageSize);
    }

    public async Task<(bool Success, string? ErrorMessage)> SaveTestingLossAsync(
        string token,
        ApiSaveTestingLossRequest requestModel,
        CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/testing-losses");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        var error = await ReadErrorMessageAsync(response, "Unable to save testing loss.", cancellationToken);
        return (false, error);
    }

    public async Task<(bool Success, string? ErrorMessage)> UpdateDipReadingAsync(
        string token,
        long id,
        ApiUpdateDipReadingRequest requestModel,
        CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Put, $"/api/dip-readings/{id}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode) return (true, null);
        var error = await ReadErrorMessageAsync(response, "Unable to update dip reading.", cancellationToken);
        return (false, error);
    }

    public async Task<(bool Success, string? ErrorMessage)> ToggleDipReadingActiveAsync(
        string token,
        long id,
        long ownerId,
        long pumpId,
        CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Put, $"/api/dip-readings/{id}/toggle-active?ownerId={ownerId}&pumpId={pumpId}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode) return (true, null);
        var error = await ReadErrorMessageAsync(response, "Unable to toggle dip reading status.", cancellationToken);
        return (false, error);
    }

    public async Task<(bool Success, string? ErrorMessage)> UpdateTestingLossAsync(
        string token,
        long id,
        ApiUpdateTestingLossRequest requestModel,
        CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Put, $"/api/testing-losses/{id}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode) return (true, null);
        var error = await ReadErrorMessageAsync(response, "Unable to update testing loss.", cancellationToken);
        return (false, error);
    }

    public async Task<(bool Success, string? ErrorMessage)> ToggleTestingLossActiveAsync(
        string token,
        long id,
        long ownerId,
        long pumpId,
        CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Put, $"/api/testing-losses/{id}/toggle-active?ownerId={ownerId}&pumpId={pumpId}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode) return (true, null);
        var error = await ReadErrorMessageAsync(response, "Unable to toggle testing loss status.", cancellationToken);
        return (false, error);
    }

    public async Task<IReadOnlyList<ApiDayBookEntryDto>> GetDayBookAsync(string token, long ownerId, long pumpId, DateOnly dateFrom, DateOnly dateTo, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/reports/day-book?ownerId={ownerId}&pumpId={pumpId}&dateFrom={dateFrom:yyyy-MM-dd}&dateTo={dateTo:yyyy-MM-dd}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiDayBookEntryDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiDayBookEntryDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiDayBookEntryDto>() : items;
    }

    public async Task<IReadOnlyList<ApiOutstandingPartyDto>> GetOutstandingAsync(string token, long ownerId, long pumpId, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/reports/outstanding?ownerId={ownerId}&pumpId={pumpId}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiOutstandingPartyDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiOutstandingPartyDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiOutstandingPartyDto>() : items;
    }

    public async Task<IReadOnlyList<ApiPumpComparisonDto>> GetPumpComparisonAsync(string token, long ownerId, DateOnly dateFrom, DateOnly dateTo, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/reports/pump-comparison?ownerId={ownerId}&dateFrom={dateFrom:yyyy-MM-dd}&dateTo={dateTo:yyyy-MM-dd}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiPumpComparisonDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiPumpComparisonDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiPumpComparisonDto>() : items;
    }

    public async Task<IReadOnlyList<ApiMonthlySaleRegisterRow>> GetSalePurchaseRegisterAsync(string token, long pumpId, long productId, int month, int year, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/reports/sale-purchase-register?pumpId={pumpId}&productId={productId}&month={month}&year={year}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiMonthlySaleRegisterRow>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiMonthlySaleRegisterRow>>(cancellationToken: cancellationToken);
        return items ?? new List<ApiMonthlySaleRegisterRow>();
    }

    public async Task<IReadOnlyList<ApiProfitLossLineDto>> GetProfitLossAsync(string token, long pumpId, DateOnly dateFrom, DateOnly dateTo, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/reports/profit-loss?pumpId={pumpId}&dateFrom={dateFrom:yyyy-MM-dd}&dateTo={dateTo:yyyy-MM-dd}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiProfitLossLineDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiProfitLossLineDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiProfitLossLineDto>() : items;
    }

    public async Task<IReadOnlyList<ApiFinancialLineDto>> GetFinancialsAsync(string token, long pumpId, DateOnly dateFrom, DateOnly dateTo, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/reports/financials?pumpId={pumpId}&dateFrom={dateFrom:yyyy-MM-dd}&dateTo={dateTo:yyyy-MM-dd}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiFinancialLineDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiFinancialLineDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiFinancialLineDto>() : items;
    }

    public async Task<IReadOnlyList<ApiAuditLogEntryDto>> GetActivityLogAsync(string token, DateOnly dateFrom, DateOnly dateTo, string? area, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
    {
        var url = $"/api/activity-log?dateFrom={dateFrom:yyyy-MM-dd}&dateTo={dateTo:yyyy-MM-dd}&pageNumber={pageNumber}&pageSize={pageSize}";
        if (!string.IsNullOrWhiteSpace(area)) url += $"&area={Uri.EscapeDataString(area)}";
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiAuditLogEntryDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiAuditLogEntryDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiAuditLogEntryDto>() : items;
    }

    public async Task<IReadOnlyList<ApiDailyStockRegisterDto>> GetDailyStockRegisterAsync(string token, long pumpId, long productId, int month, int year, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/reports/daily-stock-register?pumpId={pumpId}&productId={productId}&month={month}&year={year}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiDailyStockRegisterDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiDailyStockRegisterDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiDailyStockRegisterDto>() : items;
    }

    public async Task<IReadOnlyList<ApiFleetContractDto>> GetFleetContractsAsync(string token, long ownerId, long pumpId, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/fleet-contracts?ownerId={ownerId}&pumpId={pumpId}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiFleetContractDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiFleetContractDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiFleetContractDto>() : items;
    }

    public async Task<(bool Success, string? ErrorMessage)> SaveFleetContractAsync(string token, ApiSaveFleetContractRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/fleet-contracts");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        var error = await response.Content.ReadAsStringAsync(cancellationToken);
        return (false, string.IsNullOrWhiteSpace(error) ? "Unable to save fleet contract." : error.Trim('"'));
    }

    public async Task<IReadOnlyList<ApiCouponBookDto>> GetCouponBooksAsync(string token, long ownerId, long pumpId, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/coupon-books?ownerId={ownerId}&pumpId={pumpId}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiCouponBookDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiCouponBookDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiCouponBookDto>() : items;
    }

    public async Task<(bool Success, string? ErrorMessage)> SaveCouponBookAsync(string token, ApiSaveCouponBookRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/coupon-books");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        // Server ka asli sandesh user tak pahunchana hai. Pehle ye method
        // sirf true/false lautata tha, isliye SP ka saaf message (jaise
        // "Please pick the tank this nozzle draws from.") raste me hi gum ho
        // jaata tha aur user ko bas "Unable to save" dikhta tha.
        var error = await ReadErrorMessageAsync(response, "Could not save the coupon book.", cancellationToken);
        return (false, error);
    }

    public async Task<IReadOnlyList<ApiCouponTransactionDto>> GetCouponTransactionsAsync(string token, long ownerId, long pumpId, long? couponBookId, CancellationToken cancellationToken = default)
    {
        var url = $"/api/coupon-transactions?ownerId={ownerId}&pumpId={pumpId}";
        if (couponBookId is > 0)
        {
            url += $"&couponBookId={couponBookId.Value}";
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiCouponTransactionDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiCouponTransactionDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiCouponTransactionDto>() : items;
    }

    public async Task<(bool Success, string? ErrorMessage)> SaveCouponTransactionAsync(string token, ApiSaveCouponTransactionRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/coupon-transactions");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        // Server ka asli sandesh user tak pahunchana hai. Pehle ye method
        // sirf true/false lautata tha, isliye SP ka saaf message (jaise
        // "Please pick the tank this nozzle draws from.") raste me hi gum ho
        // jaata tha aur user ko bas "Unable to save" dikhta tha.
        var error = await ReadErrorMessageAsync(response, "Could not save the coupon entry.", cancellationToken);
        return (false, error);
    }

    public async Task<(bool Success, string? ErrorMessage)> SaveProductAsync(string token, ApiSaveProductRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/products");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        // Server ka asli sandesh user tak pahunchana hai. Pehle ye method
        // sirf true/false lautata tha, isliye SP ka saaf message (jaise
        // "Please pick the tank this nozzle draws from.") raste me hi gum ho
        // jaata tha aur user ko bas "Unable to save" dikhta tha.
        var error = await ReadErrorMessageAsync(response, "Could not save the product.", cancellationToken);
        return (false, error);
    }

    public async Task<(bool Success, string? ErrorMessage)> DeleteProductAsync(string token, long id, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Delete, $"/api/products/{id}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }
        var error = await ReadErrorMessageAsync(response, "Unable to delete product.", cancellationToken);
        return (false, error);
    }

    public async Task<(bool Success, string? ErrorMessage)> OpenShiftAsync(string token, ApiOpenShiftRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/shifts/open");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        var error = await ReadErrorMessageAsync(response, "Unable to open shift.", cancellationToken);
        return (false, error);
    }

    public async Task<(bool Success, string? ErrorMessage)> CloseShiftAsync(string token, long shiftId, ApiCloseShiftRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, $"/api/shifts/{shiftId}/close");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        var error = await ReadErrorMessageAsync(response, "Unable to close shift.", cancellationToken);
        return (false, error);
    }

    /// <summary>Close Shift form ke liye pump ke tank + (edit par) pehle se padi dip.</summary>
    public async Task<IReadOnlyList<ApiShiftClosingDipRow>> GetShiftClosingDipsAsync(string token, long shiftId, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/shifts/{shiftId}/closing-dips");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode) return Array.Empty<ApiShiftClosingDipRow>();
        return await response.Content.ReadFromJsonAsync<List<ApiShiftClosingDipRow>>(cancellationToken: cancellationToken)
               ?? new List<ApiShiftClosingDipRow>();
    }

    public async Task<(bool Success, IReadOnlyList<ApiShiftClosingDipSaved> Saved, string? ErrorMessage)> SaveShiftClosingDipsAsync(
        string token, long shiftId, ApiSaveShiftClosingDipsRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, $"/api/shifts/{shiftId}/closing-dips");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            var saved = await response.Content.ReadFromJsonAsync<List<ApiShiftClosingDipSaved>>(cancellationToken: cancellationToken)
                        ?? new List<ApiShiftClosingDipSaved>();
            return (true, saved, null);
        }

        var error = await ReadErrorMessageAsync(response, "Unable to save the dip.", cancellationToken);
        return (false, Array.Empty<ApiShiftClosingDipSaved>(), error);
    }

    /// <summary>Dip ke liye book stock — DSR wala hisaab (Section AB).</summary>
    public async Task<decimal> GetDipBookStockAsync(string token, long tankId, DateOnly date, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/tanks/{tankId}/dip-book-stock?date={date:yyyy-MM-dd}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode) return 0;
        var result = await response.Content.ReadFromJsonAsync<DipBookStockResponse>(cancellationToken: cancellationToken);
        return result?.Stock ?? 0;
    }

    private sealed record DipBookStockResponse(decimal Stock);

    public async Task<(bool Success, decimal TotalCounted, string? ErrorMessage)> SaveShiftCashDenominationAsync(string token, long shiftId, ApiSaveCashDenominationRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, $"/api/shifts/{shiftId}/cash-denomination");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            var error = await ReadErrorMessageAsync(response, "Unable to save cash denomination.", cancellationToken);
            return (false, 0, error);
        }

        var payload = await response.Content.ReadFromJsonAsync<CashDenominationSaveResult>(cancellationToken: cancellationToken);
        return (true, payload?.TotalCounted ?? 0, null);
    }

    private sealed record CashDenominationSaveResult(decimal TotalCounted);

    public async Task<IReadOnlyList<ApiShiftNozzleReadingDto>> GetShiftNozzleReadingsAsync(string token, long shiftId, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/shifts/{shiftId}/nozzle-readings");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiShiftNozzleReadingDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiShiftNozzleReadingDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiShiftNozzleReadingDto>() : items;
    }

    public async Task<IReadOnlyList<ApiShiftNozzleReadingDto>> GetLastNozzleReadingsAsync(string token, long pumpId, DateOnly? beforeDate = null, CancellationToken cancellationToken = default)
    {
        var url = $"/api/pumps/{pumpId}/last-nozzle-readings";
        if (beforeDate is not null)
        {
            url += $"?beforeDate={beforeDate.Value:yyyy-MM-dd}";
        }
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode) return Array.Empty<ApiShiftNozzleReadingDto>();
        var items = await response.Content.ReadFromJsonAsync<List<ApiShiftNozzleReadingDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiShiftNozzleReadingDto>() : items;
    }

    /// <summary>
    /// "Kis tareekh TAK" — us din ka aakhri pal, query string ke liye.
    ///
    /// Jin list ka samay wala column hai (bill 8:00 raat, kharcha 3:15 dopahar) unke SP
    /// `column &lt;= @ToDate` lagate hain. Sirf tareekh (yyyy-MM-dd) bhejne par API use raat
    /// 12:00 maanti hai, aur "10 tak" chunne par 10 tareekh ki saari entry bahar ho jaati
    /// thi — Sales ki list, Sales ka CSV aur Expenses, teeno me.
    /// (Jin list ka column sirf DATE hai — shift, dip, purchase — unhe iski zaroorat nahi.)
    /// </summary>
    private static string EndOfDay(DateTime day)
        => Uri.EscapeDataString(day.Date.AddDays(1).AddTicks(-1).ToString("yyyy-MM-ddTHH:mm:ss.fffffff", System.Globalization.CultureInfo.InvariantCulture));

    public async Task<ApiPagedResponse<ApiSaleDto>> GetSalesAsync(
        string token, 
        long ownerId, 
        long? pumpId, 
        DateTime? fromDate,
        DateTime? toDate,
        string? searchTerm,
        int pageNumber,
        int pageSize,
        CancellationToken cancellationToken = default)
    {
        var url = $"/api/sales?ownerId={ownerId}";
        if (pumpId is > 0)
        {
            url += $"&pumpId={pumpId.Value}";
        }
        if (fromDate.HasValue)
        {
            url += $"&fromDate={fromDate.Value:yyyy-MM-dd}";
        }
        if (toDate.HasValue)
        {
            url += $"&toDate={EndOfDay(toDate.Value)}";
        }
        if (!string.IsNullOrWhiteSpace(searchTerm))
        {
            url += $"&searchTerm={Uri.EscapeDataString(searchTerm)}";
        }
        url += $"&pageNumber={pageNumber}&pageSize={pageSize}";

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return new ApiPagedResponse<ApiSaleDto>(Array.Empty<ApiSaleDto>(), 0, pageNumber, pageSize);
        }

        var result = await response.Content.ReadFromJsonAsync<ApiPagedResponse<ApiSaleDto>>(cancellationToken: cancellationToken);
        return result ?? new ApiPagedResponse<ApiSaleDto>(Array.Empty<ApiSaleDto>(), 0, pageNumber, pageSize);
    }

    public async Task<ApiSaveSaleResult> SaveSaleAsync(string token, ApiSaveSaleRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/sales");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            var errorText = await ReadErrorMessageAsync(response, $"Unable to save sale. API returned {(int)response.StatusCode}.", cancellationToken);
            return new ApiSaveSaleResult(null, errorText);
        }

        var payload = await response.Content.ReadFromJsonAsync<SaveResult>(cancellationToken: cancellationToken);
        return new ApiSaveSaleResult(payload?.Id, null);
    }

    public async Task<ApiReceiptDto?> GenerateReceiptAsync(string token, long saleId, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, $"/api/sales/{saleId}/receipt");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return null;
        }

        return await response.Content.ReadFromJsonAsync<ApiReceiptDto>(cancellationToken: cancellationToken);
    }

    public async Task<IReadOnlyList<ApiUserDto>> GetUsersAsync(string token, long ownerId, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/users?ownerId={ownerId}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiUserDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiUserDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiUserDto>() : items;
    }

    public async Task<(bool Success, string? ErrorMessage)> SaveUserAsync(string token, ApiSaveUserRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/users");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        // Server ka asli sandesh user tak pahunchana hai. Pehle ye method
        // sirf true/false lautata tha, isliye SP ka saaf message (jaise
        // "Please pick the tank this nozzle draws from.") raste me hi gum ho
        // jaata tha aur user ko bas "Unable to save" dikhta tha.
        var error = await ReadErrorMessageAsync(response, "Could not save the user.", cancellationToken);
        return (false, error);
    }

    // ---- Message credits (Section Q) ----
    private async Task<T?> GetJsonAsync<T>(string token, string url, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, ct);
        if (!response.IsSuccessStatusCode) { return default; }
        return await response.Content.ReadFromJsonAsync<T>(cancellationToken: ct);
    }

    private async Task<(bool Success, string? ErrorMessage)> PostJsonAsync(string token, string url, object body, string fallback, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(body, body.GetType());
        var response = await httpClient.SendAsync(request, ct);
        if (response.IsSuccessStatusCode) { return (true, null); }
        return (false, await ReadErrorMessageAsync(response, fallback, ct));
    }

    /// <summary>
    /// Meter ki tooti hui kadi (Section R2). Sirf dikhane ke liye — koi rok nahi.
    /// Fail ho jaye to khaali list, taaki Shifts page isi wajah se na ruke.
    /// </summary>
    /// <summary>Din ka collection padho (Section W).</summary>
    public async Task<ApiShiftCollection> GetShiftCollectionAsync(string token, long shiftId, CancellationToken ct = default)
    {
        var data = await GetJsonAsync<ApiShiftCollection>(token, $"/api/shifts/{shiftId}/collection", ct);
        return data ?? new ApiShiftCollection(0, 0, new List<ApiShiftCollectionCreditLine>());
    }

    public Task<(bool Success, string? ErrorMessage)> SaveShiftCollectionAsync(string token, ApiSaveShiftCollectionRequest body, CancellationToken ct = default)
        => PostJsonAsync(token, $"/api/shifts/{body.ShiftId}/collection", body, "Could not save the collection.", ct);

    public async Task<IReadOnlyList<ApiMeterChainGap>> GetMeterChainGapsAsync(string token, long? pumpId, int days = 90, CancellationToken ct = default)
    {
        var url = $"/api/shifts/meter-chain?days={days}" + (pumpId is > 0 ? $"&pumpId={pumpId}" : string.Empty);
        var rows = await GetJsonAsync<List<ApiMeterChainGap>>(token, url, ct);
        return rows ?? new List<ApiMeterChainGap>();
    }

    public Task<ApiPlatformCreditSummary?> GetPlatformCreditAsync(string token, CancellationToken ct = default)
        => GetJsonAsync<ApiPlatformCreditSummary>(token, "/api/platform-credit", ct);

    public Task<(bool Success, string? ErrorMessage)> AddPlatformCreditAsync(string token, ApiAddPlatformCreditRequest body, CancellationToken ct = default)
        => PostJsonAsync(token, "/api/platform-credit", body, "Could not record the purchase.", ct);

    public Task<(bool Success, string? ErrorMessage)> SaveCreditSettingsAsync(string token, ApiSaveCreditSettingsRequest body, CancellationToken ct = default)
        => PostJsonAsync(token, "/api/platform-credit/settings", body, "Could not save the settings.", ct);

    public async Task<IReadOnlyList<ApiRechargeRequestDto>> GetAllRechargesAsync(string token, string? status, CancellationToken ct = default)
        => await GetJsonAsync<List<ApiRechargeRequestDto>>(token, "/api/platform-credit/recharges" + (string.IsNullOrEmpty(status) ? "" : "?status=" + status), ct)
           ?? (IReadOnlyList<ApiRechargeRequestDto>)Array.Empty<ApiRechargeRequestDto>();

    public Task<(bool Success, string? ErrorMessage)> ApproveRechargeAsync(string token, long id, string? note, CancellationToken ct = default)
        => PostJsonAsync(token, $"/api/platform-credit/recharges/{id}/approve", new ApiDecideRechargeRequest(note), "Could not approve the recharge.", ct);

    public Task<(bool Success, string? ErrorMessage)> RejectRechargeAsync(string token, long id, string? note, CancellationToken ct = default)
        => PostJsonAsync(token, $"/api/platform-credit/recharges/{id}/reject", new ApiDecideRechargeRequest(note), "Could not reject the recharge.", ct);

    public Task<ApiWalletDto?> GetWalletAsync(string token, CancellationToken ct = default)
        => GetJsonAsync<ApiWalletDto>(token, "/api/wallet", ct);

    public async Task<IReadOnlyList<ApiCreditLedgerDto>> GetWalletLedgerAsync(string token, CancellationToken ct = default)
        => await GetJsonAsync<List<ApiCreditLedgerDto>>(token, "/api/wallet/ledger?top=50", ct)
           ?? (IReadOnlyList<ApiCreditLedgerDto>)Array.Empty<ApiCreditLedgerDto>();

    public async Task<IReadOnlyList<ApiRechargeRequestDto>> GetMyRechargesAsync(string token, CancellationToken ct = default)
        => await GetJsonAsync<List<ApiRechargeRequestDto>>(token, "/api/wallet/recharges", ct)
           ?? (IReadOnlyList<ApiRechargeRequestDto>)Array.Empty<ApiRechargeRequestDto>();

    public Task<(bool Success, string? ErrorMessage)> RequestRechargeAsync(string token, decimal amount, string? upiReference, CancellationToken ct = default)
        => PostJsonAsync(token, "/api/wallet/recharge", new ApiRequestRechargeInput(amount, upiReference), "Could not submit the recharge request.", ct);

    // ---- Owner alerts (Section P) ----
    public async Task<ApiOwnerAlertsResponse> GetOwnerAlertsAsync(string token, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, "/api/owner-alerts");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return new ApiOwnerAlertsResponse(null, Array.Empty<ApiOwnerAlertDto>());
        }

        var body = await response.Content.ReadFromJsonAsync<ApiOwnerAlertsResponse>(cancellationToken: cancellationToken);
        return body ?? new ApiOwnerAlertsResponse(null, Array.Empty<ApiOwnerAlertDto>());
    }

    public async Task<(bool Success, string? ErrorMessage)> SaveOwnerAlertAsync(string token, string alertKey, bool isEnabled, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/owner-alerts");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(new ApiSaveOwnerAlertRequest(alertKey, isEnabled));
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        var error = await ReadErrorMessageAsync(response, "Could not save the alert setting.", cancellationToken);
        return (false, error);
    }

    public async Task<(bool Success, string? ErrorMessage)> SaveOwnerAlertMobileAsync(string token, string? mobile, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/owner-alerts/mobile");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(new ApiSaveOwnerAlertMobileRequest(mobile));
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        var error = await ReadErrorMessageAsync(response, "Could not save the mobile number.", cancellationToken);
        return (false, error);
    }

    // ---- Staff: employee + login ek saath (Section L) ----
    public async Task<IReadOnlyList<ApiStaffDto>> GetStaffAsync(string token, long ownerId, long pumpId, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/staff?ownerId={ownerId}&pumpId={pumpId}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiStaffDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiStaffDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiStaffDto>() : items;
    }

    public async Task<(bool Success, string? ErrorMessage)> SaveStaffAsync(string token, ApiSaveStaffRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/staff");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        var error = await ReadErrorMessageAsync(response, "Unable to save this person.", cancellationToken);
        return (false, error);
    }

    public async Task<IReadOnlyList<ApiEmployeeDto>> GetEmployeesAsync(string token, long ownerId, long pumpId, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/employees?ownerId={ownerId}&pumpId={pumpId}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiEmployeeDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiEmployeeDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiEmployeeDto>() : items;
    }

    public async Task<(bool Success, string? ErrorMessage)> SaveEmployeeAsync(string token, ApiSaveEmployeeRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/employees");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        var error = await ReadErrorMessageAsync(response, "Unable to save employee.", cancellationToken);
        return (false, error);
    }

    public async Task<IReadOnlyList<ApiSalaryPaymentDto>> GetSalaryPaymentsAsync(string token, long ownerId, long pumpId, int? salaryYear, int? salaryMonth, CancellationToken cancellationToken = default)
    {
        var url = $"/api/salary-payments?ownerId={ownerId}&pumpId={pumpId}";
        if (salaryYear is > 0)
        {
            url += $"&salaryYear={salaryYear.Value}";
        }
        if (salaryMonth is > 0)
        {
            url += $"&salaryMonth={salaryMonth.Value}";
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiSalaryPaymentDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiSalaryPaymentDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiSalaryPaymentDto>() : items;
    }

    public async Task<(bool Success, string? ErrorMessage)> SaveSalaryPaymentAsync(string token, ApiSaveSalaryPaymentRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/salary-payments");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        var error = await ReadErrorMessageAsync(response, "Unable to save salary payment.", cancellationToken);
        return (false, error);
    }

    public async Task<(bool Success, string? ErrorMessage)> DeleteUserAsync(string token, long id, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Delete, $"/api/users/{id}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }
        
        var error = await ReadErrorMessageAsync(response, "Unable to delete user.", cancellationToken);
        return (false, error);
    }

    public async Task<IReadOnlyList<ApiRoleDto>> GetRolesAsync(string token, long ownerId, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/roles?ownerId={ownerId}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiRoleDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiRoleDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiRoleDto>() : items;
    }

    public async Task<(bool Success, string? ErrorMessage)> SaveRoleAsync(string token, ApiSaveRoleRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/roles");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        // Server ka asli sandesh user tak pahunchana hai. Pehle ye method
        // sirf true/false lautata tha, isliye SP ka saaf message (jaise
        // "Please pick the tank this nozzle draws from.") raste me hi gum ho
        // jaata tha aur user ko bas "Unable to save" dikhta tha.
        var error = await ReadErrorMessageAsync(response, "Could not save the role.", cancellationToken);
        return (false, error);
    }

    public async Task<IReadOnlyList<ApiRoleMenuDto>> GetRoleMenusAsync(string token, long roleId, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/roles/{roleId}/menus");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiRoleMenuDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiRoleMenuDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiRoleMenuDto>() : items;
    }

    public async Task<(bool Success, string? ErrorMessage)> SaveRoleMenusAsync(string token, ApiSaveRoleMenusRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/roles/menus");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        // Server ka asli sandesh user tak pahunchana hai. Pehle ye method
        // sirf true/false lautata tha, isliye SP ka saaf message (jaise
        // "Please pick the tank this nozzle draws from.") raste me hi gum ho
        // jaata tha aur user ko bas "Unable to save" dikhta tha.
        var error = await ReadErrorMessageAsync(response, "Could not save the permissions.", cancellationToken);
        return (false, error);
    }

    public async Task<IReadOnlyList<ApiOwnerDto>> GetOwnersAsync(string token, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, "/api/owners");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return Array.Empty<ApiOwnerDto>();
        }

        var items = await response.Content.ReadFromJsonAsync<List<ApiOwnerDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiOwnerDto>() : items;
    }

    public async Task<(bool Success, string? ErrorMessage)> SaveOwnerAsync(string token, ApiSaveOwnerRequest requestModel, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/owners");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(requestModel);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        // Server ka asli sandesh user tak pahunchana hai. Pehle ye method
        // sirf true/false lautata tha, isliye SP ka saaf message (jaise
        // "Please pick the tank this nozzle draws from.") raste me hi gum ho
        // jaata tha aur user ko bas "Unable to save" dikhta tha.
        var error = await ReadErrorMessageAsync(response, "Could not save the owner.", cancellationToken);
        return (false, error);
    }

    public async Task<(bool Success, string? ErrorMessage)> ToggleOwnerStatusAsync(string token, long ownerId, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Put, $"/api/owners/{ownerId}/toggle-status");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        // Server ka asli sandesh user tak pahunchana hai. Pehle ye method
        // sirf true/false lautata tha, isliye SP ka saaf message (jaise
        // "Please pick the tank this nozzle draws from.") raste me hi gum ho
        // jaata tha aur user ko bas "Unable to save" dikhta tha.
        var error = await ReadErrorMessageAsync(response, "Could not change the tenant status.", cancellationToken);
        return (false, error);
    }

    public async Task<(bool Success, string? ErrorMessage)> ExtendOwnerTrialAsync(string token, long ownerId, DateTime newValidUpto, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Put, $"/api/owners/{ownerId}/extend-trial");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(new { newValidUpto });

        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        // Server ka asli sandesh user tak pahunchana hai. Pehle ye method
        // sirf true/false lautata tha, isliye SP ka saaf message (jaise
        // "Please pick the tank this nozzle draws from.") raste me hi gum ho
        // jaata tha aur user ko bas "Unable to save" dikhta tha.
        var error = await ReadErrorMessageAsync(response, "Could not extend the trial.", cancellationToken);
        return (false, error);
    }

    public async Task<IReadOnlyList<ApiSubscriptionRequestDto>> GetSubscriptionRequestsAsync(string token, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, "/api/subscription-requests");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode) return Array.Empty<ApiSubscriptionRequestDto>();
        var items = await response.Content.ReadFromJsonAsync<List<ApiSubscriptionRequestDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiSubscriptionRequestDto>() : items;
    }

    public async Task<(bool Success, string? ErrorMessage)> MarkSubscriptionDoneAsync(string token, long id, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Put, $"/api/subscription-requests/{id}/mark-done");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        // Server ka asli sandesh user tak pahunchana hai. Pehle ye method
        // sirf true/false lautata tha, isliye SP ka saaf message (jaise
        // "Please pick the tank this nozzle draws from.") raste me hi gum ho
        // jaata tha aur user ko bas "Unable to save" dikhta tha.
        var error = await ReadErrorMessageAsync(response, "Could not mark this request as done.", cancellationToken);
        return (false, error);
    }

    public async Task<(bool Success, string? ErrorMessage)> SubmitSubscriptionRequestAsync(ApiSaveSubscriptionRequest requestDto, CancellationToken cancellationToken = default)
    {
        var response = await httpClient.PostAsJsonAsync("/api/subscription-requests", requestDto, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        // Server ka asli sandesh user tak pahunchana hai. Pehle ye method
        // sirf true/false lautata tha, isliye SP ka saaf message (jaise
        // "Please pick the tank this nozzle draws from.") raste me hi gum ho
        // jaata tha aur user ko bas "Unable to save" dikhta tha.
        var error = await ReadErrorMessageAsync(response, "Could not submit your request.", cancellationToken);
        return (false, error);
    }

    public async Task<(bool Success, string? ErrorMessage)> DeleteExpenseAsync(string token, long id, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Delete, $"/api/expenses/{id}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        var error = await ReadErrorMessageAsync(response, "Unable to delete expense.", cancellationToken);
        return (false, error);
    }

    public async Task<(bool Success, string? ErrorMessage)> DeletePurchaseAsync(string token, long id, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Delete, $"/api/purchase/{id}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        var error = await ReadErrorMessageAsync(response, "Unable to delete purchase.", cancellationToken);
        return (false, error);
    }

    public async Task<(bool Success, string? ErrorMessage)> DeleteCashTransactionAsync(string token, long id, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Delete, $"/api/cash-transactions/{id}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        var error = await ReadErrorMessageAsync(response, "Unable to delete cash transaction.", cancellationToken);
        return (false, error);
    }

    public async Task<(bool Success, string? ErrorMessage)> VoidSaleAsync(string token, long id, string? reason = null, CancellationToken cancellationToken = default)
    {
        var url = $"/api/sales/{id}/void";
        if (!string.IsNullOrWhiteSpace(reason))
        {
            url += "?reason=" + Uri.EscapeDataString(reason);
        }

        using var request = new HttpRequestMessage(HttpMethod.Delete, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }
        var error = await ReadErrorMessageAsync(response, "Unable to void sale.", cancellationToken);
        return (false, error);
    }

    public async Task<(bool Success, string? ErrorMessage)> DeleteVendorAsync(string token, long id, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Delete, $"/api/vendors/{id}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        var error = await ReadErrorMessageAsync(response, "Unable to delete vendor.", cancellationToken);
        return (false, error);
    }

    public async Task<(bool Success, string? ErrorMessage)> DeleteExpenseHeadAsync(string token, long id, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Delete, $"/api/expense-heads/{id}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        var error = await ReadErrorMessageAsync(response, "Unable to delete expense head.", cancellationToken);
        return (false, error);
    }

    public async Task<(bool Success, string? ErrorMessage)> DeleteEmployeeAsync(string token, long id, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Delete, $"/api/employees/{id}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }

        var error = await ReadErrorMessageAsync(response, "Unable to delete employee.", cancellationToken);
        return (false, error);
    }

    private static async Task<string> ReadErrorMessageAsync(HttpResponseMessage response, string fallbackMessage, CancellationToken cancellationToken)
    {
        var raw = await response.Content.ReadAsStringAsync(cancellationToken);
        if (string.IsNullOrWhiteSpace(raw))
        {
            return fallbackMessage;
        }

        try
        {
            var envelope = JsonSerializer.Deserialize<ApiErrorEnvelope>(raw, new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true
            });

            if (!string.IsNullOrWhiteSpace(envelope?.Message))
            {
                return envelope.Message;
            }
        }
        catch
        {
            // Fall back to raw string below.
        }

        return raw.Trim('"');
    }

    public async Task<decimal> GetTankStockAsOfDateAsync(string token, long id, long ownerId, DateOnly date, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/tanks/{id}/stock-as-of?date={date:yyyy-MM-dd}&ownerId={ownerId}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return 0;
        }

        var result = await response.Content.ReadFromJsonAsync<StockResponse>(cancellationToken: cancellationToken);
        return result?.Stock ?? 0;
    }

    private sealed record StockResponse(decimal Stock);
    private sealed record ApiErrorEnvelope(bool Success, string? Message, object? Data);
    private sealed record SaveResult(long Id);

    // ── Support console (Section Z) — sirf Super Admin ────────────────────────
    // ownerId query me jaata hai kyunki support wala KISI BHI owner ka data
    // theek karta hai; API par "SuperAdminOnly" policy lagi hai.

    public async Task<IReadOnlyList<ApiSupportShiftDto>> GetSupportShiftsAsync(string token, long ownerId, long? pumpId, int days, CancellationToken cancellationToken = default)
    {
        var url = $"/api/support/shifts?ownerId={ownerId}&days={days}";
        if (pumpId is > 0) url += $"&pumpId={pumpId}";

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode) return Array.Empty<ApiSupportShiftDto>();
        var items = await response.Content.ReadFromJsonAsync<List<ApiSupportShiftDto>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiSupportShiftDto>() : items;
    }

    public async Task<(bool Success, string? ErrorMessage)> ReopenShiftAsync(string token, long shiftId, long ownerId, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, $"/api/support/shifts/{shiftId}/reopen?ownerId={ownerId}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode) return (true, null);
        return (false, await ReadErrorMessageAsync(response, cancellationToken));
    }

    public async Task<(bool Success, string? ErrorMessage)> DeleteShiftAsync(string token, long shiftId, long ownerId, string? reason, CancellationToken cancellationToken = default)
    {
        var url = $"/api/support/shifts/{shiftId}?ownerId={ownerId}";
        if (!string.IsNullOrWhiteSpace(reason)) url += $"&reason={Uri.EscapeDataString(reason)}";

        using var request = new HttpRequestMessage(HttpMethod.Delete, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode) return (true, null);
        return (false, await ReadErrorMessageAsync(response, cancellationToken));
    }

    /// <summary>SP ka asli sandesh nikaalo — "kuch gadbad ho gayi" se kaam nahi chalta.</summary>
    private static async Task<string> ReadErrorMessageAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        try
        {
            var body = await response.Content.ReadAsStringAsync(cancellationToken);
            if (!string.IsNullOrWhiteSpace(body))
            {
                using var doc = System.Text.Json.JsonDocument.Parse(body);
                if (doc.RootElement.TryGetProperty("message", out var m) ||
                    doc.RootElement.TryGetProperty("Message", out m))
                {
                    var text = m.GetString();
                    if (!string.IsNullOrWhiteSpace(text)) return text;
                }
            }
        }
        catch
        {
            // JSON na ho to neeche wala aam sandesh chala jayega.
        }
        return $"Request failed ({(int)response.StatusCode}).";
    }

    public async Task<IReadOnlyList<ApiMeterChainGap>> GetSupportMeterChainAsync(string token, long ownerId, long? pumpId, int days, CancellationToken cancellationToken = default)
    {
        var url = $"/api/support/meter-chain?ownerId={ownerId}&days={days}";
        if (pumpId is > 0) url += $"&pumpId={pumpId}";

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode) return Array.Empty<ApiMeterChainGap>();
        var items = await response.Content.ReadFromJsonAsync<List<ApiMeterChainGap>>(cancellationToken: cancellationToken);
        return items is null ? Array.Empty<ApiMeterChainGap>() : items;
    }

    public async Task<(bool Success, int UpdatedParties, string? ErrorMessage)> RecalculatePartyBalancesAsync(string token, long ownerId, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, $"/api/support/parties/recalculate?ownerId={ownerId}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return (false, 0, await ReadErrorMessageAsync(response, cancellationToken));
        }

        var body = await response.Content.ReadFromJsonAsync<RecalcResult>(cancellationToken: cancellationToken);
        return (true, body?.UpdatedParties ?? 0, null);
    }

    private sealed record RecalcResult(bool Success, int UpdatedParties);
}

public sealed record ApiSaveSaleResult(long? Id, string? ErrorMessage);
