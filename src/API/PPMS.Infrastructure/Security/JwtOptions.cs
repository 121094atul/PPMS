namespace PPMS.Infrastructure.Security;

public sealed class JwtOptions
{
    public const string SectionName = "Jwt";
    public string Key { get; set; } = "ChangeThisKey_AtLeast32Chars_Long!";
    public string Issuer { get; set; } = "PPMS";
    public string Audience { get; set; } = "PPMS.Client";
    public int ExpiryMinutes { get; set; } = 480;
}
