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
    public static void Main()
    {
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
            var replied = store.Replied;
            var fresh = messages.Where(m => m?["id"]?.GetValue<string>() is string id && !seen.Contains(id) && !replied.ContainsKey(id)).ToList();
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

    private void UpdateTray()
    {
        var replied = store.Replied;
        var todo = messages.Count(m => m?["mailbox"]?.GetValue<string>() != "news" && !replied.ContainsKey(m?["id"]?.GetValue<string>() ?? ""));
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
                    if (Str("messageId").Length > 0) store.SetReplied(Str("messageId"), true);
                    UpdateTray();
                    result = State();
                    break;
                case "setReplied":
                    store.SetReplied(Str("messageId"), data?["value"]?.GetValue<bool>() ?? true);
                    UpdateTray();
                    result = State();
                    break;
                case "saveTemplates":
                    store.SetTemplates(data?["templates"]);
                    break;
                case "setPrefs":
                    if (data?["pollMinutes"] is JsonNode minutes) { store.PollMinutes = minutes.GetValue<int>(); poller.Interval = TimeSpan.FromMinutes(store.PollMinutes); }
                    if (data?["notifications"] is JsonNode notif) store.Notifications = notif.GetValue<bool>();
                    result = State();
                    break;
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
