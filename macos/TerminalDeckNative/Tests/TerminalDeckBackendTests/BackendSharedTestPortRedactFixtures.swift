import Foundation

// Public fake token shapes copied from diagnostics.test.ts, never live credentials.
enum BackendSharedTestPortRedactFixtures {
    static let tokens: [(name: String, secret: String)] = [
        ("anthropic", "sk-ant-api03-Zx" + "8kQm2LpR7vNw4TgH" + "1sYbF6dJcE" + "0aUiOx9PlKm" + "QnR3tVzWyXs"),
        ("openai", "sk-proj-7HgTn2" + "QpLxV8mZcR4yBw" + "K1sD6fJaE" + "9uNoI0PlM" + "3tXvYbCqWr"),
        ("openai-legacy", "sk-T3Bl" + "bkFJ9mQx" + "2vLpR8nZ" + "wK4tYgH6" + "sB1dCeF0" + "aUiOx7Pl"),
        ("github-classic", "ghp_16C7e4" + "2F292c6912" + "E7710c" + "838347A" + "e178B4a"),
        ("github-oauth", "gho_16C7e4" + "2F292c6912E" + "7710c83" + "8347Ae1" + "78B4aZZ"),
        ("github-fine-grained", "github_pat_11ABC" + "DEFG0aBcDeFgHiJk" + "L_MnOpQrSt" + "UvWxYz01234" + "56789AbCdEf"),
        ("gitlab", "glpat-ABCdefG" + "HIjklMNOpqrST"),
        ("slack-bot", "xoxb-123456789" + "012-1234567890" + "123-AbCdE" + "fGhIjKlMn" + "OpQrStUvWx"),
        ("slack-app", "xapp-1-A012B" + "CDEFGH-12345" + "67890123" + "-abcdef0" + "123456789"),
        ("aws-access-key", "AKIAIOSFOD" + "NN7EXAMPLE"),
        ("google-api", "AIzaSyD-9tSrke72Pou" + "QMnMX-" + "a7eZSW0" + "jkFMBWY"),
        ("google-oauth", "ya29.a0AfH6S" + "MBx7Yq2LpR8n" + "ZwK4tYgH" + "6sB1dCeF" + "0aUiOx7Pl"),
        ("stripe", "sk_live_51H" + "8xQ2LpR7vNw" + "4TgH1sYbF6d"),
        ("npm", "npm_aBcDeFgHi" + "JkLmNoPqRsTuV" + "wXyZ0123456789"),
        ("huggingface", "hf_ABCdefGH" + "IjklMNOpqrS" + "TuvwxYZ0123"),
        ("supabase", "sbp_0123456789" + "abcdef012345678" + "9abcdef01234567"),
        ("sendgrid", "SG.aBcDeFgHiJkLmN" + "oPqRsT.uVwXyZ0123" + "456789AbCdEfGhIjKl"),
        ("jwt", "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzd" + "WIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4ifQ." + "dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"),
        ("bare-hex-32", "d41d8cd98f00b" + "204e9800998ec" + "f8427e1a2b3c4d"),
        ("bare-base64", "aGVsbG8gd29ybGQg" + "dGhpcyBpcyBhIGxvb" + "mcgc2VjcmV0Cg1234"),
    ]
}
