using System.IO;
using System.ComponentModel;
using System.Reflection;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Toolkit.Uwp.Notifications;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using Forms = System.Windows.Forms;

namespace HNMail;

public static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        Updater.FinishPreviousUpdate(args);
        using var mutex = new Mutex(true, "HNMail-single-instance", out var first);
        if (!first)
        {
            // Déjà ouverte : on ne lance pas une deuxième fois.
            System.Windows.MessageBox.Show("HN Mail est déjà ouverte (icône près de l'horloge).", "HN Mail");
            return;
        }
        var app = new System.Windows.Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var window = new MainWindow();
        window.Show();
        app.Run();
    }
}

/// <summary>Fenêtre principale : l'interface est une page web (WebView2), la logique est ici.</summary>
public sealed class MainWindow : Window
{
    private readonly WebView2 web = new();
    private readonly Store store = new();
    private readonly Services services;
    private readonly DispatcherTimer poller = new();
    private readonly DispatcherTimer updateTimer = new() { Interval = TimeSpan.FromHours(6) };
    private readonly Updater updater = new();
    private JsonArray sentMails = new();
    private readonly Forms.NotifyIcon tray = new();
    private JsonArray messages = new();
    private bool quitting;

    public MainWindow()
    {
        services = new Services(store);
        Title = "HN Mail";
        Width = 1280;
        Height = 820;
        MinWidth = 1000;
        MinHeight = 640;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Content = web;
        try { Icon = System.Windows.Media.Imaging.BitmapFrame.Create(new Uri("pack://application:,,,/app.ico")); } catch { }
        Loaded += async (_, _) => await InitAsync();
        SetupTray();
        ToastNotificationManagerCompat.OnActivated += args =>
        {
            var id = ToastArguments.Parse(args.Argument).TryGetValue("id", out var value) ? value : null;
            Dispatcher.Invoke(() => { ShowWindow(); if (id != null) Post(new JsonObject { ["event"] = "open", ["id"] = id }); });
        };
    }

    // ---------- démarrage ----------
    private async Task InitAsync()
    {
        var uiFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HN Mail", "ui");
        ExtractUi(uiFolder);
        var env = await CoreWebView2Environment.CreateAsync(null, Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HN Mail", "WebView2"));
        await web.EnsureCoreWebView2Async(env);
        var core = web.CoreWebView2;
        core.SetVirtualHostNameToFolderMapping("hnmail.local", uiFolder, CoreWebView2HostResourceAccessKind.Allow);
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.AreDefaultContextMenusEnabled = true;
        core.WebMessageReceived += async (_, e) => await OnMessage(e.WebMessageAsJson);
        core.NewWindowRequested += (_, e) => { e.Handled = true; OpenExternal(e.Uri); };
        core.NavigationStarting += (_, e) =>
        {
            if (!e.Uri.StartsWith("https://hnmail.local/") && !e.Uri.StartsWith("about:")) { e.Cancel = true; OpenExternal(e.Uri); }
        };
        core.Navigate("https://hnmail.local/index.html");

        poller.Tick += async (_, _) => await RefreshAsync(false);
        poller.Interval = TimeSpan.FromMinutes(store.PollMinutes);
        poller.Start();

        updateTimer.Tick += async (_, _) => await CheckUpdateAsync(true);
        updateTimer.Start();
        _ = FirstUpdateCheckAsync();
    }

    private async Task FirstUpdateCheckAsync()
    {
        await Task.Delay(TimeSpan.FromSeconds(5));
        await CheckUpdateAsync(true);
    }

    // ---------- mise à jour par Internet ----------
    private async Task CheckUpdateAsync(bool automatic)
    {
        if (automatic && !store.AutoUpdate) return;
        try
        {
            await updater.CheckAsync();
            Post(new JsonObject { ["event"] = "update", ["update"] = updater.ToJson() });
            if (automatic && updater.Available && !IsVisible)
                tray.ShowBalloonTip(5000, "Mise à jour de HN Mail", $"La version {updater.LatestVersion} est disponible. Ouvre HN Mail pour l'installer.", Forms.ToolTipIcon.Info);
        }
        catch (Exception error)
        {
            if (!automatic) throw new AppException(error.Message);
        }
    }

    private static void ExtractUi(string folder)
    {
        Directory.CreateDirectory(folder);
        var assembly = Assembly.GetExecutingAssembly();
        foreach (var name in assembly.GetManifestResourceNames().Where(n => n.StartsWith("ui/")))
        {
            using var stream = assembly.GetManifestResourceStream(name)!;
            using var file = File.Create(Path.Combine(folder, name[3..]));
            stream.CopyTo(file);
        }
    }

    // ---------- barre des tâches : icône près de l'horloge ----------
    private void SetupTray()
    {
        try { tray.Icon = System.Drawing.Icon.ExtractAssociatedIcon(Environment.ProcessPath!); } catch { tray.Icon = System.Drawing.SystemIcons.Application; }
        tray.Text = "HN Mail";
        tray.Visible = true;
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Ouvrir HN Mail", null, (_, _) => ShowWindow());
        menu.Items.Add("Actualiser", null, async (_, _) => await RefreshAsync(true));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Quitter HN Mail", null, (_, _) => Quit());
        tray.ContextMenuStrip = menu;
        tray.MouseClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left) ShowWindow(); };
    }

    private void ShowWindow()
    {
        Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
        Topmost = true;
        Topmost = false;
    }

    private void Quit()
    {
        quitting = true;
        tray.Visible = false;
        tray.Dispose();
        ToastNotificationManagerCompat.Uninstall();
        System.Windows.Application.Current.Shutdown();
    }

    // Fermer la fenêtre la cache : l'app continue de vérifier les mails dans la barre des tâches.
    protected override void OnClosing(CancelEventArgs e)
    {
        if (!quitting)
        {
            e.Cancel = true;
            Hide();
            if (!store.State.ContainsKey("trayHintShown"))
            {
                store.State["trayHintShown"] = true;
                store.Save();
                tray.ShowBalloonTip(4000, "HN Mail reste ouverte", "Elle continue de vérifier les mails. Clic droit sur l'icône près de l'horloge pour quitter.", Forms.ToolTipIcon.Info);
            }
        }
        base.OnClosing(e);
    }

    // ---------- mails ----------
    private async Task<JsonArray> RefreshAsync(bool manual)
    {
        if (!store.InboxConfigured) return messages;
        try
        {
            messages = await services.FetchInboxAsync();
            var seen = store.Seen();
            await PushPendingRepliedAsync();
            var replied = store.Replied;
            var fresh = messages.Where(m => m?["id"]?.GetValue<string>() is string id && !seen.Contains(id) && !replied.ContainsKey(id) && m?["repliedAt"] is null).ToList();
            // Pas de notification au tout premier chargement (sinon tous les anciens mails sonneraient).
            if (seen.Count > 0 && store.Notifications) Notify(fresh);
            seen.UnionWith(messages.Select(m => m?["id"]?.GetValue<string>() ?? "").Where(s => s.Length > 0));
            store.SetSeen(seen);
            UpdateTray();
            Post(new JsonObject { ["event"] = "inbox", ["messages"] = messages.DeepClone() });
        }
        catch (Exception error)
        {
            Post(new JsonObject { ["event"] = "error", ["message"] = error.Message });
        }
        return messages;
    }

    /// <summary>Envoie au serveur les « répondus » faits ici avant la synchro, puis oublie ceux déjà partagés.</summary>
    private async Task PushPendingRepliedAsync()
    {
        var replied = store.Replied;
        foreach (var m in messages)
        {
            var id = m?["id"]?.GetValue<string>() ?? "";
            if (id.Length == 0 || !replied.ContainsKey(id)) continue;
            if (m?["repliedAt"] is null)
            {
                try
                {
                    await services.SetRepliedAsync(id, true, store.TeamName);
                    m!["repliedAt"] = DateTimeOffset.UtcNow.ToString("o");
                    m["repliedBy"] = store.TeamName;
                }
                catch { continue; }
            }
            store.SetReplied(id, false);
        }
    }

    /// <summary>Partage avec l'équipe les mails envoyés d'ici qui ne le sont pas encore.</summary>
    private async Task PushPendingSentAsync()
    {
        foreach (var mail in store.PendingSent.ToList())
        {
            if (mail is null) continue;
            try { await services.SaveSentAsync(mail); }
            catch { return; }
            store.RemovePendingSent(mail["id"]?.GetValue<string>() ?? "");
        }
    }

    /// <summary>Envoyés du serveur + ceux d'ici pas encore partagés, du plus récent au plus ancien.</summary>
    private JsonArray MergedSent()
    {
        var all = new List<JsonNode>();
        var ids = new HashSet<string>();
        foreach (var mail in sentMails) if (mail is not null && ids.Add(mail["id"]?.GetValue<string>() ?? "")) all.Add(mail.DeepClone());
        foreach (var mail in store.PendingSent)
        {
            if (mail is null || !ids.Add(mail["id"]?.GetValue<string>() ?? "")) continue;
            var copy = mail.DeepClone();
            copy["pending"] = true;
            all.Add(copy);
        }
        return new JsonArray(all.OrderByDescending(m => m["sentAt"]?.GetValue<string>() ?? "", StringComparer.Ordinal).ToArray());
    }

    private void SetMessageReplied(string id, bool value)
    {
        var m = messages.FirstOrDefault(x => x?["id"]?.GetValue<string>() == id);
        if (m is null) return;
        m["repliedAt"] = value ? DateTimeOffset.UtcNow.ToString("o") : null;
        m["repliedBy"] = value ? store.TeamName : null;
    }

    private async Task MarkRepliedAsync(string id, bool value)
    {
        SetMessageReplied(id, value);
        store.SetReplied(id, value); // en attente si le serveur ne répond pas
        try
        {
            await services.SetRepliedAsync(id, value, store.TeamName);
            store.SetReplied(id, false);
        }
        catch (Exception error)
        {
            Post(new JsonObject { ["event"] = "error", ["message"] = $"État « répondu » pas encore synchronisé : {error.Message}" });
        }
        UpdateTray();
    }

    private void UpdateTray()
    {
        var replied = store.Replied;
        var todo = messages.Count(m => m?["mailbox"]?.GetValue<string>() != "news" && m?["repliedAt"] is null && !replied.ContainsKey(m?["id"]?.GetValue<string>() ?? ""));
        tray.Text = todo > 0 ? $"HN Mail : {todo} à traiter" : "HN Mail";
    }

    private static void Notify(List<JsonNode?> fresh)
    {
        if (fresh.Count == 0) return;
        if (fresh.Count > 3)
        {
            new ToastContentBuilder().AddArgument("id", fresh[0]?["id"]?.GetValue<string>() ?? "")
                .AddText("HN Mail").AddText($"{fresh.Count} nouveaux mails sur contact@heivoli-network.fr").Show();
            return;
        }
        foreach (var m in fresh)
        {
            string S(string k) => m?[k]?.GetValue<string>() ?? "";
            var from = S("fromName").Length > 0 ? S("fromName") : S("fromEmail");
            var text = S("text").Replace("\r", " ").Replace("\n", " ");
            new ToastContentBuilder().AddArgument("id", S("id"))
                .AddText(from).AddText(S("subject")).AddText(text.Length > 160 ? text[..160] + "…" : text).Show();
        }
    }

    // ---------- pont avec l'interface ----------
    private void Post(JsonObject message)
    {
        if (web.CoreWebView2 != null) web.CoreWebView2.PostWebMessageAsJson(message.ToJsonString());
    }

    private async Task OnMessage(string json)
    {
        var request = JsonNode.Parse(json) as JsonObject;
        if (request is null) return;
        var id = request["id"]?.GetValue<int>() ?? 0;
        var cmd = request["cmd"]?.GetValue<string>() ?? "";
        var data = request["data"];
        string Str(string name) => data?[name]?.GetValue<string>() ?? "";
        JsonNode? result = null;
        try
        {
            switch (cmd)
            {
                case "init":
                    result = State();
                    break;
                case "refresh":
                    var list = await RefreshAsync(true);
                    result = list.DeepClone();
                    break;
                case "saveInboxKey":
                    store.SetSecret("inboxKey", Str("key"));
                    await RefreshAsync(true);
                    result = State();
                    break;
                case "saveBrevoKey":
                    store.SetSecret("brevoKey", Str("key"));
                    result = State();
                    break;
                case "clearKey":
                    store.SetSecret(Str("name"), null);
                    result = State();
                    break;
                case "generateKey":
                    result = Store.GenerateKey();
                    break;
                case "copy":
                    System.Windows.Clipboard.SetText(Str("text"));
                    break;
                case "send":
                    if (data is null) throw new AppException("Rien à envoyer.");
                    await services.SendAsync(data);
                    store.AddPendingSent(new JsonObject
                    {
                        ["id"] = Guid.NewGuid().ToString(),
                        ["mailbox"] = Str("mailbox") == "news" ? "news" : "contact",
                        ["toEmail"] = Str("toEmail"),
                        ["toName"] = Str("toName"),
                        ["subject"] = Str("subject"),
                        ["text"] = Str("text"),
                        ["html"] = Str("html"),
                        ["by"] = store.TeamName,
                        ["inboxId"] = Str("messageId"),
                        ["template"] = Str("template"),
                        ["sentAt"] = DateTimeOffset.UtcNow.ToString("o"),
                    });
                    await PushPendingSentAsync();
                    if (Str("messageId").Length > 0) await MarkRepliedAsync(Str("messageId"), true);
                    result = State();
                    break;
                case "sent":
                    await PushPendingSentAsync();
                    try { sentMails = await services.FetchSentAsync(); } catch { }
                    result = MergedSent();
                    break;
                case "setReplied":
                    await MarkRepliedAsync(Str("messageId"), data?["value"]?.GetValue<bool>() ?? true);
                    result = State();
                    break;
                case "saveTemplates":
                    store.SetTemplates(data?["templates"]);
                    break;
                case "setPrefs":
                    if (data?["pollMinutes"] is JsonNode minutes) { store.PollMinutes = minutes.GetValue<int>(); poller.Interval = TimeSpan.FromMinutes(store.PollMinutes); }
                    if (data?["notifications"] is JsonNode notif) store.Notifications = notif.GetValue<bool>();
                    if (data?["teamName"] is JsonNode team) store.TeamName = team.GetValue<string>();
                    if (data?["autoUpdate"] is JsonNode autoUpdate) store.AutoUpdate = autoUpdate.GetValue<bool>();
                    if (data?["autoCorrect"] is JsonNode autoCorrect) store.AutoCorrect = autoCorrect.GetValue<bool>();
                    if (data?["aiEngine"] is JsonNode engine) store.AiEngine = engine.GetValue<string>();
                    if (data?["ollamaModel"] is JsonNode model) store.OllamaModel = model.GetValue<string>();
                    result = State();
                    break;
                case "ai":
                    result = await services.AiAsync(data);
                    break;
                case "checkUpdate":
                    await CheckUpdateAsync(false);
                    result = updater.ToJson();
                    break;
                case "installUpdate":
                    await updater.InstallAsync();
                    Post(new JsonObject { ["id"] = id, ["ok"] = true, ["data"] = null });
                    Quit();
                    return;
                case "openExternal":
                    OpenExternal(Str("url"));
                    break;
            }
            Post(new JsonObject { ["id"] = id, ["ok"] = true, ["data"] = result });
        }
        catch (Exception error)
        {
            Post(new JsonObject { ["id"] = id, ["ok"] = false, ["error"] = error is AppException ? error.Message : $"Erreur : {error.Message}" });
        }
    }

    private JsonObject State() => new()
    {
        ["inboxConfigured"] = store.InboxConfigured,
        ["brevoConfigured"] = store.BrevoConfigured,
        ["pollMinutes"] = store.PollMinutes,
        ["notifications"] = store.Notifications,
        ["teamName"] = store.TeamName,
        ["autoUpdate"] = store.AutoUpdate,
        ["autoCorrect"] = store.AutoCorrect,
        ["aiEngine"] = store.AiEngine,
        ["ollamaModel"] = store.OllamaModel,
        ["update"] = updater.ToJson(),
        ["replied"] = store.Replied.DeepClone(),
        ["templates"] = store.Templates?.DeepClone(),
        ["messages"] = messages.DeepClone(),
    };

    private static void OpenExternal(string url)
    {
        if (!url.StartsWith("https://") && !url.StartsWith("mailto:")) return;
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true }); } catch { }
    }
}
