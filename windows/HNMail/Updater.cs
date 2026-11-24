using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace HNMail;

/// <summary>Mise à jour par Internet : regarde la dernière Release GitHub, télécharge le nouvel .exe et le met à la place de l'ancien.</summary>
public sealed class Updater
{
    private const string ReleasesUrl = "https://api.github.com/repos/Heivoli-dev/hn-mail/releases/latest";
    private const string AssetName = "HN-Mail-Windows.exe";
    private static readonly HttpClient Http = CreateClient();

    public string CurrentVersion { get; }
    public int CurrentBuild { get; }
    public string? LatestVersion { get; private set; }
    public int LatestBuild { get; private set; }
    private string? assetUrl;
    private string? digest;

    public bool Available => CurrentBuild > 0 && LatestBuild > CurrentBuild && assetUrl != null;

    public Updater()
    {
        var info = FileVersionInfo.GetVersionInfo(Environment.ProcessPath ?? "");
        CurrentVersion = $"{info.FileMajorPart}.{info.FileMinorPart}.{info.FileBuildPart}";
        CurrentBuild = info.FilePrivatePart; // numéro de build GitHub Actions (0 = compilé à la main)
    }

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
        client.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("HN-Mail", "1.0"));
        return client;
    }

    public async Task CheckAsync()
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, ReleasesUrl);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true };
        using var response = await Http.SendAsync(request);
        if (!response.IsSuccessStatusCode) throw new AppException("GitHub ne répond pas, réessaie plus tard.");
        var json = JsonNode.Parse(await response.Content.ReadAsStringAsync());
        var tag = json?["tag_name"]?.GetValue<string>() ?? "";
        var match = Regex.Match(tag, @"build(\d+)");
        LatestBuild = match.Success ? int.Parse(match.Groups[1].Value) : 0;
        LatestVersion = tag.TrimStart('v').Split("-build")[0];
        assetUrl = null;
        digest = null;
        foreach (var asset in json?["assets"]?.AsArray() ?? new JsonArray())
        {
            if (asset?["name"]?.GetValue<string>() != AssetName) continue;
            var url = asset["browser_download_url"]?.GetValue<string>() ?? "";
            if (Uri.TryCreate(url, UriKind.Absolute, out var uri) && uri.Scheme == "https" && uri.Host == "github.com") assetUrl = url;
            digest = asset["digest"]?.GetValue<string>();
        }
    }

    /// <summary>Télécharge et met en place la nouvelle version, puis la lance. L'appelant quitte l'app ensuite.</summary>
    public async Task InstallAsync()
    {
        if (!Available || assetUrl is null) throw new AppException("Aucune mise à jour à installer.");
        var exe = Environment.ProcessPath ?? throw new AppException("Emplacement de l'app introuvable.");
        var folder = Path.GetDirectoryName(exe)!;
        var download = Path.Combine(folder, "HN Mail.update.exe");
        try
        {
            using (var response = await Http.GetAsync(assetUrl, HttpCompletionOption.ResponseHeadersRead))
            {
                if (!response.IsSuccessStatusCode) throw new AppException("Le téléchargement a échoué.");
                await using var file = File.Create(download);
                await response.Content.CopyToAsync(file);
            }
        }
        catch (UnauthorizedAccessException)
        {
            throw new AppException($"Je ne peux pas écrire dans {folder}. Télécharge la nouvelle version sur GitHub et remplace l'app à la main.");
        }

        if (digest is string expected && expected.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase))
        {
            await using var stream = File.OpenRead(download);
            var hash = Convert.ToHexString(await SHA256.HashDataAsync(stream)).ToLowerInvariant();
            if ("sha256:" + hash != expected.ToLowerInvariant())
            {
                stream.Close();
                File.Delete(download);
                throw new AppException("Le fichier téléchargé est abîmé. Réessaie.");
            }
        }

        // Windows permet de renommer un .exe en cours d'exécution : on garde l'ancien à côté, il sera effacé au prochain lancement.
        var old = exe + ".old";
        try { if (File.Exists(old)) File.Delete(old); } catch { }
        File.Move(exe, old);
        try { File.Move(download, exe); }
        catch { File.Move(old, exe); throw new AppException("L'installation a échoué, l'ancienne version est gardée."); }

        Process.Start(new ProcessStartInfo(exe) { UseShellExecute = false, ArgumentList = { "--wait-pid", Environment.ProcessId.ToString() } });
    }

    /// <summary>Au lancement : attend que l'ancienne version soit fermée puis efface son fichier.</summary>
    public static void FinishPreviousUpdate(string[] args)
    {
        var index = Array.IndexOf(args, "--wait-pid");
        if (index >= 0 && index + 1 < args.Length && int.TryParse(args[index + 1], out var pid))
        {
            try { Process.GetProcessById(pid).WaitForExit(20000); } catch { }
        }
        var old = (Environment.ProcessPath ?? "") + ".old";
        for (var i = 0; i < 5 && File.Exists(old); i++)
        {
            try { File.Delete(old); } catch { Thread.Sleep(400); }
        }
    }

    public JsonObject ToJson() => new()
    {
        ["currentVersion"] = CurrentVersion,
        ["currentBuild"] = CurrentBuild,
        ["latestVersion"] = LatestVersion,
        ["available"] = Available,
    };
}
