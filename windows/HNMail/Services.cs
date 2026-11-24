using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace HNMail;

public sealed class AppException(string message) : Exception(message);

/// <summary>Lit les mails reçus (Worker de heivoli-network.fr) et envoie les réponses (Brevo).</summary>
public sealed class Services(Store store)
{
    private const string InboxUrl = "https://heivoli-discord-auth.heivoli-discord-auth.workers.dev/api/inbox";
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };

    public async Task<JsonArray> FetchInboxAsync()
    {
        var key = store.GetSecret("inboxKey");
        if (string.IsNullOrEmpty(key) || key.Length < 24) throw new AppException("Ajoute la clé HN Mail dans les Réglages.");
        using var request = new HttpRequestMessage(HttpMethod.Get, InboxUrl);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true };
        using var response = await Http.SendAsync(request);
        var text = await response.Content.ReadAsStringAsync();
        JsonNode? json = null;
        try { json = JsonNode.Parse(text); } catch { }
        if (!response.IsSuccessStatusCode)
            throw new AppException(json?["error"]?.GetValue<string>() ?? $"Le serveur ne répond pas ({(int)response.StatusCode}).");
        return json?["messages"] as JsonArray ?? new JsonArray();
    }

    /// <summary>Marque un mail « répondu » (ou à traiter) pour toute l'équipe.</summary>
    public async Task SetRepliedAsync(string id, bool value, string by)
    {
        var key = store.GetSecret("inboxKey");
        if (string.IsNullOrEmpty(key) || key.Length < 24) throw new AppException("Ajoute la clé HN Mail dans les Réglages.");
        using var request = new HttpRequestMessage(HttpMethod.Post, InboxUrl + "/replied");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        request.Content = new StringContent(new JsonObject { ["id"] = id, ["value"] = value, ["by"] = by }.ToJsonString(), Encoding.UTF8, "application/json");
        using var response = await Http.SendAsync(request);
        if (!response.IsSuccessStatusCode) throw new AppException("Le serveur n'a pas enregistré l'état du mail.");
    }

    /// <summary>IA du Worker : « draft » (proposer une réponse) ou « correct » (corriger le texte).</summary>
    public async Task<string> AiAsync(JsonNode? data)
    {
        var key = store.GetSecret("inboxKey");
        if (string.IsNullOrEmpty(key) || key.Length < 24) throw new AppException("Ajoute la clé HN Mail dans les Réglages.");
        using var request = new HttpRequestMessage(HttpMethod.Post, InboxUrl + "/ai");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        request.Content = new StringContent(data?.ToJsonString() ?? "{}", Encoding.UTF8, "application/json");
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(90));
        HttpResponseMessage response;
        try { response = await Http.SendAsync(request, cts.Token); }
        catch { throw new AppException("L'IA ne répond pas. Vérifie ta connexion Internet."); }
        using (response)
        {
            var text = await response.Content.ReadAsStringAsync();
            JsonNode? json = null;
            try { json = JsonNode.Parse(text); } catch { }
            if ((int)response.StatusCode == 404) throw new AppException("L'IA n'est pas encore installée sur le serveur (mets le Worker à jour).");
            if (!response.IsSuccessStatusCode || json?["text"] is null)
                throw new AppException(json?["error"]?.GetValue<string>() ?? $"L'IA ne répond pas ({(int)response.StatusCode}).");
            return json["text"]!.GetValue<string>();
        }
    }

    public async Task SendAsync(JsonNode data)
    {
        var key = store.GetSecret("brevoKey");
        if (string.IsNullOrEmpty(key)) throw new AppException("Ajoute ta clé Brevo dans les Réglages.");
        string Str(string name) => data[name]?.GetValue<string>() ?? "";
        var fromAddress = Str("mailbox") == "news" ? "news@heivoli-network.fr" : "contact@heivoli-network.fr";
        var to = new JsonObject { ["email"] = Str("toEmail") };
        if (Str("toName").Length > 0) to["name"] = Str("toName");
        var payload = new JsonObject
        {
            ["sender"] = new JsonObject { ["name"] = "Heivoli Network", ["email"] = fromAddress },
            ["replyTo"] = new JsonObject { ["name"] = "Heivoli Network", ["email"] = "contact@heivoli-network.fr" },
            ["to"] = new JsonArray(to),
            ["subject"] = Str("subject"),
            ["htmlContent"] = Str("html"),
        };
        if (Str("inReplyTo").Length > 0)
            payload["headers"] = new JsonObject { ["In-Reply-To"] = Str("inReplyTo"), ["References"] = Str("inReplyTo") };

        using var request = new HttpRequestMessage(HttpMethod.Post, "https://api.brevo.com/v3/smtp/email");
        request.Headers.Add("api-key", key);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Content = new StringContent(payload.ToJsonString(), Encoding.UTF8, "application/json");
        using var response = await Http.SendAsync(request);
        if (!response.IsSuccessStatusCode)
        {
            var text = await response.Content.ReadAsStringAsync();
            string detail;
            try { detail = JsonNode.Parse(text)?["message"]?.GetValue<string>() ?? $"erreur {(int)response.StatusCode}"; }
            catch { detail = $"erreur {(int)response.StatusCode}"; }
            throw new AppException($"Brevo a refusé l'envoi : {detail}");
        }
    }
}
