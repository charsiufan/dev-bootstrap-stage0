# Development machine Stage 0

This public repository contains the authoritative first-run entry scripts. They install only the prerequisites needed to authenticate GitHub, select a branch, clone the private `charsiufan/dev-bootstrap` repository, and hand control to its platform bootstrap.

## Windows

Open PowerShell:

```powershell
irm 'https://raw.githubusercontent.com/charsiufan/dev-bootstrap-stage0/main/stage0.ps1' | iex
```

The script prompts for a data drive and bootstrap branch. For automation, download the script and use its `-DataDrive`, `-Branch`, and `-DryRun` parameters.

## macOS

Open Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/charsiufan/dev-bootstrap-stage0/main/stage0.sh | bash
```

The script supports `--branch <name>` for non-interactive branch selection and `--dry-run` for a read-only preview when prerequisites are already available.

For example:

```bash
curl -fsSL https://raw.githubusercontent.com/charsiufan/dev-bootstrap-stage0/main/stage0.sh | bash -s -- --branch refactor/declarative-bootstrap
```

Command Line Tools installation remains an Apple-controlled interactive step. GitHub authentication opens a browser when required.
