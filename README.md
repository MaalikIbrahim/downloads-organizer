# Downloads Organizer (PowerShell)

A rule-based file organizer for Windows. It sorts every loose file in a folder (your Downloads by default) into subfolders based on file-name rules you define in JSON. It never deletes anything.

I built this to keep a busy support workstation tidy: tickets, reports, exports, phone photos and installers pile up fast, and finding last week's file shouldn't take five minutes.

## Features

- **Rules in JSON, not code.** Regex rules map file names to folders; first match wins.
- **Duplicate detection.** Files with the same SHA-256 hash as something already filed go to `_Duplicates to delete` for you to review. Size is checked first, so hashing stays fast.
- **Version handling.** If a file with the same name but different content already exists, the newer one stays current and the older one moves to `Old Versions`, stamped with its last-modified date.
- **Nothing left loose.** Files no rule matches are sorted by type into `_Unsorted\<type>`.
- **Safe by design.** Nothing is deleted. Files locked by another app (e.g. open in Excel) are skipped and listed at the end.
- **Preview mode.** `-Preview` shows exactly what would move without touching anything.

## Usage

```powershell
# 1. Copy the example rules and edit them for your folders
Copy-Item .\rules.example.json .\rules.json

# 2. See what would happen
.\Organize-Downloads.ps1 -Preview

# 3. Run it
.\Organize-Downloads.ps1

# Sort a different folder with a different rules file
.\Organize-Downloads.ps1 -Path D:\Inbox -RulesFile .\inbox-rules.json
```

Prefer double-clicking? Use `Run-Organize-Downloads.cmd` or `Preview-Organize-Downloads.cmd`.

## Rules file

```json
{
  "overrides": { "IMG_0001.jpg": "Projects\\Site Visit Photos" },
  "rules": [
    { "pattern": "invoice|receipt", "folder": "Finance\\Invoices and Receipts" },
    { "pattern": "ticket|service call", "folder": "Support\\Tickets and Service Calls" }
  ]
}
```

- `overrides`: exact file name to folder, for one-off files whose names don't say where they belong.
- `rules`: case-insensitive regex patterns, checked top to bottom.

## Example output

```
Moved: Q3 usage report.xlsx -> Data\Reports and Exports\Q3 usage report.xlsx
Duplicate of Finance\Invoices and Receipts\INV-1042.pdf: INV-1042 (1).pdf -> _Duplicates to delete\INV-1042 (1).pdf
Older copy to Old Versions: runbook.docx -> Knowledge Base\Old Versions\runbook (2026-10-01).docx

Done. Nothing was deleted.
Filed: 12   Duplicates: 3   Older copies to Old Versions: 1   Unsorted: 2   Couldn't move: 0
```

## Requirements

Windows PowerShell 5.1 or PowerShell 7+.

## License

MIT
