import Foundation

/// The same control in English and Portuguese, so "click send" finds “Enviar” on a Mac set to Portuguese
/// (and "clica em guardar" finds “Save”) without asking the model.
public enum LabelSynonyms {
    static let groups: [[String]] = [
        ["send", "enviar", "envia"], ["cancel", "cancelar"], ["save", "guardar", "salvar", "gravar"], ["close", "fechar"],
        ["delete", "eliminar", "apagar", "excluir"], ["new", "novo", "nova"], ["search", "pesquisar", "procurar", "buscar", "pesquisa"],
        ["settings", "definições", "definicoes", "configurações", "configuracoes", "ajustes", "preferências", "preferences"],
        ["reply", "responder"], ["next", "seguinte", "próximo", "proximo", "avançar", "avancar"], ["back", "anterior", "voltar", "retroceder"],
        ["yes", "sim"], ["no", "não", "nao"], ["open", "abrir"], ["copy", "copiar"], ["paste", "colar"], ["attach", "anexar"],
        ["done", "concluído", "concluido", "feito"], ["edit", "editar"], ["share", "partilhar", "compartilhar"],
        ["download", "transferir", "descarregar", "baixar"], ["upload", "carregar"], ["sign in", "iniciar sessão", "iniciar sessao", "entrar"],
        ["log in", "iniciar sessão", "iniciar sessao", "entrar"], ["sign out", "terminar sessão", "terminar sessao", "sair"],
        ["continue", "continuar"], ["accept", "aceitar"], ["reject", "rejeitar", "recusar"], ["allow", "permitir"], ["home", "início", "inicio", "página inicial"],
        ["profile", "perfil"], ["message", "mensagem"], ["chat", "conversa"], ["call", "chamada", "ligar"], ["video call", "videochamada", "chamada de vídeo"],
        ["more", "mais"], ["options", "opções", "opcoes"], ["help", "ajuda"], ["print", "imprimir"], ["refresh", "atualizar", "actualizar"],
        ["add", "adicionar"], ["remove", "remover"], ["play", "reproduzir"], ["pause", "pausa", "pausar"], ["mute", "silenciar"],
        ["turn on", "ativar", "activar", "ligar"], ["turn off", "desativar", "desactivar", "desligar"], ["new tab", "novo separador", "nova aba"],
        ["new window", "nova janela"], ["close tab", "fechar separador", "fechar aba"], ["submit", "submeter", "enviar"], ["confirm", "confirmar"],
        ["select all", "selecionar tudo", "seleccionar tudo"], ["undo", "anular", "desfazer"], ["redo", "refazer"], ["inbox", "caixa de entrada"],
        ["compose", "escrever", "compor"], ["forward", "reencaminhar", "encaminhar"], ["archive", "arquivar"], ["like", "gosto", "curtir"],
        ["subscribe", "subscrever", "inscrever"], ["comments", "comentários", "comentarios"], ["notifications", "notificações", "notificacoes"],
        ["filter", "filtro", "filtrar"], ["sort", "ordenar"], ["view", "ver", "visualizar"], ["show", "mostrar"], ["hide", "ocultar", "esconder"],
    ]

    static let index: [String: [String]] = {
        var map: [String: [String]] = [:]
        for g in groups {
            for w in g { map[WakeWord.normalize(w), default: []] += g.map(WakeWord.normalize).filter { $0 != WakeWord.normalize(w) } }
        }
        return map
    }()

    /// Other spellings of a spoken label: the whole label translated, else each word that has a translation.
    public static func alternatives(_ label: String) -> [String] {
        let q = WakeWord.normalize(label)
        var out: [String] = index[q] ?? []
        let words = q.split(separator: " ").map(String.init)
        if words.count > 1 {
            for (i, w) in words.enumerated() {
                for alt in index[w] ?? [] {
                    var copy = words; copy[i] = alt
                    out.append(copy.joined(separator: " "))
                }
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }
}
