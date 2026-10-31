import Foundation

/// The probe and setup flows use this same shell question. Only the public
/// email claim is returned; access and refresh tokens stay on that server.
public enum BackendServersAgentSignin {
    public static let agentVersionAWK = #"{for(i=1;i<=NF;i++) if ($i ~ /^v?[0-9]+\.[0-9]/) {sub(/^v/,"",$i); print $i; exit}}"#
    public static let agentEnvProbe = #"printf "TDENV\t%s\t%s\n" "${CODEX_HOME:-}" "${GEMINI_API_KEY:+k}${GOOGLE_GENAI_USE_VERTEXAI:+v}${GOOGLE_GENAI_USE_GCA:+g}""#

    public static func readAgentEnv(from: String, codexHome: String, geminiEnv: String) -> String {
        #"TDENV=$(printf '%s\n' "$\#(from)" | grep '^TDENV' | head -n 1)"# + "\n" +
        #"\#(codexHome)=$(printf '%s' "$TDENV" | cut -f2)"# + "\n" +
        #"\#(geminiEnv)=$(printf '%s' "$TDENV" | cut -f3)"#
    }

    public static func signInSnippet(_ id: BackendServersAgentID, binary: String, state: String,
                                     account: String, codexHome: String, geminiEnv: String) -> String {
        switch id {
        case .claude:
            return #"""
            tds=$("$\#(binary)" auth status --json 2>/dev/null | tr -d ' \t\n\r')
            case "$tds" in
              *'"loggedIn":true'*)  \#(state)=yes ;;
              *'"loggedIn":false'*) \#(state)=no ;;
            esac
            \#(account)=$(printf '%s' "$tds" | sed -n 's/.*"email":"\([^"]*\)".*/\1/p')
            """#
        case .codex:
            return #"""
            if CODEX_HOME="${\#(codexHome):-$HOME/.codex}" "$\#(binary)" login status >/dev/null 2>&1; then \#(state)=yes; else \#(state)=no; fi
            if [ "$\#(state)" = yes ]; then
              tdt=$(sed -n 's/.*"id_token"[^"]*"\([^"]*\)".*/\1/p' "${\#(codexHome):-$HOME/.codex}/auth.json" 2>/dev/null | head -n 1 | cut -d. -f2)
              if [ -n "$tdt" ]; then
                case $(( ${#tdt} % 4 )) in 2) tdt="$tdt==" ;; 3) tdt="$tdt=" ;; esac
                tdp=$(printf '%s' "$tdt" | tr '_-' '/+')
                tdj=$(printf '%s' "$tdp" | base64 -d 2>/dev/null)
                [ -n "$tdj" ] || tdj=$(printf '%s' "$tdp" | base64 -D 2>/dev/null)
                [ -n "$tdj" ] || tdj=$(printf '%s' "$tdp" | openssl base64 -d -A 2>/dev/null)
                \#(account)=$(printf '%s' "$tdj" | tr -d ' \t\n\r' | sed -n 's/.*"email":"\([^"]*\)".*/\1/p' | head -n 1)
              fi
            fi
            """#
        case .gemini:
            return #"""
            tdg=$(sed -n 's/.*"selectedType"[^"]*"\([^"]*\)".*/\1/p' "$HOME/.gemini/settings.json" 2>/dev/null | head -n 1)
            [ -n "$tdg" ] || tdg=$(sed -n 's/.*"selectedAuthType"[^"]*"\([^"]*\)".*/\1/p' "$HOME/.gemini/settings.json" 2>/dev/null | head -n 1)
            [ -n "$tdg" ] || tdg=$\#(geminiEnv)
            if [ -n "$tdg" ]; then \#(state)=yes; else \#(state)=no; fi
            if [ "$\#(state)" = yes ]; then
              \#(account)=$(sed -n 's/.*"active"[^"]*"\([^"]*\)".*/\1/p' "$HOME/.gemini/google_accounts.json" 2>/dev/null | head -n 1)
            fi
            """#
        }
    }

    public static func signInCases(agentVar: String, binary: String, state: String, account: String,
                                   codexHome: String, geminiEnv: String) -> String {
        var lines = [#"case "$\#(agentVar)" in"#]
        for id in [BackendServersAgentID.claude, .codex, .gemini] {
            lines += [id.rawValue + ")", signInSnippet(id, binary: binary, state: state, account: account,
                                                    codexHome: codexHome, geminiEnv: geminiEnv), "  ;;"]
        }
        return (lines + ["esac"]).joined(separator: "\n")
    }
}
