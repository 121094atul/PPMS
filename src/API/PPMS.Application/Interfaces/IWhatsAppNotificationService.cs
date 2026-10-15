namespace PPMS.Application.Interfaces;

public interface IWhatsAppNotificationService
{
    Task<bool> SendMessageAsync(string phoneNumber, string message, CancellationToken cancellationToken = default);

    /// <summary>
    /// Owner ko alert bhejo — number khud us OWNER ka nikalta hai.
    ///
    /// <para>Pehle cheh jagah <c>SendMessageAsync("", msg)</c> likha tha, aur khaali ""
    /// dekh kar service DB se <c>SELECT TOP 1 Mobile FROM Users WHERE IsOwner = 1</c>
    /// karti thi — <b>bina OwnerId ke</b>. Multi-tenant me wo kisi bhi pump ke malik ka
    /// number utha leti thi, yaani ek pump ki bikri doosre ke phone par. Wo code
    /// security review me hata diya gaya, isliye ab wo cheho alert bhejte hi nahi.</para>
    ///
    /// <para>Ye method usi ki jagah hai. Number <c>Owners.ContactNo</c> se (aur wo
    /// khaali ho to usi owner ke owner-user ke mobile se) aata hai — dono jagah
    /// OwnerId ka filter hai. Saath me ye bhi dekhta hai ki owner ne is alert ko
    /// chaalu rakha hai ya nahi.</para>
    ///
    /// <param name="alertKey">SHIFT_CLOSE, PURCHASE, STOCK_LOSS, BANK_DEPOSIT,
    /// BIG_EXPENSE, PARTY_LEDGER me se koi ek.</param>
    /// </summary>
    Task<bool> SendToOwnerAsync(long ownerId, string alertKey, string message, CancellationToken cancellationToken = default);

    /// <summary>
    /// Bhejne ka intezaam hai bhi ya nahi (provider chuna hai aur uski key set hai).
    /// Config ki jaanch yahan Infrastructure me hoti hai — Application layer ko
    /// IConfiguration se joda nahi ja raha.
    ///
    /// Zaroori isliye hai ki OTP ka intezaam na ho to "OTP bhej diya" likhna jhooth
    /// hai; user hamesha ke liye atka rehta hai.
    /// </summary>
    bool IsConfigured { get; }
}
