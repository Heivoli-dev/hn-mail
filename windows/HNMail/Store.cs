using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace HNMail;

/// <summary>Réglages et état de l'app, rangés dans %APPDATA%\HN Mail. Les clés sont chiffrées pour ta session Windows (DPAPI).</summary>
public sealed class Store
{
    public static readonly string Folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "HN Mail");
    private static readonly string StatePath = Path.Combine(Folder, "state.json");

    public JsonObject State { get; private set; } = new();

    public Store()
    {
        Directory.CreateDirectory(Folder);
        try
        {
            if (File.Exists(StatePath)) State = JsonNode.Parse(File.ReadAllText(StatePath)) as JsonObject ?? new JsonObject();
        }
        catch { State = new JsonObject(); }
    }

    public void Save()
    {
        var temp = StatePath + ".tmp";
        File.WriteAllText(temp, State.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temp, StatePath, true);
    }

    // ----- clés secrètes -----
    public string? GetSecret(string name)
    {
        var value = State["secrets"]?[name]?.GetValue<string>();
        if (string.IsNullOrEmpty(value)) return null;
        try
        {
            var bytes = ProtectedData.Unprotect(Convert.FromBase64String(value), Encoding.UTF8.GetBytes("hn-mail"), DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(bytes);
        }
        catch { return null; }
    }

    public void SetSecret(string name, string? value)
    {
        var secrets = State["secrets"] as JsonObject ?? new JsonObject();
        if (string.IsNullOrWhiteSpace(value)) secrets.Remove(name);
        else
        {
            var bytes = ProtectedData.Protect(Encoding.UTF8.GetBytes(value.Trim()), Encoding.UTF8.GetBytes("hn-mail"), DataProtectionScope.CurrentUser);
            secrets[name] = Convert.ToBase64String(bytes);
        }
        State["secrets"] = secrets;
        Save();
    }

    public bool InboxConfigured => (GetSecret("inboxKey") ?? "").Length >= 24;
    public bool BrevoConfigured => !string.IsNullOrEmpty(GetSecret("brevoKey"));

    // ----- préférences -----
    public int PollMinutes
    {
        get => State["pollMinutes"]?.GetValue<int>() is int v && v > 0 ? v : 2;
        set { State["pollMinutes"] = Math.Clamp(value, 1, 60); Save(); }
    }

    public bool Notifications
    {
        get => State["notifications"]?.GetValue<bool>() ?? true;
        set { State["notifications"] = value; Save(); }
    }

    // ----- mails déjà vus / répondus -----
    public HashSet<string> Seen()
    {
        var list = State["seen"] as JsonArray;
        return list is null ? new HashSet<string>() : list.Select(n => n?.GetValue<string>() ?? "").Where(s => s.Length > 0).ToHashSet();
    }

    public void SetSeen(IEnumerable<string> ids)
    {
        State["seen"] = new JsonArray(ids.TakeLast(2000).Select(id => (JsonNode)JsonValue.Create(id)!).ToArray());
        Save();
    }

    public JsonObject Replied => State["replied"] as JsonObject ?? new JsonObject();

    public void SetReplied(string id, bool value)
    {
        var replied = State["replied"] as JsonObject ?? new JsonObject();
        if (value) replied[id] = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        else replied.Remove(id);
        State["replied"] = replied;
        Save();
    }

    public JsonNode? Templates => State["templates"];

    public void SetTemplates(JsonNode? templates)
    {
        State["templates"] = templates?.DeepClone();
        Save();
    }

    public static string GenerateKey()
    {
        const string alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
        var bytes = RandomNumberGenerator.GetBytes(40);
        return new string(bytes.Select(b => alphabet[b % alphabet.Length]).ToArray());
    }
}
