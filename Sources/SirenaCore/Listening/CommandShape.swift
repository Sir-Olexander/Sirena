import Foundation

/// What an utterance looks like before anything runs: a command, only filler words, a command cut off before
/// its object ("switch to"), a question, or room chatter. Speech without "Sirena" reaches the model only when
/// it looks like a command, so background talk and fillers never trigger clicks or chatty replies.
public enum CommandShape: Equatable {
    case command, filler, incomplete, question, chatter

    /// First words of spoken commands (English and Portuguese). Kept to verbs and command nouns, so ordinary
    /// sentences ("o terminal do Google Chrome", "fala agora") are not mistaken for commands.
    public static let verbs: Set<String> = [
        "open", "close", "switch", "go", "click", "tap", "press", "hit", "push", "select", "choose", "scroll", "type", "write", "send",
        "reply", "respond", "search", "google", "find", "look", "show", "hide", "copy", "paste", "cut", "undo", "redo", "save", "read",
        "play", "pause", "resume", "stop", "mute", "unmute", "volume", "next", "previous", "back", "forward", "reload", "refresh", "new",
        "enter", "focus", "move", "put", "minimize", "minimise", "maximize", "maximise", "zoom", "turn", "make", "format", "separate", "fix",
        "delete", "remove", "add", "insert", "take", "jump", "bring", "launch", "start", "run", "quit", "exit", "message", "text", "tell",
        "dictate", "check", "uncheck", "toggle", "enable", "disable", "drag", "resize", "rename", "create", "edit", "translate",
        "summarize", "summarise", "fill", "submit", "note", "keep", "get", "sort", "change", "increase", "decrease", "lower", "raise",
        "skip", "rewind", "reopen", "restore", "lock", "activate", "view", "display", "expand", "collapse", "split", "merge", "bullet",
        "capitalize", "organize", "organise", "highlight", "grab", "call", "dial", "answer", "accept", "decline", "mark", "star",
        "archive", "pin", "unpin", "download", "upload", "attach", "share", "print", "duplicate", "bookmark", "clear", "empty",
        "compose", "tab", "page", "inside", "first", "second", "third", "last", "scroll", "help", "list", "set", "use", "visit", "load", "navigate",
        "abre", "abrir", "abra", "fecha", "fechar", "feche", "muda", "mudar", "mude", "clica", "clicar", "clique", "carrega", "carregar",
        "escreve", "escrever", "escreva", "envia", "enviar", "envie", "manda", "mandar", "pesquisa", "pesquisar", "procura", "procurar",
        "mostra", "mostrar", "esconde", "copia", "copiar", "cola", "colar", "desfaz", "guarda", "guardar", "lê", "le", "ler", "toca",
        "tocar", "pausa", "próximo", "proximo", "próxima", "proxima", "anterior", "volta", "voltar", "seleciona", "selecionar", "apaga",
        "apagar", "liga", "desliga", "sobe", "desce", "aumenta", "diminui", "minimiza", "maximiza", "cria", "criar", "responde",
        "responder", "continua", "espera", "cancela", "cancelar", "entra", "entrar",
    ]

    static let questionStarts = "^(?:what|what's|whats|how|why|who|whom|where|when|which|whose|is|are|am|was|were|do|does|did|has|have|"
        + "como|o que|que|porque|por que|porquê|quem|onde|quando|qual|quais|quanto|quantos|será|é que|tens|há)\\b"

    /// Cut off before the object: "switch to", "click on", "search for", "go to the".
    static func isIncomplete(_ t: String) -> Bool {
        if t.firstMatch("^(?:click|click on|tap|tap on|type|write|search|search for|look up|look for|focus|focus on|select|go|switch|move|jump|"
                        + "send to|message|tell|scroll to|open up|go back to|switch back to|change to|abre o|abre a|muda para|vai para)$") != nil { return true }
        return t.firstMatch("\\s(?:to|the|a|an|for|of|into|with|my|on the|in the|to the|para|para o|para a)$") != nil
    }

    static func isQuestion(_ raw: String, _ t: String) -> Bool {
        let first = String(t.split(separator: " ").first ?? "")
        if verbs.contains(first) { return false }
        if raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'”’)"))).hasSuffix("?") { return true }
        return t.firstMatch(questionStarts) != nil
    }

    /// - Parameter isKnownPhrase: the user's own phrases (saved shortcuts) count as commands.
    public static func classify(_ raw: String, numbersVisible: Bool = false, isKnownPhrase: (String) -> Bool = { _ in false }) -> CommandShape {
        let t = FastPathParser.normalize(raw)
        if t.isEmpty { return .filler }
        let ctx = FastPathParser.Context(numbersVisible: numbersVisible)
        if FastPathParser.control(t, context: ctx) != nil { return .command }
        if UtteranceRouter.readingControl(t) != nil { return .command }
        if isKnownPhrase(t) { return .command }
        if isQuestion(raw, t) { return .question }
        if isIncomplete(t) { return .incomplete }
        if FastPathParser.parse(raw, context: ctx) != nil { return .command }
        let words = t.split(separator: " ").map(String.init)
        guard let first = words.first else { return .filler }
        return verbs.contains(first) && words.count <= 14 ? .command : .chatter
    }
}
