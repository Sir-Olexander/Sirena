import Foundation

/// Common website names → URLs, so "open Google" opens google.com instead of an app with a similar name.
public enum Websites {
    public static let catalog: [String: String] = [
        "google": "https://www.google.com", "google search": "https://www.google.com",
        "youtube": "https://www.youtube.com", "you tube": "https://www.youtube.com", "youtube music": "https://music.youtube.com",
        "gmail": "https://mail.google.com", "g mail": "https://mail.google.com", "google mail": "https://mail.google.com",
        "google drive": "https://drive.google.com", "drive": "https://drive.google.com",
        "google docs": "https://docs.google.com/document", "docs": "https://docs.google.com/document",
        "google sheets": "https://docs.google.com/spreadsheets", "sheets": "https://docs.google.com/spreadsheets",
        "google slides": "https://docs.google.com/presentation", "slides": "https://docs.google.com/presentation",
        "google calendar": "https://calendar.google.com", "google maps": "https://maps.google.com",
        "google translate": "https://translate.google.com", "translate": "https://translate.google.com",
        "google photos": "https://photos.google.com", "google meet": "https://meet.google.com", "meet": "https://meet.google.com",
        "google news": "https://news.google.com", "google keep": "https://keep.google.com", "gemini": "https://gemini.google.com",
        "github": "https://github.com", "git hub": "https://github.com", "gitlab": "https://gitlab.com",
        "stack overflow": "https://stackoverflow.com", "stackoverflow": "https://stackoverflow.com",
        "reddit": "https://www.reddit.com", "twitter": "https://x.com", "x": "https://x.com", "x dot com": "https://x.com",
        "facebook": "https://www.facebook.com", "instagram": "https://www.instagram.com", "linkedin": "https://www.linkedin.com", "linked in": "https://www.linkedin.com",
        "whatsapp": "https://web.whatsapp.com", "whatsapp web": "https://web.whatsapp.com", "whats app": "https://web.whatsapp.com",
        "telegram web": "https://web.telegram.org", "messenger": "https://www.messenger.com",
        "netflix": "https://www.netflix.com", "amazon": "https://www.amazon.com", "ebay": "https://www.ebay.com",
        "wikipedia": "https://www.wikipedia.org", "wiki": "https://www.wikipedia.org",
        "chatgpt": "https://chatgpt.com", "chat gpt": "https://chatgpt.com", "claude ai": "https://claude.ai", "claude dot ai": "https://claude.ai",
        "meta ai": "https://www.meta.ai", "perplexity": "https://www.perplexity.ai",
        "outlook": "https://outlook.live.com", "hotmail": "https://outlook.live.com", "yahoo": "https://www.yahoo.com", "yahoo mail": "https://mail.yahoo.com",
        "bing": "https://www.bing.com", "duckduckgo": "https://duckduckgo.com", "duck duck go": "https://duckduckgo.com",
        "twitch": "https://www.twitch.tv", "tiktok": "https://www.tiktok.com", "tik tok": "https://www.tiktok.com",
        "pinterest": "https://www.pinterest.com", "medium": "https://medium.com", "hacker news": "https://news.ycombinator.com",
        "product hunt": "https://www.producthunt.com", "vercel": "https://vercel.com", "figma web": "https://www.figma.com",
        "canva": "https://www.canva.com", "dropbox": "https://www.dropbox.com", "icloud": "https://www.icloud.com",
        "booking": "https://www.booking.com", "airbnb": "https://www.airbnb.com", "spotify web": "https://open.spotify.com",
        "the weather": "https://weather.com", "weather dot com": "https://weather.com", "bbc": "https://www.bbc.com", "cnn": "https://www.cnn.com",
        "the verge": "https://www.theverge.com", "notion web": "https://www.notion.so", "trello": "https://trello.com",
        "jira": "https://www.atlassian.com/software/jira", "zoom web": "https://zoom.us", "porkbun": "https://porkbun.com",
    ]

    /// URL for a spoken site name or a domain-like string ("github dot com", "example.org"), else nil.
    public static func url(for spoken: String) -> URL? {
        var t = WakeWord.normalize(spoken)
        for prefix in ["the website ", "website ", "the site ", "site ", "the web page ", "the page "] where t.hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)) }
        for suffix in [" website", " site", " web site", " dot com page", " page", " web"] where t.hasSuffix(suffix) {
            let base = String(t.dropLast(suffix.count))
            if let u = catalog[base] { return URL(string: u) }
        }
        if let u = catalog[t] { return URL(string: u) }
        return domainURL(spoken)
    }

    /// "github dot com", "example.org/docs" → https URL.
    public static func domainURL(_ spoken: String) -> URL? {
        var s = spoken.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters.subtracting(CharacterSet(charactersIn: "./"))))
        s = s.replacingOccurrences(of: "\\s+dot\\s+", with: ".", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+slash\\s+", with: "/", options: .regularExpression)
        let tlds = "com|org|net|io|ai|dev|co|edu|gov|app|me|tv|pt|uk|de|fr|es|it|br|us|info|xyz|so|gg|ly"
        guard s.firstMatch("^(?:https?://)?(?:www\\.)?[a-z0-9-]+(?:\\.[a-z0-9-]+)*\\.(?:\(tlds))(?:/\\S*)?$") != nil else { return nil }
        if !s.hasPrefix("http") { s = "https://" + s }
        return URL(string: s)
    }

    /// Host of a catalog URL, to recognise an already-open tab.
    public static func host(of url: URL) -> String {
        (url.host ?? "").replacingOccurrences(of: "www.", with: "")
    }
}
