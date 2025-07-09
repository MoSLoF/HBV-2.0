# HBV-2.0

# 🐾 HoneyBadger Vanguard (HBV) 2.0

**Modular Threat Simulation + Detection Engineering Toolkit**  
_Automates hardened lab environments, adversary emulation, and detection validation across Windows and Kali._

## 🚀 What is HBV?

**HoneyBadger Vanguard 2.0** is a cross-platform toolkit for Red, Blue, and Purple Team operations. It accelerates endpoint hardening, tradecraft simulation, and SOC validation.

- 🔐 Windows & Kali post-install hardening
- 🎭 Tradecraft prep: AV exclusions, LOLBins, payload launchers
- 🧪 BOF hunting with Volatility + YARA
- 📈 Sigma + YARA auto-rule generation
- 🛡️ Purple Team validation lab: Atomic Red Team, MITRE ATT&CK

---

## 🧰 Modules

| Module | Purpose |
|--------|---------|
| `PimpMyWindows.ps1` | GUI to toggle Secure Mode or Tradecraft Mode on Windows 11 |
| `HBV-Core.ps1` | Master script for system tuning, logging, exclusions |
| `BOF_Hunter_GUI.ps1` | YARA + Volatility GUI for BOF memory triage |
| `repo_hunter.ps1` | Clones & parses top cyber threat repos |
| `auto_parse_hunting_results.ps1` | Builds Sigma/YARA rules from hunting results |

---

## 🏁 Quick Start

1. Clone the repo:
   ```powershell
   git clone https://github.com/MoSLoF/HBV-2.0.git
   cd HBV-2.0
   ```

2. Run the GUI or core setup:
   ```powershell
   .\PimpMyWindows.ps1
   ```

3. Start a BOF hunt:
   ```powershell
   .\BOF_Hunter_GUI.ps1
   ```

4. Auto-generate detection rules:
   ```powershell
   .\auto_parse_hunting_results.ps1
   ```
