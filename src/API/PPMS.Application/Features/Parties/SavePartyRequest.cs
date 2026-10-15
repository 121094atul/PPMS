namespace PPMS.Application.Features.Parties;

public sealed record SavePartyRequest(
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
    // Edit me: user ne baki ka khaana chhua hi nahi -> true, aur sp_Party_Save baki ko
    // haath nahi lagata. Iske bina form khulne aur save hone ke beech aayi koi jama /
    // udhaar form ke purane ank se dab jaati thi. Purana client ise nahi bhejta (false).
    bool KeepBalance = false
);
