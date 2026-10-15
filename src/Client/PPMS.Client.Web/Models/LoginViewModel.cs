namespace PPMS.Client.Web.Models;

public sealed class LoginViewModel
{
    public string Username { get; set; } = string.Empty;
    public string Password { get; set; } = string.Empty;
    public string? ErrorMessage { get; set; }

    /// <summary>Plan khatam / account band par page support ka number bhi dikhata hai.</summary>
    public string? ErrorCode { get; set; }
}
