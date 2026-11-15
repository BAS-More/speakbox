# Security

SpeakBox runs locally and makes no network calls of its own. `setup.ps1` downloads models from
GitHub and Hugging Face and checks every file against a pinned SHA-256 before using it.

To report a vulnerability, please use GitHub's
[private vulnerability reporting](https://github.com/BAS-More/speakbox/security/advisories/new)
rather than a public issue.
