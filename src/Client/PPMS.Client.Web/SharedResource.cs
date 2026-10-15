namespace PPMS.Client.Web;

/// <summary>
/// Localization ka marker class.
///
/// Tarika: view me English text hi "key" hai — jaise @L["Save"]. Culture "en" par
/// koi resource file dhoondhi hi nahi jaati, key wapas aa jaati hai (yaani English).
/// Sirf Hindi ke liye Resources/SharedResource.hi.resx me tarjuma hai. Isse ek hi
/// file maintain karni padti hai aur English kabhi missing nahi ho sakti.
///
/// NOTE: ye class jaanbujh kar project ke ROOT namespace me hai (Resources folder ke
/// andar NAHI). ResourcesPath="Resources" hone par agar class bhi Resources folder me
/// hoti to ASP.NET Core "Resources/Resources.SharedResource.hi.resx" dhoondhta aur
/// tarjuma kabhi milta hi nahi.
/// </summary>
public sealed class SharedResource
{
}
